import Metal
import simd

/// 图层特效只在图层内容附近算。
///
/// WE 场景里常见的做法：人物的头发、手臂、衣摆各是一张**和整张画布一样大、大部分透明**的图，各挂一个抖动
/// （shake）之类的特效。特效链的缓冲按图层贴图的大小开（见 `SceneRenderer.bufferSize`），于是每个部件每帧都要
/// 把整屏大小的缓冲算一遍：本机 325 个动态场景里，GPU 占用高的那些主要就花在这上面。
///
/// 这里对"输入透明的地方输出也透明、内容最多被挪开一小段距离"的特效（下面的白名单，逐个看过 WE 自带的着色器），
/// 把整条链的每一遍都用裁剪矩形（scissor）限制在"贴图不透明像素的包围盒 + 各特效最多挪开的距离"里：
/// 矩形里的像素和原来逐个一样；矩形外原来算出来也是透明的，现在直接保持清空后的透明。
/// 最后把链的结果画到屏幕上时照样画整个四边形，只是用这一块在屏幕上的外接矩形裁剪（`screenScissor`）：
/// 切小四边形的话插值出来的纹理坐标会差最后几位，少数像素差 1/255。
///
/// 不用在：链里有白名单以外的特效（辉光、光线、模糊……会把内容扩散出去）；场景包自己带了同名的特效或着色器；
/// 读画面的链（复制背景）；精灵图、视频贴图；被别的特效引用结果的图层；混合方式是"不透明"或者
/// 不受透明度影响的 5、10 号混合模式（透明像素的颜色也会画上去，矩形外的结果就不一样了）。
enum EffectRegion {
    /// 一个特效最多把内容挪开多远（缓冲的 UV 比例，x、y 各一个）；不是逐个核对过的版本时为 nil。
    /// 参数是坏数（NaN、无穷大）或者挪得比整块缓冲还远时也是 nil：整块照算，限制范围也省不了什么
    static func reach(of effect: ChainEffect, bufferSize: SIMD2<Float>, files: SceneFiles) -> SIMD2<Float>? {
        guard let reach = estimatedReach(of: effect, bufferSize: bufferSize, files: files),
              reach.x.isFinite, reach.y.isFinite, reach.x >= 0, reach.y >= 0, max(reach.x, reach.y) < 1
        else { return nil }
        return reach
    }

