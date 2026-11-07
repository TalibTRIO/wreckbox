import Compression
import Foundation

/// Brings your listening history in, so search and Home know your taste from day one (port of the Android Player's
/// Import):
///  - YouTube Music (signed in): your history page (the last few months) and liked songs.
///  - Spotify (signed in): Liked Songs, your profile's top tracks this month and top artists — read from the signed-in
///    web player's pages (SpotifyPage), no developer key.
///  - A data export file, for everything you ever played: Spotify's "Extended streaming history" (or the shorter
///    "Account data"), or Google Takeout's YouTube watch-history.json. Zip or the JSON files themselves.
/// Everything stays on the phone (History). The services are read again at most twice a day (`auto`).
@MainActor
final class Import: ObservableObject {
    static let shared = Import()

    /// A line for Settings: what's importing / what the last import found.
    @Published var status: String?

    private let d = UserDefaults.standard

    private var running = false

    /// On app start: read each signed-in service again if it's been 12 hours. (One at a time: a second call while
    /// one runs does nothing.)
    func auto() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let now = Date().timeIntervalSince1970
        if await Accounts.signedIn(.youtube), now - d.double(forKey: "ytImportAt") > 12 * 3600 {
            do { try await youtube() } catch { Log.shared.write("import youtube failed: \(error.localizedDescription)") }
        }
        if await Accounts.signedIn(.spotify), now - d.double(forKey: "spImportAt") > 12 * 3600 {
            do { try await spotify() } catch { Log.shared.write("import spotify failed: \(error.localizedDescription)") }
        }
        if let status { Log.shared.write("import: \(status)") }
    }

    /// YouTube Music history + likes.
    func youtube() async throws {
        status = "Reading your YouTube Music history…"
        let items = try await YouTubeMusic.history()
        let liked = (try? await YouTubeMusic.liked()) ?? []
        // The page has no times, only "Today", "Yesterday", "This week"…, and lists each song once, at its latest play:
        // the songs played since last time are the ones above the list as it was then. Each gets a time inside its
        // section.
        let last = d.stringArray(forKey: "ytImportSeen") ?? d.string(forKey: "ytImportTop").map { [$0] } ?? []
        let fresh = items.prefix(Self.newOnTop(items.map(\.track.id), last))
        let now = Date().timeIntervalSince1970
        let plays = fresh.enumerated().map { i, e in History.Play(track: e.track, at: Self.sectionTime(e.when, now) - Double(i) * 60, listenedMs: e.track.durationMs) }
        let added = History.shared.importPlays("youtube", plays, onlyNew: false)
        History.shared.importFavourites("youtube-liked", liked, weight: 1)
        d.set(now, forKey: "ytImportAt")
        if !items.isEmpty { d.set(items.map(\.track.id), forKey: "ytImportSeen") }
        status = "YouTube Music: \(added) new plays, \(liked.count) liked songs"
    }

    /// How many songs at the top of `ids` were played since the list was `last`. The songs not played since are
    /// still in last time's order, at the bottom; a played one moved to the top, out of that order (or is new).
    static func newOnTop(_ ids: [String], _ last: [String]) -> Int {
        guard !last.isEmpty else { return ids.count }
        let at = Dictionary(last.enumerated().map { ($1, $0) }) { a, _ in a }
        var i = ids.count
        // Songs at the bottom that last time's list didn't reach are old.
        while i > 0, at[ids[i - 1]] == nil { i -= 1 }
        guard i > 0 else { return ids.count }
        var below = at[ids[i - 1]]!
        i -= 1
        while i > 0, let p = at[ids[i - 1]], p < below { below = p; i -= 1 }
        return i
    }

    private static func sectionTime(_ section: String, _ now: Double) -> Double {
        let day = 86_400.0
        switch section.lowercased() {
        case "today": return now
        case "yesterday": return now - day
        case "this week": return now - 3 * day
        case "last week": return now - 10 * day
        default:
            // "September 2026" or "September"
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            let parts = section.split(separator: " ")
            f.dateFormat = "MMMM"
            guard let first = parts.first, let m = f.date(from: String(first)) else { return now - 30 * day }
            var c = DateComponents()
            c.month = Calendar.current.component(.month, from: m)
            c.year = parts.count > 1 ? Int(parts[1]) : Calendar.current.component(.year, from: Date())
            c.day = 15; c.hour = 12
            return Calendar.current.date(from: c)?.timeIntervalSince1970 ?? now - 30 * day
        }
    }

    /// Spotify through the signed-in web player.
    func spotify() async throws {
        status = "Reading your Spotify history…"
        let j = try await withTimeout(180) { try await SpotifyPage.shared.library() }
        if let e = j.s("error") { status = "Spotify: couldn't read your history (\(e))"; throw NSError(domain: "Spotify", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
        let h = History.shared
        func tracks(_ k: String) -> [Track] { j.objs(k).compactMap(Self.spTrack) }
        // Top songs: the short-term list counts most (what you're into now).
        h.importFavourites("spotify-top-short", tracks("top_short_term"), weight: 1.6)
        let saved = tracks("saved")
        h.importFavourites("spotify-saved", saved, weight: 1)
        let artists = (j["artists"] as? [String]) ?? []
        h.importArtists("spotify-artists", artists)
        d.set(Date().timeIntervalSince1970, forKey: "spImportAt")
        status = "Spotify: \(saved.count) liked songs, \(j.objs("top_short_term").count) top tracks, \(artists.count) top artists"
    }

    private static func spTrack(_ o: JSON) -> Track? {
        guard let id = o.s("id"), !id.isEmpty else { return nil }
        let album = o.s("album") ?? ""
        let art = o.s("art") ?? ""
        return Track(source: .spotify, id: id, title: o.s("name") ?? "", artist: o.s("artists") ?? "", album: album.isEmpty ? nil : album,
                     durationMs: (o["dur"] as? NSNumber)?.int64Value ?? 0, art: art.isEmpty ? nil : art)
    }

    // MARK: export files

    /// A Spotify or Google data export (zip or JSON). Returns how many plays were added.
    @discardableResult
    func file(_ url: URL) async -> Int {
        status = "Reading the export…"
        let name = url.lastPathComponent.lowercased()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let plays: [(String, History.Play)] = await Task.detached {
            guard let data = try? Data(contentsOf: url) else { return [] }
            if name.hasSuffix(".zip") {
                return Zip.entries(data).filter { e in
                    let n = (e.name as NSString).lastPathComponent.lowercased()
                    return n.hasSuffix(".json") && (n.contains("streaming_history") || n.contains("streaminghistory") || n.contains("watch-history"))
                }.flatMap { Self.readPlays($0.data()) }
            }
            return Self.readPlays(data)
        }.value
        guard !plays.isEmpty else {
            status = name.hasSuffix(".html") ? "That's the HTML version — in Google Takeout choose JSON as the history format" : "No listening history found in that file"
            return 0
        }
        let bySource = Dictionary(grouping: plays, by: \.0)
        let added = bySource.reduce(0) { n, e in n + History.shared.importPlays(e.key, e.value.map(\.1).sorted { $0.at < $1.at }) }
        status = "Imported \(added) plays from the export"
        return added
    }

    nonisolated private static func readPlays(_ data: Data?) -> [(String, History.Play)] {
        guard let data, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [JSON] else { return [] }
        return rows.compactMap(parsePlay)
    }

    nonisolated private static func parsePlay(_ o: JSON) -> (String, History.Play)? {
        let iso = ISO8601DateFormatter()
        /// Takeout times have fractions of a second ("2024-05-01T10:00:00.123Z"); Spotify's don't.
        func isoDate(_ s: String) -> Date? {
            if let d = iso.date(from: s) { return d }
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s)
        }
        // Spotify extended streaming history
        if let title = o.s("master_metadata_track_name") {
            let ms = (o["ms_played"] as? NSNumber)?.int64Value ?? 0
            guard ms >= 30_000, let at = o.s("ts").flatMap(iso.date) else { return nil }
            let id = o.s("spotify_track_uri")?.components(separatedBy: ":").last ?? ""
            return ("spotify-export", History.Play(track: Track(source: .spotify, id: id, title: title, artist: o.s("master_metadata_album_artist_name") ?? "",
                                                                 album: o.s("master_metadata_album_album_name")), at: at.timeIntervalSince1970, listenedMs: ms))
        }
        // Spotify account data (shorter history, no song ids)
        if let title = o.s("trackName") {
            let ms = (o["msPlayed"] as? NSNumber)?.int64Value ?? 0
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            guard ms >= 30_000, let at = o.s("endTime").flatMap(f.date) else { return nil }
            return ("spotify-export", History.Play(track: Track(source: .spotify, id: "", title: title, artist: o.s("artistName") ?? ""),
                                                   at: at.timeIntervalSince1970, listenedMs: ms))
        }
        // Google Takeout watch history: YouTube Music plays (and songs from artists' "- Topic" channels on YouTube)
        if let url = o.s("titleUrl") {
            let channel = o.objs("subtitles").first?.s("name") ?? ""
            guard o.s("header") == "YouTube Music" || channel.hasSuffix(" - Topic") else { return nil }
            guard let r = url.range(of: #"[?&]v=[^&]+"#, options: .regularExpression), var title = o.s("title"),
                  let at = o.s("time").flatMap(isoDate)
            else { return nil }
            let id = String(url[r].dropFirst(3))
            if title.hasPrefix("Watched ") { title = String(title.dropFirst(8)) }
            let artist = channel.hasSuffix(" - Topic") ? String(channel.dropLast(8)) : channel
            return ("youtube-export", History.Play(track: Track(source: .youtube, id: id, title: title, artist: artist), at: at.timeIntervalSince1970))
        }
        return nil
    }
}

/// Gives up on `f` after `seconds`.
func withTimeout<T: Sendable>(_ seconds: Double, _ f: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await f() }
        g.addTask { try await Task.sleep(for: .seconds(seconds)); throw URLError(.timedOut) }
        let r = try await g.next()!
        g.cancelAll()
        return r
    }
}

