import Foundation
import SteamProtocol
import WallpaperLibrary

/// 不靠 SteamCMD 的创意工坊下载：一次认证（扫码或已存的令牌）→ 登 CM → 条目详情 → depot 密钥 →
/// 清单请求码 → 从 CDN 取清单 → 下载分块 → 拼成文件。
///
///     # 扫码登录（手机确认），然后下这一件
///     WallpaperTool steam-workshop 3807008481 /tmp/out --qr /tmp/qr.png
///
///     # 复用已经存下来的令牌
///     WallpaperTool steam-workshop 3807008481 /tmp/out --token-file /tmp/wallport-tokens.json
///
///     # 只看"我的订阅"（不改账号状态）
///     WallpaperTool steam-workshop --list --token-file /tmp/wallport-tokens.json
///
/// 订阅 / 取消订阅需要 `--subscribe` / `--unsubscribe`：会真的改 Steam 账号上的订阅，默认不做。
func steamWorkshopProbe(_ arguments: [String]) async -> Int32 {
    var itemID: UInt64?
    var outputPath: String?
    var tokenPath: String?
    var saveTokensPath: String?
    var useQR = false
    var qrPath = "/tmp/wallport-steam-qr.png"
    var account: String?
    var listOnly = false
    var printAllIDs = false
    var listType: UInt32?
    var subscribe: Bool?
    var appID: UInt32 = 431_960
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--token-file":
            index += 1
            if index < arguments.count { tokenPath = arguments[index] }
        case "--save-tokens":
            index += 1
            if index < arguments.count { saveTokensPath = arguments[index] }
        case "--qr":
            useQR = true
            index += 1
            if index < arguments.count, !arguments[index].hasPrefix("--") { qrPath = arguments[index] }
            else { index -= 1 }
        case "--account":
            index += 1
            if index < arguments.count { account = arguments[index] }
        case "--list":
            listOnly = true
        case "--ids":
            // 和 --list 一起用：把全部订阅编号一行一个打出来（排查"取消订阅后还在不在"）
            listOnly = true
            printAllIDs = true
        case "--subscribe":
            subscribe = true
        case "--unsubscribe":
            subscribe = false
        case "--list-type":
            index += 1
            if index < arguments.count, let value = UInt32(arguments[index]) { listType = value }
        case "--appid":
            index += 1
            if index < arguments.count, let value = UInt32(arguments[index]) { appID = value }
        default:
            if arguments[index].hasPrefix("--") { print("认不出的参数 \(arguments[index])"); return 2 }
            if let value = UInt64(arguments[index]), itemID == nil { itemID = value }
            else if outputPath == nil { outputPath = arguments[index] }
            else { print("多出来的参数 \(arguments[index])"); return 2 }
        }
        index += 1
    }

    guard listOnly || subscribe != nil || (itemID != nil && outputPath != nil) else {
        print("""
            用法：
              WallpaperTool steam-workshop <创意工坊编号> <输出目录> (--token-file <文件> | --qr [图片])
              WallpaperTool steam-workshop --list (--token-file <文件> | --qr)
              WallpaperTool steam-workshop <编号> --subscribe|--unsubscribe (--token-file <文件> | --qr)
            """)
        return 2
    }

    // 1. 连一台能用的 CM 并登进去（账号密码或扫码都行）
    let servers: [URL]
    do { servers = try await SteamCMConnection.webSocketServers() } catch {
        print("✗ 取 CM 服务器列表失败：\(error.localizedDescription)"); return 1
    }
    guard let session = await workshopLogOn(
        servers: servers, tokenPath: tokenPath, saveTokensPath: saveTokensPath, useQR: useQR,
        qrPath: qrPath, account: account)
    else { return 1 }
    let connection = session.connection
    print("✓ 登 CM：账号 \(session.tokens.accountName)，SteamID \(session.steamID)，cell \(session.cellID)")

    if listOnly {
        do {
            let files = try await connection.subscribedFiles(appID: appID, steamID: session.steamID, includeTags: true)
            print("✓ 我的订阅：\(files.count) 个")
            if printAllIDs { for file in files { print("ID \(file.id) updated \(file.timeUpdated) subscribed \(file.timeSubscribed)") } }
            for file in files.prefix(printAllIDs ? 0 : 20) {
                print("   · \(file.id)｜\(file.title)｜"
                    + ByteCountFormatter.string(fromByteCount: Int64(file.fileSize), countStyle: .file))
            }
        } catch {
            print("✗ 取订阅列表失败：\(error.localizedDescription)"); return 1
        }
        await connection.close()
        return 0
    }

    guard let itemID else { print("✗ 要一个创意工坊编号"); return 2 }

    if let subscribe {
        do {
            try await connection.setSubscribed(
                subscribe, id: itemID, appID: appID, listType: listType ?? SteamServiceCall.subscriptionListType)
            print("✓ 已在 Steam 上\(subscribe ? "订阅" : "取消订阅") \(itemID)")
        } catch {
            print("✗ \(subscribe ? "订阅" : "取消订阅")失败：\(error.localizedDescription)"); return 1
        }
        await connection.close()
        return 0
    }

    // 2. 条目详情 → depot 密钥 → 清单请求码 → 清单 → 分块
    do {
        let details = try await connection.call(
            SteamServiceCall.method("PublishedFile.GetDetails"),
            request: SteamServiceCall.publishedFileDetails(ids: [itemID], appID: appID))
        let items = details.values(1).compactMap { value -> PublishedFileInfo? in
            guard case .bytes(let data) = value, let message = try? ProtoMessage(data) else { return nil }
            return PublishedFileInfo(message)
        }
        guard let item = items.first, item.result == 1 else {
            print("✗ 读不到条目详情（Steam 返回 \(items.first?.result ?? 0)）"); return 1
        }
        print("✓ 条目：\(item.title)｜"
            + ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file)
            + "｜清单 \(item.contentHandle)")

        let depotKey = try await connection.depotDecryptionKey(appID: appID, depotID: appID)
        let serversBody = try await connection.call(
            SteamServiceCall.method("ContentServerDirectory.GetServersForSteamPipe"),
            request: SteamServiceCall.contentServers(cellID: session.cellID))
        let hosts = SteamContentServer.list(from: serversBody).filter(\.supportsHTTPS).map(\.host)
            + ["steampipe.akamaized.net", "cache1-lax1.steamcontent.com"]
        guard !hosts.isEmpty else { print("✗ 没有可用的内容服务器"); return 1 }
        let requestCode = try await connection.manifestRequestCode(
            appID: appID, depotID: appID, manifestID: item.contentHandle)
        let downloader = UGCContentDownloader()
        let manifest = try await downloader.manifest(
            depot: appID, manifestID: item.contentHandle, requestCode: requestCode, hosts: hosts,
            depotKey: depotKey)
        print("✓ 清单 \(manifest.manifestID)：\(manifest.files.count) 个文件，\(manifest.chunkCount) 个分块")

        let output = URL(fileURLWithPath: outputPath ?? ".", isDirectory: true)
        let started = Date()
        let state = try await downloader.download(
            manifest, to: output, hosts: hosts, depotKey: depotKey) { state in
                if state.chunksDone % 20 == 0 || state.chunksDone == state.chunksTotal {
                    print("   … \(state.chunksDone)/\(state.chunksTotal) 个分块")
                }
            }
        print("✓ 下完 \(state.filesDone) 个文件，共 "
            + ByteCountFormatter.string(fromByteCount: Int64(state.bytesDone), countStyle: .file)
            + "，用时 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒 → \(output.path)")
    } catch {
        print("✗ 下载失败：\(error.localizedDescription)")
        await connection.close()
        return 1
    }
    await connection.close()
    return 0
}