    private static func estimatedReach(of effect: ChainEffect, bufferSize: SIMD2<Float>, files: SceneFiles) -> SIMD2<Float>? {
        guard effect.buffers.isEmpty, effect.steps.count == 1, let step = effect.steps.first,
              let program = step.program, step.target == nil, step.frameBufferSlots.isEmpty,
              !step.includesBackground, step.bindings == [0: .previous],
              let rule = verifiedRule(for: effect, files: files)
        else { return nil }
        func value(_ name: String) -> Float? {
            step.fragmentUniforms.values(name)?.first ?? step.vertexUniforms.values(name)?.first
        }
        func define(_ name: String) -> Int { program.defines[name] ?? 0 }
        // 拿不到参数时按取值范围的上限算
        switch rule {
        case .shake(let base):
            // 偏移 = offset × 强度² × 方向图（方向图 −0.996…1.004）。offset 新版在 −1…1、老版开噪声时 −1…3；
            // 开了音频律动时再加上最多"音频幅度"那么多（DIRECTION 各分支里最大的情况）
            let strength = value("g_Amp") ?? 0.5
            let audio = define("AUDIOPROCESSING") != 0 ? abs(value("g_AudioMultiply") ?? 2) : 0
            return SIMD2(repeating: (base + audio) * strength * strength * 1.01)
        case .waterwaves(let perspective):
            // 偏移 = 波形（−1…1）× 单位向量 × 强度 × 遮罩；老版的强度多一项 g_Perspective × |到中线的距离|（≤ 0.71）
            let strength = value("g_Strength") ?? 1
            let extra = perspective ? abs(value("g_Perspective") ?? 0.2) * 0.71 : 0
            return SIMD2(repeating: strength * strength + extra)
        case .waterripple:
            // 偏移 = 归一化法线的 xy × 强度² × 遮罩；高光乘了输入的 alpha
            let strength = value("g_Strength") ?? 1
            return SIMD2(repeating: strength * strength)
        case .foliagesway:
            // MODE 1 是整块四边形跟着摆（顶点动），范围说不准；MODE 0 按噪声在纹理坐标里挪：
            // 每个轴最多 4 × 强度² × 0.005 × |方向向量的分量|，方向向量是 (1/宽高比, 宽高比) 转过一个角度
            guard define("MODE") == 0 else { return nil }
            let strength = value("g_Strength") ?? 1
            let ratio = value("g_Ratio") ?? 10
            let aspect = max(bufferSize.x / max(bufferSize.y, 1) * ratio, 1e-3)
            let length = (aspect * aspect + 1 / (aspect * aspect)).squareRoot()
            return SIMD2(repeating: 4 * strength * strength * 0.005 * length)
        case .iris:
            // 输出 = 当前位置和"位置 + d × 遮罩"处的取样按遮罩混合；d 每个轴 ≤ (2 + |噪声幅度|) × |缩放| × 0.001
            //（两个 sin 相加在 −2…2，再加上噪声那一项）
            let noise = abs(value("g_NoiseAmount") ?? 2)
            let scale = step.vertexUniforms.values("g_Scale") ?? step.fragmentUniforms.values("g_Scale") ?? [10, 10]
            let axes = SIMD2(abs(scale.first ?? 10), abs(scale.count > 1 ? scale[1] : scale.first ?? 10))
            return (2 + noise) * axes * 0.001 * 1.01
        case .waterflow(let cycle):
            // 在"位置 + 流向图 × 强度 × 0.1 × 周期"处取样再混合；流向图每个分量 −0.996…1.004，
            // 周期现行版在 −0.5…0.5、旧版 0…1
            let strength = abs(value("g_FlowAmp") ?? 2)
            return SIMD2(repeating: 1.01 * strength * 0.1 * cycle)
        case .perPixel:
            // 同一位置取样，只改颜色 / 按系数缩小透明度
            return .zero
        }
    }

    enum Rule: Equatable {
        /// `base`：不开音频时 offset 的最大绝对值
        case shake(base: Float)
        /// `perspective`：老版，强度里多一项 g_Perspective
        case waterwaves(perspective: Bool)
        case waterripple
        case foliagesway
        case iris
        /// `cycle`：周期那一项的最大绝对值
        case waterflow(cycle: Float)
        case perPixel
    }

