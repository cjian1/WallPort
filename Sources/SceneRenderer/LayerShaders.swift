/// 图片图层和纯色层用的 Metal 着色器，是我们自己写的。
///
/// - 普通图层：输出 = 纹理采样 × 颜色（rgb 为图层颜色，a 为透明度），对齐 WE 图片着色器默认开关下的结果；
/// - 带图层混合模式（colorBlendMode）的图层：用 Apple GPU 的可编程混合直接读出帧缓冲里已有的颜色 A，
///   结果 = mix(A, F(A, B), 透明度)，B 为图层颜色。模式编号对应 WE 自带素材 common_blending.h 里的定义，
///   各模式的公式按公开的标准混合公式实现；5 和 10 号不受透明度影响，输出的 alpha 保持底层的值。
///
/// WE 自己的着色器（特效、光照、骨骼等）要经过方言翻译才能用，那是 M5 的事。
enum LayerShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct LayerVertex {
        float2 position [[attribute(0)]];
        float2 uv [[attribute(1)]];
    };

    struct LayerUniforms {
        float4x4 projection;
        float4 color;
        int4 mode;
    };

    struct LayerFragmentInput {
        float4 position [[position]];
        float2 uv;
    };

    vertex LayerFragmentInput layer_vertex(LayerVertex in [[stage_in]], constant LayerUniforms &uniforms [[buffer(1)]]) {
        LayerFragmentInput out;
        out.position = uniforms.projection * float4(in.position, 0.0, 1.0);
        out.uv = in.uv;
        return out;
    }

    fragment float4 image_fragment(
        LayerFragmentInput in [[stage_in]], constant LayerUniforms &uniforms [[buffer(1)]],
        texture2d<float> image [[texture(0)]], sampler imageSampler [[sampler(0)]]) {
        return image.sample(imageSampler, in.uv) * uniforms.color;
    }

    fragment float4 solid_fragment(LayerFragmentInput in [[stage_in]], constant LayerUniforms &uniforms [[buffer(1)]]) {
        return uniforms.color;
    }

    // MARK: 图层混合模式

    static float color_dodge(float a, float b) { return b >= 1.0 ? 1.0 : min(a / (1.0 - b), 1.0); }
    static float color_burn(float a, float b) { return b <= 0.0 ? 0.0 : max(1.0 - (1.0 - a) / b, 0.0); }
    static float overlay(float a, float b) { return a < 0.5 ? 2.0 * a * b : 1.0 - 2.0 * (1.0 - a) * (1.0 - b); }
    static float soft_light(float a, float b) {
        return b < 0.5 ? 2.0 * a * b + a * a * (1.0 - 2.0 * b) : sqrt(a) * (2.0 * b - 1.0) + 2.0 * a * (1.0 - b);
    }
    static float vivid_light(float a, float b) { return b < 0.5 ? color_burn(a, 2.0 * b) : color_dodge(a, 2.0 * (b - 0.5)); }
    static float linear_light(float a, float b) { return b < 0.5 ? max(a + 2.0 * b - 1.0, 0.0) : a + 2.0 * (b - 0.5); }
    static float pin_light(float a, float b) { return b < 0.5 ? min(a, 2.0 * b) : max(a, 2.0 * (b - 0.5)); }
    static float hard_mix(float a, float b) { return vivid_light(a, b) < 0.5 ? 0.0 : 1.0; }
    static float reflect(float a, float b) { return b >= 1.0 ? 1.0 : min(a * a / (1.0 - b), 1.0); }

    // 参数名不能叫 a、b：宏展开时会把分量 .b 也替换掉
    #define PER_CHANNEL(f, lhs, rhs) float3(f(lhs.r, rhs.r), f(lhs.g, rhs.g), f(lhs.b, rhs.b))

    static float3 rgb_to_hsl(float3 c) {
        float high = max(max(c.r, c.g), c.b);
        float low = min(min(c.r, c.g), c.b);
        float lightness = (high + low) * 0.5;
        float delta = high - low;
        if (delta <= 0.0) return float3(0.0, 0.0, lightness);
        float saturation = lightness < 0.5 ? delta / (high + low) : delta / (2.0 - high - low);
        float hue;
        if (high == c.r) hue = (c.g - c.b) / delta + (c.g < c.b ? 6.0 : 0.0);
        else if (high == c.g) hue = (c.b - c.r) / delta + 2.0;
        else hue = (c.r - c.g) / delta + 4.0;
        return float3(hue / 6.0, saturation, lightness);
    }

    static float hue_to_rgb(float p, float q, float t) {
        t = fract(t);
        if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
        if (t < 0.5) return q;
        if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
        return p;
    }

    static float3 hsl_to_rgb(float3 hsl) {
        if (hsl.y <= 0.0) return float3(hsl.z);
        float q = hsl.z < 0.5 ? hsl.z * (1.0 + hsl.y) : hsl.z + hsl.y - hsl.z * hsl.y;
        float p = 2.0 * hsl.z - q;
        return float3(hue_to_rgb(p, q, hsl.x + 1.0 / 3.0), hue_to_rgb(p, q, hsl.x), hue_to_rgb(p, q, hsl.x - 1.0 / 3.0));
    }

    static float3 apply_blend(int mode, float3 a, float3 b, float opacity) {
        float3 blended;
        switch (mode) {
        case 1: blended = min(a, b); break;                                   // 变暗
        case 2: blended = a * b; break;                                       // 正片叠底
        case 3: blended = PER_CHANNEL(color_burn, a, b); break;               // 颜色加深
        case 4: case 20: blended = max(a + b - 1.0, 0.0); break;              // 线性加深（减去）
        case 5: return min(a, b);                                             // 深色，不受透明度影响
        case 6: blended = max(a, b); break;                                   // 变亮
        case 7: blended = 1.0 - (1.0 - a) * (1.0 - b); break;                 // 滤色
        case 8: blended = PER_CHANNEL(color_dodge, a, b); break;              // 颜色减淡
        case 9: blended = min(a + b, 1.0); break;                             // 相加
        case 10: return max(a, b);                                            // 浅色，不受透明度影响
        case 11: blended = PER_CHANNEL(overlay, a, b); break;                 // 叠加
        case 12: blended = PER_CHANNEL(soft_light, a, b); break;              // 柔光
        case 13: blended = PER_CHANNEL(overlay, b, a); break;                 // 强光
        case 14: blended = PER_CHANNEL(vivid_light, a, b); break;             // 亮光
        case 15: blended = PER_CHANNEL(linear_light, a, b); break;            // 线性光
        case 16: blended = PER_CHANNEL(pin_light, a, b); break;               // 点光
        case 17: blended = PER_CHANNEL(hard_mix, a, b); break;                // 实色混合
        case 18: blended = abs(a - b); break;                                 // 差值
        case 19: blended = a + b - 2.0 * a * b; break;                        // 排除
        case 21: blended = PER_CHANNEL(reflect, a, b); break;                 // 反射
        case 22: blended = PER_CHANNEL(reflect, b, a); break;                 // 发光
        case 23: blended = min(a, b) - max(a, b) + 1.0; break;                // 凤凰
        case 24: blended = (a + b) * 0.5; break;                              // 平均
        case 25: blended = 1.0 - abs(1.0 - a - b); break;                     // 否定
        case 26: { float3 x = rgb_to_hsl(a); blended = hsl_to_rgb(float3(rgb_to_hsl(b).x, x.y, x.z)); break; }  // 色相
        case 27: { float3 x = rgb_to_hsl(a); blended = hsl_to_rgb(float3(x.x, rgb_to_hsl(b).y, x.z)); break; }  // 饱和度
        case 28: { float3 y = rgb_to_hsl(b); blended = hsl_to_rgb(float3(y.x, y.y, rgb_to_hsl(a).z)); break; }  // 颜色
        case 29: { float3 x = rgb_to_hsl(a); blended = hsl_to_rgb(float3(x.x, x.y, rgb_to_hsl(b).z)); break; }  // 明度
        // 30–32 是 WE 的 common_blending.h 里多出来的三种（以前只做到 29，用到的场景按普通处理了）
        case 30: blended = max(a.x, max(a.y, a.z)) * b; break;                // 色调（Tint）
        case 31: return a + b * opacity;                                      // 相加（不受明暗混合影响）
        case 32: blended = a + a * b; break;                                  // 自身与自身的叠加
        default: blended = b; break;
        }
        return mix(a, blended, opacity);
    }

    fragment float4 blend_image_fragment(
        LayerFragmentInput in [[stage_in]], constant LayerUniforms &uniforms [[buffer(1)]],
        texture2d<float> image [[texture(0)]], sampler imageSampler [[sampler(0)]], float4 base [[color(0)]]) {
        float4 layer = image.sample(imageSampler, in.uv) * uniforms.color;
        return float4(saturate(apply_blend(uniforms.mode.x, base.rgb, layer.rgb, layer.a)), base.a);
    }

    fragment float4 blend_solid_fragment(
        LayerFragmentInput in [[stage_in]], constant LayerUniforms &uniforms [[buffer(1)]], float4 base [[color(0)]]) {
        float4 layer = uniforms.color;
        return float4(saturate(apply_blend(uniforms.mode.x, base.rgb, layer.rgb, layer.a)), base.a);
    }
    """
}
