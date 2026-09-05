import AppKit
import ServiceManagement

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    /// Reference to the shared view model, set by VIPAccessApp after creation.
    /// Setting this property triggers service provider registration.
    var viewModel: TokenViewModel? {
        didSet {
            registerServiceProvider()
        }
    }

    /// Retains the service provider for the lifetime of the app.
    private var serviceProvider: TokenPasteService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerServiceProvider()
        registerAsLoginItem()
    }

    /// Registers the TokenPasteService as the app's Services provider.
    /// Called both from applicationDidFinishLaunching (if viewModel is already set)
    /// and when the viewModel property is assigned (if set after launch).
    private func registerServiceProvider() {
        guard let viewModel = viewModel, serviceProvider == nil else { return }
        serviceProvider = TokenPasteService(viewModel: viewModel)
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }

    // MARK: - Login Items

    /// Registers the app as a Login Item so it launches automatically at user login.
    ///
    /// Uses the modern `SMAppService` API (macOS 13+). Registration is best-effort:
    /// if it fails (e.g., the app is not code-signed or the user has disabled it
    /// in System Settings → General → Login Items), the app continues normally.
    ///
    /// **Manual setup alternative:**
    /// If programmatic registration does not work (unsigned development builds, etc.),
    /// the user can add VIPAccess.app manually:
    ///   1. Open System Settings → General → Login Items
    ///   2. Click "+" under "Open at Login"
    ///   3. Navigate to VIPAccess.app and add it
    ///
    /// The user can also remove the app from Login Items at any time via the same UI,
    /// which will prevent it from auto-launching regardless of this call.
    private func registerAsLoginItem() {
        let service = SMAppService.mainApp
        if service.status == .notRegistered {
            do {
                try service.register()
            } catch {
                // Registration is best-effort. Common failure reasons:
                // - App is not properly code-signed
                // - User has explicitly disabled the login item in System Settings
                // - Running from Xcode without an archive build
                print("[VIPAccess] Login item registration skipped: \(error.localizedDescription)")
            }
        }
    }
}
