import SwiftUI
import AppKit

@main
struct VIPAccessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = TokenViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(viewModel: viewModel)
        } label: {
            StatusItemLabel(
                code: viewModel.currentCode,
                secondsRemaining: viewModel.secondsRemaining,
                period: 30
            )
            .onAppear {
                appDelegate.viewModel = viewModel
                viewModel.loadCredential()
            }
            .onChange(of: viewModel.error) { _, newError in
                // loadCredential() runs asynchronously, so the terminal failure
                // arrives here rather than synchronously after the call above.
                if !viewModel.isLoaded, let error = newError {
                    showErrorAlertAndQuit(error: error)
                }
            }
        }

        Window("VIP Access", id: "token-window") {
            TokenWindowView(viewModel: viewModel)
        }
        .defaultSize(width: 250, height: 228)
        .windowResizability(.contentSize)
    }

    /// Shows a critical alert explaining that no credential was found,
    /// then terminates the app after the user dismisses it.
    private func showErrorAlertAndQuit(error: KeychainError) {
        let alert = NSAlert()
        alert.messageText = "VIP Access — No Credential Found"
        alert.informativeText = """
            \(error.errorDescription ?? "Unknown error")

            VIP Access requires a credential from the Symantec VIP Access \
            keychain. Please ensure Symantec VIP Access has been provisioned \
            on this Mac before launching this app.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
