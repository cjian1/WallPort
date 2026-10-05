import Foundation
import Testing

/// 英文界面的两份对照表：键要一样，翻译里的格式符（%@ %lld …）要和原文一一对应——
/// 少一个、多一个或者类型不对，String(format:) 会读错参数甚至崩溃。
/// 缺不缺翻译要靠编译器导出键才知道，见 scripts/check-localization.sh
@Suite struct LocalizationTests {
    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App")

    private func table(_ language: String) throws -> [String: String] {
        let url = Self.app.appendingPathComponent("\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private func specifiers(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[a-zA-Z@%]"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]) }
            .sorted()
    }

    @Test func englishAndChineseCoverTheSameKeys() throws {
        let english = try table("en")
        let chinese = try table("zh-Hans")
        #expect(!english.isEmpty)
        #expect(Set(english.keys) == Set(chinese.keys))
        // 中文那份是原文对原文
        #expect(chinese.allSatisfy { $0.key == $0.value })
    }

    @Test func translationsKeepTheFormatSpecifiers() throws {
        for (key, value) in try table("en") {
            #expect(specifiers(key) == specifiers(value), "\(key) → \(value)")
        }
    }
}
