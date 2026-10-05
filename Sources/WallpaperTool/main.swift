import DesktopHost
import Foundation
import ImageIO
import VideoWallpaper
import WallpaperFormats
import WallpaperLibrary

// 开发用命令行工具。
//
//   WallpaperTool check-video <文件>...
//     逐个检查视频能否被系统播放，最后汇总。用来统计一批壁纸里有多少是 AVFoundation 解不了的格式。
//
//   WallpaperTool pkg <scene.pkg>...
//     列出包的版本和条目，按扩展名汇总。
//
//   WallpaperTool pkg-extract <scene.pkg> <输出目录>
//     把包里的全部条目解到输出目录。解出来的是壁纸作者的内容，不要放进仓库。
//
//   WallpaperTool tex <纹理.tex>...
//     打印纹理的各个字段，并核对格式是否和数据对得上。
//
//   WallpaperTool audio-spectrum [秒数]
//   WallpaperTool scan <目录> [WE 自带素材目录]
//     扫描目录下的全部壁纸项目：类型、标题、预览图；场景项目再解析 pkg、核对纹理、
//     列出需要 WE 自带素材的文件。
//
//   WallpaperTool render-scenes <目录> <WE 自带素材目录> <输出目录>
//     离屏渲染全部场景存成 PNG，并和项目自带的预览图比较相似度。
//
//   WallpaperTool regress <目录> <WE 自带素材目录> <基准目录>
//     回归基准：第一次跑会把每个场景按屏幕尺寸在第 0 秒和第 5 秒各存一张；
//     以后每次跑都和基准逐像素比较，只列出真正变了的场景（REGRESS_UPDATE=1 接受新画面）。
//
//   WallpaperTool render-folder <场景文件夹> <WE 自带素材目录> <输出.png> [秒数...]
//     渲染没打包的场景文件夹（例如 WE 自带的粒子组件预览场景），每个时间点存一张。
//     环境变量 TARGET_WIDTH / TARGET_HEIGHT 指定屏幕尺寸：给了 TARGET_HEIGHT 就按屏幕尺寸出图，
//     看到的是屏幕上真正显示的样子（含铺满裁切、文字图层的边界保护）；不给就按画布比例出图。
//
//   WallpaperTool bench-scenes <目录> <WE 自带素材目录> [帧数]
//     每个动态场景在屏幕尺寸上每帧的 CPU / GPU 时间（按 30 帧折成占用），找出最费电的场景。
//
//   WallpaperTool motion-scenes <目录> <WE 自带素材目录>
//     每个动态场景的画面动得多快、自动帧率会定成几帧、能省多少 GPU。
//
//   WallpaperTool fuzz-scenes <目录> <WE 自带素材目录> <输出目录> [每个场景几个变体] [随机种子]
//     抗坏文件测试：把真实场景包截断、改字节、篡改 JSON，每个变体在子进程里构建渲染，记下崩溃和卡死。
//
//   WallpaperTool asset-usage <目录> <WE 自带素材目录> [输出.json]
//     每个场景实际读了 WE 自带素材里的哪些文件，按"要写的一样东西"汇总，估计自己写替代素材的工作量。
//
//   WallpaperTool compat-check <目录> <WE 自带素材目录> [code|all|none] [场景编号…]
//     兼容素材的对照测试：WE 原版和兼容版各渲染一遍逐像素比较（code：只换代码；all：有的都换；none：不给 WE 素材）。
//
//   WallpaperTool scene-report <目录> <WE 自带素材目录>
//     全部场景构建一遍，汇总"暂不支持"和问题，按出现的场景数排。
//
//   WallpaperTool framing-check <目录> <WE 自带素材目录> [宽 高] [场景编号…]
//     取景自检：按屏幕尺寸渲染的和按画布比例渲染后取中间的比，找屏幕比例不同时画面不对的场景。
//
//   WallpaperTool web-capture <项目文件夹> <输出.png> [宽 高]
//     网页壁纸按给定屏幕尺寸（点，默认 1512×982）打开：报告页面有没有超出视口，并存一张截图。
//
//   WallpaperTool steam-assets <输出目录> | --version
//     用本机存的 Steam 会话下载 Wallpaper Engine 自带素材（App 里登录后自动下载的同一条路），或者只看 Steam 上的版本。
//
//   WallpaperTool steam-cm [--keychain] [--framings] [--details <编号>] [--servers] …
//     连 Steam 的 CM（客户端协议）验登录、条目详情、内容服务器列表（M7.5）。
//
//   WallpaperTool steam-manifest <清单文件> [已下载目录]
//     解析 UGC 清单（.manifest），和已下载的内容核对文件名与大小。
//
//   WallpaperTool steam-ugc <清单文件> <输出目录> …  |  --chunk <分块编号> <输出文件> …
//     不靠 SteamCMD，自己从内容服务器下载分块、解密、解压、拼成文件（M7.5-3）。

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func checkVideos(_ paths: [String]) async -> Int32 {
    var playable = 0
    for path in paths {
        if let reason = await VideoContent.unplayableReason(for: URL(fileURLWithPath: path)) {
            print("✗ \(path)\n    \(reason)")
        } else {
            playable += 1
            print("✓ \(path)")
        }
    }
    print("可以播放：\(playable) / \(paths.count)")
    return playable == paths.count ? 0 : 1
}

