import SwiftUI
import UIKit

// The WreckBox look, as on the Android Player (Theme.kt) and the Mac Player (Design.swift): near-black frosted glass,
// Urbanist for text, Doto (dot-matrix) for labels and readouts, the light-blue → peach → lilac gradient for smart
// things, and a few Y2K touches used the same way everywhere — the LCD, the candy capsule, the record play button,
// the iridescent rim on covers, the dot spectrum, the progress pixels and the pixel-record logo.

enum W {
    static let bg = Color(hex: 0x08080A)
    static let bgRaised = Color(hex: 0x111115)
    static let text = Color.white.opacity(0.94)
    static let text2 = Color.white.opacity(0.66)
    static let text3 = Color.white.opacity(0.46)
    static let hairline = Color.white.opacity(0.08)
    static let glassFill = Color.white.opacity(0.045)
    static let pressed = Color.white.opacity(0.06)
    static let peach = Color(hex: 0xEFAF86)
    static let lilac = Color(hex: 0xBB96DA)
    static let blue = Color(hex: 0xA9C8F0)
    static let smartColors = [blue, peach, lilac]
    static let smart = LinearGradient(colors: smartColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let iridescent = AngularGradient(colors: [blue, peach, lilac, blue], center: .center)

    enum Radius { static let card: CGFloat = 22; static let tile: CGFloat = 18; static let row: CGFloat = 12; static let art: CGFloat = 8 }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Urbanist", size: size).weight(weight) }
    static func dot(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .custom("Doto", size: size).weight(weight) }

    /// Source tags: PHONE lilac · YOUTUBE peach · SPOTIFY light blue.
    static func color(_ s: Source) -> Color {
        switch s { case .local: return lilac; case .youtube: return peach; case .spotify: return blue }
    }

    /// The dot displays: lilac → light blue → peach by height.
    static func dotColor(_ h: Double) -> Color {
        func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
            var (ar, ag, ab, aa): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var (br, bg, bb, ba): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            UIColor(a).getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
            UIColor(b).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            let t = CGFloat(t)
            return Color(red: ar + (br - ar) * t, green: ag + (bg - ag) * t, blue: ab + (bb - ab) * t)
        }
        return h < 0.5 ? mix(lilac, blue, h * 2) : mix(blue, peach, (h - 0.5) * 2)
    }
}

// MARK: - Surfaces

extension View {
    /// Frosted glass: blurred material, a faint white fill, a top-lit hairline.
    func glass(_ radius: CGFloat = W.Radius.card, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(W.glassFill)
                if let tint { shape.fill(tint.opacity(0.10)) }
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
    }

