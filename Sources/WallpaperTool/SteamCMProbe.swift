import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SteamProtocol
import WallpaperLibrary

/// 探针：连上 Steam 的 CM（客户端协议）并登录，用来验证 M7.5 的协议实现。
///
///     WallpaperTool steam-cm                      # 匿名登录，不需要任何凭据
///     WallpaperTool steam-cm --framings           # 把四种信封写法都试一遍（协议还没定下来时用）
///     WallpaperTool steam-cm --token <访问令牌>    # 用 IAuthenticationService 的令牌登录
///     WallpaperTool steam-cm --cm-auth <账号> --details <编号>  # 再调 PublishedFile.GetDetails#1 读条目详情
///     WallpaperTool steam-cm --cm-auth <账号> --servers         # 再调 GetServersForSteamPipe#1 取 CDN 列表
///
/// 匿名登录成功说明"服务器列表 → WebSocket → 信封格式 → protobuf 编解码"这一整条链是对的；
/// 带令牌登录成功说明"同一次认证的令牌既能让网页订阅、也能登 CM"（也就是只需要确认一次）成立。
func steamCMProbe(_ arguments: [String]) async -> Int32 {
    var token: String?
    var account = ""
    var verboseFraming = false
    var details: [UInt64] = []
    var showServers = false
    /// 用 CM 的未登录服务调用取账号的 RSA 公钥（验证"认证会话走 CM"这条链路，不需要凭据）
    var cmAuthAccount: String?
    /// 整条认证会话都在 CM 上跑（M7.5 的关键一步：这样拿到的令牌才算"客户端会话"的令牌）
    var cmAuthLogin = false
    /// `--cm-auth -`：账号名从本机存的会话（加密文件）里取（不用打在命令行上）
    var cmAuthFromKeychain = false
    /// `--cm-auth-qr`：扫码登录（不用密码）
    var cmAuthQR = false
    /// 二维码存到哪（默认 /tmp/wallport-steam-qr.png）
    var qrPath = "/tmp/wallport-steam-qr.png"
    /// 扫码/确认最多等多久
    var waitSeconds = 300.0
    /// 拿到令牌后存到哪里（0600，只给本机排查用；不放进仓库）
    var saveTokensPath: String?
    /// 直接拿这份存下来的令牌做登录实验（不用再扫码）
    var tokenFilePath: String?
    /// 认证会话的平台 / 网站（默认按参考实现：SteamClient + "Unknown"）
    var cmPlatform: UInt32 = 1
    var cmWebsite = "Unknown"
    /// 登 CM 时把 SteamID 放进 client_supplied_steam_id
    let cmSteamID: UInt64 = 0
    /// 令牌登录的字段组合（0–3），见 CMRequest.tokenLogon
    var variant = 0
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--token":
            index += 1
            guard index < arguments.count else { print("--token 后面要跟访问令牌"); return 2 }
            token = arguments[index]
            // `--token -`：从标准输入读（令牌不进命令行，别的进程用 ps 看不到）
            if token == "-" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "--account":
            index += 1
            if index < arguments.count { account = arguments[index] }
        case "--framings":
            verboseFraming = true
        case "--details":
            index += 1
            guard index < arguments.count, let id = UInt64(arguments[index]) else {
                print("--details 后面要跟创意工坊编号"); return 2
            }
            details.append(id)
        case "--servers":
            showServers = true
        case "--cm-auth-key":
            index += 1
            if index < arguments.count {
                cmAuthAccount = arguments[index] == "-" ? "" : arguments[index]
                if arguments[index] == "-" { cmAuthFromKeychain = true }
            }
        case "--cm-auth":
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                print("--cm-auth 后面要跟 Steam 账号名"); return 2
            }
            cmAuthAccount = arguments[index] == "-" ? "" : arguments[index]
            cmAuthFromKeychain = arguments[index] == "-"
            cmAuthLogin = true
        case "--platform":
            index += 1
            guard index < arguments.count, let value = UInt32(arguments[index]) else {
                print("--platform 后面要跟平台编号（1 = SteamClient、2 = WebBrowser、3 = MobileApp）"); return 2
            }
            cmPlatform = value
        case "--website":
            index += 1
            guard index < arguments.count else { print("--website 后面要跟网站名"); return 2 }
            cmWebsite = arguments[index]
        case "--cm-auth-qr":
            cmAuthQR = true
        case "--qr":
            index += 1
            guard index < arguments.count else { print("--qr 后面要跟图片路径"); return 2 }
            qrPath = arguments[index]
        case "--wait":
            index += 1
            guard index < arguments.count, let value = Double(arguments[index]) else {
                print("--wait 后面要跟秒数"); return 2
            }
            waitSeconds = value
        case "--save-tokens":
            index += 1
            guard index < arguments.count else { print("--save-tokens 后面要跟文件路径"); return 2 }
            saveTokensPath = arguments[index]
        case "--token-file":
            index += 1
            guard index < arguments.count else { print("--token-file 后面要跟文件路径"); return 2 }
            tokenFilePath = arguments[index]
        case "--variant":
            index += 1
            if index < arguments.count { variant = Int(arguments[index]) ?? 0 }
        default:
            print("认不出的参数 \(arguments[index])")
            return 2
        }
        index += 1
    }
    if cmAuthFromKeychain {
        // 账号名从本机存的 CM 会话里取（加密文件，不碰钥匙串）
        guard let stored = SteamCMSessionStore().load()?.accountName, !stored.isEmpty else {
            print("✗ 本机还没存过 CM 会话（先跑一次 --cm-auth 或 --cm-auth-qr）")
            return 1
        }
        cmAuthAccount = stored
        if account.isEmpty { account = stored }
    }

    let servers: [URL]
    do {
        servers = try await SteamCMConnection.webSocketServers()
    } catch {
        print("✗ 取 CM 服务器列表失败：\(error.localizedDescription)")
        return 1
    }
    if cmAuthQR {
        guard let server = servers.first else { print("✗ 没有可用的 CM 服务器"); return 1 }
        let connection = SteamCMConnection()
        await connection.connect(to: server)
        let result = await cmAuthQRProbe(
            connection, servers: servers, server: server, platform: cmPlatform, website: cmWebsite,
            qrPath: qrPath, waitSeconds: waitSeconds, details: details, showServers: showServers,
            saveTokensPath: saveTokensPath)
        await connection.close()
        return result
    }
    if let tokenFilePath {
        // 复用上一次存下来的令牌做实验（省一次扫码）
        guard let server = servers.first else { print("✗ 没有可用的 CM 服务器"); return 1 }
        guard let data = FileManager.default.contents(atPath: tokenFilePath),
              let saved = try? JSONDecoder().decode(SavedTokens.self, from: data)
        else {
            print("✗ 读不到 \(tokenFilePath) 里的令牌")
            return 2
        }
        let tokens = CMAuthSession.Tokens(
            accessToken: saved.accessToken, refreshToken: saved.refreshToken, accountName: saved.accountName)
        print("用 \(tokenFilePath) 里的令牌（账号 \(tokens.accountName)）做登录实验：")
        return await cmTokenVerdict(
            server: server, tokens: tokens, details: details, showServers: showServers)
    }
    if let account = cmAuthAccount {
        guard let server = servers.first else { print("✗ 没有可用的 CM 服务器"); return 1 }
        let connection = SteamCMConnection()
        await connection.connect(to: server)
        // `--cm-auth`：整条认证会话都在 CM 上跑；`--cm-auth-key`：只取 RSA 公钥，验链路
        if cmAuthLogin {
            let result = await cmAuthLoginProbe(
                connection, servers: servers, server: server, account: account, platform: cmPlatform,
                website: cmWebsite,
                details: details, showServers: showServers)
            await connection.close()
            return result
        }
        do {
            let body = try await connection.callUnauthenticated(
                SteamServiceCall.method("Authentication.GetPasswordRSAPublicKey"),
                request: SteamServiceCall.passwordRSAPublicKey(accountName: account))
            print("✓ 未登录服务调用成功：账号 \(account) 的 RSA 模长 \((body.string(1) ?? "").count * 4) 位，"
                + "指数 \(body.string(2) ?? "?")，时间戳存在 \(body.varint(3) != nil)")
        } catch {
            print("✗ 未登录服务调用失败：\(error.localizedDescription)")
        }
        await connection.close()
        return 0
    }
    let hosts = servers.prefix(3).map { $0.host ?? "?" }
    print("CM 服务器 \(servers.count) 个，先试 \(hosts.joined(separator: "、"))")

    // 信封的写法还没定下来：四种组合各试一遍（服务器也换着试），哪条通就记在哪
    let framings = verboseFraming ? CMEnvelope.Framing.allCases : [.plain]
    for framing in framings {
        for server in servers.prefix(3) {
            let connection = SteamCMConnection()
            await connection.connect(to: server)
            let started = Date()
            do {
                let result = try await connection.logOn(
                    accessToken: token, accountName: account, steamID: cmSteamID, framing: framing,
                    sendAccountName: variant == 0,
                    timeout: .seconds(8))
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                let types = await connection.seenMessageTypes()
                print("✓ \(framing.describe)：\(server.host ?? "?") 用时 \(seconds) 秒，结果 \(result.describe)"
                    + "，SteamID \(result.steamID)，心跳 \(result.heartbeatSeconds) 秒，cell \(result.cellID)"
                    + (result.vanityURL.map { "，vanity \($0)" } ?? ""))
                print("   收到过的消息编号：\(types.map(String.init).joined(separator: "、"))")
                if !details.isEmpty { await printDetails(connection, ids: details) }
                if showServers { await printContentServers(connection, cellID: result.cellID) }
                await connection.close()
                return result.isOK ? 0 : 1
            } catch {
                print("✗ \(framing.describe) @ \(server.host ?? "?"): \(error.localizedDescription)")
                let events = await connection.connectionEvents()
                if !events.isEmpty { print("   连接事件：\(events.joined(separator: "；"))") }
                await connection.close()
            }
        }
    }
    return 1
}

