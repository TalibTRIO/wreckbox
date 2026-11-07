import Foundation

/// A song in the results: the copy that plays, the same song from the other sources, whether it's a video upload.
struct Hit: Identifiable {
    var track: Track
    var alts: [Track] = []
    var video = false
    var id: String { track.key }
}

/// One search across the phone, YouTube Music and Spotify, with our own ranking. (Port of the Android Player's Search.)
///
///  - Candidates: the on-phone index (likes, playlists, history — instant, offline), YouTube Music (its own web API,
///    no key; also matches lyrics; gives the top result, artists, albums, playlists and its spelling fix), and Spotify
///    (joins with Spotify sign-in).
///  - Understanding: MusicBrainz says which artist the words mean, spelled right, with their other names; a fixed
///    spelling is searched too.
///  - Results arrive as each source answers (`stream`); the same song from several sources is one row that plays the
///    best copy (phone file first).
///  - Ranking (`score`): words matched (typo- and spelling-tolerant), the artist matching, the original over covers /
///    live / remixes / lyric videos unless asked, official songs over video uploads, and you — songs and artists you
///    play and like, and which result you picked last time you searched the same thing.
enum Search {
    struct Results {
        var query: String
        var top: Item?
        var hits: [Hit] = []
        var artists: [Item] = []
        var albums: [Item] = []
        var playlists: [Item] = []
        /// A spelling fix that was searched as well ("Showing results for …").
        var corrected: String?
        /// Services that couldn't be reached (offline, signed out, timed out).
        var failed: [String] = []
        var done = false
    }

    @MainActor
    private final class Gathering {
        let q: String
        var tracks: [(Track, Bool)] = []
        var top: Item?
        var artists: [Item] = [], albums: [Item] = [], playlists: [Item] = []
        var corrected: String?
        var mb: MusicBrainz.Artist?
        var failed: [String] = []
        var scoring: Scoring
        /// Where YouTube Music's own songs search put each song (its popularity order).
        var ytOrder: [String: Int] = [:]

        init(_ q: String) { self.q = q; scoring = Scoring(q, nil) }

        func add(_ r: YouTubeMusic.Results, fix: Bool) {
            if top == nil || fix { top = top ?? r.top }
            tracks += r.songs.map { ($0.track, $0.video) }
            artists += r.artists; albums += r.albums; playlists += r.playlists
            if fix, let c = r.corrected, norm(c) != norm(q) { corrected = c }
        }

        func results(done: Bool) -> Results {
            // Scores are worked out once per song; a new scoring only when the meaning changes (spelling fix, artist).
            if scoring.q != (corrected ?? q) || scoring.mb?.name != mb?.name { scoring = Scoring(corrected ?? q, mb) }
            func unique(_ l: [Item]) -> [Item] { var s = Set<String>(); return l.filter { s.insert($0.id).inserted } }
            return Results(query: q, top: top, hits: rank(scoring, tracks, ytOrder), artists: unique(artists), albums: unique(albums),
                           playlists: unique(playlists), corrected: corrected, failed: failed, done: done)
        }
    }

