import Foundation
import Testing
@testable import ShaderTranslation

/// 测试用的都是按 WE 方言写法手写的小片段，不含 WE 的着色器源码
@Suite struct ShaderInterfaceTests {
    private let fragment = """
    // [COMBO] {"material":"ui_noise","combo":"NOISE","type":"options","default":0}
    // [COMBO] {"material":"ui_dir","combo":"DIRECTION","type":"options","default":2,"options":{"a":0}}
    #include "common.h"
    uniform sampler2D g_Texture0; // {"hidden":true}
    uniform sampler2D g_Texture1; // {"label":"flow","mode":"flowmask","default":"util/noflow"}
    uniform sampler2D g_Texture3; // {"label":"mask","mode":"opacitymask","combo":"MASK"}
    uniform float g_Time;
    uniform float g_Speed; // {"material":"speed","label":"ui_speed","default":1,"range":[0.0, 10]}
    uniform vec2 g_Friction; // {"material":"friction","default":"1 0.5","linked":true}
    uniform float g_Samples[16]; // {"material":"samples","default":0}
    """

    @Test func readsCombosWithDefaults() {
        let interface = ShaderInterface(sources: [fragment])
        #expect(interface.combos == [
            .init(name: "NOISE", defaultValue: 0), .init(name: "DIRECTION", defaultValue: 2),
        ])
    }

    @Test func readsMaterialParametersOnly() {
        let parameters = ShaderInterface(sources: [fragment]).parameters
        #expect(parameters.map(\.key) == ["speed", "friction", "samples"])
        #expect(parameters[0].defaultValue == [1])
        #expect(parameters[1].defaultValue == [1, 0.5])
        #expect(parameters[2].uniform == "g_Samples")
    }

    @Test func readsTextureSlots() {
        let textures = ShaderInterface(sources: [fragment]).textures
        #expect(textures.map(\.index) == [0, 1, 3])
        #expect(textures[1].defaultTexture == "util/noflow")
        #expect(textures[2].combo == "MASK")
    }

    /// 向量默认值有逗号分隔的写法（WE 自带的音频可视化条用的是 "0.0, 1.0"），
    /// 以前只按空格切，逗号那一项解析不出来，整个向量就错位了
    @Test func readsCommaSeparatedVectorDefaults() {
        let source = """
        uniform vec2 g_Bounds; // {"material":"bounds","default":"0.0, 1.0"}
        uniform vec2 g_Angles; // {"material":"angles","default":"0, 360"}
        """
        let parameters = ShaderInterface(sources: [source]).parameters
        #expect(parameters[0].defaultValue == [0, 1])
        #expect(parameters[1].defaultValue == [0, 360])
    }

    @Test func sameComboInBothStagesIsCountedOnce() {
        let vertex = #"// [COMBO] {"combo":"NOISE","default":1}"#
        #expect(ShaderInterface(sources: [vertex, fragment]).combos.first == .init(name: "NOISE", defaultValue: 1))
    }
}

@Suite struct ShaderAssemblerTests {
    @Test func expandsIncludesOnceAndAddsDefines() throws {
        let headers = ["shaders/a.h": "#include \"b.h\"\nfloat a() { return b(); }", "shaders/b.h": "float b() { return 1.0; }"]
        let source = "#include \"a.h\"\n#include \"b.h\"\nvoid main() {}"
        let assembled = try ShaderAssembler.assemble(source, defines: ["MASK": 1, "NOISE": 0]) { headers[$0] }
        #expect(assembled.hasPrefix("#version 450"))
        #expect(assembled.contains("#define MASK 1\n#define NOISE 0"))
        #expect(assembled.components(separatedBy: "float b()").count == 2)
        #expect(assembled.contains("#define mul(a, b) ((b) * (a))"))
    }