/// 整条认证会话走 CM：取 RSA 公钥 → BeginAuthSessionViaCredentials → （要验证码就提交）→ 轮询拿令牌
/// → **用这枚令牌登 CM**，这就是"一次确认覆盖两边"能不能成立的关键一步。
///
/// 密码从标准输入读（终端里不回显；也可以从管道喂）。令牌只打印长度，不打印内容。
private func cmAuthLoginProbe(
    _ connection: SteamCMConnection, servers: [URL], server: URL, account: String, platform: UInt32,
    website: String, details: [UInt64], showServers: Bool
) async -> Int32 {
    var connection = connection
    print("在 CM 上开认证会话：账号 \(account)，platform_type \(platform)，website_id \"\(website)\"")
    let key: (modulus: String, exponent: String, timestamp: UInt64)
    do {
        key = try await connection.passwordRSAPublicKey(accountName: account)
        print("   ① 拿到 RSA 公钥（模数 \(key.modulus.count * 4) 位，时间戳 \(key.timestamp)）")
    } catch {
        print("   ✗ 取 RSA 公钥失败：\(error.localizedDescription)")
        return 1
    }

    guard let password = promptSecret("   Steam 密码（不回显）："), !password.isEmpty else {
        print("✗ 没有读到密码")
        return 2
    }
    let encrypted: String
    do {
        encrypted = try SteamRSA.encrypt(
            password: password, modulusHex: key.modulus, exponentHex: key.exponent)
    } catch {
        print("   ✗ 加密密码失败：\(error.localizedDescription)")
        return 1
    }

    var pending: CMAuthSession.Pending
    do {
        pending = try await connection.beginAuthSession(
            accountName: account, encryptedPassword: encrypted, timestamp: key.timestamp,
            platformType: platform, websiteID: website, machineID: CMRequest.machineID())
        print("   ② 会话开始了：client_id \(pending.clientID)，steamid \(pending.steamID)，"
            + "轮询间隔 \(String(format: "%.1f", pending.interval)) 秒，"
            + "确认方式 \(pending.guards.map(\.describe).joined(separator: "、"))")
    } catch {
        print("   ✗ 开始会话失败：\(error.localizedDescription)")
        return 1
    }

    if let codeGuard = pending.guards.first(where: \.needsCode) {
        guard let code = promptLine("   ③ 请输入\(codeGuard.describe)：")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty
        else {
            print("✗ 没有读到验证码")
            return 2
        }
        do {
            try await connection.submitGuardCode(code, type: codeGuard.type, to: pending)
            print("   ③ 验证码已提交")
        } catch {
            print("   ✗ 提交验证码失败：\(error.localizedDescription)")
            return 1
        }
    } else if let confirmation = pending.guards.first(where: \.isConfirmation) {
        print("   ③ 请\(confirmation.describe)：Steam 手机 App → 确认 → 这次登录")
    }

    let deadline = ContinuousClock.now + .seconds(180)
    var tokens: CMAuthSession.Tokens?
    while ContinuousClock.now < deadline {
        do {
            tokens = try await connection.pollAuthSession(&pending)
        } catch {
            // 同扫码那条：没登录的连接会被回收，重连接着轮询
            await connection.close()
            try? await Task.sleep(for: .seconds(2))
            connection = await connectForAuth(servers: servers, preferring: server, account: account)
            continue
        }
        if tokens != nil { break }
        try? await Task.sleep(for: .seconds(max(2, pending.interval)))
    }
    guard let tokens else {
        print("   ✗ 等令牌超时（手机上确认了吗？）")
        return 1
    }
    print("   ④ 拿到令牌：账号 \(tokens.accountName)，访问令牌 \(tokens.accessToken.count) 个字符，"
        + "refresh_token \(tokens.refreshToken.map { "\($0.count) 个字符" } ?? "没有")")

    // 关键一步：这枚令牌能不能登 CM（能的话，"一次确认覆盖订阅 + 下载"就成立了）
    let verdict = await cmTokenVerdict(
        server: server, tokens: tokens, details: details, showServers: showServers)
    print(verdict == 0
        ? "✓ 这条会话的令牌能登 CM：一次确认覆盖订阅、列表、下载（M7.5 的关键一步成立）"
        : "✗ 两枚令牌都被 CM 拒了：还要继续查（把这两行输出贴回来）")
    return verdict
}