func listPackages(_ paths: [String]) -> Int32 {
    var failures = 0
    for path in paths {
        do {
            let package = try ScenePackage(contentsOf: URL(fileURLWithPath: path))
            let total = package.entries.reduce(0) { $0 + $1.size }
            print("\(path)\n  \(package.version)，\(package.entries.count) 个条目，共 \(total) 字节")
            let groups = Dictionary(grouping: package.entries) { ($0.name as NSString).pathExtension.lowercased() }
            for (ext, entries) in groups.sorted(by: { $0.value.count > $1.value.count }) {
                let size = entries.reduce(0) { $0 + $1.size }
                print("  .\(ext.isEmpty ? "（无扩展名）" : ext)：\(entries.count) 个，\(size) 字节")
            }
        } catch {
            failures += 1
            print("✗ \(path)\n    \(error.localizedDescription)")
        }
    }
    return failures == 0 ? 0 : 1
}

/// 打印纹理的各个字段，并核对格式：原始像素的字节数必须和按格式算出的一致，内嵌图片必须有可识别的文件头
func inspectTextures(_ paths: [String]) -> Int32 {
    var failures = 0
    for path in paths {
        let name = (path as NSString).lastPathComponent
        do {
            let tex = try TexFile(data: Data(contentsOf: URL(fileURLWithPath: path)))
            var problems: [String] = []
            var payloads = Set<String>()
            for image in tex.images {
                for mipmap in image.mipmaps {
                    let data = try mipmap.decompressedData()
                    if tex.isEmbeddedImage {
                        payloads.insert(imageKind(data))
                    } else if let format = tex.pixelFormat {
                        let expected = format.byteCount(width: mipmap.width, height: mipmap.height)
                        if data.count != expected {
                            problems.append("\(mipmap.width)×\(mipmap.height) 有 \(data.count) 字节，按格式应为 \(expected)")
                        }
                    } else {
                        problems.append("未知格式 \(tex.rawFormat)")
                    }
                }
            }
            let first = tex.images.first?.mipmaps.first
            let lz4 = tex.images.flatMap(\.mipmaps).contains(where: \.isLZ4Compressed)
            let content = tex.isEmbeddedImage
                ? "内嵌图片 FreeImage=\(tex.freeImageFormat ?? -1) \(payloads.sorted().joined(separator: "/"))"
                : "原始像素 \(tex.pixelFormat.map { "\($0)" } ?? "格式\(tex.rawFormat)")"
            print("""
                \(problems.isEmpty ? "✓" : "✗") \(name)
                    \(tex.fileVersion)/\(tex.headerVersion)/\(tex.containerVersion) 标志 \(tex.flags) \(content)\(lz4 ? " LZ4" : "")\(tex.isVideo == true ? " 视频" : "")
                    纹理 \(tex.textureWidth)×\(tex.textureHeight) 图像 \(tex.imageWidth)×\(tex.imageHeight) \
                图像 \(tex.images.count) 个 × mipmap \(tex.images.first?.mipmaps.count ?? 0) 层，\
                第一层 \(first.map { "\($0.width)×\($0.height)" } ?? "-")\
                \(tex.spriteSheet.map { "，精灵图 \($0.frames.count) 帧" } ?? "")，之后还有 \(tex.trailingByteCount) 字节
                """)
            problems.prefix(3).forEach { print("    ✗ \($0)") }
            if !problems.isEmpty { failures += 1 }
        } catch {
            failures += 1
            print("✗ \(name)\n    \(error.localizedDescription)")
        }
    }
    print("格式核对通过：\(paths.count - failures) / \(paths.count)")
    return failures == 0 ? 0 : 1
}

