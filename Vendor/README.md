# 随项目一起编译的第三方库

`Vendor/` 里放三样东西：把 WE 的着色器翻成 Metal 要用的着色器编译器（glslang、SPIRV-Cross），
以及解 Steam 的分块容器要用的 zstd 解压器和 LZMA 解码器。

## glslang 与 SPIRV-Cross（着色器编译器）

场景特效要把 WE 的着色器方言翻成 Metal，中间经过两个第三方库：

- **glslang**：GLSL → SPIR-V（含预处理、GLSL/HLSL 前端、SPIR-V 生成）；
- **SPIRV-Cross**：SPIR-V → Metal（我们用它的 MSL 后端）。

以前这两个库用 Homebrew 装的（`brew install glslang spirv-cross`）：别人的机器上没有，而且 Homebrew 的构建
是面向 macOS 15 的，链接时会警告、也可能出兼容问题。现在把源码放进 `Vendor/`，跟着项目一起编译 —— 只要
Swift 工具链，不需要额外安装任何东西。

## 来源

| 目录 | 上游 | 版本 | 提交 |
|---|---|---|---|
| `glslang/` | https://github.com/KhronosGroup/glslang | `16.6.0` | `e1b562a8bed273a02f30b59b66a5d499793cede5` |
| `SPIRV-Cross/` | https://github.com/KhronosGroup/SPIRV-Cross | `vulkan-sdk-1.4.357.0` | `6c09849fe88c48eaed08413aa022aaa136a3a057` |
| `zstd/` | https://github.com/facebook/zstd | `v1.5.7` | tag `v1.5.7` |

许可证：glslang 的主体是 BSD-3-Clause，个别文件是 MIT / Apache-2.0（`glslang/LICENSE.txt` 里逐项列出，
预处理部分另有说明）；SPIRV-Cross 是 Apache-2.0（`SPIRV-Cross/LICENSE`）；zstd 是 BSD-3-Clause（见下）。
都是宽松许可，可以随产品分发；三个许可文件都原样保留在各自目录里。

例外要注意：`glslang/glslang/MachineIndependent/glslang_tab.cpp`（及 `.h`）是 GNU Bison 3.8.2 生成的解析器，
许可是 **GPL-3.0 附 Bison 特别例外**（文件开头第 21–32 行）：例外允许把解析器骨架作为更大作品的一部分、
按自己选的条款分发，条件是这个作品本身不是拿该骨架做解析器生成器（本项目不是），所以不会让整个产品变成 GPL。
不要删改这两个文件开头的许可和例外声明——删掉例外声明，文件就只剩 GPL-3.0。

SPIR-V 的头文件不需要单独引入：glslang 自带 `SPIRV/spirv.hpp11`、`SPIRV/GLSL.std.450.h`，
SPIRV-Cross 自带根目录的 `spirv.hpp` / `spirv.h`。

## 着色器编译器：拷了什么、没拷什么

只拷了两个库**本身**，以及它们的许可文件：

- glslang：`glslang/`（前端、MachineIndependent、GenericCodeGen、ResourceLimits、OSDependent/Unix、
  CInterface、HLSL）、`SPIRV/`（SPIR-V 生成与 C 接口）、`StandAlone/DirStackFileIncluder.h`
  （C 接口用它做 `#include` 解析；
  **不拷** StandAlone 的命令行程序）、`LICENSE.txt`；
- SPIRV-Cross：根目录的 `spirv_*.cpp` / `spirv_*.hpp` / `spirv_cross_c.h` / `spirv.h` / `spirv.hpp` /
  `GLSL.std.450.h`、`include/spirv_cross/`（给 C++ 嵌入用的接口头，我们不编译）、`LICENSE`。

**没拷**：两个库的测试（`Test/`、`gtests/`、`shaders*/`、`tests-other/`）、命令行工具（`StandAlone/`、
`main.cpp`）、构建脚本（CMake、gn、Android、Makefile）和 CI 配置。`Package.swift` 用 `exclude` 把剩下的
非源码文件（CMakeLists、`.y` 语法文件、Windows/Web 平台的 OSDependent、`.natvis`）排除掉。

## zstd（Steam 分块的解压器）

Steam 内容服务器上的分块外面包着 `VSZa` 容器，里面是 zstd 压出来的数据（见
`docs/M7.5-原生Steam客户端.md`）。macOS 系统里没有 libzstd（只有 Homebrew 装才有），所以照
`glslang` / `SPIRV-Cross` 的办法把上游源码放进 `Vendor/zstd/`，跟着项目一起编译：

