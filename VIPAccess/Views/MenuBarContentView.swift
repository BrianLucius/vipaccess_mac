import SwiftUI

/// Content view displayed when the menu bar item is clicked.
/// Shows the full dropdown menu with token display, credential info,
/// and actions for copy, window toggle, re-migration, and quit.
struct MenuBarContentView: View {
    @ObservedObject var viewModel: TokenViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var showingRemigrationConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Current token — tap to copy
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(viewModel.currentCode, forType: .string)
            }) {
                Text(viewModel.currentCode)
            }
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Credential ID — tap to copy
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(viewModel.credentialID, forType: .string)
            }) {
                Text(viewModel.credentialID)
            }
            .padding(.bottom, 4)

            // Progress bar showing time remaining
            ProgressBarView(
                secondsRemaining: viewModel.secondsRemaining,
                period: 30
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Copy Token
            Button("Copy Token") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(viewModel.currentCode, forType: .string)
            }
            .keyboardShortcut("c")

            // Show Window
            Button("Show Window") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "token-window")
            }
            .keyboardShortcut("w")

            // Re-migrate Credential
            Button("Re-migrate Credential") {
                showingRemigrationConfirmation = true
            }
            .confirmationDialog(
                "Re-migrate Credential",
                isPresented: $showingRemigrationConfirmation
            ) {
                Button("Replace Credential", role: .destructive) {
                    viewModel.forceRemigrate()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will replace your current credential with the one from Symantec VIP Access. Continue?")
            }

            // Enable Paste Service — opens System Settings and shows instructions
            Button("Enable Paste Service\u{2026}") {
                enablePasteService()
            }

            Divider()

            // Quit
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    /// Opens System Settings to the Keyboard Shortcuts pane and shows the user
    /// how to enable the "Paste VIP Access Token" service.
    private func enablePasteService() {
        NSApp.activate(ignoringOtherApps: true)

        // Try the modern (Ventura+) Keyboard settings identifier first,
        // then fall back to the legacy identifier, then to plain System Settings.
        let urls = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts",
        ]
        for urlString in urls {
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                break
            }
        }

        // Show step-by-step instructions the user follows in System Settings.
        let alert = NSAlert()
        alert.messageText = "Enable \"Paste VIP Access Token\""
        alert.informativeText = """
            In the System Settings window that just opened:

            1. Go to Keyboard \u{2192} Keyboard Shortcuts\u{2026}
            2. Select Services in the left list.
            3. Expand the Text section.
            4. Check the box next to "Paste VIP Access Token".

            Once enabled, right-click in any text field and choose
            Services \u{2192} Paste VIP Access Token to insert the current code.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Done")
        // Force a wider alert so the numbered steps don't wrap.
        // NSAlert sizes to its accessory view width when one is set.
        let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 1))
        alert.accessoryView = spacer
        alert.runModal()
    }
}
