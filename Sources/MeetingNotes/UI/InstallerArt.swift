import SwiftUI

/// The background of the install window that opens with Hoot's disk image: Hoot on the left, the
/// Applications folder on the right, an arrow between them.
///
/// Finder draws the two icons and their names on top (at `appCenter` and `applicationsCenter`). On a
/// background picture it writes the names in black, so the glass tiles under them are light enough to
/// keep the names easy to read.
struct InstallerBackground: View {
    static let size = CGSize(width: 640, height: 400)
    static let appCenter = CGPoint(x: 170, y: 196)
    static let applicationsCenter = CGPoint(x: 470, y: 196)

    var body: some View {
        ZStack {
            Color(red: 0.42, green: 0.29, blue: 0.70)
            RadialGradient(colors: [Color(red: 0.20, green: 0.24, blue: 0.62), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color(red: 0.93, green: 0.42, blue: 0.62).opacity(0.9), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 400)
            RadialGradient(colors: [.white.opacity(0.16), .clear],
                           center: UnitPoint(x: 0.5, y: 0.0), startRadius: 0, endRadius: 300)

            VStack(spacing: 6) {
                Text("Install Hoot").font(.system(size: 22, weight: .semibold))
                Text("Drag Hoot onto the Applications folder").font(.system(size: 13.5))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(.white)
            .position(x: Self.size.width / 2, y: 54)

            tile(at: Self.appCenter)
            tile(at: Self.applicationsCenter)
            arrow.position(x: Self.size.width / 2, y: Self.appCenter.y)

            Text("Opening it the first time? If macOS won't open Hoot, go to\nSystem Settings › Privacy & Security and click Open Anyway.")
                .font(.system(size: 11.5))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(0.72))
                .position(x: Self.size.width / 2, y: 356)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }

    /// Frosted glass under an icon and its name.
    private func tile(at center: CGPoint) -> some View {
        RoundedRectangle(cornerRadius: 38, style: .continuous)
            .fill(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.4)], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.15)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
            .frame(width: 184, height: 196)
            .position(x: center.x, y: center.y + 14)
    }

    private var arrow: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 14))
            p.addLine(to: CGPoint(x: 64, y: 14))
            p.move(to: CGPoint(x: 52, y: 2))
            p.addLine(to: CGPoint(x: 66, y: 14))
            p.addLine(to: CGPoint(x: 52, y: 26))
        }
        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
        .frame(width: 68, height: 28)
        .shadow(color: .white.opacity(0.5), radius: 6)
    }
}
