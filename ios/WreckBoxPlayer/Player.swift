import AVFoundation
import Combine
import MediaPlayer
import UIKit

/// The one player behind everything: a queue of tracks from any source. YouTube songs play as direct streams in the
/// phone's own player (NativeAudio) — no page, no ads — with YouTube's hidden page (WebEngine) as the backup when a
/// song has no direct stream. To iOS (lock screen, Control Centre, AirPods / headset / car buttons) it's one player.
///
/// The queue is ours: when a song ends the next track of our queue starts, whatever its source. (A port of the Mac
/// Player, itself a port of the Android Player's HybridPlayer.)
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    enum Repeat: Int, Codable { case off = 0, all = 1, one = 2 }
    /// How the current song is playing.
    enum Mode { case native, page }

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = -1
    @Published private(set) var playWhenReady = false
    @Published private(set) var buffering = false
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: Repeat = .off
    @Published private(set) var message: String?
    /// What's playing, technically: "AAC · 130 kbps".
    @Published private(set) var quality: String?
    @Published private(set) var mode: Mode = .native
    /// Songs autoplay added (similar to what was playing), and the song the latest mix came from.
    @Published private(set) var radioKeys: Set<String> = []
    @Published private(set) var radioFrom: String?
    @Published private(set) var radioLoading = false

    var current: Track? { queue[safe: index] }
    var playing: Bool { playWhenReady && current != nil }

    private var original: [Track]?
    private var startedAt = Date()
    private let native = NativeAudio()
    let page: WebEngine = WebEngine(.youtube)
    private var radioTask: Task<Void, Never>?
    private var radioGen = 0
    private var startGen = 0
    private var messageClear: DispatchWorkItem?
    /// Direct links already fetched, by video id (they last a few hours).
    private var streams: [String: YouTubeStream.Stream] = [:]
    /// Songs whose direct link failed this session: they go straight to the page.
    private var noDirect: Set<String> = []
    /// The YouTube Music match a Spotify song plays from, by the Spotify song's key.
    private var matches: [String: String] = [:]
    /// Playing when a call (Siri, an alarm, another app) took the audio: it plays on when that ends.
    private var interrupted = false

    private init() {
        native.onEnd = { [weak self] next in self?.nativeEnded(next) }
        native.onFail = { [weak self] key, why in self?.nativeFailed(key, why) }
        native.onStarted = { [weak self] in
            guard let self, self.mode == .native else { return }
            if self.buffering { self.buffering = false; self.publish() }
        }
        page.onState = { [weak self] s in self?.onPage(s) }
        EQ.shared.onChange = { [weak self] g in if self?.mode == .page { self?.page.eq(g) } }
        page.onEnded = { [weak self] why in self?.pageEnded(why) }
        restore()
        setUpRemoteCommands()
        setUpAudioSession()
    }

    // MARK: what the app calls

    /// `searched`: the search it was picked from (it ranks first for that search next time).
    func playList(_ tracks: [Track], start: Int = 0, shuffled: Bool = false, searched: String? = nil) {
        guard !tracks.isEmpty else { return }
        if let q = searched, let t = tracks[safe: start] { Clicks.picked(q, t); RecentSearches.add(q) }
        original = nil
        // A new list: the old radio (and any mix still loading for it) is gone.
        radioGen += 1
        radioTask?.cancel(); radioTask = nil; radioLoading = false
        radioKeys = []; radioFrom = nil
        // One entry per song; shuffle starts on a random song, with all the others shuffled after it.
        var seen = Set<String>()
        queue = tracks.filter { seen.insert($0.key).inserted }
        let first = tracks[safe: max(0, min(start, tracks.count - 1))]
        index = max(0, queue.firstIndex { $0.key == first?.key } ?? 0)
        shuffle = false
        if shuffled {
            original = queue
            queue.shuffle()
            index = 0
            shuffle = true
        }
        playWhenReady = true
        startCurrent()
    }

    func playNext(_ t: Track) {
        if queue.isEmpty { return playList([t]) }
        if t.key == current?.key { return say("Already playing") }
        let cur = current
        queue.removeAll { $0.key == t.key }
        index = max(0, queue.firstIndex { $0.key == cur?.key } ?? 0)
        queue.insert(t, at: index + 1)
        original = original.map { $0.filter { $0.key != t.key } + [t] }
        say("Plays next: \(t.title)")
        changed()
    }

    func addToQueue(_ t: Track) {
        if queue.isEmpty { return playList([t]) }
        if queue.contains(where: { $0.key == t.key }) { return say("Already in the queue") }
        // Your songs go before the autoplay ones.
        if let firstAuto = queue.indices.first(where: { $0 > index && radioKeys.contains(queue[$0].key) }) {
            queue.insert(t, at: firstAuto)
        } else {
            queue.append(t)
        }
        original?.append(t)
        say("Added to queue: \(t.title)")
        changed()
    }

    func remove(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        let t = queue.remove(at: i)
        original?.removeAll { $0.key == t.key }
        if i < index { index -= 1 }
        say("Removed from queue: \(t.title)")
        changed()
    }

    func move(_ from: Int, _ to: Int) {
        guard queue.indices.contains(from), queue.indices.contains(to), from != to else { return }
        let cur = current
        queue.insert(queue.remove(at: from), at: to)
        index = queue.firstIndex { $0.key == cur?.key } ?? index
        changed()
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        playWhenReady = true
        startCurrent()
    }

    func toggle() { playWhenReady ? pause() : resume() }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count { index += 1 } else if repeatMode == .all { index = 0 } else { return }
        playWhenReady = true
        startCurrent()
    }

    /// Restarts the song if more than 3 s in; otherwise the previous song.
    func previous() {
        guard current != nil else { return }
        if position > 3 || index == 0 { seek(0); return }
        index -= 1
        playWhenReady = true
        startCurrent()
    }

    var position: Double {
        switch mode {
        case .native: return native.position
        case .page:
            let s = page.last
            return s.position + (!s.paused ? Date().timeIntervalSince(s.at) : 0)
        }
    }

    var duration: Double {
        guard let t = current else { return 0 }
        let live = mode == .native ? native.duration : page.last.duration
        // YouTube's page can stretch the duration as it glides into the next song: the song's own length wins.
        if mode == .page, t.duration > 0, live > t.duration + 5 { return t.duration }
        return live > 0 ? live : t.duration
    }

    func seek(_ s: Double) {
        switch mode {
        case .native: native.seek(s)
        case .page: page.seek(s)
        }
        nowPlaying(force: true)
        publish()
    }

    func skip(_ by: Double) { seek(max(0, min(duration - 1, position + by))) }

    func setShuffle(_ on: Bool) { shuffleUpcoming(on); changed() }

    func cycleRepeat() {
        repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off
        changed()
    }

    /// Drops the songs autoplay added after the current one.
    func clearAutoplay() {
        let cur = current
        queue = queue.enumerated().filter { $0.offset <= index || !radioKeys.contains($0.element.key) }.map(\.element)
        original = original?.filter { !radioKeys.contains($0.key) || $0.key == cur?.key }
        index = queue.firstIndex { $0.key == cur?.key } ?? index
        radioKeys = []
        changed()
    }

    func setAutoplay(_ on: Bool) { Prefs.autoplay = on; if on { maybeAutoplay() }; objectWillChange.send() }

    /// Song radio: this song, then songs like it (whatever the autoplay setting).
    func startRadio(_ t: Track) {
        if repeatMode == .one { repeatMode = .off }
        playList([t])
        if radioTask == nil { fetchRadio(t) }
    }

    // MARK: playing

    /// `nudged`: the direct link was fetched again once; `pageNudged`: the page was nudged once mid-song.
    private var lastPos = 0.0, lastDur = 0.0, baseDur = 0.0, lastMoved = Date(), nudged = false, pageNudged = false, lastNudge = Date.distantPast
    private var seenV: String?

    private func startCurrent() {
        guard let t = current else { return }
        logHeard()
        heard = (t, 0, t.durationMs)
        startGen += 1
        let gen = startGen
        message = nil
        buffering = true
        startedAt = Date()
        lastPos = 0; lastDur = 0; baseDur = 0; seenV = nil; lastMoved = startedAt; nudged = false; pageNudged = false
        quality = nil
        Library.shared.played(t)
        Log.shared.write("play \(t.source.tag) \(t.id) “\(t.title)” — \(t.artist)")
        changed()
        Task {
            // Spotify songs play from their YouTube Music match (free, no account).
            guard let id = await match(t) else { return guardGen(gen) { failed("Not found on YouTube Music") } }
            guard gen == startGen else { return }
            switch t.source {
            case .local:
                usePage(false)
                guard await native.load(LocalFiles.url(t.id), key: t.key, ends: t.duration), gen == startGen else { return }
                quality = LocalFiles.quality(t.id)
                if playWhenReady { native.play() }
                lineUpNext()
            case .youtube, .spotify:
                await startYouTube(id, key: t.key, gen: gen)
            }
        }
    }

    private func guardGen(_ gen: Int, _ f: () -> Void) { if gen == startGen { f() } }

    /// What the song plays from: its file name or video id, or a Spotify song's YouTube Music match (looked up once).
    private func match(_ t: Track) async -> String? {
        guard t.source == .spotify else { return t.id }
        if let id = matches[t.key] { return id }
        guard let id = await Radio.findOnYouTube(t) else { return nil }
        matches[t.key] = id
        return id
    }

    /// The video a YouTube or Spotify song plays from, when it's known.
    private func videoId(_ t: Track) -> String? {
        switch t.source {
        case .youtube: return t.id
        case .spotify: return matches[t.key]
        case .local: return nil
        }
    }

    /// Direct stream first; the page when there isn't one.
    private func startYouTube(_ id: String, key: String, gen: Int) async {
        if !noDirect.contains(id), let s = await stream(id) {
            guard gen == startGen else { return }
            usePage(false)
            guard await native.load(s.url, key: key, ends: s.duration), gen == startGen else { return }
            quality = s.quality
            Log.shared.write("direct \(s.quality) itag \(s.itag)")
            if playWhenReady { native.play() }
            publish()
            lineUpNext()
            return
        }
        guard gen == startGen else { return }
        Log.shared.write("no direct stream for \(id): playing in the page")
        usePage(true)
        // The page starts afresh (also when it takes over mid-song): its start and stall checks count from now.
        buffering = true
        startedAt = Date()
        lastPos = 0; lastDur = 0; baseDur = 0; seenV = nil; lastMoved = startedAt; pageNudged = false
        publish()
        if playWhenReady { page.playTrack(id) }
    }

    private func stream(_ id: String) async -> YouTubeStream.Stream? {
        if let s = streams[id], s.expires > Date() { return s }
        do {
            let s = try await YouTubeStream.resolve(id)
            streams[id] = s
            return s
        } catch {
            Log.shared.write("direct stream failed for \(id): \(error.localizedDescription)")
            return nil
        }
    }

    private func usePage(_ on: Bool) {
        if on {
            native.stop()
            mode = .page
        } else {
            if mode == .page { page.stop() }
            mode = .native
        }
    }

    func pause() {
        interrupted = false
        playWhenReady = false
        switch mode {
        case .native: native.pause()
        case .page: page.pause()
        }
        nowPlaying(force: true)
        publish()
    }

    func resume() {
        guard current != nil else { return }
        interrupted = false
        playWhenReady = true
        switch mode {
        case .native: if native.hasItem { native.play() } else { startCurrent() }
        case .page: if page.last.hasMedia { page.play() } else { startCurrent() }
        }
        nowPlaying(force: true)
        publish()
    }

    // MARK: the phone's player

    private func nativeEnded(_ next: String?) {
        guard mode == .native else { return }
        // The lined-up song started by itself: just move along.
        if let next, repeatMode != .one, let i = queue.indices.first(where: { $0 > index && queue[$0].key == next }) ?? (repeatMode == .all ? queue.firstIndex { $0.key == next } : nil) {
            index = i
            startedAt = Date()
            logHeard()
            heard = (current!, 0, current!.durationMs)
            quality = current.flatMap { $0.source == .local ? LocalFiles.quality($0.id) : videoId($0).flatMap { streams[$0]?.quality } }
            Library.shared.played(current!)
            Log.shared.write("next (queued) “\(current!.title)”")
            changed()
            return
        }
        trackEnded()
    }

    private func nativeFailed(_ key: String, _ why: String) {
        guard let t = current, t.key == key else { return }
        Log.shared.write("direct playback failed: \(why)")
        if t.source == .local { return failed("Couldn't play this file") }
        guard let id = videoId(t) else { return failed("This song didn't play") }
        // An old link: fetch a new one once; after that, the page.
        if streams.removeValue(forKey: id) == nil || nudged { noDirect.insert(id) }
        nudged = true
        let gen = startGen
        Task { await startYouTube(id, key: key, gen: gen) }
    }

    /// Fetches and lines up the next YouTube song, so it starts by itself when this one ends.
    private func lineUpNext() {
        guard mode == .native, let n = upNext else { return native.unqueue() }
        if native.queuedKey == n.key { return }
        if n.source == .local { Task { await native.queue(LocalFiles.url(n.id), key: n.key, ends: n.duration) }; return }
        if let id = videoId(n), noDirect.contains(id) { return native.unqueue() }
        Task {
            // Still the next song once the link is here?
            guard let id = await match(n), !noDirect.contains(id), let s = await stream(id), mode == .native, upNext?.key == n.key else { return }
            await native.queue(s.url, key: n.key, ends: s.duration)
        }
    }

    /// The song that plays when this one ends.
    private var upNext: Track? {
        if repeatMode == .one { return nil }
        if index + 1 < queue.count { return queue[index + 1] }
        return repeatMode == .all ? queue.first : nil
    }

    // MARK: YouTube's page (the backup)

    private func onPage(_ st: WebState) {
        guard mode == .page, current != nil else { return }
        let now = Date()
        if !st.paused, st.hasMedia { buffering = false }
        if baseDur <= 0, st.duration > 0, st.position < 30, !st.ad { baseDur = st.duration }
        if !st.ad, now.timeIntervalSince(startedAt) > 5, let t = current {
            // YouTube Music glides into the next song on the same stream (no ended event): its video id isn't ours.
            let v = st.url.range(of: #"[?&]v=([^&#]+)"#, options: .regularExpression).map { String(st.url[$0].dropFirst(3)) }
            if let v {
                if seenV == nil { seenV = v } else if v != seenV { return pageEnded("video id changed") }
                let ours = t.duration > 0 ? t.duration : baseDur
                if v != videoId(t), ours > 0, st.position >= ours - 5 { return pageEnded("glided into the next video") }
            }
        }
        let wrapped = lastDur > 5 && lastPos > lastDur - 4 && st.position < 2 && !st.ad
        if st.position != lastPos || st.paused || st.ad { lastMoved = now }
        lastPos = st.position; lastDur = st.duration
        if wrapped, now.timeIntervalSince(startedAt) > 5 { return pageEnded("clock wrapped to 0") }
        // iOS pauses a page's video when the app leaves the screen: play on.
        if playWhenReady, st.paused, st.hasMedia, !st.ended, now.timeIntervalSince(lastNudge) > 1.5 {
            lastNudge = now
            page.play()
        }
        // "Playing" but the clock stopped: near the end that's the end; mid-song nudge it once, then give up.
        if playWhenReady, !buffering, st.duration > 0, now.timeIntervalSince(lastMoved) > 6 {
            if st.position > st.duration - 12 { return pageEnded("stalled near the end") }
            if now.timeIntervalSince(lastMoved) > 20 { return failed("The song stalled") }
            if !pageNudged { pageNudged = true; page.play() }
        }
        if playWhenReady, buffering, now.timeIntervalSince(startedAt) > 25 { return failed("YouTube didn't start this song") }
        objectWillChange.send()
    }

    private func pageEnded(_ why: String) {
        guard mode == .page, Date().timeIntervalSince(startedAt) > 4 else { return }
        Log.shared.write("page ended: \(why)")
        trackEnded()
    }

    private func trackEnded() {
        if mode == .page { page.stop() }
        switch true {
        case repeatMode == .one: startCurrent()
        case index + 1 < queue.count: index += 1; startCurrent()
        case repeatMode == .all && !queue.isEmpty: index = 0; startCurrent()
        default: logHeard(); playWhenReady = false; buffering = false; nowPlaying(force: true); publish()
        }
    }

    // MARK: listening history

    /// The song being heard and how long it has played (counted each second while it plays).
    private var heard: (track: Track, ms: Int64, dur: Int64)?

    /// Tells History how much of the song was heard: a play, a skip, or neither.
    private func logHeard() {
        guard let h = heard else { return }
        heard = nil
        History.shared.record(h.track, listenedMs: h.ms, durMs: h.dur)
    }

    private func failed(_ why: String) {
        Log.shared.write("failed: \(why)")
        say(why)
        buffering = false
        if index + 1 < queue.count { index += 1; startCurrent() } else { playWhenReady = false; publish() }
    }

    private func say(_ m: String) {
        message = m
        messageClear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.message = nil }
        messageClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
        publish()
    }

    // MARK: autoplay (song radio)

    /// On the last or second-last song (and not repeating): fetch songs similar to the one playing and add them.
    private func maybeAutoplay() {
        guard let seed = current, Prefs.autoplay, repeatMode == .off, index >= queue.count - 2, radioTask == nil else { return }
        fetchRadio(seed)
    }

    /// Fetches songs similar to `seed` and adds them to the end of the queue.
    private func fetchRadio(_ seed: Track) {
        let gen = radioGen
        radioLoading = true
        radioTask = Task { [weak self] in
            guard let self else { return }
            let recent = Library.shared.data.recent.prefix(30).map(Radio.name)
            let exclude = Set(self.queue.map(\.key) + self.queue.map(Radio.name) + recent)
            let found = await Radio.similar(to: seed, excluding: exclude)
            guard gen == radioGen else { return }
            radioTask = nil
            radioLoading = false
            let current = self.queue
            let fresh = found.filter { f in !current.contains { $0.key == f.key } }
            guard !fresh.isEmpty else { return publish() }
            Log.shared.write("autoplay: +\(fresh.count) like “\(seed.title)”")
            queue += fresh
            original? += fresh
            radioKeys.formUnion(fresh.map(\.key))
            radioFrom = seed.title
            changed()
        }
    }

    private func shuffleUpcoming(_ on: Bool) {
        let cur = current
        if on && !shuffle {
            original = queue
            queue = Array(queue.prefix(index + 1)) + queue.dropFirst(index + 1).shuffled()
        } else if !on && shuffle, let o = original {
            queue = o
            index = max(0, o.firstIndex { $0.key == cur?.key } ?? 0)
            original = nil
        }
        shuffle = on
    }

    // MARK: state out

    private func changed() {
        save()
        publish()
        nowPlaying(force: true)
        maybeAutoplay()
        lineUpNext()
    }

    func publish() { objectWillChange.send(); WidgetBridge.shared.changed() }

    private var npKey: String?, npPlaying = false, npDuration = 0.0

    /// Tells iOS (lock screen, Control Centre, Dynamic Island, car) — only when something real changed, not every
    /// tick (constant updates made Bluetooth audio drop out on Android).
    private func nowPlaying(force: Bool = false) {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = current else { center.nowPlayingInfo = nil; npKey = nil; return }
        let d = duration
        guard force || npKey != t.key || npPlaying != playWhenReady || abs(npDuration - d) > 1 else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title, MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: d, MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playWhenReady ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let a = t.album { info[MPMediaItemPropertyAlbumTitle] = a }
        if npKey == t.key, let art = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] { info[MPMediaItemPropertyArtwork] = art }
        center.nowPlayingInfo = info
        let newSong = npKey != t.key
        npKey = t.key; npPlaying = playWhenReady; npDuration = d
        if newSong {
            Task {
                guard let img = await Images.shared.load(t.art, size: 300), self.current?.key == t.key else { return }
                var i = center.nowPlayingInfo ?? [:]
                i[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                center.nowPlayingInfo = i
            }
        }
    }

    /// Called every second while the app is on screen or playing: duration arrives late for streams.
    func tick() {
        if current != nil { nowPlaying() }
        if playWhenReady, !buffering, let t = current, heard?.track.key == t.key {
            heard!.ms += 1000
            let d = Int64(duration * 1000)
            if d > 0 { heard!.dur = d }
        }
        if mode == .native, playWhenReady, buffering, Date().timeIntervalSince(startedAt) > 25 { failed("This song didn't start") }
    }

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(e.positionTime) }
            return .success
        }
    }

    /// Calls and alarms pause us (and we play on after, when we were playing and iOS says to); unplugging headphones /
    /// AirPods out pauses.
    private func setUpAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? s.setActive(true)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: s, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let resume = ((n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []).contains(.shouldResume)
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.shared.write("audio interruption \(type == .began ? "began" : "ended")\(resume ? " (resume)" : "")")
                switch type {
                case .began:
                    // iOS has stopped the sound: show paused (and stop counting it as heard) until it hands back.
                    if self.playWhenReady { self.pause(); self.interrupted = true }
                case .ended:
                    if self.interrupted, resume { self.resume() }
                    self.interrupted = false
                default: break
                }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: s, queue: .main) { [weak self] n in
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable { Log.shared.write("headphones gone: pause"); self?.pause() }
            }
        }
    }

    // MARK: saved queue (what was playing comes back after a restart, paused)

    private struct Saved: Codable { var queue: [Track]; var index: Int; var shuffle: Bool; var repeatMode: Repeat; var position: Double; var original: [Track]? }

    func save() {
        AppDirs.save(Saved(queue: queue, index: index, shuffle: shuffle, repeatMode: repeatMode, position: position, original: original), "queue.json")
    }

    private func restore() {
        // A bad saved queue must never stop the app from starting.
        guard let s = AppDirs.load(Saved.self, "queue.json") else { return }
        var seen = Set<String>()
        queue = s.queue.filter { seen.insert($0.key).inserted }
        index = queue.isEmpty ? -1 : max(0, min(s.index, queue.count - 1))
        shuffle = s.shuffle
        original = s.original
        repeatMode = s.repeatMode
    }
}
