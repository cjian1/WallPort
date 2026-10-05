import Foundation

/// CM 上的认证会话（`Authentication.*` 一族服务方法）。
///
/// 和 Steam 社区网页那套认证（走 HTTPS 的 WebApiTransport，M7 用过、现在已删）做的是同一件事，
/// 区别是**整条会话都在 CM 上**：请求发 `ServiceMethodCallFromClientNonAuthed`（EMsg 9804），方法名放头部的
/// `target_job_name`——2026-09-29 已经在本机验证这条路通（`WallpaperTool steam-cm --cm-auth-key <账号>` 能拿到
/// RSA 公钥），所以剩下的只是把三个消息拼对。
///
/// 为什么要走 CM：参考实现（MIT 许可的 node-steam-session，`src/transports/WebSocketCMTransport.ts`、
/// `src/LoginSession.ts`）里 **SteamClient 平台的会话默认就用 CM 传输**，而且它的
/// `AuthenticationClient._getPlatformData()` 给 SteamClient 发的是 `website_id = "Unknown"` +
/// `device_details.platform_type = SteamClient`（带 machine_id）。我们的网页登录是用 HTTPS 拿的客户端
/// 令牌，被 CM 拒（EResult 5）；这条路就是按参考实现改成"会话本身也走 CM"。
///
/// 字段号来自 Valve 随客户端发布的 `steam/steammessages_auth.steamclient.proto`。
public enum CMAuthSession {
    /// Steam Guard 的确认方式（EAuthSessionGuardType）
    public struct Guard: Sendable, Equatable {
        public let type: Int
        public let message: String

        /// 手机上点一下就行，不用输验证码
        public var isConfirmation: Bool { type == 4 || type == 5 || type == 6 }
        /// 要用户把验证码填回来（邮件 / 手机令牌）
        public var needsCode: Bool { type == 2 || type == 3 }

        public var describe: String {
            switch type {
            case 2: "邮件验证码"
            case 3: "手机令牌验证码"
            case 4: "手机 App 上确认"
            case 5: "邮件里点确认"
            case 6: "这台机器的令牌"
            default: "方式 \(type)"
            }
        }
    }

    /// 开始登录之后、还没拿到令牌时的会话状态
    public struct Pending: Sendable, Equatable {
        public var clientID: UInt64
        /// `request_id` 在协议里是 bytes（网页接口那边给的是十六进制字符串）
        public var requestID: [UInt8]
        public var steamID: UInt64
        /// 轮询间隔（秒）
        public var interval: Double
        public var guards: [Guard]
        public var accountName: String
        /// 扫码登录的二维码地址。Steam 会在轮询回包里给新的（`new_challenge_url`），界面要跟着换图
        public var challengeURL: String?
    }

    /// 登录成功后的令牌
    public struct Tokens: Sendable, Equatable {
        /// 登 CM 用的访问令牌
        public let accessToken: String
        /// 长期令牌（约 200 天），以后换新的访问令牌用
        public let refreshToken: String?
        public let accountName: String

