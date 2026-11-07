import SwiftUI

/// Where the app is: the page in the bar, each page's stack of opened pages, and the sheets.
@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()
    enum Tab: String, CaseIterable { case home = "Home", search = "Search", playlists = "Playlists" }

    @Published var tab: Tab = .home
    @Published var homePath = NavigationPath()
    @Published var searchPath = NavigationPath()
    @Published var playlistsPath = NavigationPath()
    @Published var playing = false
    @Published var settings = false
    @Published var eq = false
    @Published var addTo: Track?

    /// Tapping the page you're on goes back to its top.
    func go(_ t: Tab) {
        if t == tab {
            switch t {
            case .home: homePath = NavigationPath()
            case .search: searchPath = NavigationPath()
            case .playlists: playlistsPath = NavigationPath()
            }
        }
        tab = t
    }

    /// On a page opened from a tab (artist, album, mix) the pages step aside in the bar; only the player stays.
    var deep: Bool {
        switch tab {
        case .home: return !homePath.isEmpty
        case .search: return !searchPath.isEmpty
        case .playlists: return !playlistsPath.isEmpty
        }
    }
}

/// The app: the playing song's cover blurred behind everything, the three pages, the floating bar, Now playing.
struct ContentView: View {
    @ObservedObject private var nav = Nav.shared
    @ObservedObject private var player = Player.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            AmbientBackground(art: player.current?.art)
            ZStack {
                NavigationStack(path: $nav.homePath) { HomePage().browsable() }.opacity(nav.tab == .home ? 1 : 0).allowsHitTesting(nav.tab == .home)
                NavigationStack(path: $nav.searchPath) { SearchPage().browsable() }.opacity(nav.tab == .search ? 1 : 0).allowsHitTesting(nav.tab == .search)
                NavigationStack(path: $nav.playlistsPath) { PlaylistsPage().browsable() }.opacity(nav.tab == .playlists ? 1 : 0).allowsHitTesting(nav.tab == .playlists)
            }
            FloatingBar()
            if let m = player.message {
                Text(m).font(W.ui(13, .semibold)).foregroundStyle(W.text)
                    .padding(.horizontal, 16).padding(.vertical, 9).glass(20)
                    .padding(.bottom, 96)
                    .transition(.opacity).allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.message)
        .preferredColorScheme(.dark)
        .tint(W.lilac)
        // The hidden pages (YouTube's backup player, Spotify's search): a 1-point clipped box keeps them in the window.
        .background(alignment: .topLeading) { PageHost(views: [player.page.view, SpotifyPage.shared.view, SpotifyPage.shared.libraryView]).frame(width: 1, height: 1) }
        .fullScreenCover(isPresented: $nav.playing) { NowPlayingPage() }
        .sheet(isPresented: $nav.settings) { SettingsSheet() }
        .sheet(isPresented: $nav.eq) { EqualiserSheet().presentationDetents([.medium, .large]).presentationBackground(.ultraThinMaterial) }
        .sheet(item: $nav.addTo) { AddToPlaylistSheet(track: $0).presentationDetents([.medium, .large]).presentationBackground(.ultraThinMaterial) }
        // Songs sent with AirDrop or "Open in…" arrive as files; wreckbox:// links are test commands.
        .onOpenURL { url in if url.isFileURL { LocalFiles.importFiles([url]) } else { DevCommands.run(url) } }
        .task {
            DevCommands.fromLaunchArguments()
            Task {
                await Import.shared.auto()
                await HomeFeed.shared.refresh()
            }
            // Duration arrives late for streams; the lock screen hears about it here.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                player.tick()
            }
        }
    }
}

// MARK: - The bar

/// One floating pill in the widget's casing. Left, the pages (the current one on the candy capsule, with its name
/// when there's room); right, while a song is loaded, a small LCD (the song scrolling over the progress pixels — tap
/// it for Now playing) and the record play button. On opened pages only the player part shows.
struct FloatingBar: View {
    @ObservedObject private var nav = Nav.shared
    @ObservedObject private var player = Player.shared

