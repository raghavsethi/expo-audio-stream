//
//  AudioStreamManager.swift
//  ExpoAudioStream
//
//  Created by Arthur Breton on 21/4/2024.
//

import Foundation
import AVFoundation

struct RecordingSettings {
    var sampleRate: Double
    var numberOfChannels: Int = 1
    var bitDepth: Int = 16
}

// Helper to convert to little-endian byte array
extension UInt32 {
    var littleEndianBytes: [UInt8] {
        let value = self.littleEndian
        return [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
    }
}

extension UInt16 {
    var littleEndianBytes: [UInt8] {
        let value = self.littleEndian
        return [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
    }
}


struct RecordingResult {
    var fileUri: String
    var mimeType: String
    var duration: Int64
    var size: Int64
}

protocol AudioStreamManagerDelegate: AnyObject {
    func audioStreamManager(_ manager: AudioStreamManager, didReceiveAudioData data: Data, recordingTime: TimeInterval, totalDataSize: Int64)
}

enum AudioStreamError: Error {
    case audioSessionSetupFailed(String)
    case fileCreationFailed(URL)
    case audioProcessingError(String)
}

class AudioStreamManager: NSObject {
    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode {
        return audioEngine.inputNode
    }
    internal var recordingFileURL: URL?
    private var startTime: Date?
    internal var lastEmissionTime: Date?
    internal var lastEmittedSize: Int64 = 0
    private var emissionInterval: TimeInterval = 1.0 // Default to 1 second
    private var totalDataSize: Int64 = 0
    private var isRecording = false
    private var isPaused = false
    private var pausedDuration = 0
    private var fileManager = FileManager.default
    private var recordingSettings: RecordingSettings?
    internal var recordingUUID: UUID?
    internal var mimeType: String = "audio/wav"
    weak var delegate: AudioStreamManagerDelegate?  // Define the delegate here
    
    override init() {
        super.init()
        configureAudioSession()
    }
    
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
            print("Audio session configured successfully.")
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
        }
    }
    
