import SwiftUI

// The main pages in the WreckBox look: Home, Search, Playlists, Now playing, and the sheets (Settings, Equaliser,
// Add to playlist). (Port of the Android Player's pages.)

extension View {
    /// Every page can open artists, albums, playlists, mixes and moods.
    func browsable() -> some View {
        navigationDestination(for: Item.self) { DetailPage(item: $0) }
            .navigationDestination(for: Playlist.self) { p in YourPlaylistPage(id: p.id) }
            .navigationDestination(for: LibraryList.self) { l in LibraryListPage(list: l) }
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

/// Lists of your own songs a page can open.
enum LibraryList: Hashable { case liked, phone, recent }

// MARK: - Home

struct HomePage: View {
    @ObservedObject private var feed = HomeFeed.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var player = Player.shared
    @ObservedObject private var nav = Nav.shared
    @State private var signedIn = true
    @State private var phone = LocalFiles.tracks

    var body: some View {
        PageScaffold(title: nil) {
            HStack {
                Wordmark(size: 26)
                Spacer()
                RoundButton(icon: "gearshape", size: 38) { nav.settings = true }
            }
            .padding(.top, 6)
            Text(greeting.uppercased()).font(W.dot(26, .black)).tracking(1.5).foregroundStyle(W.smart).padding(.top, 18)
            if !signedIn {
                Button { nav.settings = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bring your music in").font(W.ui(17, .bold)).foregroundStyle(W.text)
                            Text("Sign in to YouTube Music and Spotify to search and play them here — and to bring your listening history in.")
                                .font(W.ui(13)).foregroundStyle(W.text2).multilineTextAlignment(.leading)
                        }
                        Spacer()
                        Image(systemName: "arrow.right").foregroundStyle(W.text)
                    }
                    .padding(18).smartGlass()
                }
                .buttonStyle(PressStyle()).padding(.top, 14)
            }
            quickTiles.padding(.top, 14)
            if feed.loading && feed.parts.isEmpty { ProgressView().tint(W.lilac).frame(maxWidth: .infinity).padding(.top, 24) }
            ForEach(["mixes", "because", "feed", "fresh", "rediscover", "charts"], id: \.self) { k in
                ForEach(Array((feed.parts[k] ?? []).enumerated()), id: \.offset) { i, shelf in
                    if k == "mixes" && i == 0 {
                        ShelfSection(shelf: shelf, action: feed.loading ? "Updating…" : "Refresh") { Task { await feed.refresh(force: true) } }
                    } else {
                        ShelfSection(shelf: shelf)
                    }
                }
            }
            if !library.data.likes.isEmpty {
                SectionHeader(title: "Liked songs · \(library.data.likes.count)", action: "All") { nav.homePath.append(LibraryList.liked) }
                PlayShuffle(tracks: library.data.likes)
                TrackList(tracks: Array(library.data.likes.prefix(5)))
            }
            if !library.data.playlists.isEmpty {
                SectionHeader(title: "Your playlists")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) { ForEach(library.data.playlists) { p in PlaylistTile(playlist: p) } }.padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
            if !library.data.recent.isEmpty {
                SectionHeader(title: "Recently played", action: "Clear") { library.clearRecent() }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(library.data.recent.prefix(15), id: \.key) { t in
                            ItemTile(item: .song(t, subtitle: t.artist, video: false), size: 120).pressable { player.playList([t]) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
            ForEach(Array((feed.parts["moods"] ?? []).enumerated()), id: \.offset) { _, shelf in ShelfSection(shelf: shelf) }
            if !phone.isEmpty {
                SectionHeader(title: "On this phone · \(phone.count)", action: "All") { nav.homePath.append(LibraryList.phone) }
                PlayShuffle(tracks: phone)
                TrackList(tracks: Array(phone.prefix(8)))
            }
        }
        .refreshable { await feed.refresh(force: true) }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            let yt = await Accounts.signedIn(.youtube)
            let sp = await Accounts.signedIn(.spotify)
            signedIn = yt || sp
        }
        .onReceive(NotificationCenter.default.publisher(for: .localFilesChanged)) { _ in phone = LocalFiles.tracks }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5...11: return "Good morning"
        case 12...16: return "Good afternoon"
        case 17...21: return "Good evening"
        default: return "Up late?"
        }
    }

    private struct Quick: Identifiable { let id: String; let title: String; let subtitle: String; let icon: String; let art: String?; let action: () -> Void }

    private var quickTiles: some View {
        let d = library.data
        var tiles: [Quick] = []
        if !d.likes.isEmpty { tiles.append(Quick(id: "liked", title: "Liked songs", subtitle: songs(d.likes.count), icon: "heart.fill", art: d.likes.first?.art) { player.playList(d.likes, shuffled: true) }) }
        let all = d.likes + phone + d.playlists.flatMap(\.tracks)
        if !all.isEmpty { tiles.append(Quick(id: "all", title: "Shuffle all", subtitle: songs(all.count), icon: "shuffle", art: nil) { player.playList(all, shuffled: true) }) }
        if let t = player.current {
            tiles.append(Quick(id: "now", title: player.playing ? "Now playing" : "Continue", subtitle: t.title, icon: player.playing ? "pause.fill" : "play.fill", art: t.art) { player.toggle() })
        }
        if let m = feed.parts["mixes"]?.first?.items.first, case .mix = m {
            tiles.append(Quick(id: "mix", title: m.title, subtitle: "Your mix", icon: "sparkles", art: m.art) { nav.homePath.append(m) })
        }
        if let p = d.playlists.max(by: { $0.updatedAt < $1.updatedAt }) {
            tiles.append(Quick(id: "pl", title: p.name, subtitle: songs(p.tracks.count), icon: "music.note.list", art: p.tracks.first?.art) { nav.homePath.append(p) })
        }
        if !phone.isEmpty { tiles.append(Quick(id: "phone", title: "On this phone", subtitle: songs(phone.count), icon: "iphone", art: nil) { player.playList(phone, shuffled: true) }) }
        let shown = Array(tiles.prefix(4))
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(shown) { q in
                HStack(spacing: 10) {
                    ZStack {
                        if let art = q.art { Cover(art: art, size: 58, radius: 0) } else {
                            W.smart.opacity(0.35)
                            Image(systemName: q.icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(W.text)
                        }
                    }
                    .frame(width: 58, height: 58).clipped()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.title).font(W.ui(14, .bold)).foregroundStyle(W.text).lineLimit(1)
                        Text(q.subtitle).font(W.ui(11.5)).foregroundStyle(W.text2).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .glass(14)
                .pressable(q.action)
            }
        }
    }

    private func songs(_ n: Int) -> String { n == 1 ? "1 song" : "\(n) songs" }
}

/// A shelf with its header.
struct ShelfSection: View {
    let shelf: Shelf
    var action: String?
    var onAction: (() -> Void)?

