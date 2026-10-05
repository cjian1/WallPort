import Foundation

/// Steam 的应用信息（PICS，Product Info / Change System）：一个应用有哪些 depot、每个 depot 公开分支的清单编号。
///
/// 下载 Wallpaper Engine 自带素材要用：素材在 WE 安装包里（`assets/` 文件夹），安装包由 depot 组成，
/// depot 的最新清单编号写在应用信息里。流程和 Steam 客户端一样：
///
/// 1. `CMsgClientPICSAccessTokenRequest`（EMsg 8905）要这个应用的访问令牌（付费应用要它才给完整信息）；
/// 2. `CMsgClientPICSProductInfoRequest`（EMsg 8903）带上令牌要应用信息，回 `…Response`（8904）；
/// 3. 信息是文本格式的 KeyValues（`"appinfo" { "depots" { "<编号>" { "manifests" { "public" … } } } }`）；
///    太大时回包里没有内容，只给一台 HTTP 服务器，到 `https://<主机>/appinfo/<应用>/sha/<sha>.txt.gz` 去取。
///
/// 消息字段号见 Valve 随客户端发布的 `steammessages_clientserver_appinfo.proto`
public struct SteamAppInfo: Sendable, Equatable {
    public struct Depot: Sendable, Equatable {
        public let id: UInt32
        /// `config/oslist`（"windows"、"macos,linux"……）；空表示不分系统
        public let osList: [String]
        /// 公开分支（public）的清单编号；没有（工具、只在测试分支里的 depot）时为 nil
        public let publicManifest: UInt64?
        /// 内容其实来自别的应用（共享的运行库之类）
        public let fromOtherApp: Bool

        public init(id: UInt32, osList: [String], publicManifest: UInt64?, fromOtherApp: Bool = false) {
            self.id = id
            self.osList = osList
            self.publicManifest = publicManifest
            self.fromOtherApp = fromOtherApp
        }
    }

    public let appID: UInt32
    public let depots: [Depot]

    public init(appID: UInt32, depots: [Depot]) {
        self.appID = appID
        self.depots = depots
    }

    /// 从文本 KeyValues 读出 depot 列表。清单编号有两种写法：
    /// 新的 `"public" { "gid" "123" "size" … }`，老的 `"public" "123"`
    public init(appID: UInt32, keyValues root: KeyValues) {
        self.appID = appID
        let info = root.name.lowercased() == "appinfo" ? root : (root["appinfo"] ?? root)
        var depots: [Depot] = []
        for depot in info["depots"]?.children ?? [] {
            guard let id = UInt32(depot.name) else { continue }   // "branches""baselanguages" 这种不是 depot
            let public_ = depot["manifests"]?["public"]
            let manifest = (public_?["gid"]?.value ?? public_?.value).flatMap { UInt64($0) }
            let osList = (depot["config"]?["oslist"]?.value ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            depots.append(Depot(
                id: id, osList: osList, publicManifest: manifest, fromOtherApp: depot["depotfromapp"] != nil))
        }
        self.depots = depots.sorted { $0.id < $1.id }
    }
}

/// 文本格式的 KeyValues（Valve 的 VDF）：`"键" "值"` 或 `"键" { … }`，可以嵌套；键不区分大小写。
/// 支持 `//` 注释、不带引号的词、`\"` `\\` `\n` `\t` 转义，平台条件（`[$WIN32]`）忽略
public struct KeyValues: Sendable, Equatable {
    public let name: String
    /// 叶子的值；有子项时为 nil
    public let value: String?
    public let children: [KeyValues]

    public init(name: String, value: String? = nil, children: [KeyValues] = []) {
        self.name = name
        self.value = value
        self.children = children
    }

    /// 按名字（不区分大小写）取第一个子项
    public subscript(_ key: String) -> KeyValues? {
        let lowered = key.lowercased()
        return children.first { $0.name.lowercased() == lowered }
    }

    /// 解析一段文本；顶层通常只有一个键（`"appinfo" { … }`）。格式不对时抛错
    public static func parse(_ text: String) throws -> KeyValues {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let items = try parser.items(topLevel: true)
        guard let first = items.first else { throw SteamCMError("KeyValues 是空的") }
        return items.count == 1 ? first : KeyValues(name: "", children: items)
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0

        mutating func items(topLevel: Bool) throws -> [KeyValues] {
            var result: [KeyValues] = []
            while true {
                guard let token = try nextToken() else {
                    if topLevel { return result }
                    throw SteamCMError("KeyValues 少了 }")
                }
                switch token {
                case .close:
                    if topLevel { throw SteamCMError("KeyValues 多了 }") }
                    return result
                case .open:
                    throw SteamCMError("KeyValues 里 { 前面没有键")
                case .text(let key):
                    guard let next = try nextToken() else { throw SteamCMError("KeyValues 的键 \(key) 后面没有值") }
                    switch next {
                    case .open: result.append(KeyValues(name: key, children: try items(topLevel: false)))
                    case .text(let value): result.append(KeyValues(name: key, value: value))
                    case .close: throw SteamCMError("KeyValues 的键 \(key) 后面直接是 }")
                    }
                }
            }
        }

        enum Token { case open, close, text(String) }

        mutating func nextToken() throws -> Token? {
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                    continue
                }
                if scalar.properties.isWhitespace || scalar == "\0" { index += 1; continue }
                if scalar == "[" {   // 平台条件：[$WIN32] 之类，跳过
                    while index < scalars.count, scalars[index] != "]" { index += 1 }
                    index += 1
                    continue
                }
                if scalar == "{" { index += 1; return .open }
                if scalar == "}" { index += 1; return .close }
                if scalar == "\"" { return .text(try quoted()) }
                var word = String.UnicodeScalarView()
                while index < scalars.count {
                    let next = scalars[index]
                    if next.properties.isWhitespace || next == "{" || next == "}" || next == "\"" { break }
                    word.append(next)
                    index += 1
                }
                return .text(String(word))
            }
            return nil
        }

