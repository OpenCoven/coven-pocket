import SafariServices
import SwiftUI

/// In-app browser for OAuth flows.
///
/// `ASWebAuthenticationSession` cannot complete against a localhost redirect,
/// so the Codex flow presents plain Safari UI; the redirect resolves to the
/// engine's in-app callback listener and the sheet is dismissed by state.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .cancel
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
