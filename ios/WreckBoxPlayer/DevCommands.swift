import Foundation

/// Test commands over the cable, for checking the app on a real iPhone without touching it:
///   xcrun devicectl device process launch --device <id> --payload-url 'wreckbox://play?q=bohemian+rhapsody' local.wreckbox.player
/// play?q=… (search, play the first hit; the rest follow) · search?q=… · artist?q=… · home · pause · resume · next · previous ·
/// seek?s=… · state
/// Launch arguments do the same at start-up: -wbPlay "query".
/// Every command and the player's answer go to the log (Documents/test.log).
@MainActor
enum DevCommands {
    static func fromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-wbPlay"), i + 1 < args.count {
            play(args[i + 1])
        }
        // A script of commands, each after a pause (the simulator asks before opening every wreckbox:// link):
        //   -wbRun "8 jump?i=2; 6 state"   → after 8 s jump, 6 s later state
        if let i = args.firstIndex(of: "-wbRun"), i + 1 < args.count {
            var at = 0.0
            for step in args[i + 1].split(separator: ";") {
                let parts = step.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                guard parts.count == 2, let wait = Double(parts[0]), let url = URL(string: "wreckbox://\(parts[1])") else { continue }
                at += wait
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { run(url) }
            }
        }
    }

    static func run(_ url: URL) {
        guard url.scheme == "wreckbox" else { return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func arg(_ k: String) -> String? { q.first { $0.name == k }?.value }
        let p = Player.shared
        Log.shared.write("command: \(url.host ?? "")\(url.query.map { "?\($0)" } ?? "")")
        switch url.host {
        case "play": if let s = arg("q") { play(s) }
        case "search": if let s = arg("q") { Task { await search(s) } }
        case "home": Task { await HomeFeed.shared.refresh(force: true) }
        case "import": Task { await Import.shared.auto(); Log.shared.write("import status: \(Import.shared.status ?? "-") · history \(History.shared.plays) plays, \(History.shared.data.songs.count) songs") }
        case "accounts": Task { Log.shared.write("accounts: YouTube \(await Accounts.signedIn(.youtube)), Spotify \(await Accounts.signedIn(.spotify))") }
        case "artist": if let s = arg("q") { Task { await artist(s) } }
        case "forget": UserDefaults.standard.removeObject(forKey: "searchClicks"); Log.shared.write("search picks cleared")
        case "eq": if let s = arg("preset") { EQ.shared.choose(s); Log.shared.write("eq: \(EQ.shared.preset) \(EQ.shared.effective)") }
        case "spotifypage": Task { Log.shared.write("spotify page: \(await SpotifyPage.shared.describe())") }
        case "show":
            let n = Nav.shared
            n.playing = false; n.settings = false; n.eq = false
            switch arg("page") {
            case "home": n.tab = .home
            case "search": n.tab = .search
            case "playlists": n.tab = .playlists
            case "playing": n.playing = true
            case "settings": n.settings = true
            case "eq": n.playing = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { n.eq = true }
            case "artist": if let q = arg("q") { Task { if let r = try? await YouTubeMusic.search(q), let a = ([r.top].compactMap { $0 } + r.artists).first(where: { if case .artist = $0 { true } else { false } }) { n.tab = .home; n.homePath.append(a) } } }
            default: break
            }
        case "jump": if let i = arg("i").flatMap(Int.init) { Player.shared.jump(to: i); WidgetBridge.shared.changed() }
        case "pause": p.pause()
        case "resume": p.resume()
        case "next": p.next()
        case "previous": p.previous()
        case "seek": if let s = arg("s").flatMap(Double.init) { p.seek(s) }
        case "state": state()
        default: Log.shared.write("unknown command")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if url.host != "state" { state() } }
    }

    static func play(_ query: String) {
        Task {
            guard let r = await search(query), !r.hits.isEmpty else { return }
            Player.shared.playList(r.hits.map(\.track), start: 0, searched: query)
        }
    }

    /// Runs a full search and logs what came back (top result, first songs, artists…).
    @discardableResult
    static func search(_ query: String) async -> Search.Results? {
        var last: Search.Results?
        for await r in Search.stream(query) { last = r }
        guard let r = last else { return nil }
        Log.shared.write("results “\(query)”\(r.corrected.map { " (→ \($0))" } ?? ""): top=\(r.top?.title ?? "-") · songs: " +
                         r.hits.prefix(5).map { "\($0.track.title) — \($0.track.artist)" }.joined(separator: " | ") +
                         " · \(r.hits.count) songs, \(r.artists.count) artists, \(r.albums.count) albums, \(r.playlists.count) playlists" +
                         (r.failed.isEmpty ? "" : " · failed: \(r.failed)"))
        return r
    }

    /// Finds the artist and logs their page (songs, shelves).
    static func artist(_ query: String) async {
        guard let r = try? await YouTubeMusic.search(query),
              let a = ([r.top].compactMap { $0 } + r.artists).first(where: { if case .artist = $0 { true } else { false } }) else {
            return Log.shared.write("artist “\(query)”: not found")
        }
        do {
            let p = try await YouTubeMusic.artist(a.id)
            Log.shared.write("artist \(p.name) (\(p.listeners)): \(p.songs.count) songs, shelves: " + p.shelves.map { "\($0.title)=\($0.items.count)" }.joined(separator: ", "))
            if let album = p.shelves.flatMap(\.items).first(where: { if case .album = $0 { true } else { false } }) {
                let c = try await YouTubeMusic.collection(album.id)
                Log.shared.write("album \(c.title) · \(c.subtitle): \(c.tracks.count) songs, first: \(c.tracks.first?.title ?? "-")")
            }
        } catch { Log.shared.write("artist page failed: \(error.localizedDescription)") }
    }

    static func state() {
        let p = Player.shared
        let t = p.current
        Log.shared.write("state: \(p.playWhenReady ? "playing" : "paused")\(p.buffering ? " (buffering)" : "") \(p.mode) " +
                         "\(Int(p.position))/\(Int(p.duration)) s · \(p.quality ?? "-") · #\(p.index + 1)/\(p.queue.count) “\(t?.title ?? "-")”")
    }
}
