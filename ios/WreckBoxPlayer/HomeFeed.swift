import Foundation

/// Home's recommendations, built in the background and kept on the phone (home.json), so Home opens at once and
/// still has something offline (port of the Android Player's HomeFeed):
///  - feed: your YouTube Music home (signed in: Quick picks, Mixed for you, Listen again…)
///  - mixes: one per top artist (their songs you love + YouTube's radio from them), this hour's mix, a liked-songs mix
///  - because: songs like the one you played last
///  - fresh: new singles and albums from your artists (this year and last)
///  - rediscover: loved before, not played in a month; and phone songs you've never played
///  - charts, moods: for a new phone with no history yet (and browsing)
/// Rebuilt when it's 6 hours old (or Refresh); each part shows as soon as it's ready.
@MainActor
final class HomeFeed: ObservableObject {
    static let shared = HomeFeed()

    static let order = ["feed", "mixes", "because", "fresh", "rediscover", "charts", "moods"]

    private struct Saved: Codable { var at: Date; var parts: [String: [Shelf]] }

    @Published private(set) var parts: [String: [Shelf]] = [:]
    @Published private(set) var loading = false
    private var builtAt = Date.distantPast

    private init() {
        if let s = AppDirs.load(Saved.self, "home.json") { parts = s.parts; builtAt = s.at }
    }

    var shelves: [Shelf] { Self.order.flatMap { parts[$0] ?? [] } }

    private func put(_ key: String, _ shelves: [Shelf]) {
        parts[key] = shelves.filter { !$0.items.isEmpty }
        AppDirs.save(Saved(at: builtAt, parts: parts), "home.json")
    }

    func refresh(force: Bool = false) async {
        guard !loading, force || Date().timeIntervalSince(builtAt) > 6 * 3600 || parts.isEmpty else { return }
        loading = true
        defer { loading = false }
        await withTaskGroup(of: Void.self) { g in
            func part(_ key: String, _ f: @escaping @MainActor () async throws -> [Shelf]) {
                g.addTask { @MainActor in
                    do { self.put(key, try await f()) } catch { Log.shared.write("home \(key) failed: \(error.localizedDescription)") }
                }
            }
            part("feed") { try await Self.feed() }
            part("mixes") { await Self.mixes() }
            part("because") { await Self.because() }
            part("fresh") { await Self.fresh() }
            part("rediscover") { Self.rediscover() }
            part("charts") { try await YouTubeMusic.shelves("FEmusic_charts").prefix(3).map { var s = $0; s.title = "Charts · \(s.title)"; return s } }
            part("moods") { try await YouTubeMusic.shelves("FEmusic_moods_and_genres") }
        }
        builtAt = Date()
        AppDirs.save(Saved(at: builtAt, parts: parts), "home.json")
        Log.shared.write("home built: " + Self.order.map { k in "\(k)=\(parts[k]?.reduce(0) { $0 + $1.items.count } ?? 0)" }.joined(separator: ", "))
    }

    /// Your YouTube Music home (signed in = yours; otherwise its general one).
    private static func feed() async throws -> [Shelf] {
        let auth = await Accounts.youtubeSignedIn()
        return try await YouTubeMusic.shelves("FEmusic_home", auth: auth)
            .filter { s in s.items.contains { if case .mood = $0 { false } else { true } } }
            .map { var s = $0; s.items = s.items.filter { if case .mood = $0 { false } else { true } }; return s }
    }

    private static func mixes() async -> [Shelf] {
        let h = History.shared
        let lib = Library.shared.data
        var out: [Item] = []
        let tops = h.topArtists(6).filter { !$0.seed.id.isEmpty }
        var artistMixes: [Item] = []
        for (i, top) in tops.enumerated() {
            let key = History.artists(top.name).first
            let yours = Array(h.top(200).filter { History.artists($0.artist).first == key && !$0.id.isEmpty }.prefix(6))
            let radio = await Radio.similar(to: top.seed, excluding: Set(yours.map(\.key)), max: 24)
            let tracks = Array(interleave(yours, radio).prefix(30))
            if tracks.count >= 8 { artistMixes.append(.mix(id: "mix:artist:\(i)", title: "\(top.name) Mix", subtitle: "\(top.name) and music like it", tracks: tracks)) }
        }
        // This hour's songs: what you tend to play around now.
        let hour = h.forThisHour(12).filter { !$0.id.isEmpty }
        if hour.count >= 6 {
            let radio = await Radio.similar(to: hour[0], excluding: Set(hour.map(\.key)), max: 15)
            out.append(.mix(id: "mix:hour", title: "\(partOfDay()) mix", subtitle: "What you play around this time",
                            tracks: Array(interleave(hour.shuffled(), radio).prefix(30))))
        }
        if lib.likes.count >= 5 {
            var radio: [Track] = []
            for s in lib.likes.shuffled().prefix(3) { radio += await Radio.similar(to: s, excluding: Set(lib.likes.map(\.key)), max: 10) }
            var seen = Set<String>()
            radio = radio.filter { seen.insert(Radio.name($0)).inserted }
            out.append(.mix(id: "mix:liked", title: "Liked mix", subtitle: "Your liked songs and new ones like them",
                            tracks: Array(interleave(Array(lib.likes.shuffled().prefix(15)), radio).prefix(30))))
        }
        return [Shelf(title: "Your mixes", items: artistMixes + out, subtitle: "Made for you, refreshed daily")]
    }

