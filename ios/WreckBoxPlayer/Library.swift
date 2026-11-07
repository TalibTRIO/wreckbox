import Foundation
import Combine

/// Where a track plays from.
enum Source: String, Codable, CaseIterable {
    case local = "LOCAL", youtube = "YOUTUBE", spotify = "SPOTIFY"
    var label: String { switch self { case .local: return "Phone"; case .youtube: return "YouTube"; case .spotify: return "Spotify" } }
    var tag: String { switch self { case .local: return "PHONE"; case .youtube: return "YOUTUBE"; case .spotify: return "SPOTIFY" } }
}

/// A song from any source. `id` is the source's own id: a file name, a YouTube video id, a Spotify track id.
struct Track: Codable, Hashable, Identifiable {
    var source: Source
    var id: String
    var title: String
    var artist: String
    var album: String?
    var durationMs: Int64 = 0
    var art: String?

    /// One per song. A song without an id (Spotify's short export has none) goes by its name instead.
    var key: String { id.isEmpty ? "\(source.rawValue):~\(Radio.name(self))" : "\(source.rawValue):\(id)" }
    var duration: Double { Double(durationMs) / 1000 }
}

struct Playlist: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var tracks: [Track]
    var updatedAt: Date
}

enum AppDirs {
    /// Library/Application Support in the app's container.
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// Writes through a temp file so a crash mid-write never leaves a half file.
    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder.iso.encode(value) else { return }
        try? data.write(to: support.appendingPathComponent(name), options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let d = try? Data(contentsOf: support.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder.iso.decode(type, from: d)
    }
}

extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }() }
extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }

extension Collection {
    subscript(safe i: Index) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The phone's own library: liked songs, playlists, recently played (library.json). Works with nothing else installed.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    struct Data: Codable { var likes: [Track] = []; var playlists: [Playlist] = []; var recent: [Track] = [] }
    @Published private(set) var data = Data()

    private init() {
        // A damaged file must never stop the app from opening.
        if let d = AppDirs.load(Data.self, "library.json") { data = d }
    }

    func isLiked(_ t: Track) -> Bool { data.likes.contains { $0.key == t.key } }

    func toggleLike(_ t: Track) {
        update { d in
            if d.likes.contains(where: { $0.key == t.key }) { d.likes.removeAll { $0.key == t.key } } else { d.likes.insert(t, at: 0) }
        }
    }

    func clearRecent() { update { $0.recent = [] } }

    func played(_ t: Track) {
        update { d in
            d.recent.removeAll { $0.key == t.key }
            d.recent.insert(t, at: 0)
            if d.recent.count > 50 { d.recent.removeLast(d.recent.count - 50) }
        }
    }

    @discardableResult
    func createPlaylist(_ name: String, tracks: [Track] = []) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let p = Playlist(id: UUID().uuidString, name: trimmed.isEmpty ? "New playlist" : trimmed, tracks: tracks, updatedAt: Date())
        update { $0.playlists.append(p) }
        return p
    }

    func playlist(_ id: String) -> Playlist? { data.playlists.first { $0.id == id } }

    func renamePlaylist(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        edit(id) { $0.name = n }
    }

    func deletePlaylist(_ id: String) { update { $0.playlists.removeAll { $0.id == id } } }

    /// False when the song was already in it.
    @discardableResult
    func add(_ t: Track, to id: String) -> Bool {
        guard let p = data.playlists.first(where: { $0.id == id }), !p.tracks.contains(where: { $0.key == t.key }) else { return false }
        edit(id) { $0.tracks.append(t) }
        return true
    }

    func remove(at i: Int, from id: String) { edit(id) { p in if p.tracks.indices.contains(i) { p.tracks.remove(at: i) } } }

    private func edit(_ id: String, _ f: (inout Playlist) -> Void) {
        update { d in
            guard let i = d.playlists.firstIndex(where: { $0.id == id }) else { return }
            f(&d.playlists[i])
            d.playlists[i].updatedAt = Date()
        }
    }

    private func update(_ f: (inout Data) -> Void) {
        var d = data
        f(&d)
        data = d
        AppDirs.save(d, "library.json")
        WidgetBridge.shared.changed()
    }
}

/// Settings, kept in UserDefaults.
enum Prefs {
    static var autoplay: Bool {
        get { UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoplay") }
    }
    static var blockAds: Bool {
        get { UserDefaults.standard.object(forKey: "blockAds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "blockAds") }
    }
    /// Now playing as a Live Activity (lock screen + Dynamic Island).
    static var liveActivity: Bool {
        get { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveActivity") }
    }
}
