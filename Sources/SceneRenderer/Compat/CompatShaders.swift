/// 着色器和公共头文件（WE 方言的 GLSL，和场景包里的着色器走同一条翻译流水线）。
///
/// 场景包里拷着 WE 的特效着色器，它们 `#include` 下面这些头文件；接口（名字、参数、含义）必须和 WE 一致，
/// 实现是自己写的。每个约定怎么来的写在旁边：场景包里的用法，或者 `WallpaperTool probe-effect`
/// 量出来的行为（只看输出）
enum CompatShaders {
    static let files: [String: String] = [
        "shaders/common.h": common,
        "shaders/common_blending.h": blending,
        "shaders/common_perspective.h": perspective,
        "shaders/common_blur.h": blur,
        "shaders/common_composite.h": composite,
        "shaders/common_fragment.h": fragment,
        "shaders/common_vertex.h": vertex,
        "shaders/genericparticle.vert": particleVertex,
        "shaders/genericparticle.frag": particleFragment,
        "shaders/downsample_quarter_bloom.vert": bloomVertex,
        "shaders/downsample_quarter_bloom.frag": bloomBrightPass,
        "shaders/downsample_eighth_blur_v.vert": bloomVertex,
        "shaders/downsample_eighth_blur_v.frag": bloomBlur(horizontal: true),
        "shaders/blur_h_bloom.vert": bloomVertex,
        "shaders/blur_h_bloom.frag": bloomBlur(horizontal: false),
        "shaders/combine.vert": bloomVertex,
        "shaders/combine.frag": bloomCombine,
    ]

    static let common = """
        // 壁坞兼容素材：WE 着色器常用的常量和小函数（自己写的实现）
        #ifndef COMPAT_COMMON_H
        #define COMPAT_COMMON_H

        // 写法和场景包里着色器自己重复定义时最常见的一样（预处理器只接受文字完全相同的重复定义）
        #define M_PI 3.14159265359
        // 在 WE 的着色器里是 2π：frac(t / M_PI_2) * M_PI_2、(atan2(y, x) + M_PI) / M_PI_2 落在 0–1
        #define M_PI_2 6.28318530718

        // 逆时针转 angle 弧度
        vec2 rotateVec2(vec2 v, float angle) {
            float s = sin(angle);
            float c = cos(angle);
            return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
        }

        // 量出来的权重：红 0.11、绿 0.59、蓝 0.30（和常见的 0.30/0.59/0.11 反过来，照 WE 的行为）
        float greyscale(vec3 color) {
            return dot(color, vec3(0.11, 0.59, 0.30));
        }

        // HSV ↔ RGB，三个分量都在 0–1（色相按圈数）
        vec3 hsv2rgb(vec3 hsv) {
            vec3 k = clamp(abs(fract(hsv.x + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
            return hsv.z * mix(vec3(1.0), k, hsv.y);
        }

        vec3 rgb2hsv(vec3 rgb) {
            float high = max(rgb.r, max(rgb.g, rgb.b));
            float low = min(rgb.r, min(rgb.g, rgb.b));
            float delta = high - low;
            float hue = 0.0;
            if (delta > 0.0) {
                if (high == rgb.r) {
                    hue = (rgb.g - rgb.b) / delta;
                } else if (high == rgb.g) {
                    hue = (rgb.b - rgb.r) / delta + 2.0;
                } else {
                    hue = (rgb.r - rgb.g) / delta + 4.0;
                }
                hue = fract(hue / 6.0 + 1.0);
            }
            return vec3(hue, high > 0.0 ? delta / high : 0.0, high);
        }

        #endif
        """

