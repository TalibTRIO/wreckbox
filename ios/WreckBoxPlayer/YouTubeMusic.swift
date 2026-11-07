import CryptoKit
import Foundation
import WebKit

typealias JSON = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func o(_ k: String) -> JSON? { self[k] as? JSON }
    func a(_ k: String) -> [Any]? { self[k] as? [Any] }
    func s(_ k: String) -> String? { self[k] as? String }
    /// The objects of an array value.
    func objs(_ k: String) -> [JSON] { (self[k] as? [Any] ?? []).compactMap { $0 as? JSON } }
}

/// Something YouTube Music lists: a song, or a page to open (album, playlist, artist).
enum Item: Codable, Hashable, Identifiable {
    case song(Track, subtitle: String, video: Bool)
    case album(id: String, title: String, subtitle: String, art: String?, artist: String)
    case playlist(id: String, title: String, subtitle: String, art: String?)
    case artist(id: String, title: String, subtitle: String, art: String?)
    /// A mood / genre button (opens a browse page with params).
    case mood(id: String, params: String, title: String, color: Int64)
    /// One of our mixes (Home): its songs are right here.
    case mix(id: String, title: String, subtitle: String, tracks: [Track])

    var id: String {
        switch self {
        case .song(let t, _, _): return t.key
        case .album(let id, _, _, _, _), .playlist(let id, _, _, _), .artist(let id, _, _, _), .mix(let id, _, _, _): return id
        case .mood(let id, let params, _, _): return id + params
        }
    }

    var title: String {
        switch self {
        case .song(let t, _, _): return t.title
        case .album(_, let t, _, _, _), .playlist(_, let t, _, _), .artist(_, let t, _, _), .mood(_, _, let t, _), .mix(_, let t, _, _): return t
        }
    }

    var subtitle: String {
        switch self {
        case .song(_, let s, _), .album(_, _, let s, _, _), .playlist(_, _, let s, _), .artist(_, _, let s, _), .mix(_, _, let s, _): return s
        case .mood: return ""
        }
    }

    var art: String? {
        switch self {
        case .song(let t, _, _): return t.art
        case .album(_, _, _, let a, _), .playlist(_, _, _, let a), .artist(_, _, _, let a): return a
        case .mood: return nil
        case .mix(_, _, _, let tracks): return tracks.first { $0.art != nil }?.art
        }
    }

    var track: Track? { if case .song(let t, _, _) = self { return t } else { return nil } }
}

/// A titled row of items (a YouTube Music shelf, or one of ours).
struct Shelf: Codable, Hashable, Identifiable {
    var title: String
    var items: [Item]
    var subtitle = ""
    var id: String { title + subtitle }
}

/// YouTube Music's own web API (the one music.youtube.com uses; no key). Signed-in calls (your home feed, your
/// history) send the session cookies from signing in, with the same SAPISIDHASH header the website sends.
/// (A port of the Android Player's YouTubeMusic.)
enum YouTubeMusic {
    static let origin = "https://music.youtube.com"

    private static func country() -> String {
        let r = Locale.current.region?.identifier ?? "US"
        return r.count == 2 ? r : "US"
    }

