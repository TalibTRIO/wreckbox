import SwiftUI

@main
struct WreckBoxPlayerApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        WreckFonts.register()
        WidgetBridge.shared.start()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .onChange(of: phase) { _, p in Log.shared.write("app: \(p)") }
    }
}