    /// 混合模式：编号和壁坞图层混合（LayerShaders.apply_blend）同一套，公式是公开的标准混合公式
    static let blending = """
        // 壁坞兼容素材：图层混合模式（自己写的实现，和壁坞图层混合的 Metal 版本同一套公式）
        #ifndef COMPAT_BLENDING_H
        #define COMPAT_BLENDING_H

        float compatColorDodge(float a, float b) { return b >= 1.0 ? 1.0 : min(a / (1.0 - b), 1.0); }
        float compatColorBurn(float a, float b) { return b <= 0.0 ? 0.0 : max(1.0 - (1.0 - a) / b, 0.0); }
        float compatOverlay(float a, float b) { return a < 0.5 ? 2.0 * a * b : 1.0 - 2.0 * (1.0 - a) * (1.0 - b); }
        float compatSoftLight(float a, float b) {
            return b < 0.5 ? 2.0 * a * b + a * a * (1.0 - 2.0 * b) : sqrt(a) * (2.0 * b - 1.0) + 2.0 * a * (1.0 - b);
        }
        float compatVividLight(float a, float b) {
            return b < 0.5 ? compatColorBurn(a, 2.0 * b) : compatColorDodge(a, 2.0 * (b - 0.5));
        }
        float compatLinearLight(float a, float b) { return b < 0.5 ? max(a + 2.0 * b - 1.0, 0.0) : a + 2.0 * (b - 0.5); }
        float compatPinLight(float a, float b) { return b < 0.5 ? min(a, 2.0 * b) : max(a, 2.0 * (b - 0.5)); }
        float compatHardMix(float a, float b) { return compatVividLight(a, b) < 0.5 ? 0.0 : 1.0; }
        float compatReflect(float a, float b) { return b >= 1.0 ? 1.0 : min(a * a / (1.0 - b), 1.0); }

        #define COMPAT_PER_CHANNEL(f, lhs, rhs) vec3(f((lhs).r, (rhs).r), f((lhs).g, (rhs).g), f((lhs).b, (rhs).b))

        vec3 compatRgbToHsl(vec3 c) {
            float high = max(max(c.r, c.g), c.b);
            float low = min(min(c.r, c.g), c.b);
            float lightness = (high + low) * 0.5;
            float delta = high - low;
            if (delta <= 0.0) return vec3(0.0, 0.0, lightness);
            float saturation = lightness < 0.5 ? delta / (high + low) : delta / (2.0 - high - low);
            float hue;
            if (high == c.r) hue = (c.g - c.b) / delta + (c.g < c.b ? 6.0 : 0.0);
            else if (high == c.g) hue = (c.b - c.r) / delta + 2.0;
            else hue = (c.r - c.g) / delta + 4.0;
            return vec3(hue / 6.0, saturation, lightness);
        }

        float compatHueToRgb(float p, float q, float t) {
            t = fract(t);
            if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
            if (t < 0.5) return q;
            if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
            return p;
        }

        vec3 compatHslToRgb(vec3 hsl) {
            if (hsl.y <= 0.0) return vec3(hsl.z);
            float q = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : hsl.z + hsl.y - hsl.z * hsl.y;
            float p = 2.0 * hsl.z - q;
            return vec3(compatHueToRgb(p, q, hsl.x + 1.0 / 3.0), compatHueToRgb(p, q, hsl.x),
                        compatHueToRgb(p, q, hsl.x - 1.0 / 3.0));
        }

        // 单个混合函数（BlendOpacity 的第三个参数传这些名字）
        vec3 BlendNormal(vec3 a, vec3 b) { return b; }
        vec3 BlendDarken(vec3 a, vec3 b) { return min(a, b); }
        vec3 BlendMultiply(vec3 a, vec3 b) { return a * b; }
        vec3 BlendColorBurn(vec3 a, vec3 b) { return COMPAT_PER_CHANNEL(compatColorBurn, a, b); }
        vec3 BlendLinearBurn(vec3 a, vec3 b) { return max(a + b - 1.0, 0.0); }
        vec3 BlendSubtract(vec3 a, vec3 b) { return max(a + b - 1.0, 0.0); }
        vec3 BlendLighten(vec3 a, vec3 b) { return max(a, b); }
        vec3 BlendScreen(vec3 a, vec3 b) { return 1.0 - (1.0 - a) * (1.0 - b); }
        vec3 BlendColorDodge(vec3 a, vec3 b) { return COMPAT_PER_CHANNEL(compatColorDodge, a, b); }
        vec3 BlendLinearDodge(vec3 a, vec3 b) { return min(a + b, 1.0); }
        vec3 BlendAdd(vec3 a, vec3 b) { return min(a + b, 1.0); }
        vec3 BlendOverlay(vec3 a, vec3 b) { return COMPAT_PER_CHANNEL(compatOverlay, a, b); }
        vec3 BlendSoftLight(vec3 a, vec3 b) { return COMPAT_PER_CHANNEL(compatSoftLight, a, b); }
        vec3 BlendHardLight(vec3 a, vec3 b) { return COMPAT_PER_CHANNEL(compatOverlay, b, a); }
        vec3 BlendVividLight(vec3 a, vec3 b) { return COMPAT_PER_CHANNEL(compatVividLight, a, b); }
        vec3 BlendLinearLight(vec3 a, vec3 b) { return COMPAT_PER_CHANNEL(compatLinearLight, a, b); }
        vec3 BlendPinLight(vec3 a, vec3 b) { return COMPAT_PER_CHANNEL(compatPinLight, a, b); }
        vec3 BlendHardMix(vec3 a, vec3 b) { return COMPAT_PER_CHANNEL(compatHardMix, a, b); }
        vec3 BlendDifference(vec3 a, vec3 b) { return abs(a - b); }
        vec3 BlendExclusion(vec3 a, vec3 b) { return a + b - 2.0 * a * b; }
        vec3 BlendReflect(vec3 a, vec3 b) { return COMPAT_PER_CHANNEL(compatReflect, a, b); }
        vec3 BlendGlow(vec3 a, vec3 b) { return COMPAT_PER_CHANNEL(compatReflect, b, a); }
        vec3 BlendPhoenix(vec3 a, vec3 b) { return min(a, b) - max(a, b) + 1.0; }
        vec3 BlendAverage(vec3 a, vec3 b) { return (a + b) * 0.5; }
        vec3 BlendNegation(vec3 a, vec3 b) { return 1.0 - abs(1.0 - a - b); }
        vec3 BlendHue(vec3 a, vec3 b) {
            vec3 x = compatRgbToHsl(a);
            return compatHslToRgb(vec3(compatRgbToHsl(b).x, x.y, x.z));
        }
        vec3 BlendSaturation(vec3 a, vec3 b) {
            vec3 x = compatRgbToHsl(a);
            return compatHslToRgb(vec3(x.x, compatRgbToHsl(b).y, x.z));
        }
        vec3 BlendColor(vec3 a, vec3 b) {
            vec3 y = compatRgbToHsl(b);
            return compatHslToRgb(vec3(y.x, y.y, compatRgbToHsl(a).z));
        }
        vec3 BlendLuminosity(vec3 a, vec3 b) {
            vec3 x = compatRgbToHsl(a);
            return compatHslToRgb(vec3(x.x, x.y, compatRgbToHsl(b).z));
        }

        // 按透明度把混合结果和底色混起来：F(底色, 混合色) × O + 底色 × (1 − O)
        #define BlendOpacity(base, blend, F, O) (F(base, blend) * (O) + (base) * (1.0 - (O)))

        // 按 BLENDMODE 开关（编译时）选混合模式，再按透明度和底色混；5、10、31 号不按透明度混。
        // 第一个参数不起作用（量出来的行为：传别的数也按 BLENDMODE；没定义 BLENDMODE 时是正常模式），
        // 场景里的着色器传的都是 BLENDMODE
        vec3 ApplyBlending(const int mode, const vec3 a, const vec3 b, const float opacity) {
        #if BLENDMODE == 5
            return min(a, b);
        #elif BLENDMODE == 10
            return max(a, b);
        #elif BLENDMODE == 31
            return a + b * opacity;
        #else
        #if BLENDMODE == 1
            vec3 blended = min(a, b);
        #elif BLENDMODE == 2
            vec3 blended = a * b;
        #elif BLENDMODE == 3
            vec3 blended = BlendColorBurn(a, b);
        #elif BLENDMODE == 4 || BLENDMODE == 20
            vec3 blended = max(a + b - 1.0, 0.0);
        #elif BLENDMODE == 6
            vec3 blended = max(a, b);
        #elif BLENDMODE == 7
            vec3 blended = BlendScreen(a, b);
        #elif BLENDMODE == 8
            vec3 blended = BlendColorDodge(a, b);
        #elif BLENDMODE == 9
            vec3 blended = min(a + b, 1.0);
        #elif BLENDMODE == 11
            vec3 blended = BlendOverlay(a, b);
        #elif BLENDMODE == 12
            vec3 blended = BlendSoftLight(a, b);
        #elif BLENDMODE == 13
            vec3 blended = BlendHardLight(a, b);
        #elif BLENDMODE == 14
            vec3 blended = BlendVividLight(a, b);
        #elif BLENDMODE == 15
            vec3 blended = BlendLinearLight(a, b);
        #elif BLENDMODE == 16
            vec3 blended = BlendPinLight(a, b);
        #elif BLENDMODE == 17
            vec3 blended = BlendHardMix(a, b);
        #elif BLENDMODE == 18
            vec3 blended = abs(a - b);
        #elif BLENDMODE == 19
            vec3 blended = a + b - 2.0 * a * b;
        #elif BLENDMODE == 21
            vec3 blended = BlendReflect(a, b);
        #elif BLENDMODE == 22
            vec3 blended = BlendGlow(a, b);
        #elif BLENDMODE == 23
            vec3 blended = BlendPhoenix(a, b);
        #elif BLENDMODE == 24
            vec3 blended = (a + b) * 0.5;
        #elif BLENDMODE == 25
            vec3 blended = BlendNegation(a, b);
        #elif BLENDMODE == 26
            vec3 blended = BlendHue(a, b);
        #elif BLENDMODE == 27
            vec3 blended = BlendSaturation(a, b);
        #elif BLENDMODE == 28
            vec3 blended = BlendColor(a, b);
        #elif BLENDMODE == 29
            vec3 blended = BlendLuminosity(a, b);
        #elif BLENDMODE == 30
            vec3 blended = max(a.x, max(a.y, a.z)) * b;
        #elif BLENDMODE == 32
            vec3 blended = a + a * b;
        #else
            vec3 blended = b;
        #endif
            return mix(a, blended, opacity);
        #endif
        }

        #endif
        """