    func smartGlass(_ radius: CGFloat = W.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(W.smart).opacity(0.16)).overlay(shape.strokeBorder(W.smart.opacity(0.55), lineWidth: 1))
    }

    /// The iridescent rim: a thin blue → peach → lilac ring, like the widget's shell.
    func iridescentRim(_ radius: CGFloat, width: CGFloat = 1.5) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(W.iridescent, lineWidth: width))
    }

    /// The widget's casing: deep violet graphite lit from above, a soft inner glow in the app's colours, granite
    /// flecks, a lit top edge and a shaded bottom edge, under a glare of curved glass.
    func casing(_ radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            ZStack {
                LinearGradient(stops: [.init(color: Color(hex: 0x433B55), location: 0), .init(color: Color(hex: 0x231F2E), location: 0.45),
                                       .init(color: Color(hex: 0x0B0A10), location: 1)], startPoint: .top, endPoint: .bottom)
                GeometryReader { g in
                    let w = g.size.width, h = g.size.height
                    ZStack {
                        RadialGradient(colors: [W.lilac.opacity(0.16), .clear], center: UnitPoint(x: 0.5, y: 1.3), startRadius: 0, endRadius: w * 0.45)
                        RadialGradient(colors: [W.peach.opacity(0.22), .clear], center: UnitPoint(x: 0.12, y: 1.15), startRadius: 0, endRadius: w * 0.32)
                        RadialGradient(colors: [W.blue.opacity(0.20), .clear], center: UnitPoint(x: 0.9, y: 1.15), startRadius: 0, endRadius: w * 0.32)
                        Canvas { ctx, sz in
                            var rng = SeededRandom(seed: 7)
                            for _ in 0..<min(1600, Int(sz.width * sz.height / 70)) {
                                let x = CGFloat(Double(rng.next() % 10_000) / 10_000) * sz.width
                                let y = CGFloat(Double(rng.next() % 10_000) / 10_000) * sz.height
                                let r = 0.3 + CGFloat(Double(rng.next() % 100) / 100) * 1.2
                                let light = rng.next() % 2 == 0
                                let c: Color = light ? .white.opacity(Double(14 + rng.next() % 26) / 255) : .black.opacity(Double(40 + rng.next() % 50) / 255)
                                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(c))
                            }
                        }
                        LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.18))
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: UnitPoint(x: 0.5, y: 0.72), endPoint: .bottom)
                        // The curved glass's glare.
                        Path { p in
                            p.move(to: CGPoint(x: w * 0.08, y: 0)); p.addLine(to: CGPoint(x: w * 0.92, y: 0))
                            p.addQuadCurve(to: CGPoint(x: w * 0.08, y: 0), control: CGPoint(x: w * 0.5, y: h * 0.55))
                        }
                        .fill(LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                    }
                }
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.6), radius: 14, y: 6)
        }
    }

    /// The candy capsule: the app's gradient with a white gloss on its top half and a thin light rim.
    func candy() -> some View {
        background {
            GeometryReader { g in
                let h = g.size.height
                ZStack {
                    Capsule().fill(W.smart)
                    RoundedRectangle(cornerRadius: h * 0.2).fill(LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom))
                        .frame(width: max(0, g.size.width - h * 0.44), height: h * 0.4).offset(x: h * 0.22, y: h * 0.06)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.8)
                }
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
    }

    /// A tap that dims while pressed (rows and tiles).
    func pressable(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { self.contentShape(Rectangle()) }.buttonStyle(PressStyle())
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1).scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The playing song's cover, huge and blurred, behind everything; soft gradients with nothing playing.
struct AmbientBackground: View {
    let art: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            W.bg
            if let image {
                Color.clear.overlay {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 70).opacity(0.45).saturation(1.3)
                }
                .clipped()
                .transition(.opacity)
            } else {
                RadialGradient(colors: [W.lilac.opacity(0.18), .clear], center: .topTrailing, startRadius: 20, endRadius: 500)
                RadialGradient(colors: [W.peach.opacity(0.09), .clear], center: .bottomLeading, startRadius: 20, endRadius: 420)
            }
            LinearGradient(colors: [W.bg.opacity(0.25), W.bg.opacity(0.88)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: image)
        .task(id: art) { image = await Images.shared.load(art, size: 160) }
    }
}

// MARK: - Type pieces

struct DotLabel: View {
    let text: String
    var color: Color = W.text2
    var size: CGFloat = 11
    init(_ text: String, color: Color = W.text2, size: CGFloat = 11) { self.text = text; self.color = color; self.size = size }
    var body: some View { Text(text.uppercased()).font(W.dot(size)).tracking(1.6).foregroundStyle(color).lineLimit(1) }
}

/// A section header: dot label, optional action on the right.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var action: String?
    var onAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                DotLabel(title, size: 12)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).font(W.ui(12)).foregroundStyle(W.text3).lineLimit(1) }
            }
            Spacer()
            if let action, let onAction {
                Button(action, action: onAction).buttonStyle(.plain).font(W.ui(13, .semibold)).foregroundStyle(W.text2)
            }
        }
        .padding(.top, 22).padding(.bottom, 10)
    }
}

/// The pixel-art record (the app icon); its two glints travel round while it plays.
struct PixelRecord: View {
    var size: CGFloat = 22
    var tile = true
    var spinning = false
    var buffering = false

