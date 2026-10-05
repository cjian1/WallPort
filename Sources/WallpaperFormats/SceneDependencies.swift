import Foundation

/// 从 scene.json 出发，顺着引用链找出场景用到的全部文件，分成"包里有""在 WE 自带素材里"和"都找不到"三类。
/// 包里没有的，按 WE 的约定来自它自带的素材目录（assets）；给了素材目录时，也会继续追踪素材自身的引用
/// （例如自带着色器 #include 的头文件）。
///
/// 引用规则（2026-09-28 用 ~/wp 里的 8 个真实场景核对）：
/// - 场景对象：`image` → 模型 JSON，`particle` → 粒子 JSON，`model` → 模型 JSON，
///   `effects[].file` → 特效 JSON，`font` → 字体文件，`sound[]` → 音频文件；
/// - 模型：`material` → 材质 JSON；特效：`passes[].material` → 材质 JSON，`dependencies[]` → 文件；
/// - 材质和各处的 pass：`shader` → shaders/<名>.vert 和 .frag，`textures[]` → materials/<名>.tex；
///   以 `_rt_` 开头的纹理名是运行时的渲染目标，不是文件；
/// - 着色器里的 `#include "x"` → shaders/x。
public struct SceneDependencies: Sendable {
    /// 场景的投影方式（和 `SceneDescription.Projection` 同一个口径）
    public enum Projection: Sendable, Equatable {
        case fixed(width: Int, height: Int)
        case auto
        case perspective
    }

    public let sceneVersion: Int?
    /// general.orthogonalprojection 的宽高；透视场景为 nil
    public let projection: (width: Int, height: Int)?
    /// 投影方式：写了宽高 / auto / 缺省（透视）
    public let projectionKind: Projection
    /// 对象按类型计数：image、particle、text、sound、model、其他
    public let objectKinds: [String: Int]
    public let inPackage: Set<String>
    /// 在 WE 自带素材目录里找到的
    public let inAssets: Set<String>
    /// 包里和素材目录里都没有（没给素材目录时，就是全部不在包里的）
    public let missing: Set<String>
    /// 读不懂的文件和原因
    public let problems: [String]

    /// - Parameter assets: WE 自带素材目录（Windows 上的 wallpaper_engine/assets）；nil 时只看包
    public init(package: ScenePackage, assets: URL? = nil) throws {
        guard let sceneData = package.contents(of: "scene.json") else {
            throw FormatError("包里没有 scene.json")
        }
        guard let scene = (try? JSONSerialization.jsonObject(with: sceneData)) as? [String: Any] else {
            throw FormatError("scene.json 不是有效的 JSON")
        }
        let general = scene["general"] as? [String: Any]
        sceneVersion = scene["version"] as? Int
        if let ortho = general?["orthogonalprojection"] as? [String: Any] {
            if let width = ortho["width"] as? Int, let height = ortho["height"] as? Int, width > 0, height > 0 {
                projection = (width, height)
                projectionKind = .fixed(width: width, height: height)
            } else if (ortho["auto"] as? Bool) == true
                || ((ortho["auto"] as? [String: Any])?["value"] as? Bool) == true {
                projection = nil
                projectionKind = .auto
            } else {
                projection = nil
                projectionKind = .perspective
            }
        } else {
            projection = nil
            projectionKind = .perspective
        }
        var kinds: [String: Int] = [:]
        for object in scene["objects"] as? [[String: Any]] ?? [] {
            let kind = ["image", "particle", "text", "sound", "model", "light"].first { object[$0] != nil } ?? "其他"
            kinds[kind, default: 0] += 1
        }
        objectKinds = kinds

        let names = Set(package.entries.map(\.name))
        var found: Set<String> = ["scene.json"]
        var fromAssets: Set<String> = []
        var missing: Set<String> = []
        var problems: [String] = []
        var queue: [String] = []

        func assetFile(_ path: String) -> URL? {
            guard let assets else { return nil }
            let file = assets.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: file.path) ? file : nil
        }

        func visit(_ path: String) {
            guard !found.contains(path), !fromAssets.contains(path), !missing.contains(path) else { return }
            if names.contains(path) {
                found.insert(path)
                queue.append(path)
            } else if assetFile(path) != nil {
                fromAssets.insert(path)
                queue.append(path)
            } else {
                missing.insert(path)
            }
        }

        Self.references(in: scene).forEach(visit)
        while let path = queue.popLast() {
            let contents = names.contains(path) ? package.contents(of: path) : assetFile(path).flatMap { try? Data(contentsOf: $0) }
            guard let data = contents else { continue }
            switch (path as NSString).pathExtension.lowercased() {
            case "json":
                if let object = try? JSONSerialization.jsonObject(with: data) {
                    Self.references(in: object).forEach(visit)
                } else {
                    problems.append("\(path) 不是有效的 JSON")
                }
            case "vert", "frag", "h":
                Self.includes(in: String(decoding: data, as: UTF8.self)).forEach(visit)
            default:
                break
            }
        }
        inPackage = found
        inAssets = fromAssets
        self.missing = missing
        self.problems = problems
    }

    /// 在任意 JSON 值里按上面的规则找引用
    static func references(in value: Any) -> [String] {
        var result: [String] = []
        func walk(_ value: Any) {
            if let array = value as? [Any] {
                array.forEach(walk)
                return
            }
            guard let object = value as? [String: Any] else { return }
            for (key, child) in object {
                switch (key, child) {
                case ("image", let path as String), ("particle", let path as String), ("model", let path as String),
                     ("material", let path as String), ("file", let path as String):
                    if path.contains("/") || path.hasSuffix(".json") { result.append(path) }
                case ("font", let path as String) where !path.hasPrefix("systemfont"):
                    result.append(path)
                case ("sound", let paths as [Any]):
                    result += paths.compactMap { $0 as? String }
                case ("dependencies", let paths as [Any]):
                    result += paths.compactMap { $0 as? String }.map(runtimeAsset)
                case ("shader", let name as String):
                    result += ["shaders/\(name).vert", "shaders/\(name).frag"]
                case ("textures", let names as [Any]):
                    result += names.compactMap { $0 as? String }
                        .filter { !$0.isEmpty && !$0.hasPrefix("_rt_") }
                        .map { "materials/\($0).tex" }
                default:
                    break
                }
                walk(child)
            }
        }
        walk(value)
        return result
    }

    /// 特效的 dependencies 里会列出编辑器用的源图片（.png、.tex-json 等），运行时用的是编译好的同名 .tex
    static func runtimeAsset(_ path: String) -> String {
        let sourceExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tga", "bmp", "tex-json"]
        let ext = (path as NSString).pathExtension.lowercased()
        guard sourceExtensions.contains(ext) else { return path }
        return (path as NSString).deletingPathExtension + ".tex"
    }

    /// 着色器源码里的 #include "x"
    static func includes(in source: String) -> [String] {
        source.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#include"),
                  let open = trimmed.firstIndex(of: "\""),
                  let close = trimmed[trimmed.index(after: open)...].firstIndex(of: "\"")
            else { return nil }
            return "shaders/" + trimmed[trimmed.index(after: open)..<close]
        }
    }
}