    var body: some View {
        SectionHeader(title: shelf.title, subtitle: shelf.subtitle, action: action, onAction: onAction)
        ShelfRow(shelf: shelf).padding(.horizontal, -16)
    }
}

struct PlaylistTile: View {
    let playlist: Playlist
    var body: some View {
        NavigationLink(value: playlist) {
            VStack(alignment: .leading, spacing: 6) {
                Cover(art: playlist.tracks.first?.art, size: 138, radius: W.Radius.tile)
                Text(playlist.name).font(W.ui(13.5, .semibold)).foregroundStyle(W.text).lineLimit(1)
                Text("\(playlist.tracks.count) songs").font(W.ui(11.5)).foregroundStyle(W.text3)
            }
            .frame(width: 138, alignment: .leading)
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Search

struct SearchPage: View {
    @State private var q = ""
    @State private var results: Search.Results?
    @State private var suggestions: (texts: [String], items: [Item]) = ([], [])
    @State private var typing: Task<Void, Never>?
    @State private var running: Task<Void, Never>?
    @State private var recent = RecentSearches.all
    @State private var filter = "All"
    @FocusState private var focused: Bool

    private static let filters = ["All", "Songs", "Artists", "Albums", "Playlists", "Phone", "YouTube", "Spotify"]

    var body: some View {
        PageScaffold(title: "Search") {
            searchBox.padding(.top, 6)
            if q.trimmingCharacters(in: .whitespaces).isEmpty {
                recentSection
            } else {
                if results != nil {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(Self.filters, id: \.self) { f in Chip(label: f, selected: filter == f) { filter = f } } }
                            .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, -16).padding(.top, 12)
                }
                if results?.done != true { suggestionSection }
                if let r = results { resultSections(r) }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .scrollDismissesKeyboard(.immediately)
    }

    private var searchBox: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(W.text2)
            TextField("", text: $q, prompt: Text("Songs, artists, lyrics").foregroundStyle(W.text3))
                .font(W.ui(16, .medium)).foregroundStyle(W.text)
                .focused($focused).submitLabel(.search).autocorrectionDisabled()
                .onSubmit { submit(q) }
                .onChange(of: q) { _, v in typed(v) }
            if !q.isEmpty {
                Button { q = ""; focused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(W.text3) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).frame(height: 48)
        .glass(16)
    }

    @ViewBuilder private var recentSection: some View {
        if !recent.isEmpty {
            SectionHeader(title: "Recent searches", action: "Clear") { RecentSearches.clear(); recent = [] }
            VStack(spacing: 0) {
                ForEach(recent, id: \.self) { r in
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(W.text3)
                        Text(r).font(W.ui(15, .medium)).foregroundStyle(W.text).lineLimit(1)
                        Spacer()
                        Button { RecentSearches.remove(r); recent = RecentSearches.all } label: { Image(systemName: "xmark").font(.caption).foregroundStyle(W.text3) }
                            .buttonStyle(.plain)
                    }
                    .padding(.vertical, 11).padding(.horizontal, 6)
                    .pressable { q = r; submit(r) }
                }
            }
        } else {
            VStack(spacing: 10) {
                PixelRecord(size: 56)
                Text("Search the phone, YouTube Music and Spotify").font(W.ui(15, .semibold)).foregroundStyle(W.text2)
                Text("By song, artist, or a line of the lyrics.").font(W.ui(13)).foregroundStyle(W.text3)
            }
            .frame(maxWidth: .infinity).padding(.top, 60)
        }
    }

    @ViewBuilder private var suggestionSection: some View {
        VStack(spacing: 0) {
            ForEach(suggestions.texts.prefix(5), id: \.self) { s in
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(W.text3)
                    Text(s).font(W.ui(15, .medium)).foregroundStyle(W.text).lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(W.text3)
                }
                .padding(.vertical, 10).padding(.horizontal, 6)
                .pressable { q = s; submit(s) }
            }
        }
        .padding(.top, 8)
        ForEach(suggestions.items.prefix(3)) { item in itemRow(item) }
    }

    private func show(_ section: String) -> Bool { filter == "All" || filter == section }

    @ViewBuilder private func resultSections(_ r: Search.Results) -> some View {
        if let c = r.corrected { Text("Showing results for “\(c)”").font(W.ui(13)).foregroundStyle(W.text2).padding(.top, 12) }
        if !r.failed.isEmpty { Text("Couldn't reach \(r.failed.joined(separator: ", "))").font(W.ui(12.5)).foregroundStyle(W.peach).padding(.top, 6) }
        if filter == "All", let top = r.top {
            SectionHeader(title: "Top result")
            topCard(top)
        }
        let hits = r.hits.filter { h in
            switch filter {
            case "Phone": return h.track.source == .local || h.alts.contains { $0.source == .local }
            case "YouTube": return h.track.source == .youtube || h.alts.contains { $0.source == .youtube }
            case "Spotify": return h.track.source == .spotify || h.alts.contains { $0.source == .spotify }
            default: return true
            }
        }
        if show("Songs") || ["Phone", "YouTube", "Spotify"].contains(filter) {
            SectionHeader(title: "Songs")
            LazyVStack(spacing: 2) {
                ForEach(Array(hits.prefix(filter == "All" ? 12 : 50).enumerated()), id: \.element.id) { i, h in
                    TrackRow(track: h.track, alts: h.alts) {
                        Player.shared.playList(hits.map(\.track), start: i, searched: r.query)
                        recent = RecentSearches.all
                    }
                }
            }
            if !r.done { ProgressView().tint(W.lilac).frame(maxWidth: .infinity).padding(.vertical, 10) }
        }
        if show("Artists"), !r.artists.isEmpty { ShelfSection(shelf: Shelf(title: "Artists", items: r.artists)) }
        if show("Albums"), !r.albums.isEmpty { ShelfSection(shelf: Shelf(title: "Albums & singles", items: r.albums)) }
        if show("Playlists"), !r.playlists.isEmpty { ShelfSection(shelf: Shelf(title: "Playlists", items: r.playlists)) }
    }

    @ViewBuilder private func topCard(_ item: Item) -> some View {
        let content = HStack(spacing: 14) {
            Cover(art: item.art, size: 84, radius: 12, circle: { if case .artist = item { true } else { false } }())
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(W.ui(19, .bold)).foregroundStyle(W.text).lineLimit(2)
                Text(item.subtitle).font(W.ui(13)).foregroundStyle(W.text2).lineLimit(2)
            }
            Spacer(minLength: 0)
            if item.track != nil { Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(W.smart) }
        }
        .padding(14).glass(W.Radius.card)
        if let t = item.track {
            content.pressable { Player.shared.playList([t], searched: q) }
        } else {
            NavigationLink(value: item) { content }.buttonStyle(PressStyle())
        }
    }

