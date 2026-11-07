import ActivityKit
import SwiftUI
import WidgetKit

// Now playing as a Live Activity, in the Y2K widget's pieces (candy play, peach Doto clock, lilac badges, the
// iridescent rim):
//  - lock screen / banner (every iPhone): cover, title, badges, transport, clock + seek bar;
//  - Dynamic Island (Pro models): compact = cover + running clock, minimal = cover, expanded = cover, title, candy
//    play, seek bar and the keys.
// The clocks and bars run by themselves; the app updates the activity only when something it shows changes. Once
// it's stale (the app went away mid-song) it reads as paused.

struct PlayerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlayerActivityAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color(hex: 0x16141C))
                .activitySystemActionForegroundColor(Y2K.lilac)
                .widgetURL(NowPlaying.openURL)
        } dynamicIsland: { context in
            let st = context.state
            let s = snapshot(st, stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Cover(art: st.art, size: 58, radius: 12).padding(.leading, 4).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: PlayerCommandIntent(.toggle)) { Candy(size: 50, playing: s.playing) }
                        .buttonStyle(.plain).padding(.trailing, 4).padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text("WRECKBOX").font(Y2K.dot(8.5, .black)).tracking(1.4)
                                .foregroundStyle(LinearGradient(colors: Y2K.smartColors, startPoint: .leading, endPoint: .trailing))
                            Spacer(minLength: 4)
                            badges(st)
                        }
                        Text(st.title).font(Y2K.ui(16, .bold)).foregroundStyle(Y2K.text).lineLimit(1)
                        Text(st.artist).font(Y2K.ui(13, .medium)).foregroundStyle(Y2K.text2).lineLimit(1)
                    }
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        TimeRow(s: s, start: st.start, end: st.end)
                        HStack(spacing: 0) {
                            key(.like, st.liked ? "heart.fill" : "heart", lit: st.liked)
                            Spacer()
                            key(.back10, "gobackward.10")
                            Spacer()
                            key(.previous, "backward.end.fill")
                            Spacer()
                            key(.next, "forward.end.fill")
                            Spacer()
                            key(.fwd10, "goforward.10")
                        }
                        .padding(.horizontal, 6)
                    }
                    .padding(.horizontal, 4).padding(.bottom, 2)
                }
            } compactLeading: {
                Cover(art: st.art, size: 24, radius: 7)
            } compactTrailing: {
                CompactClock(s: s, start: st.start, end: st.end)
            } minimal: {
                Cover(art: st.art, size: 24, radius: 12)
            }
            .keylineTint(Y2K.lilac)
            .widgetURL(NowPlaying.openURL)
        }
    }

    private func badges(_ st: PlayerActivityAttributes.ContentState) -> some View {
        HStack(spacing: 3) {
            if !st.sourceBadge.isEmpty { Badge(text: st.sourceBadge) }
            if !st.format.isEmpty { Badge(text: st.format) }
        }
    }

    private func key(_ c: WidgetCommand, _ glyph: String, lit: Bool = false) -> some View {
        Button(intent: PlayerCommandIntent(c)) { RoundKey(glyph: glyph, lit: lit) }.buttonStyle(.plain)
    }
}

/// The activity's state as the widgets' snapshot (so it can use their clock and seek bar). Stale = paused where the
/// song would have ended.
func snapshot(_ st: PlayerActivityAttributes.ContentState, stale: Bool) -> WidgetSnapshot {
    var s = WidgetSnapshot(title: st.title, artist: st.artist, playing: st.playing && !stale, position: st.position, duration: st.duration, at: st.at)
    if stale && st.playing { s.position = st.duration }
    return s
}

