import AppKit

/// macOS Services provider that allows inserting the current VIP Access token
/// into any text field via the right-click "Services" menu.
class TokenPasteService: NSObject {
    private let viewModel: TokenViewModel

    init(viewModel: TokenViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    /// Called by the system when the user selects "Paste VIP Access Token" from
    /// the Services menu in any text field. Generates the current TOTP code and
    /// places it on the pasteboard for text replacement.
    ///
    /// - Parameters:
    ///   - pboard: The pasteboard to write the token to.
    ///   - userData: User data from the service declaration (unused).
    ///   - error: Error pointer for reporting failures back to the system.
    @MainActor @objc func pasteToken(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let code = viewModel.currentCode
        pboard.clearContents()
        pboard.setString(code, forType: .string)
    }
}