    @Test func missingIncludeIsReported() {
        #expect(throws: ShaderAssembler.AssemblyError.missingInclude("nope.h")) {
            try ShaderAssembler.assemble("#include \"nope.h\"", defines: [:]) { _ in nil }
        }
    }

    /// 真实语料（workshop/2973943998 iris_movement__.vert）结尾多写了一个 #endif，
    /// WE 的编译器容忍，glslang 会报 "mismatched statements"：把多余的 #endif 丢掉，
    /// 但条件编译块本身要原样保留。
    @Test func dropsStrayEndifButKeepsBalancedBlocks() {
        let balanced = "#if A\nfloat a;\n#endif\n#if B\nfloat b;\n#endif\n"
        #expect(ShaderAssembler.balancingConditionals(balanced) == balanced)

        let stray = "#if A\nfloat a;\n#endif\n#endif\nfloat b;\n"
        #expect(ShaderAssembler.balancingConditionals(stray) == "#if A\nfloat a;\n#endif\nfloat b;\n")

        // #ifdef / #ifndef 与 #if 一样计入深度，#else / #elif 不改变深度
        let mixed = "#ifdef A\n#ifndef B\nfloat x;\n#else\nfloat y;\n#endif\n#endif\n#endif\n"
        #expect(ShaderAssembler.balancingConditionals(mixed)
            == "#ifdef A\n#ifndef B\nfloat x;\n#else\nfloat y;\n#endif\n#endif\n")
    }

    /// WE 走 HLSL 编译器，宏换了内容再定义只是警告、后面的生效（3795078488 的音频特效又定义了一遍 M_PI_2）；
    /// glslang 当错误。第二次 #define 前补一句 #undef，第一次定义不动，开关和方言宏也算"已经定义"
    @Test func laterRedefinitionWinsLikeHLSL() throws {
        let headers = ["shaders/common.h": "#define M_PI_2 6.28318530718\nfloat half_pi() { return M_PI_2; }"]
        let source = "#include \"common.h\"\n#define M_PI_2 1.57079632679\n  #  define MASK 0\n#define LOCAL(x) (x)\nvoid main() {}"
        let assembled = try ShaderAssembler.assemble(source, defines: ["MASK": 1]) { headers[$0] }
        #expect(assembled.contains("#undef M_PI_2\n#define M_PI_2 1.57079632679"))
        #expect(!assembled.contains("#undef M_PI_2\n#define M_PI_2 6.28318530718"))
        #expect(assembled.contains("#undef MASK\n  #  define MASK 0"))
        #expect(!assembled.contains("#undef LOCAL"))
        #expect(ShaderAssembler.definedName("#define frac fract") == "frac")
        #expect(ShaderAssembler.definedName("#defined x") == nil)
    }
}

@Suite struct GLSLRewriterTests {
    @Test func assignsSharedVaryingLocationsAcrossStages() {
        var rewriter = GLSLRewriter()
        let vertex = rewriter.rewrite("""
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec4 v_TexCoord;
            varying vec2 v_Bounds;
            void main() {}
            """, stage: .vertex)
        #expect(vertex.source.contains("layout(location = 0) in vec3 a_Position;"))
        #expect(vertex.source.contains("layout(location = 1) in vec2 a_TexCoord;"))
        #expect(vertex.source.contains("layout(location = 0) out vec4 v_TexCoord;"))
        #expect(vertex.source.contains("layout(location = 1) out vec2 v_Bounds;"))

        // 片段着色器里的声明顺序不同，编号仍然按名字对上
        let fragment = rewriter.rewrite("varying vec2 v_Bounds;\nvarying vec4 v_TexCoord;\nvoid main() {}", stage: .fragment)
        #expect(fragment.source.contains("layout(location = 1) in vec2 v_Bounds;"))
        #expect(fragment.source.contains("layout(location = 0) in vec4 v_TexCoord;"))
    }