- 只要**解压**，不要压缩：`lib/common/`（`debug.c`、`entropy_common.c`、`error_private.c`、
  `fse_decompress.c`、`zstd_common.c`、`xxhash.c` 及其头文件）与 `lib/decompress/`
  （`huf_decompress.c`、`zstd_ddict.c`、`zstd_decompress.c`、`zstd_decompress_block.c`），
  再加 `lib/zstd.h`、`lib/zstd_errors.h`、`LICENSE`。这份清单就是上游
  `build/single_file_libs/zstddeclib-in.c` 里"解码器需要哪些文件"的那一份；
- 没拷：命令行工具（`programs/`）、压缩实现（`lib/compress/`）、词典构建、测试、
  x86-64 汇编版 huf 解码循环（`huf_decompress_amd64.S`，`Package.swift` 里用
  `ZSTD_DISABLE_ASM=1` 关掉）；
- `Vendor/zstd/module.modulemap` 是我们写的：只把 `lib/zstd.h` 暴露给 Swift。

许可证：`LICENSE` 里是 BSD-3-Clause / GPLv2 双许可（我们选 BSD-3-Clause），原样保留。

## LZMA 解码器（Steam 旧分块的 `VZa` 容器）

旧一些的创意工坊内容，分块外面是 `VZa` 容器，里面是 LZMA（不是 zstd）。macOS SDK 里的 liblzma 没有头文件
（系统私用），所以和 zstd 一样把解码器源码放进 `Vendor/lzma/` 随项目编译：

| 目录 | 上游 | 版本 | 文件 |
|---|---|---|---|
| `lzma/` | https://github.com/ip7z/7zip（7-Zip 官方仓库里的 LZMA SDK，`C/` 目录） | `26.03` | `LzmaDec.c`、`LzmaDec.h`、`7zTypes.h`、`Precomp.h`、`Compiler.h` |

许可证：这五个文件开头都写着 **"Igor Pavlov : Public domain"**（公有领域），可以随产品分发。
只拷了解码器，没有编码器、没有 7-Zip 本身的其它代码（7-Zip 程序本体是 LGPL，和这里无关）。
`Vendor/lzma/module.modulemap` 是我们写的：只把 `LzmaDec.h` 暴露给 Swift（`import CLzma`）。

```bash
for f in LzmaDec.c LzmaDec.h 7zTypes.h Precomp.h Compiler.h; do
  curl -L -o Vendor/lzma/$f https://raw.githubusercontent.com/ip7z/7zip/<版本>/C/$f
done
```

## 我们另外补的文件

上游用 CMake 生成、源码树里没有的两个头，随源码编译时写死：

- `glslang/glslang/build_info.h`：用上游 `build_info.py` 从 `build_info.h.tmpl` 生成
  （版本 16.6.0）；
- `SPIRV-Cross/gitversion.h`：对应上游 `cmake/gitversion.in.h`，内容就是版本字符串。

`Vendor/*/module.modulemap` 是我们写的：只把 **C 接口**（`glslang_c_interface.h`、
`resource_limits_c.h`、`spirv_cross_c.h`）暴露给 Swift。库内部的头文件大量是 C++，如果一起丢进模块，
Swift 的 Clang 导入器会当成 C 去解析、报 `<string> file not found`。

编译开关在根目录 `Package.swift` 里：

- glslang：`GLSLANG_OSINCLUDE_UNIX`、`ENABLE_HLSL`（C 接口支持 HLSL 输入，链接时要用到）、
  `ENABLE_OPT=0`（不用 SPIRV-Tools 的优化后端）；
- SPIRV-Cross：`SPIRV_CROSS_C_API_{GLSL,HLSL,MSL,CPP,REFLECT}=1`（上游 CMake 按"编了哪些后端"
  给 C 接口打开对应开关，我们真正用的是 MSL）；
- 整个包用 `cxxLanguageStandard: .cxx17`（两个库都要求 C++17）。

## 怎么更新

```bash
git clone --depth 1 --branch <新版本标签> https://github.com/KhronosGroup/glslang /tmp/glslang
git clone --depth 1 --branch vulkan-sdk-<版本> https://github.com/KhronosGroup/SPIRV-Cross /tmp/SPIRV-Cross
# 按上面"拷了什么"覆盖 Vendor/ 下对应文件，再重新生成两个头：
python3 /tmp/glslang/build_info.py /tmp/glslang -i /tmp/glslang/build_info.h.tmpl \
    -o Vendor/glslang/glslang/build_info.h

# zstd 只要 lib/ 下解压需要的那几个文件，照"zstd（Steam 分块的解压器）"一节列的清单拷：
git clone --depth 1 --branch v1.5.7 https://github.com/facebook/zstd /tmp/zstd
```

更新后要跑 `swift test`（`ShaderCompilerTests` 里有用真实 WE 着色器的端到端翻译和渲染核对），
再用 `WallpaperTool render-scenes` 跑一遍本机场景，对比差异有没有变化；Steam 那部分用
`WallpaperTool steam-ugc … --verify <SteamCMD 下好的目录>` 核对分块解压还是逐字节一致。
