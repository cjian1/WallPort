import Foundation

/// 一个 WE 着色器对外暴露的接口：开关、材质参数、贴图槽。
///
/// 这些信息写在注释里（预处理之后就没了），所以必须从原始源码读：
///
///     // [COMBO] {"material":"…","combo":"MASK","type":"options","default":0}
///     uniform float g_Speed; // {"material":"speed","default":1,"range":[0.0, 10]}
///     uniform sampler2D g_Texture1; // {"mode":"flowmask","default":"util/noflow","combo":"TIMEOFFSET"}
///
/// 规则来自 2026-09-28 对用户本机 WE 自带素材和场景包里着色器的观察。
public struct ShaderInterface: Equatable, Sendable, Codable {
    public struct Combo: Equatable, Sendable, Codable {
        public let name: String
        public let defaultValue: Int
    }

    /// 可以由材质或场景设置的 uniform（注释里带 "material" 键的）
    public struct Parameter: Equatable, Sendable, Codable {
        public let uniform: String
        /// 材质和场景里用的键，例如 "speed"
        public let key: String
        public let type: String
        /// 注释里的默认值，统一成浮点分量（"1 1" → [1, 1]，true → [1]）
        public let defaultValue: [Float]
    }

    public struct TextureSlot: Equatable, Sendable, Codable {
        /// g_TextureN 的 N
        public let index: Int
        /// 没有指定贴图时用的默认贴图，例如 "util/noflow"
        public let defaultTexture: String?
        /// 这个槽有贴图时要打开的开关，例如 "MASK"
        public let combo: String?
    }

    public var combos: [Combo] = []
    public var parameters: [Parameter] = []
    public var textures: [TextureSlot] = []

    public init() {}

    /// 从一段或多段源码（顶点、片段和它们引用的头文件）里收集接口
    public init(sources: [String]) {
        var seenCombos = Set<String>()
        var seenParameters = Set<String>()
        var seenTextures = Set<Int>()
        for source in sources {
            for line in source.split(whereSeparator: \.isNewline) {
                let text = line.trimmingCharacters(in: .whitespaces)
                if let combo = Self.combo(in: text), seenCombos.insert(combo.name).inserted {
                    combos.append(combo)
                } else if let slot = Self.textureSlot(in: text), seenTextures.insert(slot.index).inserted {
                    textures.append(slot)
                } else if let parameter = Self.parameter(in: text), seenParameters.insert(parameter.uniform).inserted {
                    parameters.append(parameter)
                }
            }
        }
        textures.sort { $0.index < $1.index }
    }

    static func combo(in line: String) -> Combo? {
        guard line.hasPrefix("//"), let marker = line.range(of: "[COMBO]"),
              let json = Self.json(String(line[marker.upperBound...])),
              let name = json["combo"] as? String
        else { return nil }
        return Combo(name: name, defaultValue: (json["default"] as? NSNumber)?.intValue ?? 0)
    }

    static func textureSlot(in line: String) -> TextureSlot? {
        guard let declaration = uniformDeclaration(in: line), declaration.type.hasPrefix("sampler"),
              declaration.name.hasPrefix("g_Texture"), let index = Int(declaration.name.dropFirst("g_Texture".count))
        else { return nil }
        return TextureSlot(
            index: index,
            defaultTexture: declaration.annotation?["default"] as? String,
            combo: declaration.annotation?["combo"] as? String)
    }

    static func parameter(in line: String) -> Parameter? {
        guard let declaration = uniformDeclaration(in: line), !declaration.type.hasPrefix("sampler"),
              let key = declaration.annotation?["material"] as? String
        else { return nil }
        return Parameter(
            uniform: declaration.name, key: key, type: declaration.type,
            defaultValue: floats(declaration.annotation?["default"]))
    }

    /// `uniform <类型> <名字>[数组]; // {注释 JSON}`
    static func uniformDeclaration(in line: String) -> (type: String, name: String, annotation: [String: Any]?)? {
        guard line.hasPrefix("uniform ") else { return nil }
        let parts = line.components(separatedBy: "//")
        let declaration = parts[0].trimmingCharacters(in: .whitespaces)
        guard declaration.hasSuffix(";") else { return nil }
        let words = declaration.dropLast().split(separator: " ").map(String.init)
        guard words.count >= 3 else { return nil }
        let name = words[2].split(separator: "[").first.map(String.init) ?? words[2]
        let annotation = parts.count > 1 ? json(parts.dropFirst().joined(separator: "//")) : nil
        return (words[1], name, annotation)
    }

    static func json(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 注释和材质里的值：数字、布尔、"1 0.5" 这样的字符串。有 NaN、无穷大时当成没写
    public static func floats(_ value: Any?) -> [Float] {
        switch value {
        case let number as NSNumber:
            return number.floatValue.isFinite ? [number.floatValue] : []
        case let text as String:
            // 向量写法可能是空格分隔，也可能是逗号分隔（"0.0, 1.0"）
            let values = text.replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
            return values.allSatisfy(\.isFinite) ? values : []
        case let array as [Any]:
            return array.flatMap(floats)
        default:
            return []
        }
    }
}
