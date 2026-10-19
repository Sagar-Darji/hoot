import CoreGraphics
import Foundation
import simd

/// Renders Hoot's crane as real-looking glass, working out each pixel from how light would behave:
/// - every fold is a pane of glass with its own lean; creases are smoothed into gentle bends,
/// - the outer edges are rounded, so light bends strongly there,
/// - whatever is behind is refracted through the glass, with a touch of colour dispersion,
/// - tinted glass absorbs light, so colour deepens where the path through it is longer (the edges),
/// - Fresnel reflections of a studio (a big softbox up-left, a strip light on the right),
/// - sharp glints where an edge catches the light, and light glowing inside the far edges,
/// - on light backgrounds, a coloured shadow with focused light (caustics) on the surface below.
/// Everything is computed in linear light at `supersample`× resolution, then averaged down.
enum GlassRenderer {
    /// `clear` renders the glass alone on a transparent background, lit by neutral light from behind
    /// (for the record button and the notch, where it sits on Liquid Glass or black).
    enum Backdrop: Sendable { case prism, dusk, night, orb, clear }

    /// Where the crane's unit square sits inside the image's unit square.
    struct Placement: Sendable {
        var scale: Float
        var dx: Float = 0
        var dy: Float = 0
    }

    static func render(_ panes: [CranePane], backdrop: Backdrop, size: Int, placement: Placement,
                       supersample: Int = 2) -> CGImage? {
        let ss = max(1, supersample)
        let W = size * ss
        guard W > 8 else { return nil }
        let fw = Float(W)
        let unit = fw * placement.scale                        // pixels per crane unit

        func toPixels(_ p: CGPoint) -> SIMD2<Float> {
            SIMD2((Float(p.x) - 0.5) * placement.scale + 0.5 + placement.dx,
                  (Float(p.y) - 0.5) * placement.scale + 0.5 + placement.dy) * fw
        }
        let triangles = panes.map { $0.points.map(toPixels) }
        let glowCentre = SIMD2<Float>(0.5, (0.47 - 0.5) * placement.scale + 0.5 + placement.dy)

        // 1. What's behind the glass.
        var behind = Planes(W: W)
        for y in 0..<W {
            for x in 0..<W {
                behind.set(y * W + x, backdropColour(backdrop, u: (Float(x) + 0.5) / fw, v: (Float(y) + 0.5) / fw, glow: glowCentre))
            }
        }

        // 2. The glass, in layers: the far wing, then the main folded sheet in front of it.
        let layers = Array(Set(panes.map(\.layer))).sorted().map { key in
            Layer(panes: panes, triangles: triangles, members: panes.indices.filter { panes[$0].layer == key }, W: W, unit: unit)
        }

        // 3. Light passing through tinted glass colours the surface below it.
        if backdrop == .prism { castLight(through: layers, onto: &behind, W: W, unit: unit) }

        // 4. Each layer refracts, tints and reflects whatever is behind it. For a transparent result the
        //    glass is also composited over nothing (premultiplied), so only the crane has coverage.
        let ruled = panes.firstIndex(where: \.ruled).map(Int32.init)
        var alone: Planes? = backdrop == .clear ? Planes(W: W) : nil
        var aloneCover: [Float]? = backdrop == .clear ? [Float](repeating: 0, count: W * W) : nil
        for layer in layers {
            shade(layer, over: &behind, W: W, unit: unit, backdrop: backdrop, ruled: ruled, alone: &alone, aloneCover: &aloneCover)
        }

        // 5. Average the supersamples, tone map, encode as sRGB.
        if let alone, let aloneCover { return encode(alone, cover: aloneCover, W: W, ss: ss, size: size) }
        return encode(behind, W: W, ss: ss, size: size)
    }

    // MARK: - Scene

    /// How far the rounded edge reaches in from the outline, in crane units.
    private static let bevelWidth: Float = 0.028

