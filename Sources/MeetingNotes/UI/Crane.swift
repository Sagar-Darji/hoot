import CoreGraphics
import simd

/// One flat fold of Hoot's origami crane.
struct CranePane: Sendable {
    let points: [CGPoint]         // unit square, y down
    let light: Double             // 0 = turned away from the light … 1 = facing it (used by the flat drawing)
    let rgb: SIMD3<Float>         // the glass's colour, sRGB
    let tilt: SIMD2<Float>        // how the pane leans; negative x/y leans toward the light at the top left
    var ruled = false             // etched with notepaper lines
    var layer = 1                 // 0 = the far wing, behind; 1 = the main folded sheet
}

/// Hoot's mark: a sheet of coloured glass folded into a crane in flight — your notes taking flight.
enum Crane {
    static let blue = SIMD3<Float>(0.05, 0.50, 1.00)
    static let violet = SIMD3<Float>(0.50, 0.26, 1.00)
    static let purple = SIMD3<Float>(0.74, 0.28, 1.00)
    static let magenta = SIMD3<Float>(1.00, 0.16, 0.52)
    static let orange = SIMD3<Float>(1.00, 0.48, 0.16)

    /// The folds back to front. `lift` (0 … ~0.1) raises the wings.
    static func panes(lift: CGFloat = 0) -> [CranePane] {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        let beak = P(0.95, 0.31), neckTop = P(0.775, 0.385), throat = P(0.80, 0.445)
        let shoulder = P(0.60, 0.48), chest = P(0.645, 0.565), belly = P(0.50, 0.70), root = P(0.40, 0.545)
        let tail = P(0.06, 0.655), tailFold = P(0.25, 0.555), tailLow = P(0.31, 0.675)
        let wingTip = P(0.30, 0.06 + lift), wingFold = P(0.505, 0.30 + lift * 0.5)
        let farTip = P(0.15, 0.25 + lift * 0.6), farRoot = P(0.47, 0.475)
        return [
            CranePane(points: [root, farTip, farRoot], light: 0.18, rgb: violet, tilt: [0.32, 0.20], layer: 0),   // far wing
            CranePane(points: [tail, tailFold, root], light: 0.92, rgb: orange, tilt: [-0.28, -0.32]),            // tail, top fold
            CranePane(points: [tail, root, tailLow], light: 0.42, rgb: magenta, tilt: [0.12, 0.30]),              // tail, underside
            CranePane(points: [tailLow, root, belly], light: 0.30, rgb: magenta, tilt: [0.22, 0.32]),             // tail into belly
            CranePane(points: [root, chest, belly], light: 0.36, rgb: purple, tilt: [0.25, 0.22]),                // body
            CranePane(points: [root, shoulder, chest], light: 0.55, rgb: purple, tilt: [0.02, 0.12]),             // flank
            CranePane(points: [shoulder, neckTop, throat], light: 0.78, rgb: orange, tilt: [-0.22, -0.26]),       // neck, lit side
            CranePane(points: [shoulder, throat, chest], light: 0.40, rgb: magenta, tilt: [0.28, 0.18]),          // neck, shaded side
            CranePane(points: [neckTop, beak, throat], light: 0.95, rgb: orange, tilt: [-0.20, -0.38]),           // head
            CranePane(points: [root, wingTip, wingFold], light: 1.00, rgb: blue, tilt: [-0.38, -0.22], ruled: true), // near wing, lit
            CranePane(points: [wingFold, wingTip, shoulder], light: 0.52, rgb: violet, tilt: [0.34, -0.06]),      // near wing, turned away
            CranePane(points: [root, wingFold, shoulder], light: 0.70, rgb: purple, tilt: [-0.06, -0.16]),        // wing root
        ]
    }
}
