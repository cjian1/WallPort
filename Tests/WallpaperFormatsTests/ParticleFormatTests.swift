import Foundation
import Testing
@testable import WallpaperFormats

/// 拼一个最小的 TEX：1×1 RGBA，一层 mipmap，后面可选地接精灵图段
private func makeTex(sheet: Data? = nil) -> Data {
    var data = Data("TEXV0005".utf8) + Data([0]) + Data("TEXI0001".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    u32(0)  // RGBA8888
    u32(4)  // 标志
    u32(1); u32(1); u32(1); u32(1)
    u32(0)
    data += Data("TEXB0003".utf8) + Data([0])
    u32(1)  // 图像数
    u32(UInt32(bitPattern: -1))  // 不是内嵌图片
    u32(1)  // mipmap 数
    u32(1); u32(1)
    u32(0); u32(4)  // 不压缩，解压后 4 字节
    u32(4)
    data += Data([255, 255, 255, 255])
    if let sheet { data += sheet }
    return data
}

private func makeSheet(version: Int, frames: [(x: Float, y: Float, width: Float, height: Float)]) -> Data {
    var data = Data("TEXS000\(version)".utf8) + Data([0])
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func f32(_ value: Float) { u32(value.bitPattern) }
    u32(UInt32(frames.count))
    if version >= 3 {
        u32(UInt32(frames.first?.width ?? 0))
        u32(UInt32(frames.first?.height ?? 0))
    }
    for frame in frames {
        u32(0)
        f32(1 / Float(frames.count))
        f32(frame.x); f32(frame.y); f32(frame.width); f32(0); f32(0); f32(frame.height)
    }
    return data
}

@Suite struct SpriteSheetTests {
    @Test func readsVersion3Frames() throws {
        let frames = [(Float(0), Float(0), Float(102.5), Float(128)), (102.5, 0, 102.5, 128), (205, 0, 102.5, 128)]
        let tex = try TexFile(data: makeTex(sheet: makeSheet(version: 3, frames: frames.map { ($0.0, $0.1, $0.2, $0.3) })))
        let sheet = try #require(tex.spriteSheet)
        #expect(sheet.frames.count == 3)
        #expect(sheet.frames[1].x == 102.5)
        #expect(sheet.frames[2].width == 102.5)
        #expect(sheet.frames[0].height == 128)
        #expect(abs(sheet.frames[0].duration - 1.0 / 3) < 0.0001)
        #expect(tex.trailingByteCount == 0)
    }

    @Test func readsVersion2WithoutSizeHeader() throws {
        let tex = try TexFile(data: makeTex(sheet: makeSheet(version: 2, frames: [(0, 0, 64, 64), (64, 0, 64, 64)])))
        #expect(tex.spriteSheet?.frames.map(\.x) == [0, 64])
        #expect(tex.trailingByteCount == 0)
    }

    @Test func plainTexturesHaveNoSheet() throws {
        let tex = try TexFile(data: makeTex())
        #expect(tex.spriteSheet == nil)
    }

    @Test func truncatedSheetIsAnError() {
        var sheet = makeSheet(version: 3, frames: [(0, 0, 64, 64), (64, 0, 64, 64)])
        sheet.removeLast(10)
        #expect(throws: FormatError.self) { try TexFile(data: makeTex(sheet: sheet)) }
    }
}

@Suite struct ParticleDefinitionTests {
    private let json = """
    {
        "material": "materials/particle/halo.json",
        "maxcount": 150,
        "starttime": 30,
        "animationmode": "randomframe",
        "sequencemultiplier": 3,
        "emitter": [{"name": "boxrandom", "rate": 40, "distancemax": "2000 800 0"},
                    {"name": "sphererandom", "distancemax": 512, "directions": {"user": "dir", "value": "1 0.5 0"}}],
        "initializer": [{"name": "colorrandom", "min": "255 128 0"}],
        "operator": [{"name": "remapvalue", "operation": "remap", "output": "speed", "outputrangemin": -5}],
        "renderer": [{"name": "spritetrail", "length": 0.005}],
        "controlpoint": [{"id": 0, "flags": 1}, {"id": 1, "flags": 0, "offset": "100 0 0"}],
        "children": [{"name": "particles/glow.json", "type": "eventfollow", "origin": "0 10 0"},
                     {"name": "particles/static.json"}]
    }
    """

    @Test func readsTopLevelFields() throws {
        let definition = try ParticleDefinition(json: Data(json.utf8))
        #expect(definition.material == "materials/particle/halo.json")
        #expect(definition.maxCount == 150)
        #expect(definition.startTime == 30)
        #expect(definition.animationMode == "randomframe")
        #expect(definition.sequenceMultiplier == 3)
    }

    @Test func componentsKeepNumbersVectorsAndStrings() throws {
        let definition = try ParticleDefinition(json: Data(json.utf8))
        let box = definition.emitters[0]
        #expect(box.name == "boxrandom")
        #expect(box.float("rate", 0) == 40)
        #expect(box.vector("distancemax", .zero) == SIMD3(2000, 800, 0))
        // 一个数的向量字段三个分量都用它；包在 {"value": …} 里的也能读
        let sphere = definition.emitters[1]
        #expect(sphere.vector("distancemax", .zero) == SIMD3(512, 512, 512))
        #expect(sphere.vector("directions", .zero) == SIMD3(1, 0.5, 0))
        #expect(sphere.float("rate", 5) == 5)
        let remap = definition.operators[0]
        #expect(remap.strings["operation"] == "remap")
        #expect(remap.float("outputrangemin", 0) == -5)
        #expect(definition.renderers[0].float("length", 0) == 0.005)
    }

    @Test func readsControlPointsAndChildren() throws {
        let definition = try ParticleDefinition(json: Data(json.utf8))
        #expect(definition.controlPoints[0].followsPointer)
        #expect(!definition.controlPoints[1].followsPointer)
        #expect(definition.controlPoints[1].offset == SIMD3(100, 0, 0))
        #expect(definition.children.count == 2)
        #expect(definition.children[0].kind == .eventFollow)
        #expect(definition.children[0].origin == SIMD3(0, 10, 0))
        // 没写类型的按 static
        #expect(definition.children[1].kind == .static)
    }

    /// 有限但超出 Int 范围的数（坏文件里的 1e20）不能让解析崩掉：截到上限
    @Test func hugeIntegersAreClampedInsteadOfCrashing() throws {
        let huge = #"{"material": "m.json", "maxcount": 1e20, "flags": -1e20, "controlpoint": [{"id": 1e30}]}"#
        let definition = try ParticleDefinition(json: Data(huge.utf8))
        #expect(definition.maxCount == 1 << 52)
        #expect(definition.flags == -(1 << 52))
        #expect(definition.controlPoints.first?.id == 1 << 52)
        let scene = #"{"objects": [{"id": 1e20, "text": {"value": "x"}}]}"#
        #expect(SceneElements.list(sceneJSON: Data(scene.utf8)).first?.id == "text:\(1 << 52)")
    }

    @Test func missingMaterialIsAnError() {
        #expect(throws: FormatError.self) { try ParticleDefinition(json: Data("{\"maxcount\": 5}".utf8)) }
    }

    @Test func sceneObjectsCarryInstanceOverrides() throws {
        let scene = """
        {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": [
            {"id": 1, "particle": "particles/a.json",
             "instanceoverride": {"id": 2, "size": 1.5, "count": 0.5, "colorn": {"user": "c", "value": "0.5 1 1"},
                                  "rate": {"script": "export function update() {}"}, "controlpoint1": "10 20 0"}},
            {"id": 3, "particle": "particles/b.json"},
            {"id": 4, "image": "models/x.json"}
         ]}
        """
        let description = try SceneDescription(json: Data(scene.utf8))
        let first = try #require(description.objects[0].particleOverride)
        #expect(first.size == 1.5)
        #expect(first.count == 0.5)
        #expect(first.rate == 1)  // 只有脚本没有值时按 1
        #expect(first.color == SIMD3(0.5, 1, 1))
        #expect(first.controlPoints[1] == SIMD3(10, 20, 0))
        #expect(description.objects[1].particleOverride == ParticleOverride())
        #expect(description.objects[2].particleOverride == nil)
    }
}