    @objc func handleAudioSessionInterruption(notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        if type == .began {
            // Pause your audio recording
        } else if type == .ended {
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    // Resume your audio recording
                    try? AVAudioSession.sharedInstance().setActive(true)
                }
            }
        }
    }
    
    private func createRecordingFile() -> URL? {
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        recordingUUID = UUID()
        let fileName = "\(recordingUUID!.uuidString).wav"
        let fileURL = documentsDirectory.appendingPathComponent(fileName)
        
        if fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: nil) {
            do {
                let fileHandle = try FileHandle(forWritingTo: fileURL)
                let wavHeader = createWavHeader(dataSize: 0)  // Initially set data size to 0
                fileHandle.write(wavHeader)
                fileHandle.closeFile()
                print("Recording file with header created at:", fileURL.path)
            } catch {
                print("Failed to write WAV header: \(error.localizedDescription)")
                return nil
            }
        }
        return fileURL
    }
    
    private func createWavHeader(dataSize: Int) -> Data {
        var header = Data()
        
        let sampleRate = UInt32(recordingSettings!.sampleRate)
        let channels = UInt32(recordingSettings!.numberOfChannels)
        let bitDepth = UInt32(recordingSettings!.bitDepth)
        
        // Calculate byteRate
        let byteRate = sampleRate * channels * (bitDepth / 8)
        
        // "RIFF" chunk descriptor
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: UInt32(36 + dataSize).littleEndianBytes)
        header.append(contentsOf: "WAVE".utf8)
        
        // "fmt " sub-chunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: UInt32(16).littleEndianBytes)  // PCM format requires 16 bytes for the fmt sub-chunk
        header.append(contentsOf: UInt16(1).littleEndianBytes)   // Audio format 1 for PCM
        header.append(contentsOf: UInt16(channels).littleEndianBytes)
        header.append(contentsOf: sampleRate.littleEndianBytes)
        header.append(contentsOf: byteRate.littleEndianBytes)    // byteRate
        header.append(contentsOf: UInt16(channels * (bitDepth / 8)).littleEndianBytes)  // blockAlign
        header.append(contentsOf: UInt16(bitDepth).littleEndianBytes)  // bits per sample
        
        // "data" sub-chunk
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: UInt32(dataSize).littleEndianBytes)  // Sub-chunk data size
        
        return header
    }
    
    
    func getStatus() -> [String: Any] {
        let currentTime = Date()
        let totalRecordedTime = startTime != nil ? Int(currentTime.timeIntervalSince(startTime!)) - pausedDuration : 0
        return [
            "duration": totalRecordedTime * 1000,
            "isRecording": isRecording,
            "isPaused": isPaused,
            "mimeType": mimeType,
            "size": totalDataSize,
            "interval": emissionInterval
        ]
    }
    
    func startRecording(settings: RecordingSettings, intervalMilliseconds: Int) -> String? {
        guard !isRecording else {
            print("Debug: Recording is already in progress.")
            return nil
        }

        emissionInterval = max(100.0, Double(intervalMilliseconds)) / 1000.0
        lastEmissionTime = Date()
        recordingSettings = settings
        
        let session = AVAudioSession.sharedInstance()
        do {
            print("Debug: Configuring audio session with sample rate: \(settings.sampleRate) Hz")
            try session.setPreferredSampleRate(settings.sampleRate)
            try session.setPreferredIOBufferDuration(1024 / settings.sampleRate)
            try session.setCategory(.playAndRecord)
            try session.setActive(true)
            print("Debug: Audio session activated successfully.")
        } catch {
            print("Error: Failed to set up audio session with preferred settings: \(error.localizedDescription)")
            return nil
        }

        NotificationCenter.default.addObserver(self, selector: #selector(handleAudioSessionInterruption), name: AVAudioSession.interruptionNotification, object: nil)

        guard let channelLayout = AVAudioChannelLayout(layoutTag: settings.numberOfChannels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo) else {
            print("Error: Failed to create channel layout.")
            return nil
        }
        let errorFormat = AVAudioFormat(standardFormatWithSampleRate: settings.sampleRate, channelLayout: channelLayout)

        audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: errorFormat) { [weak self] (buffer, time) in
            guard let self = self, let fileURL = self.recordingFileURL else {
                print("Error: File URL or self is nil during buffer processing.")
                return
            }
            self.processAudioBuffer(buffer, fileURL: fileURL)
        }

        recordingFileURL = createRecordingFile()
        if recordingFileURL == nil {
            print("Error: Failed to create recording file.")
            return nil
        }

        do {
            startTime = Date()
            try audioEngine.start()
            isRecording = true
            print("Debug: Recording started successfully.")
            return recordingFileURL?.absoluteString
        } catch {
            print("Error: Could not start the audio engine: \(error.localizedDescription)")
            isRecording = false
            return nil
        }
    }

    
    func stopRecording() -> RecordingResult? {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        
        guard let fileURL = recordingFileURL, let startTime = startTime else {
            print("Recording or file URL is nil.")
            return nil
        }
        
        let endTime = Date()
        let duration = Int64(endTime.timeIntervalSince(startTime) * 1000) - Int64(pausedDuration * 1000)
        
        // Calculate the total size of audio data written to the file
        let filePath = fileURL.path
        do {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: filePath)
            let fileSize = fileAttributes[FileAttributeKey.size] as? Int64 ?? 0
            
            // Update the WAV header with the correct file size
            updateWavHeader(fileURL: fileURL, totalDataSize: fileSize - 44) // Subtract the header size to get audio data size
            
            let result = RecordingResult(fileUri: fileURL.absoluteString, mimeType: mimeType, duration: duration, size: fileSize)
            recordingFileURL = nil // Reset for next recording
            return result
        } catch {
            print("Failed to fetch file attributes: \(error)")
            return nil
        }
    }
    
    private func updateWavHeader(fileURL: URL, totalDataSize: Int64) {
        do {
            let fileHandle = try FileHandle(forUpdating: fileURL)
            defer { fileHandle.closeFile() }
            
            // Calculate sizes
            let fileSize = totalDataSize + 44 - 8 // Total file size minus 8 bytes for 'RIFF' and size field itself
            let dataSize = totalDataSize // Size of the 'data' sub-chunk
            
            // Update RIFF chunk size at offset 4
            fileHandle.seek(toFileOffset: 4)
            let fileSizeBytes = UInt32(fileSize).littleEndianBytes
            fileHandle.write(Data(fileSizeBytes))
            
            // Update data chunk size at offset 40
            fileHandle.seek(toFileOffset: 40)
            let dataSizeBytes = UInt32(dataSize).littleEndianBytes
            fileHandle.write(Data(dataSizeBytes))
            
        } catch let error {
            print("Error updating WAV header: \(error)")
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, fileURL: URL) {
        guard let fileHandle = try? FileHandle(forWritingTo: fileURL) else {
            print("Failed to open file handle for URL: \(fileURL)")
            return
        }
        
        let audioData = buffer.audioBufferList.pointee.mBuffers
        guard let bufferData = audioData.mData else {
            print("Buffer data is nil.")
            return
        }
        let data = Data(bytes: bufferData, count: Int(audioData.mDataByteSize))
        
        print("Writing data size: \(data.count) bytes")  // Debug: Check the size of data being written
        fileHandle.seekToEndOfFile()
        fileHandle.write(data)
        fileHandle.closeFile()
        
        totalDataSize += Int64(data.count)
        print("Total data size written: \(totalDataSize) bytes")  // Debug: Check total data written

        let currentTime = Date()
        if let lastEmissionTime = lastEmissionTime, currentTime.timeIntervalSince(lastEmissionTime) >= emissionInterval {
            if let startTime = startTime {
                let recordingTime = currentTime.timeIntervalSince(startTime)
                print("Emitting data: Recording time \(recordingTime) seconds, Data size \(totalDataSize) bytes")
                self.delegate?.audioStreamManager(self, didReceiveAudioData: data, recordingTime: recordingTime, totalDataSize: totalDataSize)
                self.lastEmissionTime = currentTime // Update last emission time
                self.lastEmittedSize = totalDataSize
            }
        }
    }
    
}