    /// 四边形透视（"透视"特效）：Heckbert 的正方形 → 四边形投影映射，(0,0)、(1,0)、(1,1)、(0,1) 依次对到 p0–p3。
    /// 矩阵按 WE 方言的 mul(v, M) 写法给出（GLSL 的列 = HLSL 的行）；求逆用 GLSL 内置的 inverse
    static let perspective = """
        // 壁坞兼容素材：四边形透视映射（自己写的实现）
        #ifndef COMPAT_PERSPECTIVE_H
        #define COMPAT_PERSPECTIVE_H

        mat3 squareToQuad(vec2 p0, vec2 p1, vec2 p2, vec2 p3) {
            float sx = p0.x - p1.x + p2.x - p3.x;
            float sy = p0.y - p1.y + p2.y - p3.y;
            float dx1 = p1.x - p2.x, dx2 = p3.x - p2.x;
            float dy1 = p1.y - p2.y, dy2 = p3.y - p2.y;
            float det = dx1 * dy2 - dx2 * dy1;
            float g = (sx * dy2 - dx2 * sy) / det;
            float h = (dx1 * sy - sx * dy1) / det;
            return mat3(p1.x - p0.x + g * p1.x, p1.y - p0.y + g * p1.y, g,
                        p3.x - p0.x + h * p3.x, p3.y - p0.y + h * p3.y, h,
                        p0.x, p0.y, 1.0);
        }

        #endif
        """