    /// 逐个核对过的版本：特效名 → "片元着色器指纹-顶点着色器指纹" → 偏移怎么算。
    /// 2026-09-30 用 `WallpaperTool effect-variants` 列出本机 353 个场景包里这几个特效的全部 38 个版本
    /// （WE 自带素材里的现行版，加上场景包里拷的各个旧版），逐个读过源码：输出只由"上一步在当前位置加上
    /// 一个有界偏移处"的取样得来（或者逐像素改颜色、按系数缩小透明度），顶点着色器都是原样的四边形。
    /// 不在表里的版本（作者改过的、以后的新版）一律不限制
    static let verified: [String: [String: Rule]] = [
        "shake": [
            "847605ac6ef471e8-5ebe40fb6a00c148": .shake(base: 1),  // WE 自带的现行版
            "975a4d6149b030c5-5ebe40fb6a00c148": .shake(base: 1),
            "2854233f248934f4-5ebe40fb6a00c148": .shake(base: 1),
            "975a4d6149b030c5-0dd72c05a6ee75e5": .shake(base: 1),
            "ea3711d3567d805e-aa4e71e686f69fb0": .shake(base: 1),
            "9efd63355ac5d42f-fe5b04e7d0080d93": .shake(base: 1),
            // 旧版：噪声分支 offset = dot(0.5, 四个 0…1) × 2 − 1，在 −1…3；没有音频律动
            "1a799f22bdb89519-fb06ce1c4988bff4": .shake(base: 3),
            "c20a3bd99b375feb-fb06ce1c4988bff4": .shake(base: 3),
            "b4bfcea605848599-fb06ce1c4988bff4": .shake(base: 3),
        ],
        "waterwaves": [
            "829746f678cdeb48-937d38a996309f0a": .waterwaves(perspective: false),  // WE 自带的现行版
            "97c88ed841966540-d363860d49f635a1": .waterwaves(perspective: true),
            "97c88ed841966540-4562b5ba01e3f8f8": .waterwaves(perspective: true),
            "2f844bb76c6a798c-4562b5ba01e3f8f8": .waterwaves(perspective: true),
            "78c8018380111854-72b7ed98cc3d00ac": .waterwaves(perspective: true),
            "b1151b0f00bf4998-ced3bec253d84646": .waterwaves(perspective: true),
        ],
        "waterripple": [
            "6f25d87c285ed4dd-296651404e4abc80": .waterripple,  // WE 自带的现行版
            "54764a515392c2c2-c5f924601876cf16": .waterripple,
            "22f7e9cf96f931f0-e9e7d049aff42a6c": .waterripple,
            "1b66987a7ed51eaf-17cb96e0112e3321": .waterripple,
            "1b66987a7ed51eaf-c5f924601876cf16": .waterripple,
        ],
        // cdf5ae5b472db6b2-9a87c3e9b76dccd4 只有"顶点跟着摆"的写法，不收
        "foliagesway": [
            "78a4c7a4a16d721b-23713a007841f44d": .foliagesway,  // WE 自带的现行版
            "8a4b5515b61071d7-b9bcda6a4ed4ee0f": .foliagesway,
        ],
        "iris": [
            "d5804f531aa80151-1368eaf29e98af64": .iris,  // WE 自带的现行版
            "e8ef4f2f10ba6a37-253bfd2d46065cd5": .iris,
        ],
        "waterflow": [
            "875d57e659717b64-1e7fbc59f722197c": .waterflow(cycle: 0.5),  // WE 自带的现行版
            "bbf45ec4dce984a3-fb06ce1c4988bff4": .waterflow(cycle: 0.5),
            "2be51b668b7d17eb-fb06ce1c4988bff4": .waterflow(cycle: 1),
        ],
        "pulse": [
            "392d2da3449026d8-bbc5e56992abd995": .perPixel,  // WE 自带的现行版
            "c364ab68d6341550-e0915caae89252c7": .perPixel,
            "0fe077ef39c04bea-f07c9427f3b7c477": .perPixel,
            "25297bedce64aad9-9313e4c4720cf27f": .perPixel,
            "40f2bbe09df48805-e0915caae89252c7": .perPixel,
            "c53a9e4372a31439-413477a32a2554d0": .perPixel,
            "01d61cd095fbaa61-bbc5e56992abd995": .perPixel,
            "3f4b79e5ed5b9b22-b3d071efb45a7872": .perPixel,
        ],
        "opacity": [
            "f9201271a03c7651-fb06ce1c4988bff4": .perPixel,  // WE 自带的现行版
            "301436fc9366de79-fb06ce1c4988bff4": .perPixel,
        ],
    ]

    /// 测试里补登记的版本（测试用自己写的特效，指纹不在上面的表里）。
    /// 测试是并行跑的，别的测试建场景时会同时读它，所以读写都加锁
    static var additionalVerified: [String: [String: Rule]] {
        get { additionalLock.withLock { additionalStorage } }
        set { additionalLock.withLock { additionalStorage = newValue } }
    }
    private static let additionalLock = NSLock()
    nonisolated(unsafe) private static var additionalStorage: [String: [String: Rule]] = [:]

    /// 这个特效实际用的着色器是不是核对过的版本（场景包里拷的优先，和编译时找文件的顺序一样）；
    /// 特效定义和材质也得是"一个通道、用同名着色器"
    static func verifiedRule(for effect: ChainEffect, files: SceneFiles) -> Rule? {
        verifiedVariant(for: effect, files: files)?.rule
    }

    /// 同上，另外给出版本的指纹（遮罩表按它查）
    static func verifiedVariant(for effect: ChainEffect, files: SceneFiles) -> (rule: Rule, key: String)? {
        guard effect.name.hasPrefix("effects/") else { return nil }
        let name = String(effect.name.dropFirst("effects/".count))
        let rules = (verified[name] ?? [:]).merging(additionalVerified[name] ?? [:]) { known, _ in known }
        guard !rules.isEmpty,
              let definition = files.json("effects/\(name)/effect.json"),
              let passes = definition["passes"] as? [[String: Any]], passes.count == 1,
              let materialPath = passes[0]["material"] as? String,
              let material = files.json(materialPath),
              (material["passes"] as? [[String: Any]])?.first?["shader"] as? String == "effects/\(name)",
              let fragment = files.text("shaders/effects/\(name).frag"),
              let vertex = files.text("shaders/effects/\(name).vert")
        else { return nil }
        let key = String(format: "%016llx-%016llx", codeHash(fragment), codeHash(vertex))
        return rules[key].map { ($0, key) }
    }


