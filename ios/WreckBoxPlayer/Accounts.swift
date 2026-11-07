import SwiftUI
import WebKit

/// Signing in to YouTube Music and Spotify in a web page inside the app. The session cookies stay in the app's web
/// storage, shared with the hidden pages: YouTube's are used for signed-in YouTube Music calls (your home, history,
/// likes), Spotify's let its hidden page search and read your library.
@MainActor
enum Accounts {
    enum Service: String { case youtube = "YouTube Music", spotify = "Spotify" }

    static func signInURL(_ s: Service) -> URL {
        switch s {
        case .youtube: URL(string: "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F")!
        case .spotify: URL(string: "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F")!
        }
    }

    private static func cookies(for host: String) async -> [HTTPCookie] {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter {
            host.hasSuffix($0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain)
        }
    }

    /// The Cookie header for music.youtube.com and the SAPISID for its hash, when signed in.
    static func youtubeCookies() async -> (cookie: String, sapisid: String)? {
        let yt = await cookies(for: "music.youtube.com")
        guard let sapisid = yt.first(where: { $0.name == "SAPISID" })?.value ?? yt.first(where: { $0.name == "__Secure-3PAPISID" })?.value else { return nil }
        return (yt.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), sapisid)
    }

    static func signedIn(_ s: Service) async -> Bool {
        switch s {
        case .youtube: return await youtubeCookies() != nil
        case .spotify: return await cookies(for: "open.spotify.com").contains { $0.name == "sp_dc" }
        }
    }

    static func youtubeSignedIn() async -> Bool { await signedIn(.youtube) }

    static func signOut(_ s: Service) async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let words = s == .youtube ? ["youtube", "google"] : ["spotify"]
        let mine = records.filter { r in words.contains { r.displayName.contains($0) } }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine)
    }
}

/// The sign-in page. It closes itself once the service's own site is reached signed in.
struct SignInSheet: UIViewRepresentable {
    let service: Accounts.Service
    let done: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(service, done) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let v = WKWebView(frame: .zero, configuration: cfg)
        // Google refuses sign-in in apps that say they're an app's web view: this is Safari's own user agent. Spotify gets
        // Safari on a Mac: on an iPhone its site sends you off to the Spotify app instead of signing in here.
        v.customUserAgent = service == .spotify ? WebEngine.userAgent
            : "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        v.load(URLRequest(url: Accounts.signInURL(service)))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let service: Accounts.Service
        let done: () -> Void
        init(_ service: Accounts.Service, _ done: @escaping () -> Void) { self.service = service; self.done = done }

        /// Sign-in stays in this page: links that would open another app (spotify://, the Spotify or YouTube app's
        /// universal links) are kept here or dropped.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let scheme = action.request.url?.scheme?.lowercased(), scheme == "https" || scheme == "http" || scheme == "about" || scheme == "blob" || scheme == "data" else {
                Log.shared.write("sign-in: kept out of another app (\(action.request.url?.absoluteString.prefix(60) ?? ""))")
                return decisionHandler(.cancel)
            }
            // .allow + 2 = allow without trying the app link (WebKit's own value; the public one may hand off to an app).
            decisionHandler(WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let home = service == .youtube ? "music.youtube.com" : "open.spotify.com"
            guard webView.url?.host == home else { return }
            Task { @MainActor in if await Accounts.signedIn(service) { done() } }
        }

        /// "Continue with Google / Apple" opens a popup that reports back to the page: shown on top of it, closed
        /// when it closes itself.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: webView.bounds, configuration: configuration)
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            popup.customUserAgent = webView.customUserAgent
            popup.navigationDelegate = self
            popup.uiDelegate = self
            webView.addSubview(popup)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) { webView.removeFromSuperview() }
    }
}
