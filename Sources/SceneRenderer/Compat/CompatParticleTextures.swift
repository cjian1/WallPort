import Foundation
import simd

/// 程序生成的粒子贴图：光斑、光束、星芒、水滴、法线图、动画精灵图（雾、烟、火、闪电、气泡、碎石、雪花、树叶、花瓣）。
/// 尺寸、格式、精灵图的帧数和帧尺寸和 WE 里同名的贴图一样（粒子按这些拉伸、选帧），画面是自己画的。
///
/// 折射用的法线图按壁坞粒子着色器的约定编码：偏移 = r ×（2a − 1, 2g − 1），r 是强度、a 是横向、g 是纵向（朝下为正）
enum CompatParticleTextures {
    typealias Format = CompatTexWriter.Format

    static let generators: [String: @Sendable () -> Data] = [
        // 光斑
        "materials/particle/halo.tex": { glow(64) { r in pow(max(0, 1 - r), 2.2) } },
        "materials/particle/halo_2.tex": { glow(64) { r in exp(-r * r * 5) * edge(r) } },
        "materials/particle/halo_3.tex": { glow(64) { r in max(exp(-r * r * 30), 0.6 * exp(-r * r * 4)) * edge(r) } },
        "materials/particle/halo_4.tex": {
            glow(128) { r in (0.8 * exp(-pow((r - 0.6) / 0.15, 2)) + 0.4 * exp(-r * r * 12)) * edge(r) }
        },
        "materials/particle/halo_5.tex": { glow(64) { r in pow(max(0, 1 - r), 4) } },
        "materials/particle/halo_6.tex": { glow(128) { r in exp(-r * r * 3.5) * edge(r) } },
        "materials/particle/sharp_halo.tex": { glow(64) { r in 1 - smooth(0.75, 0.95, r) } },
        "materials/particle/chromaticdot.tex": {
            single(64, 64, .rgba) { u, v in
                // 三个通道各一个圆，左右错开一点，边缘出现色散的彩边
                let channel = { (dx: Float) -> Float in 1 - smooth(0.55, 0.72, distance(u + dx, v)) }
                let rgb = SIMD3(channel(0.035), channel(0), channel(-0.035))
                return SIMD4(rgb, max(rgb.x, max(rgb.y, rgb.z)))
            }
        },
        // 折射法线图
        "materials/particle/sharp_halo_normal.tex": {
            single(64, 64, .rgba) { u, v in
                let d = SIMD2(u - 0.5, v - 0.5) * 2
                return normal(d * 0.9, strength: 1 - smooth(0.82, 0.95, simd_length(d)))
            }
        },
        "materials/particle/normal_ring_smooth.tex": {
            single(64, 64, .rgba) { u, v in
                let d = SIMD2(u - 0.5, v - 0.5) * 2
                let r = simd_length(d)
                let ring = exp(-pow((r - 0.65) / 0.2, 2))
                let direction = r > 1e-4 ? d / r : .zero
                return normal(direction * (r - 0.65) / 0.2 * 0.8, strength: ring)
            }
        },
        // 水滴：上细下圆，越往上越淡
        "materials/particle/drop.tex": {
            single(32, 128, .rgba) { u, v in
                let width = 0.12 + 0.3 * smooth(0.15, 0.85, v)
                let body = 1 - smooth(width * 0.55, width, abs(u - 0.5))
                let alpha = body * smooth(0, 0.65, v) * (1 - smooth(0.93, 1, v))
                return SIMD4(0.86, 0.93, 1, alpha)
            }
        },
        // 光束（灰度 + 透明度）
        "materials/particle/light/light_shafts_0.tex": { shafts(256, 512, seed: 1, count: 5, width: 0.05) },
        "materials/particle/light/light_shafts_1.tex": { shafts(256, 512, seed: 2, count: 3, width: 0.09) },
        "materials/particle/light/light_shafts_5.tex": { shafts(256, 256, seed: 5, count: 4, width: 0.12) },
        "materials/particle/light/light_shafts_6.tex": { shafts(128, 512, seed: 6, count: 2, width: 0.12) },
        "materials/particle/beam/beam_1.tex": {
            single(32, 128, .rg88) { u, v in
                SIMD4(1, 0, 0, exp(-pow((u - 0.5) / 0.16, 2)) * smooth(0, 0.15, v) * (1 - smooth(0.85, 1, v)))
            }
        },
        "materials/particle/beam/beam_2.tex": {
            single(32, 128, .rg88) { u, v in
                let core = exp(-pow((u - 0.5) / 0.05, 2)), glow = 0.5 * exp(-pow((u - 0.5) / 0.22, 2))
                return SIMD4(1, 0, 0, min(core + glow, 1) * smooth(0, 0.1, v) * (1 - smooth(0.9, 1, v)))
            }
        },
        // 星芒
        "materials/particle/light/flare_0.tex": { flare(rays: 4, ring: false, seed: 0) },
        "materials/particle/light/flare_1.tex": { flare(rays: 6, ring: false, seed: 1) },
        "materials/particle/light/flare_2.tex": { flare(rays: 8, ring: true, seed: 2) },
        "materials/particle/misc/star_0.tex": {
            single(128, 128, .rg88) { u, v in
                let x = abs(u - 0.5) * 2, y = abs(v - 0.5) * 2
                let arms = exp(-x * 9) * exp(-y * 1.6) + exp(-y * 9) * exp(-x * 1.6)
                return SIMD4(1, 0, 0, min(arms + exp(-(x * x + y * y) * 20), 1) * edge(simd_length(SIMD2(x, y))))
            }
        },
        // 雾和烟：每帧是一团慢慢翻滚的云
        "materials/particle/fog/fog1.tex": {
            sheet(1024, 1024, .r8, frames: 64, frame: SIMD2(128, 128)) { u, v, frame in
                SIMD4(1, 1, 1, cloud(u, v, frame: frame, frames: 64, seed: 11, density: 0.55))
            }
        },
        "materials/particle/fog/fog3.tex": {
            sheet(1024, 1024, .rg88, frames: 64, frame: SIMD2(128, 128)) { u, v, frame in
                let alpha = cloud(u, v, frame: frame, frames: 64, seed: 13, density: 0.6)
                return SIMD4(0.75 + 0.25 * cloud(u, v, frame: frame, frames: 64, seed: 31, density: 0.9), 0, 0, alpha)
            }
        },
        "materials/particle/smoke/smoke2.tex": {
            sheet(1024, 1024, .rg88, frames: 64, frame: SIMD2(128, 128)) { u, v, frame in
                // 一口烟：越往后越散开、越淡
                let t = Float(frame) / 63
                let alpha = cloud(u, v, frame: frame, frames: 64, seed: 17, density: 0.75, radius: 0.55 + 0.4 * t) * (1 - 0.6 * t)
                return SIMD4(0.85 - 0.25 * t, 0, 0, alpha)
            }
        },
        "materials/particle/fire/fire1.tex": {
            sheet(1024, 1024, .r8, frames: 64, frame: SIMD2(128, 128)) { u, v, frame in
                SIMD4(1, 1, 1, flame(u, v, frame: frame, frames: 64, seed: 19))
            }
        },
        "materials/particle/fire/fire2.tex": {
            sheet(1024, 512, .r8, frames: 32, frame: SIMD2(128, 128)) { u, v, frame in
                SIMD4(1, 1, 1, flame(u, v, frame: frame, frames: 32, seed: 23))
            }
        },
        // 闪电：每帧一道不同的电弧
        "materials/particle/lightning/lightning1.tex": { lightning(1024, 512, frames: 64, frame: SIMD2(128, 64), seed: 1) },
        "materials/particle/lightning/lightning2.tex": { lightning(1024, 512, frames: 32, frame: SIMD2(256, 64), seed: 2) },
        "materials/particle/lightning/lightning3.tex": { lightning(1024, 1024, frames: 50, frame: SIMD2(204.8, 102.4), seed: 3) },
        // 气泡：边缘亮、中间透明，带高光，逐帧轻轻抖动
        "materials/particle/bubbles/bubble2.tex": { bubbles(512, 512, frames: 30, frame: SIMD2(102.4, 512 / 6)) },
        "materials/particle/bubbles/bubble3.tex": { bubbles(1024, 1024, frames: 64, frame: SIMD2(128, 128)) },
        // 碎石：8 块形状不同的碎片
        "materials/particle/debris/debris1.tex": {
            sheet(1024, 128, .r8, frames: 8, frame: SIMD2(128, 128)) { u, v, frame in
                SIMD4(1, 1, 1, shard(u, v, seed: UInt64(frame) &+ 101))
            }
        },
        // 雪花：四种六角对称的花样
        "materials/particle/nature/snow.tex": {
            sheet(256, 256, .rg88, frames: 4, frame: SIMD2(128, 128)) { u, v, frame in
                SIMD4(1, 0, 0, snowflake(u, v, seed: UInt64(frame) &+ 7))
            }
        },
        // 花瓣：5 片（第 5 片在第一行最右边，和着色器"帧号 × 帧宽"的选帧方式一致）
        "materials/particle/nature/rosepetals.tex": {
            sheet(512, 128, .rgba, frames: 5, frame: SIMD2(102.5, 128)) { u, v, frame in
                petal(u, v, seed: UInt64(frame) &+ 41)
            }
        },
        // 树叶：每张 30 帧，一片叶子在空中翻转
        "materials/particle/nature/leaves1.tex": { leaves(512, 512, frame: SIMD2(512 / 6, 102.4), color: SIMD3(0.36, 0.62, 0.22)) },
        "materials/particle/nature/leaves2.tex": { leaves(512, 512, frame: SIMD2(512 / 6, 102.4), color: SIMD3(0.86, 0.46, 0.12)) },
        "materials/particle/nature/leaves3.tex": { leaves(512, 512, frame: SIMD2(512 / 6, 102.4), color: SIMD3(0.72, 0.16, 0.10)) },
        "materials/particle/nature/leaves5.tex": { leaves(512, 256, frame: SIMD2(512 / 6, 51.2), color: SIMD3(0.9, 0.72, 0.2)) },
        "materials/particle/nature/leaves7.tex": { leaves(512, 512, frame: SIMD2(512 / 6, 102.4), color: SIMD3(0.55, 0.36, 0.18)) },
        "materials/particle/nature/leaves8.tex": { leaves(512, 512, frame: SIMD2(512 / 6, 102.4), color: SIMD3(0.62, 0.7, 0.2)) },
        // 雨滴精灵图（灰度 + 透明度）和配套的法线图
        "materials/particle/water/rain_drops_sheet.tex": {
            sheet(256, 256, .rg88, frames: 16, frame: SIMD2(64, 64)) { u, v, frame in
                SIMD4(0.9, 0, 0, raindrop(u, v, seed: UInt64(frame) &+ 61).alpha)
            }
        },
        "materials/particle/water/rain_drops_sheet_normal.tex": {
            sheet(256, 256, .rgba, frames: 16, frame: SIMD2(64, 64)) { u, v, frame in
                let drop = raindrop(u, v, seed: UInt64(frame) &+ 61)
                return normal(drop.slope, strength: drop.alpha)
            }
        },
    ]

