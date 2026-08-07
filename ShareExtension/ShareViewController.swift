import UIKit
import SwiftUI

/// M0 placeholder. The real flow (load `public.plain-text` from the
/// extension item, organize in-process, preview, save) lands in M6.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let hosting = UIHostingController(
            rootView: ShareRootView(onDone: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            })
        )

        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }
}

private struct ShareRootView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Shared text will appear here")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding()

            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