    @ViewBuilder private func itemRow(_ item: Item) -> some View {
        if let t = item.track {
            TrackRow(track: t) { Player.shared.playList([t], searched: q) }
        } else {
            NavigationLink(value: item) {
                HStack(spacing: 12) {
                    Cover(art: item.art, size: 46, circle: { if case .artist = item { true } else { false } }())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(W.ui(15, .semibold)).foregroundStyle(W.text).lineLimit(1)
                        Text(item.subtitle).font(W.ui(12.5)).foregroundStyle(W.text2).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(W.text3)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .buttonStyle(PressStyle())
        }
    }

    /// While typing: suggestions at once, results after a short pause.
    private func typed(_ text: String) {
        typing?.cancel()
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { running?.cancel(); results = nil; suggestions = ([], []); recent = RecentSearches.all; return }
        typing = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if let s = try? await YouTubeMusic.suggestions(query), !Task.isCancelled { suggestions = s }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            run(query)
        }
    }

    private func submit(_ text: String) {
        typing?.cancel()
        focused = false
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        RecentSearches.add(query)
        run(query)
    }

    private func run(_ query: String) {
        running?.cancel()
        running = Task {
            for await r in Search.stream(query) {
                guard !Task.isCancelled else { return }
                results = r
            }
        }
    }
}

// MARK: - Playlists (your music)

struct PlaylistsPage: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var nav = Nav.shared
    @State private var phone = LocalFiles.tracks
    @State private var newPlaylist = false
    @State private var newName = ""
    @State private var pickingSongs = false