    private static func linear(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        func f(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return SIMD3(f(r), f(g), f(b))
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func backdropColour(_ backdrop: Backdrop, u: Float, v: Float, glow: SIMD2<Float>) -> SIMD3<Float> {
        let g = simd_length(SIMD2(u, v) - glow) / 0.42
        let glowFalloff = exp(-g * g * 2.1)
        switch backdrop {
        case .prism:
            return simd_mix(linear(0.985, 0.985, 1.0), linear(0.84, 0.86, 0.93), SIMD3(repeating: smoothstep(0, 1, v)))
        case .dusk:
            let top = linear(0.04, 0.08, 0.36), middle = linear(0.20, 0.08, 0.52), bottom = linear(0.52, 0.10, 0.50)
            let sky = v < 0.55 ? simd_mix(top, middle, SIMD3(repeating: v / 0.55))
                               : simd_mix(middle, bottom, SIMD3(repeating: (v - 0.55) / 0.45))
            return sky + linear(1.0, 0.62, 0.75) * (0.9 * glowFalloff)        // warm light behind the crane
        case .night:
            let r = simd_length(SIMD2(u, v) - SIMD2(0.5, 0.35))
            let base = simd_mix(linear(0.20, 0.20, 0.26), linear(0.05, 0.05, 0.07), SIMD3(repeating: smoothstep(0, 0.75, r)))
            return base + linear(0.80, 0.80, 0.92) * (0.75 * glowFalloff)   // neutral light, so the glass shows its true colours
        case .clear:
            return linear(0.86, 0.86, 0.92)
        case .orb:
            let r = simd_length(SIMD2(u, v) - SIMD2(0.5, 0.5))
            let base = simd_mix(linear(0.14, 0.14, 0.19), linear(0.03, 0.03, 0.05), SIMD3(repeating: smoothstep(0, 0.6, r)))
            return base + linear(0.82, 0.82, 0.94) * (0.95 * glowFalloff)
        }
    }

    /// The studio the glass reflects: brighter overhead, a big softbox up-left, a strip light right.
    private static func environment(_ r: SIMD3<Float>) -> SIMD3<Float> {
        var c = simd_mix(SIMD3<Float>(0.30, 0.31, 0.36), SIMD3<Float>(0.95, 0.96, 1.0), SIMD3(repeating: smoothstep(-0.5, 0.7, -r.y)))
        let window = simd_normalize(SIMD3<Float>(-0.5, -0.72, 0.48))
        c += SIMD3(repeating: 4.5 * smoothstep(0.83, 0.95, simd_dot(r, window)))
        let strip = simd_normalize(SIMD3<Float>(0.82, -0.2, 0.54))
        c += SIMD3(repeating: 2.2 * smoothstep(0.95, 0.988, simd_dot(r, strip)))
        return c
    }

    // MARK: - Layers

    /// One sheet of glass: which pane covers each pixel, how far it is from the edge, and its
    /// lean and colour smoothed across the creases.
    private struct Layer {
        let ids: [Int32]          // pane index per pixel, -1 outside
        let alpha: [Float]        // antialiased coverage
        let edge: [Float]         // signed distance to the outline in pixels (positive inside)
        let tiltX: [Float], tiltY: [Float]
        let tint: Planes          // linear colour of the glass

        init(panes: [CranePane], triangles: [[SIMD2<Float>]], members: [Int], W: Int, unit: Float) {
            let N = W * W
            var ids = [Int32](repeating: -1, count: N)
            for i in members { rasterize(triangles[i], id: Int32(i), into: &ids, W: W) }
            let inside = ids.map { $0 >= 0 }
            let toOutside = distanceTransform(W: W) { !inside[$0] }
            let toInside = distanceTransform(W: W) { inside[$0] }
            var edge = [Float](repeating: 0, count: N)
            for i in 0..<N { edge[i] = inside[i] ? toOutside[i] - 0.5 : -(toInside[i] - 0.5) }
            boxBlur(&edge, W: W, radius: max(1, Int(unit * 0.002)), passes: 2)

            // Lean and colour, blurred across the creases (normalised so the outline doesn't fade them).
            var weight = [Float](repeating: 0, count: N)
            var tx = weight, ty = weight
            var tint = Planes(W: W)
            for i in 0..<N where ids[i] >= 0 {
                let pane = panes[Int(ids[i])]
                weight[i] = 1
                tx[i] = pane.tilt.x
                ty[i] = pane.tilt.y
                tint.set(i, GlassRenderer.linear(pane.rgb.x, pane.rgb.y, pane.rgb.z))
            }
            let foldRadius = max(1, Int(unit * 0.009)), colourRadius = max(1, Int(unit * 0.007))
            var colourWeight = weight
            boxBlur(&weight, W: W, radius: foldRadius, passes: 3)
            boxBlur(&tx, W: W, radius: foldRadius, passes: 3)
            boxBlur(&ty, W: W, radius: foldRadius, passes: 3)
            boxBlur(&colourWeight, W: W, radius: colourRadius, passes: 3)
            boxBlur(&tint.r, W: W, radius: colourRadius, passes: 3)
            boxBlur(&tint.g, W: W, radius: colourRadius, passes: 3)
            boxBlur(&tint.b, W: W, radius: colourRadius, passes: 3)
            for i in 0..<N {
                if weight[i] > 1e-4 { tx[i] /= weight[i]; ty[i] /= weight[i] }
                if colourWeight[i] > 1e-4 { tint.set(i, tint.get(i) / colourWeight[i]) }
            }

            self.ids = ids
            self.alpha = edge.map { min(max($0 + 0.5, 0), 1) }
            self.edge = edge
            self.tiltX = tx
            self.tiltY = ty
            self.tint = tint
        }
    }

    // MARK: - Light on the surface

    private static func castLight(through layers: [Layer], onto behind: inout Planes, W: Int, unit: Float) {
        let N = W * W
        let bevel = unit * bevelWidth
        var cover = [Float](repeating: 0, count: N)
        var tint = Planes(W: W)
        var rim = [Float](repeating: 0, count: N)
        var focus = [Float](repeating: 0, count: N)
        for layer in layers {
            for i in 0..<N where layer.alpha[i] > 0 {
                let a = layer.alpha[i]
                tint.set(i, tint.get(i) * (1 - a) + layer.tint.get(i) * a)
                cover[i] = max(cover[i], a)
                let d = max(layer.edge[i], 0)
                let s = max(0, 1 - d / bevel)
                rim[i] = max(rim[i], a * s * s)
                let k = (d - bevel * 1.3) / (bevel * 0.5)
                focus[i] = max(focus[i], a * exp(-k * k))
            }
        }
        // Light comes from the top left, so the shadow falls down and to the right; focused light lands a bit further.
        let sx = Int(unit * 0.03), sy = Int(unit * 0.06)
        func shifted(_ a: [Float], _ dx: Int, _ dy: Int) -> [Float] {
            var out = [Float](repeating: 0, count: N)
            for y in max(0, dy)..<min(W, W + dy) {
                for x in max(0, dx)..<min(W, W + dx) { out[y * W + x] = a[(y - dy) * W + (x - dx)] }
            }
            return out
        }
        var c = shifted(cover, sx, sy)
        var tr = shifted(zip(tint.r, cover).map(*), sx, sy)
        var tg = shifted(zip(tint.g, cover).map(*), sx, sy)
        var tb = shifted(zip(tint.b, cover).map(*), sx, sy)
        var rimShadow = shifted(rim, sx, sy)
        var caustic = shifted(focus, Int(Float(sx) * 1.15), Int(Float(sy) * 1.15))
        let soft = max(1, Int(unit * 0.012))
        boxBlur(&c, W: W, radius: soft, passes: 3)
        boxBlur(&tr, W: W, radius: soft, passes: 3)
        boxBlur(&tg, W: W, radius: soft, passes: 3)
        boxBlur(&tb, W: W, radius: soft, passes: 3)
        boxBlur(&rimShadow, W: W, radius: soft, passes: 3)
        boxBlur(&caustic, W: W, radius: max(1, Int(unit * 0.004)), passes: 3)
        for i in 0..<N where c[i] > 0.002 {
            let t = SIMD3(tr[i], tg[i], tb[i]) / c[i]
            let shadowColour = (t * 0.7 + 0.3) * 0.9
            var colour = behind.get(i)
            colour *= SIMD3(repeating: 1) + (shadowColour - 1) * (c[i] * 0.78)
            colour *= 1 - 0.2 * rimShadow[i]
            colour += (t * 0.6 + 0.4) * (caustic[i] * 0.5)
            behind.set(i, colour)
        }
    }

    // MARK: - Shading

    private static func shade(_ layer: Layer, over behind: inout Planes, W: Int, unit: Float, backdrop: Backdrop, ruled: Int32?,
                              alone: inout Planes?, aloneCover: inout [Float]?) {
        let source = behind                                  // refraction reads what was there before this layer
        let fw = Float(W)
        let bevel = unit * bevelWidth
        let depth = unit * 0.065
        let light = simd_normalize(SIMD3<Float>(-0.45, -0.6, 0.66))
        let across = simd_normalize(SIMD2<Float>(0.45, 0.6))   // the way light travels over the picture
        let reflectionGain: Float = backdrop == .prism ? 1 : 0.55
        let glowGain: Float = backdrop == .prism ? 0.6 : 1.1
        let lineAngle: Float = -12 * .pi / 180
        let linePerp = SIMD2<Float>(-sin(lineAngle), cos(lineAngle))
        let lineSpacing = unit * 0.055, lineWidth = max(1, unit * 0.0035)

        for y in 1..<(W - 1) {
            for x in 1..<(W - 1) {
                let i = y * W + x
                let a = layer.alpha[i]
                if a <= 0 { continue }
                let flat = simd_normalize(SIMD3(layer.tiltX[i], layer.tiltY[i], 1))
                let d = max(layer.edge[i], 0)
                var out = -SIMD2(layer.edge[i + 1] - layer.edge[i - 1], layer.edge[i + W] - layer.edge[i - W])
                let len = simd_length(out)
                out = len > 1e-5 ? out / len : .zero

                // Rounded edge: the surface turns outward as it approaches the outline.
                let s = max(0, 1 - d / bevel)
                let sinT = 0.9 * pow(s, 1.4)
                let n = simd_normalize(flat * sqrt(max(0, 1 - sinT * sinT)) + SIMD3(out.x, out.y, 0) * sinT)

                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let view = simd_normalize(SIMD3((0.5 - px / fw) * 0.9, (0.5 - py / fw) * 0.9, 1))
                let nv = max(simd_dot(n, view), 0.02)
                let fresnel = 0.06 + 0.94 * pow(1 - nv, 5)
                let reflection = environment(2 * nv * n - view) * reflectionGain

                // Refraction, a little different per colour (dispersion).
                let incoming = -view
                func bend(_ eta: Float) -> SIMD2<Float> {
                    let k = 1 - eta * eta * (1 - nv * nv)
                    guard k > 0 else { return .zero }
                    let t = eta * incoming + (eta * nv - sqrt(k)) * n
                    return (SIMD2(t.x, t.y) / max(-t.z, 0.05) - SIMD2(incoming.x, incoming.y) / max(-incoming.z, 0.05)) * depth
                }
                let oR = bend(1 / 1.47), oG = bend(1 / 1.50), oB = bend(1 / 1.54)
                var through = SIMD3(Planes.sample(source.r, px + oR.x, py + oR.y, W),
                                    Planes.sample(source.g, px + oG.x, py + oG.y, W),
                                    Planes.sample(source.b, px + oB.x, py + oB.y, W))

                // Tinted glass absorbs more where light travels further through it.
                let tint = simd_max(layer.tint.get(i), SIMD3(repeating: 0.004))
                let path = 0.9 + 1.2 * (1 - nv)
                through *= SIMD3(pow(tint.x, path), pow(tint.y, path), pow(tint.z, path))
                // Panes facing the light pass more of it; panes turned away look deeper.
                through *= 0.6 + 0.55 * max(simd_dot(flat, light), 0)

                // Light trapped in the glass glows along the edges facing away from the light.
                let glowAmount: Float = max(0, simd_dot(out, across)) * s * s * glowGain
                let glowColour = SIMD3(tint.x.squareRoot(), tint.y.squareRoot(), tint.z.squareRoot()) * 0.8 + SIMD3(repeating: 0.2)
                let glow = glowColour * glowAmount

                // Sharp glints and a soft sheen.
                let nh = max(simd_dot(n, simd_normalize(light + view)), 0)
                let specular = 3.2 * pow(nh, 650) + 0.1 * pow(nh, 28)

                let transmitted: SIMD3<Float> = through * (1 - fresnel)
                let mirrored: SIMD3<Float> = reflection * fresnel
                let bendX = layer.tiltX[i + 1] - layer.tiltX[i - 1], bendY = layer.tiltY[i + W] - layer.tiltY[i - W]
                let bendX2 = layer.tiltY[i + 1] - layer.tiltY[i - 1], bendY2 = layer.tiltX[i + W] - layer.tiltX[i - W]
                let crease = min(1, (abs(bendX) + abs(bendY) + abs(bendX2) + abs(bendY2)) * unit * 0.02) * (1 - s)
                let foldLight = SIMD3<Float>(repeating: crease * 0.13 * (0.5 + 0.5 * max(simd_dot(flat, light), 0)))
                var colour: SIMD3<Float> = transmitted + mirrored + SIMD3(repeating: specular) + glow + foldLight

                // Notepaper lines etched (frosted) into the lit wing.
                if let ruled, layer.ids[i] == ruled {
                    let q = simd_dot(SIMD2(px, py), linePerp) / lineSpacing
                    let f = q - floor(q)
                    let line = max(0, 1 - min(f, 1 - f) * lineSpacing / lineWidth)
                    let frosted: SIMD3<Float> = colour * 0.6 + SIMD3(repeating: 0.32)
                    colour += (frosted - colour) * (0.45 * line)
                }

                let old = behind.get(i)
                behind.set(i, old + (colour - old) * a)
                if alone != nil, aloneCover != nil {
                    alone!.set(i, alone!.get(i) * (1 - a) + colour * a)
                    aloneCover![i] = aloneCover![i] * (1 - a) + a
                }
            }
        }
    }

    // MARK: - Output

    /// Premultiplied colour + coverage → a transparent image.
    private static func encode(_ image: Planes, cover: [Float], W: Int, ss: Int, size: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let inv = 1 / Float(ss * ss)
        for y in 0..<size {
            for x in 0..<size {
                var c = SIMD3<Float>(repeating: 0)
                var a: Float = 0
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let i = (y * ss + sy) * W + x * ss + sx
                        c += image.get(i)
                        a += cover[i]
                    }
                }
                c *= inv
                a *= inv
                guard a > 0.001 else { continue }
                let o = (y * size + x) * 4
                let straight = c / a
                bytes[o] = UInt8(Float(toneByte(straight.x)) * a)
                bytes[o + 1] = UInt8(Float(toneByte(straight.y)) * a)
                bytes[o + 2] = UInt8(Float(toneByte(straight.z)) * a)
                bytes[o + 3] = UInt8(min(255, (a * 255).rounded()))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Linear light → tone-mapped sRGB byte (a soft shoulder so highlights roll off instead of clipping).
    private static func toneByte(_ v: Float) -> UInt8 {
        let k: Float = 0.82
        let t = v <= k ? max(v, 0) : k + (1 - k) * (1 - exp(-(v - k) / (1 - k)))
        let s = t <= 0.0031308 ? 12.92 * t : 1.055 * pow(t, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255).rounded())))
    }

