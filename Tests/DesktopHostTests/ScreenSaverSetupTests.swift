import Foundation
import Testing
@testable import DesktopHost

/// 屏保装到 ~/Library/Screen Savers 的那份是拷贝：装、换、"没装过就不动"都在临时文件夹里试
@MainActor
@Suite struct ScreenSaverSetupTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScreenSaverSetupTests-\(UUID().uuidString)", isDirectory: true)

    /// 假的 .saver：Contents/MacOS/WallPort 里写上 `version`
    private func makeSaver(_ name: String, version: String) throws -> URL {
        let saver = root.appendingPathComponent(name, isDirectory: true)
        let macOS = saver.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data(version.utf8).write(to: macOS.appendingPathComponent("WallPort"))
        return saver
    }

    private func version(at saver: URL) throws -> String {
        try String(contentsOf: saver.appendingPathComponent("Contents/MacOS/WallPort"), encoding: .utf8)
    }

    @Test func installCopiesAndReplaces() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Library/Screen Savers/WallPort.saver", isDirectory: true)
        try ScreenSaverSetup.install(from: try makeSaver("v1.saver", version: "1"), to: destination)
        #expect(try version(at: destination) == "1")

        try ScreenSaverSetup.install(from: try makeSaver("v2.saver", version: "2"), to: destination)
        #expect(try version(at: destination) == "2")
        // 换的时候用的临时拷贝不留下
        let left = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        #expect(left == ["WallPort.saver"])
    }

    /// App 更新以后：装过的跟着换；一样的不动；没装过的不替用户装
    @Test func updateOnlyTouchesAnOutdatedInstall() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Screen Savers/WallPort.saver", isDirectory: true)
        let v1 = try makeSaver("v1.saver", version: "1")
        let v2 = try makeSaver("v2.saver", version: "2")

        #expect(try !ScreenSaverSetup.updateIfInstalled(from: v1, to: destination))
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        try ScreenSaverSetup.install(from: v1, to: destination)
        #expect(try !ScreenSaverSetup.updateIfInstalled(from: v1, to: destination))
        #expect(try ScreenSaverSetup.updateIfInstalled(from: v2, to: destination))
        #expect(try version(at: destination) == "2")
    }

    @Test func recognisesOurModuleByName() {
        #expect(ScreenSaverSetup.isSelected(modulePath: "/Users/me/Library/Screen Savers/WallPort.saver"))
        #expect(!ScreenSaverSetup.isSelected(modulePath: "/System/Library/ExtensionKit/Extensions/Ventura.appex"))
        #expect(!ScreenSaverSetup.isSelected(modulePath: nil))
    }
}
