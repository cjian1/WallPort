import Foundation
import CryptoKit

/// Steam 客户端协议（CM）用到的消息编号。取值来自 Valve 随客户端发布的 `.proto` 与公开的
/// EMsg 对照表（见 REFERENCES.md）
public enum EMsg: UInt32, Sendable {
    case multi = 1
    case serviceMethodResponse = 147
    /// 登录后按 `CMsgClientLogonResponse.heartbeat_seconds` 定时发，不发 CM 会把连接当成掉线回收
    case clientHeartBeat = 703
    case serviceMethodCallFromClient = 151
    case clientLogOnResponse = 751
    case clientLoggedOff = 757
    case clientLogon = 5514
    /// 取 depot 解密密钥（内容服务器上的分块要用它解密）
    case clientGetDepotDecryptionKey = 5438
    case clientGetDepotDecryptionKeyResponse = 5439
    /// 应用信息（PICS）：先要访问令牌，再带着令牌要应用信息（depot 和清单编号，见 `SteamAppInfo`）
    case clientPICSProductInfoRequest = 8903
    case clientPICSProductInfoResponse = 8904
    case clientPICSAccessTokenRequest = 8905
    case clientPICSAccessTokenResponse = 8906
    /// 还没登录时调服务方法（认证会话就是这么做的）
    case serviceMethodCallFromClientNonAuthed = 9804
    /// 连上 CM 之后要先打个招呼，否则后面发的东西会被当成"没有凭据"
    case clientHello = 9805
}

public struct SteamCMError: Error, LocalizedError, Equatable {
    public let message: String
    /// Steam 明确回了一个失败结果码（服务方法头部的 `eresult`、登录回应等）
    public let eresult: Int32?
    /// 连接断了、被下线或等回包超时：换一条连接重试可能就好（和"Steam 明确拒绝"区分开）
    public let isConnectionLoss: Bool

    public init(_ message: String, eresult: Int32? = nil, connectionLoss: Bool = false) {
        self.message = message
        self.eresult = eresult
        self.isConnectionLoss = connectionLoss
    }

    public var errorDescription: String? { message }
}

/// 消息信封：`[EMsg 4 字节小端][头部长度 4 字节小端][CMsgProtoBufHeader][消息体]`。
///
/// TCP 传输在最外面还包一层 `[长度][magic "VT01"]`（加密之后才有），WebSocket 传输直接把信封
/// 当作一个二进制帧发出去。2026-09-29 用匿名登录在本机验证过（见 `WallpaperTool steam-cm`）。
public enum CMEnvelope {
    /// 组装信封时的两种可选写法（2026-09-29 用匿名登录逐个试出来的，见 `WallpaperTool steam-cm`）：
    /// - `protobufBit`：消息号带 0x80000000（老协议里区分"体是 protobuf"的标志）
    /// - `vt01Wrapper`：外面再包一层 TCP 传输用的 `[长度][magic "VT01"]`
    public struct Framing: Sendable, Equatable, CaseIterable {
        public var protobufBit: Bool
        public var vt01Wrapper: Bool

        public init(protobufBit: Bool, vt01Wrapper: Bool) {
            self.protobufBit = protobufBit
            self.vt01Wrapper = vt01Wrapper
        }

        /// 本机实测通过的写法：消息号带 protobuf 位，外面不再包 VT01
        public static let plain = Framing(protobufBit: true, vt01Wrapper: false)
        public static let withoutProtobufBit = Framing(protobufBit: false, vt01Wrapper: false)
        public static let withProtobufBit = Framing(protobufBit: true, vt01Wrapper: false)
        public static let withVT01 = Framing(protobufBit: false, vt01Wrapper: true)
        public static let withBoth = Framing(protobufBit: true, vt01Wrapper: true)
        public static let allCases: [Framing] = [.withProtobufBit, .withoutProtobufBit, .withVT01, .withBoth]

        public var describe: String {
            (protobufBit ? "消息号带 protobuf 位" : "消息号原样") + (vt01Wrapper ? " + VT01 包装" : "")
        }
    }

    public static func encode(
        _ type: EMsg, header: ProtoWriter, body: ProtoWriter, framing: Framing = .plain
    ) -> [UInt8] {
        var envelope: [UInt8] = []
        let type = framing.protobufBit ? type.rawValue | 0x8000_0000 : type.rawValue
        append(type, to: &envelope)
        append(UInt32(header.bytes.count), to: &envelope)
        envelope += header.bytes
        envelope += body.bytes
        guard framing.vt01Wrapper else { return envelope }
        var out: [UInt8] = []
        append(UInt32(envelope.count), to: &out)
        out += Array("VT01".utf8)
        out += envelope
        return out
    }