        mutating func quoted() throws -> String {
            index += 1
            var text = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                if scalar == "\"" { return String(text) }
                if scalar == "\\", index < scalars.count {
                    let escaped = scalars[index]
                    index += 1
                    switch escaped {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    default: text.append(escaped)
                    }
                    continue
                }
                text.append(scalar)
            }
            throw SteamCMError("KeyValues 的引号没有结束")
        }
    }
}

extension CMRequest {
    /// `CMsgClientPICSAccessTokenRequest`：要应用的访问令牌（appids 是字段 2）
    public static func picsAccessToken(appID: UInt32) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(2, varint: UInt64(appID))
        return body
    }

    /// `CMsgClientPICSProductInfoRequest`：要应用信息（apps 是字段 2：appid + access_token），
    /// `single_response`（字段 7）让 Steam 一次回完
    public static func picsProductInfo(appID: UInt32, accessToken: UInt64) -> ProtoWriter {
        var app = ProtoWriter()
        app.field(1, varint: UInt64(appID))
        if accessToken != 0 { app.field(2, varint: accessToken) }
        var body = ProtoWriter()
        body.field(2, message: app)
        body.field(7, bool: true)
        return body
    }
}

/// PICS 回包的解析（拆出来好测）
public enum PICSResponse {
    /// `CMsgClientPICSAccessTokenResponse` 里这个应用的令牌（`app_access_tokens` 是字段 3）；被拒或没有时是 0
    public static func accessToken(_ body: ProtoMessage, appID: UInt32) -> UInt64 {
        for value in body.values(3) {
            guard case .bytes(let data) = value, let token = try? ProtoMessage(data),
                  UInt32(truncatingIfNeeded: token.varint(1) ?? 0) == appID
            else { continue }
            return token.varint(2) ?? 0
        }
        return 0
    }

    /// `CMsgClientPICSProductInfoResponse` 里这个应用的信息：要么直接带着文本（`buffer`，字段 5），
    /// 要么只给 sha（字段 4）和一台 HTTP 服务器（`http_host`，字段 8），要另外去取
    public enum AppData: Equatable {
        case inline(String)
        case http(URL)
    }

    public static func appData(_ body: ProtoMessage, appID: UInt32) throws -> AppData {
        for value in body.values(1) {
            guard case .bytes(let data) = value, let app = try? ProtoMessage(data),
                  UInt32(truncatingIfNeeded: app.varint(1) ?? 0) == appID
            else { continue }
            if let buffer = app.bytes(5), !buffer.isEmpty {
                return .inline(String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self))
            }
            if let sha = app.bytes(4), !sha.isEmpty, let host = body.string(8), !host.isEmpty {
                let hex = sha.map { String(format: "%02x", $0) }.joined()
                guard let url = URL(string: "https://\(host)/appinfo/\(appID)/sha/\(hex).txt.gz") else { break }
                return .http(url)
            }
            if app.bool(3) == true { throw SteamCMError("Steam 没给应用 \(appID) 的完整信息（缺访问令牌）") }
            break
        }
        let unknown = body.values(2).contains { if case .varint(let id) = $0 { return id == UInt64(appID) } else { return false } }
        throw SteamCMError(unknown ? "Steam 说没有应用 \(appID)" : "回包里没有应用 \(appID) 的信息")
    }
}

extension SteamCMConnection {
    /// 读一个应用的信息（depot 列表、公开分支的清单编号）。要先登录；付费应用要账号拥有它才有完整信息
    public func appInfo(appID: UInt32, session: URLSession = .shared) async throws -> SteamAppInfo {
        let tokens = try await send(
            .clientPICSAccessTokenRequest, body: CMRequest.picsAccessToken(appID: appID),
            expecting: .clientPICSAccessTokenResponse)
        let token = PICSResponse.accessToken(tokens, appID: appID)
        let response = try await send(
            .clientPICSProductInfoRequest, body: CMRequest.picsProductInfo(appID: appID, accessToken: token),
            expecting: .clientPICSProductInfoResponse)
        let text: String
        switch try PICSResponse.appData(response, appID: appID) {
        case .inline(let inline):
            text = inline
        case .http(let url):
            let (data, reply) = try await session.data(from: url)
            guard (reply as? HTTPURLResponse)?.statusCode == 200 else {
                throw SteamCMError("取应用信息失败（HTTP \((reply as? HTTPURLResponse)?.statusCode ?? 0)）")
            }
            let bytes = [UInt8](data)
            let plain = bytes.starts(with: [0x1f, 0x8b]) ? try Gzip.decompress(bytes) : bytes
            text = String(decoding: plain.prefix { $0 != 0 }, as: UTF8.self)
        }
        return SteamAppInfo(appID: appID, keyValues: try KeyValues.parse(text))
    }
}
