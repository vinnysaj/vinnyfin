#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Rings of water spreading over the picture from where it was double-tapped (`PictureRipples`).
/// Each ring bends the picture under it along its slope, splitting red and blue a little apart
/// where it bends most, and catches the light on its crests. Behind the leading ring the water
/// settles; ahead of it, once it has settled, and off the picture, nothing is drawn, so the
/// picture playing below shows through and the bars around it stay black.
///
/// - Parameters:
///   - ripples: Three values a ripple: where it began, x and y, and the seconds since.
///   - count: The number of values in `ripples`.
///   - amplitude: How far, in points, the steepest wave moves the picture.
///   - wavelength: From one crest to the next, in points.
///   - speed: How fast the leading ring spreads, in points a second.
///   - decay: How fast the water settles, over time and behind the leading ring.
///   - aberration: How far apart red and blue bend, as a share of the bend.
[[ stitchable ]] half4 waterRipple(float2 position, SwiftUI::Layer layer, device const float *ripples, int count,
                                   float amplitude, float wavelength, float speed, float decay, float aberration) {
    float2 offset = float2(0.0);
    float light = 0.0;
    float presence = 0.0;
    for (int index = 0; index + 2 < count; index += 3) {
        float2 origin = float2(ripples[index], ripples[index + 1]);
        float time = ripples[index + 2];
        float2 delta = position - origin;
        float distance = length(delta);
        // How far behind the leading ring this point is.
        float behind = speed * time - distance;
        if (behind <= 0.0 || distance < 0.001) {
            continue;
        }
        float2 outward = delta / distance;
        float envelope = exp(-decay * time)
            * exp(-behind / (2.2 * wavelength))
            * smoothstep(0.0, 0.6 * wavelength, behind);
        float phase = 2.0 * M_PI_F * behind / wavelength;
        // Bent along the slope, as a surface refracts what's under it.
        offset += outward * cos(phase) * envelope * amplitude;
        light += sin(phase) * envelope;
        presence = max(presence, envelope);
    }
    if (presence < 0.002) {
        return half4(0.0);
    }
    half4 green = layer.sample(position + offset);
    half4 red = layer.sample(position + offset * (1.0 + aberration));
    half4 blue = layer.sample(position + offset * (1.0 - aberration));
    half4 color = half4(red.r, green.g, blue.b, green.a);
    color.rgb += half(0.22 * max(light, 0.0)) * color.a;
    color.rgb -= half(0.08 * max(-light, 0.0)) * color.a;
    color.rgb = clamp(color.rgb, half3(0.0), half3(color.a));
    // Faded in from where the water is still, which is the picture as it plays. Only over the
    // frame: bent in from its edge, the picture would spill into the bars around it.
    half alpha = half(smoothstep(0.0, 0.35, presence)) * layer.sample(position).a;
    return color * alpha;
}