    static func cell(_ x: Int, _ y: Int, glintAt: Double = 0, pulse: Double = 1) -> Color? {
        let dx = Double(x) - 15.5, dy = Double(y) - 15.5
        let r = (dx * dx + dy * dy).squareRoot()
        let angle = atan2(dy, dx) * 180 / .pi
        func inGlint(_ center: Double) -> Bool { let d = (angle - center + 540).truncatingRemainder(dividingBy: 360) - 180; return d > -16 && d < 16 }
        switch r {
        case ..<1.6: return Color(hex: 0x050506)
        case ..<3.6: return W.lilac.opacity(pulse)
        case ..<5.6: return W.peach.opacity(pulse)
        case ..<6.3: return Color(hex: 0x050506)
        case ..<14.6:
            let glint = inGlint(-134 + glintAt) || inGlint(46 + glintAt)
            let band = Int((r - 6.3) / 1.7) % 2 == 0
            if glint { return band ? Color(hex: 0x4A4A56) : Color(hex: 0x5C5C6A) }
            return band ? Color(hex: 0x15151A) : Color(hex: 0x202027)
        case ..<15.6: return Color(hex: 0x34343E)
        default: return nil
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !spinning && !buffering)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let glintAt = spinning ? (t / 2.4 * 360).truncatingRemainder(dividingBy: 360) : 0
            let pulse = buffering ? 0.55 + 0.45 * (sin(t * .pi * 2) + 1) / 2 : 1
            Canvas { ctx, sz in
                let s = sz.width
                var inner = s, o: CGFloat = 0
                if tile {
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerRadius: s * 0.225),
                             with: .linearGradient(Gradient(colors: [Color(hex: 0xF1ECE4), Color(hex: 0xDCD5CA)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: s)))
                    inner = s * 0.78; o = (s - inner) / 2
                }
                let px = inner / 32
                for y in 0..<32 { for x in 0..<32 {
                    guard let c = Self.cell(x, y, glintAt: glintAt, pulse: pulse) else { continue }
                    ctx.fill(Path(CGRect(x: o + CGFloat(x) * px, y: o + CGFloat(y) * px, width: px + 0.4, height: px + 0.4)), with: .color(c))
                } }
            }
        }
        .frame(width: size, height: size)
    }
}

/// The pixel record and WRECKBOX in Doto with the gradient.
struct Wordmark: View {
    var size: CGFloat = 26
    var body: some View {
        HStack(spacing: 10) {
            PixelRecord(size: size)
            Text("WRECKBOX").font(W.dot(size * 0.72, .black)).tracking(2).foregroundStyle(W.smart)
        }
    }
}

// MARK: - Controls

/// Capsule chip: white with a lilac dot when selected, glass otherwise.
struct Chip: View {
    let label: String
    var count: Int?
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected { Circle().fill(W.lilac).frame(width: 6, height: 6) }
                Text(label).font(W.ui(13, .semibold)).lineLimit(1)
                if let count { Text("\(count)").font(W.dot(11)).opacity(0.6) }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .fixedSize()
            .foregroundStyle(selected ? Color.black : W.text2)
            .background { if selected { Capsule().fill(.white) } else { Capsule().fill(W.glassFill).overlay(Capsule().strokeBorder(W.hairline)) } }
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

struct Pill: View {
    enum Style { case glass, primary, smart }
    let label: String
    var icon: String?
    var style: Style = .glass
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(label).font(W.ui(14, .semibold))
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .foregroundStyle(style == .primary ? Color.black : W.text)
            .background {
                switch style {
                case .primary: Capsule().fill(.white)
                case .smart: Capsule().fill(W.smart.opacity(0.28)).overlay(Capsule().strokeBorder(W.smart.opacity(0.7)))
                case .glass: Capsule().fill(W.glassFill).overlay(Capsule().strokeBorder(W.hairline))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct RoundButton: View {
    let icon: String
    var size: CGFloat = 38
    var tint: Color = W.text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(W.glassFill).overlay(Circle().strokeBorder(W.hairline)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
    }
}

/// The play button as the WreckBox logo: the pixel record in a dark well, under glass, with a white play / pause
/// symbol over it; its shine turns while music plays.
struct RecordButton: View {
    let size: CGFloat
    let playing: Bool
    var buffering = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(hex: 0x07060A))
                PixelRecord(size: size, tile: false, spinning: playing && !buffering, buffering: buffering)
                Circle().fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center))
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                if !buffering {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size * 0.36, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.6)).offset(x: 1, y: 1.5)
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size * 0.36, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

// MARK: - Y2K readouts

/// The LCD: deep violet glass with lilac ripple rings, ghost dots and scanlines, where the player's numbers live.
struct Lcd<Content: View>: View {
    var radius: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background { LcdFace() }
            .clipShape(shape)
            .overlay(shape.strokeBorder(W.lilac.opacity(0.25), lineWidth: 1))
    }
}

