// WatchNotifyWidget.swift
// 내장 SF Symbol 사용으로 에셋 인덱싱 오류 및 느낌표 현상 완벽 방지

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct WatchNotifyEntry: TimelineEntry {
    let date: Date
}

// MARK: - Timeline Provider

struct WatchNotifyProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchNotifyEntry {
        WatchNotifyEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchNotifyEntry) -> Void) {
        completion(WatchNotifyEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchNotifyEntry>) -> Void) {
        let entry = WatchNotifyEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

// MARK: - Widget View

struct WatchNotifyWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var entry: WatchNotifyEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                
                Image(systemName: "bell.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            }

        #if os(watchOS)
        case .accessoryCorner:
            Image(systemName: "bell.fill")
                .font(.system(size: 16))
                .widgetLabel {
                    Text("알림")
                }
        #endif

        case .accessoryRectangular:
            HStack(spacing: 4) {
                Image(systemName: "bell.fill")
                    .widgetAccentable()

                Text("알림")
                    .font(.caption)
            }

        default:
            Image(systemName: "bell.fill")
                .resizable()
                .scaledToFit()
        }
    }
}

// MARK: - Widget Configuration

struct WatchNotifyWidget: Widget {
    let kind = "WatchNotifyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchNotifyProvider()) { entry in
            WatchNotifyWidgetView(entry: entry)
        }
        .configurationDisplayName("WatchNotify")
        .description("알림 상태 확인")
        .supportedFamilies({
            var families: [WidgetFamily] = [.accessoryCircular, .accessoryRectangular]
            #if os(watchOS)
            families.append(.accessoryCorner)
            #endif
            return families
        }())
    }
}
