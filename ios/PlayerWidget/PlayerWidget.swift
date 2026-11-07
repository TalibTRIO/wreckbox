import SwiftUI
import WidgetKit

// The extension holds only the now-playing Live Activity (PlayerLiveActivity.swift): lock screen + Dynamic Island.
// No home-screen widget in the first build — on the iPhone it froze on an old picture.

@main
struct PlayerWidgets: WidgetBundle {
    init() { WreckFonts.register() }
    var body: some Widget {
        PlayerLiveActivity()
    }
}
