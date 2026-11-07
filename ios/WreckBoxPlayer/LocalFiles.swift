import AudioToolbox
import AVFoundation
import UIKit

/// Songs saved on the phone: Documents/Music, filled from Files, AirDrop, "Open in…", or by dropping files into
/// On My iPhone → WreckBox Player → Music in the Files app. Each file's tags (title, artist, album), length, cover
/// and real quality ("FLAC · 24/96 · 2,612 kbps") are read once and kept in local-2.json.
@MainActor
enum LocalFiles {
    static let folder: URL = {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Music")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    nonisolated static func url(_ id: String) -> URL { folder.appendingPathComponent(id) }

    static let extensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "alac", "caf", "mp4"]

    struct Info: Codable {
        var size: Int
        var modified: Date
        var track: Track
        var quality: String?
    }

    private static var index: [String: Info] = AppDirs.load([String: Info].self, "local-2.json") ?? [:]
    private static var cached: [Track]?

    /// The phone's songs, by title.
    static var tracks: [Track] {
        if let cached { return cached }
        let list = scan()
        cached = list
        return list
    }

    static func quality(_ id: String) -> String? { index[id]?.quality }

    static func refresh() { cached = nil; NotificationCenter.default.post(name: .localFilesChanged, object: nil) }

    /// Reads new or changed files (tags are read once per file).
    private static func scan() -> [Track] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var fresh: [String: Info] = [:]
        for f in files where extensions.contains(f.pathExtension.lowercased()) {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = v?.fileSize ?? 0, mod = v?.contentModificationDate ?? .distantPast
            let id = f.lastPathComponent
            if let known = index[id], known.size == size, known.modified == mod { fresh[id] = known; continue }
            let (track, q) = read(f)
            fresh[id] = Info(size: size, modified: mod, track: track, quality: q)
        }
        index = fresh
        AppDirs.save(index, "local-2.json")
        return index.values.map(\.track).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Tags, length and quality from Core Audio (it reads FLAC's tags as well as MP3's and M4A's).
    private static func read(_ url: URL) -> (Track, String?) {
        let id = url.lastPathComponent
        let base = url.deletingPathExtension().lastPathComponent
        let parts = base.components(separatedBy: " - ")
        var title = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : base
        var artist = parts.count > 1 ? parts[0] : ""
        var album: String?
        var duration: Double = 0
        var quality: String?
        var fileID: AudioFileID?
        if AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let f = fileID {
            defer { AudioFileClose(f) }
            var dict: Unmanaged<CFDictionary>?
            var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
            if AudioFileGetProperty(f, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr, let info = dict?.takeRetainedValue() as? [String: Any] {
                if let t = info[kAFInfoDictionary_Title] as? String, !t.isEmpty { title = t }
                if let a = info[kAFInfoDictionary_Artist] as? String, !a.isEmpty { artist = a }
                if let al = info[kAFInfoDictionary_Album] as? String, !al.isEmpty { album = al }
                if let d = info[kAFInfoDictionary_ApproximateDurationInSeconds] as? String { duration = Double(d) ?? 0 }
            }
            var fmt = AudioStreamBasicDescription()
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioFileGetProperty(f, kAudioFilePropertyDataFormat, &size, &fmt)
            var bits: UInt32 = 0
            size = 4
            AudioFileGetProperty(f, kAudioFilePropertySourceBitDepth, &size, &bits)
            var bitrate: UInt32 = 0
            size = 4
            AudioFileGetProperty(f, kAudioFilePropertyBitRate, &size, &bitrate)
            if duration == 0 {
                var secs: Double = 0
                size = 8
                if AudioFileGetProperty(f, kAudioFilePropertyEstimatedDuration, &size, &secs) == noErr { duration = secs }
            }
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            quality = label(url.pathExtension.lowercased(), fmt, Int(bits), Int(bitrate), bytes, duration)
        }
        let t = Track(source: .local, id: id, title: title, artist: artist, album: album, durationMs: Int64(duration * 1000), art: "file:\(id)")
        return (t, quality)
    }

    /// "FLAC · 24/96 · 2,612 kbps", "MP3 · 320 kbps".
    private static func label(_ ext: String, _ f: AudioStreamBasicDescription, _ bits: Int, _ bitrate: Int, _ bytes: Int, _ secs: Double) -> String? {
        let format: String
        switch f.mFormatID {
        case kAudioFormatFLAC: format = "FLAC"
        case kAudioFormatAppleLossless: format = "ALAC"
        case kAudioFormatMPEGLayer3: format = "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: format = "AAC"
        case kAudioFormatLinearPCM: format = ext == "wav" ? "WAV" : ext.hasPrefix("aif") ? "AIFF" : "PCM"
        default: format = ext.uppercased()
        }
        let kbps = bitrate > 0 ? bitrate / 1000 : secs > 0 ? Int(Double(bytes) * 8 / secs / 1000) : 0
        let lossless = ["FLAC", "ALAC", "WAV", "AIFF", "PCM"].contains(format)
        let rate = f.mSampleRate / 1000
        let res = lossless && f.mSampleRate > 0 ? "\(bits > 0 ? "\(bits)/" : "")\(rate.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(rate)) : String(format: "%.1f", rate))" : nil
        let n = NumberFormatter()
        n.numberStyle = .decimal
        n.locale = Locale(identifier: "en_US")
        return [format, res, kbps > 0 ? "\(n.string(from: NSNumber(value: kbps)) ?? "\(kbps)") kbps" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// Copies songs in (from the Files picker, AirDrop, "Open in…"). Returns how many were added.
    @discardableResult
    static func importFiles(_ urls: [URL]) -> Int {
        var added = 0
        for u in urls {
            let access = u.startAccessingSecurityScopedResource()
            defer { if access { u.stopAccessingSecurityScopedResource() } }
            guard extensions.contains(u.pathExtension.lowercased()) else { continue }
            var dest = folder.appendingPathComponent(u.lastPathComponent)
            // Already here: same name and size is the same song.
            if let a = try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize, a == (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) { continue }
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = folder.appendingPathComponent("\(u.deletingPathExtension().lastPathComponent) (\(n)).\(u.pathExtension)")
                n += 1
            }
            // Files handed over in the app's Inbox (AirDrop / Open in) are moved; picked files are copied.
            let inbox = u.path.contains("/Documents/Inbox/")
            if (inbox ? (try? FileManager.default.moveItem(at: u, to: dest)) : (try? FileManager.default.copyItem(at: u, to: dest))) != nil { added += 1 }
        }
        if added > 0 { refresh() }
        Log.shared.write("phone songs: \(added) added, \(tracks.count) in all")
        return added
    }

    static func delete(_ t: Track) {
        try? FileManager.default.removeItem(at: url(t.id))
        refresh()
    }

    /// The cover inside a file (FLAC's picture, ID3's, M4A's).
    nonisolated static func artwork(_ id: String) async -> Data? {
        let u = url(id)
        var fileID: AudioFileID?
        if AudioFileOpenURL(u as CFURL, .readPermission, 0, &fileID) == noErr, let f = fileID {
            defer { AudioFileClose(f) }
            var art: Unmanaged<CFData>?
            var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
            if AudioFileGetProperty(f, kAudioFilePropertyAlbumArtwork, &size, &art) == noErr, let d = art?.takeRetainedValue() { return d as Data }
        }
        let asset = AVURLAsset(url: u)
        guard let meta = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork) {
            if let d = try? await item.load(.dataValue) { return d }
        }
        return nil
    }
}

extension Notification.Name {
    static let localFilesChanged = Notification.Name("localFilesChanged")
}
