import Core
import SwiftUI

struct FailureScreen: View {
    let message: String

    @Environment(\.superTheme) private var theme
    @Environment(\.superTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bootstrap failed")
                .font(typography.font(.headline, weight: .semibold))
                .foregroundStyle(theme.errorAccent)
            Text(message)
                .font(typography.font(.callout))
                .foregroundStyle(theme.inkSoft)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