        public init(accessToken: String, refreshToken: String?, accountName: String) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.accountName = accountName
        }
    }

    // MARK: - 请求

    /// `Authentication.GetPasswordRSAPublicKey#1`（未登录就能调）
    public static func passwordRSAPublicKeyRequest(accountName: String) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, string: accountName)
        return body
    }

    /// `Authentication.BeginAuthSessionViaCredentials#1`
    ///
    /// - Parameters:
    ///   - platformType: `EAuthTokenPlatformType`（1 = SteamClient、2 = WebBrowser、3 = MobileApp）
    ///   - websiteID: SteamClient 会话按参考实现填 `"Unknown"`
    ///   - machineID: Steam 客户端那套 `"BB3" + SHA-1(...)`（只有客户端平台要带）
    public static func beginAuthSessionRequest(
        accountName: String, encryptedPassword: String, timestamp: UInt64,
        platformType: UInt32 = 1, websiteID: String = "Unknown", deviceName: String = "WallPort (Mac)",
        machineID: [UInt8]? = nil, osType: Int32 = 16, persist: Bool = true
    ) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, string: deviceName)                 // device_friendly_name
        body.field(2, string: accountName)                // account_name
        body.field(3, string: encryptedPassword)          // encrypted_password
        body.field(4, varint: timestamp)                  // encryption_timestamp
        body.field(5, bool: persist)                      // remember_login
        body.field(6, varint: UInt64(platformType))       // platform_type
        body.field(7, varint: persist ? 1 : 0)            // persistence：1 = 长期
        body.field(8, string: websiteID)                  // website_id
        var device = ProtoWriter()
        device.field(1, string: deviceName)               // device_friendly_name
        device.field(2, varint: UInt64(platformType))     // platform_type
        device.field(3, int32: osType)                    // os_type
        device.field(4, varint: 1)                        // gaming_device_type：1 = 桌面
        if let machineID { device.field(6, bytes: machineID) }
        body.field(9, message: device)                    // device_details
        return body
    }

    /// `Authentication.UpdateAuthSessionWithSteamGuardCode#1`
    public static func guardCodeRequest(
        clientID: UInt64, steamID: UInt64, code: String, codeType: Int
    ) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, varint: clientID)
        body.field(2, fixed64: steamID)
        body.field(3, string: code)
        body.field(4, varint: UInt64(codeType))
        return body
    }

    /// `Authentication.PollAuthSessionStatus#1`
    public static func pollRequest(clientID: UInt64, requestID: [UInt8]) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, varint: clientID)
        body.field(2, bytes: requestID)
        return body
    }

    /// `Authentication.BeginAuthSessionViaQR#1`：手机扫码确认，**不用输密码**
    /// （Steam 客户端"用手机扫码登录"就是这条）
    public static func qrAuthSessionRequest(
        platformType: UInt32 = 1, websiteID: String = "Unknown", deviceName: String = "WallPort (Mac)"
    ) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, string: deviceName)                 // device_friendly_name
        body.field(2, varint: UInt64(platformType))       // platform_type
        var device = ProtoWriter()
        device.field(1, string: deviceName)
        device.field(2, varint: UInt64(platformType))
        device.field(3, int32: 16)                        // os_type：macOS 10.15+
        device.field(4, varint: 1)                        // gaming_device_type：桌面
        body.field(3, message: device)                    // device_details
        body.field(4, string: websiteID)                  // website_id
        return body
    }

    // MARK: - 回包

    /// `GetPasswordRSAPublicKey` 的回包
    public static func publicKey(from body: ProtoMessage) -> (modulus: String, exponent: String, timestamp: UInt64)? {
        guard let modulus = body.string(1), let exponent = body.string(2) else { return nil }
        return (modulus, exponent, body.varint(3) ?? 0)
    }

    /// `BeginAuthSessionViaCredentials` 的回包
    public static func pending(from body: ProtoMessage, accountName: String) -> Pending? {
        guard let clientID = body.varint(1), let requestID = body.bytes(2) else { return nil }
        let guards = body.values(4).compactMap { value -> Guard? in
            guard case .bytes(let data) = value, let message = try? ProtoMessage(data),
                  let type = message.varint(1)
            else { return nil }
            return Guard(type: Int(type), message: message.string(2) ?? "")
        }
        // steamid（字段 5）在 .proto 里是 `uint64`（varint）；只有提交验证码的请求里才是 fixed64
        return Pending(
            clientID: clientID, requestID: requestID, steamID: body.varint(5) ?? 0,
            interval: (body.fixed32(3).map { Double(Float(bitPattern: $0)) }) ?? 5,
            guards: guards, accountName: accountName)
    }

    /// `PollAuthSessionStatus` 的回包：还没好返回 nil（手机上还没点、验证码还没交）
    public static func tokens(from body: ProtoMessage, accountName: String) -> Tokens? {
        guard let access = body.string(4), !access.isEmpty else { return nil }
        return Tokens(
            accessToken: access, refreshToken: body.string(3),
            accountName: body.string(6) ?? accountName)
    }

    /// 轮询回包里的新 client_id（Steam 每轮会换一个，要跟着走）
    public static func newClientID(from body: ProtoMessage) -> UInt64? {
        body.varint(1)
    }

    /// 轮询回包里的新二维码地址（`new_challenge_url` = 2）：扫码会话的码会过期换新
    public static func newChallengeURL(from body: ProtoMessage) -> String? {
        guard let url = body.string(2), !url.isEmpty else { return nil }
        return url
    }

    /// `BeginAuthSessionViaQR` 的回包：会话状态 + 要生成二维码的 `challenge_url`
    public static func qrPending(from body: ProtoMessage) -> (pending: Pending, challengeURL: String)? {
        guard let clientID = body.varint(1), let url = body.string(2), let requestID = body.bytes(3) else {
            return nil
        }
        let guards = body.values(5).compactMap { value -> Guard? in
            guard case .bytes(let data) = value, let message = try? ProtoMessage(data),
                  let type = message.varint(1)
            else { return nil }
            return Guard(type: Int(type), message: message.string(2) ?? "")
        }
        return (Pending(
            clientID: clientID, requestID: requestID, steamID: 0,
            interval: (body.fixed32(4).map { Double(Float(bitPattern: $0)) }) ?? 5,
            guards: guards, accountName: "", challengeURL: url), url)
    }
}
