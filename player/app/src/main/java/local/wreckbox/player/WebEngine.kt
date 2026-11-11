package local.wreckbox.player

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.CompletableDeferred
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.net.URLEncoder

/** The streaming services that play in a hidden page. */
enum class Service(val origin: String, val login: String) {
    YOUTUBE("https://music.youtube.com", "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F"),
    SPOTIFY("https://open.spotify.com", "https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F");

    val source get() = if (this == YOUTUBE) Source.YOUTUBE else Source.SPOTIFY
}

/** What a page's player is doing, reported every half second. */
data class WebState(
    val hasMedia: Boolean = false,
    val paused: Boolean = true,
    val position: Double = 0.0,
    val duration: Double = 0.0,
    val ended: Boolean = false,
    val ad: Boolean = false,
    val title: String? = null,
    val artist: String? = null,
    val art: String? = null,
    val url: String = "",
    val at: Long = 0,
    /** YouTube: the audio format its player picked (itag), for the quality label. */
    val itag: Int? = null,
    /** Stutters seen in the page so far (clock fell behind / waited for data) — for the log. */
    val hiccups: Int = 0,
    val waits: Int = 0,
)

/**
 * A service's web player running in a WebView nobody sees (only LoginActivity ever shows one). Scripts injected
 * before the page's own code keep it believing it's on screen, catch the media element it plays, report state through
 * the `WB` bridge, fire `ended` the moment a song finishes (so the service's autoplay never takes over), skip YouTube
 * ads and block ad hosts (ad blocking is on by default; Premium accounts never see ads anyway).
 */
@SuppressLint("SetJavaScriptEnabled")
open class WebPage(context: Context, val service: Service) {
    protected val main = Handler(Looper.getMainLooper())