    /// The results so far, again each time a source answers; the last one has done = true.
    @MainActor
    static func stream(_ q: String) -> AsyncStream<Results> {
        AsyncStream { cont in
            let task = Task { @MainActor in
                let g = Gathering(q)
                let started = Date()
                var times: [String] = []
                func lap(_ name: String, _ ok: Bool) { times.append("\(name) \(Int(Date().timeIntervalSince(started) * 1000))ms\(ok ? "" : " (failed)")") }
                // Your own music: on the phone, instant.
                g.tracks = SearchIndex.search(q).map { ($0, false) }
                cont.yield(g.results(done: false))
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in
                        do { g.add(try await YtCache.shared.mixed(q), fix: true); lap("YouTube Music", true) } catch { g.failed.append("YouTube Music"); lap("YouTube Music", false) }
                        cont.yield(g.results(done: false))
                    }
                    // YouTube Music, songs only: more of them than the mixed list has.
                    group.addTask { @MainActor in
                        if let s = try? await YtCache.shared.songs(q) {
                            for (i, t) in s.enumerated() where g.ytOrder[t.key] == nil { g.ytOrder[t.key] = i }
                            g.tracks += s.map { ($0, false) }
                            cont.yield(g.results(done: false))
                        }
                        lap("YouTube songs", true)
                    }
                    // Spotify (signed in): its own search page, read by the hidden SpotifyPage.
                    if await Accounts.signedIn(.spotify) {
                        group.addTask { @MainActor in
                            do {
                                let found = try await withTimeout(15) { try await SpotifyPage.shared.search(q) }
                                g.tracks += found.map { ($0, false) }
                                lap("Spotify", true)
                            } catch { g.failed.append("Spotify"); lap("Spotify", false) }
                            cont.yield(g.results(done: false))
                        }
                    }
                    // MusicBrainz: the artist meant, with their other names; a misspelt artist is searched again spelled right.
                    group.addTask { @MainActor in
                        guard let a = await MusicBrainz.shared.artist(q) else { return lap("MusicBrainz", true) }
                        g.mb = a
                        let nq = norm(q)
                        if !a.names.contains(where: { $0 == nq || nq.contains($0) }), g.corrected == nil {
                            g.corrected = a.name
                            cont.yield(g.results(done: false))
                            if let more = try? await YtCache.shared.mixed(a.name) {
                                g.top = g.top ?? more.top
                                g.tracks += more.songs.map { ($0.track, $0.video) }
                                g.artists += more.artists; g.albums += more.albums
                            }
                        }
                        cont.yield(g.results(done: false))
                        lap("MusicBrainz", true)
                    }
                }
                cont.yield(g.results(done: true))
                Log.shared.write("search “\(q)”: \(times.joined(separator: ", "))")
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// YouTube Music searches, shared between search-while-typing and the full search, kept 10 minutes: typing starts
    /// them, Enter reuses them (often already answered). A failed one is forgotten so the next try asks again.
    actor YtCache {
        static let shared = YtCache()
        private var mixed: [String: (at: Date, task: Task<YouTubeMusic.Results, Error>)] = [:]
        private var songs: [String: (at: Date, task: Task<[Track], Error>)] = [:]

        func mixed(_ q: String) async throws -> YouTubeMusic.Results {
            let k = Search.norm(q)
            if let e = mixed[k], Date().timeIntervalSince(e.at) < 600 { if let r = try? await e.task.value { return r } }
            let t = Task { try await YouTubeMusic.search(q) }
            mixed[k] = (Date(), t)
            if mixed.count > 40, let old = mixed.min(by: { $0.value.at < $1.value.at })?.key { mixed[old] = nil }
            do { return try await t.value } catch { mixed[k] = nil; throw error }
        }

        func songs(_ q: String) async throws -> [Track] {
            let k = Search.norm(q)
            if let e = songs[k], Date().timeIntervalSince(e.at) < 600 { if let r = try? await e.task.value { return r } }
            let t = Task { try await Search.youtube(q) }
            songs[k] = (Date(), t)
            if songs.count > 40, let old = songs.min(by: { $0.value.at < $1.value.at })?.key { songs[old] = nil }
            do { return try await t.value } catch { songs[k] = nil; throw error }
        }
    }

    /// Words that mark something other than the original song — ranked down unless the search asks for them.
    private static let noise: [(String, NSRegularExpression)] = ["cover", "karaoke", "instrumental", "8 bit", "dance", "choreography", "tutorial",
        "reaction", "slowed", "reverb", "sped up", "nightcore", "originally performed", "tribute", "lesson", "piano version", "status", "live", "remix",
        "mashup", "lofi", "lo fi", "8d", "lyrics", "lyrical", "bass boosted", "extended", "unplugged", "acoustic", "whatsapp"]
        .map { ($0, try! NSRegularExpression(pattern: "\\b\($0)\\b")) }

    /// Merges the same song from several sources into one hit and puts the nearest first.
    @MainActor
    private static func rank(_ x: Scoring, _ list: [(Track, Bool)], _ ytOrder: [String: Int] = [:]) -> [Hit] {
        var order: [String] = []
        var groups: [String: [(Track, Bool)]] = [:]
        for (t, v) in list {
            let n = Radio.name(t)
            if groups[n] == nil { order.append(n); groups[n] = [] }
            if !groups[n]!.contains(where: { $0.0.key == t.key }) { groups[n]!.append((t, v)) }
        }
        let scored = order.enumerated().map { i, n -> (Hit, Double, Int) in
            let g = groups[n]!
            // The copy that plays: phone file, then the official YouTube Music song, then Spotify, then a video upload.
            func pref(_ e: (Track, Bool)) -> Int { e.0.source == .local ? 0 : e.0.source == .youtube && !e.1 ? 1 : e.0.source == .spotify ? 2 : 3 }
            let sorted = g.sorted { pref($0) < pref($1) }
            var main = sorted[0].0
            main.art = main.art ?? g.first { $0.0.art != nil }?.0.art
            main.album = main.album ?? g.first { $0.0.album != nil }?.0.album
            var best = g.map { e in x.memo["\(e.0.key)|\(e.1)"] ?? { let s = score(x, e.0, e.1); x.memo["\(e.0.key)|\(e.1)"] = s; return s }() }.max() ?? 0
            // YouTube's own top songs (what most people mean) get a little lift: up to 0.3 for its first, none past 10th.
            if let pos = g.compactMap({ ytOrder[$0.0.key] }).min(), pos < 10 { best += 0.3 * Double(10 - pos) / 10 }
            return (Hit(track: main, alts: sorted.dropFirst().map(\.0), video: sorted[0].1), best, i)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
    }

    /// For radio: plain tracks, nearest first (no personal ranking, no merging).
    @MainActor
    static func rank(_ q: String, _ list: [Track]) -> [Track] {
        let x = Scoring(q, nil, personal: false)
        return list.enumerated().map { ($0.element, score(x, $0.element, false), $0.offset) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
    }

    @MainActor
    private final class Scoring {
        let q: String
        let mb: MusicBrainz.Artist?
        var memo: [String: Double] = [:]
        let nq: String
        let words: [String]
        let personal: Bool
        let liked: Set<String>
        let clicks: [String: Int]
        /// The typed words that are the artist's name (or one of their other names).
        let artistWords: Set<String>

        init(_ q: String, _ mb: MusicBrainz.Artist?, personal: Bool = true) {
            self.q = q
            self.mb = mb
            self.personal = personal
            nq = norm(Fuzzy.devanagari(q))
            words = nq.split(separator: " ").map(String.init)
            liked = personal ? Set(Library.shared.data.likes.map(\.key)) : []
            clicks = personal ? Clicks.forQuery(q) : [:]
            let n = nq
            artistWords = Set(mb?.names.first { n.contains($0) }?.split(separator: " ").map(String.init) ?? [])
        }
    }

    @MainActor
    private static func score(_ x: Scoring, _ t: Track, _ video: Bool) -> Double {
        let title = norm(Fuzzy.devanagari(t.title))
        let artist = norm(Fuzzy.devanagari(t.artist))
        // The title's own words: "(From "Brahmastra")", "(feat. …)", "[Official Video]" aren't extra words of the song.
        let core = norm(Fuzzy.devanagari(t.title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)))
        let tw = (core.isEmpty ? title : core).split(separator: " ").map(String.init)
        let aw = artist.split(separator: " ").map(String.init)
        let alw = norm(t.album ?? "").split(separator: " ").map(String.init)
        var matched = 0.0
        var artistHit = false
        for (i, w) in x.words.enumerated() {
            let last = i == x.words.count - 1
            let inTitle = tw.map { Fuzzy.word(w, $0, last) }.max() ?? 0
            var inArtist = aw.map { Fuzzy.word(w, $0, last) }.max() ?? 0
            // A word of the artist's other name (MusicBrainz) counts as the artist when the track's artist is them.
            if inArtist == 0, x.artistWords.contains(w), let mb = x.mb, mb.names.contains(where: { artist.contains($0) }) { inArtist = 0.9 }
            let inAlbum = (alw.map { Fuzzy.word(w, $0, last) }.max() ?? 0) * 0.8
            if w.count > 2, inArtist >= 0.7, inArtist >= inTitle { artistHit = true }
            matched += max(inTitle, inArtist, inAlbum)
        }
        var s = matched / Double(max(1, x.words.count))
        if artistHit { s += 0.6 }
        if let mb = x.mb, mb.names.contains(where: { artist.contains($0) }) { s += 0.3 }
        if title == x.nq || core == x.nq || (x.words.allSatisfy { w in tw.contains { Fuzzy.word(w, $0, false) > 0 } } && tw.count <= x.words.count + 1) { s += 0.5 }
        s -= 0.4 * Double(tw.filter { w in !x.words.contains { w.contains($0) } }.count) / Double(max(1, tw.count))
        let all = "\(title) \(artist)"
        if noise.contains(where: { n, re in !x.nq.contains(n) && re.firstMatch(in: all, range: NSRange(all.startIndex..., in: all)) != nil }) { s -= 1 }
        if video && !t.artist.hasSuffix("VEVO") && !t.artist.hasSuffix(" - Topic") { s -= 0.3 }
        if t.source == .local { s += 0.2 }
        guard x.personal else { return s }
        // You: liked, played (and not skipped), your artists, and what you picked for this search before.
        if x.liked.contains(t.key) { s += 0.4 }
        let h = History.shared
        if let st = h.stat(t) { s += min(0.5, max(-0.4, st.score * 0.1)) }
        s += min(0.45, log(1 + max(0, h.artistScore(t.artist))) * 0.15)
        if let c = x.clicks[Radio.name(t)] { s += 0.8 * Double(min(c, 3)) }
        return s
    }

    static func norm(_ s: String) -> String {
        let folded = s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    // MARK: YouTube Music songs (also used by radio)

    private static let songsParams = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    private static let videosParams = "EgWKAQIQAWoMEA4QChADEAQQCRAF"

    static func youtube(_ q: String) async throws -> [Track] {
        async let s = ytQuery(q, songsParams)
        async let v = ytQuery(q, videosParams)
        let all = try await s + (try await v).prefix(5)
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    private static func ytQuery(_ q: String, _ params: String) async throws -> [Track] {
        let j = try await YouTubeMusic.call("search", ["query": q, "params": params])
        var out: [Track] = []
        YouTubeMusic.walk(j, "musicResponsiveListItemRenderer") { if let t = YouTubeMusic.listItem($0)?.track { out.append(t) } }
        return out
    }
}

/// Which result you played after searching something: picked again, it ranks first next time.
enum Clicks {
    private static var all: [String: [String: Int]] {
        get { UserDefaults.standard.dictionary(forKey: "searchClicks") as? [String: [String: Int]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "searchClicks") }
    }

    static func forQuery(_ q: String) -> [String: Int] { all[Search.norm(q)] ?? [:] }

    static func picked(_ q: String, _ t: Track) {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var a = all
        a[Search.norm(q), default: [:]][Radio.name(t), default: 0] += 1
        // Keep it small: 300 searches.
        if a.count > 300 { for k in a.keys.prefix(a.count - 300) { a[k] = nil } }
        all = a
    }
}

/// The searches you made, newest first (the empty Search page lists them).
enum RecentSearches {
    static var all: [String] { UserDefaults.standard.stringArray(forKey: "recentSearches") ?? [] }
    static func add(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        save([t] + all.filter { $0.caseInsensitiveCompare(t) != .orderedSame })
    }
    static func remove(_ q: String) { save(all.filter { $0 != q }) }
    static func clear() { save([]) }
    private static func save(_ l: [String]) { UserDefaults.standard.set(Array(l.prefix(20)), forKey: "recentSearches") }
}

/// Loose word matching: typos, Hindi in either script, the usual spelling variants of romanised Indian names.
enum Fuzzy {
    /// Damerau–Levenshtein distance, giving up (returning limit + 1) once it's over `limit`.
    static func distance(_ sa: String, _ sb: String, limit: Int = 3) -> Int {
        if sa == sb { return 0 }
        let a = Array(sa), b = Array(sb)
        if abs(a.count - b.count) > limit { return limit + 1 }
        let n = a.count, m = b.count
        var prev2 = [Int](repeating: 0, count: m + 1)
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        if n == 0 { return m }
        for i in 1...n {
            cur[0] = i
            var best = cur[0]
            if m > 0 {
                for j in 1...m {
                    let cost = a[i - 1] == b[j - 1] ? 0 : 1
                    var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                    if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { v = min(v, prev2[j - 2] + 1) }
                    cur[j] = v
                    best = min(best, v)
                }
            }
            if best > limit { return limit + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[m]
    }

    /// One spelling for the ways a name gets romanised: "Arijeet"/"Arijit", "Pyaar"/"Pyar", "Khwaab"/"Kwab".
    nonisolated(unsafe) private static var phonetics: [String: String] = [:]
    private static let lock = NSLock()

    static func phonetic(_ w: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let p = phonetics[w] { return p }
        if phonetics.count > 50_000 { phonetics.removeAll() }
        let p = computePhonetic(w)
        phonetics[w] = p
        return p
    }

    private static let replacements = [("ee", "i"), ("oo", "u"), ("aa", "a"), ("ii", "i"), ("uu", "u"), ("ph", "f"), ("kh", "k"), ("gh", "g"),
        ("th", "t"), ("dh", "d"), ("bh", "b"), ("jh", "j"), ("ch", "c"), ("sh", "s"), ("w", "v"), ("z", "j"), ("q", "k"), ("ck", "k"), ("y", "i")]

    private static func computePhonetic(_ w: String) -> String {
        var s = devanagari(w)
        for (a, b) in replacements { s = s.replacingOccurrences(of: a, with: b) }
        s = s.replacingOccurrences(of: #"(.)\1+"#, with: "$1", options: .regularExpression)
        if s.count > 3, s.hasSuffix("h") { s.removeLast() }
        if s.count > 3, s.hasSuffix("a") { s.removeLast() }
        return s
    }

    private static let consonants: [Character: String] = [
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n", "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
        "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n", "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
        "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m", "य": "y", "र": "r", "ल": "l", "व": "v", "श": "sh",
        "ष": "sh", "स": "s", "ह": "h",
    ]
    private static let vowels: [Character: String] = ["अ": "a", "आ": "aa", "इ": "i", "ई": "ee", "उ": "u", "ऊ": "oo", "ऋ": "ri", "ए": "e", "ऐ": "ai", "ओ": "o", "औ": "au"]
    private static let signs: [Character: String] = ["\u{093E}": "aa", "\u{093F}": "i", "\u{0940}": "ee", "\u{0941}": "u", "\u{0942}": "oo", "\u{0943}": "ri",
                                                    "\u{0947}": "e", "\u{0948}": "ai", "\u{094B}": "o", "\u{094C}": "au"]

    /// Hindi (Devanagari) → Latin letters, roughly as people type it: "अरिजीत सिंह" → "arijit sinh".
    static func devanagari(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) }) else { return s }
        // Work on single code points: NFD splits the nukta letters (क़ = क + ़), which then read as their base letter.
        let chars = s.decomposedStringWithCanonicalMapping.unicodeScalars.map { Character($0) }
        var out = ""
        var i = 0
        func at(_ k: Int) -> Character? { k < chars.count ? chars[k] : nil }
        while i < chars.count {
            let ch = chars[i]
            if consonants[ch] != nil, at(i + 1) == "\u{093C}" { i += 1 } // nukta: read as the base letter
            let next = at(i + 1)
            if let c = consonants[ch] {
                out += c
                if next == "\u{094D}" { i += 1 } // no vowel
                else if let n = next, let sgn = signs[n] { out += sgn; i += 1 }
                // The silent final "a" (schwa) of a word isn't typed: "सिंह" is "singh", not "singha".
                else if next == nil || next == " " || (next == "\u{0902}" && (at(i + 2) == nil || at(i + 2) == " ")) {}
                else { out += "a" }
            } else if let v = vowels[ch] { out += v }
            else if let sgn = signs[ch] { out += sgn }
            else if ch == "\u{0902}" || ch == "\u{0901}" { out += "n" }
            else if ch == "\u{0903}" { out += "h" }
            else if ch == "\u{093C}" || ch == "\u{094D}" {}
            else { out.append(ch) }
            i += 1
        }
        return out
    }

    /// How well one typed word matches a word of a title/artist: 1 exact, 0.9 the start of it (while typing), 0.85
    /// same spelling-variant, 0.7 within a typo or two, else 0.
    static func word(_ q: String, _ w: String, _ last: Bool) -> Double {
        if q == w { return 1 }
        if last, q.count >= 2, w.hasPrefix(q) { return 0.9 }
        if q.count >= 3, phonetic(q) == phonetic(w) { return 0.85 }
        if q.count >= 4 {
            let limit = q.count >= 8 ? 2 : 1
            if distance(q, w, limit: limit) <= limit { return 0.7 }
            if last, w.count > q.count, distance(q, String(w.prefix(q.count)), limit: 1) <= 1 { return 0.6 }
        }
        return 0
    }
}

/// The on-phone search index: everything you own or have touched — phone songs, likes, playlists, recently played
/// and your listening history — searched instantly and offline, with typo and spelling tolerance.
@MainActor
enum SearchIndex {
    private struct Entry { var track: Track; var title: [String]; var artist: [String]; var album: [String]; var mine: Double }
    private static var entries: [Entry] = []
    private static var signature = ""

    private static func words(_ s: String?) -> [String] { Search.norm(Fuzzy.devanagari(s ?? "")).split(separator: " ").map(String.init) }

    private static func ensure() {
        let lib = Library.shared.data
        let hist = History.shared.data
        let local = LocalFiles.tracks
        let sig = "\(local.count)|\(lib.likes.count)|\(lib.playlists.reduce(0) { $0 + $1.tracks.count })|\(lib.recent.first?.key ?? "")|\(hist.songs.count)"
        if sig == signature { return }
        let liked = Set(lib.likes.map(\.key))
        var order: [String] = []
        var all: [String: Track] = [:]
        // Phone songs first: when a song is known twice, the copy kept is the one on the phone.
        for t in local + lib.likes + lib.playlists.flatMap(\.tracks) + lib.recent + hist.songs.values.map(\.track) {
            let n = Radio.name(t)
            if all[n] == nil { all[n] = t; order.append(n) }
        }
        entries = order.map { n in
            let t = all[n]!
            let st = hist.songs[n]
            let mine = (liked.contains(t.key) ? 1.0 : 0) + (t.source == .local ? 0.4 : 0) + min(4, max(-1, st?.score ?? 0)) * 0.25
            return Entry(track: t, title: words(t.title), artist: words(t.artist), album: words(t.album), mine: mine)
        }
        signature = sig
    }

    /// Your songs matching `q`, best first: every typed word must match (one may miss when you typed 3+).
    static func search(_ q: String, max limit: Int = 40) -> [Track] {
        ensure()
        let qw = words(q)
        guard !qw.isEmpty else { return [] }
        let found = entries.compactMap { e -> (Track, Double)? in
            var total = 0.0, missed = 0, artistHit = false
            for (i, w) in qw.enumerated() {
                let last = i == qw.count - 1
                let t = e.title.map { Fuzzy.word(w, $0, last) }.max() ?? 0
                let a = e.artist.map { Fuzzy.word(w, $0, last) }.max() ?? 0
                let al = (e.album.map { Fuzzy.word(w, $0, last) }.max() ?? 0) * 0.8
                let best = max(t, a, al)
                if a >= 0.85, a >= t { artistHit = true }
                if best == 0 { missed += 1 } else { total += best }
            }
            if missed > (qw.count >= 3 ? 1 : 0) { return nil }
            let s = total / Double(qw.count) + (artistHit ? 0.15 : 0) + e.mine * 0.2 - Double(max(0, e.title.count - qw.count)) * 0.02
            return (e.track, s)
        }
        return Array(found.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
    }
}

/// MusicBrainz (the open music encyclopedia, no key): what artist a search means, spelled right, with the other names
/// they go by ("Arjit Singh" → Arijit Singh, "अरिजीत सिंह"). Answers are cached on the phone (mb.json); MusicBrainz
/// asks for at most one request a second and a User-Agent that says who's asking.
actor MusicBrainz {
    static let shared = MusicBrainz()

    struct Artist: Codable {
        var name: String
        var aliases: [String]
        /// Every name, normalised.
        var names: [String] {
            var seen = Set<String>()
            return ([name] + aliases).map(Search.norm).filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    private struct Cached: Codable { var artist: Artist?; var at: Date }

    private static let agent = "WreckBoxPlayer-iOS/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") ( https://github.com/moloyb301-eng/wreckbox )"
    private var lastCall = Date.distantPast
    private lazy var cache: [String: Cached] = AppDirs.load([String: Cached].self, "mb.json") ?? [:]

    /// The artist `q` most likely names (or starts with), or nil when MusicBrainz isn't sure. Only confident matches
    /// count: score 95+, and the name close to what was typed (so "tum hi ho" doesn't turn into some band).
    func artist(_ q: String) async -> Artist? {
        let key = Search.norm(q)
        guard key.count >= 3 else { return nil }
        if let c = cache[key], Date().timeIntervalSince(c.at) < 30 * 86_400 { return c.artist }
        guard let found = try? await fetch(key) else { return nil } // offline: ask again next time
        cache[key] = Cached(artist: found, at: Date())
        AppDirs.save(cache, "mb.json")
        return found
    }

    /// nil = asked, nothing confident (cached too); throws when MusicBrainz can't be reached.
    private func fetch(_ key: String) async throws -> Artist? {
        let wait = 1.1 - Date().timeIntervalSince(lastCall)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        lastCall = Date()
        var c = URLComponents(string: "https://musicbrainz.org/ws/2/artist")!
        c.queryItems = [.init(name: "fmt", value: "json"), .init(name: "limit", value: "5"), .init(name: "query", value: key)]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 8
        req.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: req)
        let artists = ((try JSONSerialization.jsonObject(with: data) as? JSON)?.objs("artists")) ?? []
        for a in artists {
            if (a["score"] as? Int ?? 0) < 95 { break }
            var seen = Set<String>()
            let aliases = a.objs("aliases").compactMap { $0.s("name") }.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(12)
            let art = Artist(name: a.s("name") ?? "", aliases: Array(aliases))
            // Close to what was typed: some name of theirs is within a couple of typos of the query (or of its start).
            if art.names.contains(where: { Self.close(key, $0) || (key.hasPrefix($0) && $0.count >= 4) }) { return art }
        }
        return nil
    }

    /// Within ~1 typo per 4 letters.
    static func close(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let limit = min(3, max(1, max(a.count, b.count) / 4))
        return abs(a.count - b.count) <= limit && Fuzzy.distance(a, b, limit: limit) <= limit
    }
}

/// Song radio, the way YouTube Music does it: every song has a radio mix ("RDAMVM" + its video id) that YouTube's
/// recommender fills with similar music — the same queue its own app plays after a song. No key, no account.
/// A Spotify or phone song is first found on YouTube Music to seed it; songs from the mix that are on the phone play
/// from the phone's copy.
enum Radio {
    @MainActor
    static func similar(to seed: Track, excluding exclude: Set<String>, max: Int = 25) async -> [Track] {
        let id: String
        if seed.source == .youtube { id = seed.id } else if let found = await findOnYouTube(seed) { id = found } else { return [] }
        let mix = ((try? await next(id)) ?? []).filter { $0.id != id }
        var local: [String: Track] = [:]
        for t in LocalFiles.tracks { local[name(t)] = t }
        var seen = exclude
        seen.insert(name(seed))
        var out: [Track] = []
        for t in mix {
            let n = name(t)
            if seen.contains(t.key) || seen.contains(n) { continue }
            seen.insert(n)
            out.append(local[n] ?? t)
            if out.count >= max { break }
        }
        return out
    }

    /// "title|first artist", normalised — the same song across sources.
    static func name(_ t: Track) -> String {
        let title = t.title.components(separatedBy: " (feat").first!.components(separatedBy: " - ").first!
        var artist = t.artist
        for sep in [",", "&", " x ", " feat"] { artist = artist.components(separatedBy: sep).first ?? artist }
        return Search.norm(title) + "|" + Search.norm(artist)
    }

    /// The YouTube Music song for a Spotify / phone track: the best-ranked search hit with the same name.
    @MainActor
    static func findOnYouTube(_ t: Track) async -> String? {
        let q = "\(t.title) \(t.artist)"
        let hits = (try? await Search.youtube(q)) ?? []
        return (hits.first { name($0) == name(t) } ?? Search.rank(q, hits).first)?.id
    }

    /// YouTube Music's "next" for the song's radio playlist: its up-next panel, ~50 songs.
    private static func next(_ videoId: String) async throws -> [Track] {
        let j = try await YouTubeMusic.call("next", ["videoId": videoId, "playlistId": "RDAMVM\(videoId)", "params": "wAEB", "isAudioOnly": true])
        var out: [Track] = []
        YouTubeMusic.walk(j, "playlistPanelVideoRenderer") { if let t = panelItem($0) { out.append(t) } }
        return out
    }

    /// One song of the panel: "Artist • Album • Year". Fan uploads ("… views" with no artist link) are skipped; a video
    /// by the artist's own channel stays (a mix seeded from a music video is all videos).
    private static func panelItem(_ r: JSON) -> Track? {
        guard let id = r.s("videoId"), !id.isEmpty, let title = r.o("title")?.objs("runs").first?.s("text") else { return nil }
        let runs = r.o("longBylineText")?.objs("runs") ?? []
        let official = runs.contains { ["MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL"].contains(YouTubeMusic.runPage($0) ?? "") }
        if runs.contains(where: { ($0.s("text") ?? "").hasSuffix(" views") }) && !official { return nil }
        var artists: [String] = [], album: String?
        for p in runs {
            switch YouTubeMusic.runPage(p) {
            case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL": artists.append(p.s("text") ?? "")
            case "MUSIC_PAGE_TYPE_ALBUM": album = p.s("text")
            default: break
            }
        }
        if artists.isEmpty, let a = runs.first?.s("text") { artists.append(a) }
        let length = r.o("lengthText")?.objs("runs").first?.s("text") ?? ""
        return Track(source: .youtube, id: id, title: title, artist: artists.joined(separator: ", "), album: album,
                     durationMs: YouTubeMusic.dur(length), art: YouTubeMusic.thumb(r.o("thumbnail")))
    }
}