    /// 高斯模糊：σ = 2 的高斯按像素格积分、截成 3 / 7 / 13 格归一化，相邻两格合成一次双线性采样
    /// （公开的"线性采样"技巧）。g_Texture0 由调用的着色器声明；direction 是一格的纹理坐标步长
    static let blur = """
        // 壁坞兼容素材：一维高斯模糊（自己写的实现）
        #ifndef COMPAT_BLUR_H
        #define COMPAT_BLUR_H

        vec4 blur3a(vec2 uv, vec2 direction) {
            return texSample2D(g_Texture0, uv) * 0.5
                + (texSample2D(g_Texture0, uv + direction) + texSample2D(g_Texture0, uv - direction)) * 0.25;
        }

        vec4 blur7a(vec2 uv, vec2 direction) {
            vec4 color = texSample2D(g_Texture0, uv) * 0.2146072;
            vec2 near = direction * 1.4092019;
            vec2 far = direction * 3.0;
            color += (texSample2D(g_Texture0, uv + near) + texSample2D(g_Texture0, uv - near)) * 0.3213941;
            color += (texSample2D(g_Texture0, uv + far) + texSample2D(g_Texture0, uv - far)) * 0.0713028;
            return color;
        }

        vec4 blur13a(vec2 uv, vec2 direction) {
            vec4 color = texSample2D(g_Texture0, uv) * 0.1976410;
            vec2 o1 = direction * 1.4091966, o3 = direction * 3.2979343, o5 = direction * 5.2063286;
            color += (texSample2D(g_Texture0, uv + o1) + texSample2D(g_Texture0, uv - o1)) * 0.2959858;
            color += (texSample2D(g_Texture0, uv + o3) + texSample2D(g_Texture0, uv - o3)) * 0.0935337;
            color += (texSample2D(g_Texture0, uv + o5) + texSample2D(g_Texture0, uv - o5)) * 0.0116611;
            return color;
        }

        #endif
        """

