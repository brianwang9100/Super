/// App-owned identities for Apple's on-device and Private Cloud Compute (PCC)
/// models. These values discriminate saved configurations, not HTTP model names.
public enum AppleFoundationModel: String, Sendable, Equatable, Codable, CaseIterable {
    case local = "system-default"
    case privateCloudCompute = "private-cloud-compute"

    public var displayName: String {
        switch self {
        case .local: "Apple Intelligence — Local only"
        case .privateCloudCompute: "Apple Intelligence — Private Cloud Compute"
        }
    }

    /// Inert configuration placeholder when runtime metadata has not resolved.
    /// Generation must use a resolved context size; this is not a measured limit.
    public var fallbackContextTokens: Int {
        switch self {
        case .local: AppleFoundationLLMProvider.defaultMaxContextTokens
        case .privateCloudCompute: 32_000
        }
    }
}
