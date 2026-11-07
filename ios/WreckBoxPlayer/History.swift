import Foundation

/// What you listen to, kept on this phone only (history.json): per song, how often you played it, how often you
/// skipped it, when you last played it and at what hours; plus weight from imports (your YouTube Music and Spotify
/// history, likes and top lists). Search ranking and Home's recommendations read it.
///
/// Songs are counted by name ("title|artist", Radio.name), so the same song played from the phone, YouTube or Spotify
/// is one song; the `track` kept is the most playable copy seen (phone > YouTube > Spotify). (Port of the Android
/// Player's History.)
@MainActor
final class History: ObservableObject {
    static let shared = History()

    struct Stat: Codable {
        var track: Track
        var plays = 0
        var skips = 0
        var firstAt: Double = 0
        var lastAt: Double = 0
        var listenedMs: Int64 = 0
        /// Plays per hour of the day (0–23).
        var hours = [Int](repeating: 0, count: 24)
        /// Extra weight from imports: liked elsewhere, in a top-songs list.
        var boost = 0.0

        /// How much you like it: plays (diminishing), minus skips, plus import weight.
        var score: Double { log(1.0 + Double(plays)) * 2 - Double(skips) * 0.6 + boost }
    }

    struct Data: Codable {
        var songs: [String: Stat] = [:]
        var artists: [String: Double] = [:]
        var recent: [String] = []
        var imported: [String: Double] = [:]
        /// Per export source, the time spans its imported files covered ([from, to]; optional: older files lack it).
        var covered: [String: [[Double]]]?
    }

    @Published private(set) var data = Data()

    private init() {
        if let d = AppDirs.load(Data.self, "history.json") { data = d }
    }

    var plays: Int { data.songs.values.reduce(0) { $0 + $1.plays } }

    /// A song stopped (finished, skipped or replaced): a play when at least half (or 4 minutes) was heard, a skip
    /// when it was cut off in the first 30 seconds of a longer song; in between it's neither.
    func record(_ t: Track, listenedMs: Int64, durMs: Int64, at: Date = Date()) {
        let played = listenedMs >= min(240_000, (durMs > 0 ? durMs : 180_000) / 2)
        let skipped = !played && listenedMs < 30_000 && (durMs == 0 || durMs > 60_000)
        guard played || skipped else { return }
        let ts = at.timeIntervalSince1970
        update { d in
            let n = Self.name(t)
            var s = d.songs[n] ?? Stat(track: t, firstAt: ts)
            if played { s.hours[Self.hour(ts)] += 1 }
            s.track = Self.better(s.track, t)
            s.plays += played ? 1 : 0
            s.skips += skipped ? 1 : 0
            s.lastAt = max(s.lastAt, ts)
            s.listenedMs += listenedMs
            d.songs[n] = s
            if played { d.recent = Array(([n] + d.recent.filter { $0 != n }).prefix(200)) }
            for a in Self.artists(t.artist) { d.artists[a, default: 0] += played ? 1 : -0.3 }
        }
    }

    struct Play { var track: Track; var at: Double; var listenedMs: Int64 = 0 }

    /// Imported plays; a source can be imported again without counting the same plays twice (`covered` remembers the
    /// time spans imported files held, so files can come in any order: a year's file after the newer ones, the full
    /// history after the short one). `onlyNew: false` takes every play (the caller has picked the new ones).
    @discardableResult
    func importPlays(_ source: String, _ plays: [Play], onlyNew: Bool = true) -> Int {
        // Imported before spans were kept: everything up to the old mark counts as covered.
        let spans = data.covered?[source] ?? data.imported[source].map { [[0, $0]] } ?? []
        let fresh = onlyNew ? plays.filter { p in !spans.contains { $0[0] <= p.at && p.at <= $0[1] } } : plays
        if onlyNew, let lo = plays.map(\.at).min(), let hi = plays.map(\.at).max() {
            update { $0.covered = ($0.covered ?? [:]).merging([source: Self.merge(spans + [[lo, hi]])]) { $1 } }
        }
        guard !fresh.isEmpty else { return 0 }
        update { d in
            for p in fresh {
                let n = Self.name(p.track)
                var s = d.songs[n] ?? Stat(track: p.track, firstAt: p.at)
                s.hours[Self.hour(p.at)] += 1
                s.track = Self.better(s.track, p.track)
                s.plays += 1
                s.firstAt = min(s.firstAt > 0 ? s.firstAt : p.at, p.at)
                s.lastAt = max(s.lastAt, p.at)
                s.listenedMs += p.listenedMs
                d.songs[n] = s
                for a in Self.artists(p.track.artist) { d.artists[a, default: 0] += 1 }
            }
            if d.recent.isEmpty {
                var seen = Set<String>()
                d.recent = Array(fresh.sorted { $0.at > $1.at }.map { Self.name($0.track) }.filter { seen.insert($0).inserted }.prefix(200))
            }
            d.imported[source] = max(d.imported[source] ?? 0, fresh.map(\.at).max() ?? 0)
        }
        return fresh.count
    }

    /// Overlapping spans joined into one.
    private static func merge(_ spans: [[Double]]) -> [[Double]] {
        var out: [[Double]] = []
        for s in spans.filter({ $0.count == 2 }).sorted(by: { $0[0] < $1[0] }) {
            if let last = out.last, s[0] <= last[1] { out[out.count - 1][1] = max(last[1], s[1]) } else { out.append(s) }
        }
        return out
    }

