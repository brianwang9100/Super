import AVFoundation
import Core
import Foundation

/// Persistent voice identity, independent of the speech engine's framework objects.
public struct NarrationVoice: Codable, Sendable, Equatable, Identifiable {
    /// Company shown alongside every voice in the narration picker.
    public enum Company: String, Codable, Sendable { case apple, openAI }
    public let company: Company
    public let identifier: String
    public var id: String { "\(company.rawValue):\(identifier)" }
    public var companyName: String { company == .openAI ? "OpenAI" : "Apple" }
    public var openAI: OpenAISpeechVoice? { company == .openAI ? OpenAISpeechVoice(rawValue: identifier) : nil }
    public var appleVoice: AVSpeechSynthesisVoice? {
        company == .apple && !identifier.isEmpty ? AVSpeechSynthesisVoice(identifier: identifier) : nil
    }
    public init(company: Company, identifier: String) {
        self.company = company
        self.identifier = identifier
    }
    public init(_ voice: AVSpeechSynthesisVoice) {
        self.init(company: .apple, identifier: voice.identifier)
    }
    public init?(id: String) {
        guard let colon = id.firstIndex(of: ":"), let company = Company(rawValue: String(id[..<colon])) else { return nil }
        self.init(company: company, identifier: String(id[id.index(after: colon)...]))
    }
    public static let appleDefault = NarrationVoice(company: .apple, identifier: "")
    public static let marin = NarrationVoice(company: .openAI, identifier: "marin")
}