    public struct Decoded: Sendable {
        public let type: EMsg?
        public let rawType: UInt32
        public let header: ProtoMessage
        public let body: ProtoMessage
        public let bodyBytes: [UInt8]
    }

    /// 解开 `CMsgMulti`（EMsg 1）：CM 会把好几条消息（可能 gzip 压过）打包成一条发过来。
    /// 2026-09-29 实测：**未登录的服务调用（EMsg 9804）的回包就是这么回来的**——之前看着像"没回应"，
    /// 其实是裹在 Multi 里没拆（`receivedTypes` 里只有一个 1）。
    ///
    /// 载荷是若干 `[长度 4 字节小端][完整消息信封]` 串起来的（字段号见 `steammessages_base.proto`
    /// 的 `CMsgMulti`：`size_unzipped` = 1、`message_body` = 2）
    public static func multiMessages(_ body: [UInt8]) -> [[UInt8]] {
        guard let message = try? ProtoMessage(body), let raw = message.bytes(2) else { return [] }
        var candidates: [[UInt8]] = []
        if (message.varint(1) ?? 0) != 0, let unzipped = try? Gzip.decompress(raw) {
            candidates.append(unzipped)
        }
        candidates.append(raw)
        for payload in candidates {
            let messages = splitEnvelopes(payload)
            // 切出来的每一段都得是能解开的信封，否则宁可当作"拆不出来"（别把压缩数据当消息用）
            if !messages.isEmpty, messages.allSatisfy({ (try? CMEnvelope.decode($0)) != nil }) {
                return messages
            }
        }
        return []
    }

    /// 把 `[长度 4 字节小端][信封]` 串起来的一段载荷切成若干条消息
    private static func splitEnvelopes(_ payload: [UInt8]) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        var offset = 0
        while offset + 4 <= payload.count {
            let size = Int(UInt32(payload[offset]) | UInt32(payload[offset + 1]) << 8
                | UInt32(payload[offset + 2]) << 16 | UInt32(payload[offset + 3]) << 24)
            offset += 4
            if size == 0 { continue }                       // 空段（跳过，不算错）
            guard offset + size <= payload.count else { break }
            messages.append(Array(payload[offset..<(offset + size)]))
            offset += size
        }
        return messages
    }

    /// 拆包失败时给一句能看懂的诊断（`deliver` 里用）
    static func describeMulti(_ body: [UInt8]) -> String {
        guard let message = try? ProtoMessage(body), let raw = message.bytes(2) else {
            return "不是 CMsgMulti（\(body.count) 字节）"
        }
        let unzipped = Int(message.varint(1) ?? 0)
        var text = "CMsgMulti：body \(raw.count) 字节，size_unzipped \(unzipped)"
        var payload = raw
        if unzipped != 0 {
            if let inflated = try? Gzip.decompress(raw) {
                text += "，解压后 \(inflated.count) 字节"
                payload = inflated
            } else {
                text += "，gzip 解压失败"
            }
        }
        let messages = splitEnvelopes(payload)
        text += "，切出 \(messages.count) 段"
        for (index, message) in messages.enumerated() where (try? CMEnvelope.decode(message)) == nil {
            let head = message.prefix(4).map { String(format: "%02x", $0) }.joined()
            text += "；第 \(index + 1) 段解不开（\(message.count) 字节，head \(head)）"
            break
        }
        return text
    }

    public static func decode(_ data: [UInt8]) throws -> Decoded {
        // TCP 那层包装（如果对端也这么发）要去掉
        var data = data
        if data.count >= 8, Array(data[4..<8]) == Array("VT01".utf8) {
            let length = Int(UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24)
            if 8 + length <= data.count { data = Array(data[8..<8 + length]) }
        }
        guard data.count >= 8 else { throw SteamCMError("消息太短（\(data.count) 字节）") }
        let raw = UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
        let rawType = raw & 0x7fff_ffff
        let headerLength = Int(UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24)
        guard 8 + headerLength <= data.count else {
            // 老式的**非 protobuf** 消息（`CMsgMulti` 里会混着它们）：头部布局不一样——
            // [消息号 4][头部长 1 字节 = 36][版本 2][目标 job 8][来源 job 8][canary 1][steamid 8][session 4]。
            // 这种消息我们不认（type = nil），交给调用方跳过；不能当成坏的 protobuf 消息报错——
            // 一条 Multi 里只要有这么一段，整条就全丢了（2026-09-29 实测：751 就在那条 Multi 里）。
            if data.count >= 5, data[4] == 36 {
                return Decoded(
                    type: nil, rawType: rawType, header: ProtoMessage(),
                    body: ProtoMessage(), bodyBytes: Array(data[min(40, data.count)...]))
            }
            throw SteamCMError("头部长得超出消息")
        }
        let header = try ProtoMessage(Array(data[8..<8 + headerLength]))
        let bodyBytes = Array(data[(8 + headerLength)...])
        return Decoded(
            type: EMsg(rawValue: rawType), rawType: rawType, header: header,
            body: (try? ProtoMessage(bodyBytes)) ?? ProtoMessage(), bodyBytes: bodyBytes)
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((value >> UInt32(shift)) & 0xff)) }
    }
}