/// 扫码登录：CM 上开一个 QR 会话，把 `challenge_url` 画成二维码等人扫，然后轮询到令牌，
/// 最后用令牌试登 CM。**不用密码、不用钥匙串**——手机上确认那一下就够。
private func cmAuthQRProbe(
    _ connection: SteamCMConnection, servers: [URL], server: URL, platform: UInt32, website: String,
    qrPath: String, waitSeconds: Double, details: [UInt64], showServers: Bool, saveTokensPath: String? = nil
) async -> Int32 {
    // 后台跑（nohup + 重定向）时 stdout 会带缓冲，进度和地址就看不到了：这一条命令关掉缓冲
    setvbuf(stdout, nil, _IONBF, 0)
    print("在 CM 上开扫码会话：platform_type \(platform)，website_id \"\(website)\"")
    var pending: CMAuthSession.Pending
    do {
        let (started, url) = try await connection.beginAuthSessionViaQR(
            platformType: platform, websiteID: website)
        pending = started
        print("   ① 会话开始了：client_id \(pending.clientID)，轮询间隔 "
            + "\(String(format: "%.1f", pending.interval)) 秒")
        print("   ② 二维码地址：\(url)")
        if writeQRCode(url, to: qrPath) {
            print("   ③ 二维码图片写到 \(qrPath)：用手机的 Steam App → 扫码 → 确认这次登录")
        } else {
            print("   ✗ 二维码图片没写出来（地址在上面，也可以自己生成二维码）")
        }
    } catch {
        print("   ✗ 开扫码会话失败：\(error.localizedDescription)")
        return 1
    }

    var connection = connection
    let deadline = ContinuousClock.now + .seconds(waitSeconds)
    var tokens: CMAuthSession.Tokens?
    var said = false
    var reconnects = 0
    while ContinuousClock.now < deadline {
        do {
            tokens = try await connection.pollAuthSession(&pending)
        } catch {
            // 没登录的 CM 连接会被回收（实测 ~1 分钟），而会话是按 client_id/request_id 走的、
            // 不绑连接：重连接着轮询就行
            reconnects += 1
            guard reconnects <= 20 else {
                print("   ✗ 轮询失败（重连 \(reconnects) 次都是通的但拉不到）：\(error.localizedDescription)")
                return 1
            }
            if reconnects == 1 { print("   … 连接被 CM 收回了（\(error.localizedDescription)），重连接着等") }
            await connection.close()
            try? await Task.sleep(for: .seconds(2))
            connection = await connectForAuth(servers: servers, preferring: server, account: pending.accountName)
            continue
        }
        if tokens != nil { break }
        if !said {
            said = true
            print("   … 等你扫码确认（最多 \(Int(waitSeconds)) 秒）")
        }
        try? await Task.sleep(for: .seconds(max(2, pending.interval)))
    }
    guard let tokens else {
        print("   ✗ 等确认超时")
        return 1
    }
    print("   ④ 确认成功：账号 \(tokens.accountName)，访问令牌 \(tokens.accessToken.count) 个字符，"
        + "refresh_token \(tokens.refreshToken.map { "\($0.count) 个字符" } ?? "没有")")
    saveTokens(tokens, to: saveTokensPath)
    // 先在这条**同一个连接**上试一次：CM 有可能把认证会话和连接绑在一起
    if let refresh = tokens.refreshToken {
        do {
            let result = try await connection.logOn(
                accessToken: refresh, accountName: tokens.accountName,
                steamID: SteamJWT.steamID(refresh) ?? 0,
                machineID: CMRequest.machineID(accountName: tokens.accountName), timeout: .seconds(15))
            print("   \(result.isOK ? "✓" : "✗") 在认证会话那条连接上直接登 CM：\(result.describe)"
                + "，SteamID \(result.steamID)")
        } catch {
            print("   ✗ 在认证会话那条连接上直接登 CM：\(error.localizedDescription)")
        }
    }
    let verdict = await cmTokenVerdict(
        server: server, tokens: tokens, details: details, showServers: showServers)
    print(verdict == 0
        ? "✓ 扫码这一路拿到的令牌能登 CM：一次确认覆盖订阅、列表、下载"
        : "✗ 两枚令牌都被 CM 拒了：把上面两行贴回来")
    return verdict
}