struct LcdFace: View {
    var body: some View {
        Canvas { ctx, sz in
            let center = CGPoint(x: sz.width * 0.88, y: sz.height * 1.1)
            ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .radialGradient(Gradient(colors: [Color(hex: 0x2A1F3D), Color(hex: 0x07060B)]),
                                                                              center: center, startRadius: 0, endRadius: sz.width))
            for i in 1...18 {
                let r = CGFloat(i) * 7
                ctx.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                           with: .color(W.lilac.opacity(Double(max(6, 46 - i * 2)) / 255)), lineWidth: 0.8)
            }
            var y: CGFloat = 0
            while y < sz.height { ctx.fill(Path(CGRect(x: 0, y: y, width: sz.width, height: 0.6)), with: .color(.black.opacity(0.10))); y += 2 }
        }
    }
}

/// A glowing LCD readout (peach digits over faint "88:88" segments).
struct LcdText: View {
    let text: String
    var ghost: String?
    var size: CGFloat = 22
    var color: Color = W.peach
    var body: some View {
        ZStack(alignment: .leading) {
            if let ghost { Text(ghost).font(W.dot(size, .black)).foregroundStyle(color.opacity(0.12)) }
            Text(text).font(W.dot(size, .black)).foregroundStyle(color).shadow(color: color.opacity(0.6), radius: 7)
        }
    }
}

/// LED lettering: peach Doto with a glow, scrolling when it doesn't fit.
struct LedText: View {
    let text: String
    var size: CGFloat = 11
    @State private var width: CGFloat = 0
    @State private var box: CGFloat = 0

    var body: some View {
        let label = Text(text).font(W.dot(size, .black)).tracking(0.8).foregroundStyle(W.peach).shadow(color: W.peach.opacity(0.6), radius: 4)
        GeometryReader { g in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: width <= g.size.width)) { tl in
                let gap: CGFloat = 40
                let travel = width + gap
                let t = tl.date.timeIntervalSinceReferenceDate
                let x = width > g.size.width ? -CGFloat((t * 28).truncatingRemainder(dividingBy: Double(travel))) : 0
                HStack(spacing: gap) {
                    label.fixedSize().background(GeometryReader { s in Color.clear.onAppear { width = s.size.width }.onChange(of: text) { width = s.size.width } })
                    if width > g.size.width { label.fixedSize() }
                }
                .offset(x: x)
            }
        }
        .frame(height: size * 1.3)
        .clipped()
    }
}

/// A small outlined LCD badge: "FLAC 24/96", "SHUF".
struct LcdBadge: View {
    let text: String
    var color: Color = W.lilac
    var body: some View {
        Text(text).font(W.dot(10)).tracking(1).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.55), lineWidth: 0.8))
    }
}