    // MARK: - 按遮罩限制

    /// 特效的遮罩：它为 0 的地方特效的输出和输入逐像素一样，所以只需要在遮罩不为 0 的范围里算，外面照抄输入
    struct MaskSpec: Equatable {
        /// 透明度遮罩的贴图槽；`define` 不为 nil 时这个开关不为 0 才采样（开关关着就没有遮罩）
        var slot: Int?
        var define: String?
        /// 遮罩在"位置 + 偏移"处采样（shake）：会变的范围要再扩出偏移上限
        var displaced = false
        /// 方向图（shake 的 g_Texture1）：r、g 都是 127 的地方偏移只剩 (127/255 − 0.498) × 2 ≈ 7.84e-5 倍
        var flowSlot: Int?
        /// 这些开关不为 0 时遮罩以外也会变（waterripple 的高光、iris 的背景色）
        var forbidden: [String] = []
    }

    /// 各版本的遮罩（逐个读过源码：遮罩为 0 时 `mix(输入, x, 0)`、偏移 × 0、振幅 × 0，输出就是输入在当前位置的取样）
    static func maskSpec(effect name: String, variant key: String) -> MaskSpec? {
        switch name {
        case "shake":
            // 9 个版本都用 g_Texture1 当方向图；新版另有 g_Texture3 当透明度遮罩（在偏移后的位置采样）。
            // 9efd… 那一版遮罩的写法不对（按偏移后的纹理坐标直接取，没乘比例），不用它的遮罩
            let opacity: Set<String> = [
                "847605ac6ef471e8-5ebe40fb6a00c148", "975a4d6149b030c5-5ebe40fb6a00c148",
                "2854233f248934f4-5ebe40fb6a00c148", "975a4d6149b030c5-0dd72c05a6ee75e5",
            ]
            return opacity.contains(key)
                ? MaskSpec(slot: 3, define: "MASK", displaced: true, flowSlot: 1) : MaskSpec(flowSlot: 1)
        case "waterwaves":
            // 97c88ed8… 两版不看开关，总是采样遮罩
            return MaskSpec(slot: 1, define: key.hasPrefix("97c88ed841966540") ? nil : "MASK")
        case "waterripple":
            // 22f7… 那一版遮罩在 g_Texture2（法线图在 g_Texture1）；1b66… 和 22f7… 不看开关
            switch key {
            case "22f7e9cf96f931f0-e9e7d049aff42a6c": return MaskSpec(slot: 2, forbidden: ["SPECULAR"])
            case "1b66987a7ed51eaf-17cb96e0112e3321", "1b66987a7ed51eaf-c5f924601876cf16":
                return MaskSpec(slot: 1, forbidden: ["SPECULAR"])
            default: return MaskSpec(slot: 1, define: "MASK", forbidden: ["SPECULAR"])
            }
        case "foliagesway":
            // Vertex 模式整块四边形跟着摆，遮罩外也在动
            return MaskSpec(slot: 1, define: "MASK", forbidden: ["MODE"])
        case "pulse":
            return MaskSpec(slot: 2, define: "MASK")
        case "iris":
            // 现行版开了背景色时遮罩外也会填眼睛的颜色；旧版是 mix(原色, 虹膜, 遮罩)，没这个问题
            return MaskSpec(
                slot: 1, define: "MASK", forbidden: key == "d5804f531aa80151-1368eaf29e98af64" ? ["BACKGROUND"] : [])
        default:
            return nil
        }
    }

    /// 贴图里要找的像素
    enum PixelTest: Hashable {
        /// alpha 不为 0（图层内容）
        case alpha
        /// 红色通道不为 0（透明度遮罩）
        case red
        /// 红、绿不都是 127（方向图的"不动"）
        case flowing
    }

