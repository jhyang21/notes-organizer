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
                onCancel: { [weak self] in self?.cancel() }
            )
        )

        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
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
