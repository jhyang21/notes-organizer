import NotesOrganizerKit
import SwiftUI
import WidgetKit

/// One tap from the Lock Screen or the Home Screen to a running recording.
///
/// It deep-links rather than doing anything itself, and that is the whole
/// design: a microphone needs the app in front of the user, so the honest
/// widget is a shortcut to the app, not a pretend record button that would
/// leave people talking at a Lock Screen.
struct QuickTidyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickTidyWidget", provider: QuickTidyProvider()) { _ in
            QuickTidyWidgetView()
                .widgetURL(QuickCaptureLink.record.url)
        }
        .configurationDisplayName("Start a Tidy")
        .description("Opens TidyNote and starts recording.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .systemSmall])
    }
}

/// Nothing here changes on its own, so there is one entry and no reason to ask
/// for another. The date is what `TimelineEntry` requires, not something the
/// widget reads.
struct QuickTidyEntry: TimelineEntry {
    let date: Date
}

struct QuickTidyProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickTidyEntry {
        QuickTidyEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickTidyEntry) -> Void) {
        completion(QuickTidyEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickTidyEntry>) -> Void) {
        completion(Timeline(entries: [QuickTidyEntry(date: .now)], policy: .never))
    }
}

struct QuickTidyWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            // The whole widget is one tap target, so it reads as one thing.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Start a Tidy"))
            .accessibilityHint(Text("Opens TidyNote and starts recording."))
            .containerBackground(for: .widget) {
                // Only the Home Screen tile paints a background. The Lock
                // Screen has its own material behind it, and a second one
                // under that is a grey box on a photo.
                if family == .systemSmall {
                    Color.accentColor.opacity(0.12)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title2)
            }

        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                Text("Start a Tidy")
                    .font(.headline)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        default:
            VStack(spacing: 8) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text("Start a Tidy")
                    .font(.headline)
                    // Long words at the largest text sizes shrink rather than
                    // truncate: a widget has no room to scroll.
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
