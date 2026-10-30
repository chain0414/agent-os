import Foundation

/// Short-lived credentials for one account. Never persist or log these values.
nonisolated struct V2SpeechCredentials: Decodable, Sendable {
    let provider: String
    let model: String
    let websocketUrl: URL
    let token: String
    let expiresAt: Double
    let languageHints: [String]
    let sampleRate: Int
    let maxRecordingSeconds: Int
}
