/// Optional chapter navigation contributed by the full reader host.
struct BibleChapterNavigation {
    let previousLabel: String?
    let nextLabel: String?
    let onPrevious: () -> Void
    let onNext: () -> Void
}