/// 登录成功后的结果（`CMsgClientLogonResponse` 里我们用得到的字段）
public struct CMLogOnResult: Sendable {
    public let eresult: Int32
    /// 更细的错误码（`eresult_extended`，字段 10）
    public let eresultExtended: Int32
    public let heartbeatSeconds: Int32
    public let steamID: UInt64
    public let cellID: UInt32
    public let vanityURL: String?

    public var isOK: Bool { eresult == 1 }

    /// EResult 里常见的几个翻成中文，其余原样给编号
    public var describe: String {
        switch eresult {
        case 1: String(localized: "成功")
        case 2: String(localized: "失败（EResult 2）")
        case 3: String(localized: "没有登录")
        case 5: String(localized: "账号或密码不对")
        case 63: String(localized: "需要 Steam Guard 验证码")
        case 65: String(localized: "验证码不对")
        case 84: String(localized: "登录太频繁，Steam 暂时拒绝")
        case 88: String(localized: "需要两步验证码")
        default: String(localized: "失败（EResult \(eresult)）")
        }
    }
}

/// 我们发出去的消息体（从 Valve 的 `.proto` 手写编码，字段号见注释）
public enum CMRequest {
    /// 当前客户端协议版本。Steam 会按它决定支持哪些消息
    public static let protocolVersion: UInt32 = 65580

    /// `CMsgClientLogon`：匿名登录（SteamCMD 的 `+login anonymous` 走的就是这个）
    public static func anonymousLogon() -> ProtoWriter {
        logon(accountName: "anonymous")
    }