    var body: some View {
        PageScaffold(title: "Playlists") {
            Pill(label: "New", icon: "plus", style: .smart) { newPlaylist = true }
        } content: {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                bigTile("Liked songs", "\(library.data.likes.count) songs", "heart.fill", library.data.likes.first?.art) { nav.playlistsPath.append(LibraryList.liked) }
                bigTile("On this phone", "\(phone.count) songs", "iphone", phone.first?.art) { nav.playlistsPath.append(LibraryList.phone) }
            }
            .padding(.top, 10)
            SectionHeader(title: "Your playlists")
            if library.data.playlists.isEmpty {
                Text("Make one with New, or long-press any song → Add to playlist. Albums and playlists from YouTube Music can be saved here too.")
                    .font(W.ui(13.5)).foregroundStyle(W.text3)
            }
            LazyVStack(spacing: 4) {
                ForEach(library.data.playlists) { p in
                    NavigationLink(value: p) {
                        HStack(spacing: 12) {
                            Cover(art: p.tracks.first?.art, size: 56, radius: 10)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(W.ui(16, .semibold)).foregroundStyle(W.text).lineLimit(1)
                                Text("\(p.tracks.count) songs").font(W.dot(10.5)).foregroundStyle(W.text3)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(W.text3)
                        }
                        .padding(8)
                    }
                    .buttonStyle(PressStyle())
                    .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { library.deletePlaylist(p.id) } }
                }
            }
            SectionHeader(title: "Songs on this phone")
            Text("Add songs from Files, AirDrop them to the app, or put them in Files → On My iPhone → WreckBox Player → Music.")
                .font(W.ui(13)).foregroundStyle(W.text3)
            Pill(label: "Add songs from Files", icon: "plus") { pickingSongs = true }.padding(.top, 10)
            if !library.data.recent.isEmpty {
                SectionHeader(title: "Recently played", action: "All") { nav.playlistsPath.append(LibraryList.recent) }
                TrackList(tracks: Array(library.data.recent.prefix(6)))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onReceive(NotificationCenter.default.publisher(for: .localFilesChanged)) { _ in phone = LocalFiles.tracks }
        .alert("New playlist", isPresented: $newPlaylist) {
            TextField("Name", text: $newName)
            Button("Create") { library.createPlaylist(newName); newName = "" }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .fileImporter(isPresented: $pickingSongs, allowedContentTypes: [.audio], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { LocalFiles.importFiles(urls) }
        }
    }

    private func bigTile(_ title: String, _ sub: String, _ icon: String, _ art: String?, _ action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                if let art { Cover(art: art, size: 160, radius: 0).frame(maxWidth: .infinity).frame(height: 110).clipped() }
                else { W.smart.opacity(0.3).frame(height: 110) }
                Image(systemName: icon).font(.system(size: 22, weight: .bold)).foregroundStyle(.white).padding(12).shadow(radius: 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(title).font(W.ui(15, .bold)).foregroundStyle(W.text)
            Text(sub).font(W.dot(10.5)).foregroundStyle(W.text3)
        }
        .padding(10).glass(W.Radius.tile)
        .pressable(action)
    }
}

struct LibraryListPage: View {
    let list: LibraryList
    @ObservedObject private var library = Library.shared
    @State private var phone = LocalFiles.tracks

