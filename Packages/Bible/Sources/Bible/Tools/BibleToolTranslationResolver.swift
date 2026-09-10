import Foundation

enum BibleToolTranslationResolver {
    /// Explicit codes are case-insensitive and strictly validated. Nil/blank uses the
    /// saved translation, then the default if storage is unavailable. Unknown explicit
    /// codes throw BibleToolValidationError so the model can correct them.
    static func resolve(
        explicitCode: String?,
        positionRepository: (any BibleReadingPositionRepository)?
    ) async throws -> BibleTranslation {
        if let raw = explicitCode,
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let translation = BibleTranslation(rawValue: code) else {
                let valid = BibleTranslation.allCases.map(\.rawValue).joined(separator: ", ")
                throw BibleToolValidationError("Unknown translation '\(raw)'. Available: \(valid).")
            }
            return translation
        }
        var storedCode: String?
        if let positionRepository {
            storedCode = (try? await positionRepository.load())?.translationId
        }
        return storedCode.flatMap(BibleTranslation.init(rawValue:)) ?? .defaultTranslation
    }
}

/// Tool executors return this as a correctable isError result instead of failing the turn.
struct BibleToolValidationError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}