    /// 合成方式（COMPOSITE 开关：0 正常、1 混合、2 置于下方、3 挖空；COMPOSITEMONO 先把新颜色变成灰度）。
    /// 各方式的结果是 `probe-effect` 量出来的
    static let composite = """
        // 壁坞兼容素材：把新算出的颜色和原来的颜色合成（自己写的实现）
        #ifndef COMPAT_COMPOSITE_H
        #define COMPAT_COMPOSITE_H
        #include "common.h"
        #include "common_blending.h"

        vec2 ApplyCompositeOffset(vec2 coords, vec2 resolution) {
            return coords;
        }

        vec4 ApplyComposite(vec4 previous, vec4 color) {
        #if COMPOSITEMONO
            color.rgb = CAST3(greyscale(color.rgb));
        #endif
        #if COMPOSITE == 1
            return vec4(ApplyBlending(BLENDMODE, previous.rgb, color.rgb, color.a), max(previous.a, color.a));
        #elif COMPOSITE == 2
            return mix(color, previous, previous.a);
        #elif COMPOSITE == 3
            return vec4(color.rgb, color.a * (1.0 - previous.a));
        #else
            return color;
        #endif
        }

        #endif
        """

    /// 贴图格式常量：和 TEX 里的格式编号一致（引擎按贴图格式设 TEXnFORMAT 开关，见粒子和特效的程序构建）
    static let fragment = """
        // 壁坞兼容素材：片元着色器的公共定义（自己写的）
        #ifndef COMPAT_FRAGMENT_H
        #define COMPAT_FRAGMENT_H
        #define FORMAT_RGBA8888 0
        #define FORMAT_DXT5 4
        #define FORMAT_DXT3 6
        #define FORMAT_DXT1 7
        #define FORMAT_RG88 8
        #define FORMAT_R8 9
        #endif
        """

    static let vertex = """
        // 壁坞兼容素材：顶点着色器的公共定义（场景包里用到它的着色器只是引用，没有用到里面的名字）
        #ifndef COMPAT_VERTEX_H
        #define COMPAT_VERTEX_H
        #endif
        """