    var body: some View {
        let (title, tracks, empty): (String, [Track], String) = {
            switch list {
            case .liked: return ("Liked songs", library.data.likes, "Songs you ♥ show up here.")
            case .phone: return ("On this phone", phone, "No songs on this phone yet.")
            case .recent: return ("Recently played", library.data.recent, "Nothing played yet.")
            }
        }()
        PageScaffold(title: title) {
            PlayShuffle(tracks: tracks)
            if tracks.isEmpty { Text(empty).font(W.ui(14)).foregroundStyle(W.text3).padding(.top, 20) }
            TrackList(tracks: tracks)
        }
        .onReceive(NotificationCenter.default.publisher(for: .localFilesChanged)) { _ in phone = LocalFiles.tracks }
    }
}

struct YourPlaylistPage: View {
    let id: String
    @ObservedObject private var library = Library.shared
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        if let p = library.playlist(id) {
            PageScaffold(title: p.name) {
                Menu {
                    Button("Rename", systemImage: "pencil") { name = p.name; renaming = true }
                    Button("Delete", systemImage: "trash", role: .destructive) { library.deletePlaylist(id); dismiss() }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 22)).foregroundStyle(W.text2) }
            } content: {
                Cover(art: p.tracks.first?.art, size: 200, radius: W.Radius.card, rim: true).frame(maxWidth: .infinity).padding(.vertical, 8)
                PlayShuffle(tracks: p.tracks)
                if p.tracks.isEmpty { Text("Long-press any song → Add to playlist.").font(W.ui(14)).foregroundStyle(W.text3) }
                TrackList(tracks: p.tracks, playlistID: id)
            }
            .alert("Rename playlist", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Save") { library.renamePlaylist(id, name) }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            Text("This playlist is gone").font(W.ui(15)).foregroundStyle(W.text3)
        }
    }
}

// MARK: - Now playing

struct NowPlayingPage: View {
    @ObservedObject private var player = Player.shared
    @ObservedObject private var library = Library.shared
    @ObservedObject private var eq = EQ.shared
    @ObservedObject private var nav = Nav.shared
    @Environment(\.dismiss) private var dismiss
    @State private var dragging: Double?
    @State private var pull: CGFloat = 0

    var body: some View {
        ZStack {
            AmbientBackground(art: player.current?.art)
            if let t = player.current {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        GeometryReader { g in
                            Cover(art: t.art, size: g.size.width, radius: W.Radius.card, rim: true)
                                .shadow(color: W.lilac.opacity(0.35), radius: 30, y: 10)
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .padding(.horizontal, 30).padding(.top, 10)
                        titleRow(t).padding(.top, 22)
                        lcd(t).padding(.top, 16)
                        seekBar.padding(.top, 14)
                        transport.padding(.top, 6)
                        let shaped = eq.on && eq.preset != "Flat"
                        Pill(label: shaped ? "EQ · \(eq.preset)" : "Equaliser", icon: "slider.vertical.3", style: shaped ? .smart : .glass) { nav.eq = true }
                            .padding(.top, 12)
                        upNext.padding(.top, 8)
                    }
                    .padding(.horizontal, 18).padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
            } else {
                VStack(spacing: 12) {
                    PixelRecord(size: 72)
                    Text("Nothing playing").font(W.ui(18, .bold)).foregroundStyle(W.text)
                    Text("Find something in Search.").font(W.ui(14)).foregroundStyle(W.text2)
                    Pill(label: "Close", style: .glass) { dismiss() }
                }
            }
        }
        .offset(y: max(0, pull))
        .gesture(DragGesture().onChanged { v in if v.translation.height > 0 && abs(v.translation.width) < v.translation.height { pull = v.translation.height } }
            .onEnded { v in if v.translation.height > 140 { dismiss() }; withAnimation(.spring) { pull = 0 } })
        .preferredColorScheme(.dark)
        .sheet(isPresented: $nav.eq) { EqualiserSheet().presentationDetents([.medium, .large]).presentationBackground(.ultraThinMaterial) }
        .sheet(item: $nav.addTo) { AddToPlaylistSheet(track: $0).presentationDetents([.medium, .large]).presentationBackground(.ultraThinMaterial) }
    }

