import AppKit
import SwiftUI

extension Color {
    /// Blends toward another colour (0 = self, 1 = other).
    func mixed(with other: Color, by fraction: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.deviceRGB) ?? .gray
        let b = NSColor(other).usingColorSpace(.deviceRGB) ?? .gray
        return Color(nsColor: a.blended(withFraction: fraction, of: b) ?? a)
    }
}

/// A straight-edged facet from points in a unit square (y down).
struct Facet: Shape {
    let points: [CGPoint]
    func path(in r: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: CGPoint(x: r.minX + first.x * r.width, y: r.minY + first.y * r.height))
        for q in points.dropFirst() { p.addLine(to: CGPoint(x: r.minX + q.x * r.width, y: r.minY + q.y * r.height)) }
        p.closeSubpath()
        return p
    }
}

/// A flat drawing of the crane — shown only for the moment before the glass renders are ready.
struct HootMark: View {
    enum Form: String, CaseIterable {
        case prism, dusk, night
        var backdrop: GlassRenderer.Backdrop {
            switch self {
            case .prism: return .prism
            case .dusk: return .dusk
            case .night: return .night
            }
        }
    }

    var size: CGFloat
    var lift: CGFloat = 0
    var muted = false

    static let you = Color(red: 0.30, green: 0.52, blue: 1.00)
    static let middle = Color(red: 0.60, green: 0.40, blue: 1.00)
    static let others = Color(red: 1.00, green: 0.38, blue: 0.62)

    var body: some View {
        ZStack {
            ForEach(Array(Crane.panes(lift: lift).enumerated()), id: \.offset) { _, pane in
                let tint = Color(red: Double(pane.rgb.x), green: Double(pane.rgb.y), blue: Double(pane.rgb.z))
                Facet(points: pane.points)
                    .fill(LinearGradient(colors: [tint.mixed(with: .white, by: 0.25 * pane.light),
                                                  tint.mixed(with: .black, by: 0.3 * (1 - pane.light))],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .frame(width: size, height: size)
        .saturation(muted ? 0.05 : 1)
        .opacity(muted ? 0.6 : 1)
    }
}

/// The glass crane for the record button, pre-rendered at a few wing positions so it can move with
/// the voices. Rendering is fast at this size, so it happens once in the background at launch.
@MainActor
final class GlassFrames: ObservableObject {
    static let shared = GlassFrames()
    nonisolated static let steps = 7

    @Published private(set) var images: [NSImage] = []
    private var started = false

    func prepare() {
        guard !started else { return }
        started = true
        Task.detached(priority: .userInitiated) {
            let rendered = GlassFrames.render()
            await MainActor.run { GlassFrames.shared.images = rendered }
        }
    }

    /// For command-line renders, which can't wait for the background task.
    func prepareNow(pixels: Int = 120) {
        started = true
        images = Self.render(pixels: pixels)
    }

    /// The crane alone, as transparent glass (no backdrop), centred in its square.
    nonisolated static func render(pixels: Int = 120) -> [NSImage] {
        (0..<steps).compactMap { step in
            let level = CGFloat(step) / CGFloat(steps - 1)
            guard let cg = GlassRenderer.render(Crane.panes(lift: level * 0.10), backdrop: .clear, size: pixels,
                                                placement: .init(scale: 1.0, dy: 0.12), supersample: 3) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: pixels / 2, height: pixels / 2))
        }
    }

    /// The two frames either side of `level` (0…1), and how far between them it is.
    func frames(at level: CGFloat) -> (lower: NSImage, upper: NSImage, mix: Double)? {
        guard !images.isEmpty else { return nil }
        let position = min(max(level, 0), 1) * CGFloat(images.count - 1)
        let lower = Int(position.rounded(.down)), upper = min(lower + 1, images.count - 1)
        return (images[lower], images[upper], Double(position - CGFloat(lower)))
    }
}

/// Hoot's record button: the glass crane, whose wing lifts with the voices, with a soft light ring
/// rising around it while recording. It reads the levels straight from `LiveMeter`, so only this small
/// view redraws while recording — and it doesn't animate at all when nothing is happening.
struct HootOrb: View {
    enum Mood { case idle, sleeping, listening, busy, saved }

    var mood: Mood
    @ObservedObject var meter: LiveMeter
    var glow = false                // something new to look at (e.g. an AI answer): a still, soft ring
    var size: CGFloat = 32

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let siri = AngularGradient(colors: [
        HootMark.you, Color(red: 0.62, green: 0.45, blue: 1.0), HootMark.others,
        Color(red: 0.62, green: 0.45, blue: 1.0), HootMark.you,
    ], center: .center)

    var body: some View {
        let animating = !reduceMotion && (mood == .listening || mood == .busy)
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !animating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = CGFloat(meter.level)
            let lift: CGFloat = mood == .listening ? level : (mood == .busy && animating ? CGFloat(0.5 + 0.5 * sin(t * 7)) : 0)
            ZStack {
                ring(angle: animating ? (t * 90).truncatingRemainder(dividingBy: 360) : 0, level: level)
                GlassCrane(lift: lift, size: size)
                    .saturation(mood == .sleeping ? 0.05 : 1)
                    .opacity(mood == .sleeping ? 0.55 : 1)
                    .shadow(color: .black.opacity(0.22), radius: size * 0.04, y: size * 0.03)
                if mood == .saved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: size * 0.38))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(nsColor: .systemGreen))
                        .background(Circle().fill(.black.opacity(0.4)))
                        .offset(x: size * 0.36, y: size * 0.36)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
        }
    }

    /// A soft light ring in the two speakers' colours, swelling with the voices while listening.
    @ViewBuilder private func ring(angle: Double, level: CGFloat) -> some View {
        if mood == .listening || mood == .busy || glow {
            Circle()
                .strokeBorder(Self.siri, lineWidth: size * (0.10 + level * 0.08))
                .rotationEffect(.degrees(angle))
                .blur(radius: size * 0.12)
                .scaleEffect(1.12 + level * 0.12)
                .opacity(mood == .listening ? 0.3 + Double(level) * 0.5 : 0.5)
        }
    }
}