    private static func interleave(_ a: [Track], _ b: [Track]) -> [Track] {
        var out: [Track] = []
        var seen = Set<String>()
        for i in 0..<max(a.count, b.count) {
            for t in [a[safe: i], b[safe: i * 2], b[safe: i * 2 + 1]].compactMap({ $0 }) where seen.insert(Radio.name(t)).inserted { out.append(t) }
        }
        return out
    }

    static func partOfDay() -> String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5...11: return "Morning"
        case 12...16: return "Afternoon"
        case 17...20: return "Evening"
        default: return "Late-night"
        }
    }

    private static func because() async -> [Shelf] {
        var seen = Set<String>()
        let seeds = (History.shared.recentPlays(3) + Library.shared.data.recent).filter { !$0.id.isEmpty && seen.insert(Radio.name($0)).inserted }.prefix(2)
        var out: [Shelf] = []
        for seed in seeds {
            let found = await Radio.similar(to: seed, excluding: [], max: 20)
            out.append(Shelf(title: "Because you played \(seed.title)", items: found.map { .song($0, subtitle: $0.artist, video: false) }, subtitle: seed.artist))
        }
        return out
    }

    /// New releases from your top artists: their singles/albums dated this year or last.
    private static func fresh() async -> [Shelf] {
        let year = Calendar.current.component(.year, from: Date())
        var ids = UserDefaults.standard.dictionary(forKey: "artistIds") as? [String: String] ?? [:]
        var found: [(Int, Item)] = []
        for (artist, _) in History.shared.topArtists(10) {
            let key = Search.norm(artist)
            var id = ids[key]
            if id == nil, let r = try? await YouTubeMusic.search(artist) {
                id = ([r.top].compactMap { $0 } + r.artists).first { if case .artist = $0 { Search.norm($0.title) == key } else { false } }?.id
                if let id { ids[key] = id }
            }
            guard let id, let page = try? await YouTubeMusic.artist(id) else { continue }
            let albums = page.shelves.filter { $0.title.contains("Single") || $0.title.contains("Album") || $0.title.contains("EP") }.flatMap(\.items)
            var n = 0
            for case .album(let aid, let title, let sub, let art, let by) in albums where n < 3 {
                // The release year: a 20xx in the subtitle that isn't in the future.
                let years = sub.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }.filter { (2000...year).contains($0) }
                guard let y = years.first, y >= year - 1 else { continue }
                let first = sub.components(separatedBy: " • ").first ?? sub
                found.append((y, .album(id: aid, title: title, subtitle: "\(first) · \(artist) · \(y)", art: art, artist: by.isEmpty ? artist : by)))
                n += 1
            }
        }
        UserDefaults.standard.set(ids, forKey: "artistIds")
        var seen = Set<String>()
        let items = found.sorted { $0.0 > $1.0 }.map(\.1).filter { seen.insert($0.id).inserted }
        return [Shelf(title: "New from your artists", items: Array(items.prefix(20)))]
    }

    private static func rediscover() -> [Shelf] {
        let h = History.shared
        let forgotten = h.forgotten().filter { !$0.id.isEmpty }
        // Phone songs you've never played here — a different handful each day.
        var rng = SeededRandom(seed: UInt64(Date().timeIntervalSince1970 / 86_400))
        let unplayed = Array(LocalFiles.tracks.filter { h.stat($0) == nil }.shuffled(using: &rng).prefix(20))
        return [
            Shelf(title: "Rediscover", items: forgotten.map { .song($0, subtitle: $0.artist, video: false) }, subtitle: "Loved before, not played lately"),
            Shelf(title: "On this phone, never played", items: unplayed.map { .song($0, subtitle: $0.artist, video: false) }),
        ]
    }
}

/// The same shuffle all day (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed &+= 0x9E3779B97F4A7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