/// 重新连一台 CM（认证会话不绑连接，断线重连后接着轮询就行）
private func connectForAuth(
    servers: [URL], preferring preferred: URL?, account: String
) async -> SteamCMConnection {
    let candidates = ([preferred].compactMap { $0 } + servers).prefix(4)
    for server in candidates {
        let connection = SteamCMConnection()
        await connection.connect(to: server)
        return connection
    }
    return SteamCMConnection()
}

/// 拿到的令牌能不能登 CM：`refresh_token` 和 `access_token` 各试一遍（公开实现里 CM 的
/// `access_token` 字段填的是 refresh token，所以两种都试）
private func cmTokenVerdict(
    server: URL, tokens: CMAuthSession.Tokens, details: [UInt64], showServers: Bool
) async -> Int32 {
    // 先看清令牌自报的身份：CM 只认 iss = steam、aud 含 client 的 refresh token
    if let refresh = tokens.refreshToken { print("   refresh_token：\(SteamJWT.describe(refresh))") }
    print("   access_token ：\(SteamJWT.describe(tokens.accessToken))")

    // 一枚枚令牌试：不带 account_name（参考实现的规定）、SteamID 用 token 的 sub，
    // machine_id 三种形态都试（不带 / 老写法 / 参考实现那种按账号名算的结构化值）
    var candidates: [(String, String)] = []
    if let refresh = tokens.refreshToken { candidates.append(("refresh_token", refresh)) }
    candidates.append(("access_token", tokens.accessToken))
    for (label, token) in candidates {
        let tokenSteamID = SteamJWT.steamID(token) ?? 0
        let shapes: [(String, [UInt8]?, Bool)] = [
            ("machine_id 不带", nil, false),
            ("machine_id 参考实现", CMRequest.machineID(accountName: tokens.accountName), true),
            ("machine_id 老写法", CMRequest.machineID(), true),
        ]
        for (shape, machineID, includeMachineID) in shapes {
            let probe = SteamCMConnection()
            await probe.connect(to: server)
            do {
                let result = try await probe.logOn(
                    accessToken: token, accountName: tokens.accountName, steamID: tokenSteamID,
                    includeMachineID: includeMachineID, machineID: machineID, timeout: .seconds(15))
                print("   \(result.isOK ? "✓" : "✗") \(label) + \(shape)：\(result.describe)"
                    + "，SteamID \(result.steamID)，cell \(result.cellID)"
                    + (result.eresultExtended == 0 ? "" : "，扩展错误码 \(result.eresultExtended)"))
                if result.isOK {
                    if !details.isEmpty { await printDetails(probe, ids: details) }
                    if showServers { await printContentServers(probe, cellID: result.cellID) }
                    await probe.close()
                    return 0
                }
            } catch {
                print("   ✗ \(label) + \(shape)：\(error.localizedDescription)")
            }
            await probe.close()
        }
    }
    return 1
}