    /// `CMsgClientLogon` 的公共部分
    private static func logon(accountName: String?) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, varint: UInt64(protocolVersion))       // protocol_version
        body.field(6, string: "english")                     // client_language
        // account_name：匿名登录写 "anonymous"（Steam 自己的约定），令牌登录写真实账号名
        if let accountName, !accountName.isEmpty { body.field(50, string: accountName) }
        return body
    }

    /// `CMsgClientGetDepotDecryptionKey`（EMsg 5438）：要某个 depot 的解密密钥。
    /// 这是客户端消息，不是统一服务方法；字段号见 Valve 的
    /// `steammessages_clientserver_2.proto`
    public static func depotDecryptionKey(appID: UInt32, depotID: UInt32) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, varint: UInt64(depotID))
        body.field(2, varint: UInt64(appID))
        return body
    }

    /// `CMsgClientHello`：连上 CM 之后的第一条消息（协议版本）
    public static func clientHello() -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, varint: UInt64(protocolVersion))
        return body
    }

    /// `CMsgClientLogon`：用 IAuthenticationService 会话登录。**注意 `access_token` 字段要填的是
    /// refresh token**（公开实现 steam-user 就是这么做的：它还会先校验 `iss == "steam"`、
    /// `aud` 里含 `client`、`sub` 是 SteamID），不是 access token —— 2026-09-29 用错这一项时
    /// CM 一律以 EResult 5（账号或密码不对）拒绝。
    ///
    /// 两个容易踩的点（都按 steam-user 的做法）：
    /// - `sendAccountName` 默认 **false**：带令牌登录时不能再带 `account_name`，steam-user 里明文规定
    ///   "Cannot specify account_name when logging in with a refresh token"；
    /// - `steamID`（token 的 `sub`）要放进 `client_supplied_steam_id`。
    public static func tokenLogon(
        accessToken: String, accountName: String = "", steamID: UInt64 = 0,
        sendAccountName: Bool = false, sendMachineName: Bool = true,
        includeMachineID: Bool = true, machineID: [UInt8]? = nil
    ) -> ProtoWriter {
        var body = logon(accountName: sendAccountName ? accountName : nil)
        body.field(108, string: accessToken)                 // access_token
        body.field(8, bool: true)                            // should_remember_password：让 CM 缓存凭据
        if steamID != 0 { body.field(22, fixed64: steamID) } // client_supplied_steam_id
        // 下面这几个是公开实现（steam-user）一定会带的：本机 IP（混淆过的私网地址）、
        // 客户端系统类型（16 = macOS 10.15+，Steam 的 EOSType）、限流回应开关、聊天模式
        var privateIP = ProtoWriter()
        privateIP.field(1, fixed32: 0)                       // CMsgIPAddress.v4
        body.field(11, message: privateIP)                   // obfuscated_private_ip
        body.field(7, varint: 16)                            // client_os_type
        body.field(102, bool: true)                          // supports_rate_limit_response
        body.field(33, varint: 2)                            // chat_mode
        if sendMachineName, !accountName.isEmpty {
            body.field(96, string: "WallPort (Mac)")         // machine_name
            body.field(97, string: "WallPort (Mac)")         // machine_name_userchosen
        }
        // machine_id：非匿名登录一律要带（参考实现里 `_getMachineID` 就是这个条件）
        if includeMachineID {
            body.field(30, bytes: machineID ?? Self.machineID(accountName: accountName))
        }
        return body
    }

    /// machine_id：按**字节**放进消息（不是字符串字段）。有账号名时照公开实现
    /// node-steam-session 的 `createMachineId(accountName)` 拼：
    ///
    ///     [0]["MessageObject" 0][1]["BB3" 0][SHA1("SteamUser Hash BB3 <账号名>") 0]
    ///                         [1]["FF2" 0][SHA-1(...)] [1]["3B3" 0][SHA-1(...)] [8][8]
    ///
    /// 不知道账号名（匿名登录）时退回 "BB3" + SHA-1(机器名 + 用户名)。
    public static func machineID(accountName: String? = nil) -> [UInt8] {
        guard let accountName, !accountName.isEmpty else {
            let text = ProcessInfo.processInfo.hostName + NSUserName()
            let digest = Insecure.SHA1.hash(data: Data(text.utf8))
            return Array(("BB3" + digest.map { String(format: "%02x", $0) }.joined()).utf8)
        }
        var out: [UInt8] = [0]
        out += Array("MessageObject".utf8) + [0]
        for prefix in ["BB3", "FF2", "3B3"] {
            out.append(1)
            out += Array(prefix.utf8) + [0]
            let digest = Insecure.SHA1.hash(data: Data("SteamUser Hash \(prefix) \(accountName)".utf8))
            out += Array(digest.map { String(format: "%02x", $0) }.joined().utf8) + [0]
        }
        out += [8, 8]
        return out
    }

    /// 登录类消息（ClientHello / ClientLogon）用的**极简头部**：只有 steamid 和 client_sessionid，
    /// 两个都是 0。公开实现（node-steam-session 的 WebSocketCMTransport）就是这么发的，
    /// 多写 jobid_source / seq_num 会被 CM 拒（2026-09-29 实测）
    public static func header(jobID: UInt64, steamID: UInt64 = 0) -> ProtoWriter {
        var header = ProtoWriter()
        header.field(1, fixed64: steamID)                    // steamid（登录前是 0）
        header.field(2, int32: 0)                            // client_sessionid = 0
        return header
    }

    /// 调服务方法用的头部：`target_job_name` 写 "服务.方法#版本"（例如 `PublishedFile.GetDetails#1`），
    /// 回包的头部里 `jobid_target` 会等于这里的 `jobid_source`
    public static func serviceHeader(jobID: UInt64, method: String, steamID: UInt64 = 0) -> ProtoWriter {
        var header = ProtoWriter()
        if steamID != 0 { header.field(1, fixed64: steamID) }  // steamid
        header.field(12, string: method)                      // target_job_name
        header.field(10, fixed64: jobID)                      // jobid_source
        header.field(32, varint: 1)                           // realm
        return header
    }
}

