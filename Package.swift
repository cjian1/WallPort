// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacWallpaper",
    platforms: [.macOS(.v14)],
    targets: [
        // 第三方着色器编译器：源码随项目一起编译（见 Vendor/README.md），不依赖 Homebrew
        .target(
            name: "glslang",
            path: "Vendor/glslang",
            exclude: [
                "LICENSE.txt",
                "glslang/CMakeLists.txt",
                "glslang/MachineIndependent/glslang.y",
                "glslang/updateGrammar",
                "glslang/OSDependent/Windows",
                "glslang/OSDependent/Web",
                "SPIRV/CMakeLists.txt",
            ],
            publicHeadersPath: ".",
            cxxSettings: [
                .define("GLSLANG_OSINCLUDE_UNIX"),
                // HLSL 前端（C 接口支持 HLSL 输入，链接时需要）
                .define("ENABLE_HLSL"),
                // 不用 SPIRV-Tools 的优化后端
                .define("ENABLE_OPT", to: "0"),
            ]),
        .target(
            name: "SPIRVCross",
            path: "Vendor/SPIRV-Cross",
            exclude: ["LICENSE", "include"],
            publicHeadersPath: ".",
            cxxSettings: [
                // 上游的 CMake 按"编了哪些后端"给 C 接口打开对应的开关，这里四个后端都编进来了；
                // MSL 是我们真正用的，其余几个是 C 接口里互相引用需要
                .define("SPIRV_CROSS_C_API_GLSL", to: "1"),
                .define("SPIRV_CROSS_C_API_HLSL", to: "1"),
                .define("SPIRV_CROSS_C_API_MSL", to: "1"),
                .define("SPIRV_CROSS_C_API_CPP", to: "1"),
                .define("SPIRV_CROSS_C_API_REFLECT", to: "1"),
            ]),
        // 呈现层：每块显示器一个桌面层窗口，跟随显示器变化同步，并自检窗口是否真的在屏幕上
        .target(name: "DesktopHost"),
        // 库与素材层：逐屏的壁纸分配；创意工坊的原生流程（登录/订阅/下载）直接用 SteamProtocol
        .target(name: "WallpaperLibrary", dependencies: ["SteamProtocol", "DesktopHost"]),
        // 格式层：scene.pkg、TEX 纹理等 WE 文件格式的读取，不依赖任何渲染代码
        .target(name: "WallpaperFormats"),
        // WE 着色器方言的翻译：读取接口、拼装、改写成可编成 SPIR-V 的 GLSL
        .target(name: "ShaderTranslation"),
        // glslang 与 SPIRV-Cross 的 C 接口（薄薄一层，把两个库的头文件暴露给 Swift）
        .target(
            name: "CShaderCompilers", dependencies: ["glslang", "SPIRVCross"],
            path: "Sources/CShaderCompilers", publicHeadersPath: "include"),
        // zstd 解压：Steam 的分块容器（"VSZa"）用的就是它。只编解压需要的部分，见 Vendor/README.md
        .target(
            name: "CZstd",
            path: "Vendor/zstd",
            exclude: ["LICENSE"],
            publicHeadersPath: ".",
            cSettings: [
                // 只随项目编译解码器：汇编版 huf 解码循环、旧格式（0.1–0.7 的帧）和追踪钩子都不带
                .define("ZSTD_DISABLE_ASM", to: "1"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
                .define("ZSTD_TRACE", to: "0"),
                .define("DEBUGLEVEL", to: "0"),
            ]),
        // LZMA 解压：Steam 旧内容的分块容器（"VZa"）用它。只有 LZMA SDK 的解码器（公有领域），见 Vendor/README.md
        .target(
            name: "CLzma",
            path: "Vendor/lzma",
            publicHeadersPath: "."),
        // 在进程内把 WE 着色器翻译成 Metal 源码
        .target(name: "ShaderCompiler", dependencies: ["CShaderCompilers", "ShaderTranslation"]),
        // Steam 客户端协议（M7.5）：CM 的 WebSocket 连接、登录、订阅与 UGC 下载，不依赖 SteamCMD
        .target(name: "SteamProtocol", dependencies: ["CZstd", "CLzma"]),
        // 场景渲染：Metal 绘制场景图层，以及挂到桌面窗口上的场景内容
        .target(
            name: "SceneRenderer",
            dependencies: ["DesktopHost", "WallpaperFormats", "ShaderCompiler", "ShaderTranslation"]),
        // 视频壁纸：AVFoundation 硬件解码、无缝循环、遮挡时暂停
        .target(name: "VideoWallpaper", dependencies: ["DesktopHost"]),
        // 网页壁纸：WKWebView 加载项目文件夹，注入与 WE 网页壁纸接口兼容的脚本
        .target(name: "WebWallpaper", dependencies: ["DesktopHost"]),
        // 菜单栏应用外壳
        .executableTarget(
            name: "MacWallpaperApp",
            dependencies: ["DesktopHost", "WallpaperLibrary", "VideoWallpaper", "WebWallpaper", "SceneRenderer"]),
        // 命令行工具：批量检查视频能否播放、查看和解包 scene.pkg 等
        .executableTarget(
            name: "WallpaperTool",
            dependencies: [
                "VideoWallpaper", "WallpaperFormats", "WallpaperLibrary", "SceneRenderer", "ShaderTranslation", "ShaderCompiler",
                "SteamProtocol", "WebWallpaper",
            ]),
        .testTarget(name: "DesktopHostTests", dependencies: ["DesktopHost"]),
        .testTarget(name: "WallpaperLibraryTests", dependencies: ["WallpaperLibrary", "SteamProtocol"]),
        .testTarget(name: "WebWallpaperTests", dependencies: ["WebWallpaper"]),
        .testTarget(name: "WallpaperFormatsTests", dependencies: ["WallpaperFormats"]),
        .testTarget(name: "ShaderTranslationTests", dependencies: ["ShaderTranslation"]),
        .testTarget(name: "SteamProtocolTests", dependencies: ["SteamProtocol"]),
        .testTarget(
            name: "ShaderCompilerTests", dependencies: ["ShaderCompiler", "ShaderTranslation"]),
        .testTarget(
            name: "SceneRendererTests", dependencies: ["SceneRenderer", "WallpaperFormats", "DesktopHost"]),
        // 壁纸库界面的布局检查（假项目、不加载缩略图、不联网）
        .testTarget(name: "MacWallpaperAppTests", dependencies: ["MacWallpaperApp", "WallpaperLibrary"]),
    ],
    // glslang 和 SPIRV-Cross 都要求 C++17
    cxxLanguageStandard: .cxx17
)
