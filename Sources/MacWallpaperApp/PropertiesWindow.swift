import AppKit
import SwiftUI
import WallpaperFormats
import WallpaperLibrary

/// 壁纸设置：列出作者在 project.json 里声明的用户属性，改动立即交给 onChange 存下并生效。
/// 显示在壁纸库窗口的右侧栏里（点一张壁纸就能调，不用再单独开窗口）。
/// 属性按 group 分节；带 condition 的属性按其它属性的当前值显隐。
/// 场景壁纸在作者的设置后面还有"显示内容"：自动列出的粒子、文字 / 时钟、特效，每项一个开关（见 SceneElements）。
/// 最前面是壁坞自己加的播放选项：有声音的壁纸可以单独静音、调音量；比例和屏幕不同的可以选完整显示或铺满时看哪一部分
struct PropertiesView: View {
    let project: WallpaperProject
    @State var values: [String: PropertyValue]
    /// 场景里可以单独关掉的内容
    var elements: [SceneElement] = []
    /// 已经关掉的内容（元素的 id）
    @State var hidden: Set<String> = []
    /// 这个壁纸自己的播放选项
    @State var options = WallpaperOptions()
    /// 播放选项要显示哪些（有没有声音、铺满会不会裁）
    var playback = PlaybackOptionsContext()
    /// 某一项改了（nil 表示恢复成默认值）；参数是属性名和新值
    let onChange: (String, PropertyValue?) -> Void
    /// 某项内容关掉（true）或重新打开（false）
    var onElementChange: (String, Bool) -> Void = { _, _ in }
    /// 播放选项改了
    var onOptionsChange: (WallpaperOptions) -> Void = { _ in }
    /// 全部恢复默认
    let onReset: () -> Void

    private struct Section: Identifiable {
        let id: String
        let title: String?
        let properties: [UserProperty]
    }

    private var sections: [Section] {
        var result: [Section] = []
        var title: String?
        var id = "top"
        var current: [UserProperty] = []
        for property in project.properties {
            if property.kind == .group {
                if !current.isEmpty || title != nil { result.append(Section(id: id, title: title, properties: current)) }
                title = property.label
                id = property.name
                current = []
            } else {
                current.append(property)
            }
        }
        if !current.isEmpty || title != nil { result.append(Section(id: id, title: title, properties: current)) }
        return result
    }