    private var header: some View {
        HStack {
            RoundButton(icon: "chevron.down", size: 38) { dismiss() }
            Spacer()
            DotLabel("Now playing", color: W.text2, size: 11)
            Spacer()
            RoundButton(icon: "music.note.list", size: 38) { if let t = player.current { nav.addTo = t } }
        }
        .padding(.top, 6)
    }

    private func titleRow(_ t: Track) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).font(W.ui(24, .bold)).foregroundStyle(W.text).lineLimit(2)
                Text(t.artist).font(W.ui(16)).foregroundStyle(W.text2).lineLimit(1)
            }
            Spacer()
            let liked = library.isLiked(t)
            Button { library.toggleLike(t); UIImpactFeedbackGenerator(style: .light).impactOccurred() } label: {
                Image(systemName: liked ? "heart.fill" : "heart").font(.system(size: 24)).foregroundStyle(liked ? W.peach : W.text)
            }
            .buttonStyle(PressStyle())
        }
    }

    /// The LCD: clock, track counter, source and format.
    private func lcd(_ t: Track) -> some View {
        Lcd {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                HStack(alignment: .center) {
                    LcdText(text: clock(dragging.map { $0 * player.duration } ?? player.position), ghost: "88:88", size: 26)
                    Text("/ \(clock(player.duration))").font(W.dot(13)).foregroundStyle(W.peach.opacity(0.5))
                    Spacer()
                    DotSpectrum(live: player.playing, cols: 8, rows: 5, dot: 3.5, gap: 1.5)
                }
            }
            HStack(spacing: 6) {
                Text(String(format: "TRK %03d/%03d", player.index + 1, player.queue.count)).font(W.dot(10)).tracking(1).foregroundStyle(W.lilac)
                Spacer()
                LcdBadge(text: t.source == .local ? "PHONE" : t.source == .youtube ? "YT MUSIC" : "SPOTIFY")
                if player.shuffle { LcdBadge(text: "SHUF") }
                if player.repeatMode != .off { LcdBadge(text: player.repeatMode == .one ? "RPT 1" : "RPT") }
            }
            Text(player.quality ?? (player.buffering ? "Loading…" : "—")).font(W.dot(11)).tracking(0.8).foregroundStyle(W.blue.opacity(0.9)).lineLimit(1)
        }
    }

    private var seekBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let d = max(player.duration, 1)
            let p = dragging ?? min(1, player.position / d)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1)).frame(height: 5)
                    Capsule().fill(W.smart).frame(width: max(5, g.size.width * p), height: 5)
                    Circle().fill(.white).frame(width: dragging == nil ? 13 : 20).shadow(color: W.peach.opacity(0.6), radius: 6)
                        .offset(x: g.size.width * p - (dragging == nil ? 6.5 : 10))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in dragging = max(0, min(1, v.location.x / g.size.width)) }
                    .onEnded { _ in if let x = dragging { player.seek(x * d) }; dragging = nil })
            }
            .frame(height: 30)
        }
    }

    private var transport: some View {
        HStack {
            Button { player.setShuffle(!player.shuffle) } label: { Image(systemName: "shuffle").font(.system(size: 20, weight: .semibold)).foregroundStyle(player.shuffle ? W.lilac : W.text3) }
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)).foregroundStyle(W.text) }
            Spacer()
            RecordButton(size: 80, playing: player.playing, buffering: player.buffering && player.playWhenReady) { player.toggle() }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)).foregroundStyle(W.text) }
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? W.text3 : W.lilac)
            }
        }
        .buttonStyle(PressStyle())
        .padding(.horizontal, 6)
    }

    /// Up next: what you queued, then what autoplay added (similar songs).
    @ViewBuilder private var upNext: some View {
        let upcoming = player.queue.enumerated().filter { $0.offset > player.index }
        let mine = upcoming.filter { !player.radioKeys.contains($0.element.key) }
        let auto = upcoming.filter { player.radioKeys.contains($0.element.key) }
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Up next")
            if upcoming.isEmpty && !player.radioLoading {
                Text(Prefs.autoplay ? "Nothing after this song." : "Nothing after this song — Autoplay is off (Settings).").font(W.ui(13)).foregroundStyle(W.text3)
            }
            LazyVStack(spacing: 2) {
                ForEach(mine, id: \.element.key) { i, t in TrackRow(track: t, inQueue: i) { player.jump(to: i) } }
            }
            if !auto.isEmpty || player.radioLoading {
                SectionHeader(title: "Autoplay · like \(player.radioFrom ?? player.current?.title ?? "")", action: auto.isEmpty ? nil : "Clear") { player.clearAutoplay() }
                if player.radioLoading && auto.isEmpty {
                    HStack(spacing: 10) { ProgressView().tint(W.lilac); Text("Finding similar songs…").font(W.ui(13)).foregroundStyle(W.text2) }
                }
                LazyVStack(spacing: 2) {
                    ForEach(auto, id: \.element.key) { i, t in TrackRow(track: t, inQueue: i) { player.jump(to: i) } }
                }
            }
        }
    }
}

