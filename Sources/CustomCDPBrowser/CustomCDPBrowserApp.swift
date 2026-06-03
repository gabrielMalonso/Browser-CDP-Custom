import SwiftUI

@main
struct CustomCDPBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra("Custom CDP Browser", systemImage: "network", isInserted: $showMenuBarIcon) {
            MenuBarView(appDelegate: appDelegate)
        }

        Settings {
            SettingsView()
        }
    }
}

struct MenuBarView: View {
    let appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading) {
            Button("Open Profiles...") {
                appDelegate.togglePanel()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Divider()

            SettingsLink {
                Text("Settings...")
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