    static func call(_ endpoint: String, _ body: JSON, auth: Bool = false) async throws -> JSON {
        var payload = body
        payload["context"] = ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20251001.01.00", "hl": "en", "gl": country()]]
        var req = URLRequest(url: URL(string: "\(origin)/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(origin, forHTTPHeaderField: "X-Origin")
        req.setValue(WebEngine.userAgent, forHTTPHeaderField: "User-Agent")
        if auth, let (cookie, sapisid) = await Accounts.youtubeCookies() {
            let ts = Int(Date().timeIntervalSince1970)
            let hash = Insecure.SHA1.hash(data: Data("\(ts) \(sapisid) \(origin)".utf8)).map { String(format: "%02x", $0) }.joined()
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue("SAPISIDHASH \(ts)_\(hash)", forHTTPHeaderField: "Authorization")
            req.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let j = try JSONSerialization.jsonObject(with: data) as? JSON else {
            throw URLError(.badServerResponse)
        }
        return j
    }

    // MARK: search

    struct Results {
        var top: Item?
        var songs: [(track: Track, video: Bool)]
        var artists: [Item]
        var albums: [Item]
        var playlists: [Item]
        /// "Showing results for …": YouTube's own spelling fix.
        var corrected: String?
    }

    /// The unfiltered search: the top result and a mix of songs, videos, artists, albums and playlists.
    static func search(_ q: String) async throws -> Results {
        let j = try await call("search", ["query": q])
        var top: Item?
        walk(j, "musicCardShelfRenderer") { card in
            guard let run = card.o("title")?.objs("runs").first else { return }
            let sub = text(card.o("subtitle"))
            let art = thumb(card.o("thumbnail"))
            let nav = run.o("navigationEndpoint")
            if let nav, let b = browseItem(nav, run.s("text") ?? "", sub, art) { top = b; return }
            if let id = nav?.o("watchEndpoint")?.s("videoId"), !id.isEmpty {
                let parts = sub.components(separatedBy: " • ")
                top = .song(Track(source: .youtube, id: id, title: run.s("text") ?? "", artist: parts[safe: 1] ?? "", album: parts[safe: 2],
                                  durationMs: dur(parts.last), art: art), subtitle: sub, video: parts.first == "Video")
            }
        }
        var items: [Item] = []
        walk(j, "musicResponsiveListItemRenderer") { if let i = listItem($0) { items.append(i) } }
        var corrected: String?
        walk(j, "showingResultsForRenderer") { corrected = $0.o("correctedQueryEndpoint")?.o("searchEndpoint")?.s("query") }
        // The top card repeats a few of its own songs below it: keep each once.
        var seen = Set<String>()
        var songs: [(Track, Bool)] = []
        for case .song(let t, _, let v) in items where seen.insert(t.id).inserted { songs.append((t, v)) }
        func unique(_ f: (Item) -> Bool) -> [Item] { var s = Set<String>(); return items.filter { f($0) && s.insert($0.id).inserted } }
        return Results(top: top, songs: songs, artists: unique { if case .artist = $0 { true } else { false } },
                       albums: unique { if case .album = $0 { true } else { false } },
                       playlists: unique { if case .playlist = $0 { true } else { false } }, corrected: corrected)
    }

    /// Suggestions while typing: completed queries, then a few direct hits (artists, songs).
    static func suggestions(_ q: String) async throws -> (texts: [String], items: [Item]) {
        let j = try await call("music/get_search_suggestions", ["input": q])
        var texts: [String] = []
        walk(j, "searchSuggestionRenderer") { r in
            if let s = r.o("navigationEndpoint")?.o("searchEndpoint")?.s("query"), !s.isEmpty { texts.append(s) }
        }
        var items: [Item] = []
        walk(j, "musicResponsiveListItemRenderer") { if let i = listItem($0) { items.append(i) } }
        return (texts, items)
    }

    // MARK: pages

    struct ArtistPage {
        var name: String
        var art: String?
        var about: String
        var listeners: String
        var songs: [Track]
        var songsPlaylist: String?
        var shelves: [Shelf]
        var radio: String?
    }

    static func artist(_ id: String) async throws -> ArtistPage {
        let j = try await call("browse", ["browseId": id])
        let h = j.o("header").flatMap { $0.o("musicImmersiveHeaderRenderer") ?? $0.o("musicVisualHeaderRenderer") }
        let name = text(h?.o("title"))
        var songs: [Track] = []
        var songsPlaylist: String?
        var shelves: [Shelf] = []
        for s in sections(j) {
            if let m = s.o("musicShelfRenderer") {
                for o in m.objs("contents") {
                    if let r = o.o("musicResponsiveListItemRenderer"), case .song(var t, _, _)? = listItem(r) {
                        if t.artist.isEmpty { t.artist = name }
                        songs.append(t)
                    }
                }
                let end = m.o("bottomEndpoint") ?? m.o("title")?.objs("runs").first?.o("navigationEndpoint")
                if let b = end?.o("browseEndpoint")?.s("browseId"), !b.isEmpty { songsPlaylist = b }
            }
            if let c = s.o("musicCarouselShelfRenderer") {
                let shelf = carousel(c, artist: name)
                if !shelf.items.isEmpty { shelves.append(shelf) }
            }
        }
        let radio = h?.o("startRadioButton")?.o("buttonRenderer")?.o("navigationEndpoint")?.o("watchPlaylistEndpoint")?.s("playlistId")
        return ArtistPage(name: name, art: thumb(h?.o("thumbnail")), about: text(h?.o("description")), listeners: text(h?.o("monthlyListenerCount")),
                          songs: songs, songsPlaylist: songsPlaylist, shelves: shelves, radio: radio)
    }

    struct Collection {
        var title: String
        var subtitle: String
        var art: String?
        var tracks: [Track]
    }

    /// An album (MPREb_…) or a playlist (VL…) — its songs.
    static func collection(_ id: String) async throws -> Collection {
        let j = try await call("browse", ["browseId": id])
        var title = "", sub = "", artist = ""
        var art: String?
        walk(j, "musicResponsiveHeaderRenderer") { h in
            title = text(h.o("title")); sub = text(h.o("subtitle")); artist = text(h.o("straplineTextOne")); art = thumb(h.o("thumbnail"))
        }
        if title.isEmpty {
            walk(j, "musicDetailHeaderRenderer") { h in title = text(h.o("title")); sub = text(h.o("subtitle")); art = thumb(h.o("thumbnail")) }
        }
        let album = id.hasPrefix("MPRE")
        var tracks: [Track] = []
        var seen = Set<String>()
        walk(j, "musicResponsiveListItemRenderer") { r in
            guard case .song(var t, _, _)? = listItem(r), seen.insert(t.id).inserted else { return }
            // Album rows leave out the artist and cover: they're the album's.
            if album {
                if t.artist.isEmpty { t.artist = artist }
                t.album = t.album ?? title
                t.art = t.art ?? art
            }
            tracks.append(t)
        }
        return Collection(title: title, subtitle: [sub, artist].filter { !$0.isEmpty }.joined(separator: " · "), art: art, tracks: tracks)
    }

    /// A browse page made of shelves: home, charts, new releases, a mood or genre.
    static func shelves(_ browseId: String, params: String? = nil, auth: Bool = false) async throws -> [Shelf] {
        var body: JSON = ["browseId": browseId]
        if let params { body["params"] = params }
        let j = try await call("browse", body, auth: auth)
        var out: [Shelf] = []
        for s in sections(j) {
            if let c = s.o("musicCarouselShelfRenderer") { out.append(carousel(c, artist: "")) }
            if let m = s.o("musicShelfRenderer") {
                let items = m.objs("contents").compactMap { $0.o("musicResponsiveListItemRenderer").flatMap(listItem) }
                out.append(Shelf(title: text(m.o("title")), items: items))
            }
            if let g = s.o("gridRenderer") {
                var items: [Item] = []
                for o in g.objs("items") {
                    if let r = o.o("musicTwoRowItemRenderer"), let i = twoRow(r, artist: "") { items.append(i) }
                    if let b = o.o("musicNavigationButtonRenderer"), let i = moodButton(b) { items.append(i) }
                }
                out.append(Shelf(title: text(g.o("header")?.o("gridHeaderRenderer")?.o("title")), items: items))
            }
        }
        return out.filter { !$0.items.isEmpty }
    }

    /// Your listening history on YouTube Music (signed in): songs under "Today", "Yesterday", "This week"…
    static func history() async throws -> [(when: String, track: Track)] {
        let j = try await call("browse", ["browseId": "FEmusic_history"], auth: true)
        var out: [(String, Track)] = []
        for s in sections(j) {
            guard let m = s.o("musicShelfRenderer") else { continue }
            let when = text(m.o("title"))
            for o in m.objs("contents") {
                if let r = o.o("musicResponsiveListItemRenderer"), let t = listItem(r)?.track { out.append((when, t)) }
            }
        }
        return out
    }

    /// Songs you liked on YouTube Music (signed in).
    static func liked() async throws -> [Track] {
        let j = try await call("browse", ["browseId": "FEmusic_liked_videos"], auth: true)
        var out: [Track] = []
        walk(j, "musicResponsiveListItemRenderer") { if let t = listItem($0)?.track { out.append(t) } }
        return out
    }

    // MARK: parsing

    private static func sections(_ j: JSON) -> [JSON] {
        var out: [JSON] = []
        walk(j, "sectionListRenderer") { out += $0.objs("contents") }
        return out
    }

    private static func carousel(_ c: JSON, artist: String) -> Shelf {
        let header = c.o("header")?.o("musicCarouselShelfBasicHeaderRenderer")
        var items: [Item] = []
        for o in c.objs("contents") {
            if let r = o.o("musicTwoRowItemRenderer"), let i = twoRow(r, artist: artist) { items.append(i) }
            if let r = o.o("musicResponsiveListItemRenderer"), let i = listItem(r) { items.append(i) }
            if let b = o.o("musicNavigationButtonRenderer"), let i = moodButton(b) { items.append(i) }
        }
        return Shelf(title: text(header?.o("title")), items: items, subtitle: text(header?.o("strapline")))
    }

    private static func moodButton(_ b: JSON) -> Item? {
        guard let be = b.o("clickCommand")?.o("browseEndpoint") else { return nil }
        let color = (b.o("solid")?["leftStripeColor"] as? NSNumber)?.int64Value ?? 0xFF555555
        return .mood(id: be.s("browseId") ?? "", params: be.s("params") ?? "", title: text(b.o("buttonText")), color: color)
    }

    /// A tile: album, playlist, artist, or a song/video.
    private static func twoRow(_ r: JSON, artist: String) -> Item? {
        let title = text(r.o("title"))
        guard !title.isEmpty, let nav = r.o("navigationEndpoint") else { return nil }
        let sub = text(r.o("subtitle"))
        let art = thumb(r.o("thumbnailRenderer"))
        if let b = browseItem(nav, title, sub, art, artist: artist) { return b }
        guard let id = nav.o("watchEndpoint")?.s("videoId"), !id.isEmpty else { return nil }
        let parts = sub.components(separatedBy: " • ")
        let by = parts.first { p in !["Song", "Video", "Single", "EP"].contains(p) && !p.hasSuffix(" views") && !p.hasSuffix(" plays") } ?? artist
        return .song(Track(source: .youtube, id: id, title: title, artist: by, album: nil, durationMs: 0, art: art), subtitle: sub, video: sub.contains(" views"))
    }

    private static func browseItem(_ nav: JSON, _ title: String, _ sub: String, _ art: String?, artist: String = "") -> Item? {
        guard let be = nav.o("browseEndpoint"), let id = be.s("browseId"), !id.isEmpty else { return nil }
        switch pageType(be) {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            return .album(id: id, title: title, subtitle: sub, art: art, artist: artist.isEmpty ? (sub.components(separatedBy: " • ")[safe: 1] ?? "") : artist)
        case "MUSIC_PAGE_TYPE_PLAYLIST": return .playlist(id: id, title: title, subtitle: sub, art: art)
        case "MUSIC_PAGE_TYPE_ARTIST": return .artist(id: id, title: title, subtitle: sub, art: art)
        default: return nil
        }
    }

    private static func pageType(_ browseEndpoint: JSON?) -> String? {
        browseEndpoint?.o("browseEndpointContextSupportedConfigs")?.o("browseEndpointContextMusicConfig")?.s("pageType")
    }

    /// A run's page type: artist, album…
    static func runPage(_ run: JSON) -> String? { pageType(run.o("navigationEndpoint")?.o("browseEndpoint")) }

    private static let clockRE = try! NSRegularExpression(pattern: #"^\d+:\d{2}(:\d{2})?$"#)
    private static let dateRE = try! NSRegularExpression(pattern: #"^[A-Z][a-z]{2,8} \d{1,2}, \d{4}$"#)
    static func isDate(_ s: String) -> Bool { dateRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    static func isClock(_ s: String) -> Bool { clockRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// A list row: a song or video (has a video id), else an artist / album / playlist link.
    static func listItem(_ r: JSON) -> Item? {
        let cols = r.objs("flexColumns")
        guard !cols.isEmpty else { return nil }
        func col(_ i: Int) -> JSON? { cols[safe: i]?.o("musicResponsiveListItemFlexColumnRenderer")?.o("text") }
        guard let first = col(0)?.objs("runs").first else { return nil }
        let title = text(col(0))
        let art = thumb(r.o("thumbnail"))
        let meta = col(1)?.objs("runs") ?? []
        let sub = text(col(1))
        let id = [r.o("playlistItemData")?.s("videoId"), first.o("navigationEndpoint")?.o("watchEndpoint")?.s("videoId")]
            .compactMap { $0 }.first { !$0.isEmpty }
        guard let id else {
            guard let nav = r.o("navigationEndpoint") ?? first.o("navigationEndpoint") else { return nil }
            let after = sub.range(of: " • ").map { String(sub[$0.upperBound...]) } ?? sub
            return browseItem(nav, title, after, art)
        }
        var artists: [String] = []
        var album: String?
        var duration: Int64 = 0
        for run in meta {
            let t = run.s("text") ?? ""
            switch runPage(run) {
            case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL": artists.append(t)
            case "MUSIC_PAGE_TYPE_ALBUM": album = t
            default: if isClock(t) { duration = dur(t) }
            }
        }
        // Third column / fixed column: the album or the length on some pages.
        for i in 2..<max(2, cols.count) { let t = text(col(i)); if isClock(t) { duration = dur(t) } }
        for f in r.objs("fixedColumns") {
            let t = text(f.o("musicResponsiveListItemFixedColumnRenderer")?.o("text"))
            if isClock(t) { duration = dur(t) }
        }
        let kind = meta.first?.s("text")
        // (Podcast-style uploads lead with their date: "Apr 12, 2024 • Channel".)
        if artists.isEmpty, let a = sub.components(separatedBy: " • ").first(where: { !$0.isEmpty && !["Song", "Video", "Episode"].contains($0) && !isClock($0) && !isDate($0) }) {
            artists.append(a)
        }
        return .song(Track(source: .youtube, id: id, title: title, artist: artists.joined(separator: ", "), album: album, durationMs: duration, art: art),
                     subtitle: sub, video: kind == "Video" || sub.contains(" views"))
    }

    static func text(_ o: JSON?) -> String {
        guard let o else { return "" }
        guard let runs = o.a("runs") else { return o.s("simpleText") ?? "" }
        return runs.compactMap { ($0 as? JSON)?.s("text") }.joined()
    }

    /// The largest thumbnail under `o`, asked for at 544 px (Images picks the size it needs).
    static func thumb(_ o: JSON?) -> String? {
        guard let o else { return nil }
        var best: String?
        walkAll(o) { k, v in
            if best == nil, k == "thumbnails", let a = v as? [Any], let last = a.last as? JSON { best = last.s("url") }
        }
        guard var url = best else { return nil }
        url = url.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w544-h544", options: .regularExpression)
        if url.hasPrefix("//") { url = "https:" + url }
        return url
    }

    static func dur(_ t: String?) -> Int64 {
        guard let t, isClock(t) else { return 0 }
        return t.split(separator: ":").reduce(Int64(0)) { $0 * 60 + (Int64($1) ?? 0) } * 1000
    }

    /// Every object stored under `key` anywhere in the answer (not looking inside a match).
    static func walk(_ v: Any, _ key: String, _ f: (JSON) -> Void) {
        if let o = v as? JSON {
            for (k, x) in o {
                if k == key, let m = x as? JSON { f(m) } else { walk(x, key, f) }
            }
        } else if let a = v as? [Any] {
            for x in a { walk(x, key, f) }
        }
    }

    private static func walkAll(_ v: Any, _ f: (String, Any) -> Void) {
        if let o = v as? JSON {
            for (k, x) in o { f(k, x); walkAll(x, f) }
        } else if let a = v as? [Any] {
            for x in a { walkAll(x, f) }
        }
    }
}