    /// 粒子：每个粒子画成一个四边形，四个角共用粒子的数据（排列见 ParticleLayer）。
    /// 约定由 `WallpaperTool probe-particle` 对照量出：大小是直径；贴图正着贴（左上角是 uv (0,0)）
    static let particleVertex = """
        // 壁坞兼容素材：粒子的顶点着色器（自己写的实现）
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform vec3 g_OrientationRight;
        uniform vec3 g_OrientationUp;
        uniform vec3 g_OrientationForward;
        uniform vec3 g_EyePosition;
        // 拖尾：长度系数、最长、最短
        uniform vec4 g_RenderVar0;
        // 精灵图：一帧占的宽、高（纹理的比例）、帧数、帧的高宽比
        uniform vec4 g_RenderVar1;
        uniform vec4 g_Texture0Resolution;

        attribute vec3 a_Position;
        // 角的纹理坐标、绕 z 的旋转、大小
        attribute vec4 a_TexCoordVec4;
        attribute vec4 a_Color;
        #if THICKFORMAT
        // 绕 x、y 的旋转
        attribute vec2 a_TexCoordC2;
        // 速度、寿命进度（0–1）
        attribute vec4 a_TexCoordVec4C1;
        #endif

        varying vec2 v_TexCoord;
        varying vec4 v_Color;
        #if REFRACT
        // 裁剪坐标的 x、y、w：片元里换成"到这里为止的画面"上的取样位置
        varying vec3 v_ScreenCoord;
        // 粒子自己的 x、y 轴在画面上的方向：法线图里的偏移是按粒子自己的方向写的，跟着粒子转
        varying vec4 v_RefractAxes;
        #endif

        vec3 compatRotate(vec3 v, vec3 angles) {
            float sx = sin(angles.x), cx = cos(angles.x);
            float sy = sin(angles.y), cy = cos(angles.y);
            float sz = sin(angles.z), cz = cos(angles.z);
            // 绕 z 是顺时针（量出来的：屏幕上 y 向上时角度增大往顺时针转）
            v = vec3(cz * v.x + sz * v.y, -sz * v.x + cz * v.y, v.z);
            v = vec3(v.x, cx * v.y - sx * v.z, sx * v.y + cx * v.z);
            v = vec3(cy * v.x + sy * v.z, v.y, -sy * v.x + cy * v.z);
            return v;
        }

        // 折射偏移用的方向：先绕 y、再绕 x（角度取反）、最后绕 z（和顶点的旋转不是同一个顺序，量出来的）
        vec3 compatRotateNormal(vec3 v, vec3 angles) {
            float sx = sin(-angles.x), cx = cos(-angles.x);
            float sy = sin(angles.y), cy = cos(angles.y);
            float sz = sin(angles.z), cz = cos(angles.z);
            v = vec3(cy * v.x + sy * v.z, v.y, -sy * v.x + cy * v.z);
            v = vec3(v.x, cx * v.y - sx * v.z, sx * v.y + cx * v.z);
            v = vec3(cz * v.x + sz * v.y, -sz * v.x + cz * v.y, v.z);
            return v;
        }

        void main() {
            vec2 corner = a_TexCoordVec4.xy;
            float size = a_TexCoordVec4.w;
        #if THICKFORMAT
            vec3 angles = vec3(a_TexCoordC2.xy, a_TexCoordVec4.z);
        #else
            vec3 angles = vec3(0.0, 0.0, a_TexCoordVec4.z);
        #endif
            vec3 position = a_Position;
        #if TRAILRENDERER && THICKFORMAT
            vec3 velocity = a_TexCoordVec4C1.xyz;
            float speed = length(velocity);
            // 速度为 0 时方向是 NaN、这个粒子画不出来（和 WE 一样）
            vec3 along = velocity / speed;
            vec3 side = normalize(cross(along, g_EyePosition - a_Position));
            // 拖尾长度也按贴图的高宽比缩放（量出来的）
            float trail = clamp(speed * g_RenderVar0.x, g_RenderVar0.z, g_RenderVar0.y) * size * g_RenderVar1.w;
            position += side * (corner.x - 0.5) * size + along * (0.5 - corner.y) * trail;
        #else
            // 高度按贴图（精灵图是一帧）的高宽比拉伸
            vec3 offset = compatRotate(vec3((corner.x - 0.5) * size, (0.5 - corner.y) * size * g_RenderVar1.w, 0.0), angles);
            position += g_OrientationRight * offset.x + g_OrientationUp * offset.y + g_OrientationForward * offset.z;
        #endif
            gl_Position = mul(vec4(position, 1.0), g_ModelViewProjectionMatrix);
            v_Color = a_Color;
        #if REFRACT
            v_ScreenCoord = gl_Position.xyw;
        #if TRAILRENDERER && THICKFORMAT
            v_RefractAxes = vec4(side.xy, along.xy);
        #else
            vec3 axisX = compatRotateNormal(vec3(1.0, 0.0, 0.0), angles);
            vec3 axisY = compatRotateNormal(vec3(0.0, 1.0, 0.0), angles);
            v_RefractAxes = vec4(axisX.xy, axisY.xy);
        #endif
        #endif
        #if SPRITESHEET && THICKFORMAT
            float frameCount = g_RenderVar1.z;
            float frame = min(floor(a_TexCoordVec4C1.w * frameCount), frameCount - 1.0);
            // 帧按行排：帧号 × 帧宽，超过一行（有补齐边距时是图像占的宽度）就换到下一行（量出来的：
            // 帧宽是 102.5/512 这种除不尽的值时，一行放得下几帧以这个乘积为准）
            float frameOffset = frame * g_RenderVar1.x;
            float span = g_Texture0Resolution.z / g_Texture0Resolution.x;
            vec2 origin = vec2(mod(frameOffset, span), floor(frameOffset / span) * g_RenderVar1.y);
            v_TexCoord = origin + corner * g_RenderVar1.xy;
        #else
            // 整张贴图的 0–1（有补齐边距时补齐的部分也画出来，和 WE 一样）
            v_TexCoord = corner;
        #endif
        }
        """