    /// 这个特效会改动的范围（缓冲像素，左上原点）：外面的输出和输入逐像素一样。没有遮罩、遮罩几乎铺满、
    /// 不在核对表里时为 nil（整块都算）
    static func changedRegion(
        of effect: ChainEffect, bufferSize size: SIMD2<Int>, files: SceneFiles,
        bounds: (LoadedTexture, PixelTest) -> SIMD4<Float>?
    ) -> MTLScissorRect? {
        let buffer = SIMD2(Float(size.x), Float(size.y))
        guard let step = effect.steps.first, effect.steps.count == 1, let program = step.program,
              let (rule, key) = verifiedVariant(for: effect, files: files),
              let reach = reach(of: effect, bufferSize: buffer, files: files),
              let spec = maskSpec(effect: String(effect.name.dropFirst("effects/".count)), variant: key),
              !spec.forbidden.contains(where: { (program.defines[$0] ?? 0) != 0 })
        else { return nil }
        func value(_ name: String) -> Float? {
            step.fragmentUniforms.values(name)?.first ?? step.vertexUniforms.values(name)?.first
        }
        /// 遮罩在缓冲里的范围，再放宽采样时会"洇"出去的那一点（见 `samplingMargin`）
        func region(slot: Int, test: PixelTest) -> SIMD4<Float>? {
            guard let texture = step.textures[slot], let box = bounds(texture, test) else { return nil }
            let margin = samplingMargin(of: texture, bufferSize: buffer)
            return SIMD4(box.x - margin.x, box.y - margin.y, box.z + margin.x, box.w + margin.y)
        }
        var box: SIMD4<Float>?
        if let slot = spec.slot, spec.define.map({ (program.defines[$0] ?? 0) != 0 }) ?? true,
           var opacity = region(slot: slot, test: .red) {
            if spec.displaced { opacity += SIMD4(-reach.x, -reach.y, reach.x, reach.y) }
            box = opacity
        }
        if let slot = spec.flowSlot, case .shake(let base) = rule {
            // 方向图是 127 的地方还剩一点点偏移：GPU 的插值权重按 8 位小数量化，偏移不到 1/512 个像素时和不偏移一样。
            // 但插值出来的纹理坐标本身就差最后几位（约万分之几个像素），叠上去会跨过取整边界：
            // 强度 0.09、3024 宽时剩 0.00192 个像素，实测有少数像素差 1/255。所以只认不到 1/1024 个像素的
            let strength = value("g_Amp") ?? 0.5
            let audio = (program.defines["AUDIOPROCESSING"] ?? 0) != 0 ? abs(value("g_AudioMultiply") ?? 2) : 0
            let residual = (base + audio) * strength * strength * 7.85e-5 * max(buffer.x, buffer.y)
            if residual < 1.0 / 1024, let flowing = region(slot: slot, test: .flowing) {
                box = box.map { SIMD4(max($0.x, flowing.x), max($0.y, flowing.y), min($0.z, flowing.z), min($0.w, flowing.w)) }
                    ?? flowing
            }
        }
        guard let box else { return nil }
        if box.z <= box.x || box.w <= box.y { return MTLScissorRect(x: 0, y: 0, width: 1, height: 1) }
        let rect = scissor(content: box, reach: .zero, bufferSize: size)
        return Double(rect.width * rect.height) < 0.9 * Double(size.x * size.y) ? rect : nil
    }

    /// 贴图第 0 层里满足条件的像素的包围盒（0–1：左、上、右、下；一个都没有时是空的盒子）。
    /// alpha 支持 RGBA 和 BC1/2/3；遮罩和方向图只认 RGBA / RG / R 这几种不压缩的格式，其余返回 nil
    static func bounds(of texture: any MTLTexture, test: PixelTest) -> SIMD4<Float>? {
        if test == .alpha { return alphaBounds(of: texture) }
        guard texture.storageMode != .private, texture.textureType == .type2D else { return nil }
        let width = texture.width, height = texture.height
        let channels: Int, red: Int, green: Int?
        switch texture.pixelFormat {
        case .rgba8Unorm, .rgba8Unorm_srgb: (channels, red, green) = (4, 0, 1)
        case .bgra8Unorm, .bgra8Unorm_srgb: (channels, red, green) = (4, 2, 1)
        case .rg8Unorm: (channels, red, green) = (2, 0, 1)
        case .r8Unorm: (channels, red, green) = (1, 0, nil)
        default: return nil
        }
        var bytes = [UInt8](repeating: 0, count: width * height * channels)
        bytes.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!, bytesPerRow: width * channels, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let box = bytes.withUnsafeBufferPointer { pixels in
            scan(width: width, height: height) { x, y in
                let offset = (y * width + x) * channels
                switch test {
                case .red, .alpha: return pixels[offset + red] != 0
                case .flowing: return pixels[offset + red] != 127 || (green.map { pixels[offset + $0] } ?? 0) != 127
                }
            }
        }
        return normalized(box, width: width, height: height, scale: 1)
    }

