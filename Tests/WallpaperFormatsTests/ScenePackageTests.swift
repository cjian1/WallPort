import Foundation
import Testing
@testable import WallpaperFormats

/// 按 ScenePackage 注释里的格式拼一个包，测试用
func makePackage(version: String = "PKGV0020", files: [(String, Data)]) -> Data {
    var header = Data()
    func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
    append(UInt32(version.utf8.count))
    header.append(contentsOf: version.utf8)
    append(UInt32(files.count))
    var offset: UInt32 = 0
    for (name, contents) in files {
        append(UInt32(name.utf8.count))
        header.append(contentsOf: name.utf8)
        append(offset)
        append(UInt32(contents.count))
        offset += UInt32(contents.count)
    }
    return files.reduce(header) { $0 + $1.1 }
}

@Suite struct ScenePackageTests {
    @Test func readsEntriesAndContents() throws {
        let package = try ScenePackage(data: makePackage(files: [
            ("scene.json", Data(#"{"objects":[]}"#.utf8)),
            ("materials/背景.tex", Data([1, 2, 3])),
        ]))
        #expect(package.version == "PKGV0020")
        #expect(package.entries.map(\.name) == ["scene.json", "materials/背景.tex"])
        #expect(package.contents(of: "scene.json") == Data(#"{"objects":[]}"#.utf8))
        #expect(package.contents(of: "materials/背景.tex") == Data([1, 2, 3]))
        #expect(package.contents(of: "missing") == nil)
    }

    @Test func emptyPackageIsValid() throws {
        #expect(try ScenePackage(data: makePackage(files: [])).entries.isEmpty)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: FormatError.self) { try ScenePackage(data: Data("PK\u{3}\u{4}zipfile".utf8)) }
        #expect(throws: FormatError.self) { try ScenePackage(data: makePackage(version: "TEXV0005", files: [])) }
    }

    @Test func rejectsTruncatedFiles() {
        let full = makePackage(files: [("scene.json", Data(repeating: 7, count: 100))])
        for length in [0, 3, 12, 30, full.count - 1] {
            #expect(throws: FormatError.self) { try ScenePackage(data: full.prefix(length)) }
        }
    }

    @Test func rejectsAbsurdCountsInsteadOfAllocating() {
        var data = makePackage(files: [])
        data.replaceSubrange((data.count - 4)..<data.count, with: [0xff, 0xff, 0xff, 0x7f])
        #expect(throws: FormatError.self) { try ScenePackage(data: data) }
    }

    @Test func worksOnDataSlices() throws {
        let package = makePackage(files: [("a", Data([9]))])
        let padded = Data([0, 0, 0]) + package
        let slice = padded[3...]
        #expect(try ScenePackage(data: slice).contents(of: "a") == Data([9]))
    }
}