    static let particleFragment = """
        // 壁坞兼容素材：粒子的片元着色器（自己写的实现）
        #include "common_fragment.h"

        uniform sampler2D g_Texture0; // {"material":"albedo","label":"ui_editor_properties_albedo","default":"particle/halo"}
        uniform float g_Overbright; // {"material":"ui_editor_properties_overbright","label":"ui_editor_properties_overbright","default":1.0,"range":[0,5]}
        #if CUTOUT
        uniform float g_CutoutStart; // {"material":"ui_editor_properties_cutout_start","label":"ui_editor_properties_cutout_start","default":0.1,"range":[0,1]}
        uniform float g_CutoutEnd; // {"material":"ui_editor_properties_cutout_end","label":"ui_editor_properties_cutout_end","default":0.2,"range":[0,1]}
        uniform float g_CutoutOpacity; // {"material":"ui_editor_properties_cutout_opacity","label":"ui_editor_properties_cutout_opacity","default":1.0,"range":[0,1]}
        #endif
        #if REFRACT
        // 折射：1 号槽是法线图（给了贴图时 NORMALMAP 开关自动打开），3 号槽是"到这里为止的画面"（上下翻转过）
        uniform sampler2D g_Texture1; // {"material":"normal","label":"ui_editor_properties_normal_map","format":"normalmap","formatcombo":true,"combo":"NORMALMAP","mode":"normal","require":{"REFRACT":1}}
        uniform sampler2D g_Texture3; // {"default":"_rt_FullFrameBuffer","hidden":true}
        uniform float g_RefractAmount; // {"material":"ui_editor_properties_refract_amount","label":"ui_editor_properties_refract_amount","default":0.05,"range":[-1,1]}
        varying vec3 v_ScreenCoord;
        varying vec4 v_RefractAxes;
        #endif

        varying vec2 v_TexCoord;
        varying vec4 v_Color;

        void main() {
            vec4 color = texSample2D(g_Texture0, v_TexCoord);
        #if TEX0FORMAT == FORMAT_R8
            color = vec4(1.0, 1.0, 1.0, color.r);
        #elif TEX0FORMAT == FORMAT_RG88
            color = vec4(color.rrr, color.g);
        #endif
            color *= v_Color;
        #if CUTOUT
            // 挖空：alpha 在起止阈值之间陡升（量出来的曲线）
            color.a = smoothstep(g_CutoutStart, g_CutoutEnd, color.a) * g_CutoutOpacity;
        #endif
            color.rgb *= g_Overbright;
        #if REFRACT
            vec2 offset = CAST2(0.0);
        #if NORMALMAP
            // 量出来的：偏移 = r × (2a − 1, 2g − 1) × 折射强度 × 粒子（顶点）的 alpha（法线的 x 在 alpha、y 在绿色通道，再乘红色通道）
            vec4 normal = texSample2D(g_Texture1, v_TexCoord);
            vec2 local = (normal.ag * 2.0 - 1.0) * normal.r * g_RefractAmount * v_Color.a;
            // 法线图的 y 朝贴图下方，也就是粒子自己 y 轴（朝上）的反方向
            offset = local.x * v_RefractAxes.xy - local.y * v_RefractAxes.zw;
        #endif
            vec2 screen = v_ScreenCoord.xy / v_ScreenCoord.z * 0.5 + 0.5 + offset;
            color.rgb *= texSample2D(g_Texture3, screen).rgb;
        #endif
            gl_FragColor = color;
        }
        """

    // MARK: 场景泛光（SceneBloom 依次跑这四个：提亮降采样 → 横向模糊 → 纵向模糊 → 加回画面）