    var body: some View {
        Form {
            PlaybackOptionsSections(options: $options, context: playback)
            if !project.properties.contains(where: \.isEditable) && elements.isEmpty && !playback.showsAnything {
                Text("这个壁纸没有可以调整的设置。").foregroundStyle(.secondary)
            }
            ForEach(sections) { section in
                SwiftUI.Section(section.title ?? "") {
                    ForEach(section.properties.filter(isShown)) { property in
                        row(property)
                    }
                }
            }
            ForEach(SceneElement.Kind.allCases, id: \.self) { kind in
                let items = elements.filter { $0.kind == kind }
                if !items.isEmpty {
                    SwiftUI.Section {
                        ForEach(items) { element in
                            Toggle(element.count > 1 ? "\(element.title) ×\(element.count)" : element.title, isOn: Binding(
                                get: { !hidden.contains(element.id) },
                                set: { shown in setElement(element.id, hidden: !shown) }))
                        }
                    } header: {
                        Text("显示内容 · \(kind.title)")
                    } footer: {
                        if kind == SceneElement.Kind.allCases.last(where: { k in elements.contains { $0.kind == k } }) {
                            Text("按壁纸内容自动列出，关掉的就不画。作者自己的设置里有同样的开关时，两边任一关掉都不显示。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("恢复默认") {
                    values = project.propertyValues(overrides: [:])
                    hidden = []
                    options = WallpaperOptions()
                    onReset()
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 280, minHeight: 200)
        .onChange(of: options) { _, new in onOptionsChange(new) }
    }

    /// 满足显示条件；只剩图片、链接的说明文字（去掉 HTML 后是空的）不占一行
    private func isShown(_ property: UserProperty) -> Bool {
        guard UserProperty.conditionHolds(property.condition, values: values) else { return false }
        return !(property.kind == .text && property.label.isEmpty)
    }

    @ViewBuilder
    private func row(_ property: UserProperty) -> some View {
        switch property.kind {
        case .bool:
            Toggle(property.label, isOn: Binding(
                get: { values[property.name]?.isTruthy ?? false },
                set: { update(property, .bool($0)) }))
        case .slider:
            let minimum = property.minimum ?? 0
            let maximum = max(property.maximum ?? 1, minimum + 0.0001)
            let current = number(values[property.name]) ?? minimum
            // 侧栏比较窄：名字单独一行，滑块和数值在下面一行，长名字也放得下
            VStack(alignment: .leading, spacing: 4) {
                Text(property.label)
                HStack {
                    Slider(
                        value: Binding(get: { current }, set: { update(property, .number(rounded($0, property))) }),
                        in: minimum...maximum)
                    Text(format(current, property)).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                }
            }
        case .combo:
            Picker(property.label, selection: Binding(
                get: { property.options.firstIndex { $0.value == values[property.name] } ?? 0 },
                set: { index in
                    guard property.options.indices.contains(index) else { return }
                    update(property, property.options[index].value)
                })) {
                ForEach(Array(property.options.enumerated()), id: \.offset) { index, option in
                    Text(option.label).tag(index)
                }
            }
        case .color:
            ColorPicker(property.label, selection: Binding(
                get: { Self.color(values[property.name]) },
                set: { update(property, .string(Self.text($0))) }),
                supportsOpacity: false)
        case .textinput:
            LabeledContent(property.label) {
                TextField("", text: Binding(
                    get: { values[property.name]?.conditionText ?? "" },
                    set: { update(property, .string($0)) }))
            }
        case .text:
            Text(property.label).font(.footnote).foregroundStyle(.secondary)
        case .file, .directory, .unknown, .group:
            LabeledContent(property.label) { Text("暂不支持").foregroundStyle(.secondary) }
        }
    }

    private func setElement(_ id: String, hidden isHidden: Bool) {
        guard hidden.contains(id) != isHidden else { return }
        if isHidden { hidden.insert(id) } else { hidden.remove(id) }
        onElementChange(id, isHidden)
    }

    private func update(_ property: UserProperty, _ value: PropertyValue) {
        guard values[property.name] != value else { return }
        values[property.name] = value
        onChange(property.name, value == property.defaultValue ? nil : value)
    }

    private func number(_ value: PropertyValue?) -> Double? {
        switch value {
        case .number(let number): return number
        case .string(let text): return Double(text)
        case .bool(let flag): return flag ? 1 : 0
        case nil: return nil
        }
    }

    /// 按 step 取整；fraction 为 false 时只取整数
    private func rounded(_ value: Double, _ property: UserProperty) -> Double {
        if property.isInteger { return value.rounded() }
        if let step = property.step, step > 0 { return (value / step).rounded() * step }
        return (value * 1000).rounded() / 1000
    }

    private func format(_ value: Double, _ property: UserProperty) -> String {
        property.isInteger ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }

    /// "r g b"（0–1）↔ SwiftUI 的颜色（sRGB）
    static func color(_ value: PropertyValue?) -> Color {
        let parts = (value?.conditionText ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard parts.count >= 3 else { return .white }
        return Color(.sRGB, red: parts[0], green: parts[1], blue: parts[2])
    }

    static func text(_ color: Color) -> String {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "%.5f %.5f %.5f", converted.redComponent, converted.greenComponent, converted.blueComponent)
    }
}

/// 播放选项要显示哪些：有没有声音、菜单栏的总开关、铺满会裁掉多少
struct PlaybackOptionsContext {
    var hasAudio = false
    var playsAudio = true
    var crop: LibraryModel.Crop?
    var onEnableAudio: () -> Void = {}

    var showsAnything: Bool { hasAudio || crop != nil }
}

/// 壁坞自己加的两节：声音（这个壁纸静音 / 音量）、显示（铺满或完整显示、铺满时看哪一部分）
struct PlaybackOptionsSections: View {
    @Binding var options: WallpaperOptions
    let context: PlaybackOptionsContext

    var body: some View {
        if context.hasAudio {
            Section {
                Toggle("播放声音", isOn: Binding(get: { !options.isMuted }, set: { options.isMuted = !$0 }))
                VStack(alignment: .leading, spacing: 4) {
                    Text("音量")
                    HStack {
                        Slider(value: $options.volume, in: 0...1)
                        Text("\(Int((options.volume * 100).rounded()))%")
                            .monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                    }
                }
                .disabled(options.isMuted)
            } header: {
                Text("声音")
            } footer: {
                if !context.playsAudio {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("菜单栏里的“播放壁纸声音”关着，所有壁纸都不出声。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("打开壁纸声音", action: context.onEnableAudio).controlSize(.small)
                    }
                }
            }
        }
        if let crop = context.crop {
            Section {
                Picker("显示方式", selection: $options.fitsWhole) {
                    Text("铺满屏幕").tag(false)
                    Text("完整显示").tag(true)
                }
                if !options.fitsWhole {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(crop.axis == .vertical ? "上下位置" : "左右位置")
                        Slider(value: $options.position, in: 0...1) {
                            Text(crop.axis == .vertical ? "上下位置" : "左右位置")
                        } minimumValueLabel: {
                            Text(crop.axis == .vertical ? "上" : "左").foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text(crop.axis == .vertical ? "下" : "右").foregroundStyle(.secondary)
                        }
                        .labelsHidden()
                    }
                }
            } header: {
                Text("显示")
            } footer: {
                Text(options.fitsWhole
                    ? "整张壁纸都在屏幕上，比例不同的方向两边留黑边。"
                    : "壁纸和屏幕的比例不同，铺满时只看得到约 \(Int((crop.visible * 100).rounded()))%，用上面的滑块选看哪一部分。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
