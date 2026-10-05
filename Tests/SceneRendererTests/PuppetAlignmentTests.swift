import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SceneRenderer
import WallpaperFormats

/// 木偶网格的顶点和四边形一样以图层框中心为原点，所以对齐方式也要作用在网格上。
/// 2572528403 的背景和人物部件都是左上对齐（origin 是部件的左上角）：只挪背景不挪人物的话，
/// 人物整体偏半个框，背景给人物留的位置露出底色。夹具是自己拼的最小场景，不含 WE 内容。

private func package(_ files: [String: Data]) throws -> ScenePackage {
    var header = Data()
    func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
    u32(8)
    header += Data("PKGV0001".utf8)
    u32(files.count)
    var body = Data()
    for (name, data) in files.sorted(by: { $0.key < $1.key }) {
        u32(name.utf8.count)
        header += Data(name.utf8)
        u32(body.count)
        u32(data.count)
        body += data
    }
    return try ScenePackage(data: header + body)
}

/// 全白的 8×8 RGBA TEX
private func whiteTex() -> Data {
    var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    u32(0); u32(2); u32(8); u32(8); u32(8); u32(8); u32(0)
    data += Data("TEXB0003".utf8) + Data([0])
    u32(1); u32(UInt32(bitPattern: -1))
    u32(1); u32(8); u32(8); u32(0); u32(256); u32(256)
    return data + Data(repeating: 255, count: 256)
}

/// 最小的木偶模型（结构同 PuppetMeshTests）：一个以原点为中心、边长 20 的正方形，骨骼和动画都是空的
private func squareModel() -> Data {
    var data = Data("MDLV0023".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func f32(_ value: Float) { u32(value.bitPattern) }
    u32(0x0180_0009)
    u32(1)
    u32(1)
    data += Data("materials/white.json".utf8) + Data([0])
    data += Data(repeating: 0, count: 28)
    u32(0x0180_000F)
    let vertices: [(SIMD2<Float>, SIMD2<Float>)] = [
        (SIMD2(-10, -10), SIMD2(0, 1)), (SIMD2(10, -10), SIMD2(1, 1)),
        (SIMD2(-10, 10), SIMD2(0, 0)), (SIMD2(10, 10), SIMD2(1, 0)),
    ]
    u32(UInt32(vertices.count * 80))
    for (position, uv) in vertices {
        f32(position.x); f32(position.y); f32(0)
        f32(0); f32(0); f32(1)
        f32(1); f32(0); f32(0); f32(1)
        u32(3); u32(0); u32(0); u32(0)
        f32(1); f32(0); f32(0); f32(0)
        f32(uv.x); f32(uv.y)
    }
    let indices: [UInt16] = [0, 1, 2, 2, 1, 3]
    u32(UInt32(indices.count * 2))
    for index in indices { withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) } }
    data += Data(repeating: 0x11, count: 24)
    // 空的骨骼段和动画段（结构同 PuppetMeshTests 的 appendSkeleton）：段头、段尾偏移、个数 0
    func patch(_ at: Int) {
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { data.replaceSubrange(at..<(at + 4), with: $0) }
    }
    data += Data("MDLS0004".utf8) + Data([0])
    let bonesEnd = data.count
    u32(0)
    u32(0)
    data += Data(repeating: 0, count: 17)
    patch(bonesEnd)
    data += Data("MDLA0006".utf8) + Data([0])
    let animationsEnd = data.count
    u32(0)
    u32(0)
    patch(animationsEnd)
    return data + Data("MDLE0001".utf8) + Data([0])
}

private func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let offset = y * image.bytesPerRow + x * 4
    return [data[offset + 2], data[offset + 1], data[offset]]
}

@Suite struct PuppetAlignmentTests {
    @Test func topLeftAlignedPuppetHangsDownRightFromItsOrigin() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let files: [String: Data] = [
            "models/part.json": Data(#"{"material": "materials/white.json", "puppet": "models/part.mdl"}"#.utf8),
            "models/part.mdl": squareModel(),
            "materials/white.json": Data(
                #"{"passes": [{"blending": "translucent", "shader": "genericimage2", "textures": ["white"]}]}"#.utf8),
            "materials/white.tex": whiteTex(),
            // 画布 100×100（y 向上）：origin 在画布左上角，框 20×20，左上对齐时占画布 x 0…20、y 80…100
            "scene.json": Data("""
            {"general": {"orthogonalprojection": {"width": 100, "height": 100}, "clearcolor": "0 0 0"},
             "objects": [
               {"id": 1, "image": "models/part.json", "origin": "0 100 0", "size": "20 20", "alignment": "topleft"}
             ]}
            """.utf8),
        ]
        let renderer = try SceneRenderer(device: device, package: package(files), assets: nil)
        #expect(renderer.problems.isEmpty, "\(renderer.problems)")
        let image = try renderer.renderImage(width: 100, height: 100)
        // 画面第 y 行 = 画布 100 − y
        #expect(rgb(image, 15, 15) == [255, 255, 255], "左上对齐的网格要从 origin 往右下铺开")
        #expect(rgb(image, 5, 5) == [255, 255, 255])
        #expect(rgb(image, 25, 10) == [0, 0, 0], "网格宽 20，不该伸到 x = 25")
        #expect(rgb(image, 10, 25) == [0, 0, 0], "网格高 20，不该伸到画布 y = 75")
    }
}