    val view: WebView = WebView(context).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.mediaPlaybackRequiresUserGesture = false
        settings.userAgentString = WebEngine.userAgent()
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
        addJavascriptInterface(Bridge(), "WB")
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(this, PAGE_SCRIPT, setOf(service.origin))
        }
        webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String) {
                // Older WebViews without document-start scripts: inject now (guarded against running twice).
                view.evaluateJavascript(PAGE_SCRIPT, null)
            }

            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                if (AdBlock.enabled && AdBlock.blocks(request.url.host ?: "", request.url.toString())) {
                    return WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))
                }
                return null
            }
        }
        webChromeClient = object : WebChromeClient() {
            // Spotify's player needs DRM (Widevine): allow it for the services' own pages only.
            override fun onPermissionRequest(request: PermissionRequest) {
                val host = request.origin.host ?: ""
                if ((host.endsWith("spotify.com") || host.endsWith("youtube.com")) && PermissionRequest.RESOURCE_PROTECTED_MEDIA_ID in request.resources) {
                    request.grant(arrayOf(PermissionRequest.RESOURCE_PROTECTED_MEDIA_ID))
                } else request.deny()
            }
        }
        // Never on screen, but a real desktop-sized page (1280×800 CSS pixels) so the services use their full layout.
        val d = context.resources.displayMetrics.density
        val w = (1280 * d).toInt()
        val h = (800 * d).toInt()
        measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
        layout(0, 0, w, h)
        onResume()
        resumeTimers()
        // Background priority until it plays (see important()).
        setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, true)
    }

    open fun onState(s: WebState) {}
    open fun onEnded(why: String) {}
    open fun onResults(json: String) {}
    open fun onData(json: String) {}

    fun open(url: String) = main.post { view.loadUrl(url) }

    /**
     * While this page plays: keep its renderer at foreground priority (Android lowers a never-visible WebView's
     * renderer, and starved of CPU its audio stutters). Otherwise let it drop back.
     */
    fun important(on: Boolean) = main.post { view.setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, !on) }

    /** Unloads the page (frees its memory and timers); the next song loads it again. */
    open fun park() { open("about:blank"); important(false) }
    fun js(code: String) = main.post { view.evaluateJavascript("window.WBC && $code", null) }
    fun destroy() = main.post { view.destroy() }

    inner class Bridge {
        @JavascriptInterface
        fun state(json: String) {
            val j = runCatching { JSONObject(json) }.getOrNull() ?: return
            fun d(k: String) = j.optDouble(k, 0.0).let { if (it.isNaN() || it.isInfinite()) 0.0 else it }
            val st = (WebState(
                hasMedia = j.optBoolean("has"), paused = j.optBoolean("paused", true), position = d("pos"), duration = d("dur"),
                ended = j.optBoolean("ended"), ad = j.optBoolean("ad"),
                title = j.optString("title").ifBlank { null }, artist = j.optString("artist").ifBlank { null },
                art = j.optString("art").ifBlank { null }, url = j.optString("url"), at = System.currentTimeMillis(),
                itag = j.optInt("itag", 0).takeIf { it > 0 },
                hiccups = j.optInt("hic"), waits = j.optInt("waits"),
            ))
            main.post { onState(st) } // the bridge runs on a WebView thread; the player lives on the main thread
        }

        @JavascriptInterface
        fun ended(why: String) = main.post { onEnded(why) }

        /** Asked by the page script as it starts: strip YouTube's ads out of its player data? (the Block ads setting) */
        @JavascriptInterface
        fun noAds(): Boolean = AdBlock.enabled

        @JavascriptInterface
        fun results(json: String) = main.post { onResults(json) }

        @JavascriptInterface
        fun data(json: String) = main.post { onData(json) }

        /** The page's spectrum: 8 comma-separated levels 0..1. */
        @JavascriptInterface
        fun levels(csv: String) {
            val b = csv.split(',').mapNotNull { it.toFloatOrNull() }
            if (b.size == Levels.BANDS) Levels.fromWeb(b.toFloatArray())
        }
    }

    companion object {
        /**
         * Runs first on every page of the services. `WBC` is what the app calls: play, pause, seek, press the
         * page's play button. The song name / artist / cover come from the page's player bar (YouTube Music) or
         * now-playing widget (Spotify), falling back to the page's media session.
         */
        val PAGE_SCRIPT = """
            (function () {
              if (window.WBC) return;
              try {
                Object.defineProperty(document, 'visibilityState', { get: function () { return 'visible'; } });
                Object.defineProperty(document, 'hidden', { get: function () { return false; } });
                document.addEventListener('visibilitychange', function (e) { e.stopImmediatePropagation(); }, true);
                window.addEventListener('blur', function (e) { e.stopImmediatePropagation(); }, true);
              } catch (e) {}
              // YouTube ads, removed before they exist: the ad schedule rides inside the player's data (the page's first
              // ytInitialPlayerResponse, then each song's /player answer). Without it the player has no ad to show, so a
              // song starts at once instead of after an ad is loaded and skipped. The skip in tick() stays as a backup.
              try {
                if (yt() && typeof WB !== 'undefined' && WB.noAds && WB.noAds()) {
                  var AD_KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams'];
                  var prune = function (o) {
                    if (o && typeof o === 'object' && !Array.isArray(o)) {
                      for (var i = 0; i < AD_KEYS.length; i++) if (AD_KEYS[i] in o) delete o[AD_KEYS[i]];
                      if (o.playerResponse) prune(o.playerResponse);
                    }
                    return o;
                  };
                  var jp = JSON.parse;
                  JSON.parse = function () { return prune(jp.apply(this, arguments)); };
                  var rj = Response.prototype.json;
                  Response.prototype.json = function () { return rj.apply(this, arguments).then(prune); };
                  var ipr;
                  Object.defineProperty(window, 'ytInitialPlayerResponse', { configurable: true,
                    get: function () { return ipr; }, set: function (v) { ipr = prune(v); } });
                }
              } catch (e) {}
              var last = null, endedFor = null;
              function hook(m) {
                if (m.__wb) return; m.__wb = 1;
                // Spotify also plays short muted clips of its own (not the song): their end isn't the song's end.
                m.addEventListener('ended', function () {
                  if (isAd() || (!yt() && (m.muted || !(m.duration > 30)))) return;
                  m.pause(); WB.ended('media ended');
                });
              }
              // EQ (YouTube only — Spotify's audio is DRM-protected, which Web Audio can't process): the media element
              // is routed through ten filters, only once a non-flat curve is asked for; after that a flat curve
              // just sets them to 0 dB.
              var eqG = null, actx = null, an = null, lv = null, chains = [], FREQ = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
              // Each wired element: its source and filters. route() connects only what's needed right now:
              // EQ shaped → filters (+ analyser); flat but a display watching → analyser only; neither → straight out.
              var wired = [];
              function shaped() { return !!eqG && eqG.some(function (g) { return g !== 0; }); }
              function eqWire(m) {
                if (m.__wbeq || location.hostname.indexOf('youtube') < 0) return;
                if (!lv && !shaped()) return;
                try {
                  // 'playback' = big buffers: a filter chain that never glitches (the default is tuned for low latency).
                  actx = actx || new AudioContext({ latencyHint: 'playback' });
                  an = an || actx.createAnalyser(); an.fftSize = 2048; an.smoothingTimeConstant = 0.5;
                  var src = actx.createMediaElementSource(m), fs = [], g0 = eqG || [0,0,0,0,0,0,0,0,0,0];
                  FREQ.forEach(function (f, i) {
                    var b = actx.createBiquadFilter();
                    b.type = i === 0 ? 'lowshelf' : i === 9 ? 'highshelf' : 'peaking';
                    b.frequency.value = f; b.Q.value = 1.1; b.gain.value = g0[i];
                    if (i > 0) fs[i - 1].connect(b);
                    fs.push(b);
                  });
                  var w = { src: src, fs: fs, mode: '' };
                  m.__wbeq = w; wired.push(w); chains.push(fs);
                  route();
                } catch (e) {}
              }
              function route() {
                var mode = shaped() ? 'eq' : lv ? 'an' : 'direct';
                wired.forEach(function (w) {
                  if (w.mode === mode) return;
                  w.src.disconnect(); w.fs[9].disconnect();
                  if (mode === 'eq') { w.src.connect(w.fs[0]); w.fs[9].connect(actx.destination); w.fs[9].connect(an); }
                  else { w.src.connect(actx.destination); if (mode === 'an') w.src.connect(an); }
                  w.mode = mode;
                });
              }
              var origPlay = HTMLMediaElement.prototype.play;
              HTMLMediaElement.prototype.play = function () {
                last = this; hook(this); eqWire(this);
                if (window.WBC && window.WBC.hold) { return Promise.resolve(); }
                return origPlay.apply(this, arguments);
              };
              // The playing element: the last one play() was called on (kept by the hook) — a page-wide search only when
              // there's none yet, at most every 2 s (YouTube Music's page has ~20,000 elements).
              var scanAt = 0, scanned = null;
              function media() {
                if (last && !last.paused) return last;
                var now = Date.now();
                if (now - scanAt > 2000) {
                  scanAt = now; scanned = null;
                  var all = document.getElementsByTagName('video');
                  for (var i = 0; i < all.length && !scanned; i++) if (!all[i].paused) scanned = all[i];
                  if (!scanned) { all = document.getElementsByTagName('audio'); for (var j = 0; j < all.length && !scanned; j++) if (!all[j].paused) scanned = all[j]; }
                  if (!scanned && !last) scanned = document.querySelector('video,audio');
                }
                return scanned || last;
              }
              function q(sel) { return document.querySelector(sel); }
              function text(sel) { var e = q(sel); return e ? (e.getAttribute('title') || e.textContent || '').trim() : ''; }
              function click(sel) { var b = q(sel); if (b) { b.click(); return true; } return false; }
              function secs(t) { return (t || '').split(':').reduce(function (a, p) { return a * 60 + (parseInt(p, 10) || 0); }, 0); }
              // Spotify plays through an element that isn't in the page: its player bar is the truth.
              function sp() {
                var b = q('[data-testid="control-button-playpause"]');
                if (!b) return null;
                return { playing: /pause/i.test(b.getAttribute('aria-label') || ''), btn: b,
                         pos: secs(text('[data-testid="playback-position"]')), dur: secs(text('[data-testid="playback-duration"]')),
                         title: text('[data-testid="context-item-info-title"]') };
              }
              // Ads: classes on YouTube's player and an attribute on the player bar — both elements kept, not searched for.
              var mpEl = null, barEl = null;
              function isAd() {
                if (!yt()) return false;
                if (!mpEl || !mpEl.isConnected) mpEl = document.getElementById('movie_player');
                if (!barEl || !barEl.isConnected) barEl = document.querySelector('ytmusic-player-bar');
                return !!((mpEl && (mpEl.classList.contains('ad-showing') || mpEl.classList.contains('ad-interrupting'))) || (barEl && barEl.hasAttribute('is-ad')));
              }
              function yt() { return location.hostname.indexOf('youtube') >= 0; }
              function meta() {
                var md = navigator.mediaSession && navigator.mediaSession.metadata;
                var t = '', a = '', art = '';
                if (yt()) {
                  t = text('ytmusic-player-bar .title');
                  var by = q('ytmusic-player-bar .byline');
                  if (by) a = Array.prototype.map.call(by.querySelectorAll('a'), function (x) { return x.textContent.trim(); })
                      .filter(function (x, i, arr) { return x && (i < arr.length - 1 || arr.length === 1); }).join(', ');
                  var img = q('ytmusic-player-bar img.image'); art = img ? img.src : '';
                } else {
                  t = text('[data-testid="context-item-info-title"]');
                  a = Array.prototype.map.call(document.querySelectorAll('[data-testid="context-item-info-artist"]'), function (x) { return x.textContent.trim(); }).join(', ');
                  var im = q('[data-testid="now-playing-widget"] img, [data-testid="cover-art-image"]'); art = im ? im.src : '';
                }
                if (!t && md) { t = md.title || ''; a = md.artist || ''; }
                if (!art && md && md.artwork && md.artwork.length) art = md.artwork[md.artwork.length - 1].src;
                return { title: t, artist: a, art: art };
              }
              window.WBC = {
                hold: false,
                hic: 0, waits: 0, lastT: 0, lastPos: 0, lastEl: null, startedAt: 0,
                expect: null,
                want: null,      // Spotify: 'play' or 'pause' — kept that way by settle(), one press at a time
                pressed: 0,
                settle: function () {
                  var s = sp();
                  if (!s || !WBC.want || Date.now() - WBC.pressed < 1500) return;
                  if ((WBC.want === 'play') !== s.playing) { WBC.pressed = Date.now(); s.btn.click(); }
                },
                play: function () {
                  WBC.hold = false;
                  WBC.startedAt = Date.now();
                  if (!yt()) { WBC.want = 'play'; WBC.settle(); return; }
                  var m = media();
                  if (m && m.src) { m.play(); return; }
                  click('[data-testid="control-button-playpause"]') || click('#play-pause-button') || click('main [data-testid="play-button"]');
                },
                pause: function () {
                  if (!yt()) { WBC.want = 'pause'; WBC.settle(); return; }
                  var m = media(); if (m) m.pause();
                },
                // The dot displays' spectrum: 8 log-spaced bands (60 Hz … 16 kHz) from the analyser, ~12 a second,
                // only while the app shows a display.
                levels: function (on) {
                  if (!on) { if (lv) clearInterval(lv); lv = null; route(); return; }
                  if (lv) return;
                  lv = setInterval(function () {
                    var m = media(); if (!m || m.paused || isAd()) return;
                    eqWire(m); if (!an) return;
                    if (actx.state === 'suspended') actx.resume();
                    var d = new Uint8Array(an.frequencyBinCount); an.getByteFrequencyData(d);
                    var hz = actx.sampleRate / an.fftSize, out = [];
                    for (var b = 0; b < 8; b++) {
                      var lo = Math.max(1, Math.floor(60 * Math.pow(16000 / 60, b / 8) / hz)), hi = Math.max(lo + 1, Math.floor(60 * Math.pow(16000 / 60, (b + 1) / 8) / hz)), p = 0;
                      for (var k = lo; k < hi && k < d.length; k++) p = Math.max(p, d[k]);
                      out.push((p / 255).toFixed(2));
                    }
                    WB.levels(out.join(','));
                  }, 100);
                  route();
                },
                eq: function (g) {
                  eqG = g;
                  chains.forEach(function (fs) { fs.forEach(function (b, i) { b.gain.value = g[i]; }); });
                  route();
                  var m = media(); if (m) eqWire(m);
                },
                stop: function () { WBC.hold = true; WBC.expect = null; WBC.pause(); },
                seek: function (sec) {
                  if (!yt()) {
                    // Spotify: a press on its progress bar at that point (setting the range input stalls its audio).
                    var pb = q('[data-testid="progress-bar"]'), s = sp();
                    if (pb && s && s.dur > 0) {
                      var r = pb.getBoundingClientRect(), f = Math.max(0, Math.min(1, sec / s.dur));
                      var o = { bubbles: true, cancelable: true, clientX: r.x + r.width * f, clientY: r.y + r.height / 2,
                                pointerId: 1, pointerType: 'mouse', button: 0, isPrimary: true };
                      [['pointerdown', PointerEvent, 1], ['mousedown', MouseEvent, 1], ['pointerup', PointerEvent, 0],
                       ['mouseup', MouseEvent, 0], ['click', MouseEvent, 0]].forEach(function (e) {
                        o.buttons = e[2]; pb.dispatchEvent(new e[1](e[0], o));
                      });
                    }
                    return;
                  }
                  var m = media(); if (m) m.currentTime = sec;
                },
                start: function () {
                  WBC.hold = false;
                  WBC.startedAt = Date.now();
                  if (!yt()) {
                    WBC.want = null;
                    // A Spotify track page: press its big Play once it's there; again only if nothing started.
                    var tries = 0, pressedAt = -10, t = setInterval(function () {
                      tries++;
                      var name = text('main [data-testid="entityTitle"]') || text('main h1');
                      var s = sp();
                      if (s && s.playing && name && s.title === name) { WBC.expect = name; WBC.want = 'play'; clearInterval(t); return; }
                      if (tries > 30) { clearInterval(t); return; }
                      var b = q('[data-testid="action-bar-row"] [data-testid="play-button"]');
                      if (b && name && tries - pressedAt >= 6 && !(s && s.playing && s.title === name)) { b.click(); pressedAt = tries; WBC.pressed = Date.now(); }
                    }, 500);
                    return;
                  }
                  var tries2 = 0, t2 = setInterval(function () {
                    tries2++;
                    var m = media();
                    if ((m && !m.paused) || tries2 > 25) { clearInterval(t2); return; }
                    click('#play-pause-button') || (m && m.play && m.play());
                  }, 800);
                },
                // YouTube Music, already open: go to another song inside the page (as tapping a song in it does) instead
                // of loading the whole site again. If the page didn't move to it within 1.5 s, load it the slow way.
                go: function (id) {
                  WBC.hold = false; WBC.expect = null; WBC.itag = 0;
                  WBC.startedAt = Date.now();
                  var m0 = media(); if (m0 && !m0.paused) m0.pause(); // the old song stops now, not when the new one loads
                  var url = '/watch?v=' + encodeURIComponent(id), app = q('ytmusic-app');
                  var full = function () { location.href = url; };
                  if (!app) return full();
                  try {
                    app.dispatchEvent(new CustomEvent('yt-navigate', { bubbles: true, composed: true, detail: { endpoint: {
                      commandMetadata: { webCommandMetadata: { url: url, webPageType: 'MUSIC_PAGE_TYPE_WATCH' } },
                      watchEndpoint: { videoId: id } } } }));
                  } catch (e) { return full(); }
                  setTimeout(function () {
                    if (location.href.indexOf('v=' + id) < 0) return full();
                    WBC.start();
                  }, 1500);
                }
              };
              var ticks = 0, md = { title: '', artist: '', art: '' };
              (function tick() {
                var m = media(), ad = isAd();
                ticks++;
                // YouTube ads: muted and skipped to their end (or the Skip button pressed).
                if (ad && m) {
                  m.muted = true;
                  if (isFinite(m.duration) && m.duration > 0) m.currentTime = m.duration;
                  click('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
                } else if (m && m.muted && yt()) m.muted = false;
                if (actx && actx.state === 'suspended' && m && !m.paused) actx.resume();
                // Hiccups: while playing, the song's clock should advance with the wall clock; a tick where it moved
                // much less (or the element had to wait for data) is a stutter. Counted for the log / testing.
                var now = Date.now();
                if (yt() && m && !m.paused && !m.seeking && !ad && WBC.lastT && WBC.lastEl === m) {
                  var wall = (now - WBC.lastT) / 1000, moved = m.currentTime - WBC.lastPos;
                  if (wall > 0.3 && moved >= 0 && moved < wall * 0.75) WBC.hic++;
                }
                if (m && !m.__wbw) { m.__wbw = 1; m.addEventListener('waiting', function () { if (!m.paused) WBC.waits++; }); }
                WBC.lastT = now; WBC.lastPos = m ? m.currentTime : 0; WBC.lastEl = m;
                var itag = WBC.itag || 0;
                // The stream's format, read once per song (the stats call isn't free).
                if (yt() && (!itag || WBC.itagFor !== location.href)) try {
                  var mp = document.getElementById('movie_player'), sn = mp && mp.getStatsForNerds && mp.getStatsForNerds();
                  var mt = sn && sn.codecs && sn.codecs.match(/\((\d+)\)[^()]*$/); if (mt) { itag = +mt[1]; WBC.itag = itag; WBC.itagFor = location.href; }
                } catch (e) {}
                // Song info is only for the log: read every 10th tick.
                if (ticks % 10 === 1) md = meta();
                var st = { itag: itag, hic: WBC.hic, waits: WBC.waits,
                  has: !!(m && (m.currentSrc || m.src || m.readyState > 0 || m.currentTime > 0)), paused: m ? m.paused : true, pos: m ? m.currentTime : 0, dur: m ? m.duration : 0,
                  ended: m ? m.ended : false, ad: ad, title: md.title, artist: md.artist, art: md.art, url: location.href
                };
                if (!yt()) {
                  var s = sp();
                  if (s) { st.has = s.dur > 0; st.paused = !s.playing; st.pos = s.pos; st.dur = s.dur; st.ended = false; }
                  // Spotify carried on to another song by itself: ours has ended.
                  if (WBC.expect && s && s.title && s.title !== WBC.expect) { WBC.expect = null; WBC.want = 'pause'; WB.ended('spotify moved on to ' + s.title); }
                  WBC.settle();
                }
                WB.state(JSON.stringify(st));
                // Twice a second while something plays or is being started; every 2 s when idle (paused, held, stopped).
                var busy = (m && !m.paused) || WBC.want === 'play' || (!yt() && st.has && !st.paused) || Date.now() - WBC.startedAt < 15000;
                setTimeout(tick, busy ? 500 : 2000);
              })();
            })();
        """.trimIndent()
    }
}

