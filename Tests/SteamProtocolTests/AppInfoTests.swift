import Foundation
import Testing
@testable import SteamProtocol

/// 应用信息（PICS）：KeyValues 文本、depot 和清单编号、回包解析；清单只取 assets 子目录
@Suite struct AppInfoTests {
    /// 自己写的样例（结构和 Steam 的应用信息一样：新老两种清单写法、注释、转义、平台条件、非 depot 的子项）
    private let sample = #"""
        "appinfo"
        {
            "appid"     "431960"
            "common" { "name" "Wallpaper \"Engine\"" }   // 注释
            "depots"
            {
                "431961"
                {
                    "config" { "oslist" "windows" }
                    "manifests" { "public" { "gid" "3687007859740550172" "size" "123" } }
                }
                "431962"
                {
                    "config" { "oslist" "macos,linux" }
                    "manifests" { "public" "42" }
                }
                "431963" { "manifests" { "beta" { "gid" "9" } } }
                "228988" { "depotfromapp" "228980" "manifests" { "public" "5" } }
                "branches" { "public" { "buildid" "1" } }
                "baselanguages" "english"
            }
            "extended" { "flag" "1" [$WIN32] }
        }
        """#

    @Test func parsesKeyValuesText() throws {
        let root = try KeyValues.parse(sample)
        #expect(root.name == "appinfo")
        #expect(root["COMMON"]?["name"]?.value == #"Wallpaper "Engine""#, "键不区分大小写、转义的引号")
        #expect(root["depots"]?["431961"]?["manifests"]?["public"]?["gid"]?.value == "3687007859740550172")
        #expect(throws: SteamCMError.self) { try KeyValues.parse(#""a" { "b" "c" "#) }
        #expect(throws: SteamCMError.self) { try KeyValues.parse(#""a" "b" }"#) }
    }

    @Test func readsDepotsAndPublicManifests() throws {
        let info = SteamAppInfo(appID: 431_960, keyValues: try KeyValues.parse(sample))
        #expect(info.depots == [
            .init(id: 228_988, osList: [], publicManifest: 5, fromOtherApp: true),
            .init(id: 431_961, osList: ["windows"], publicManifest: 3_687_007_859_740_550_172),
            .init(id: 431_962, osList: ["macos", "linux"], publicManifest: 42),
            .init(id: 431_963, osList: [], publicManifest: nil),
        ])
    }

    @Test func requestsCarryAppAndToken() throws {
        let token = try ProtoMessage(CMRequest.picsAccessToken(appID: 431_960).bytes)
        #expect(token.varint(2) == 431_960)
        let info = try ProtoMessage(CMRequest.picsProductInfo(appID: 431_960, accessToken: 77).bytes)
        let app = try #require(info.message(2))
        #expect(app.varint(1) == 431_960 && app.varint(2) == 77)
        #expect(info.bool(7) == true, "single_response")
    }

    @Test func parsesResponses() throws {
        var appToken = ProtoWriter()
        appToken.field(1, varint: 431_960)
        appToken.field(2, varint: 123_456)
        var tokens = ProtoWriter()
        tokens.field(3, message: appToken)
        #expect(PICSResponse.accessToken(try ProtoMessage(tokens.bytes), appID: 431_960) == 123_456)
        #expect(PICSResponse.accessToken(try ProtoMessage(tokens.bytes), appID: 1) == 0)

        var inline = ProtoWriter()
        inline.field(1, varint: 431_960)
        inline.field(5, bytes: Array(sample.utf8) + [0])
        var response = ProtoWriter()
        response.field(1, message: inline)
        #expect(try PICSResponse.appData(try ProtoMessage(response.bytes), appID: 431_960) == .inline(sample))

        var viaHTTP = ProtoWriter()
        viaHTTP.field(1, varint: 431_960)
        viaHTTP.field(4, bytes: [0xab, 0x01])
        var big = ProtoWriter()
        big.field(1, message: viaHTTP)
        big.field(8, string: "appinfo.example.com")
        #expect(try PICSResponse.appData(try ProtoMessage(big.bytes), appID: 431_960)
            == .http(URL(string: "https://appinfo.example.com/appinfo/431960/sha/ab01.txt.gz")!))

        var unknown = ProtoWriter()
        unknown.field(2, varint: 431_960)
        #expect(throws: SteamCMError.self) { try PICSResponse.appData(try ProtoMessage(unknown.bytes), appID: 431_960) }
    }

    /// 只要 assets 子目录：不区分大小写、Windows 的反斜杠、路径去掉这一级；程序本身和同名前缀的文件夹不要
    @Test func manifestSubtreeKeepsOnlyAssets() {
        let chunk = ContentManifest.Chunk(sha: [1], offset: 0, originalSize: 1, compressedSize: 1)
        let manifest = ContentManifest(files: [
            .init(name: "wallpaper32.exe", size: 1, chunks: [chunk]),
            .init(name: "assets", size: 0, chunks: [], flags: ContentManifest.File.directoryFlag),
            .init(name: "assets\\shaders\\common.h", size: 1, chunks: [chunk]),
            .init(name: "Assets/materials", size: 0, chunks: [], flags: ContentManifest.File.directoryFlag),
            .init(name: "assetsbackup/x.json", size: 1, chunks: [chunk]),
        ], depotID: 431_961, manifestID: 9)
        let assets = manifest.subtree("assets")
        #expect(assets.files.map(\.name) == ["shaders/common.h", "materials"])
        #expect(assets.depotID == 431_961 && assets.manifestID == 9)
        #expect(assets.files[1].isDirectory)
    }
}
