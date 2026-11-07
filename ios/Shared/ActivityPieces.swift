import SwiftUI

// The Live Activity's pieces in the WreckBox look — shapes and gradients only (no pictures, Canvas, shadows,
// GeometryReader or ProgressView(timerInterval:): its built-in GeometryReader crashed iOS 27's widget renderer with
// "view origin is invalid: (nan, 3.0)").
// (There's no home-screen widget in the first build: on the iPhone it froze on an old picture.)

enum NowPlaying {
    /// Tapping the Live Activity opens Now playing.
    static let openURL = URL(string: "wreckbox://show?page=playing")!

    static func time(_ s: Double) -> String { let i = Int(max(0, s)); return String(format: "%d:%02d", i / 60, i % 60) }
}

/// The palette's darks, as on Android.
enum Ink {
    static let well = Color(hex: 0x07060A)
    static let keyTop = Color(hex: 0x34303F), keyBottom = Color(hex: 0x16141C)
    static let candyText = Color(hex: 0x0A0A0C)
}

/// The seek bar: a dark well with a peach fill (Android's wb_seek).
struct SeekBar: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Capsule().fill(Ink.well)
            BarFill(fraction: fraction).fill(Y2K.peach)
        }
        .clipShape(Capsule())
    }
}

/// The left `fraction` of the rect, with round ends.
struct BarFill: Shape {
    let fraction: Double
    func path(in r: CGRect) -> Path {
        let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
        guard f > 0 else { return Path() }
        let w = max(r.height, r.width * f)
        return Path(roundedRect: CGRect(x: r.minX, y: r.minY, width: w, height: r.height), cornerRadius: r.height / 2)
    }
}

/// A small outlined LCD badge: "YTM", "AAC 131".
struct Badge: View {
    let text: String
    var body: some View {
        Text(text).font(Y2K.dot(7.5)).tracking(0.75).foregroundStyle(Y2K.lilac).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).frame(height: 11)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Y2K.lilac.opacity(140 / 255), lineWidth: 0.8))
    }
}

/// The candy play button (wb_play): the gradient, a white rim, a gloss on top; a dark play / pause.
struct Candy: View {
    let size: CGFloat
    let playing: Bool
    var body: some View {
        ZStack {
            Circle().fill(Ink.well)
            Circle().fill(LinearGradient(colors: Y2K.smartColors, startPoint: .bottomLeading, endPoint: .topTrailing)).padding(2)
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1).padding(2)
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.66, height: size * 0.46).offset(y: -size * 0.2)
            PlayPauseGlyph(playing: playing).fill(Ink.candyText)
                .frame(width: size * 0.44, height: size * 0.44)
        }
        .frame(width: size, height: size)
    }
}

/// Play (a triangle on Material's 24 grid) or pause (two bars).
struct PlayPauseGlyph: Shape {
    let playing: Bool
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        if playing {
            p.addRoundedRect(in: CGRect(x: w * 0.22, y: h * 0.18, width: w * 0.2, height: h * 0.64), cornerSize: CGSize(width: 1, height: 1))
            p.addRoundedRect(in: CGRect(x: w * 0.58, y: h * 0.18, width: w * 0.2, height: h * 0.64), cornerSize: CGSize(width: 1, height: 1))
        } else {
            p.move(to: CGPoint(x: w * 8 / 24, y: h * 5 / 24)); p.addLine(to: CGPoint(x: w * 8 / 24, y: h * 19 / 24))
            p.addLine(to: CGPoint(x: w * 19 / 24, y: h * 12 / 24)); p.closeSubpath()
        }
        return p
    }
}

/// The WreckBox record (the app's pixel record, as rings): grooves, peach and lilac label, the hole; on its beige
/// tile if `tile`.
struct Disc: View {
    let size: CGFloat
    var tile = false
    var body: some View {
        let inner = tile ? size * 0.78 : size
        ZStack {
            if tile {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xF1ECE4), Color(hex: 0xDCD5CA)], startPoint: .top, endPoint: .bottom))
            }
            Circle().fill(Color(hex: 0x34343E)).frame(width: inner, height: inner)
            Circle().fill(Color(hex: 0x15151A)).frame(width: inner * 14.6 / 15.6, height: inner * 14.6 / 15.6)
            Grooves(from: inner * 7.5 / 31.2, step: inner * 3.4 / 31.2).stroke(Color(hex: 0x2A2A33), lineWidth: max(0.5, inner / 32))
                .frame(width: inner, height: inner)
            Circle().fill(Y2K.peach).frame(width: inner * 5.6 / 15.6, height: inner * 5.6 / 15.6)
            Circle().fill(Y2K.lilac).frame(width: inner * 3.6 / 15.6, height: inner * 3.6 / 15.6)
            Circle().fill(Color(hex: 0x050506)).frame(width: inner * 1.6 / 15.6, height: inner * 1.6 / 15.6)
        }
        .frame(width: size, height: size)
    }

    /// Three groove rings round the centre (one shape).
    private struct Grooves: Shape {
        let from: CGFloat, step: CGFloat
        func path(in r: CGRect) -> Path {
            var p = Path()
            for i in 0..<3 {
                let rad = from + CGFloat(i) * step
                p.addEllipse(in: CGRect(x: r.midX - rad, y: r.midY - rad, width: 2 * rad, height: 2 * rad))
            }
            return p
        }
    }
}