func imageKind(_ data: Data) -> String {
    let head = [UInt8](data.prefix(8))
    if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "JPEG" }
    if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
    if head.starts(with: Array("GIF8".utf8)) { return "GIF" }
    if head.count >= 8, head[4...7].elementsEqual("ftyp".utf8) { return "MP4" }
    return "未知(\(head.map { String(format: "%02x", $0) }.joined()))"
}

func scanProjects(in directory: String, assets: URL?) -> Int32 {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    let folders = ((try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    var kinds: [String: Int] = [:]
    var ratings: [String: Int] = [:]
    var features: [String: Int] = [:]
    var effects: [String: Int] = [:]
    var builtIn: [String: Int] = [:]
    var unresolved: [String: Int] = [:]
    var textureCount = 0
    var formats: [String: Int] = [:]
    var failures = 0

    for folder in folders {
        let project: WallpaperProject
        do {
            project = try WallpaperProject(folder: folder)
        } catch {
            failures += 1
            print("✗ \(folder.lastPathComponent)：\(error.localizedDescription)")
            continue
        }
        let raw = (try? Data(contentsOf: folder.appendingPathComponent("project.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let rating = raw?["contentrating"] as? String ?? "未标注"
        kinds[project.kind.rawValue, default: 0] += 1
        ratings[rating, default: 0] += 1
        print("\(folder.lastPathComponent) [\(project.kind.rawValue)|\(rating)] \(project.title) · 预览 \(project.preview.map(describeImage) ?? "无")")

        switch project.kind {
        case .video, .web:
            if !(project.entry.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) {
                failures += 1
                print("    ✗ 入口文件不存在")
            }
        case .scene:
            do {
                let package = try ScenePackage(contentsOf: folder.appendingPathComponent("scene.pkg"))
                let dependencies = try SceneDependencies(package: package, assets: assets)
                var textureProblems = 0
                var animated = false
                for entry in package.entries where entry.name.hasSuffix(".tex") {
                    textureCount += 1
                    if let tex = try? TexFile(data: package.contents(of: entry)) {
                        let format = tex.isEmbeddedImage ? "内嵌图片" : (tex.pixelFormat.map { "\($0)" } ?? "格式\(tex.rawFormat)")
                        formats[format, default: 0] += 1
                        if tex.spriteSheet != nil || tex.trailingByteCount > 0 { animated = true }
                    } else {
                        textureProblems += 1
                    }
                }
                let found = sceneFeatures(package: package, dependencies: dependencies, animatedTexture: animated)
                found.features.forEach { features[$0, default: 0] += 1 }
                found.effects.forEach { effects[$0, default: 0] += 1 }
                dependencies.inAssets.forEach { builtIn[$0, default: 0] += 1 }
                dependencies.missing.forEach { unresolved[$0, default: 0] += 1 }

                print("    \(package.version) 条目 \(package.entries.count) · 自带素材 \(dependencies.inAssets.count) · "
                    + (dependencies.missing.isEmpty ? "依赖齐全" : "找不到 \(dependencies.missing.count) 个")
                    + (textureProblems > 0 ? " · ✗ \(textureProblems) 个纹理读不了" : "")
                    + " · \(found.features.sorted().joined(separator: "、"))")
                dependencies.problems.forEach { print("    ✗ \($0)") }
                if textureProblems > 0 || !dependencies.problems.isEmpty { failures += 1 }
            } catch {
                failures += 1
                print("    ✗ \(error.localizedDescription)")
            }
        case .application, .unknown:
            break
        }
    }

    func table(_ title: String, _ counts: [String: Int], limit: Int = 40) {
        guard !counts.isEmpty else { return }
        print("\n\(title)")
        for (name, count) in counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }).prefix(limit) {
            print("  \(String(format: "%3d", count))  \(name)")
        }
    }

    print("\n共 \(folders.count) 个项目：" + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "，"))
    print("内容分级：" + ratings.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "，"))
    print("场景包里的纹理 \(textureCount) 个：" + formats.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "，"))
    table("场景功能（数字是用到它的场景数）", features)
    table("特效使用次数（同一场景里用多次按多次计）", effects)
    table("用到最多的 WE 自带素材（场景数）", builtIn, limit: 25)
    if assets != nil {
        table("包里和自带素材里都找不到的文件（场景数）", unresolved)
    }
    print(failures == 0 ? "\n全部正常" : "\n有 \(failures) 处问题")
    return failures == 0 ? 0 : 1
}