/// Siri's thinking glow: a rotating band of colour around a window's edge while Apple Intelligence works.
struct SiriEdgeGlow: View {
    var active: Bool
    var cornerRadius: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let angle = (context.date.timeIntervalSinceReferenceDate * 120).truncatingRemainder(dividingBy: 360)
                let gradient = AngularGradient(colors: [
                    HootMark.you, Color(red: 0.62, green: 0.45, blue: 1.0), HootMark.others,
                    Color(red: 0.62, green: 0.45, blue: 1.0), HootMark.you,
                ], center: .center, angle: .degrees(angle))
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(gradient, lineWidth: 10).blur(radius: 14).opacity(0.85)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(gradient, lineWidth: 2.5).blur(radius: 1)
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// The app icon artwork (rendered to AppIcon.icns by `MeetingNotes --render-icon`): the glass crane
/// rendered onto the tile, inside macOS's icon shape with a glass sheen and rim.
struct HootIconArt: View {
    let form: HootMark.Form
    private let glass: CGImage?

    init(form: HootMark.Form = .prism) {
        self.form = form
        // The tile is 824 px inside the 1024 canvas; the crane fills most of it, nudged down to centre it optically.
        glass = GlassRenderer.render(Crane.panes(lift: 0.02), backdrop: form.backdrop, size: 824,
                                     placement: .init(scale: 760.0 / 824.0, dy: 64.0 / 824.0))
    }

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 185, style: .continuous)
        let light = form == .prism
        ZStack {
            if let glass { Image(decorative: glass, scale: 1).resizable() }
            tile.fill(LinearGradient(colors: [.white.opacity(light ? 0.3 : 0.12), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
            tile.strokeBorder(LinearGradient(colors: [.white.opacity(light ? 0.95 : 0.4), .white.opacity(light ? 0.35 : 0.05)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 4)
        }
        .frame(width: 824, height: 824)
        .clipShape(tile)
        .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        .frame(width: 1024, height: 1024)
    }
}
