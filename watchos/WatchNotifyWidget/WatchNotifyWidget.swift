import SwiftUI
import WidgetKit

struct WatchNotifyEntry: TimelineEntry {
    let date: Date
}

struct WatchNotifyProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchNotifyEntry {
        WatchNotifyEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchNotifyEntry) -> Void) {
        completion(WatchNotifyEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchNotifyEntry>) -> Void) {
        completion(Timeline(entries: [WatchNotifyEntry(date: .now)], policy: .never))
    }
}

private struct WatchNotifyCircularView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            if renderingMode == .fullColor {
                ZStack {
                    Circle()
                        .fill(Color(red: 26.0 / 255.0, green: 52.0 / 255.0, blue: 90.0 / 255.0))
                    bell
                        .foregroundStyle(.white)
                }
            } else {
                bell
                    .widgetAccentable()
            }
        }
        .accessibilityLabel("WatchNotify 알림")
    }

    private var bell: some View {
        Image(systemName: "bell.fill")
            .resizable()
            .scaledToFit()
            .padding(9)
    }
}

struct WatchNotifyCircularWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchNotify.circular.v1", provider: WatchNotifyProvider()) { _ in
            WatchNotifyCircularView()
            .containerBackground(for: .widget) {
                AccessoryWidgetBackground()
            }
        }
        .configurationDisplayName("WatchNotify 원형")
        .description("원형 알림 컴플리케이션")
        .supportedFamilies([.accessoryCircular])
    }
}

struct WatchNotifyCornerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchNotify.corner.v1", provider: WatchNotifyProvider()) { _ in
            Image(systemName: "bell.fill")
                .widgetLabel {
                    Text("알림")
                }
                .containerBackground(for: .widget) {}
                .accessibilityLabel("WatchNotify 알림")
        }
        .configurationDisplayName("WatchNotify 모서리")
        .description("모서리 알림 컴플리케이션")
        .supportedFamilies([.accessoryCorner])
    }
}

struct WatchNotifyRectangularWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchNotify.rectangular.v1", provider: WatchNotifyProvider()) { _ in
            VStack(alignment: .leading, spacing: 3) {
                Label("WatchNotify", systemImage: "bell.fill")
                    .font(.headline)
                    .widgetAccentable()
                Text("휴대폰 알림 수신")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .containerBackground(for: .widget) {}
        }
        .configurationDisplayName("WatchNotify 직사각형")
        .description("직사각형 알림 컴플리케이션")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct WatchNotifyInlineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchNotify.inline.v1", provider: WatchNotifyProvider()) { _ in
            Label("알림 수신", systemImage: "bell.fill")
                .containerBackground(for: .widget) {}
        }
        .configurationDisplayName("WatchNotify 인라인")
        .description("인라인 알림 컴플리케이션")
        .supportedFamilies([.accessoryInline])
    }
}