/// 粗略判断场景用了哪些功能，用来安排渲染器的开发顺序。基于关键字，不追求精确
func sceneFeatures(
    package: ScenePackage, dependencies: SceneDependencies, animatedTexture: Bool
) -> (features: Set<String>, effects: [String]) {
    var features = Set<String>()
    let sceneText = package.contents(of: "scene.json").map { String(decoding: $0, as: UTF8.self) } ?? ""
    let scene = package.contents(of: "scene.json").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let general = scene?["general"] as? [String: Any]
    func enabled(_ key: String) -> Bool {
        let value = general?[key]
        return (value as? Bool) ?? ((value as? [String: Any])?["value"] as? Bool) ?? false
    }

    for (kind, count) in dependencies.objectKinds where count > 0 {
        switch kind {
        case "particle": features.insert("粒子")
        case "text": features.insert("文字")
        case "sound": features.insert("声音")
        case "model": features.insert("3D 模型对象")
        case "light": features.insert("灯光")
        default: break
        }
    }
    if case .perspective = dependencies.projectionKind { features.insert("透视相机") }
    if case .auto = dependencies.projectionKind { features.insert("自动画布") }
    if enabled("cameraparallax") { features.insert("鼠标视差") }
    if enabled("camerashake") { features.insert("镜头抖动") }
    if enabled("bloom") || enabled("hdr") { features.insert("泛光/HDR") }
    if sceneText.contains("\"script\"") { features.insert("脚本") }
    if sceneText.contains("\"user\"") { features.insert("用户属性") }
    if animatedTexture { features.insert("动图纹理") }

    var packageText = ""
    for entry in package.entries {
        let name = entry.name.lowercased()
        if name.hasSuffix(".mdl") { features.insert("MDL 模型") }
        if name.hasSuffix(".json") || name.hasSuffix(".frag") || name.hasSuffix(".vert") {
            packageText += String(decoding: package.contents(of: entry), as: UTF8.self).lowercased()
        }
    }
    if packageText.contains("\"puppet\"") { features.insert("木偶变形") }
    if packageText.contains("audiospectrum") || sceneText.lowercased().contains("audioprocessing") {
        features.insert("音频响应")
    }

    var effectFiles: [String] = []
    for object in scene?["objects"] as? [[String: Any]] ?? [] {
        for effect in object["effects"] as? [[String: Any]] ?? [] {
            if let file = effect["file"] as? String {
                effectFiles.append(file.replacingOccurrences(of: "/effect.json", with: ""))
            }
        }
    }
    if !effectFiles.isEmpty { features.insert("特效") }
    return (features, effectFiles)
}

func describeImage(_ url: URL) -> String {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return "\(url.lastPathComponent) ✗ 读不出来" }
    let frames = CGImageSourceGetCount(source)
    return "\(url.lastPathComponent) \(width)×\(height)" + (frames > 1 ? "，\(frames) 帧动图" : "")
}

