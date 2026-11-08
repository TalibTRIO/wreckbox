import Foundation
import SwiftUI

/// "Keep offline": saves a YouTube song's audio into the phone's songs (Documents/Music). The player prefers that
/// copy, so the song plays with no connection. Which songs were asked for, and how each download went, is kept in
/// offline-2.json so the Offline songs page can show it.
@MainActor
final class Offline: ObservableObject {
    static let shared = Offline()

    enum Status: String, Codable { case downloading, failed, saved }

    struct Entry: Codable, Identifiable {
        var track: Track
        var status: Status
        var file: String?
        var bytes: Int = 0
        var total: Int?
        var error: String?
        var at: Date = Date()
        var id: String { track.key }
    }

    @Published private(set) var entries: [String: Entry] = AppDirs.load([String: Entry].self, "offline-2.json") ?? [:]

    private init() {
        // A download cut off by closing the app isn't running any more: show it as failed so it can be retried.
        for (k, e) in entries where e.status == .downloading {
            entries[k]?.status = .failed
            entries[k]?.error = "Interrupted"
        }
        persist()
    }

    /// Newest first.
    var list: [Entry] { entries.values.sorted { $0.at > $1.at } }

    func entry(_ t: Track) -> Entry? { entries[t.key] }

    /// The saved file, if the song was kept offline and the file is still there (it may have been deleted from Files).
    func fileURL(_ t: Track) -> URL? {
        guard let e = entries[t.key], e.status == .saved, let f = e.file else { return nil }
        let u = LocalFiles.url(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func isSaved(_ t: Track) -> Bool { t.source == .local || fileURL(t) != nil }
    func isWorking(_ t: Track) -> Bool { entries[t.key]?.status == .downloading }

    /// Only YouTube songs can be fetched; Spotify's are streamed through its page and phone songs are already here.
    func canSave(_ t: Track) -> Bool { t.source == .youtube ? !t.id.isEmpty : t.source == .spotify }

    /// Downloads the song's audio in 1 MB pieces (YouTube's links stall on one big request) to a temp file.
    private func fetch(_ t: Track) async throws -> URL {
        var video = t.id
        if t.source == .spotify {
            guard let v = await Radio.findOnYouTube(t) else { throw YouTubeStream.Failure.notPlayable("Not found on YouTube Music") }
            video = v
        }
        let s = try await YouTubeStream.resolve(video)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let h = try FileHandle(forWritingTo: tmp)
        defer { try? h.close() }
        var pos = 0, total = Int.max
        while pos < total {
            var req = URLRequest(url: s.url)
            req.timeoutInterval = 20 // a link that goes quiet fails instead of showing Downloading forever
            req.setValue(YouTubeStream.client.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("bytes=\(pos)-\(pos + 1_048_575)", forHTTPHeaderField: "Range")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200, !data.isEmpty else {
                throw YouTubeStream.Failure.badAnswer
            }
            try h.write(contentsOf: data)
            if http.statusCode == 200 { // the server ignored the range and sent everything
                pos = data.count
                total = pos
            } else {
                pos += data.count
                if let cr = http.value(forHTTPHeaderField: "Content-Range"), let n = cr.split(separator: "/").last.flatMap({ Int($0) }) { total = n }
            }
            entries[t.key]?.bytes = pos
            entries[t.key]?.total = total == Int.max ? nil : total
        }
        return tmp
    }

    func save(_ t: Track) {
        guard canSave(t), !isSaved(t), !isWorking(t) else { return }
        entries[t.key] = Entry(track: t, status: .downloading)
        persist()
        Task {
            do {
                let tmp = try await fetch(t)
                let ext = "m4a" // only AAC (itag 140 / 139) is asked for
                // "Artist - Title.m4a": LocalFiles reads title and artist from the name when the file has no tags.
                let stem = Self.safe([t.artist, t.title].filter { !$0.isEmpty }.joined(separator: " - "))
                let base = stem.isEmpty ? t.id : stem
                var dest = LocalFiles.folder.appendingPathComponent("\(base).\(ext)")
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = LocalFiles.folder.appendingPathComponent("\(base) (\(n)).\(ext)")
                    n += 1
                }
                try FileManager.default.moveItem(at: tmp, to: dest)
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                entries[t.key] = Entry(track: t, status: .saved, file: dest.lastPathComponent, bytes: size)
                persist()
                LocalFiles.refresh()
                Log.shared.write("offline: saved \(t.id) as \(dest.lastPathComponent)")
            } catch {
                entries[t.key] = Entry(track: t, status: .failed, error: error.localizedDescription)
                persist()
                Log.shared.write("offline: \(t.id) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Removes the saved copy (the song stays in the library and streams again).
    func remove(_ t: Track) {
        if let f = entries[t.key]?.file { try? FileManager.default.removeItem(at: LocalFiles.url(f)) }
        entries[t.key] = nil
        persist()
        LocalFiles.refresh()
    }

    private func persist() { AppDirs.save(entries, "offline-2.json") }

    private static func safe(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Offline songs page


/// Every song kept offline, with how its download went: Downloading, Saved (with size) or Failed (with Retry).
struct OfflinePage: View {
    @ObservedObject private var offline = Offline.shared

    var body: some View {
        let list = offline.list
        let saved = list.filter { $0.status == .saved }
        PageScaffold(title: "Offline songs") {
            if !saved.isEmpty { PlayShuffle(tracks: saved.map(\.track)) }
            Text(summary(list)).font(W.ui(13)).foregroundStyle(W.text3).padding(.vertical, 8)
            if list.isEmpty {
                Text("Open a YouTube song's ••• menu and choose Keep offline. Saved songs play without a connection.")
                    .font(W.ui(14)).foregroundStyle(W.text3).padding(.top, 12)
            }
            LazyVStack(spacing: 6) {
                ForEach(list) { e in row(e, queue: saved.map(\.track)) }
            }
        }
    }

    private func summary(_ list: [Offline.Entry]) -> String {
        let s = list.filter { $0.status == .saved }
        let d = list.filter { $0.status == .downloading }.count
        let f = list.filter { $0.status == .failed }.count
        let mb = Double(s.reduce(0) { $0 + $1.bytes }) / 1_048_576
        return "\(s.count) saved (\(String(format: "%.1f", mb)) MB) · \(d) downloading · \(f) failed"
    }

    @ViewBuilder private func row(_ e: Offline.Entry, queue: [Track]) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.track.title).font(W.ui(15, .semibold)).foregroundStyle(W.text).lineLimit(1)
                Text(e.track.artist).font(W.ui(12.5)).foregroundStyle(W.text2).lineLimit(1)
                statusLine(e)
            }
            Spacer(minLength: 6)
            if e.status == .failed {
                Button { offline.save(e.track) } label: { Image(systemName: "arrow.clockwise") }.foregroundStyle(W.lilac)
            }
            Button(role: .destructive) { offline.remove(e.track) } label: { Image(systemName: "trash") }
                .foregroundStyle(W.text2)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard e.status == .saved, let i = queue.firstIndex(where: { $0.key == e.track.key }) else { return }
            Player.shared.playList(queue, start: i)
        }
    }

    @ViewBuilder private func statusLine(_ e: Offline.Entry) -> some View {
        switch e.status {
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text(e.total.map { "Downloading… \(Int(Double(e.bytes) / Double(max($0, 1)) * 100))%" } ?? "Downloading…")
                    .font(W.ui(12)).foregroundStyle(W.text3)
            }
        case .saved:
            Label("Available offline · \(String(format: "%.1f", Double(e.bytes) / 1_048_576)) MB", systemImage: "checkmark.circle.fill")
                .font(W.ui(12)).foregroundStyle(W.text3)
        case .failed:
            Label("Failed\(e.error.map { ": \($0)" } ?? "")", systemImage: "exclamationmark.triangle.fill")
                .font(W.ui(12)).foregroundStyle(W.text3).lineLimit(1)
        }
    }
}