    private static func encode(_ image: Planes, W: Int, ss: Int, size: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        let inv = 1 / Float(ss * ss)
        func byte(_ v: Float) -> UInt8 { toneByte(v) }
        for y in 0..<size {
            for x in 0..<size {
                var c = SIMD3<Float>(repeating: 0)
                for sy in 0..<ss { for sx in 0..<ss { c += image.get((y * ss + sy) * W + x * ss + sx) } }
                c *= inv
                let o = (y * size + x) * 4
                bytes[o] = byte(c.x); bytes[o + 1] = byte(c.y); bytes[o + 2] = byte(c.z)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Image helpers

/// Three float planes (linear RGB).
private struct Planes {
    var r: [Float], g: [Float], b: [Float]

    init(W: Int) {
        r = [Float](repeating: 0, count: W * W)
        g = r
        b = r
    }

    @inline(__always) func get(_ i: Int) -> SIMD3<Float> { SIMD3(r[i], g[i], b[i]) }
    @inline(__always) mutating func set(_ i: Int, _ c: SIMD3<Float>) { r[i] = c.x; g[i] = c.y; b[i] = c.z }

    /// Bilinear sample at pixel coordinates (pixel centres at +0.5), clamped to the edges.
    @inline(__always) static func sample(_ ch: [Float], _ x: Float, _ y: Float, _ W: Int) -> Float {
        let fx = min(max(x - 0.5, 0), Float(W) - 1.001), fy = min(max(y - 0.5, 0), Float(W) - 1.001)
        let x0 = Int(fx), y0 = Int(fy)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let i = y0 * W + x0
        let top = ch[i] + (ch[i + 1] - ch[i]) * tx
        let bottom = ch[i + W] + (ch[i + W + 1] - ch[i + W]) * tx
        return top + (bottom - top) * ty
    }
}

@inline(__always) private func cross2(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }

private func rasterize(_ tri: [SIMD2<Float>], id: Int32, into ids: inout [Int32], W: Int) {
    guard tri.count == 3 else { return }
    let a = tri[0], b = tri[1], c = tri[2]
    let area = cross2(b - a, c - a)
    guard abs(area) > 1e-6 else { return }
    let minX = max(0, Int(floor(min(a.x, b.x, c.x)))), maxX = min(W - 1, Int(ceil(max(a.x, b.x, c.x))))
    let minY = max(0, Int(floor(min(a.y, b.y, c.y)))), maxY = min(W - 1, Int(ceil(max(a.y, b.y, c.y))))
    guard minX <= maxX, minY <= maxY else { return }
    for y in minY...maxY {
        for x in minX...maxX {
            let p = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
            if cross2(b - a, p - a) / area >= 0, cross2(c - b, p - b) / area >= 0, cross2(a - c, p - c) / area >= 0 {
                ids[y * W + x] = id
            }
        }
    }
}

/// Exact Euclidean distance (in pixels) from every pixel to the nearest target pixel
/// (Felzenszwalb & Huttenlocher's linear-time algorithm).
private func distanceTransform(W: Int, isTarget: (Int) -> Bool) -> [Float] {
    let far: Float = 1e20
    var f = [Float](repeating: 0, count: W * W)
    for i in 0..<(W * W) { f[i] = isTarget(i) ? 0 : far }
    var line = [Float](repeating: 0, count: W), out = line
    var v = [Int](repeating: 0, count: W), z = [Float](repeating: 0, count: W + 1)

    func pass1D() {
        var k = 0
        v[0] = 0; z[0] = -far; z[1] = far
        if W > 1 {
            for q in 1..<W {
                var s: Float
                repeat {
                    let p = v[k]
                    s = ((line[q] + Float(q * q)) - (line[p] + Float(p * p))) / Float(2 * q - 2 * p)
                    if s <= z[k] { k -= 1 } else { break }
                } while k >= 0
                k += 1
                v[k] = q; z[k] = s; z[k + 1] = far
            }
        }
        k = 0
        for q in 0..<W {
            while z[k + 1] < Float(q) { k += 1 }
            let dq = Float(q - v[k])
            out[q] = dq * dq + line[v[k]]
        }
    }
    for x in 0..<W {
        for y in 0..<W { line[y] = f[y * W + x] }
        pass1D()
        for y in 0..<W { f[y * W + x] = out[y] }
    }
    for y in 0..<W {
        for x in 0..<W { line[x] = f[y * W + x] }
        pass1D()
        for x in 0..<W { f[y * W + x] = out[x].squareRoot() }
    }
    return f
}

/// Repeated box blur (three passes ≈ a Gaussian with sigma ≈ radius), clamped at the edges.
private func boxBlur(_ a: inout [Float], W: Int, radius r: Int, passes: Int) {
    guard r > 0 else { return }
    var tmp = [Float](repeating: 0, count: a.count)
    let norm = 1 / Float(2 * r + 1)
    a.withUnsafeMutableBufferPointer { src in
        tmp.withUnsafeMutableBufferPointer { dst in
            for _ in 0..<passes {
                for y in 0..<W {                                       // horizontal: src → dst
                    let row = y * W
                    var acc: Float = 0
                    for k in -r...r { acc += src[row + min(max(k, 0), W - 1)] }
                    for x in 0..<W {
                        dst[row + x] = acc * norm
                        acc += src[row + min(x + r + 1, W - 1)] - src[row + max(x - r, 0)]
                    }
                }
                for x in 0..<W {                                       // vertical: dst → src
                    var acc: Float = 0
                    for k in -r...r { acc += dst[min(max(k, 0), W - 1) * W + x] }
                    for y in 0..<W {
                        src[y * W + x] = acc * norm
                        acc += dst[min(y + r + 1, W - 1) * W + x] - dst[max(y - r, 0) * W + x]
                    }
                }
            }
        }
    }
}
