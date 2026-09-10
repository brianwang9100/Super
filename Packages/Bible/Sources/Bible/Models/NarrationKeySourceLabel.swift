import Core

enum NarrationKeySourceLabel {
    static func make(for source: ProviderAudioCredential, among sources: [ProviderAudioCredential]) -> String {
        let matchingIDs = sources.filter { $0.name == source.name }.map(\.id).sorted()
        guard matchingIDs.count > 1, let index = matchingIDs.firstIndex(of: source.id) else {
            return "Use existing key (\(source.name))"
        }
        return "Use existing key \(index + 1) (\(source.name))"
    }
}
