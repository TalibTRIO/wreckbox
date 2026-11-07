import UIKit
import WebKit

/// What a page's player is doing, reported every half second.
struct WebState {
    var hasMedia = false
    var paused = true
    var position: Double = 0
    var duration: Double = 0
    var ended = false
    var ad = false
    var url = ""
    var at = Date()
    var itag: Int?
}

/// The streaming services that play in a hidden page.
enum Service: String {
    case youtube = "YouTube Music"
    case spotify = "Spotify"

    func trackURL(_ id: String) -> URL {
        switch self {
        case .youtube: URL(string: "https://music.youtube.com/watch?v=\(id)")!
        case .spotify: URL(string: "https://open.spotify.com/track/\(id)")!
        }
    }

    var signIn: URL {
        switch self {
        case .youtube: URL(string: "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F")!
        case .spotify: URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F")!
        }
    }
}

/// A streaming service's web player in a web view nobody sees (it sits in a 1-point clipped box in the app's window,
/// so iOS treats it as on screen). The desktop Safari user agent gets the full web player rather than the mobile
/// "open the app" page.
@MainActor
final class WebEngine: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    let service: Service
    let view: WKWebView
    private(set) var last = WebState()
    var onState: ((WebState) -> Void)?
    var onEnded: ((String) -> Void)?
    var onLoaded: ((String) -> Void)?

    init(_ service: Service) {
        self.service = service
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()
        cfg.userContentController.addUserScript(WKUserScript(source: Self.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: cfg)
        view.customUserAgent = Self.userAgent
        view.isInspectable = true
        super.init()
        cfg.userContentController.add(WeakHandler(self), name: "wb")
        view.navigationDelegate = self
        if service == .youtube { Self.applyAdBlock(to: cfg.userContentController) }
    }

    func playTrack(_ id: String) {
        last = WebState()
        view.load(URLRequest(url: service.trackURL(id)))
        // The page's script starts the track once it's loaded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            switch service {
            case .youtube: js("WBC.start()"); eq(EQ.shared.effective)
            case .spotify: view.evaluateJavaScript(Self.spotifyStart, completionHandler: nil)
            }
        }
    }

    func open(_ url: URL) { view.load(URLRequest(url: url)) }
    func play() { js("WBC.play()") }
    func pause() { js("WBC.pause()") }
    func stop() { js("WBC.stop()") }
    func seek(_ s: Double) { js("WBC.seek(\(s))") }
    func eq(_ g: [Float]) { js("WBC.eq([\(g.map { String($0) }.joined(separator: ","))])") }

    /// Which DRM systems this page's browser offers (Spotify's web player needs Widevine).
    func probeDRM() async -> String {
        let r = try? await view.callAsyncJavaScript(Self.drmProbe, contentWorld: .page)
        return r as? String ?? "probe failed"
    }

    /// The page's title and the start of its visible text, to see what it's showing.
    func describe() async -> String {
        let r = try? await view.evaluateJavaScript("document.title + ' | ' + (document.body ? document.body.innerText.replace(/\\s+/g, ' ').slice(0, 300) : '')")
        return r as? String ?? ""
    }

    private func js(_ code: String) { view.evaluateJavaScript("window.WBC && \(code)", completionHandler: nil) }

    // MARK: the page reports

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let o = m.body as? [String: Any], let k = o["k"] as? String else { return }
        switch k {
        case "state":
            guard let s = o["v"] as? String, let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return }
            func d(_ key: String) -> Double { let v = (j[key] as? NSNumber)?.doubleValue ?? 0; return v.isFinite ? v : 0 }
            last = WebState(hasMedia: j["has"] as? Bool ?? false, paused: j["paused"] as? Bool ?? true, position: d("pos"), duration: d("dur"),
                            ended: j["ended"] as? Bool ?? false, ad: j["ad"] as? Bool ?? false, url: j["url"] as? String ?? "", at: Date(),
                            itag: (j["itag"] as? NSNumber).map(\.intValue).flatMap { $0 > 0 ? $0 : nil })
            onState?(last)
        case "ended": onEnded?(o["v"] as? String ?? "ended")
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoaded?(webView.url?.absoluteString ?? "")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onEnded?("page process ended")
    }

    // MARK: ad blocking

    /// Known ad and tracking hosts never load in the page (YouTube's in-video ads come from the same servers as the
    /// music, so the page script mutes and skips those instead).
    private static func applyAdBlock(to uc: WKUserContentController) {
        guard Prefs.blockAds else { return }
        let hosts = ["doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com", "googletagmanager.com",
                     "googletagservices.com", "adservice.google.com", "imasdk.googleapis.com", "scorecardresearch.com", "moatads.com", "adnxs.com"]
        var rules = hosts.map { #"{"trigger":{"url-filter":"^https?://([^/]+\.)?\#($0.replacingOccurrences(of: ".", with: "\\\\."))/"},"action":{"type":"block"}}"# }
        for p in ["/pagead/", "/ptracking", "/api/stats/ads", "/get_midroll_", "/api/stats/atr"] {
            rules.append(#"{"trigger":{"url-filter":"youtube\\.com\#(p)"},"action":{"type":"block"}}"#)
        }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "wb-adblock", encodedContentRuleList: "[\(rules.joined(separator: ","))]") { list, _ in
            if let list { uc.add(list) }
        }
    }

    static let spotifyStart = """
    (function () {
      var n = 0, t = setInterval(function () {
        n++;
        var m = document.querySelector('video,audio');
        if ((m && !m.paused) || n > 25) { clearInterval(t); return; }
        var b = document.querySelector('[data-testid="play-button"], button[aria-label^="Play"]');
        if (b) b.click();
      }, 1000);
    })();
    """

    static let drmProbe = """
    const out = { eme: !!navigator.requestMediaKeySystemAccess };
    for (const ks of ['com.widevine.alpha', 'com.apple.fps', 'com.apple.fps.1_0']) {
      try {
        await navigator.requestMediaKeySystemAccess(ks, [{ initDataTypes: ['cenc', 'sinf', 'skd'],
          audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }] }]);
        out[ks] = 'yes';
      } catch (e) { out[ks] = 'no (' + e.name + ')'; }
    }
    return JSON.stringify(out);
    """
}

/// WKUserContentController keeps its handlers strongly; this keeps the engine from being held forever.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(u, didReceive: m)
    }
}