/** The page that plays: opens a track and reports how it's going. */
class WebEngine(context: Context, service: Service, private val state: (WebState) -> Unit, private val ended: (String) -> Unit) : WebPage(context, service) {
    @Volatile var last = WebState()
        private set

    /** The page has YouTube Music loaded (not parked): a new song can be switched to inside it. */
    private var siteOpen = false

    override fun onState(s: WebState) {
        last = s
        siteOpen = s.url.startsWith(Service.YOUTUBE.origin)
        state(s)
    }

    override fun onEnded(why: String) = ended(why)

    /** Bumped by every play / pause / stop, so a delayed start meant for an earlier request does nothing. */
    private var gen = 0

    fun playTrack(id: String) {
        warmed = true
        important(true)
        val g = ++gen
        // YouTube Music already open in the page: switch songs inside it (well under a second) rather than reloading
        // the whole site (several seconds). The page falls back to a full load by itself if that doesn't take.
        val live = service == Service.YOUTUBE && siteOpen
        last = WebState()
        if (live) {
            js("WBC.go(${JSONObject.quote(id)})")
            eq(Eq.state.value.effective)
            if (levelsOn) js("WBC.levels(true)")
            // Backup: if it still isn't playing (e.g. the page had to fall back to a full load), press play.
            main.postDelayed({ if (gen == g) js("WBC.start()") }, 4500)
            return
        }
        open(when (service) {
            Service.YOUTUBE -> "https://music.youtube.com/watch?v=$id"
            Service.SPOTIFY -> "https://open.spotify.com/track/$id"
        })
        // The page's script starts the track once it's loaded (Spotify waits for a press of its play button).
        main.postDelayed({ if (gen == g) { js("WBC.start()"); eq(Eq.state.value.effective); if (levelsOn) js("WBC.levels(true)") } }, 2500)
    }