/// The lock screen (and the banner on iPhones without the island).
private struct LockScreenView: View {
    let state: PlayerActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        let s = snapshot(state, stale: stale)
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Cover(art: state.art, size: 58, radius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Disc(size: 12, tile: true)
                        Text("WRECKBOX").font(Y2K.dot(8.5, .black)).tracking(1.4)
                            .foregroundStyle(LinearGradient(colors: Y2K.smartColors, startPoint: .leading, endPoint: .trailing))
                        if !state.sourceBadge.isEmpty { Badge(text: state.sourceBadge) }
                        if !state.format.isEmpty { Badge(text: state.format) }
                    }
                    Text(state.title).font(Y2K.ui(16, .bold)).foregroundStyle(Y2K.text).lineLimit(1)
                    Text(state.artist).font(Y2K.ui(13, .medium)).foregroundStyle(Y2K.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button(intent: PlayerCommandIntent(.previous)) { RoundKey(glyph: "backward.end.fill") }.buttonStyle(.plain)
                    Button(intent: PlayerCommandIntent(.toggle)) { Candy(size: 46, playing: s.playing) }.buttonStyle(.plain)
                    Button(intent: PlayerCommandIntent(.next)) { RoundKey(glyph: "forward.end.fill") }.buttonStyle(.plain)
                }
            }
            TimeRow(s: s, start: state.start, end: state.end)
        }
        .padding(14)
        .overlay(ContainerRelativeShape().strokeBorder(LinearGradient(colors: Y2K.smartColors.map { $0.opacity(0.7) }, startPoint: .leading, endPoint: .trailing), lineWidth: 1.2))
    }
}

/// Elapsed (peach Doto, running) · the seek bar · the length.
private struct TimeRow: View {
    let s: WidgetSnapshot
    let start: Date, end: Date
    var body: some View {
        HStack(spacing: 8) {
            Group {
                if s.playing && s.duration > 0 { Text(timerInterval: start...end, countsDown: false) } else { Text(NowPlaying.time(s.position)) }
            }
            .font(Y2K.dot(12, .black)).foregroundStyle(Y2K.peach).monospacedDigit()
            .frame(width: 38, alignment: .leading)
            SeekBar(fraction: s.duration > 0 ? min(1, s.position / s.duration) : 0).frame(height: 5)
            Text(s.duration > 0 ? NowPlaying.time(s.duration) : "--:--").font(Y2K.dot(12, .black)).foregroundStyle(Y2K.lilac.opacity(0.8))
                .monospacedDigit().frame(width: 38, alignment: .trailing)
        }
    }
}

/// The compact island's right side: the running clock while playing, a pause mark otherwise.
private struct CompactClock: View {
    let s: WidgetSnapshot
    let start: Date, end: Date
    var body: some View {
        Group {
            if s.playing && s.duration > 0 {
                Text(timerInterval: start...end, countsDown: false).multilineTextAlignment(.trailing)
            } else if s.playing {
                Image(systemName: "waveform")
            } else {
                Image(systemName: "pause.fill")
            }
        }
        .font(Y2K.dot(13, .black)).foregroundStyle(s.playing ? Y2K.peach : Y2K.lilac).monospacedDigit()
        .frame(maxWidth: 44, alignment: .trailing)
    }
}

/// The cover from the App Group with the iridescent rim; the pixel record on its tile when there's none.
private struct Cover: View {
    let art: String
    let size: CGFloat
    let radius: CGFloat
    var body: some View {
        Group {
            if !art.isEmpty, let img = WidgetFiles.art.flatMap({ UIImage(contentsOfFile: $0.path) }) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Disc(size: size, tile: true)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LinearGradient(colors: Y2K.smartColors, startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: size > 30 ? 1.5 : 1))
    }
}

/// A round glossy smoked key (lit: the candy gradient).
private struct RoundKey: View {
    let glyph: String
    var lit = false
    var body: some View {
        ZStack {
            Circle().fill(lit ? AnyShapeStyle(LinearGradient(colors: Y2K.smartColors, startPoint: .leading, endPoint: .trailing))
                              : AnyShapeStyle(LinearGradient(colors: [Ink.keyTop, Ink.keyBottom], startPoint: .top, endPoint: .bottom)))
            Circle().strokeBorder(.white.opacity(lit ? 0.6 : 0.22), lineWidth: 1)
            Ellipse().fill(LinearGradient(colors: [.white.opacity(lit ? 0.5 : 0.2), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: 24, height: 14).offset(y: -8)
            Image(systemName: glyph).font(.system(size: 14, weight: .heavy)).foregroundStyle(lit ? Ink.candyText : Y2K.text)
        }
        .frame(width: 38, height: 38)
    }
}