/// CM 上"服务方法"的调用与回包（EMsg 151 / 147），订阅、条目详情、内容服务器、depot 密钥都走它。
///
/// 这是把 Steam 的各种能力接进来的统一入口：客户端把请求 protobuf 放在消息体里、
/// 方法名放在头部的 `target_job_name`，服务端用同一条通道回结果。
public enum SteamServiceCall {
    /// `PublishedFile.GetDetails#1`：按编号取条目详情（订阅数、标题、内容句柄…）
    public static func publishedFileDetails(ids: [UInt64], appID: UInt32, includeTags: Bool = true) -> ProtoWriter {
        var body = ProtoWriter()
        for id in ids { body.field(1, fixed64: id) }   // publishedfileids（repeated fixed64）
        if includeTags { body.field(2, bool: true) }   // includetags
        body.field(14, varint: UInt64(appID))          // appid
        return body
    }

    /// `ContentServerDirectory.GetServersForSteamPipe#1`：拿内容服务器（CDN）列表
    public static func contentServers(cellID: UInt32 = 0, maxServers: UInt32 = 20) -> ProtoWriter {
        var body = ProtoWriter()
        if cellID != 0 { body.field(1, varint: UInt64(cellID)) }   // cell_id
        body.field(2, varint: UInt64(maxServers))                  // max_servers
        return body
    }

    /// `ContentServerDirectory.GetManifestRequestCode#1`：清单地址里那段请求码（不带它取清单是 401）。
    /// 字段号见 Valve 的 `steammessages_contentsystem.steamclient.proto`
    public static func manifestRequestCode(
        appID: UInt32, depotID: UInt32, manifestID: UInt64, branch: String = "public"
    ) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, varint: UInt64(appID))          // app_id
        body.field(2, varint: UInt64(depotID))        // depot_id
        body.field(3, varint: manifestID)             // manifest_id
        body.field(4, string: branch)                 // app_branch
        return body
    }

    /// 统一消息的方法名写法：`服务.方法#版本`
    public static func method(_ name: String, version: Int = 1) -> String { "\(name)#\(version)" }

    /// `Authentication.GetPasswordRSAPublicKey#1`：认证会话的第一步（不需要凭据就能调，
    /// 用来验证"未登录状态下的服务调用"这条链路）
    public static func passwordRSAPublicKey(accountName: String) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, string: accountName)
        return body
    }
}

/// 条目详情里我们关心的字段（`PublishedFileDetails`，见 Valve 的 `.proto`）
public struct PublishedFileInfo: Sendable {
    public let id: UInt64
    public let result: UInt32
    public let title: String
    public let fileSize: UInt64
    /// 预览图地址（字段 11）
    public let previewURL: String?
    /// 订阅数 / 收藏数（字段 36 / 37）
    public let subscriptions: UInt32
    public let favorited: UInt32
    /// 内容句柄：普通单文件条目是 UGC 文件编号，带清单的条目（WE 的都是）就是清单编号
    public let contentHandle: UInt64
    public let timeUpdated: UInt32
    /// 当前账号订阅它的时间（`time_subscribed` = 56；"我的订阅"列表里才有）
    public let timeSubscribed: UInt32
    public let tags: [String]

    public init?(_ message: ProtoMessage) {
        // 字段号见 Valve 的 steammessages_publishedfile.steamclient.proto 里的 PublishedFileDetails
        guard let id = message.varint(2) else { return nil }   // publishedfileid
        self.id = id
        result = UInt32(truncatingIfNeeded: message.varint(1) ?? 0)   // result
        title = message.string(16) ?? ""                              // title
        fileSize = message.varint(8) ?? 0                             // file_size
        previewURL = message.string(11)                               // preview_url
        subscriptions = UInt32(truncatingIfNeeded: message.varint(36) ?? 0)  // subscriptions
        favorited = UInt32(truncatingIfNeeded: message.varint(37) ?? 0)      // favorited
        contentHandle = message.fixed64(14) ?? 0                      // hcontent_file
        timeUpdated = UInt32(truncatingIfNeeded: message.varint(20) ?? 0)  // time_updated
        timeSubscribed = UInt32(truncatingIfNeeded: message.varint(56) ?? 0)  // time_subscribed
        tags = message.values(52).compactMap { value -> String? in    // tags[].tag
            guard case .bytes(let data) = value else { return nil }
            return (try? ProtoMessage(data))?.string(1)
        }
    }
}