    @Test func collectsUniformsIntoOneBlockAndBindsTextures() {
        var rewriter = GLSLRewriter()
        let result = rewriter.rewrite("""
            uniform mat4 g_ModelViewProjectionMatrix;
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture3;
            float helper() { return 1.0; }
            uniform float g_AudioSpectrum16Left[16];
            uniform float g_Time;
            uniform float g_Time;
            void main() { gl_FragColor = texture(g_Texture0, vec2(g_Time)); }
            """, stage: .fragment)
        #expect(result.uniforms == [
            .init(name: "g_ModelViewProjectionMatrix", type: "mat4", count: nil),
            .init(name: "g_AudioSpectrum16Left", type: "float", count: 16),
            .init(name: "g_Time", type: "float", count: nil),
        ])
        #expect(result.source.contains("layout(scalar, binding = 0) uniform WallpaperUniforms {"))
        #expect(result.source.contains("layout(binding = 1) uniform sampler2D g_Texture0;"))
        #expect(result.source.contains("layout(binding = 4) uniform sampler2D g_Texture3;"))
        #expect(result.source.contains("_fragColor = texture(g_Texture0"))
        #expect(result.source.contains("layout(location = 0) out vec4 _fragColor;"))
        // 所有声明都在用到它们的函数之前
        let block = result.source.range(of: "WallpaperUniforms")!.lowerBound
        let helper = result.source.range(of: "float helper()")!.lowerBound
        #expect(block < helper)
    }

    @Test func declarationsAfterFunctionsAreHoisted() {
        var rewriter = GLSLRewriter()
        let result = rewriter.rewrite("""
            vec3 blur(vec2 u) { return texture(g_Texture0, u).rgb; }
            uniform sampler2D g_Texture0;
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = vec4(blur(v_TexCoord), 1.0); }
            """, stage: .fragment)
        let sampler = result.source.range(of: "uniform sampler2D g_Texture0")!.lowerBound
        let varying = result.source.range(of: "in vec2 v_TexCoord")!.lowerBound
        let function = result.source.range(of: "vec3 blur")!.lowerBound
        #expect(sampler < function && varying < function)
    }

    @Test func integerInitializersFromFloatsAreCast() {
        #expect(GLSLRewriter.castIntegerInitializer("\tint count = g_Samples * 2.0;") == "\tint count = int(g_Samples * 2.0);")
        #expect(GLSLRewriter.castIntegerInitializer("int a = 1, b = 2;") == "int a = 1, b = 2;")
        #expect(GLSLRewriter.castIntegerInitializer("float x = 1.0;") == "float x = 1.0;")
    }

    @Test func fragmentVaryingsWithFewerComponentsAreAdapted() {
        var rewriter = GLSLRewriter()
        _ = rewriter.rewrite("varying vec4 v_TexCoord;\nvoid main() {}", stage: .vertex)
        let fragment = rewriter.rewrite("""
            varying vec2 v_TexCoord;
            varying vec3 v_Missing;
            void main()
            {
                gl_FragColor = vec4(v_TexCoord, v_Missing.x, 1.0);
            }
            """, stage: .fragment)
        #expect(fragment.source.contains("layout(location = 0) in vec4 _varying_v_TexCoord;"))
        #expect(fragment.source.contains("vec2 v_TexCoord;"))
        #expect(fragment.source.contains("{ v_TexCoord = vec2(_varying_v_TexCoord);"))
        #expect(fragment.source.contains("vec3 v_Missing = vec3(0);"))
    }

    @Test func parsesDeclarationsWithPrecisionAndArrays() {
        #expect(GLSLRewriter.declaration("varying highp vec2 v_X;", keyword: "varying")?.name == "v_X")
        let array = GLSLRewriter.declaration("uniform float g_B[16];", keyword: "uniform")
        #expect(array?.name == "g_B" && array?.count == 16 && array?.suffix == "[16]")
        #expect(GLSLRewriter.declaration("uniformfloat x;", keyword: "uniform") == nil)
    }
}

/// WE 的着色器常用 Windows 的 CRLF 换行。Swift 里 "\r\n" 是一个字符，按 "\n" 切行会切不开
@Suite struct LineEndingTests {
    @Test func crlfSourcesExpandIncludesAndExposeInterface() throws {
        let source = "// [COMBO] {\"combo\":\"MASK\",\"default\":1}\r\n#include \"a.h\"\r\nvoid main() {}\r\n"
        let assembled = try ShaderAssembler.assemble(source, defines: [:]) { $0 == "shaders/a.h" ? "float a;\r\n" : nil }
        #expect(!assembled.contains("#include"))
        #expect(assembled.contains("float a;"))
        #expect(ShaderInterface(sources: [source]).combos == [.init(name: "MASK", defaultValue: 1)])
    }
}

