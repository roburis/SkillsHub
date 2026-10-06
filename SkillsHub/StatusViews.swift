import SwiftUI

struct StatusBanner: View {
    enum Style {
        case status
        case error
    }

    var message: LocalizedMessage
    var language: AppLanguage
    var systemImage: String
    var style: Style
    var dismissAccessibilityLabel: String? = nil
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(SkillsHubLocalization().localized(message, language: language))
                .foregroundStyle(style == .error ? .primary : .secondary)
                .accessibilityIdentifier("status-banner")

            Spacer(minLength: 12)

            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(dismissAccessibilityLabel ?? "")
                .accessibilityLabel(dismissAccessibilityLabel ?? "")
                .accessibilityIdentifier("status-banner-dismiss")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }
}