// MARK: - Sheets

struct EqualiserSheet: View {
    @ObservedObject private var eq = EQ.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Equaliser").font(W.ui(22, .heavy)).foregroundStyle(W.text)
                Spacer()
                Toggle("", isOn: Binding(get: { eq.on }, set: { eq.setOn($0) })).labelsHidden().tint(W.lilac)
            }
            Lcd {
                EqDots(gains: eq.gains, on: eq.on) { i, db in eq.setBand(i, db) }.frame(height: 150)
                HStack(spacing: 0) { ForEach(EQ.labels, id: \.self) { Text($0).font(W.dot(9)).foregroundStyle(W.text3).frame(maxWidth: .infinity) } }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { ForEach(EQ.presets, id: \.0) { p in Chip(label: p.0, selected: eq.preset == p.0) { eq.choose(p.0) } } }
            }
            Text("Drag on the dots to shape it. Works on YouTube songs and songs on this phone.").font(W.ui(12.5)).foregroundStyle(W.text3)
            Spacer(minLength: 0)
        }
        .padding(20)
        .preferredColorScheme(.dark)
    }
}

struct AddToPlaylistSheet: View {
    let track: Track
    @ObservedObject private var library = Library.shared
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to playlist").font(W.ui(22, .heavy)).foregroundStyle(W.text)
            HStack(spacing: 10) {
                Cover(art: track.art, size: 40)
                Text(track.title).font(W.ui(14, .semibold)).foregroundStyle(W.text2).lineLimit(1)
            }
            HStack {
                TextField("", text: $newName, prompt: Text("New playlist").foregroundStyle(W.text3)).font(W.ui(15)).foregroundStyle(W.text)
                Pill(label: "Create", icon: "plus", style: .primary, enabled: !newName.trimmingCharacters(in: .whitespaces).isEmpty) {
                    library.createPlaylist(newName, tracks: [track]); dismiss()
                }
            }
            .padding(.leading, 14).padding(6).glass(16)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(library.data.playlists) { p in
                        let has = p.tracks.contains { $0.key == track.key }
                        HStack(spacing: 12) {
                            Cover(art: p.tracks.first?.art, size: 44)
                            Text(p.name).font(W.ui(15, .semibold)).foregroundStyle(W.text)
                            Spacer()
                            Image(systemName: has ? "checkmark.circle.fill" : "plus.circle").foregroundStyle(has ? W.lilac : W.text2)
                        }
                        .padding(6)
                        .pressable { if !has { library.add(track, to: p.id) }; dismiss() }
                    }
                }
            }
        }
        .padding(20)
        .preferredColorScheme(.dark)
    }
}

struct SettingsSheet: View {
    @ObservedObject private var history = History.shared
    @ObservedObject private var importer = Import.shared
    @Environment(\.dismiss) private var dismiss
    @State private var signingIn: Accounts.Service?
    @State private var signedIn: Set<String> = []
    @State private var pickingFile = false
    @State private var autoplay = Prefs.autoplay
    @State private var blockAds = Prefs.blockAds
    @State private var liveActivity = Prefs.liveActivity

