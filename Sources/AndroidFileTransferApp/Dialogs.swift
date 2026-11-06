import SwiftUI

struct ConflictSheet: View {
    @Environment(Localization.self) private var l10n

    let request: ConflictRequest
    let resolve: (ConflictResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.t("conflict.title"))
                .font(.title2.weight(.semibold))

            Text(l10n.t("conflict.message", request.names.count))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(request.names, id: \.self) { name in
                    Label(name, systemImage: "doc")
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Text(l10n.t("conflict.replaceWarning"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(l10n.t("conflict.cancel")) {
                    resolve(.cancel)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(l10n.t("conflict.keepBoth")) {
                    resolve(.keepBoth)
                }
                .keyboardShortcut(.defaultAction)

                Button(l10n.t("conflict.replace"), role: .destructive) {
                    resolve(.replace)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }
}

struct OnboardingView: View {
    @Environment(Localization.self) private var l10n

    let done: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text(l10n.t("onboarding.title"))
                .font(.largeTitle.weight(.semibold))

            Text(l10n.t("onboarding.subtitle"))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                Label(l10n.t("onboarding.step1"), systemImage: "1.circle.fill")
                Label(l10n.t("onboarding.step2"), systemImage: "2.circle.fill")
                Label(l10n.t("onboarding.step3"), systemImage: "3.circle.fill")
            }
            .padding(.top, 4)

            HStack {
                Button(l10n.t("onboarding.access")) {
                    AccessGuideWindowController.shared.show(l10n: l10n)
                }

                Spacer()

                Button(l10n.t("onboarding.done")) {
                    done()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 500)
    }
}