    /// 着色器代码的指纹：去掉注释和所有空白后的 FNV-1a 64 位哈希。只认代码，不认注释、排版和换行符——
    /// 场景包里拷的常是旧版 WE 的特效，注释和写法不同，代码可能一样
    static func codeHash(_ source: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let bytes = Array(source.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") {
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
                continue
            }
            if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) {
                    index += 1
                }
                index += 2
                continue
            }
            index += 1
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0B || byte == 0x0C { continue }
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// 贴图里 alpha 不为 0 的像素的包围盒（贴图第 0 层的 0–1 坐标：左、上、右、下）。
    /// 全透明时返回空的盒子（左 = 右）；读不了的格式（只有 GPU 能读的、没有 alpha 的）返回 nil
    static func alphaBounds(of texture: any MTLTexture) -> SIMD4<Float>? {
        guard texture.storageMode != .private, texture.textureType == .type2D else { return nil }
        let width = texture.width, height = texture.height
        let region = MTLRegionMake2D(0, 0, width, height)
        switch texture.pixelFormat {
        case .rgba8Unorm, .bgra8Unorm, .rgba8Unorm_srgb, .bgra8Unorm_srgb:
            var pixels = [UInt32](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: region, mipmapLevel: 0)
            }
            // 小端序：alpha 是最高的那个字节
            let box = pixels.withUnsafeBufferPointer { buffer in
                scan(width: width, height: height) { x, y in buffer[y * width + x] > 0x00FF_FFFF }
            }
            return normalized(box, width: width, height: height, scale: 1)
        case .bc1_rgba, .bc2_rgba, .bc3_rgba:
            let blockBytes = texture.pixelFormat == .bc1_rgba ? 8 : 16
            let columns = (width + 3) / 4, rows = (height + 3) / 4
            var blocks = [UInt8](repeating: 0, count: columns * rows * blockBytes)
            blocks.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: columns * blockBytes, from: region, mipmapLevel: 0)
            }
            let format = texture.pixelFormat
            let box = blocks.withUnsafeBufferPointer { buffer in
                scan(width: columns, height: rows) { x, y in
                    blockHasAlpha(buffer, offset: (y * columns + x) * blockBytes, format: format)
                }
            }
            return normalized(box, width: width, height: height, scale: 4)
        default:
            return nil
        }
    }

    /// 一个压缩块（4×4）里有没有 alpha 不为 0 的像素
    private static func blockHasAlpha(_ block: UnsafeBufferPointer<UInt8>, offset: Int, format: MTLPixelFormat) -> Bool {
        switch format {
        case .bc1_rgba:
            // color0 ≤ color1 时索引 3 是透明黑，其余不透明；color0 > color1 时整块不透明
            let color0 = UInt16(block[offset]) | UInt16(block[offset + 1]) << 8
            let color1 = UInt16(block[offset + 2]) | UInt16(block[offset + 3]) << 8
            guard color0 <= color1 else { return true }
            let indices = UInt32(block[offset + 4]) | UInt32(block[offset + 5]) << 8
                | UInt32(block[offset + 6]) << 16 | UInt32(block[offset + 7]) << 24
            return indices != 0xFFFF_FFFF
        case .bc2_rgba:
            // 前 8 字节是 16 个 4 位的 alpha
            return (0..<8).contains { block[offset + $0] != 0 }
        default:
            // BC3：两个端点 + 16 个 3 位索引，按调色板查出每个像素的 alpha
            let alpha0 = Int(block[offset]), alpha1 = Int(block[offset + 1])
            var palette = [alpha0, alpha1]
            if alpha0 > alpha1 {
                palette += (1...6).map { ((7 - $0) * alpha0 + $0 * alpha1) / 7 }
            } else {
                palette += (1...4).map { ((5 - $0) * alpha0 + $0 * alpha1) / 5 } + [0, 255]
            }
            var bits: UInt64 = 0
            for byte in 0..<6 { bits |= UInt64(block[offset + 2 + byte]) << (8 * UInt64(byte)) }
            return (0..<16).contains { palette[Int((bits >> (3 * UInt64($0))) & 7)] > 0 }
        }
    }

    /// 找 `filled(x, y)` 为真的格子的包围盒：从上、下往里找第一行，再在这几行之间从左、右往里找，
    /// 找到就停（内容只占一小块时只扫它外面那一圈）。全空时返回 nil
    private static func scan(
        width: Int, height: Int, filled: (Int, Int) -> Bool
    ) -> (left: Int, top: Int, right: Int, bottom: Int)? {
        func rowIsEmpty(_ y: Int) -> Bool { !(0..<width).contains { filled($0, y) } }
        guard let top = (0..<height).first(where: { !rowIsEmpty($0) }),
              let bottom = (0..<height).reversed().first(where: { !rowIsEmpty($0) })
        else { return nil }
        var left = width, right = -1
        for y in top...bottom {
            var x = 0
            while x < left, !filled(x, y) { x += 1 }
            left = min(left, x)
            x = width - 1
            while x > right, !filled(x, y) { x -= 1 }
            right = max(right, x)
        }
        return (left, top, right, bottom)
    }

    private static func normalized(
        _ box: (left: Int, top: Int, right: Int, bottom: Int)?, width: Int, height: Int, scale: Int
    ) -> SIMD4<Float> {
        guard let box else { return .zero }
        let size = SIMD4(Float(width), Float(height), Float(width), Float(height))
        let pixels = SIMD4(
            Float(box.left * scale), Float(box.top * scale),
            Float(min((box.right + 1) * scale, width)), Float(min((box.bottom + 1) * scale, height)))
        return pixels / size
    }

    /// 贴图（按补齐比例）画满缓冲时，第 0 层里一个非零的像素在采样结果里最多影响到多远（贴图的 0–1 坐标）。
    /// 线性插值会取到相邻的格子：2 格。贴图比缓冲大（缩小采样）又有多层 mipmap 时，GPU 还会读更粗的几层，
    /// 那几层的非零范围比第 0 层宽：盒式缩小累计最多宽出那一层的 1 格、线性插值再 1.5 格，
    /// 按用得上的最粗一层的 4 格放宽（余下的留给别的缩小方式，WE 的 .tex 自带的 mipmap 不知道用的什么滤波）
    static func samplingMargin(of texture: LoadedTexture, bufferSize: SIMD2<Float>) -> SIMD2<Float> {
        // 按实际加载的像素算（可能跳过了几层 mipmap）
        let loaded = simd_max(
            SIMD2(Float(texture.texture.width), Float(texture.texture.height)) * texture.uvScale, SIMD2(1, 1))
        let ratio = max(loaded.x / max(bufferSize.x, 1), loaded.y / max(bufferSize.y, 1))
        var texels: Float = 2
        if texture.texture.mipmapLevelCount > 1, ratio > 1 {
            let coarsest = min(Float(texture.texture.mipmapLevelCount - 1), log2(ratio).rounded(.up))
            texels += 4 * exp2(coarsest)
        }
        return SIMD2(repeating: texels) / loaded
    }

    /// 整条链要在内容外面留多宽（缓冲的 UV 比例）。范围外的缓冲清成透明黑，整块算时那里是"透明但带颜色"
    /// （贴图透明处的颜色常不是 0）：这点差别每过一个特效往里渗"偏移 + 线性插值的 1 格"，内容（alpha 不为 0 的部分）
    /// 也每过一个特效往外长同样一段；线性插值会把透明像素的颜色按权重混进来，所以两边都要留：
    /// 2 × Σ（偏移 + 1 格），再加最后画到屏幕上时线性插值的 1 格（`scissor` 自己另外留 2 像素）
    static func chainGrowth(reach: SIMD2<Float>, effects: Int, bufferSize: SIMD2<Float>) -> SIMD2<Float> {
        let pixel = 1 / simd_max(bufferSize, SIMD2(1, 1))
        return 2 * (reach + Float(effects) * pixel) + pixel
    }

    /// 缓冲里要算的那一块：内容的包围盒（缓冲的 0–1 坐标）向外扩出各特效最多挪开的距离，再多留 2 像素给线性插值
    static func scissor(content: SIMD4<Float>, reach: SIMD2<Float>, bufferSize: SIMD2<Int>) -> MTLScissorRect {
        let size = SIMD2(Float(bufferSize.x), Float(bufferSize.y))
        let low = (SIMD2(content.x, content.y) - reach) * size - 2
        let high = (SIMD2(content.z, content.w) + reach) * size + 2
        let x0 = max(0, min(bufferSize.x - 1, Int(saturating: low.x.rounded(.down))))
        let y0 = max(0, min(bufferSize.y - 1, Int(saturating: low.y.rounded(.down))))
        let x1 = max(x0 + 1, min(bufferSize.x, Int(saturating: high.x.rounded(.up))))
        let y1 = max(y0 + 1, min(bufferSize.y, Int(saturating: high.y.rounded(.up))))
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 画布上的一块（四个角）经过投影后在屏幕上的外接矩形（像素），每边再放宽 1 像素；整块在屏幕外时为 nil。
    /// 投影里有透视（w ≤ 0）时算不准，返回整个屏幕
    static func screenScissor(
        _ corners: [SIMD4<Float>], projection: simd_float4x4, target: SIMD2<Int>
    ) -> MTLScissorRect? {
        var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var high = -low
        for corner in corners {
            let clip = projection * SIMD4(corner.x, corner.y, 0, 1)
            guard clip.w > 1e-6 else { return MTLScissorRect(x: 0, y: 0, width: target.x, height: target.y) }
            let ndc = SIMD2(clip.x, clip.y) / clip.w
            let pixel = SIMD2((ndc.x * 0.5 + 0.5) * Float(target.x), (0.5 - ndc.y * 0.5) * Float(target.y))
            low = simd_min(low, pixel)
            high = simd_max(high, pixel)
        }
        let x0 = max(0, Int(saturating: (low.x - 1).rounded(.down))), y0 = max(0, Int(saturating: (low.y - 1).rounded(.down)))
        let x1 = min(target.x, Int(saturating: (high.x + 1).rounded(.up)))
        let y1 = min(target.y, Int(saturating: (high.y + 1).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 四边形（左下、右下、左上、右上；xy 是位置，zw 是纹理坐标，纹理坐标铺满 0–1）里对应纹理坐标
    /// `[u0, u1] × [v0, v1]` 的那一小块。图层四边形是平行四边形，按纹理坐标线性插值位置就是准的
    static func subQuad(_ quad: [SIMD4<Float>], u: ClosedRange<Float>, v: ClosedRange<Float>) -> [SIMD4<Float>] {
        guard quad.count == 4 else { return quad }
        // 按纹理坐标找出四个角：(0,0) 左上、(1,0) 右上、(0,1) 左下
        func corner(_ cu: Float, _ cv: Float) -> SIMD2<Float> {
            let match = quad.min { simd_distance(SIMD2($0.z, $0.w), SIMD2(cu, cv)) < simd_distance(SIMD2($1.z, $1.w), SIMD2(cu, cv)) }!
            return SIMD2(match.x, match.y)
        }
        let origin = corner(0, 0)
        let across = corner(1, 0) - origin
        let down = corner(0, 1) - origin
        func point(_ pu: Float, _ pv: Float) -> SIMD4<Float> {
            let position = origin + across * pu + down * pv
            return SIMD4(position.x, position.y, pu, pv)
        }
        return [
            point(u.lowerBound, v.upperBound), point(u.upperBound, v.upperBound),
            point(u.lowerBound, v.lowerBound), point(u.upperBound, v.lowerBound),
        ]
    }
}

/// 着色器代码的指纹（见 `EffectRegion.codeHash`），给开发工具列出场景包里各个版本的特效用
public func effectShaderCodeHash(_ source: String) -> UInt64 {
    EffectRegion.codeHash(source)
}
