package net.siteed.audiostream

data class Features(
    val energy: Float = 0f,
    val mfcc: List<Float> = emptyList(),
    val rms: Float = 0f,
    val zcr: Float = 0f,
    val spectralCentroid: Float = 0f,
    val spectralFlatness: Float = 0f,
    val spectralRollOff: Float = 0f,
    val spectralBandwidth: Float = 0f,
    val chromagram: List<Float> = emptyList(),
    val tempo: Float = 0f,
    val hnr: Float = 0f
) {
    fun toDictionary(): Map<String, Any> {
        return mapOf(
            "energy" to energy,
            "mfcc" to mfcc,
            "rms" to rms,
            "zcr" to zcr,
            "spectralCentroid" to spectralCentroid,
            "spectralFlatness" to spectralFlatness,
            "spectralRollOff" to spectralRollOff,
            "spectralBandwidth" to spectralBandwidth,
            "chromagram" to chromagram,
            "tempo" to tempo,
            "hnr" to hnr
        )
    }
}