/// Reads the files in a zip (stored or deflated) — enough for data exports.
enum Zip {
    struct Entry {
        let name: String
        fileprivate let blob: Data
        fileprivate let method: UInt16
        fileprivate let size: Int

        func data() -> Data? {
            if method == 0 { return blob }
            guard method == 8 else { return nil }
            var out = Data(count: size)
            let n = out.withUnsafeMutableBytes { dst in
                blob.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, blob.count, nil, COMPRESSION_ZLIB)
                }
            }
            return n == size ? out : nil
        }
    }

    /// From the central directory at the end of the file.
    static func entries(_ d: Data) -> [Entry] {
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard b.count > 22, let eocd = stride(from: b.count - 22, through: max(0, b.count - 65_557), by: -1).first(where: { u32($0) == 0x06054b50 }) else { return [] }
        var p = u32(eocd + 16)
        var out: [Entry] = []
        for _ in 0..<u16(eocd + 10) {
            guard u32(p) == 0x02014b50 else { break }
            let method = UInt16(u16(p + 10)), csize = u32(p + 20), usize = u32(p + 24)
            let nlen = u16(p + 28), elen = u16(p + 30), clen = u16(p + 32), local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<min(b.count, p + 46 + nlen)], as: UTF8.self)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            if start + csize <= b.count, !name.hasSuffix("/") {
                out.append(Entry(name: name, blob: d.subdata(in: start..<(start + csize)), method: method, size: usize))
            }
            p += 46 + nlen + elen + clen
        }
        return out
    }
}
