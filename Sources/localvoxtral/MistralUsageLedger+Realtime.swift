import Foundation

extension MistralUsageLedger: MistralRealtimeUsageRecording {
    func recordRealtimeDictation(date: Date, model: String, audioSeconds: Double) {
        record(
            MistralUsageEntry(
                date: date,
                kind: .dictation,
                model: model,
                audioSeconds: audioSeconds,
                costEUR: MistralPricing.dictationCost(model: model, audioSeconds: audioSeconds)
            )
        )
    }
}
