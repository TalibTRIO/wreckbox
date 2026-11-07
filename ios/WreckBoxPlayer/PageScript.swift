import Foundation

// The page script every hidden streaming page runs: the same one as the Mac Player's YouTubeEngine and the Android
// Player's WebEngine (YouTube parts). Keeps the page believing it's on screen, catches the media element, reports
// state every half second, fires `ended` when a song finishes, routes audio through the EQ, and skips ads.
extension WebEngine {
    static let pageScript = """
    (function () {
      if (window.WBC) return;
      var post = function (k, v) { try { window.webkit.messageHandlers.wb.postMessage({ k: k, v: v }); } catch (e) {} };
      var WB = { state: function (j) { post('state', j); }, ended: function (w) { post('ended', w); }, levels: function (c) { post('levels', c); } };
      var BLOCK_ADS = \(Prefs.blockAds ? "true" : "false");
      try {
        Object.defineProperty(document, 'visibilityState', { get: function () { return 'visible'; } });
        Object.defineProperty(document, 'hidden', { get: function () { return false; } });
        document.addEventListener('visibilitychange', function (e) { e.stopImmediatePropagation(); }, true);
        window.addEventListener('blur', function (e) { e.stopImmediatePropagation(); }, true);
      } catch (e) {}
      var last = null;
      function hook(m) {
        if (m.__wb) return; m.__wb = 1;
        m.addEventListener('ended', function () { if (isAd()) return; m.pause(); WB.ended('media ended'); });
      }
      var eqG = null, actx = null, an = null, lv = null, wired = [], FREQ = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
      function shaped() { return !!eqG && eqG.some(function (g) { return g !== 0; }); }
      function eqWire(m) {
        if (m.__wbeq) return;
        if (!lv && !shaped()) return;
        try {
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
          m.__wbeq = w; wired.push(w);
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
        if (window.WBC && window.WBC.hold) return Promise.resolve();
        return origPlay.apply(this, arguments);
      };
      var scanAt = 0, scanned = null;
      function media() {
        if (last && !last.paused) return last;
        var now = Date.now();
        if (now - scanAt > 2000) {
          scanAt = now; scanned = null;
          var all = document.getElementsByTagName('video');
          for (var i = 0; i < all.length && !scanned; i++) if (!all[i].paused) scanned = all[i];
          if (!scanned && !last) scanned = document.querySelector('video,audio');
        }
        return scanned || last;
      }
      function q(sel) { return document.querySelector(sel); }
      function click(sel) { var b = q(sel); if (b) { b.click(); return true; } return false; }
      var mpEl = null, barEl = null;
      function isAd() {
        if (!mpEl || !mpEl.isConnected) mpEl = document.getElementById('movie_player');
        if (!barEl || !barEl.isConnected) barEl = document.querySelector('ytmusic-player-bar');
        return !!((mpEl && (mpEl.classList.contains('ad-showing') || mpEl.classList.contains('ad-interrupting'))) || (barEl && barEl.hasAttribute('is-ad')));
      }
      window.WBC = {
        hold: false, startedAt: 0,
        play: function () {
          WBC.hold = false; WBC.startedAt = Date.now();
          var m = media();
          if (m && m.src) { m.play(); return; }
          click('#play-pause-button');
        },
        pause: function () { var m = media(); if (m) m.pause(); },
        stop: function () { WBC.hold = true; WBC.pause(); },
        seek: function (sec) { var m = media(); if (m) m.currentTime = sec; },
        eq: function (g) {
          eqG = g;
          wired.forEach(function (w) { w.fs.forEach(function (b, i) { b.gain.value = g[i]; }); });
          route();
          var m = media(); if (m) eqWire(m);
        },
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
        start: function () {
          WBC.hold = false; WBC.startedAt = Date.now();
          var tries = 0, t = setInterval(function () {
            tries++;
            var m = media();
            if ((m && !m.paused) || tries > 25) { clearInterval(t); return; }
            click('#play-pause-button') || (m && m.play && m.play());
          }, 800);
        }
      };
      (function tick() {
        var m = media(), ad = isAd();
        if (ad && m && BLOCK_ADS) {
          m.muted = true;
          if (isFinite(m.duration) && m.duration > 0) m.currentTime = m.duration;
          click('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
        } else if (m && m.muted) m.muted = false;
        if (actx && actx.state === 'suspended' && m && !m.paused) actx.resume();
        var itag = WBC.itag || 0;
        if (!itag || WBC.itagFor !== location.href) try {
          var mp = document.getElementById('movie_player'), sn = mp && mp.getStatsForNerds && mp.getStatsForNerds();
          var mt = sn && sn.codecs && sn.codecs.match(/\\((\\d+)\\)[^()]*$/); if (mt) { itag = +mt[1]; WBC.itag = itag; WBC.itagFor = location.href; }
        } catch (e) {}
        WB.state(JSON.stringify({ itag: itag,
          has: !!(m && (m.currentSrc || m.src || m.readyState > 0 || m.currentTime > 0)), paused: m ? m.paused : true,
          pos: m ? m.currentTime : 0, dur: m ? m.duration : 0, ended: m ? m.ended : false, ad: ad, url: location.href }));
        var busy = (m && !m.paused) || Date.now() - WBC.startedAt < 15000;
        setTimeout(tick, busy ? 500 : 2000);
      })();
    })();
    """
}