    var body: some View {
        let showPlayer = player.current != nil
        let showPages = !(nav.deep && showPlayer)
        HStack(spacing: 6) {
            if showPages {
                HStack(spacing: 2) {
                    ForEach(Nav.Tab.allCases, id: \.self) { t in destination(t, label: !showPlayer) }
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
                if !showPlayer { Spacer(minLength: 0) }
            }
            if showPlayer {
                // The LCD sits in a well: shadow along its top, a light lip along its bottom.
                MiniLcd().onTapGesture { nav.playing = true }
                    .padding(EdgeInsets(top: 2, leading: 1.5, bottom: 1.5, trailing: 1.5))
                    .background(LinearGradient(colors: [.black.opacity(0.7), .black.opacity(0.25), .white.opacity(0.16)], startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                RecordButton(size: 48, playing: player.playing, buffering: player.buffering && player.playWhenReady) { player.toggle() }
            }
        }
        .padding(8)
        .frame(height: 64)
        .frame(maxWidth: showPages ? .infinity : 300)
        .casing(32)
        .padding(.horizontal, 14).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showPages)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showPlayer)
    }

    private func destination(_ t: Nav.Tab, label: Bool) -> some View {
        let on = nav.tab == t
        let icon = t == .home ? "house" : t == .search ? "magnifyingglass" : "music.note.list"
        return Button { nav.go(t) } label: {
            HStack(spacing: 7) {
                Image(systemName: on && t == .home ? "house.fill" : icon).font(.system(size: 19, weight: .semibold))
                if on && label { Text(t.rawValue.uppercased()).font(W.dot(11, .black)).tracking(1.2).lineLimit(1) }
            }
            .foregroundStyle(on ? Color(hex: 0x0A0A0C) : W.text2)
            .padding(.horizontal, 13)
            .frame(height: 48)
            .background { if on { Color.clear.candy() } }
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(t.rawValue)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The bar's LCD: the song's name scrolling in peach dots over the progress pixels.
struct MiniLcd: View {
    @ObservedObject private var player = Player.shared

    var body: some View {
        if let t = player.current {
            VStack(alignment: .leading, spacing: 4) {
                LedText(text: "\(t.title.uppercased())  ·  \(t.artist.uppercased())", size: 11)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    ProgressPixels(progress: player.duration > 0 ? min(1, player.position / player.duration) : 0, playing: player.playing)
                }
                .frame(height: 12)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46)
            .background { LcdFace() }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Now playing: \(t.title)")
            .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - Pieces

/// A page: big title, content, room at the bottom for the bar.
struct PageScaffold<Content: View, Trailing: View>: View {
    let title: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    HStack(alignment: .center) {
                        Text(title).font(W.ui(32, .heavy)).foregroundStyle(W.text).lineLimit(2)
                        Spacer()
                        trailing
                    }
                    .padding(.top, 8).padding(.bottom, 6)
                }
                content
            }
            .padding(.horizontal, 16).padding(.bottom, 110)
        }
        .scrollIndicators(.hidden)
    }
}

extension PageScaffold where Trailing == EmptyView {
    init(title: String?, @ViewBuilder content: () -> Content) { self.title = title; self.trailing = EmptyView(); self.content = content() }
}

struct Cover: View {
    let art: String?
    var size: CGFloat
    var radius: CGFloat = W.Radius.art
    var rim = false
    var circle = false
    @State private var image: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: circle ? size / 2 : radius, style: .continuous)
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                // No cover: the pixel record on the gradient, not a grey square.
                LinearGradient(colors: [W.lilac.opacity(0.35), W.blue.opacity(0.2), W.peach.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                PixelRecord(size: size * 0.5, tile: false).opacity(0.8)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08)))
        .overlay { if rim { shape.strokeBorder(W.iridescent, lineWidth: 2) } }
        .task(id: art) { image = await Images.shared.load(art, size: size) }
    }
}

struct SourceTag: View {
    let source: Source
    var body: some View {
        Text(source.tag).font(W.dot(9)).tracking(1).foregroundStyle(W.color(source))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(W.color(source).opacity(0.55), lineWidth: 0.8))
    }
}

/// A song row: tap to play (the rest of the list follows), ⋯ or long-press for the menu. Swipe it sideways: right →
/// add to queue, left → play next; in Up next either way removes it.
struct TrackRow: View {
    let track: Track
    var number: Int?
    /// The same song on other sources (search merges them).
    var alts: [Track] = []
    var inQueue: Int?
    var playlist: (id: String, index: Int)?
    var onTap: () -> Void
    @ObservedObject private var player = Player.shared
    @ObservedObject private var library = Library.shared
    @State private var dx: CGFloat = 0