/// 登 CM：优先用存下来的令牌，其次扫码（手机确认），最后才用账号密码
private func workshopLogOn(
    servers: [URL], tokenPath: String?, saveTokensPath: String?, useQR: Bool, qrPath: String,
    account: String?
) async -> (connection: SteamCMConnection, tokens: CMAuthSession.Tokens, steamID: UInt64, cellID: UInt32)? {
    var tokens: CMAuthSession.Tokens?
    if let tokenPath {
        guard let data = FileManager.default.contents(atPath: tokenPath),
              let saved = try? JSONDecoder().decode(WorkshopSavedTokens.self, from: data)
        else { print("✗ 读不到 \(tokenPath) 里的令牌"); return nil }
        tokens = CMAuthSession.Tokens(
            accessToken: saved.accessToken, refreshToken: saved.refreshToken, accountName: saved.accountName)
    } else if useQR {
        tokens = await workshopQRTokens(servers: servers, qrPath: qrPath)
    } else if let account {
        tokens = await workshopPasswordTokens(servers: servers, account: account)
    } else if let stored = SteamCMSessionStore().load() {
        // 默认走本机存的会话（加密文件，0600；不碰钥匙串）——"一次确认"之后启动就直接用
        print("用本机存的会话：账号 \(stored.accountName)")
        tokens = CMAuthSession.Tokens(
            accessToken: stored.accessToken ?? stored.refreshToken, refreshToken: stored.refreshToken,
            accountName: stored.accountName)
    } else {
        print("✗ 要 --qr、--account 或 --token-file 之一（本机也还没有存过会话）")
        return nil
    }
    guard var tokens else { return nil }
    // 刚登录（扫码/密码）拿到的会话存起来：文件 + 机器密钥加密 + 0600，下次直接用
    if useQR || account != nil {
        SteamCMSessionStore().save(SteamCMSession(
            accountName: tokens.accountName,
            steamID: String(SteamJWT.steamID(tokens.refreshToken ?? tokens.accessToken) ?? 0),
            refreshToken: tokens.refreshToken ?? tokens.accessToken, accessToken: tokens.accessToken))
        print("   （会话存到 \(SteamCMSessionStore().fileURL.path)，加密 + 0600）")
    }
    if let saveTokensPath {
        let value = WorkshopSavedTokens(
            accountName: tokens.accountName, accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken)
        if let data = try? JSONEncoder().encode(value) {
            FileManager.default.createFile(
                atPath: saveTokensPath, contents: data, attributes: [.posixPermissions: 0o600])
            print("   （令牌存到 \(saveTokensPath)，权限 0600）")
        }
    }

    // 令牌登 CM：头部要带 SteamID（见 SteamCMConnection.logOn 的说明）；有的 CM 不响应，换着试
    let refresh = tokens.refreshToken ?? tokens.accessToken
    let steamID = SteamJWT.steamID(refresh) ?? 0
    for server in servers.prefix(8) {
        let connection = SteamCMConnection()
        await connection.connect(to: server)
        if let result = try? await connection.logOn(
            accessToken: refresh, accountName: tokens.accountName, steamID: steamID, timeout: .seconds(12)),
           result.isOK {
            if tokens.refreshToken == nil {
                tokens = CMAuthSession.Tokens(
                    accessToken: tokens.accessToken, refreshToken: tokens.accessToken,
                    accountName: tokens.accountName)
            }
            return (connection, tokens, result.steamID, result.cellID)
        }
        await connection.close()
    }
    print("✗ 没登上任何一台 CM")
    return nil
}