    /// Songs with weight but no plays to count (liked on a service, in a top list): `weight` each.
    func importFavourites(_ source: String, _ tracks: [Track], weight: Double) {
        guard !tracks.isEmpty else { return }
        update { d in
            for t in tracks {
                let n = Self.name(t)
                var s = d.songs[n] ?? Stat(track: t)
                s.track = Self.better(s.track, t)
                s.boost = max(s.boost, weight)
                d.songs[n] = s
                for a in Self.artists(t.artist) { d.artists[a, default: 0] += weight * 0.5 }
            }
            d.imported[source] = Date().timeIntervalSince1970
        }
    }

    /// Artists from a service's "top artists" list: the first counts most.
    func importArtists(_ source: String, _ names: [String]) {
        update { d in
            for (i, a) in names.enumerated() {
                let k = Search.norm(a)
                if !k.isEmpty { d.artists[k, default: 0] += Double(names.count - i) * 0.5 }
            }
            d.imported[source] = Date().timeIntervalSince1970
        }
    }

    func clear() { update { $0 = Data() } }

    // MARK: reading

    func stat(_ t: Track) -> Stat? { data.songs[Self.name(t)] }

    /// How much you like this artist (0 = never heard), by any of the track's artists.
    func artistScore(_ artist: String) -> Double { Self.artists(artist).map { data.artists[$0] ?? 0 }.max() ?? 0 }

    /// Your top artists, best first, with a representative song each (the one you play most).
    func topArtists(_ n: Int) -> [(name: String, seed: Track)] {
        let bySong = Dictionary(grouping: data.songs.values.filter { $0.score > 0 }) { Self.artists($0.track.artist).first ?? "" }
        return data.artists.filter { $0.value > 0 && !$0.key.isEmpty }.sorted { $0.value > $1.value }.compactMap { a, _ -> (String, Track)? in
            guard let s = bySong[a]?.max(by: { $0.score < $1.score }) else { return nil }
            let display = Self.split(s.track.artist).first?.trimmingCharacters(in: .whitespaces) ?? s.track.artist
            return (display, s.track)
        }.prefix(n).map { $0 }
    }

    /// The most recent songs you played through (not skips), newest first.
    func recentPlays(_ n: Int) -> [Track] {
        Array(data.recent.compactMap { k in data.songs[k].flatMap { $0.plays > $0.skips ? $0.track : nil } }.prefix(n))
    }

    /// Loved before, not played lately: played 3+ times, last over `days` days ago.
    func forgotten(days: Double = 30, _ n: Int = 20) -> [Track] {
        let cut = Date().timeIntervalSince1970 - days * 86_400
        return Array(data.songs.values.filter { $0.plays >= 3 && $0.lastAt > 0 && $0.lastAt < cut && $0.plays > $0.skips * 2 }
            .sorted { $0.score > $1.score }.map(\.track).prefix(n))
    }

    /// Songs you tend to play at this hour of the day (± 1 hour).
    func forThisHour(_ n: Int = 25) -> [Track] {
        let h = Self.hour(Date().timeIntervalSince1970)
        return Array(data.songs.values.map { s in (s, s.hours[(h + 23) % 24] + s.hours[h] * 2 + s.hours[(h + 1) % 24]) }
            .filter { $0.1 >= 2 }.sorted { $0.1 > $1.1 }.map(\.0.track).prefix(n))
    }

    /// Your most-played songs.
    func top(_ n: Int) -> [Track] { Array(data.songs.values.filter { $0.score > 0.5 }.sorted { $0.score > $1.score }.map(\.track).prefix(n)) }

    // MARK: storage

    private var saveTask: Task<Void, Never>?

    private func update(_ f: (inout Data) -> Void) {
        var d = data
        f(&d)
        data = d
        // Imports change thousands of songs at once: written once things settle.
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            AppDirs.save(self.data, "history.json")
        }
    }

    static func name(_ t: Track) -> String { Radio.name(t) }

    private static func split(_ artist: String) -> [String] {
        var parts = [artist.hasSuffix(" - Topic") ? String(artist.dropLast(8)) : artist]
        for sep in [",", "&", " x ", " X ", " feat.", " feat", " ft.", " and ", " with "] { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        return parts
    }

    /// "Ritviz & Nucleya" → ["ritviz", "nucleya"], normalised.
    static func artists(_ artist: String) -> [String] { split(artist).map(Search.norm).filter { !$0.isEmpty } }

    private static func hour(_ ts: Double) -> Int { Calendar.current.component(.hour, from: Date(timeIntervalSince1970: ts)) }

    /// The copy to keep: a phone file plays best, then YouTube (starts fastest), then Spotify.
    private static func better(_ a: Track, _ b: Track) -> Track {
        // (A song from Spotify's short export has no id: it can't play, so any other copy wins.)
        func rank(_ t: Track) -> Int { t.id.isEmpty ? 9 : t.source == .local ? 0 : t.source == .youtube ? 1 : 2 }
        if rank(b) < rank(a) { var x = b; x.art = b.art ?? a.art; return x }
        var x = a
        x.art = a.art ?? b.art
        // A fresh read of the same song corrects its length.
        if a.source == b.source && a.id == b.id && b.durationMs > 0 { x.durationMs = b.durationMs }
        return x
    }
}
