import AppIntents
import CoreText
import Foundation
import WidgetKit

/// The player's state as the Live Activity needs it, built by the app whenever the player changes (WidgetBridge).
struct WidgetSnapshot: Codable, Equatable {
    struct Upcoming: Codable, Equatable {
        var number: Int
        var title: String
        var artist: String
    }

    var title: String?
    var artist: String?
    var source: String?          // "LOCAL", "YOUTUBE", "SPOTIFY"
    var quality: String?         // "FLAC · 24/96 · 2,612 kbps"
    var playing = false
    var position: Double = 0     // seconds, at `at`
    var duration: Double = 0
    var at = Date()
    var track = ""               // "3/24"
    var shuffle = false
    var repeatMode = 0           // 0 off, 1 all, 2 one
    var liked = false
    var eqOn = true
    var eqPreset = "Flat"
    var eqGains: [Float] = Array(repeating: 0, count: 10)
    var upcoming: [Upcoming] = []
    var hasArt = false

    /// "FLAC 24/96", "MP3 320", "AAC 130": the LCD's short format badge.
    var format: String {
        guard let p = quality?.components(separatedBy: " · "), let first = p.first else { return "" }
        guard p.count >= 2 else { return first }
        let second = p[1].replacingOccurrences(of: "~", with: "").replacingOccurrences(of: " kbps", with: "").replacingOccurrences(of: ",", with: "")
        return "\(first) \(second)"
    }

    /// The source as the LCD badge says it.
    var sourceBadge: String {
        switch source { case "LOCAL": return "PHONE"; case "YOUTUBE": return "YTM"; case "SPOTIFY": return "SPOT"; default: return "" }
    }
}

enum WidgetFiles {
    static let group = "group.com.talibahmed.wreckbox.shared"
    static var dir: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var art: URL? { dir?.appendingPathComponent("art.jpg") }
    static var shared: UserDefaults? { UserDefaults(suiteName: group) }
}

/// Urbanist and Doto, from whichever bundle runs this (the app or the Live Activity extension).
enum WreckFonts {
    nonisolated(unsafe) private static var done = false
    static func register() {
        guard !done, let dir = Bundle.main.resourceURL else { return }
        done = true
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            + ((try? fm.contentsOfDirectory(at: dir.appendingPathComponent("Fonts"), includingPropertiesForKeys: nil)) ?? [])
        for f in files where f.pathExtension.lowercased() == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
    }
}

// MARK: - The Live Activity's buttons

/// What a widget button asks for.
enum WidgetCommand: String, AppEnum {
    case toggle, next, previous, like, shuffle, repeatMode, back10, fwd10, eqToggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Player command"
    static let caseDisplayRepresentations: [WidgetCommand: DisplayRepresentation] = [
        .toggle: "Play / pause", .next: "Next", .previous: "Previous", .like: "Like", .shuffle: "Shuffle", .repeatMode: "Repeat",
        .back10: "Back 10 seconds", .fwd10: "Forward 10 seconds", .eqToggle: "Equaliser on / off",
    ]
}

/// Set by the app when it starts: runs a command on the player. (The widget extension compiles this too, but iOS
/// runs audio intents in the app's own process, so there it's never called.)
@MainActor
enum WidgetActions {
    static var run: ((WidgetCommand) -> Void)?
}

/// A Live Activity button. An audio-playback intent: iOS runs it inside the app (starting the app in the background if it
/// isn't running), so the press acts at once without opening the app.
struct PlayerCommandIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "WreckBox Player"
    static let isDiscoverable = false

    @Parameter(title: "Command") var command: WidgetCommand

    init() {}
    init(_ command: WidgetCommand) { self.command = command }

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetActions.run?(command)
        return .result()
    }
}
