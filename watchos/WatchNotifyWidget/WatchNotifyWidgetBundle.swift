import WidgetKit
import SwiftUI

@main
struct WatchNotifyWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchNotifyCircularWidget()
        WatchNotifyCornerWidget()
        WatchNotifyRectangularWidget()
        WatchNotifyInlineWidget()
    }
}
