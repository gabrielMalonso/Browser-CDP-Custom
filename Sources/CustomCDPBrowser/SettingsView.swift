import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var currentDefaultBrowserName = DefaultBrowserManager.currentDefaultBrowserName()
    @State private var isSelfDefaultBrowser = DefaultBrowserManager.isSelfDefaultBrowser()
    @State private var isSettingDefaultBrowser = false
    @State private var defaultBrowserFeedback: String?
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage(UserDefaultsKeys.linkRoutingMode) private var linkRoutingMode = LinkRoutingMode.askEveryTime.rawValue

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try LaunchAtLogin.enable()
                            } else {
                                try LaunchAtLogin.disable()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }

                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)

                KeyboardShortcuts.Recorder("Open Overlay:", name: .toggleOverlay)
                    .padding(.vertical, 4)
            }

            Section("Links") {
                LabeledContent("Default browser", value: currentDefaultBrowserName)

                Button {
                    setAsDefaultBrowser()
                } label: {
                    if isSettingDefaultBrowser {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Set as Default Browser")
                    }
                }
                .disabled(isSettingDefaultBrowser || isSelfDefaultBrowser)

                Picker("Open links:", selection: $linkRoutingMode) {
                    ForEach(LinkRoutingMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }

                if let defaultBrowserFeedback {
                    Text(defaultBrowserFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                Text("If the menu bar icon is hidden, use the global shortcut or reopen the app from Spotlight to access this panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Version", value: AppVersion.current)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 400)
        .onAppear {
            refreshDefaultBrowserStatus()
        }
    }

    private func refreshDefaultBrowserStatus() {
        currentDefaultBrowserName = DefaultBrowserManager.currentDefaultBrowserName()
        isSelfDefaultBrowser = DefaultBrowserManager.isSelfDefaultBrowser()
    }

    private func setAsDefaultBrowser() {
        isSettingDefaultBrowser = true
        defaultBrowserFeedback = nil

        DefaultBrowserManager.setSelfAsDefaultBrowser { result in
            isSettingDefaultBrowser = false
            refreshDefaultBrowserStatus()

            switch result {
            case .success:
                defaultBrowserFeedback = "Custom CDP Browser is the default browser."
            case .failure(let error):
                defaultBrowserFeedback = error.localizedDescription
            }
        }
    }
}

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
