import ActivityKit
import UIKit

/// The now-playing Live Activity (lock screen + Dynamic Island), fed by WidgetBridge, so it changes only when
/// something it shows does.
///  - iOS only lets an app start one while it's in front: it starts when music plays with the app open (or when the
///    app comes to the front with music playing), then stays — paused too — until the queue empties, it's switched
///    off in Settings, or the app quits. Updates from the background are fine.
///  - One at a time: a leftover one from an earlier run is taken over, extras ended.
@MainActor
final class LiveActivityBridge {
    static let shared = LiveActivityBridge()
    private var activity: Activity<PlayerActivityAttributes>?
    private var last: (snap: WidgetSnapshot, art: String)?
    private var lastState: PlayerActivityAttributes.ContentState?
    /// While playing: moves the seek bar along every few seconds (it's a plain shape — see SeekBar).
    private var ticker: Timer?

    func start() {
        let all = Activity<PlayerActivityAttributes>.activities
        activity = all.first
        for a in all.dropFirst() { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        if activity != nil { Log.shared.write("live activity: took over the running one") }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LiveActivityBridge.shared.resync() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LiveActivityBridge.shared.endNow() }
        }
    }

    /// The player changed (or its cover arrived): start, update or end the activity.
    func sync(_ snap: WidgetSnapshot, art: String) {
        last = (snap, art)
        tick(snap.playing && snap.duration > 0)
        guard Prefs.liveActivity, let state = PlayerActivityAttributes.ContentState(snap, art: art) else { return end("nothing playing") }
        if let a = activity, a.activityState == .active || a.activityState == .stale {
            guard state != lastState else { return }
            lastState = state
            Task { await a.update(content(state)) }
            return
        }
        activity = nil
        guard snap.playing, UIApplication.shared.applicationState == .active else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return Log.shared.write("live activity: switched off for WreckBox in iOS Settings") }
        do {
            activity = try Activity.request(attributes: PlayerActivityAttributes(), content: content(state))
            lastState = state
            Log.shared.write("live activity: started")
        } catch {
            Log.shared.write("live activity: couldn't start (\(error.localizedDescription))")
        }
    }

    /// Back in front: start one if music plays and there's none (iOS may have ended it, or it was started in the
    /// background), or catch up after Settings.
    func resync() {
        if let last { sync(last.snap, art: last.art) }
    }

    private func tick(_ on: Bool) {
        if !on { ticker?.invalidate(); ticker = nil; return }
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let me = LiveActivityBridge.shared
                guard let a = me.activity, var st = me.lastState, st.playing else { return }
                st.position = min(st.duration, st.position + Date().timeIntervalSince(st.at))
                st.at = Date()
                me.lastState = st
                Task { await a.update(me.content(st)) }
            }
        }
    }

    private func content(_ state: PlayerActivityAttributes.ContentState) -> ActivityContent<PlayerActivityAttributes.ContentState> {
        // Playing: stale shortly after the song should have ended (the app would have said otherwise).
        ActivityContent(state: state, staleDate: state.playing && state.duration > 0 ? state.end.addingTimeInterval(30) : nil)
    }

    private func end(_ why: String) {
        tick(false)
        guard let a = activity else { return }
        activity = nil
        lastState = nil
        Log.shared.write("live activity: ended (\(why))")
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    /// The app is quitting: end it before the process goes (waits up to a second).
    private func endNow() {
        guard let a = activity else { return }
        activity = nil
        let done = DispatchSemaphore(value: 0)
        Task.detached { await a.end(nil, dismissalPolicy: .immediate); done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }
}
