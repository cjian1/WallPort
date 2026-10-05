internal import CShaderCompilers
import Foundation
import ShaderTranslation

/// 在进程内调用 glslang 和 SPIRV-Cross：预处理、GLSL → SPIR-V、SPIR-V → Metal 源码。
///
/// glslang 的全局状态不保证线程安全，所有调用都串行执行。
public enum ShaderCompiler {
    public struct CompileError: Error, LocalizedError {
        public let step: String
        public let log: String

        public var errorDescription: String? { "\(step)失败：\(log)" }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var isInitialized = false

    /// 只做预处理：展开 #if 和宏
    public static func preprocess(_ source: String, stage: ShaderStage) throws -> String {
        try withShader(source, stage: stage) { shader, input in
            guard glslang_shader_preprocess(shader, &input) == 1 else {
                throw CompileError(step: "预处理", log: infoLog(shader))
            }
            return String(cString: glslang_shader_get_preprocessed_code(shader))
        }
    }

    /// 把 Vulkan 风格的 GLSL 450 编成 SPIR-V
    public static func spirv(_ source: String, stage: ShaderStage) throws -> [UInt32] {
        try withShader(source, stage: stage) { shader, input in
            guard glslang_shader_preprocess(shader, &input) == 1, glslang_shader_parse(shader, &input) == 1 else {
                throw CompileError(step: "编译成 SPIR-V", log: infoLog(shader))
            }
            guard let program = glslang_program_create() else { throw CompileError(step: "编译成 SPIR-V", log: "无法创建程序") }
            defer { glslang_program_delete(program) }
            glslang_program_add_shader(program, shader)
            let messages = Int32(GLSLANG_MSG_SPV_RULES_BIT.rawValue | GLSLANG_MSG_VULKAN_RULES_BIT.rawValue)
            guard glslang_program_link(program, messages) == 1 else {
                throw CompileError(step: "链接", log: String(cString: glslang_program_get_info_log(program)))
            }
            glslang_program_SPIRV_generate(program, input.stage)
            var words = [UInt32](repeating: 0, count: glslang_program_SPIRV_get_size(program))
            words.withUnsafeMutableBufferPointer { glslang_program_SPIRV_get(program, $0.baseAddress) }
            return words
        }
    }

    /// SPIR-V → Metal 源码。资源的 [[buffer]]/[[texture]]/[[sampler]] 编号直接用 GLSL 里的 binding，
    /// 入口函数叫 main0
    public static func metal(fromSPIRV words: [UInt32]) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        var context: spvc_context?
        guard spvc_context_create(&context) == SPVC_SUCCESS, let context else {
            throw CompileError(step: "转 Metal", log: "无法创建 SPIRV-Cross 上下文")
        }
        defer { spvc_context_destroy(context) }
        func fail() -> CompileError {
            CompileError(step: "转 Metal", log: String(cString: spvc_context_get_last_error_string(context)))
        }

        var ir: spvc_parsed_ir?
        let parsed = words.withUnsafeBufferPointer { spvc_context_parse_spirv(context, $0.baseAddress, $0.count, &ir) }
        guard parsed == SPVC_SUCCESS else { throw fail() }
        var compiler: spvc_compiler?
        guard spvc_context_create_compiler(context, SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler)
            == SPVC_SUCCESS
        else { throw fail() }
        var options: spvc_compiler_options?
        guard spvc_compiler_create_compiler_options(compiler, &options) == SPVC_SUCCESS else { throw fail() }
        // MSL 2.3，对应 macOS 11 起的 Metal
        spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_VERSION, 2 * 10000 + 3 * 100)
        spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING, spvc_bool(1))
        guard spvc_compiler_install_compiler_options(compiler, options) == SPVC_SUCCESS else { throw fail() }
        var result: UnsafePointer<CChar>?
        guard spvc_compiler_compile(compiler, &result) == SPVC_SUCCESS, let result else { throw fail() }
        return String(cString: result)
    }

    private static func withShader<T>(
        _ source: String, stage: ShaderStage,
        _ body: (OpaquePointer, inout glslang_input_t) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if !isInitialized {
            glslang_initialize_process()
            isInitialized = true
        }
        return try source.withCString { code in
            var input = glslang_input_t()
            input.language = GLSLANG_SOURCE_GLSL
            input.stage = stage == .vertex ? GLSLANG_STAGE_VERTEX : GLSLANG_STAGE_FRAGMENT
            input.client = GLSLANG_CLIENT_VULKAN
            input.client_version = GLSLANG_TARGET_VULKAN_1_1
            input.target_language = GLSLANG_TARGET_SPV
            input.target_language_version = GLSLANG_TARGET_SPV_1_3
            input.code = code
            input.default_version = 450
            input.default_profile = GLSLANG_NO_PROFILE
            input.messages = GLSLANG_MSG_DEFAULT_BIT
            input.resource = glslang_default_resource()
            guard let shader = glslang_shader_create(&input) else {
                throw CompileError(step: "创建着色器", log: "glslang 无法创建着色器")
            }
            defer { glslang_shader_delete(shader) }
            return try body(shader, &input)
        }
    }

    private static func infoLog(_ shader: OpaquePointer) -> String {
        String(cString: glslang_shader_get_info_log(shader)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
