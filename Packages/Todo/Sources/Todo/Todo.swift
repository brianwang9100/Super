/// Top-level umbrella for the Todo applet. Real types live under
/// `Applet/`, `Database/`, `Models/`, `Repositories/`, `Domain/`,
/// `ViewModels/`, and `UI/` as later milestones land.
public enum TodoModule {
    /// Stable applet identifier — used for routing, settings keys, and
    /// deep-link URIs (`super://todo/<recordID>`).
    public static let appletID: String = "todo"
}