    var body: some View {
        NavigationStack {
            ZStack {
                W.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(title: "Accounts")
                        VStack(spacing: 0) {
                            ForEach([Accounts.Service.youtube, .spotify], id: \.rawValue) { s in
                                row(s.rawValue, signedIn.contains(s.rawValue) ? "Signed in" : "Not signed in") {
                                    if signedIn.contains(s.rawValue) {
                                        Pill(label: "Sign out") { Task { await Accounts.signOut(s); await refreshAccounts() } }
                                    } else {
                                        Pill(label: "Sign in", style: .primary) { signingIn = s }
                                    }
                                }
                            }
                        }
                        .glass(W.Radius.tile)
                        Text("Spotify songs play from their YouTube Music match — free, no ads.").font(W.ui(12)).foregroundStyle(W.text3).padding(.top, 8)

                        SectionHeader(title: "Listening history")
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("\(history.plays) plays · \(history.data.songs.count) songs").font(W.dot(12)).foregroundStyle(W.peach)
                                Spacer()
                                Text("kept on this phone").font(W.ui(12)).foregroundStyle(W.text3)
                            }
                            if let s = importer.status { Text(s).font(W.ui(12.5)).foregroundStyle(W.text2) }
                            HStack(spacing: 8) {
                                if signedIn.contains(Accounts.Service.youtube.rawValue) {
                                    Pill(label: "From YouTube", icon: "arrow.down") { Task { try? await importer.youtube(); await HomeFeed.shared.refresh(force: true) } }
                                }
                                if signedIn.contains(Accounts.Service.spotify.rawValue) {
                                    Pill(label: "From Spotify", icon: "arrow.down") { Task { try? await importer.spotify(); await HomeFeed.shared.refresh(force: true) } }
                                }
                            }
                            HStack(spacing: 8) {
                                Pill(label: "Import a file", icon: "doc") { pickingFile = true }
                                Pill(label: "Clear") { history.clear() }
                            }
                            Text("Spotify: Account privacy → Download your data → Extended streaming history. Google Takeout: YouTube history as JSON.")
                                .font(W.ui(12)).foregroundStyle(W.text3)
                        }
                        .padding(14).glass(W.Radius.tile)

                        SectionHeader(title: "Playback")
                        VStack(spacing: 0) {
                            toggle("Autoplay similar songs", "When the queue runs out", $autoplay) { Player.shared.setAutoplay($0) }
                            toggle("Block ads", "In YouTube's backup player (direct songs have none)", $blockAds) { Prefs.blockAds = $0 }
                            toggle("Live Activity", "Now playing on the lock screen and in the Dynamic Island", $liveActivity) {
                                Prefs.liveActivity = $0
                                LiveActivityBridge.shared.resync()
                            }
                        }
                        .glass(W.Radius.tile)

                        SectionHeader(title: "About")
                        VStack(alignment: .leading, spacing: 8) {
                            Wordmark(size: 22)
                            Text("WreckBox Player for iPhone \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                                .font(W.ui(13)).foregroundStyle(W.text2)
                            NavigationLink { LogPage() } label: { Text("Test log").font(W.ui(13, .semibold)).foregroundStyle(W.lilac) }
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading).glass(W.Radius.tile)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 30)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.font(W.ui(15, .semibold)) }
        }
        .preferredColorScheme(.dark)
        .task { await refreshAccounts() }
        .sheet(item: $signingIn) { s in
            NavigationStack {
                SignInSheet(service: s) {
                    signingIn = nil
                    Task {
                        await refreshAccounts()
                        await Import.shared.auto()
                        await HomeFeed.shared.refresh(force: true)
                    }
                }
                .navigationTitle("Sign in to \(s.rawValue)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { signingIn = nil; Task { await refreshAccounts() } } }
            }
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.json, .zip]) { r in
            if case .success(let url) = r { Task { await importer.file(url); await HomeFeed.shared.refresh(force: true) } }
        }
    }

    private func row<Trailing: View>(_ title: String, _ sub: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(W.ui(15, .semibold)).foregroundStyle(W.text)
                Text(sub).font(W.ui(12)).foregroundStyle(W.text3)
            }
            Spacer()
            trailing()
        }
        .padding(14)
    }

    private func toggle(_ title: String, _ sub: String, _ value: Binding<Bool>, _ set: @escaping (Bool) -> Void) -> some View {
        row(title, sub) {
            Toggle("", isOn: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; set($0) })).labelsHidden().tint(W.lilac)
        }
    }

    private func refreshAccounts() async {
        var s = Set<String>()
        for a in [Accounts.Service.youtube, .spotify] where await Accounts.signedIn(a) { s.insert(a.rawValue) }
        signedIn = s
    }
}

extension Accounts.Service: Identifiable { var id: String { rawValue } }

/// What the player did (test builds).
struct LogPage: View {
    @ObservedObject private var log = Log.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { i, l in Text(l).font(.caption2.monospaced()).foregroundStyle(W.text2).id(i) }
                }
                .padding(12)
            }
            .onAppear { proxy.scrollTo(log.lines.count - 1) }
        }
        .background(W.bg)
        .navigationTitle("Test log")
    }
}
