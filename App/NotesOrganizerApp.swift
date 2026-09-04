import NotesOrganizerKit
import SwiftUI
import WidgetKit

@main
struct NotesOrganizerApp: App {
    /// The plan every screen reads, and the one object allowed to change it.
    /// Both live for the whole process: RevenueCat wants the app user ID
    /// before it configures, and the paywall wants offerings ready before the
    /// user can reach Settings.
    @State private var plan: PlanModel
    @State private var purchases: PurchasesController

    @Environment(\.scenePhase) private var scenePhase

    /// The sweep is here for the opposite reason to the store: a recording
    /// left behind by a tidy nobody came back to should go before the user
    /// does anything else, and launch is the one moment we know no recording
    /// is in flight.
    ///
    /// The unit tests are hosted by this app, so a test run launches it for
    /// real. RevenueCat is skipped there — a test that reaches the network is
    /// not a test. Everything else stays: the plan reads shared storage and
    /// the sweep unlinks stale temporary files, and neither talks to anyone.
    init() {
        let plan = PlanModel()
        let purchases = PurchasesController(plan: plan)
        _plan = State(initialValue: plan)
        _purchases = State(initialValue: purchases)

        if !Self.isRunningTests {
            purchases.configure()
        }
        AudioRecorderService.sweepStaleRecordings()
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            CaptureScreen()
                .environment(plan)
                .environment(purchases)
                // A tidy spent in the share extension, or a subscription
                // bought on another iPhone, happens while this app is away.
                // Coming back is the moment to ask again — and the only
                // moment the answer is on screen.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        plan.refresh()
                    }
                }
                // Every link lands on this one screen, in this one scene,
                // because everything a link can ask for — recording, the
                // paywall — needs the two objects injected just above. A
                // second scene to catch URLs would be a screen without them.
                //
                // The router rather than the screen directly: an App Intent
                // has no view to talk to, and a cold launch's URL can arrive
                // before the screen exists. Both leave the request in the same
                // place, and the screen picks it up.
                .onOpenURL { url in
                    if let link = QuickCaptureLink.route(url, acceptedTokens: QuickCaptureToken.accepted()) {
                        QuickCaptureRouter.shared.request(link)
                    }
                }
                // Rotating here rather than in `init()` is the whole reason a
                // cold-start widget tap still records: a launch URL is
                // delivered while the scene connects, before this task runs,
                // so it is checked against the token the widget actually used.
                // The token the rotation retires stays valid for one more
                // launch anyway, so nothing rests on that ordering.
                //
                // Then the widget and the control are asked to redraw. They
                // build their URL from the token, so a tile still holding the
                // old one is a tap that only opens the app.
                .task {
                    QuickCaptureToken.rotate()
                    WidgetCenter.shared.reloadAllTimelines()
                    if #available(iOS 18, *) {
                        ControlCenter.shared.reloadAllControls()
                    }
                }
        }
    }
}
