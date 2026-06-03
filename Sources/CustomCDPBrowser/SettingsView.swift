import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

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

            Section("About") {
                Text("If the menu bar icon is hidden, use the global shortcut or reopen the app from Spotlight to access this panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Version", value: AppVersion.current)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 400)
    }
}

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}
