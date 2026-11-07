import AVFoundation

/// The phone's own player for everything that is a plain audio file or link: YouTube direct streams and phone songs.
/// The next song is queued inside the player before this one ends, so it starts by itself with the screen locked
/// (an app with nothing playing may be suspended before it could start the next song).
@MainActor
final class NativeAudio {
    /// The song finished. `next` is the key of the queued song that started by itself, if there was one.
    var onEnd: ((_ next: String?) -> Void)?
    var onFail: ((_ key: String, _ why: String) -> Void)?
    var onStarted: (() -> Void)?

    private let player = AVQueuePlayer()
    private var keys: [ObjectIdentifier: String] = [:]
    private var itemObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var statusWatch: (ObjectIdentifier, NSKeyValueObservation)?
    private var observers: [NSKeyValueObservation] = []
    private(set) var currentKey: String?
    private(set) var queuedKey: String?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .advance
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.ended(id) }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.object as? AVPlayerItem).map(ObjectIdentifier.init)
            let err = (n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "playback failed"
            MainActor.assumeIsolated { self?.failed(id, err) }
        }
        observers.append(player.observe(\.timeControlStatus) { [weak self] p, _ in
            let playing = p.timeControlStatus == .playing
            MainActor.assumeIsolated { if playing { self?.onStarted?() } }
        })
    }

    var hasItem: Bool { player.currentItem != nil }
    var isPlaying: Bool { player.timeControlStatus == .playing }

    var position: Double {
        let s = player.currentTime().seconds
        return s.isFinite ? s : 0
    }

    var duration: Double {
        guard let item = player.currentItem else { return 0 }
        let end = item.forwardPlaybackEndTime.seconds
        if end.isFinite, end > 0 { return end }
        let d = item.duration.seconds
        return d.isFinite ? d : 0
    }

    /// Starts afresh with this song (anything queued is dropped). False when something else was started meanwhile.
    @discardableResult
    func load(_ url: URL, key: String, ends: Double? = nil) async -> Bool {
        loading = key
        let item = await makeItem(url, key, ends)
        guard loading == key else { return false }
        loading = nil
        player.removeAllItems()
        keys = [ObjectIdentifier(item): key]
        queuedKey = nil
        player.insert(item, after: nil)
        currentKey = key
        prune()
        return true
    }

    /// The song being prepared by `load` (the newest call wins).
    private var loading: String?

    /// Lines up the song after this one (replaces a different one queued earlier).
    func queue(_ url: URL, key: String, ends: Double? = nil) async {
        guard currentKey != nil, queuedKey != key else { return }
        let item = await makeItem(url, key, ends)
        guard currentKey != nil, queuedKey != key, let cur = player.items().first else { return }
        unqueue(prune: false)
        keys[ObjectIdentifier(item)] = key
        player.insert(item, after: cur)
        queuedKey = key
        prune()
    }

    /// Drops the lined-up song (the queue changed).
    func unqueue(prune clean: Bool = true) {
        for item in player.items().dropFirst() { keys[ObjectIdentifier(item)] = nil; player.remove(item) }
        queuedKey = nil
        if clean { prune() }
    }

    /// An item's status watcher goes with it.
    private func prune() { itemObservers = itemObservers.filter { keys[$0.key] != nil } }

    func play() { player.play() }
    func pause() { player.pause() }

    func stop() {
        loading = nil
        player.pause()
        player.removeAllItems()
        keys = [:]
        currentKey = nil
        queuedKey = nil
        prune()
    }

    func seek(_ s: Double) {
        player.seek(to: CMTime(seconds: s, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func makeItem(_ url: URL, _ key: String, _ ends: Double?) async -> AVPlayerItem {
        let asset = AVURLAsset(url: url, options: url.isFileURL ? nil : [AVURLAssetHTTPUserAgentKey: YouTubeStream.client.userAgent])
        let item = AVPlayerItem(asset: asset)
        // Ends here (and the queued song starts) even when the player thinks the file is longer.
        if let ends, ends > 1 { item.forwardPlaybackEndTime = CMTime(seconds: ends, preferredTimescale: 1000) }
        // Enough buffered to ride out a weak signal without holding minutes of audio.
        item.preferredForwardBufferDuration = 30
        // The EQ and the dot displays' measuring sit inside the item's audio (a stream's header takes a moment to read;
        // past 3 s it plays without them rather than wait).
        item.audioMix = try? await withTimeout(3) { await AudioTap.mix(for: asset, trackID: url.isFileURL ? nil : 1) }
        statusWatch = (ObjectIdentifier(item), item.observe(\.status) { [weak self] it, _ in
            guard it.status == .failed else { return }
            let id = ObjectIdentifier(it)
            let why = it.error?.localizedDescription ?? "couldn't open"
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.failed(id, why) } }
        })
        itemObservers[statusWatch!.0] = statusWatch!.1
        return item
    }

    private func ended(_ id: ObjectIdentifier?) {
        guard let id, let key = keys[id], key == currentKey else { return }
        keys[id] = nil
        prune()
        // The player has moved on to the queued song by itself (actionAtItemEnd = .advance).
        let next = queuedKey
        currentKey = next
        queuedKey = nil
        onEnd?(next)
    }

    private func failed(_ id: ObjectIdentifier?, _ why: String) {
        guard let id, let key = keys[id] else { return }
        if key == queuedKey {
            // The lined-up song can't play: drop it; it gets another go when its turn comes.
            unqueue()
            return
        }
        guard key == currentKey else { return }
        onFail?(key, why)
    }
}
