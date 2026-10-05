import Foundation

/// scene.pkg：Wallpaper Engine 场景项目的打包文件，里面是 scene.json、模型、材质、纹理、着色器等。
///
/// 格式（2026-09-28 用 ~/wp 里 8 个真实场景逐字节核对，见 REFERENCES.md）。整数都是小端 uint32：
///
///     [版本字符串长度][版本字符串，例如 "PKGV0020"]
///     [条目数]
///     条目 × 条目数：[名称长度][名称，UTF-8，用 / 分隔目录][偏移][大小]
///     数据区：紧跟在条目表之后，条目的偏移相对于数据区开头
///
/// 包本身不压缩也不加密。文件按内存映射打开，只在取条目内容时才真正读盘。
public struct ScenePackage: Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        /// 相对于文件开头的绝对偏移
        public let offset: Int
        public let size: Int
    }

    public let version: String
    public let entries: [Entry]
    private let data: Data

    private static let maxEntries = 100_000
    private static let maxNameLength = 4096

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        var reader = ByteReader(data)
        let versionLength = try reader.count(limit: 64, what: "版本字符串长度")
        version = try reader.string(versionLength)
        guard version.hasPrefix("PKGV") else { throw FormatError("不是 scene.pkg：开头是 \(version)") }

        let count = try reader.count(limit: Self.maxEntries, what: "条目数")
        var table: [(name: String, offset: Int, size: Int)] = []
        table.reserveCapacity(count)
        for _ in 0..<count {
            let nameLength = try reader.count(limit: Self.maxNameLength, what: "条目名称长度")
            let name = try reader.string(nameLength)
            let offset = Int(try reader.uint32())
            let size = Int(try reader.uint32())
            table.append((name, offset, size))
        }

        let dataStart = reader.offset
        entries = try table.map { item in
            let start = dataStart + item.offset
            guard start + item.size <= data.count else {
                throw FormatError("条目 \(item.name) 超出文件末尾（偏移 \(start)，大小 \(item.size)，文件 \(data.count) 字节）")
            }
            return Entry(name: item.name, offset: start, size: item.size)
        }
        self.data = data
    }

    public func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    public func contents(of entry: Entry) -> Data {
        let start = data.startIndex + entry.offset
        return data.subdata(in: start..<(start + entry.size))
    }

    public func contents(of name: String) -> Data? {
        entry(named: name).map(contents(of:))
    }
}
