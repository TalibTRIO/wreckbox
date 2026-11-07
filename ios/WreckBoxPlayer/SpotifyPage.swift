import UIKit
import WebKit

/// Spotify through a hidden, signed-in Spotify web page (no developer key needed): search, and your library — Liked
/// Songs, top tracks this month, top artists — read from the page itself. Spotify songs play from their YouTube Music
/// match (Spotify's own audio needs Premium and its own app). (Port of the Android Player's SpotifySearch.)
@MainActor
final class SpotifyPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = SpotifyPage()

    /// Searches run here; reading your library runs in `libraryView`, so neither moves the page under the other.
    let view: WKWebView
    let libraryView: WKWebView
    private var pending: CheckedContinuation<[Track], Error>?
    private var pendingData: CheckedContinuation<JSON, Error>?
    /// The page is loaded and showing Spotify: a new search can move inside it instead of reloading it.
    private var live = false
    private var idle: Task<Void, Never>?

    enum Failure: LocalizedError {
        case notLoaded, busy, unreadable
        var errorDescription: String? {
            switch self {
            case .notLoaded: return "Spotify's page didn't load"
            case .busy: return "replaced by a newer search"
            case .unreadable: return "unreadable answer"
            }
        }
    }

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        // The bridge the Android scripts talk to (WB.results / WB.data).
        let bridge = """
        window.WB = { results: function (s) { window.webkit.messageHandlers.wb.postMessage({ k: 'results', v: s }); },
                      data: function (s) { window.webkit.messageHandlers.wb.postMessage({ k: 'data', v: s }); } };
        """
        cfg.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Both pages share the content controller (the bridge) and the sign-in (the default data store).
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        libraryView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        for v in [view, libraryView] { v.customUserAgent = WebEngine.userAgent; v.isInspectable = true }
        super.init()
        cfg.userContentController.add(Weak(self), name: "wb")
        libraryView.navigationDelegate = self
    }

    func search(_ q: String) async throws -> [Track] {
        pending?.resume(throwing: Failure.busy)
        pending = nil
        let path = "/search/\(q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? q)/tracks"
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { cont in
            pending = cont
            if live {
                // Spotify's page is a single-page app: going to the new search inside it skips loading the whole player
                // again (3–5 s → well under one). The old first result is remembered: until the list changes, what's on
                // screen is still the last search.
                let js = "(function(){var a=document.querySelector('[data-testid=\"tracklist-row\"] a[href*=\"/track/\"]');window.__wbPrev=a?a.getAttribute('href'):null;" +
                    "history.pushState({}, '', \(Self.quote(path))); dispatchEvent(new PopStateEvent('popstate'));})()"
                view.evaluateJavaScript(js, completionHandler: nil)
                after(0.3) { self.view.evaluateJavaScript(Self.read(q), completionHandler: nil) }
            } else {
                view.load(URLRequest(url: URL(string: "https://open.spotify.com\(path)")!))
                after(1.5) { self.view.evaluateJavaScript(Self.read(q), completionHandler: nil) }
            }
          }
        } onCancel: {
            // Gave up (time limit, newer search): nothing waits on this answer any more.
            Task { @MainActor in self.pending?.resume(throwing: CancellationError()); self.pending = nil }
        }
    }

    /// Your Spotify listening, read from the web player's pages: Liked Songs (up to 600), top tracks this month, top artists.
    func library() async throws -> JSON {
        pendingData?.resume(throwing: Failure.busy)
        pendingData = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pendingData = cont
                runLibraryOnLoad = true
                libraryView.load(URLRequest(url: URL(string: "https://open.spotify.com/collection/tracks")!))
            }
        } onCancel: {
            Task { @MainActor in
                self.pendingData?.resume(throwing: CancellationError()); self.pendingData = nil; self.runLibraryOnLoad = false
                self.unloadLibrary()
            }
        }
    }

    /// The library script runs once Spotify's page has loaded (run earlier, the page replaced it as it loaded).
    private var runLibraryOnLoad = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === libraryView, runLibraryOnLoad, webView.url?.host == "open.spotify.com" else { return }
        runLibraryOnLoad = false
        after(2) { self.libraryView.evaluateJavaScript(Self.libraryScript, completionHandler: nil) }
    }

    /// The library is read (or given up on): its page goes.
    private func unloadLibrary() { libraryView.load(URLRequest(url: URL(string: "about:blank")!)) }

    /// What the hidden page shows (for the test log).
    func describe() async -> String {
        let js = "location.href + ' | ' + document.title + ' | rows=' + document.querySelectorAll('[data-testid=\"tracklist-row\"]').length + ' | user=' + !!document.querySelector('a[href*=\"/user/\"]') + ' | ' + (document.body ? document.body.innerText.replace(/\\s+/g, ' ').slice(0, 160) : '')"
        return ((try? await view.evaluateJavaScript(js)) as? String) ?? "page not readable"
    }

    private func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
    }

    /// Nothing to do until the next search: unload after 2 minutes.
    private func parkLater() {
        idle?.cancel()
        idle = Task {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, pending == nil else { return }
            live = false
            view.load(URLRequest(url: URL(string: "about:blank")!))
        }
    }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let o = m.body as? [String: Any], let k = o["k"] as? String, let v = o["v"] as? String else { return }
        switch k {
        case "results":
            if v == "null" { live = false; pending?.resume(throwing: Failure.notLoaded); pending = nil; return }
            live = true
            let rows = (try? JSONSerialization.jsonObject(with: Data(v.utf8)) as? [JSON]) ?? []
            let list = rows.compactMap { o -> Track? in
                guard let id = o.s("id"), !id.isEmpty else { return nil }
                let dur = (o.s("dur") ?? "").split(separator: ":").reduce(Int64(0)) { $0 * 60 + (Int64($1) ?? 0) } * 1000
                return Track(source: .spotify, id: id, title: o.s("title") ?? "", artist: o.s("artist") ?? "",
                             album: (o.s("album") ?? "").isEmpty ? nil : o.s("album"), durationMs: dur, art: (o.s("art") ?? "").isEmpty ? nil : o.s("art"))
            }
            pending?.resume(returning: list)
            pending = nil
            parkLater()
        case "data":
            let j = (try? JSONSerialization.jsonObject(with: Data(v.utf8)) as? JSON) ?? ["error": "unreadable answer"]
            pendingData?.resume(returning: j)
            pendingData = nil
            unloadLibrary()
        default: break
        }
    }

    private static func quote(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        return d.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    /// Reads the result rows once they've rendered (checks every 0.25 s for ~10 s). Only rows of THIS query count: if
    /// the page is still an older search (or the new one never loaded, e.g. offline) the answer is empty, never stale.
    private static func read(_ q: String) -> String {
        """
        (function () {
          var want = \(quote(q.lowercased())), tries = 0;
          function onPage() { try { return decodeURIComponent(location.pathname).toLowerCase().indexOf('/search/' + want + '/') === 0; } catch (e) { return false; } }
          var t = setInterval(function () {
            tries++;
            var rows = onPage() ? document.querySelectorAll('[data-testid="tracklist-row"]') : [];
            var firstA = rows.length ? rows[0].querySelector('a[href*="/track/"]') : null;
            var same = window.__wbPrev && firstA && firstA.getAttribute('href') === window.__wbPrev;
            if ((!rows.length || (same && tries < 16)) && tries < 40) return;
            window.__wbPrev = null;
            clearInterval(t);
            if (!onPage()) { WB.results('null'); return; }
            var out = [];
            Array.prototype.forEach.call(rows, function (r) {
              var a = r.querySelector('a[href*="/track/"]'); if (!a) return;
              var id = (a.getAttribute('href').match(/track\\/([A-Za-z0-9]+)/) || [])[1];
              var artists = Array.prototype.map.call(r.querySelectorAll('a[href*="/artist/"]'), function (x) { return x.textContent.trim(); });
              var al = r.querySelector('a[href*="/album/"]');
              var img = r.querySelector('img');
              var dur = '', w = document.createTreeWalker(r, NodeFilter.SHOW_TEXT), n;
              while ((n = w.nextNode())) { var tx = n.nodeValue.trim(); if (/^(\\d{1,2}:)?\\d{1,2}:\\d{2}$/.test(tx)) dur = tx; }
              out.push({ id: id, title: a.textContent.trim(), artist: artists.join(', '), album: al ? al.textContent.trim() : '',
                         art: img ? img.src.replace('ab67616d00004851', 'ab67616d00001e02') : '', dur: dur });
            });
            WB.results(JSON.stringify(out));
          }, 250);
        })();
        """
    }

    private static let libraryScript = """
    (async function () {
      function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
      function rows() {
        return Array.prototype.map.call(document.querySelectorAll('[data-testid="tracklist-row"]'), function (r) {
          var a = r.querySelector('a[href*="/track/"]'); if (!a) return null;
          var id = (a.getAttribute('href').match(/track\\/([A-Za-z0-9]+)/) || [])[1]; if (!id) return null;
          var artists = Array.prototype.map.call(r.querySelectorAll('a[href*="/artist/"]'), function (x) { return x.textContent.trim(); });
          var al = r.querySelector('a[href*="/album/"]'), img = r.querySelector('img');
          var d = '0:00', w = document.createTreeWalker(r, NodeFilter.SHOW_TEXT), n;
          while ((n = w.nextNode())) { var t = n.nodeValue.trim(); if (/^(\\d{1,2}:)?\\d{1,2}:\\d{2}$/.test(t)) d = t; }
          var sec = d.split(':').reduce(function (s, p) { return s * 60 + +p; }, 0);
          return { id: id, name: a.textContent.trim(), artists: artists.join(', '), album: al ? al.textContent.trim() : '',
                   art: img ? img.src.replace('ab67616d00004851', 'ab67616d00001e02') : '', dur: sec * 1000 };
        }).filter(Boolean);
      }
      async function go(path, ready) {
        if (location.pathname !== path) { history.pushState({}, '', path); dispatchEvent(new PopStateEvent('popstate')); }
        for (var i = 0; i < 30; i++) { await sleep(400); if (location.pathname === path && ready()) return true; }
        return false;
      }
      function scroller() {
        var e = document.querySelector('[data-testid="track-list"]');
        while (e && !(e.scrollHeight > e.clientHeight + 20 && /(auto|scroll)/.test(getComputedStyle(e).overflowY))) e = e.parentElement;
        return e;
      }
      var out = { recent: [], saved: [], top_short_term: [], artists: [] };
      try {
        await go('/collection/tracks', function () { return rows().length > 0; });
        var seen = {}, still = 0;
        for (var n = 0; n < 200 && out.saved.length < 600 && still < 4; n++) {
          var before = out.saved.length;
          rows().forEach(function (t) { if (!seen[t.id]) { seen[t.id] = 1; out.saved.push(t); } });
          still = out.saved.length === before ? still + 1 : 0;
          var sc = scroller(); if (!sc) break;
          sc.scrollTop += sc.clientHeight * 0.9;
          await sleep(500);
        }
        var u = document.querySelector('a[href*="/user/"]');
        var me = u ? (u.getAttribute('href').match(/user\\/([^/?#]+)/) || [])[1] : null;
        if (me) {
          var main = function () { var m = document.querySelector('main'); return m ? m.innerText : ''; };
          if (await go('/user/' + me + '/top/tracks', function () { return main().indexOf('Top tracks') >= 0 && rows().length > 0; })) { await sleep(800); out.top_short_term = rows(); }
          if (await go('/user/' + me + '/top/artists', function () { return main().indexOf('Top artists') >= 0 && document.querySelector('[data-encore-id="card"] a[href*="/artist/"]'); })) {
            await sleep(800);
            var names = {};
            Array.prototype.forEach.call(document.querySelectorAll('[data-encore-id="card"]'), function (c) {
              var a = c.querySelector('a[href*="/artist/"]'); var name = a ? (a.getAttribute('title') || a.textContent || '').trim() : '';
              if (!name) name = (c.innerText || '').split('\\n')[0].trim();
              if (name && !names[name]) { names[name] = 1; out.artists.push(name); }
            });
          }
        }
      } catch (e) { out.error = String(e); }
      if (!out.saved.length && !out.top_short_term.length && !out.artists.length) out.error = out.error || 'nothing found — signed in to Spotify?';
      WB.data(JSON.stringify(out));
    })();
    """
}

/// WKUserContentController keeps its handlers strongly; this keeps the page from being held forever.
final class Weak: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(u, didReceive: m) }
}
