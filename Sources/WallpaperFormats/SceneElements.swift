import Foundation

/// 场景里用户可以单独关掉的内容：粒子、文字（时钟、日期）、图层上的特效（电光、火焰、晃动……）。
///
/// 作者不一定在壁纸设置里给这些做开关，所以设置面板按场景内容自动列出来，关掉的就不画。
/// 按类别合并成一项，免得列表太长（语料 351 个场景里单个元素中位数 4 个、最多 71 个）：
/// - 粒子按名字合并（"Snow particles" 三个系统是一项）；WE 的粒子预设名本身就说明了是什么（Ember、Fireflies…）；
/// - 文字每个图层一项（时钟、日期、秒数往往是几个图层，用户可能只想关其中一个）；
/// - 特效按种类合并（3142391697 的"电光" nitro 挂在 5 个文字图层上，是一项）。
public struct SceneElement: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case particles, text, effect

        public var title: String {
            switch self {
            case .particles: String(localized: "粒子")
            case .text: String(localized: "文字 / 时钟")
            case .effect: String(localized: "特效")
            }
        }
    }

    /// 存设置用的键：`particles:<名字>` / `text:<图层编号>` / `effect:<特效文件夹名>`
    public let id: String
    public let kind: Kind
    public let title: String
    /// 合并了几个（大于 1 时界面上写"×N"）
    public let count: Int
}

public enum SceneElements {
    /// 从场景包里列出可以关掉的内容（只读 scene.json；包是内存映射打开的，不会整个读进来）
    public static func list(package: ScenePackage) -> [SceneElement] {
        package.contents(of: "scene.json").map(list(sceneJSON:)) ?? []
    }

    public static func list(sceneJSON: Data) -> [SceneElement] {
        guard let root = try? JSONSerialization.jsonObject(with: sceneJSON) as? [String: Any],
              let objects = root["objects"] as? [[String: Any]]
        else { return [] }
        var particles: [(name: String, count: Int)] = []
        var texts: [SceneElement] = []
        var effects: [(folder: String, count: Int)] = []
        for object in objects where !isAlwaysHidden(object["visible"]) {
            if object["particle"] != nil {
                let name = displayName(object["name"]) ?? "粒子"
                if let index = particles.firstIndex(where: { $0.name == name }) {
                    particles[index].count += 1
                } else {
                    particles.append((name, 1))
                }
            } else if object["text"] != nil, let id = SceneValue.int(object["id"]) {
                texts.append(SceneElement(
                    id: "text:\(id)", kind: .text, title: displayName(object["name"]) ?? String(localized: "文字 \(id)"),
                    count: 1))
            }
            for effect in object["effects"] as? [[String: Any]] ?? [] where !isAlwaysHidden(effect["visible"]) {
                guard let folder = effectFolder(effect["file"]) else { continue }
                if let index = effects.firstIndex(where: { $0.folder == folder }) {
                    effects[index].count += 1
                } else {
                    effects.append((folder, 1))
                }
            }
        }
        // 没名字的粒子：存设置的键里是"粒子"（不能跟着界面语言变，否则关掉的设置会失效），显示的名字才翻译
        return particles.map { particle in
            SceneElement(
                id: "particles:\(particle.name)", kind: .particles,
                title: particle.name == "粒子" ? String(localized: "粒子") : particle.name, count: particle.count)
        }
            + texts
            + effects.map { SceneElement(id: "effect:\($0.folder)", kind: .effect, title: effectTitle($0.folder), count: $0.count) }
    }

    /// 把用户关掉的内容标成不可见（图层的 `visible`、特效的 `visible` 直接写成 false，原来绑的属性、脚本都不再起作用）。
    /// 关掉父图层时子图层跟着不画（和 WE 里隐藏父图层一样：时钟的秒数、日期常挂在时钟下面）
    static func hiding(_ hidden: Set<String>, in root: [String: Any]) -> [String: Any] {
        guard !hidden.isEmpty, var objects = root["objects"] as? [[String: Any]] else { return root }
        for index in objects.indices {
            var object = objects[index]
            let id = SceneValue.int(object["id"])
            let isHidden: Bool
            if object["particle"] != nil {
                isHidden = hidden.contains("particles:\(displayName(object["name"]) ?? "粒子")")
            } else if object["text"] != nil, let id {
                isHidden = hidden.contains("text:\(id)")
            } else {
                isHidden = false
            }
            if isHidden { object["visible"] = false }
            if var effects = object["effects"] as? [[String: Any]] {
                for effectIndex in effects.indices {
                    if let folder = effectFolder(effects[effectIndex]["file"]), hidden.contains("effect:\(folder)") {
                        effects[effectIndex]["visible"] = false
                    }
                }
                object["effects"] = effects
            }
            objects[index] = object
        }
        var result = root
        result["objects"] = objects
        return result
    }

    /// 写死成 false（没绑属性、没挂脚本）的：作者本来就不让它出现，列出来也没意义
    private static func isAlwaysHidden(_ visible: Any?) -> Bool {
        guard let flag = visible as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
        return !flag.boolValue
    }

    private static func displayName(_ raw: Any?) -> String? {
        guard let name = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return name
    }

    /// `effects/workshop/2214939679/psyhue/effect.json` → `psyhue`
    static func effectFolder(_ raw: Any?) -> String? {
        guard let file = raw as? String else { return nil }
        let parts = file.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return String(parts[parts.count - 2])
    }

    /// 常见的 WE 自带特效给个好懂的名字（跟着界面语言），其余用文件夹名（下划线换成空格）。都带上原名，方便和 WE 编辑器对照
    static func effectTitle(_ folder: String) -> String {
        let readable = folder.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        guard let known = knownEffects[readable.lowercased()] else { return readable }
        return String(localized: "\(known)（\(readable)）")
    }

    private static let knownEffects: [String: String] = [
        "shake": String(localized: "晃动"),
        "waterwaves": String(localized: "水波"),
        "foliagesway": String(localized: "植物摇摆"),
        "pulse": String(localized: "脉动"),
        "waterripple": String(localized: "水面涟漪"),
        "xray": String(localized: "X 光"),
        "x ray plus": String(localized: "X 光"),
        "waterflow": String(localized: "水流"),
        "shine": String(localized: "闪光"),
        "iris": String(localized: "眼睛移动"),
        "iris follow cursor": String(localized: "眼睛跟随鼠标"),
        "godrays": String(localized: "光束"),
        "lightshafts": String(localized: "光束"),
        "blend": String(localized: "混合"),
        "opacity": String(localized: "透明度"),
        "blur": String(localized: "模糊"),
        "blurprecise": String(localized: "模糊"),
        "motionblur": String(localized: "动态模糊"),
        "localcontrast": String(localized: "局部对比度"),
        "nitro": String(localized: "电光"),
        "psyhue": String(localized: "变色"),
        "hue shift": String(localized: "变色"),
        "shift hue": String(localized: "变色"),
        "scroll": String(localized: "滚动"),
        "clouds": String(localized: "云"),
        "vhs": String(localized: "VHS 故障"),
        "twirl": String(localized: "旋涡"),
        "spin": String(localized: "旋转"),
        "reflection": String(localized: "倒影"),
        "transform": String(localized: "变换"),
        "tint": String(localized: "着色"),
        "swing": String(localized: "摆动"),
        "fire": String(localized: "火焰"),
        "bloom": String(localized: "泛光"),
        "simple audio bars": String(localized: "音频条"),
        "audio responsive oscilloscope": String(localized: "音频示波器"),
        "crt scan line": String(localized: "扫描线"),
    ]
}
