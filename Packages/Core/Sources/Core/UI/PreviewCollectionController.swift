#if DEBUG && canImport(UIKit)
import SwiftUI
import UIKit

/// A fixed viewport of deterministic collection cells proving UIKit preview discovery.
/// The remaining rows intentionally extend beyond the captured viewport.
final class PreviewCollectionController: UICollectionViewController {
    init() {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 370, height: 48)
        layout.minimumLineSpacing = 8
        super.init(collectionViewLayout: layout)
        // Reused worktree simulators may retain accessibility text-size settings.
        traitOverrides.preferredContentSizeCategory = .large
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        Core.registerBundledFonts()
        collectionView.backgroundColor = UIColor(SuperTheme.make(.vellumLight).background)
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "row")
    }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        12
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath)
        let typography = SuperTypography.make(.serif)
        cell.contentConfiguration = UIHostingConfiguration {
            HStack {
                Text("Preview row").font(typography.font(.body))
                Spacer()
                Text(String(indexPath.item + 1)).font(typography.mono(12))
            }
            .foregroundStyle(SuperTheme.make(.vellumLight).ink)
        }
        return cell
    }
}

#Preview("collection_viewport_light", traits: .fixedLayout(width: 402, height: 180)) {
    PreviewCollectionController()
}

// A non-scrolling UIViewController isolates UIKit bridging and font rendering
// from the renderer's collection-view expansion behavior.
/// Creates the font probe's UIKit host for capture and environment regression tests.
func makePreviewFontPanelController() -> UIViewController {
    Core.registerBundledFonts()
    let typography = SuperTypography.make(.serif)
    let controller = UIHostingController(rootView:
        VStack(spacing: 16) {
            Text("EB Garamond").font(typography.display(26))
            Text("JetBrains Mono 0123456789").font(typography.mono(12))
        }
        .frame(width: 402, height: 180)
        .foregroundStyle(SuperTheme.make(.vellumLight).ink)
        .background(SuperTheme.make(.vellumLight).background)
    )
    controller.traitOverrides.preferredContentSizeCategory = .large
    return controller
}

#Preview("font_panel_light", traits: .fixedLayout(width: 402, height: 180)) {
    makePreviewFontPanelController()
}
#endif
