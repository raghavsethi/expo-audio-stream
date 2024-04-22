import ExpoModulesCore
import AVFoundation

let audioDataEvent: String = "AudioData"

public class ExpoAudioStreamModule: Module, AudioStreamManagerDelegate {
    private var streamManager = AudioStreamManager()
    
    public func definition() -> ModuleDefinition {
        Name("ExpoAudioStream")
        
        // Defines event names that the module can send to JavaScript.
        Events(audioDataEvent)
        
        OnCreate {
            print("Setting streamManager delegate")
            streamManager.delegate = self
        }
        
        AsyncFunction("startRecording") { (options: [String: Any], promise: Promise) in
            self.checkMicrophonePermission { granted in
                guard granted else {
                    promise.reject("PERMISSION_DENIED", "Recording permission has not been granted")
                    return
                }
                
                // Extract settings from provided options, using default values if necessary
                let sampleRate = options["sampleRate"] as? Double ?? 16000.0 // it fails if not 48000, why?
                let numberOfChannels = options["channelConfig"] as? Int ?? 1 // Mono channel configuration
                let bitDepth = options["audioFormat"] as? Int ?? 16 // 16bits
                let interval = options["interval"] as? Int ?? 1000
                
                let settings = RecordingSettings(sampleRate: sampleRate, numberOfChannels: numberOfChannels, bitDepth: bitDepth)
                let url = self.streamManager.startRecording(settings: settings, intervalMilliseconds: interval)
                
                promise.resolve(url)
            }
        }
        
        Function("status") {
            return self.streamManager.getStatus()
        }
        
        AsyncFunction("stopRecording") { (promise: Promise) in
            if let recordingResult = self.streamManager.stopRecording() {
                // Convert RecordingResult to a dictionary
                let resultDict: [String: Any] = [
                    "fileUri": recordingResult.fileUri,
                    "duration": recordingResult.duration,
                    "size": recordingResult.size
                ]
                promise.resolve(resultDict)
            } else {
                promise.reject("ERROR", "Failed to stop recording or no recording in progress.")
            }
        }
        
        AsyncFunction("listAudioFiles") { (promise: Promise) in
            let files = listAudioFiles()
            promise.resolve(files)
        }
        
        Function("clearAudioFiles") {
            clearAudioFiles()
        }
    }
    
    func audioStreamManager(_ manager: AudioStreamManager, didReceiveAudioData data: Data, recordingTime: TimeInterval, totalDataSize: Int64) {
        guard let fileURL = manager.recordingFileURL else { return }
        let encodedData = data.base64EncodedString()
        
        // Assuming `lastEmittedSize` and `streamUuid` are tracked within `AudioStreamManager`
        let deltaSize = data.count  // This needs to be calculated based on what was last sent if using chunks
        let fileSize = totalDataSize  // Total data size in bytes
        
        // Construct the event payload similar to Android
        let eventBody: [String: Any] = [
            "fileUri": fileURL.absoluteString,
            "from": manager.lastEmittedSize,  // Needs to be maintained within AudioStreamManager
            "encoded": encodedData,
            "deltaSize": deltaSize,
            "totalSize": fileSize,
            "mimeType": manager.mimeType,
            "streamUuid": manager.recordingUUID?.uuidString ?? UUID().uuidString
        ]
        
        // Update the last emitted size for the next calculation
        manager.lastEmittedSize += Int64(deltaSize)
        
        // Emit the event to JavaScript
        sendEvent(audioDataEvent, eventBody)
    }
    
    private func checkMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        @unknown default:
            completion(false)
        }
    }
    
    private func clearAudioFiles() {
        let filenames = listAudioFiles()
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        filenames.forEach { filename in
            let fileURL = documentDirectory.appendingPathComponent(filename)
            do {
                try FileManager.default.removeItem(at: fileURL)
                print("Removed file at:", fileURL.path)
            } catch {
                print("Error removing file at \(fileURL.path):", error.localizedDescription)
            }
        }
    }
    
    func listAudioFiles() -> [String] {
        guard let documentDirectory = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else {
            print("Failed to access document directory.")
            return []
        }
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: documentDirectory, includingPropertiesForKeys: nil)
            let audioFiles = files.filter { $0.pathExtension == "wav" }.map { $0.lastPathComponent }
            return audioFiles
        } catch {
            print("Error listing audio files:", error.localizedDescription)
            return []
        }
    }
    
}