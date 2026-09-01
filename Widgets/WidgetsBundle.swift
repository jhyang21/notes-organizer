import SwiftUI
import WidgetKit

/// Everything TidyNote puts outside the app: one widget for the Lock Screen
/// and the Home Screen, and one Control Center control.
@main
struct WidgetsBundle: WidgetBundle {
    var body: some Widget {
        QuickTidyWidget()
        // Controls are iOS 18. TidyNote runs on 17, and one control is not a
        // reason to stop: it is compiled behind availability instead, and an
        // iPhone on 17 simply never sees it offered.
        if #available(iOS 18.0, *) {
            TidyControl()
        }
    }
}
