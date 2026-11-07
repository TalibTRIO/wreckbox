import Foundation

/// YouTube Music songs as plain audio files the phone's own player plays: no page, no ads, no video.
///
/// The phone asks YouTube's player API for the song the way YouTube's visionOS app does (the client yt-dlp uses by
/// default; it hands out plain https links, no PO token or player script needed). A visitor id from youtube.com goes
/// with it — without one some songs come back "Sign in to confirm you're not a bot". The links work only from the
/// network that asked for them and expire after a few hours, so a song is resolved right before it plays.
enum YouTubeStream {
    struct Stream {
        var url: URL
        var itag: Int
        var mime: String
        var bitrate: Int
        var expires: Date
        /// The real length. The phone's player reads YouTube's audio files as twice as long as they are, so it's
        /// told where each one really ends.
        var duration: Double?

        /// "AAC · 130 kbps"
        var quality: String {
            let codec = mime.contains("opus") ? "OPUS" : mime.contains("mp4a") ? "AAC" : mime.uppercased()
            return "\(codec) · \(bitrate / 1000) kbps"
        }
    }

    enum Failure: LocalizedError {
        case notPlayable(String), noAudio, badAnswer
        var errorDescription: String? {
            switch self {
            case .notPlayable(let why): return why
            case .noAudio: return "No audio stream"
            case .badAnswer: return "YouTube didn't answer"
            }
        }
    }

    /// Who the request says it is. Built in now; later also fetched from wreckbox-api so a YouTube change can be
    /// fixed without an app update.
    struct Client: Codable {
        var name = "VISIONOS"
        var nameNumber = "101"
        var version = "1.02"
        var deviceMake = "Apple"
        var deviceModel = "RealityDevice17,1"
        var osName = "visionOS"
        var osVersion = "26.5.23O471"
        var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        /// AAC first: the phone's player can't open WebM.
        var itags = [140, 139]
    }

    static var client = Client()

    /// A playable link for the song, freshest visitor id first; a refused answer gets one retry with a new id.
    static func resolve(_ videoId: String) async throws -> Stream {
        do {
            return try await player(videoId, visitor: await Visitor.shared.id())
        } catch Failure.notPlayable {
            return try await player(videoId, visitor: await Visitor.shared.id(fresh: true))
        }
    }

    private static func player(_ videoId: String, visitor: String?) async throws -> Stream {
        let c = client
        var ctx: [String: Any] = ["clientName": c.name, "clientVersion": c.version, "deviceMake": c.deviceMake, "deviceModel": c.deviceModel,
                                  "osName": c.osName, "osVersion": c.osVersion, "hl": "en"]
        if let visitor { ctx["visitorData"] = visitor }
        let body: [String: Any] = ["context": ["client": ctx], "videoId": videoId, "contentCheckOk": true, "racyCheckOk": true]
        var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(c.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(c.nameNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(c.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if let visitor { req.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.badAnswer }
        let ps = j["playabilityStatus"] as? [String: Any]
        guard (ps?["status"] as? String) == "OK" else { throw Failure.notPlayable(ps?["reason"] as? String ?? "Not playable") }
        let sd = j["streamingData"] as? [String: Any]
        let formats = (sd?["adaptiveFormats"] as? [[String: Any]]) ?? []
        let expiresIn = Double(sd?["expiresInSeconds"] as? String ?? "") ?? 6 * 3600
        for itag in c.itags {
            guard let f = formats.first(where: { ($0["itag"] as? Int) == itag }),
                  let s = f["url"] as? String, let url = URL(string: s) else { continue }
            let ms = Double(f["approxDurationMs"] as? String ?? "")
            return Stream(url: url, itag: itag, mime: f["mimeType"] as? String ?? "", bitrate: f["bitrate"] as? Int ?? 0,
                          expires: Date().addingTimeInterval(expiresIn - 300), duration: ms.map { $0 / 1000 })
        }
        throw Failure.noAudio
    }

    /// youtube.com's visitor id (VISITOR_DATA), kept for a day — also across app starts, so the first song after
    /// opening the app doesn't wait for youtube.com.
    actor Visitor {
        static let shared = Visitor()
        private var value: String? = UserDefaults.standard.string(forKey: "ytVisitor")
        private var at = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "ytVisitorAt"))

        func id(fresh: Bool = false) async -> String? {
            if !fresh, let value, Date().timeIntervalSince(at) < 24 * 3600 { return value }
            var req = URLRequest(url: URL(string: "https://www.youtube.com/")!)
            req.timeoutInterval = 10
            req.setValue(YouTubeStream.client.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("en", forHTTPHeaderField: "Accept-Language")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let html = String(data: data, encoding: .utf8),
                  let r = html.range(of: #""VISITOR_DATA":"[^"]+""#, options: .regularExpression) else { return value }
            value = String(html[r].dropFirst(16).dropLast())
            at = Date()
            UserDefaults.standard.set(value, forKey: "ytVisitor")
            UserDefaults.standard.set(at.timeIntervalSince1970, forKey: "ytVisitorAt")
            return value
        }
    }
}
