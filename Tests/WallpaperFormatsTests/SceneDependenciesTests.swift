import Foundation
import Testing
@testable import WallpaperFormats

/// 这里的 JSON 都是按真实文件的结构手写的最小样例，不含任何 WE 内容
@Suite struct SceneDependenciesTests {
    private func package(_ files: [String: String]) throws -> ScenePackage {
        try ScenePackage(data: makePackage(files: files.sorted { $0.key < $1.key }.map { ($0.key, Data($0.value.utf8)) }))
    }

    @Test func followsImageModelMaterialChain() throws {
        let dependencies = try SceneDependencies(package: package([
            "scene.json": #"""
                {"version": 5, "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
                 "objects": [{"image": "models/bg.json"}, {"particle": "particles/snow.json"}, {"text": {"value": "hi"}, "font": "systemfont_arial"}]}
                """#,
            "models/bg.json": #"{"material": "materials/bg.json"}"#,
            "materials/bg.json": #"{"passes": [{"shader": "genericimage4", "textures": ["bg", null, "_rt_default"]}]}"#,
            "materials/bg.tex": "tex",
        ]))
        #expect(dependencies.sceneVersion == 5)
        #expect(dependencies.projection?.width == 1920)
        #expect(dependencies.objectKinds == ["image": 1, "particle": 1, "text": 1])
        #expect(dependencies.inPackage == ["scene.json", "models/bg.json", "materials/bg.json", "materials/bg.tex"])
        #expect(dependencies.missing == [
            "particles/snow.json", "shaders/genericimage4.vert", "shaders/genericimage4.frag",
        ])
    }

    @Test func followsEffectsAndShaderIncludes() throws {
        let dependencies = try SceneDependencies(package: package([
            "scene.json": #"{"objects": [{"effects": [{"file": "effects/shake/effect.json", "passes": [{"textures": [null, "masks/m"]}]}]}]}"#,
            "effects/shake/effect.json": #"{"passes": [{"material": "materials/effects/shake.json"}], "dependencies": ["shaders/effects/shake.frag"]}"#,
            "materials/effects/shake.json": #"{"passes": [{"shader": "effects/shake"}]}"#,
            "shaders/effects/shake.frag": "#include \"common.h\"\nvoid main() {}",
            "shaders/effects/shake.vert": "  #include \"common_vertex.h\"",
            "materials/masks/m.tex": "tex",
        ]))
        #expect(dependencies.missing == ["shaders/common.h", "shaders/common_vertex.h"])
        #expect(dependencies.inPackage.contains("materials/masks/m.tex"))
        #expect(dependencies.inPackage.contains("shaders/effects/shake.vert"))
    }

    @Test func editorSourceImagesInDependenciesMapToCompiledTextures() throws {
        let dependencies = try SceneDependencies(package: package([
            "scene.json": #"{"objects": [{"effects": [{"file": "effects/water/effect.json"}]}]}"#,
            "effects/water/effect.json": #"{"dependencies": ["materials/effects/flow.png", "materials/effects/flow.tex-json"]}"#,
            "materials/effects/flow.tex": "tex",
        ]))
        #expect(dependencies.missing.isEmpty)
        #expect(dependencies.inPackage.contains("materials/effects/flow.tex"))
    }

    @Test func resolvesAgainstAssetsAndFollowsTheirReferences() throws {
        let assets = FileManager.default.temporaryDirectory
            .appendingPathComponent("SceneDependenciesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: assets) }
        try FileManager.default.createDirectory(at: assets.appendingPathComponent("shaders"), withIntermediateDirectories: true)
        try Data("#include \"common.h\"".utf8).write(to: assets.appendingPathComponent("shaders/genericimage4.frag"))
        try Data("".utf8).write(to: assets.appendingPathComponent("shaders/genericimage4.vert"))
        try Data("".utf8).write(to: assets.appendingPathComponent("shaders/common.h"))

        let dependencies = try SceneDependencies(package: package([
            "scene.json": #"{"objects": [{"image": "models/bg.json"}]}"#,
            "models/bg.json": #"{"material": "materials/bg.json"}"#,
            "materials/bg.json": #"{"passes": [{"shader": "genericimage4", "textures": ["util/noise"]}]}"#,
        ]), assets: assets)
        #expect(dependencies.inAssets == ["shaders/genericimage4.vert", "shaders/genericimage4.frag", "shaders/common.h"])
        #expect(dependencies.missing == ["materials/util/noise.tex"])
    }

    @Test func packageWithoutSceneIsRejected() {
        #expect(throws: FormatError.self) { try SceneDependencies(package: package(["other.json": "{}"])) }
    }
}