/// The progress pixels: a grid filling column by column, green at the start through yellow to red at the end; the
/// next one blinks while it plays; paused, the lit ones dim.
struct ProgressPixels: View {
    let progress: Double
    let playing: Bool
    var cols = 22
    var rows = 2

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { tl in
            let blink = Int(tl.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
            Canvas { ctx, sz in
                let cell = sz.width / CGFloat(cols)
                let rowH = sz.height / CGFloat(rows)
                let d = min(cell, rowH) * 0.72
                let lit = Int(progress * Double(cols * rows))
                for c in 0..<cols { for r in 0..<rows {
                    let i = c * rows + r
                    let hue = 120.0 / 360 * (1 - Double(c) / Double(cols - 1))
                    let h = Color(hue: hue, saturation: 0.75, brightness: 1)
                    let color: Color = i < lit ? h.opacity(playing ? 1 : 0.55) : (i == lit && playing && blink) ? h : .white.opacity(0.08)
                    ctx.fill(Path(CGRect(x: CGFloat(c) * cell + (cell - d) / 2, y: CGFloat(r) * rowH + (rowH - d) / 2, width: d, height: d)), with: .color(color))
                } }
            }
        }
    }
}

/// The dot spectrum: columns of dots lit by the music's REAL spectrum (Levels). Still when nothing can be measured
/// (paused) — nothing is faked. It only listens while on screen.
struct DotSpectrum: View {
    var live: Bool
    var cols = 4
    var rows = 4
    var dot: CGFloat = 3
    var gap: CGFloat = 1.5
    @ObservedObject private var levels = Levels.shared

    var body: some View {
        Canvas { ctx, sz in
            let b = live ? levels.bands : nil
            for i in 0..<cols {
                var level: Float = 0
                if let b {
                    let from = i * Levels.count / cols, to = max(from + 1, (i + 1) * Levels.count / cols)
                    level = b[from..<min(to, b.count)].max() ?? 0
                }
                let lit = b == nil ? 1 : max(0, min(rows, Int(level * Float(rows) + 0.35)))
                for r in 0..<rows {
                    let on = r < lit
                    let c: Color = !on ? .white.opacity(0.08) : b == nil ? W.text3 : W.dotColor(Double(r) / Double(max(1, rows - 1)))
                    let rect = CGRect(x: CGFloat(i) * (dot + gap), y: sz.height - CGFloat(r + 1) * dot - CGFloat(r) * gap, width: dot, height: dot)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: dot * 0.3), with: .color(c))
                }
            }
        }
        .frame(width: dot * CGFloat(cols) + gap * CGFloat(cols - 1), height: dot * CGFloat(rows) + gap * CGFloat(rows - 1))
        .onAppear { if live { Levels.shared.want() } }
        .onDisappear { if live { Levels.shared.unwant() } }
    }
}

/// The EQ as the apps draw it: ten dot columns from −12 to +12 dB, lit from the 0 line. Drag to shape it.
struct EqDots: View {
    let gains: [Float]
    let on: Bool
    var onBand: ((Int, Float) -> Void)?

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, sz in
                let dots = 13, half = dots / 2
                let colW = sz.width / 10, step = sz.height / CGFloat(dots - 1)
                for i in 0..<10 {
                    let x = colW * (CGFloat(i) + 0.5)
                    let level = Int((Double(gains[safe: i] ?? 0) / 12 * Double(half)).rounded())
                    for row in 0..<dots {
                        let k = half - row
                        let lit = (level > 0 && (1...level).contains(k)) || (level < 0 && k < 0 && k >= level)
                        let c: Color = k == 0 ? W.text3 : lit && on ? W.dotColor(Double(row) / Double(dots - 1)) : lit ? .white.opacity(0.35) : .white.opacity(0.07)
                        let w = colW * 0.5
                        ctx.fill(Path(roundedRect: CGRect(x: x - w / 2, y: CGFloat(row) * step - 1.5, width: w, height: 3), cornerRadius: 1), with: .color(c))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard let onBand else { return }
                let band = max(0, min(9, Int(v.location.x / g.size.width * 10)))
                let db = max(-12, min(12, (0.5 - v.location.y / g.size.height) * 24))
                onBand(band, Float((db * 2).rounded() / 2))
            })
        }
    }
}

/// "3:07" / "1:02:03".
func timeLabel(_ seconds: Double) -> String { clock(seconds) }
