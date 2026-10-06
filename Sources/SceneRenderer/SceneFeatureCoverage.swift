import Foundation
import WallpaperFormats

/// 场景特性的覆盖检查：把 scene.json 里作者写了、但渲染器**没有实现**的整场景特性列出来。
///
/// 渲染器以前只报告它自己知道要跳过的东西（"灯光"、"粒子算子 vortex_v2"……）。但像 `general.zoom`、
/// `general.cameraparallax`、`general.gravitystrength` 这类是**解析层面就没读**——渲染器根本不知道它们存在，
/// 于是 `scene-report` 看起来接近满分，实际画面和 WE 不一样。这个检查把这些沉默的缺口变成可见的报告项，
/// 交给 `WallpaperTool acceptance` 判定（哪些计入失分、哪些是写着证据的豁免）。
///
/// 只报"确认没实现、且可能改变画面"的项，普通编辑器字段（locktransforms 之类）不报，免得报告全是噪音。
enum SceneFeatureCoverage {
    /// `general` 里我们已经处理、或者确认不影响画面的键。名单外的键一律当成"未处理"报出来——
    /// 作者那边一出现新键就能看到，而不是悄悄忽略
    static let knownGeneralKeys: Set<String> = [
        // 已经实现
        "orthogonalprojection", "clearcolor", "clearenabled",
        "fov", "nearz", "farz", "perspectiveoverridefov",
        "bloom", "bloomstrength", "bloomthreshold", "bloomtint",
        "bloomhdrfeather", "bloomhdrscatter", "bloomhdrstrength", "bloomhdrthreshold", "bloomhdriterations",
        "zoom", "cameraparallax", "cameraparallaxamount", "cameraparallaxdelay", "cameraparallaxmouseinfluence",
        "camerashake", "camerashakeamplitude", "camerashakeroughness", "camerashakespeed",
        "gravitydirection", "gravitystrength", "windenabled", "winddirection", "windstrength",
        // 编辑器用 / 只对 3D 光照有意义，2D 场景不受影响
        "camerapreview", "ambientcolor", "skylightcolor",
    ]

    /// 作者写了、但这一版**故意没做**的项（会报出来，再由验收口径决定计分还是豁免）
    static let knownGaps: Set<String> = ["camerafade", "hdr"]

    /// 图层上"确认没实现、又可能改变画面"的键
    static let unhandledObjectKeys: Set<String> = [
        "perspective", "castshadow", "disablepropagation", "ledsource",
    ]

    /// 返回"暂不支持"报告项 → 出现次数，格式和 `SceneRenderer.unsupported` 一致
    static func unhandled(in sceneData: Data, scene: SceneDescription) -> [String: Int] {
        guard let root = (try? JSONSerialization.jsonObject(with: sceneData)) as? [String: Any] else { return [:] }
        var result: [String: Int] = [:]

        let general = root["general"] as? [String: Any] ?? [:]
        for key in general.keys where !knownGeneralKeys.contains(key) && !knownGaps.contains(key) {
            result["general.\(key)（未处理）", default: 0] += 1
        }
        // 开场淡入：WE 加载时会从黑色淡进来，壁坞不实现（场景文件里没有时长参数，无法照做）
        if scene.cameraEffects.fadeEnabled {
            result["开场淡入（camerafade，未实现）", default: 0] += 1
        }
        // HDR 场景的泛光是另一套（要浮点精度），没实现；非 HDR 的泛光是做了的
        if SceneValue.bool(general["hdr"]) == true, SceneValue.bool(general["bloom"]) == true {
            result["HDR 泛光（未实现）", default: 0] += 1
        }

        for raw in root["objects"] as? [[String: Any]] ?? [] {
            for key in unhandledObjectKeys where raw[key] != nil {
                guard let value = SceneValue.unwrap(raw[key]) else { continue }
                switch key {
                default:
                    // 其余几个只在打开（true）时才有作用；关着就当没写
                    if let flag = value as? Bool, flag {
                        result[objectKeyTitle(key), default: 0] += 1
                    } else if let number = value as? NSNumber, number.boolValue {
                        result[objectKeyTitle(key), default: 0] += 1
                    }
                }
            }
        }
        return result
    }

    private static func objectKeyTitle(_ key: String) -> String {
        switch key {
        case "perspective": return "透视图层（perspective，未实现）"
        case "castshadow": return "图层投影（castshadow，未实现）"
        case "disablepropagation": return "光照不传播（disablepropagation，未实现）"
        case "ledsource": return "LED 联动（ledsource，未实现）"
        default: return "图层字段 \(key)（未处理）"
        }
    }
}