    /// 整屏四边形：位置已经是裁剪坐标
    static let bloomVertex = """
        // 壁坞兼容素材：泛光各步的顶点着色器（自己写的）
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = vec4(a_Position, 1.0);
            v_TexCoord = a_TexCoord;
        }
        """

    /// 整帧 → 1/4：在 ±1 个整帧像素处取四个点平均（双线性，合起来是 4×4 平均），再提出亮的部分。
    /// 提亮的公式是对照 WE 的画面拟合出来的（`WallpaperTool probe-scene` 铺纯色量，误差在 8 位量化以内）：
    /// 每个通道 2·c²·(最大通道 − 阈值) / (最大通道 × (1 + 亮度))，再乘强度和色调
    static let bloomBrightPass = """
        // 壁坞兼容素材：泛光的提亮降采样（自己写的）
        uniform sampler2D g_Texture0;
        uniform vec2 g_TexelSize;
        uniform float g_BloomStrength;
        uniform float g_BloomThreshold;
        uniform vec3 g_BloomTint;
        varying vec2 v_TexCoord;
        void main() {
            vec3 color = (texSample2D(g_Texture0, v_TexCoord + g_TexelSize * vec2(-1.0, -1.0)).rgb
                + texSample2D(g_Texture0, v_TexCoord + g_TexelSize * vec2(1.0, -1.0)).rgb
                + texSample2D(g_Texture0, v_TexCoord + g_TexelSize * vec2(-1.0, 1.0)).rgb
                + texSample2D(g_Texture0, v_TexCoord + g_TexelSize * vec2(1.0, 1.0)).rgb) * 0.25;
            float high = max(color.r, max(color.g, color.b));
            float luminance = dot(color, vec3(0.299, 0.587, 0.114));
            vec3 bright = 2.0 * color * color * max(high - g_BloomThreshold, 0.0) / (max(high, 0.0001) * (1.0 + luminance));
            gl_FragColor = vec4(bright * g_BloomStrength * g_BloomTint, 1.0);
        }
        """

    /// 13 点高斯（σ = 2.3，按像素格积分后归一化；σ 是对照 WE 的画面量出来的：亮块洇出去的距离只差 1/255），
    /// 采样间隔是 8 个整帧像素
    static func bloomBlur(horizontal: Bool) -> String {
        let axis = horizontal ? "vec2(g_TexelSize.x * 8.0, 0.0)" : "vec2(0.0, g_TexelSize.y * 8.0)"
        return """
            // 壁坞兼容素材：泛光的模糊（自己写的）
            uniform sampler2D g_Texture0;
            uniform vec2 g_TexelSize;
            varying vec2 v_TexCoord;
            void main() {
                vec2 step = \(axis);
                vec4 color = texSample2D(g_Texture0, v_TexCoord) * 0.1729114;
                color += (texSample2D(g_Texture0, v_TexCoord + step) + texSample2D(g_Texture0, v_TexCoord - step)) * 0.1575496;
                color += (texSample2D(g_Texture0, v_TexCoord + step * 2.0) + texSample2D(g_Texture0, v_TexCoord - step * 2.0)) * 0.1191781;
                color += (texSample2D(g_Texture0, v_TexCoord + step * 3.0) + texSample2D(g_Texture0, v_TexCoord - step * 3.0)) * 0.0748434;
                color += (texSample2D(g_Texture0, v_TexCoord + step * 4.0) + texSample2D(g_Texture0, v_TexCoord - step * 4.0)) * 0.0390192;
                color += (texSample2D(g_Texture0, v_TexCoord + step * 5.0) + texSample2D(g_Texture0, v_TexCoord - step * 5.0)) * 0.0168871;
                color += (texSample2D(g_Texture0, v_TexCoord + step * 6.0) + texSample2D(g_Texture0, v_TexCoord - step * 6.0)) * 0.0060669;
                gl_FragColor = color;
            }
            """
    }

    /// 原画面 + 泛光（直接相加：量出来亮块洇到周围的量和底色无关）
    static let bloomCombine = """
        // 壁坞兼容素材：泛光加回画面（自己写的）
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        varying vec2 v_TexCoord;
        void main() {
            vec4 frame = texSample2D(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(frame.rgb + texSample2D(g_Texture1, v_TexCoord).rgb, frame.a);
        }
        """
}