    var body: some View {
        let isCurrent = player.current?.key == track.key
        ZStack {
            if dx != 0 {
                let right = dx > 0
                Text(inQueue != nil ? "Remove from queue" : right ? "Add to queue" : "Play next")
                    .font(W.ui(12.5, .bold)).foregroundStyle(W.text)
                    .frame(maxWidth: .infinity, alignment: right ? .leading : .trailing).padding(.horizontal, 18)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: W.Radius.row).fill(W.smart.opacity(min(0.5, abs(dx) / 200))))
            }
            HStack(spacing: 12) {
                if let number { Text(String(format: "%02d", number)).font(W.dot(11)).foregroundStyle(isCurrent ? W.peach : W.text3).frame(width: 22) }
                Cover(art: track.art, size: 46, radius: 8, rim: isCurrent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(W.ui(15, .semibold)).foregroundStyle(isCurrent ? W.peach : W.text).lineLimit(1)
                    HStack(spacing: 5) {
                        SourceTag(source: track.source)
                        ForEach(alts.map(\.source).filter { $0 != track.source }, id: \.self) { SourceTag(source: $0).opacity(0.7) }
                        Text([track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(W.ui(12.5)).foregroundStyle(W.text2).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if isCurrent && player.playing { DotSpectrum(live: true) }
                if library.isLiked(track) { Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(W.lilac) }
                Menu { menuItems } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold)).foregroundStyle(W.text2).frame(width: 30, height: 36).contentShape(Rectangle())
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: W.Radius.row).fill(isCurrent ? W.pressed : .clear))
            .contentShape(Rectangle())
            .offset(x: dx)
        }
        .onTapGesture(perform: onTap)
        .contextMenu { menuItems }
        .simultaneousGesture(DragGesture(minimumDistance: 20).onChanged { v in
            if abs(v.translation.width) > abs(v.translation.height) * 1.5 { dx = v.translation.width }
        }.onEnded { _ in
            let w = dx
            withAnimation(.spring(response: 0.3)) { dx = 0 }
            guard abs(w) > 90 else { return } // short swipes do nothing
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let i = inQueue { player.remove(at: i) } else if w > 0 { player.addToQueue(track) } else { player.playNext(track) }
        })
    }

    @ViewBuilder private var menuItems: some View {
        if inQueue == nil {
            Button("Play next", systemImage: "text.insert") { player.playNext(track) }
            Button("Add to queue", systemImage: "text.append") { player.addToQueue(track) }
        }
        Button(library.isLiked(track) ? "Unlike" : "Like", systemImage: library.isLiked(track) ? "heart.slash" : "heart") { library.toggleLike(track) }
        Button("Add to playlist…", systemImage: "music.note.list") { Nav.shared.addTo = track }
        Button("Song radio", systemImage: "dot.radiowaves.left.and.right") { player.startRadio(track) }
        ForEach(alts, id: \.key) { alt in Button("Play from \(alt.source.label)", systemImage: "play") { player.playList([alt]) } }
        if let i = inQueue {
            Divider()
            Button("Move up", systemImage: "arrow.up") { player.move(i, i - 1) }.disabled(i <= player.index + 1)
            Button("Move down", systemImage: "arrow.down") { player.move(i, i + 1) }.disabled(i >= player.queue.count - 1)
            Button("Remove from queue", systemImage: "minus.circle", role: .destructive) { player.remove(at: i) }
        }
        if let p = playlist {
            Divider()
            Button("Remove from playlist", systemImage: "minus.circle", role: .destructive) { library.remove(at: p.index, from: p.id) }
        }
        if track.source == .local {
            Divider()
            Button("Delete from phone", systemImage: "trash", role: .destructive) { LocalFiles.delete(track) }
        }
    }
}

/// A list of songs; tapping one plays the list from there.
struct TrackList: View {
    let tracks: [Track]
    var numbered = false
    var playlistID: String?

    var body: some View {
        LazyVStack(spacing: 2) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t, number: numbered ? i + 1 : nil, playlist: playlistID.map { ($0, i) }) { Player.shared.playList(tracks, start: i) }
            }
        }
    }
}

/// Play · Shuffle (· Radio), and a count.
struct PlayShuffle: View {
    let tracks: [Track]
    var radio: Track?

    var body: some View {
        HStack(spacing: 10) {
            Pill(label: "Play", icon: "play.fill", style: .primary, enabled: !tracks.isEmpty) { Player.shared.playList(tracks) }
            Pill(label: "Shuffle", icon: "shuffle", enabled: !tracks.isEmpty) { Player.shared.playList(tracks, shuffled: true) }
            if let radio { Pill(label: "Radio", icon: "dot.radiowaves.left.and.right", style: .smart) { Player.shared.startRadio(radio) } }
            Spacer()
            Text("\(tracks.count) songs").font(W.dot(11)).foregroundStyle(W.text3)
        }
        .padding(.vertical, 10)
    }
}

func clock(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "0:00" }
    let t = Int(s)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

/// Holds the hidden pages at their desktop size inside the clipped box.
struct PageHost: UIViewRepresentable {
    let views: [UIView]

    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.clipsToBounds = true
        box.isUserInteractionEnabled = false
        for v in views { v.frame = CGRect(x: 0, y: 0, width: 1280, height: 900); box.addSubview(v) }
        return box
    }

    func updateUIView(_ box: UIView, context: Context) {}
}