private struct WorkshopSavedTokens: Codable {
    let accountName: String
    let accessToken: String
    let refreshToken: String?
}

/// 扫码登录：把二维码写出来（手机扫一下确认），轮询到令牌（断线重连后继续）
private func workshopQRTokens(servers: [URL], qrPath: String) async -> CMAuthSession.Tokens? {
    setvbuf(stdout, nil, _IONBF, 0)
    guard let server = servers.first else { print("✗ 没有可用的 CM 服务器"); return nil }
    var connection = SteamCMConnection()
    await connection.connect(to: server)
    var pending: CMAuthSession.Pending
    do {
        let (started, url) = try await connection.beginAuthSessionViaQR()
        pending = started
        print("扫码登录：用手机 Steam App 扫这个码（或打开 \(url)）")
        if let image = SteamLoginQRCode.imageData(for: url, scale: 12), (try? image.write(to: URL(fileURLWithPath: qrPath))) != nil {
            print("   二维码图片：\(qrPath)")
        }
    } catch {
        print("✗ 开扫码会话失败：\(error.localizedDescription)")
        return nil
    }
    let deadline = ContinuousClock.now + .seconds(300)
    while ContinuousClock.now < deadline {
        do {
            if let tokens = try await connection.pollAuthSession(&pending) { return tokens }
        } catch {
            await connection.close()
            connection = SteamCMConnection()
            if let next = servers.first { await connection.connect(to: next) }
        }
        try? await Task.sleep(for: .seconds(max(2, pending.interval)))
    }
    print("✗ 等确认超时")
    return nil
}

/// 账号密码登录（密码从终端读，不回显）：整条认证会话在 CM 上跑
private func workshopPasswordTokens(servers: [URL], account: String) async -> CMAuthSession.Tokens? {
    guard let server = servers.first else { print("✗ 没有可用的 CM 服务器"); return nil }
    let connection = SteamCMConnection()
    await connection.connect(to: server)
    do {
        let key = try await connection.passwordRSAPublicKey(accountName: account)
        guard let password = workshopPromptSecret("   Steam 密码（不回显）："), !password.isEmpty else {
            print("✗ 没读到密码"); return nil
        }
        let encrypted = try SteamRSA.encrypt(
            password: password, modulusHex: key.modulus, exponentHex: key.exponent)
        var pending = try await connection.beginAuthSession(
            accountName: account, encryptedPassword: encrypted, timestamp: key.timestamp,
            machineID: CMRequest.machineID(accountName: account))
        if let codeGuard = pending.guards.first(where: \.needsCode) {
            FileHandle.standardError.write(Data("   \(codeGuard.describe)：".utf8))
            guard let code = Swift.readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !code.isEmpty
            else { print("✗ 没读到验证码"); return nil }
            try await connection.submitGuardCode(code, type: codeGuard.type, to: pending)
        } else if let confirmation = pending.guards.first(where: \.isConfirmation) {
            print("   请\(confirmation.describe)（手机 Steam App）")
        }
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            if let tokens = try await connection.pollAuthSession(&pending) { return tokens }
            try? await Task.sleep(for: .seconds(max(2, pending.interval)))
        }
    } catch {
        print("✗ 登录失败：\(error.localizedDescription)")
        return nil
    }
    print("✗ 等令牌超时")
    return nil
}

private func workshopPromptSecret(_ prompt: String) -> String? {
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