    fun eq(gains: List<Float>) = js("WBC.eq([${gains.joinToString(",")}])")
    private var levelsOn = false
    fun levels(on: Boolean) { if (on != levelsOn || on) { levelsOn = on; js("WBC.levels($on)") } }

    fun play() { important(true); js("WBC.play()") }
    fun pause() { gen++; js("WBC.pause()"); important(false) }

    override fun park() {
        last = WebState()
        siteOpen = false
        warmed = false
        levelsOn = false
        super.park()
    }
    /**
     * Done with this page for now (another song or source is up). YouTube: paused and held. Spotify: the page is
     * unloaded — its player otherwise carries on through its own autoplay, and shows as "playing on Web Player" on
     * the account's other devices.
     */
    private var warmed = false

    /**
     * Spotify, ahead of its first song: open the web player and start its DRM module (Widevine) — the slow part of a
     * first play — so the song itself starts at once. Once per app run; nothing plays.
     */
    fun warm() {
        if (warmed || service != Service.SPOTIFY) return
        warmed = true
        open("https://open.spotify.com/")
        main.postDelayed({
            main.post {
                view.evaluateJavascript(
                    "navigator.requestMediaKeySystemAccess('com.widevine.alpha',[{initDataTypes:['cenc'],audioCapabilities:[{contentType:'audio/mp4;codecs=\"mp4a.40.2\"'}]}])" +
                        ".then(function(a){return a.createMediaKeys();}).then(function(){window.__wbWarm=1;})", null)
            }
        }, 4000)
    }

