import Foundation

/// 创意工坊的订阅操作，全部走 CM 的统一服务方法（和 `PublishedFile.GetDetails` 同一条通道）。
/// 这样"订阅 / 取消订阅 / 我的订阅 / 下载"都只用登录那一个会话，不再需要 Steam 社区的网页会话。
///
/// 字段号和类型见 Valve 的 `steammessages_publishedfile.steamclient.proto`。**注意**：
/// 订阅 / 取消订阅里的 `publishedfileid` 是 `uint64`（varint），不是 `GetDetails` 那种
/// `repeated fixed64`——类型写错时 Steam 的解析器把它当成不认识的字段丢掉，等于没传编号。
public extension SteamServiceCall {
    /// `list_type`：**订阅列表是 1**。不填（= 0）时 Steam 照样回"成功"，但订阅列表根本不变——
    /// 2026-09-29 用户在应用里订阅 6 个、取消 2 个，全都回了 EResult 1，`GetUserFiles(mysubscriptions)`
    /// 里却一个没变；改成 1 以后逐个核对：取消的消失、订阅的出现（441 → 445）。`.proto` 里没有这个字段的取值说明
    static let subscriptionListType: UInt32 = 1

    /// `PublishedFile.Subscribe#1`
    static func subscribeRequest(
        id: UInt64, appID: UInt32, notifyClient: Bool = true, listType: UInt32? = subscriptionListType
    ) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, varint: id)                      // publishedfileid（uint64）
        if let listType { body.field(2, varint: UInt64(listType)) }  // list_type
        body.field(3, int32: Int32(appID))             // appid
        body.field(4, bool: notifyClient)              // notify_client
        body.field(5, bool: true)                      // include_dependencies
        return body
    }

    /// `PublishedFile.Unsubscribe#1`
    static func unsubscribeRequest(
        id: UInt64, appID: UInt32, notifyClient: Bool = true, listType: UInt32? = subscriptionListType
    ) -> ProtoWriter {
        var body = ProtoWriter()
        body.field(1, varint: id)                      // publishedfileid（uint64）
        if let listType { body.field(2, varint: UInt64(listType)) }  // list_type
        body.field(3, int32: Int32(appID))
        body.field(4, bool: notifyClient)
        return body
    }

    /// `PublishedFile.GetUserFiles#1`：**我的订阅**（`type` = `mysubscriptions`，和网页
    /// `browsefilter=mysubscriptions` 对应）；一页最多 100 条
    static func userFilesRequest(
        appID: UInt32, steamID: UInt64 = 0, page: UInt32 = 1, perPage: UInt32 = 100,
        kind: String = "mysubscriptions", includeTags: Bool = false
    ) -> ProtoWriter {
        var body = ProtoWriter()
        if steamID != 0 { body.field(1, fixed64: steamID) }   // steamid
        body.field(2, varint: UInt64(appID))                 // appid
        body.field(4, varint: UInt64(page))                  // page
        body.field(5, varint: UInt64(perPage))               // numperpage
        body.field(6, string: kind)                          // type
        body.field(7, string: "lastupdated")                 // sortmethod
        body.field(20, bool: includeTags)                    // return_tags
        return body
    }
}

public extension SteamCMConnection {
    /// 订阅 / 取消订阅（走 CM，不需要网页会话）
    func setSubscribed(
        _ subscribed: Bool, id: UInt64, appID: UInt32, notifyClient: Bool = true,
        listType: UInt32? = SteamServiceCall.subscriptionListType, timeout: Duration = .seconds(20)
    ) async throws {
        let method = subscribed ? "PublishedFile.Subscribe" : "PublishedFile.Unsubscribe"
        _ = try await call(
            SteamServiceCall.method(method),
            request: subscribed
                ? SteamServiceCall.subscribeRequest(id: id, appID: appID, notifyClient: notifyClient, listType: listType)
                : SteamServiceCall.unsubscribeRequest(id: id, appID: appID, notifyClient: notifyClient, listType: listType),
            timeout: timeout)
    }

    /// 我的订阅列表（一页 100 条，读到没有新条目为止）。`includeTags` 为真时顺便带回标签
    func subscribedFiles(
        appID: UInt32, steamID: UInt64 = 0, includeTags: Bool = false,
        timeout: Duration = .seconds(20)
    ) async throws -> [PublishedFileInfo] {
        var items: [PublishedFileInfo] = []
        for page in 1...50 {
            let body = try await call(
                SteamServiceCall.method("PublishedFile.GetUserFiles"),
                request: SteamServiceCall.userFilesRequest(
                    appID: appID, steamID: steamID, page: UInt32(page), perPage: 100,
                    includeTags: includeTags),
                timeout: timeout)
            let pageItems = body.values(3).compactMap { value -> PublishedFileInfo? in
                guard case .bytes(let data) = value, let message = try? ProtoMessage(data) else { return nil }
                return PublishedFileInfo(message)
            }
            if pageItems.isEmpty { break }
            items += pageItems
            if pageItems.count < 100 { break }
        }
        return items
    }
}