func extractPackage(_ path: String, to output: String) throws {
    let package = try ScenePackage(contentsOf: URL(fileURLWithPath: path))
    let root = URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
    for entry in package.entries {
        // 条目名来自不可信文件，不允许写到输出目录之外
        let file = root.appendingPathComponent(entry.name).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else {
            print("跳过越界条目：\(entry.name)")
            continue
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try package.contents(of: entry).write(to: file)
    }
    print("已解出 \(package.entries.count) 个条目到 \(root.path)")
}

switch (arguments.first, arguments.count) {
case ("check-video", 2...):
    exit(await checkVideos(Array(arguments.dropFirst())))
case ("pkg", 2...):
    exit(listPackages(Array(arguments.dropFirst())))
case ("tex", 2...):
    exit(inspectTextures(Array(arguments.dropFirst())))
case ("audio-spectrum", 2...3):
    exit(await inspectAudioSpectrum(seconds: arguments.count > 2 ? Double(arguments[2]) ?? 3 : 3))
case ("scene-report", 3):
    exit(sceneReport(in: arguments[1], assets: URL(fileURLWithPath: arguments[2])))
case ("framing-check", 3...):
    var rest = Array(arguments.dropFirst(3))
    var size = (1512, 982)
    if rest.count >= 2, let w = Int(rest[0]), let h = Int(rest[1]), w < 100_000, h < 100_000 {
        size = (w, h)
        rest.removeFirst(2)
    }
    exit(framingCheck(
        in: arguments[1], assets: URL(fileURLWithPath: arguments[2]), width: size.0, height: size.1, only: Set(rest)))
case ("web-capture", 3), ("web-capture", 5):
    let size = arguments.count == 5
        ? CGSize(width: Double(arguments[3]) ?? 1512, height: Double(arguments[4]) ?? 982) : CGSize(width: 1512, height: 982)
    exit(await webCapture(folder: arguments[1], output: arguments[2], size: size))
case ("steam-assets", 2):
    exit(await steamAssets(output: arguments[1] == "--version" ? nil : arguments[1]))
case ("steam-cm", 1...):
    exit(await steamCMProbe(Array(arguments.dropFirst())))
case ("steam-manifest", 2...3):
    exit(steamManifestProbe(Array(arguments.dropFirst())))
case ("steam-ugc", 1...):
    exit(await steamUGCProbe(Array(arguments.dropFirst())))
case ("steam-workshop", 2...):
    exit(await steamWorkshopProbe(Array(arguments.dropFirst())))
case ("scan", 2...3):
    exit(scanProjects(in: arguments[1], assets: arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : nil))
case ("shader-corpus", 4):
    exit(shaderCorpus(in: arguments[1], assets: URL(fileURLWithPath: arguments[2]), output: arguments[3]))
case ("render-scenes", 4):
    exit(renderScenes(in: arguments[1], assets: URL(fileURLWithPath: arguments[2]), output: arguments[3]))
case ("regress", 4):
    exit(regressScenes(in: arguments[1], assets: URL(fileURLWithPath: arguments[2]), baseline: arguments[3]))
case ("render-folder", 4...):
    exit(renderFolder(
        arguments[1], assets: URL(fileURLWithPath: arguments[2]), output: arguments[3],
        times: arguments.count > 4 ? arguments.dropFirst(4).compactMap { Float($0) } : [0, 2]))
case ("bench-scenes", 3...4):
    exit(benchScenes(
        in: arguments[1], assets: URL(fileURLWithPath: arguments[2]),
        frames: arguments.count > 3 ? Int(arguments[3]) ?? 60 : 60))
case ("fuzz-scenes", 4...6):
    exit(fuzzScenes(
        in: arguments[1], assets: arguments[2], output: arguments[3],
        variants: arguments.count > 4 ? Int(arguments[4]) ?? 12 : 12,
        seed: arguments.count > 5 ? UInt64(arguments[5]) ?? 1 : 1))
case ("asset-usage", 3...4):
    exit(assetUsage(
        in: arguments[1], assets: URL(fileURLWithPath: arguments[2]), output: arguments.count > 3 ? arguments[3] : nil))
case ("compat-check", 3...):
    exit(compatCheck(
        in: arguments[1], assets: URL(fileURLWithPath: arguments[2]), mode: arguments.count > 3 ? arguments[3] : "code",
        only: Set(arguments.dropFirst(4))))
case ("probe-effect", 3...7):
    exit(probeEffect(
        assets: arguments[1], fragment: arguments[2], input: arguments.count > 3 ? arguments[3] : "impulse",
        width: arguments.count > 4 ? Int(arguments[4]) ?? 33 : 33, height: arguments.count > 5 ? Int(arguments[5]) ?? 9 : 9,
        vertex: arguments.count > 6 ? arguments[6] : nil))
case ("probe-particle", 4):
    exit(probeParticle(assets: arguments[1], output: arguments[2], spec: arguments[3]))
case ("probe-scene", 4...):
    exit(probeScene(
        assets: arguments[1], folder: arguments[2], output: arguments[3],
        time: arguments.count > 4 ? Float(arguments[4]) ?? 0 : 0,
        points: arguments.dropFirst(5).compactMap { item in
            let parts = item.split(separator: ",").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }))
case ("compat-textures", 2):
    exit(exportCompatTextures(to: arguments[1]))
case ("tex-stats", 2...):
    exit(texStats(Array(arguments.dropFirst())))
case ("fuzz-one", 3):
    exit(fuzzOne(package: arguments[1], assets: arguments[2]))
case ("motion-scenes", 3):
    exit(motionScenes(in: arguments[1], assets: URL(fileURLWithPath: arguments[2])))
case ("effect-variants", 4...):
    exit(listEffectVariants(
        in: arguments[1], assets: URL(fileURLWithPath: arguments[2]), output: arguments[3],
        names: arguments.count > 4 ? Array(arguments.dropFirst(4))
            : ["shake", "waterwaves", "waterripple", "foliagesway", "iris", "waterflow", "pulse", "opacity"]))
case ("pkg-extract", 3):
    do {
        try extractPackage(arguments[1], to: arguments[2])
    } catch {
        fail("解包失败：\(error.localizedDescription)")
    }
default:
    fail("""
        用法：
          WallpaperTool check-video <文件>...
          WallpaperTool pkg <scene.pkg>...
          WallpaperTool pkg-extract <scene.pkg> <输出目录>
          WallpaperTool tex <纹理.tex>...
          WallpaperTool audio-spectrum [秒数]
          WallpaperTool scan <目录> [WE 自带素材目录]
          WallpaperTool render-scenes <目录> <WE 自带素材目录> <输出目录>
          WallpaperTool regress <目录> <WE 自带素材目录> <基准目录>
          WallpaperTool render-folder <场景文件夹> <WE 自带素材目录> <输出.png> [秒数...]
          WallpaperTool bench-scenes <目录> <WE 自带素材目录> [帧数]
          WallpaperTool motion-scenes <目录> <WE 自带素材目录>
          WallpaperTool fuzz-scenes <目录> <WE 自带素材目录> <输出目录> [每个场景几个变体] [随机种子]
          WallpaperTool asset-usage <目录> <WE 自带素材目录> [输出.json]
          WallpaperTool compat-check <目录> <WE 自带素材目录> [code|all|none] [场景编号…]
          WallpaperTool probe-effect <WE 自带素材目录|none> <片元着色器> [impulse|ramp|grid] [宽] [高] [顶点着色器]
          WallpaperTool probe-particle <WE 自带素材目录> <输出目录> '<规格 JSON>'
          WallpaperTool probe-scene <WE 自带素材目录> <场景文件夹> <输出目录> [秒数] [x,y …]
          WallpaperTool effect-variants <目录> <WE 自带素材目录> <输出目录> [特效名...]
          WallpaperTool shader-corpus <目录> <WE 自带素材目录> <输出目录>
        """)
}

/// 打印系统音频的频谱，用来核对音频律动（放音乐时数值应当跟着变）
func inspectAudioSpectrum(seconds: Double) async -> Int32 {
    let spectrum = SystemAudioSpectrum.shared
    guard spectrum.start() else {
        print("✗ 系统音频采集不可用：\(spectrum.problem ?? "未知原因")")
        return 1
    }
    print("已开始采集系统音频，\(Int(seconds)) 秒内每 0.25 秒打印一次 16 段频谱（放点音乐看看数值会不会动）")
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 250_000_000)
        let bands = spectrum.bands(16)
        let left = bands.left.map { String(format: "%.2f", $0) }.joined(separator: " ")
        let peak = bands.left.max() ?? 0
        print(String(format: "[%5.2f] 峰值 %.3f  L: %@", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100), peak, left))
    }
    spectrum.stop()
    return 0
}