    fun stop() {
        gen++
        important(false)
        if (service == Service.SPOTIFY) {
            last = WebState()
            open("about:blank") // queued on the main thread, so a playTrack() right after still wins
        } else js("WBC.stop()")
    }
    fun seek(seconds: Double) {
        js("WBC.seek($seconds)")
        // The page may not report again while paused: show the new position at once instead of the stale one.
        last = last.copy(position = seconds, at = System.currentTimeMillis())
    }

    companion object {
        /** A desktop Chrome on Linux on this WebView's engine version: both services serve their full web player to it. */
        fun userAgent(): String {
            val chrome = runCatching { WebView.getCurrentWebViewPackage()?.versionName?.substringBefore('.') }.getOrNull() ?: "140"
            return "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$chrome.0.0.0 Safari/537.36"
        }
    }
}

/** Spotify search through a second hidden, signed-in page (no developer key needed). */
class SpotifySearch private constructor(context: Context) : WebPage(context, Service.SPOTIFY) {
    private var pending: CompletableDeferred<List<Track>>? = null
    private var pendingData: CompletableDeferred<JSONObject>? = null
    private val idle = Runnable { if (pending == null && pendingData == null) park() }

    init {
        // Notes the web player's own sign-in token as it talks to Spotify, so [library] can ask for your history with it.
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            main.post { WebViewCompat.addDocumentStartJavaScript(view, TOKEN_SCRIPT, setOf(Service.SPOTIFY.origin)) }
        }
    }

    /**
     * Your Spotify listening, read with the web player's token: recently played, top songs (3 ranges), top artists,
     * saved songs (up to 1,000). Each song slimmed to id / name / artists / album / art / dur (/ at).
     */
    suspend fun library(): JSONObject {
        pendingData?.cancel()
        val d = CompletableDeferred<JSONObject>()
        pendingData = d
        open("https://open.spotify.com/collection/tracks")
        main.postDelayed({ main.post { view.evaluateJavascript(LIBRARY_SCRIPT, null) } }, 1500)
        return d.await()
    }

    override fun onData(json: String) {
        val j = runCatching { JSONObject(json) }.getOrElse { JSONObject().put("error", "unreadable answer") }
        live = !j.has("error")
        pendingData?.complete(j)
        pendingData = null
        main.removeCallbacks(idle)
        main.postDelayed(idle, 120_000)
    }

    /** The page is loaded and showing Spotify (not parked): a new search can move inside it instead of reloading it. */
    private var live = false

    suspend fun search(q: String): List<Track> {
        pending?.cancel()
        val d = CompletableDeferred<List<Track>>()
        pending = d
        val path = "/search/${URLEncoder.encode(q, "UTF-8").replace("+", "%20")}/tracks"
        if (live) {
            // Spotify's page is a single-page app: going to the new search inside it skips loading the whole player
            // again (3–5 s → well under one).
            main.post {
                // Remember the old first result: until the list changes, what's on screen is still the last search.
                view.evaluateJavascript("(function(){var a=document.querySelector('[data-testid=\"tracklist-row\"] a[href*=\"/track/\"]');window.__wbPrev=a?a.getAttribute('href'):null;" +
                    "history.pushState({}, '', ${JSONObject.quote(path)}); dispatchEvent(new PopStateEvent('popstate'));})()", null)
                main.postDelayed({ js(read(q)) }, 300)
            }
        } else {
            open("https://open.spotify.com$path")
            main.postDelayed({ js(read(q)) }, 1500)
        }
        return d.await()
    }

    override fun park() { live = false; super.park() }

    override fun onResults(json: String) {
        if (json == "null") { live = false; pending?.completeExceptionally(IllegalStateException("search page didn't load")); pending = null; return }
        live = true
        val a = runCatching { JSONArray(json) }.getOrNull() ?: return
        val list = (0 until a.length()).mapNotNull { i ->
            val o = a.getJSONObject(i)
            val id = o.optString("id").ifEmpty { return@mapNotNull null }
            val dur = o.optString("dur").split(':').mapNotNull { it.toLongOrNull() }.fold(0L) { acc, p -> acc * 60 + p } * 1000
            Track(Source.SPOTIFY, id, o.optString("title"), o.optString("artist"), o.optString("album").ifEmpty { null }, dur,
                o.optString("art").ifEmpty { null })
        }
        pending?.complete(list)
        pending = null
        // Nothing else to do here until the next search (which loads its own page): unload after 2 minutes.
        main.removeCallbacks(idle)
        main.postDelayed(idle, 120_000)
    }

    companion object {
        /**
         * Reads the result rows once they've rendered (checks every 0.25 s for ~10 s). Only rows of THIS query count: if the page is
         * still an older search (or the new one never loaded, e.g. offline) the answer is empty, never stale rows.
         */
        private fun read(q: String) = """
            (function () {
              var want = ${org.json.JSONObject.quote(q.lowercase())}, tries = 0;
              function onPage() { try { return decodeURIComponent(location.pathname).toLowerCase().indexOf('/search/' + want + '/') === 0; } catch (e) { return false; } }
              var t = setInterval(function () {
                tries++;
                var rows = onPage() ? document.querySelectorAll('[data-testid="tracklist-row"]') : [];
                var firstA = rows.length ? rows[0].querySelector('a[href*="/track/"]') : null;
                var same = window.__wbPrev && firstA && firstA.getAttribute('href') === window.__wbPrev;
                if ((!rows.length || (same && tries < 16)) && tries < 40) return;
                window.__wbPrev = null;
                clearInterval(t);
                if (!onPage()) { WB.results('null'); return; } // never loaded (offline / blocked): report it, don't guess
                var out = [];
                Array.prototype.forEach.call(rows, function (r) {
                  var a = r.querySelector('a[href*="/track/"]'); if (!a) return;
                  var id = (a.getAttribute('href').match(/track\/([A-Za-z0-9]+)/) || [])[1];
                  var artists = Array.prototype.map.call(r.querySelectorAll('a[href*="/artist/"]'), function (x) { return x.textContent.trim(); });
                  var al = r.querySelector('a[href*="/album/"]');
                  var img = r.querySelector('img');
                  // The time cell on its own: the row's joined text glues "Aug 12, 2024" to "3:45" (→ "43:45").
                  var dur = '', w = document.createTreeWalker(r, NodeFilter.SHOW_TEXT), n;
                  while ((n = w.nextNode())) { var t = n.nodeValue.trim(); if (/^(\d{1,2}:)?\d{1,2}:\d{2}$/.test(t)) dur = t; }
                  out.push({ id: id, title: a.textContent.trim(), artist: artists.join(', '), album: al ? al.textContent.trim() : '',
                             art: img ? img.src.replace('ab67616d00004851', 'ab67616d00001e02') : '', dur: dur });
                });
                WB.results(JSON.stringify(out));
              }, 250);
            })();
        """.trimIndent()

        private val TOKEN_SCRIPT = """
            (function () {
              if (window.__wbHook) return; window.__wbHook = 1;
              function note(v) { if (v && /^Bearer /i.test(v)) window.__wbAuth = v; }
              var f = window.fetch;
              window.fetch = function (input, init) {
                try {
                  var h = init && init.headers;
                  if (h) note(typeof h.get === 'function' ? h.get('authorization') : (h.authorization || h.Authorization));
                  if (input && input.headers && typeof input.headers.get === 'function') note(input.headers.get('authorization'));
                } catch (e) {}
                return f.apply(this, arguments);
              };
              var set = XMLHttpRequest.prototype.setRequestHeader;
              XMLHttpRequest.prototype.setRequestHeader = function (k, v) { try { if (String(k).toLowerCase() === 'authorization') note(v); } catch (e) {} return set.apply(this, arguments); };
            })();
        """.trimIndent()

        /**
         * Reads your Spotify listening from the web player's own pages (its public Web API refuses the web player's token
         * with 429): Liked Songs (scrolled through, up to 600), your profile's "Top tracks this month" and top artists.
         */
        private val LIBRARY_SCRIPT = """
            (async function () {
              function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
              function rows() {
                return Array.prototype.map.call(document.querySelectorAll('[data-testid="tracklist-row"]'), function (r) {
                  var a = r.querySelector('a[href*="/track/"]'); if (!a) return null;
                  var id = (a.getAttribute('href').match(/track\/([A-Za-z0-9]+)/) || [])[1]; if (!id) return null;
                  var artists = Array.prototype.map.call(r.querySelectorAll('a[href*="/artist/"]'), function (x) { return x.textContent.trim(); });
                  var al = r.querySelector('a[href*="/album/"]'), img = r.querySelector('img');
                  // The time cell on its own: the row's joined text glues "Aug 12, 2024" to "3:45" (→ "43:45").
                  var d = '0:00', w = document.createTreeWalker(r, NodeFilter.SHOW_TEXT), n;
                  while ((n = w.nextNode())) { var t = n.nodeValue.trim(); if (/^(\d{1,2}:)?\d{1,2}:\d{2}$/.test(t)) d = t; }
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
                // Liked Songs: the list only renders what's on screen, so scroll and collect.
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
                var me = u ? (u.getAttribute('href').match(/user\/([^/?#]+)/) || [])[1] : null;
                if (me) {
                  // Ready = its own heading is up (the old page's rows can linger for a moment).
                  var main = function () { var m = document.querySelector('main'); return m ? m.innerText : ''; };
                  if (await go('/user/' + me + '/top/tracks', function () { return main().indexOf('Top tracks') >= 0 && rows().length > 0; })) { await sleep(800); out.top_short_term = rows(); }
                  if (await go('/user/' + me + '/top/artists', function () { return main().indexOf('Top artists') >= 0 && document.querySelector('[data-encore-id="card"] a[href*="/artist/"]'); })) {
                    await sleep(800);
                    var names = {};
                    Array.prototype.forEach.call(document.querySelectorAll('[data-encore-id="card"]'), function (c) {
                      var a = c.querySelector('a[href*="/artist/"]'); var name = a ? (a.getAttribute('title') || a.textContent || '').trim() : '';
                      if (!name) name = (c.innerText || '').split('\n')[0].trim();
                      if (name && !names[name]) { names[name] = 1; out.artists.push(name); }
                    });
                  }
                }
              } catch (e) { out.error = String(e); }
              if (!out.saved.length && !out.top_short_term.length && !out.artists.length) out.error = out.error || 'nothing found — signed in to Spotify?';
              WB.data(JSON.stringify(out));
            })();
        """.trimIndent()

        @Volatile private var instance: SpotifySearch? = null
        fun get(c: Context) = instance ?: synchronized(this) {
            instance ?: SpotifySearch(c.applicationContext).also { instance = it }
        }
    }
}

/**
 * Ad blocking, on by default: known ad and tracking hosts never load in the hidden pages. (YouTube's in-video ads come
 * from the same servers as the music, so the page script mutes and skips those instead.)
 */
object AdBlock {
    @Volatile var enabled = true
    private val hosts = listOf(
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com", "googletagmanager.com",
        "googletagservices.com", "adservice.google.com", "imasdk.googleapis.com", "pagead2.googlesyndication.com",
        "adeventtracker.spotify.com", "ads-fa.spotify.com", "analytics.spotify.com", "pubads.g.doubleclick.net",
        "securepubads.g.doubleclick.net", "scorecardresearch.com", "moatads.com", "adnxs.com", "omtrdc.net",
    )
    private val paths = listOf("/pagead/", "/ptracking", "/api/stats/ads", "/get_midroll_", "youtube.com/api/stats/atr", "/ad-logic/", "/ads/")

    fun blocks(host: String, url: String) = hosts.any { host == it || host.endsWith(".$it") } ||
        ((host.endsWith("youtube.com") || host.endsWith("spotify.com")) && paths.any { url.contains(it) })
}