@Suite struct ImplicitConversionFixerTests {
    @Test func castsTruncatingVectorAssignment() {
        let source = "void main() {\n\tv_Small = v_Big;\n}"
        let log = "ERROR: 0:2: 'assign' :  cannot convert from 'layout( location=0) smooth out highp 4-component vector of float' to 'layout( location=1) smooth out highp 2-component vector of float'\nERROR: 0:2: '' : compilation terminated"
        #expect(ImplicitConversionFixer.fix(source: source, log: log) == "void main() {\n\tv_Small = vec2(v_Big);\n}")
    }

    @Test func castsFloatToIntAssignment() {
        let source = "int a;\na = g_Value * 2.0;"
        let log = "ERROR: 0:2: '=' :  cannot convert from 'layout( column_major scalar offset=548) uniform highp float' to ' temp highp int'"
        #expect(ImplicitConversionFixer.fix(source: source, log: log) == "int a;\na = int(g_Value * 2.0);")
    }

    @Test func castsArgumentsOfUserFunctions() {
        let source = "vec2 rotateVec2(vec2 v, float r)\n{ return v; }\nvoid main() { vec2 c = rotateVec2(v_TexCoord, - u_direction + 1.5) * u_scale; }"
        let log = "ERROR: 0:3: 'rotateVec2' : no matching overloaded function found \nERROR: 0:3: '=' :  cannot convert from ' const float' to ' temp highp 2-component vector of float'"
        let fixed = ImplicitConversionFixer.fix(source: source, log: log)
        #expect(fixed?.contains("rotateVec2(vec2(v_TexCoord), float(- u_direction + 1.5)) * u_scale") == true)
    }

