import SwiftUI

/// Pages you open from a tile or a row: artist, album / playlist, one of our mixes, a mood or genre. (Port of the
/// Android Player's Browse.)
struct DetailPage: View {
    let item: Item

    var body: some View {
        switch item {
        case .artist(let id, let title, _, _): ArtistPage(id: id, name: title)
        case .album(let id, let title, _, _, _), .playlist(let id, let title, _, _): CollectionPage(id: id, title: title)
        case .mix(_, let title, let subtitle, let tracks): MixPage(title: title, subtitle: subtitle, tracks: tracks)
        case .mood(let id, let params, let title, _): BrowsePage(id: id, params: params, title: title)
        case .song(let t, _, _): MixPage(title: t.title, subtitle: t.artist, tracks: [t])
        }
    }
}

/// Loading / couldn't load, in the look.
private struct Waiting: View {
    let failed: Bool
    var body: some View {
        VStack(spacing: 12) {
            if failed {
                Text("Couldn't load this").font(W.ui(15, .semibold)).foregroundStyle(W.text2)
                Text("Check the connection and try again.").font(W.ui(13)).foregroundStyle(W.text3)
            } else {
                PixelRecord(size: 44, tile: false, spinning: true)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

struct ArtistPage: View {
    let id: String
    let name: String
    @State private var page: YouTubeMusic.ArtistPage?
    @State private var failed = false
    @State private var aboutOpen = false

    var body: some View {
        PageScaffold(title: nil) {
            if let p = page {
                VStack(spacing: 10) {
                    Cover(art: p.art, size: 190, rim: true, circle: true).shadow(color: W.lilac.opacity(0.35), radius: 24)
                    Text(p.name).font(W.ui(30, .heavy)).foregroundStyle(W.text).multilineTextAlignment(.center)
                    if !p.listeners.isEmpty { Text(p.listeners.uppercased()).font(W.dot(11)).tracking(1.2).foregroundStyle(W.peach) }
                }
                .frame(maxWidth: .infinity).padding(.top, 4)
                PlayShuffle(tracks: p.songs, radio: p.songs.first)
                SectionHeader(title: "Top songs", action: p.songsPlaylist == nil ? nil : "All songs") {
                    if let all = p.songsPlaylist { Nav.shared.push(.playlist(id: all, title: "\(p.name): all songs", subtitle: "", art: p.art)) }
                }
                TrackList(tracks: p.songs, numbered: true)
                ForEach(p.shelves) { s in ShelfSection(shelf: s) }
                if !p.about.isEmpty {
                    SectionHeader(title: "About")
                    Text(p.about).font(W.ui(14)).foregroundStyle(W.text2).lineLimit(aboutOpen ? nil : 4)
                        .padding(14).glass(W.Radius.tile)
                        .onTapGesture { withAnimation { aboutOpen.toggle() } }
                }
            } else {
                Waiting(failed: failed)
            }
        }
        .navigationTitle(page?.name ?? name).navigationBarTitleDisplayMode(.inline)
        .task { do { page = try await YouTubeMusic.artist(id) } catch { failed = true } }
    }
}

struct CollectionPage: View {
    let id: String
    let title: String
    @State private var c: YouTubeMusic.Collection?
    @State private var failed = false
    @State private var saved = false

    var body: some View {
        PageScaffold(title: nil) {
            if let c {
                VStack(spacing: 10) {
                    Cover(art: c.art, size: 220, radius: W.Radius.card, rim: true).shadow(color: W.lilac.opacity(0.35), radius: 24)
                    Text(c.title).font(W.ui(24, .heavy)).foregroundStyle(W.text).multilineTextAlignment(.center)
                    Text(c.subtitle).font(W.ui(13)).foregroundStyle(W.text2).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.top, 4)
                PlayShuffle(tracks: c.tracks)
                Pill(label: saved ? "Saved to your playlists" : "Save as your playlist", icon: saved ? "checkmark" : "plus", style: saved ? .glass : .smart, enabled: !saved) {
                    Library.shared.createPlaylist(c.title, tracks: c.tracks)
                    saved = true
                }
                .padding(.bottom, 6)
                TrackList(tracks: c.tracks, numbered: id.hasPrefix("MPRE"))
            } else {
                Waiting(failed: failed)
            }
        }
        .navigationTitle(c?.title ?? title).navigationBarTitleDisplayMode(.inline)
        .task { do { c = try await YouTubeMusic.collection(id) } catch { failed = true } }
    }
}

/// Songs that are already here: one of our mixes.
struct MixPage: View {
    let title: String
    let subtitle: String
    let tracks: [Track]

    var body: some View {
        PageScaffold(title: title) {
            if !subtitle.isEmpty { Text(subtitle).font(W.ui(14)).foregroundStyle(W.text2) }
            Mosaic(arts: tracks.compactMap(\.art), size: 220).frame(maxWidth: .infinity).padding(.vertical, 12)
            PlayShuffle(tracks: tracks)
            TrackList(tracks: tracks)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A browse page made of shelves (a mood, a genre).
struct BrowsePage: View {
    let id: String
    let params: String
    let title: String
    @State private var shelves: [Shelf]?

    var body: some View {
        PageScaffold(title: title) {
            if let shelves {
                if shelves.isEmpty { Waiting(failed: true) }
                ForEach(shelves) { s in ShelfSection(shelf: s) }
            } else {
                Waiting(failed: false)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { shelves = (try? await YouTubeMusic.shelves(id, params: params.isEmpty ? nil : params)) ?? [] }
    }
}

/// A shelf: a sideways row of tiles. A song plays with the shelf's other songs after it; anything else opens.
struct ShelfRow: View {
    let shelf: Shelf

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(shelf.items) { item in
                    if let t = item.track {
                        ItemTile(item: item)
                            .pressable {
                                let songs = shelf.items.compactMap(\.track)
                                Player.shared.playList(songs, start: songs.firstIndex { $0.key == t.key } ?? 0)
                            }
                            .contextMenu {
                                Button("Play next", systemImage: "text.insert") { Player.shared.playNext(t) }
                                Button("Add to queue", systemImage: "text.append") { Player.shared.addToQueue(t) }
                                Button(Library.shared.isLiked(t) ? "Unlike" : "Like", systemImage: "heart") { Library.shared.toggleLike(t) }
                                Button("Add to playlist…", systemImage: "music.note.list") { Nav.shared.addTo = t }
                                Button("Song radio", systemImage: "dot.radiowaves.left.and.right") { Player.shared.playList([t]) }
                            }
                    } else {
                        NavigationLink(value: item) { ItemTile(item: item) }.buttonStyle(PressStyle())
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 2)
        }
    }
}

struct ItemTile: View {
    let item: Item
    var size: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch item {
            case .mood(_, _, let title, let color):
                Text(title).font(W.ui(15, .bold)).foregroundStyle(.white).padding(12)
                    .frame(width: 160, height: 72, alignment: .bottomLeading)
                    .background {
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(W.glassFill)
                            Rectangle().fill(Color(argb: color)).frame(width: 6)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .glass(14)
            case .artist:
                Cover(art: item.art, size: size, circle: true)
                Text(item.title).font(W.ui(13.5, .semibold)).foregroundStyle(W.text).lineLimit(1).frame(width: size)
            case .mix(_, _, _, let tracks):
                Mosaic(arts: tracks.compactMap(\.art), size: size)
                Text(item.title).font(W.ui(13.5, .semibold)).foregroundStyle(W.text).lineLimit(1)
                Text(item.subtitle).font(W.ui(11.5)).foregroundStyle(W.text3).lineLimit(2)
            default:
                Cover(art: item.art, size: size, radius: W.Radius.tile)
                Text(item.title).font(W.ui(13.5, .semibold)).foregroundStyle(W.text).lineLimit(2)
                Text(item.subtitle).font(W.ui(11.5)).foregroundStyle(W.text3).lineLimit(1)
            }
        }
        .frame(width: { if case .mood = item { 160 } else { size } }(), alignment: .leading)
    }
}

/// Four covers in a square (our mixes), with the iridescent rim.
struct Mosaic: View {
    let arts: [String]
    let size: CGFloat

    var body: some View {
        let unique = Array(NSOrderedSet(array: arts).array as? [String] ?? []).prefix(4)
        Group {
            if unique.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { Cover(art: unique[0], size: size / 2, radius: 0); Cover(art: unique[1], size: size / 2, radius: 0) }
                    HStack(spacing: 0) { Cover(art: unique[2], size: size / 2, radius: 0); Cover(art: unique[3], size: size / 2, radius: 0) }
                }
            } else {
                Cover(art: unique.first, size: size, radius: 0)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: W.Radius.tile, style: .continuous))
        .iridescentRim(W.Radius.tile)
    }
}

extension Color {
    /// 0xAARRGGBB, as YouTube gives mood colours.
    init(argb: Int64) {
        self.init(red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255, blue: Double(argb & 0xFF) / 255)
    }
}

extension Nav {
    /// Opens a page on the current tab.
    func push(_ item: Item) {
        switch tab {
        case .home: homePath.append(item)
        case .search: searchPath.append(item)
        case .playlists: playlistsPath.append(item)
        }
    }
}