/// 把一段文字画成二维码存成 PNG（手机上扫）
private func writeQRCode(_ text: String, to path: String) -> Bool {
    guard let data = SteamLoginQRCode.imageData(for: text, scale: 12) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
}

/// 提示并读一行（验证码用，允许回显）
private func promptLine(_ prompt: String) -> String? {
    FileHandle.standardError.write(Data(prompt.utf8))
    return Swift.readLine()
}

/// 读一行秘密（关掉回显；标准输入不是终端时按普通行读，方便管道喂）
private func promptSecret(_ prompt: String) -> String? {
    FileHandle.standardError.write(Data(prompt.utf8))
    guard isatty(0) == 1 else { return Swift.readLine() }
    var original = termios()
    guard tcgetattr(0, &original) == 0 else { return Swift.readLine() }
    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(0, TCSAFLUSH, &hidden)
    let line = Swift.readLine()
    tcsetattr(0, TCSAFLUSH, &original)
    FileHandle.standardError.write(Data("\n".utf8))
    return line
}

/// 存下来的令牌（只给本机排查用，文件权限 0600）
private struct SavedTokens: Codable {
    let accountName: String
    let accessToken: String
    let refreshToken: String?
}

private func saveTokens(_ tokens: CMAuthSession.Tokens, to path: String?) {
    guard let path else { return }
    let value = SavedTokens(
        accountName: tokens.accountName, accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
    guard let data = try? JSONEncoder().encode(value) else { return }
    FileManager.default.createFile(
        atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    print("   （令牌存到 \(path)，权限 0600；用完了删掉）")
}

/// `PublishedFile.GetDetails#1`：条目详情。和网页接口 `GetPublishedFileDetails` 的结果对照着看
private func printDetails(_ connection: SteamCMConnection, ids: [UInt64]) async {
    do {
        let body = try await connection.call(
            SteamServiceCall.method("PublishedFile.GetDetails"),
            request: SteamServiceCall.publishedFileDetails(ids: ids, appID: 431_960),
            timeout: .seconds(15))
        let items = body.values(1).compactMap { value -> PublishedFileInfo? in
            guard case .bytes(let data) = value, let message = try? ProtoMessage(data) else { return nil }
            return PublishedFileInfo(message)
        }
        for item in items {
            print("   条目 \(item.id)：\(item.title)"
                + "，大小 \(ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file))"
                + "，内容句柄 \(item.contentHandle)，result \(item.result)"
                + (item.tags.isEmpty ? "" : "，标签 \(item.tags.joined(separator: "/"))"))
        }
        if items.isEmpty { print("   条目详情是空的（回包体 \(body.fieldNumbers)）") }
    } catch {
        print("   ✗ 取条目详情失败：\(error.localizedDescription)")
    }
}

/// `ContentServerDirectory.GetServersForSteamPipe#1`：下载要用的内容服务器
private func printContentServers(_ connection: SteamCMConnection, cellID: UInt32) async {
    do {
        let body = try await connection.call(
            SteamServiceCall.method("ContentServerDirectory.GetServersForSteamPipe"),
            request: SteamServiceCall.contentServers(cellID: cellID), timeout: .seconds(15))
        let servers = SteamContentServer.list(from: body)
        let usable = servers.filter(\.supportsHTTPS)
        print("   内容服务器 \(servers.count) 个（能走 HTTPS 的 \(usable.count) 个）："
            + usable.prefix(4).map { "\($0.type) \($0.host)" }.joined(separator: "、"))
    } catch {
        print("   ✗ 取内容服务器失败：\(error.localizedDescription)")
    }
}