    // MARK: - 画法

    /// 中心在 (0.5, 0.5) 的距离，边缘是 1
    static func distance(_ u: Float, _ v: Float) -> Float { simd_length(SIMD2(u - 0.5, v - 0.5)) * 2 }

    static func smooth(_ low: Float, _ high: Float, _ x: Float) -> Float {
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 让圆形光斑在贴图边上收成 0
    static func edge(_ r: Float) -> Float { 1 - smooth(0.85, 1, r) }

    /// 法线图的一个像素：offset 是想要的偏移方向（贴图坐标，y 朝下），strength 是强度
    static func normal(_ offset: SIMD2<Float>, strength: Float) -> SIMD4<Float> {
        SIMD4(strength, 0.5 + 0.5 * min(max(offset.y, -1), 1), 1, 0.5 + 0.5 * min(max(offset.x, -1), 1))
    }

    /// 白色的圆形光斑，profile 按到中心的距离（0–1）给透明度
    static func glow(_ size: Int, _ profile: @escaping (Float) -> Float) -> Data {
        single(size, size, .rgba) { u, v in SIMD4(1, 1, 1, profile(distance(u, v))) }
    }

    static func single(
        _ width: Int, _ height: Int, _ format: Format, clamps: Bool = true, _ pixel: (Float, Float) -> SIMD4<Float>
    ) -> Data {
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = pixel((Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height))
            }
        }
        return CompatTexWriter(width: width, height: height, format: format, clamps: clamps).write(pixels)
    }

    /// 精灵图：第 k 帧放在（k × 帧宽 对贴图宽取模，⌊k × 帧宽 / 贴图宽⌋ × 帧高）——和粒子着色器选帧的换算一样。
    /// pixel 收到帧内的 0–1 坐标和帧号
    static func sheet(
        _ width: Int, _ height: Int, _ format: Format, frames: Int, frame size: SIMD2<Float>,
        _ pixel: (Float, Float, Int) -> SIMD4<Float>
    ) -> Data {
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * height)
        var layout: [CompatTexWriter.Frame] = []
        for index in 0..<frames {
            let along = Float(index) * size.x
            let origin = SIMD2(along.truncatingRemainder(dividingBy: Float(width)), (along / Float(width)).rounded(.down) * size.y)
            layout.append(.init(x: origin.x, y: origin.y, width: size.x, height: size.y))
            let x0 = Int(origin.x.rounded(.down)), y0 = Int(origin.y.rounded(.down))
            let x1 = min(width, Int((origin.x + size.x).rounded(.up))), y1 = min(height, Int((origin.y + size.y).rounded(.up)))
            guard y0 < height else { continue }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let u = (Float(x) + 0.5 - origin.x) / size.x, v = (Float(y) + 0.5 - origin.y) / size.y
                    guard u >= 0, u <= 1, v >= 0, v <= 1 else { continue }
                    pixels[y * width + x] = pixel(u, v, index)
                }
            }
        }
        var writer = CompatTexWriter(width: width, height: height, format: format, clamps: true)
        writer.frames = layout
        return writer.write(pixels)
    }

    static func shafts(_ width: Int, _ height: Int, seed: UInt64, count: Int, width spread: Float) -> Data {
        var random = CompatRandom(seed: seed)
        let bands = (0..<count).map { _ in (center: random.range(0.25, 0.75), width: spread * random.range(0.6, 1.4), strength: random.range(0.5, 1)) }
        return single(width, height, .rg88) { u, v in
            let across = bands.reduce(Float(0)) { $0 + $1.strength * exp(-pow((u - $1.center) / $1.width, 2)) }
            let fade = smooth(0, 0.35, v) * (1 - smooth(0.55, 1, v))
            return SIMD4(1, 0, 0, min(across, 1) * fade * (1 - smooth(0.4, 0.5, abs(u - 0.5))))
        }
    }

    static func flare(rays: Int, ring: Bool, seed: UInt64) -> Data {
        var random = CompatRandom(seed: seed &+ 900)
        let tilt = random.range(0, .pi / Float(rays))
        return single(256, 256, .rg88) { u, v in
            let d = SIMD2(u - 0.5, v - 0.5) * 2
            let r = simd_length(d)
            let angle = atan2(d.y, d.x) + tilt
            let spoke = pow(abs(cos(angle * Float(rays) / 2)), 40) * exp(-r * 3)
            var alpha = exp(-r * r * 40) + 0.35 * exp(-r * r * 6) + spoke
            if ring { alpha += 0.25 * exp(-pow((r - 0.55) / 0.04, 2)) }
            return SIMD4(1, 0, 0, min(alpha, 1) * edge(r))
        }
    }

    /// 一团云：柔和的圆团，用随帧缓慢流动的分形噪声调制浓淡和边缘
    static func cloud(
        _ u: Float, _ v: Float, frame: Int, frames: Int, seed: UInt64, density: Float, radius: Float = 0.8
    ) -> Float {
        let noise = CompatNoise(seed: seed)
        let t = Float(frame) / Float(frames) * 2 * .pi
        // 噪声坐标绕一个小圆走：最后一帧接得回第一帧
        let n = noise.fbm(x: u * 0.6 + 0.15 * cos(t), y: v * 0.6 + 0.15 * sin(t), period: 8, octaves: 5) * 0.5 + 0.5
        let r = distance(u, v) / radius
        let blob = exp(-r * r * 2.2) * (1 - smooth(0.85, 1, distance(u, v)))
        return min(max(blob * (density + (n - 0.5) * 1.6), 0), 1)
    }

    /// 火苗：底宽顶尖的水滴形，里面的噪声往上走
    static func flame(_ u: Float, _ v: Float, frame: Int, frames: Int, seed: UInt64) -> Float {
        let noise = CompatNoise(seed: seed)
        let t = Float(frame) / Float(frames)
        let height = 1 - v
        let halfWidth = 0.32 * pow(max(1 - height, 0), 0.6) * smooth(0, 0.12, 1 - height + 0.05)
        let shape = 1 - smooth(halfWidth * 0.5, halfWidth + 0.02, abs(u - 0.5))
        let n = noise.fbm(x: u * 0.5, y: v * 0.5 + t, period: 8, octaves: 4) * 0.5 + 0.5
        return min(max(shape * (0.4 + n * 1.2) - height * 0.35, 0), 1) * smooth(0.98, 0.85, v)
    }

    /// 一道电弧：从左到右，中点位移生成折线，核心亮、外面一圈辉光
    static func lightning(_ width: Int, _ height: Int, frames: Int, frame size: SIMD2<Float>, seed: UInt64) -> Data {
        let paths = (0..<frames).map { index -> [SIMD2<Float>] in
            var random = CompatRandom(seed: seed &* 1000 &+ UInt64(index))
            var points = [SIMD2<Float>(0.02, 0.5), SIMD2<Float>(0.98, random.range(0.35, 0.65))]
            var displacement: Float = 0.22
            for _ in 0..<6 {
                var next: [SIMD2<Float>] = []
                for (a, b) in zip(points, points.dropFirst()) {
                    next.append(a)
                    next.append(SIMD2((a.x + b.x) / 2, min(max((a.y + b.y) / 2 + random.range(-displacement, displacement), 0.1), 0.9)))
                }
                next.append(points.last!)
                points = next
                displacement *= 0.55
            }
            return points
        }
        let aspect = size.y / size.x
        return sheet(width, height, .r8, frames: frames, frame: size) { u, v, index in
            let path = paths[index]
            // 横向按段找最近的线段（点按 x 递增）
            let segment = min(max(Int(u * Float(path.count - 1)), 0), path.count - 2)
            var nearest: Float = 1
            for s in max(segment - 2, 0)...min(segment + 2, path.count - 2) {
                let a = path[s], b = path[s + 1]
                let ab = b - a, ap = SIMD2(u, v) - a
                let t = min(max(simd_dot(ap, ab) / max(simd_dot(ab, ab), 1e-6), 0), 1)
                let closest = a + ab * t - SIMD2(u, v)
                nearest = min(nearest, simd_length(SIMD2(closest.x, closest.y * aspect)))
            }
            let alpha = exp(-pow(nearest / 0.006, 2)) + 0.45 * exp(-nearest / 0.03)
            return SIMD4(1, 1, 1, min(alpha, 1) * smooth(0, 0.04, u) * smooth(1, 0.96, u))
        }
    }

    static func bubbles(_ width: Int, _ height: Int, frames: Int, frame size: SIMD2<Float>) -> Data {
        sheet(width, height, .rgba, frames: frames, frame: size) { u, v, index in
            let phase = Float(index) / Float(frames) * 2 * .pi
            let squash = SIMD2(1 + 0.05 * sin(phase), 1 - 0.05 * sin(phase))
            let d = SIMD2(u - 0.5, v - 0.5) * 2 / squash
            let r = simd_length(d)
            let rim = smooth(0.6, 0.93, r) * (1 - smooth(0.93, 1, r))
            let highlight = exp(-simd_length_squared(d - SIMD2(-0.35, -0.4)) * 30)
            let tint = CompatColor.hsv(0.55 + 0.3 * d.x + 0.1 * sin(phase), 0.25, 1)
            let alpha = min(rim * 0.85 + 0.08 * (1 - smooth(0.9, 1, r)) + highlight, 1)
            return SIMD4(simd_mix(tint, SIMD3(1, 1, 1), SIMD3(repeating: highlight)), alpha)
        }
    }

    /// 不规则多边形的碎片
    static func shard(_ u: Float, _ v: Float, seed: UInt64) -> Float {
        var random = CompatRandom(seed: seed)
        let corners = 6 + Int(random.unit() * 4)
        let radii = (0..<corners).map { _ in random.range(0.45, 0.85) }
        let d = SIMD2(u - 0.5, v - 0.5) * 2
        let angle = atan2(d.y, d.x)
        let position = (angle / (2 * .pi) + 0.5) * Float(corners)
        let index = Int(position.rounded(.down)) % corners
        let t = position - position.rounded(.down)
        let radius = simd_mix(radii[index], radii[(index + 1) % corners], t)
        return 1 - smooth(radius - 0.04, radius, simd_length(d))
    }

    /// 六角对称的雪花：把角度折到 30° 以内，主干加几根分叉
    static func snowflake(_ u: Float, _ v: Float, seed: UInt64) -> Float {
        var random = CompatRandom(seed: seed)
        let branches = (0..<3).map { _ in (at: random.range(0.25, 0.75), length: random.range(0.12, 0.3)) }
        var d = SIMD2(u - 0.5, v - 0.5) * 2
        let r = simd_length(d)
        var angle = atan2(d.y, d.x)
        let sector = Float.pi / 3
        angle = angle - (angle / sector).rounded(.down) * sector
        if angle > sector / 2 { angle = sector - angle }
        d = SIMD2(cos(angle), sin(angle)) * r
        var mask = (1 - smooth(0.02, 0.045, abs(d.y))) * (1 - smooth(0.85, 0.92, d.x))
        for branch in branches {
            // 分叉从主干上斜着伸出去（60°）
            let local = d - SIMD2(branch.at, 0)
            let along = local.x * 0.5 + local.y * 0.866, across = -local.x * 0.866 + local.y * 0.5
            if along > 0, along < branch.length { mask = max(mask, 1 - smooth(0.015, 0.035, abs(across))) }
        }
        return max(mask, 1 - smooth(0.08, 0.12, r))
    }

    static func petal(_ u: Float, _ v: Float, seed: UInt64) -> SIMD4<Float> {
        var random = CompatRandom(seed: seed)
        let rotation = random.range(-0.6, 0.6), stretch = random.range(0.75, 1)
        var d = SIMD2(u - 0.5, v - 0.5) * 2
        d = SIMD2(d.x * cos(rotation) - d.y * sin(rotation), d.x * sin(rotation) + d.y * cos(rotation))
        d.x /= stretch
        // 上宽下窄的花瓣，顶端中间有个浅凹口
        let y = d.y / 0.92
        let width = 0.6 * sqrt(max(0, 1 - y * y)) * (0.7 + 0.3 * (1 - y))
        let notch = y < -0.6 ? (1 - smooth(0, 0.12, abs(d.x))) * smooth(-0.6, -0.95, y) : 0
        let inside = (1 - smooth(width - 0.05, width, abs(d.x))) * (1 - notch)
        let shade = 1 - 0.35 * simd_length(d)
        let color = simd_mix(SIMD3<Float>(0.92, 0.38, 0.55), SIMD3<Float>(1, 0.78, 0.84), SIMD3(repeating: shade))
        return SIMD4(color, inside)
    }

    /// 30 帧：一片叶子绕自己的长轴翻转一圈、同时慢慢转
    static func leaves(_ width: Int, _ height: Int, frame size: SIMD2<Float>, color: SIMD3<Float>) -> Data {
        sheet(width, height, .rgba, frames: 30, frame: size) { u, v, index in
            let phase = Float(index) / 30 * 2 * .pi
            let flip = cos(phase), turn = phase * 0.25
            var d = SIMD2(u - 0.5, v - 0.5) * 2
            d = SIMD2(d.x * cos(turn) - d.y * sin(turn), d.x * sin(turn) + d.y * cos(turn))
            let squeeze = max(abs(flip), 0.12)
            d.x /= squeeze
            // 两头尖的叶片 + 中间的叶脉 + 一小段叶柄
            let halfWidth = 0.42 * max(0, 1 - pow(d.y / 0.82, 2))
            let blade = 1 - smooth(halfWidth - 0.05, halfWidth, abs(d.x))
            let stem = (1 - smooth(0.02, 0.04, abs(d.x))) * smooth(0.78, 0.8, d.y) * (1 - smooth(0.95, 0.98, d.y))
            let vein = 1 - smooth(0.01, 0.03, abs(d.x))
            let side = flip > 0 ? Float(1) : 0.72
            let tone = color * side * (1 - 0.25 * vein) * (0.85 + 0.15 * (1 - abs(d.y)))
            return SIMD4(tone, max(blade, stem))
        }
    }

    /// 雨滴：圆形或拉长的水珠，返回透明度和法线方向（往外鼓）
    static func raindrop(_ u: Float, _ v: Float, seed: UInt64) -> (alpha: Float, slope: SIMD2<Float>) {
        var random = CompatRandom(seed: seed)
        let stretch = random.range(1, 1.8), size = random.range(0.55, 0.9)
        let d = SIMD2(u - 0.5, (v - 0.5) / stretch) * 2 / size
        let r = simd_length(d)
        let alpha = 1 - smooth(0.85, 1, r)
        return (alpha, d * 0.8)
    }
}
