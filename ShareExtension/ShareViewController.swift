import SwiftUI
import UIKit

/// Hosts the SwiftUI share flow and owns the two ways out of an extension:
/// `completeRequest` when the user is done, `cancelRequest` when they back
/// out. Both are safe to call more than once — the guard keeps a second tap
/// from reaching an already-finished context.
final class ShareViewController: UIViewController {
    private var hasFinished = false

    override func viewDidLoad() {
        super.viewDidLoad()

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let hosting = UIHostingController(
            rootView: ShareRootView(
                items: items,
                onDone: { [weak self] in self?.finish() },
                onCancel: { [weak self] in self?.cancel() },
                onOpenApp: { [weak self] url in
                    guard let self else { return false }
                    return await self.openApp(url)
                }
            )
        )

        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    /// Asks the host to open a `tidynote://` link, and says whether it did.
    ///
    /// Each extension point decides for itself whether `open` works, and the
    /// share sheet is the one Apple documents as free to refuse — expect
    /// `false`, and expect the screen to go back to telling the user where to
    /// go. The alternative doing the rounds, walking the responder chain to
    /// reach `UIApplication.open`, is private-API behaviour in all but name
    /// and not worth the review risk for a button.
    private func openApp(_ url: URL) async -> Bool {
        guard let extensionContext else { return false }
        return await withCheckedContinuation { continuation in
            extensionContext.open(url) { opened in
                continuation.resume(returning: opened)
            }
        }
    }

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        extensionContext?.cancelRequest(
            withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        )
    }
}
