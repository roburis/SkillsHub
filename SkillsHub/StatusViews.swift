import SwiftUI

struct ValidationStatusLabel: View {
    var validation: SkillValidationResult
    var language: AppLanguage
    private let localization = SkillsHubLocalization()

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(style)
    }

    private var title: String {
        switch validation.status {
        case .valid:
            return localized("Valid")
        case .warning:
            return localized("Warning")
        case .invalid:
            return localized("Invalid")
        }
    }

    private func localized(_ text: String) -> String {
        localization.localized(text, language: language)
    }

    private var systemImage: String {
        switch validation.status {
        case .valid:
            return "checkmark.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .invalid:
            return "xmark.octagon"
        }
    }

    private var style: HierarchicalShapeStyle {
        switch validation.status {
        case .valid:
            return .secondary
        case .warning:
            return .primary
        case .invalid:
            return .primary
        }
    }
}

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
