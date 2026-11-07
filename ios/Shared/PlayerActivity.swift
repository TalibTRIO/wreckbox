import ActivityKit
import Foundation

/// The Live Activity: now playing on the lock screen and in the Dynamic Island (iPhone Pro models), started by the
/// app (LiveActivityBridge) and drawn by the widget extension (PlayerLiveActivity). The state is the widgets'
/// snapshot cut down to what it shows; ActivityKit allows 4 KB, so the cover comes from the App Group (art.jpg).
struct PlayerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var sourceBadge: String      // "YTM", "PHONE", "SPOT"
        var format: String           // "FLAC 24/96"
        var playing: Bool
        var position: Double         // seconds, at `at`
        var duration: Double
        var at: Date
        var liked: Bool
        /// Changes when art.jpg does, so the views pick up the new cover.
        var art: String

        var start: Date { at.addingTimeInterval(-position) }
        var end: Date { start.addingTimeInterval(max(duration, position + 1)) }
    }
}

extension PlayerActivityAttributes.ContentState {
    init?(_ s: WidgetSnapshot, art: String) {
        guard let title = s.title else { return nil }
        self.init(title: title, artist: s.artist ?? "", sourceBadge: s.sourceBadge, format: s.format, playing: s.playing,
                  position: s.position, duration: s.duration, at: s.at, liked: s.liked, art: art)
    }
}