    @Test func castsOnlyTheInitializerOfForLoops() {
        #expect(ImplicitConversionFixer.castAssignment("\tfor (int i = u_Min; i < u_Max; i ++) {", to: "int")
            == "\tfor (int i = int(u_Min); i < u_Max; i ++) {")
        #expect(ImplicitConversionFixer.castAssignment("a = 1; b = 2;", to: "int") == nil)
    }

    @Test func fixesBuiltinCallsWithIntegerLiterals() {
        let log = "ERROR: 0:1: 'max' : no matching overloaded function found "
        #expect(ImplicitConversionFixer.fix(source: "c = vec4(max(0, albedo.rgb), 1.0);", log: log)
            == "c = vec4(max(albedo.rgb, 0.0), 1.0);")
        #expect(ImplicitConversionFixer.floatLiteralArguments("x = clamp(v, 0, 1);", function: "clamp") == "x = clamp(v, 0.0, 1.0);")
        #expect(ImplicitConversionFixer.floatLiteralArguments("x = clamp(v, 0.0, 1.0);", function: "clamp") == nil)
    }

    @Test func leavesComparisonsAndUnknownErrorsAlone() {
        #expect(ImplicitConversionFixer.castAssignment("if (a == b) c = d;", to: "vec2") == "if (a == b) c = vec2(d);")
        #expect(ImplicitConversionFixer.fix(source: "x", log: "ERROR: 0:1: 'foo' : undeclared identifier") == nil)
        #expect(ImplicitConversionFixer.glslType("temp highp 3-component vector of int") == "ivec3")
    }

    /// WE 的方言按 HLSL 来，浮点也能取模（`%`）；GLSL 只允许整数。按报错那一行改成 mod()
    @Test func fixesFloatingPointModulo() {
        let log = "ERROR: 0:1: '%' :  wrong operand types: no operation '%' exists that takes a "
            + "left-hand operand of type ' temp highp float' and a right operand of type ' const int'"
        let fixed = ImplicitConversionFixer.fix(source: "uint barFreq = frequency % RESOLUTION;", log: log)
        #expect(fixed == "uint barFreq = mod(frequency, float(RESOLUTION));", "得到 \(fixed ?? "nil")")
        // 括号里的左操作数要整个取出来
        #expect(ImplicitConversionFixer.rewriteModulo("\tuint b = (a + 1) % RESOLUTION;")
            == "\tuint b = mod((a + 1), float(RESOLUTION));")
        #expect(ImplicitConversionFixer.rewriteModulo("float x = 1.0;") == nil)
    }

    /// 真实的报错形态：glslang 把多声明符里的隐式转换报成"未声明标识符"（token 是空的）
    @Test func fixesMultiDeclaratorThroughTheError() {
        let log = "ERROR: 0:1: '' :  undeclared identifier "
        let fixed = ImplicitConversionFixer.fix(source: "vec4 color = 0, color_2 = 0;", log: log)
        #expect(fixed != nil, "应当把这一行拆开")
        #expect(ImplicitConversionFixer.parseErrors(log).first?.message.contains("undeclared") == true)
    }

    /// 一行多个声明符：`vec4 color = 0, color_2 = 0;` 拆成两条，各自的初始化转换才能补上
    @Test func splitsMultiDeclaratorStatements() {
        #expect(ImplicitConversionFixer.splitDeclaration("    vec4 color =0,color_2=0;")
            == "    vec4 color =0;\n    vec4 color_2=0;")
        #expect(ImplicitConversionFixer.splitDeclaration("a = b, c = d;") == nil)
        #expect(ImplicitConversionFixer.splitDeclaration("mix(a, b, c);") == nil)
    }

    /// HLSL 会把内置函数的参数截断（`mix(vec4, vec3, float)`），GLSL 不认：
    /// 按源码里声明过的维度，把最长的参数截短
    @Test func truncatesVectorArgumentsOfBuiltins() {
        let source = """
        void main() {
        	vec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
        	vec3 newAlbedo = hsv2rgb(albedo.rgb);
        	float mask = 1.0;
        	albedo.rgb = mix(albedo, newAlbedo, mask);
        }
        """
        let truncated = ImplicitConversionFixer.truncateArguments(
            "\talbedo.rgb = mix(albedo, newAlbedo, mask);", function: "mix", in: source)
        #expect(truncated == "\talbedo.rgb = mix(albedo.rgb, newAlbedo, mask);", "得到 \(truncated ?? "nil")")
    }

    /// 真实语料（workshop/2973943998 iris_movement__.vert）：HLSL 允许 `vec4 * vec2`，
    /// 按较大的维度算、多出来的分量丢掉；GLSL 报 "wrong operand types"。
    /// 从报错里读出两侧维度，把较大的操作数截短。
    @Test func truncatesVectorOperandsOfBinaryOperators() {
        let source = """
        uniform vec2 g_CursorScale;
        void main() {
        	vec4 transformedCursorPosition = vec4(0.0);
        	vec2 da = transformedCursorPosition * g_CursorScale * 0.001;
        }
        """
        let line = "\tvec2 da = transformedCursorPosition * g_CursorScale * 0.001;"
        let message = "wrong operand types: no operation '*' exists that takes a left-hand operand of type"
            + " ' temp highp 4-component vector of float' and a right operand of type"
            + " 'layout( column_major scalar offset=68) uniform highp 2-component vector of float'"
        #expect(ImplicitConversionFixer.vectorSizes(in: message) == [4, 2])
        #expect(ImplicitConversionFixer.truncateOperandsForOperator(
            line, symbol: "*", message: message, in: source)
            == "\tvec2 da = transformedCursorPosition.xy * g_CursorScale * 0.001;")
        // 同维度的报错（矩阵乘向量）不动，留给别的机制处理
        #expect(ImplicitConversionFixer.truncateOperandsForOperator(
            line, symbol: "*", message: "wrong operand types: 4-component vector of float",
            in: source) == nil)
    }
}
