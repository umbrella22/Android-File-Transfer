import SwiftUI

struct SettingsView: View {
    let appModel: AppModel
    let l10n: Localization

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        Form {
            Section(l10n.t("settings.general")) {
                Picker(
                    l10n.t("general.language"),
                    selection: Binding(
                        get: { l10n.language },
                        set: { l10n.language = $0 }
                    )
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(l10n.displayName(for: language))
                            .tag(language)
                    }
                }
            }

            Section(l10n.t("settings.browsing")) {
                Toggle(
                    l10n.t("settings.showHiddenFiles"),
                    isOn: Binding(
                        get: { appModel.local.showHiddenFiles },
                        set: { appModel.local.showHiddenFiles = $0 }
                    )
                )
            }

            Section(l10n.t("settings.permissions")) {
                Button(l10n.t("settings.accessGuide")) {
                    AccessGuideWindowController.shared.show(
                        l10n: l10n,
                        onRecheck: { appModel.local.reload() }
                    )
                }
            }

            Section(l10n.t("settings.about")) {
                LabeledContent("Android File Transfer", value: l10n.t("settings.version", appVersion))
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 360)
        .navigationTitle(l10n.t("settings.title"))
    }
}
