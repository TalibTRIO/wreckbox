import SwiftUI
import UIKit

/// Keeps the Live Activity current and runs its buttons. (No home-screen widget in the first build.)
///  - Out: the player's state as WidgetSnapshot → LiveActivityBridge, and the cover as art.jpg in the App Group folder.
///    Only when something it shows changed (or the position jumped) — the activity runs its own clock.
///  - In: PlayerCommandIntent (the activity's buttons) → `run`.
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()
    private var pending = false
    private var lastSig = ""
    private var lastArt: String?
    /// The cover whose picture is in art.jpg now ("" none): the Live Activity's art key.
    private var artReady = ""
    private var lastSnap: WidgetSnapshot?
    private var lastLogged: String?
    private var lastPos: (pos: Double, at: Date, playing: Bool) = (0, .distantPast, false)

    /// Hooks the widgets' buttons up to the player (at app start).
    func start() {
        WidgetActions.run = { [weak self] c in self?.run(c) }

        if WidgetFiles.dir == nil { Log.shared.write("widgets: no App Group folder (the widgets can't see the player)") }
        LiveActivityBridge.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Self.removeOldFiles()
            self?.lastArt = "-"
            self?.lastSig = ""
            self?.write()
        }
    }

    /// Something changed: write soon (changes come in bursts).
    func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pending = false
            self?.write()
        }
    }

    private func write() {
        guard let dir = WidgetFiles.dir, let artURL = WidgetFiles.art else { return Log.shared.write("live activity: no App Group folder") }
        let p = Player.shared
        let t = p.current
        let eq = EQ.shared
        let upcoming = p.queue.enumerated().dropFirst(p.index + 1).prefix(5).map {
            WidgetSnapshot.Upcoming(number: $0.offset + 1, title: $0.element.title, artist: $0.element.artist)
        }
        let snap = WidgetSnapshot(
            title: t?.title, artist: t?.artist, source: t?.source.rawValue, quality: p.quality, playing: p.playing,
            position: p.position, duration: p.duration, at: Date(), track: t == nil ? "" : String(format: "%03d/%03d", p.index + 1, p.queue.count),
            shuffle: p.shuffle, repeatMode: p.repeatMode.rawValue, liked: t.map(Library.shared.isLiked) ?? false,
            eqOn: eq.on, eqPreset: eq.preset, eqGains: eq.gains, upcoming: Array(upcoming), hasArt: t?.art != nil)
        // The position only matters when it jumped (a seek) — otherwise the activity's clock runs by itself.
        let expected = lastPos.playing ? lastPos.pos + Date().timeIntervalSince(lastPos.at) : lastPos.pos
        let sig = [snap.title ?? "", snap.artist ?? "", snap.quality ?? "", "\(snap.playing)", "\(Int(snap.duration))", snap.track,
                   "\(snap.shuffle)", "\(snap.repeatMode)", "\(snap.liked)", "\(snap.eqOn)", snap.eqPreset, snap.eqGains.map { String($0) }.joined(separator: ","),
                   upcoming.map(\.title).joined(separator: "|")].joined(separator: "§")
        guard sig != lastSig || abs(snap.position - expected) > 2.5 else { return }
        lastSig = sig
        lastPos = (snap.position, Date(), snap.playing)
        lastSnap = snap

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if snap.title != lastLogged { lastLogged = snap.title; Log.shared.write("now \(snap.title ?? "-") (\(snap.playing ? "playing" : "paused"))") }
        if t?.art != lastArt {
            lastArt = t?.art
            let art = t?.art
            Task {
                // Only the Live Activity shows the cover, at 58 points at most: 128 pixels is plenty (and its
                // renderer has even less memory than the widgets').
                if let img = await Images.shared.load(art, size: 60), let small = Self.shrink(img, 128), let d = small.jpegData(compressionQuality: 0.8) {
                    try? d.write(to: artURL, options: .atomic)
                    self.artReady = art ?? ""
                } else {
                    try? FileManager.default.removeItem(at: artURL)
                    self.artReady = ""
                }
                if let s = self.lastSnap { LiveActivityBridge.shared.sync(s, art: self.artReady) }
            }
        }
        LiveActivityBridge.shared.sync(snap, art: artReady)
    }

    private static func shrink(_ img: UIImage, _ px: CGFloat) -> UIImage? {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: f).image { _ in img.draw(in: CGRect(x: 0, y: 0, width: px, height: px)) }
    }

    /// What the old home-screen widgets used (casing pictures, now.json, their log): gone.
    private static func removeOldFiles() {
        guard let dir = WidgetFiles.dir, let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files where f.hasPrefix("shell-") || ["record.png", "tile.png", "art-bg.jpg", "now.json", "widget.log"].contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    /// A Live Activity button.
    func run(_ c: WidgetCommand) {
        let p = Player.shared
        Log.shared.write("widget: \(c.rawValue)")
        switch c {
        case .toggle: p.toggle()
        case .next: p.next()
        case .previous: p.previous()
        case .like: if let t = p.current { Library.shared.toggleLike(t) }
        case .shuffle: p.setShuffle(!p.shuffle)
        case .repeatMode: p.cycleRepeat()
        case .back10: p.skip(-10)
        case .fwd10: p.skip(10)
        case .eqToggle: EQ.shared.setOn(!EQ.shared.on)
        }
        changed()
    }
}
