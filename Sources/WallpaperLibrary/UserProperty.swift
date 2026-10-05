import DesktopHost
import Foundation

/// 属性的值。颜色是 "r g b"（0–1）字符串，下拉选项的值可能是字符串也可能是数字
public enum PropertyValue: Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)

    public init?(json: Any?) {
        // 先按 NSNumber 判断：Swift 会把任何 NSNumber 桥接成 Bool（1 也会变成 true），
        // JSONSerialization 读出的 true/false 和数字都是 NSNumber，只能看它是不是 CFBoolean
        switch json {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let flag as Bool: self = .bool(flag)
        case let text as String: self = .string(text)
        default: return nil
        }
    }

    /// 能放进 JSON 和 UserDefaults 的值
    public var jsonValue: Any {
        switch self {
        case .bool(let flag): return flag
        case .number(let number): return number
        case .string(let text): return text
        }
    }

    /// 和条件里的字面量比较用的文字形式：整数不带小数点，布尔是 true / false
    public var conditionText: String {
        switch self {
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number):
            return number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .string(let text): return text
        }
    }

    /// 真假：布尔本身、数字非 0、字符串非空
    public var isTruthy: Bool {
        switch self {
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        case .string(let text): return !text.isEmpty
        }
    }
}

/// 壁纸作者在 project.json 的 general.properties 里声明的用户属性。
///
/// 字段（2026-09-28 用 ~/wp 的 60 个项目核对：场景 24、视频 29、网页 7，共 233 个属性）：
/// type（slider / bool / color / combo / textinput / group / file，没写时是一段说明文字）、text（标签，
/// 可能是 ui_ 开头的本地化键或一段 HTML）、value（默认值）、order、min / max / step / fraction（滑块，
/// fraction 为 false 时只取整数）、options（下拉选项，label + value）、condition（显示条件，例如
/// "newproperty3.value" 或 "hidemarketingwords.value==false"）。
public struct UserProperty: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case bool, slider, combo, color, textinput, group, text, file, directory, unknown
    }

    public struct Option: Equatable, Sendable {
        public let label: String
        public let value: PropertyValue
    }

    public let name: String
    public let kind: Kind
    /// 去掉 HTML、换掉已知本地化键之后的标签
    public let label: String
    public let order: Int
    public let defaultValue: PropertyValue?
    public let minimum: Double?
    public let maximum: Double?
    public let step: Double?
    /// 滑块只取整数（fraction 为 false）
    public let isInteger: Bool
    public let options: [Option]
    public let condition: String?

    public var id: String { name }

    /// 设置面板里能改的类型；file / directory 要选文件，暂不支持
    public var isEditable: Bool { [.bool, .slider, .combo, .color, .textinput].contains(kind) }

    init?(name: String, raw: [String: Any]) {
        self.name = name
        let type = raw["type"] as? String
        kind = type.map { Kind(rawValue: $0.lowercased()) ?? .unknown } ?? .text
        label = Self.plainText(raw["text"] as? String ?? name)
        order = (raw["order"] as? NSNumber)?.intValue ?? 0
        defaultValue = PropertyValue(json: raw["value"])
        minimum = (raw["min"] as? NSNumber)?.doubleValue
        maximum = (raw["max"] as? NSNumber)?.doubleValue
        step = (raw["step"] as? NSNumber)?.doubleValue
        isInteger = (raw["fraction"] as? Bool) == false
        options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option in
            guard let value = PropertyValue(json: option["value"]) else { return nil }
            return Option(label: Self.plainText(option["label"] as? String ?? value.conditionText), value: value)
        }
        condition = raw["condition"] as? String
    }

    /// 按 order 排好的全部属性
    static func parse(_ properties: [String: Any]?) -> [UserProperty] {
        (properties ?? [:]).compactMap { name, raw in (raw as? [String: Any]).flatMap { UserProperty(name: name, raw: $0) } }
            .sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    /// WE 界面自己的本地化键，常见的几个换成中文
    private static let knownLabels = [
        "ui_browse_properties_scheme_color": String(localized: "方案颜色"),
        "ui_browse_properties_alignment": String(localized: "对齐方式"),
        "ui_browse_properties_background_color": String(localized: "背景颜色"),
        "ui_browse_properties_image": String(localized: "图片"),
    ]

    /// 标签可能是一段 HTML（作者用来写说明、放链接），显示时只留文字
    static func plainText(_ text: String) -> String {
        if let known = knownLabels[text] { return known }
        var result = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 显示条件。支持真实数据里出现的写法："a.value"、"!a.value"、"a.value==x"、"a.value!=x"，
    /// 以及用 && / || 连起来的组合；认不出来的条件按"显示"处理
    public static func conditionHolds(_ condition: String?, values: [String: PropertyValue]) -> Bool {
        guard let condition = condition?.trimmingCharacters(in: .whitespaces), !condition.isEmpty else { return true }
        return condition.components(separatedBy: "||").contains { alternative in
            alternative.components(separatedBy: "&&").allSatisfy { term($0, values: values) ?? true }
        }
    }

    private static func term(_ raw: String, values: [String: PropertyValue]) -> Bool? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var negated = false
        while text.hasPrefix("!"), !text.hasPrefix("!=") {
            negated.toggle()
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for op in ["!==", "===", "!=", "=="] {
            guard let range = text.range(of: op) else { continue }
            let left = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            var literal = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            literal = literal.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            guard let value = reference(left, values: values) else { return nil }
            let equal = value.conditionText == literal
                || (Double(literal).map { number in value == .number(number) } ?? false)
            return (op.hasPrefix("!") ? !equal : equal) != negated
        }
        guard let value = reference(text, values: values) else { return nil }
        return value.isTruthy != negated
    }

    private static func reference(_ text: String, values: [String: PropertyValue]) -> PropertyValue? {
        let name = text.hasSuffix(".value") ? String(text.dropLast(6)) : text
        return values[name]
    }
}

extension WallpaperProject {
    /// 作者声明的用户属性，按 order 排好
    public var properties: [UserProperty] {
        let raw = userProperties.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return UserProperty.parse(raw)
    }

    /// 默认值加上用户改过的值
    public func propertyValues(overrides: [String: PropertyValue]) -> [String: PropertyValue] {
        var values: [String: PropertyValue] = [:]
        for property in properties { values[property.name] = property.defaultValue }
        values.merge(overrides) { $1 }
        return values
    }

    /// 默认值加用户改过的值，打包成"名字 → 值"的 JSON 对象（交给场景渲染器代入绑定、给脚本的 engine.userProperties）
    public func propertyValuesJSON(overrides: [String: PropertyValue]) -> Data? {
        let values = propertyValues(overrides: overrides).mapValues(\.jsonValue)
        return values.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: values)
    }

    /// 只含一项属性（值换成新的）的 applyUserProperties 参数，属性改动时实时推给网页壁纸
    public func userPropertyChangeJSON(name: String, value: PropertyValue) -> Data? {
        guard let raw = userProperties.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
              var property = raw[name] as? [String: Any]
        else { return nil }
        property["value"] = value.jsonValue
        return try? JSONSerialization.data(withJSONObject: [name: property])
    }

    /// 给网页壁纸的 applyUserProperties：general.properties 原样，只把用户改过的 value 换掉
    public func userPropertiesJSON(overrides: [String: PropertyValue]) -> Data? {
        guard var raw = userProperties.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
            return userProperties
        }
        for (name, value) in overrides {
            guard var property = raw[name] as? [String: Any] else { continue }
            property["value"] = value.jsonValue
            raw[name] = property
        }
        return try? JSONSerialization.data(withJSONObject: raw)
    }
}

/// 用户在设置面板里改过的属性值，按项目文件夹分开存在 UserDefaults 里
public final class UserPropertyStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "userPropertyOverrides"

    public init(defaults: UserDefaults = AppFolder.settings) {
        self.defaults = defaults
    }

    private func storageKey(_ folder: URL) -> String { folder.standardizedFileURL.path }

    public func overrides(for folder: URL) -> [String: PropertyValue] {
        let all = defaults.dictionary(forKey: key) ?? [:]
        let stored = all[storageKey(folder)] as? [String: Any] ?? [:]
        return stored.compactMapValues { PropertyValue(json: $0) }
    }

    /// value 为 nil 时恢复默认值
    public func set(_ value: PropertyValue?, for name: String, in folder: URL) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        var stored = all[storageKey(folder)] as? [String: Any] ?? [:]
        stored[name] = value?.jsonValue
        all[storageKey(folder)] = stored.isEmpty ? nil : stored
        defaults.set(all, forKey: key)
    }

    public func reset(_ folder: URL) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[storageKey(folder)] = nil
        defaults.set(all, forKey: key)
    }
}
