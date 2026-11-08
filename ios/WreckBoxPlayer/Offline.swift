import Foundation

/// "Keep offline": saves a YouTube song's audio into the phone's songs (Documents/Music), where it plays with no
/// connection and shows up under Phone. Which songs were saved is remembered in offline.json (track key → file name).
@MainActor
final class Offline: ObservableObject {
    static let shared = Offline()

    @Published private(set) var saved: [String: String] = AppDirs.load([String: String].self, "offline.json") ?? [:]
    @Published private(set) var working: Set<String> = []
    @Published var lastError: String?

    /// Saved and the file is still there (the user may have deleted it from Files).
    func isSaved(_ t: Track) -> Bool {
        if t.source == .local { return true }
        guard let name = saved[t.key] else { return false }
        return FileManager.default.fileExists(atPath: LocalFiles.url(name).path)
    }

    func isWorking(_ t: Track) -> Bool { working.contains(t.key) }

    /// Only YouTube songs can be fetched; Spotify's are streamed through its page and phone songs are already here.
    func canSave(_ t: Track) -> Bool { t.source == .youtube && !t.id.isEmpty }

    func save(_ t: Track) {
        guard canSave(t), !isSaved(t), !working.contains(t.key) else { return }
        working.insert(t.key)
        lastError = nil
        Task {
            defer { working.remove(t.key) }
            do {
                let s = try await YouTubeStream.resolve(t.id)
                let (tmp, resp) = try await URLSession.shared.download(from: s.url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 || (resp as? HTTPURLResponse)?.statusCode == 206 else {
                    throw YouTubeStream.Failure.badAnswer
                }
                let ext = "m4a" // only AAC (itag 140 / 139) is asked for
                // "Artist - Title.m4a": LocalFiles reads title and artist from the name when the file has no tags.
                let stem = Self.safe([t.artist, t.title].filter { !$0.isEmpty }.joined(separator: " - "))
                var dest = LocalFiles.folder.appendingPathComponent("\(stem.isEmpty ? t.id : stem).\(ext)")
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = LocalFiles.folder.appendingPathComponent("\(stem) (\(n)).\(ext)")
                    n += 1
                }
                try FileManager.default.moveItem(at: tmp, to: dest)
                saved[t.key] = dest.lastPathComponent
                AppDirs.save(saved, "offline.json")
                LocalFiles.refresh()
                Log.shared.write("offline: saved \(t.id) as \(dest.lastPathComponent)")
            } catch {
                lastError = error.localizedDescription
                Log.shared.write("offline: \(t.id) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Removes the saved copy (the song stays in the library and streams again).
    func remove(_ t: Track) {
        guard let name = saved[t.key] else { return }
        try? FileManager.default.removeItem(at: LocalFiles.url(name))
        saved[t.key] = nil
        AppDirs.save(saved, "offline.json")
        LocalFiles.refresh()
    }

    private static func safe(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
