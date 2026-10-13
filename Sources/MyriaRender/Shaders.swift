// The Metal shaders, compiled at runtime from source so that the package
// builds with plain `swift build`.
enum Shaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct SurfaceVertex { float2 local; float2 outward; uint face; uint paint; };
struct FaceFrame { float4 origin; float4 xAxis; float4 yAxis; };
struct FacePose { float4 r0; float4 r1; float4 r2; };
struct Paint { float4 color; uint mode; uint pad0; uint pad1; uint pad2; };
struct LineInstance { float2 a; float2 b; uint face; uint style; };
struct LineStyle { float4 color; float width; float glow; float pad0; float pad1; };
struct PointInstance { float2 local; uint face; uint style; float radius; float pad; };

struct ViewUniforms {
    float4x4 viewProjection;
    float2 viewportSize;
    float fold;
    float depthBias;
    float4 light;
};

struct SurfaceUniforms {
    float4 oceanColor;
    float4 backfaceColor;
    float4 nightColor;
    float4 graticuleColor;
    float4 sun;
    float4 fieldGrid;
    float4 fieldSizeRange;
    float4 elevationGrid;
    float4 elevationSize;
    float4 graticule;
    float4 reliefRange;
    uint baseMode;
    uint fieldScale;
    uint hasElevation;
    uint fieldOverlay;
};

constant float PI = 3.14159265358979;
constant float DEG = 57.2957795130823;

inline float3 worldOf(FacePose p, float2 local) {
    float4 q = float4(local, 0, 1);
    return float3(dot(p.r0, q), dot(p.r1, q), dot(p.r2, q));
}

// MARK: Surfaces (face polygons and fills)

struct SurfaceOut {
    float4 position [[position]];
    float3 globe;
    float3 normal;
    uint paint [[flat]];
    uint face [[flat]];
};

vertex SurfaceOut surfaceVertex(uint vid [[vertex_id]],
                                const device SurfaceVertex *vertices [[buffer(0)]],
                                const device FaceFrame *frames [[buffer(1)]],
                                const device FacePose *poses [[buffer(2)]],
                                constant ViewUniforms &view [[buffer(3)]]) {
    SurfaceVertex v = vertices[vid];
    FacePose pose = poses[v.face];
    FaceFrame frame = frames[v.face];
    SurfaceOut out;
    float4 clip = view.viewProjection * float4(worldOf(pose, v.local), 1);
    // Dilation: push edge vertices outwards by a fraction of a pixel, so
    // slits narrower than that close up.
    float dilation = view.light.w;
    if (dilation > 0.0 && (v.outward.x != 0.0 || v.outward.y != 0.0)) {
        float3 dir = float3(dot(pose.r0.xy, v.outward), dot(pose.r1.xy, v.outward), dot(pose.r2.xy, v.outward));
        float2 d = (view.viewProjection * float4(dir, 0)).xy * view.viewportSize * 0.5;
        float len = length(d);
        if (len > 1e-9) {
            float2 px = d / len * dilation * min(length(v.outward), 2.0);
            clip.xy += px / (view.viewportSize * 0.5) * clip.w;
        }
    }
    clip.z += view.depthBias * clip.w;
    out.position = clip;
    out.globe = frame.origin.xyz + frame.xAxis.xyz * v.local.x + frame.yAxis.xyz * v.local.y;
    out.normal = float3(pose.r0.z, pose.r1.z, pose.r2.z);
    out.paint = v.paint;
    out.face = v.face;
    return out;
}

inline float2 gridUV(float lat, float lon, float4 grid, float2 size) {
    float u = ((lon - grid.x) / grid.z + 0.5) / size.x;
    float v = ((lat - grid.y) / grid.w + 0.5) / size.y;
    return float2(u, v);
}

inline float elevationAt(texture2d<float> elevation, sampler s, float lat, float lon, constant SurfaceUniforms &u) {
    return elevation.sample(s, gridUV(lat, lon, u.elevationGrid, u.elevationSize.xy)).r;
}

// Lambertian hill shading from the elevation's gradient, light from the north-west.
inline float hillshade(texture2d<float> elevation, sampler s, float lat, float lon, constant SurfaceUniforms &u) {
    float dlat = u.elevationGrid.w, dlon = u.elevationGrid.z;
    float east = elevationAt(elevation, s, lat, lon + dlon, u) - elevationAt(elevation, s, lat, lon - dlon, u);
    float north = elevationAt(elevation, s, lat + dlat, lon, u) - elevationAt(elevation, s, lat - dlat, lon, u);
    float metresPerDegree = 111320.0;
    float dx = east / (2.0 * dlon * metresPerDegree * max(cos(lat / DEG), 0.05));
    float dy = north / (2.0 * dlat * metresPerDegree);
    float k = u.elevationSize.w;
    float3 n = normalize(float3(-dx * k, -dy * k, 1.0));
    float3 l = normalize(float3(-0.6, 0.6, 0.55));
    float lambert = dot(n, l) / l.z;
    return mix(1.0, clamp(lambert, 0.0, 1.6), u.elevationSize.z);
}

inline float gridLine(float value, float step, float pixelWidth, float halfWidth) {
    float d = abs(fract(value / step + 0.5) - 0.5) * step;
    float px = d / max(pixelWidth, 1e-6);
    return 1.0 - smoothstep(halfWidth - 0.5, halfWidth + 0.5, px);
}

fragment float4 surfaceFragment(SurfaceOut in [[stage_in]],
                                constant SurfaceUniforms &u [[buffer(0)]],
                                const device Paint *paints [[buffer(1)]],
                                const device uint *facePaints [[buffer(2)]],
                                constant ViewUniforms &view [[buffer(3)]],
                                texture2d<float> field [[texture(0)]],
                                texture2d<float> fieldLUT [[texture(1)]],
                                texture2d<float> elevation [[texture(2)]],
                                texture2d<float> reliefLUT [[texture(3)]]) {
    constexpr sampler linearWrap(filter::linear, s_address::repeat, t_address::clamp_to_edge);
    constexpr sampler lut(filter::linear, address::clamp_to_edge);

    float3 dir = normalize(in.globe);
    float lat = asin(clamp(dir.z, -1.0, 1.0)) * DEG;
    float lon = atan2(dir.y, dir.x) * DEG;

    // Paint 0xFFFFFFFF means: the base layer, coloured by the base mode.
    bool isBase = in.paint == 0xFFFFFFFFu;
    uint paintIndex = in.paint;
    if (isBase && u.baseMode == 3) { paintIndex = facePaints[in.face]; }
    float4 color;
    uint mode;
    if (paintIndex == 0xFFFFFFFFu) {
        color = u.oceanColor;
        mode = u.baseMode == 2 ? 4 : 0;
    } else {
        color = paints[paintIndex].color;
        mode = paints[paintIndex].mode;
    }

    if (mode == 5) {
        // A translucent tint over other fills, with the hill shading.
        float4 tint = float4(color.rgb * color.a, color.a);
        if (u.hasElevation != 0) {
            float s = hillshade(elevation, linearWrap, lat, lon, u);
            float4 shade = s < 1.0 ? float4(0, 0, 0, (1.0 - s) * 0.55) : float4(1, 1, 1, 1) * min((s - 1.0) * 0.35, 0.3);
            tint = tint + shade * (1.0 - tint.a);
        }
        return tint;
    }

    if (mode == 1 || mode == 2 || mode == 4) {
        if (u.hasElevation != 0) {
            float h = elevationAt(elevation, linearWrap, lat, lon, u);
            if (mode == 1) {
                float t = sqrt(clamp(h / 6000.0, 0.0, 1.0));
                color = reliefLUT.sample(lut, float2(t, 0.75));
            } else if (mode == 4 && u.reliefRange.z > 0.0) {
                // A body of its own colours, lowest to highest ground.
                float t = clamp((h - u.reliefRange.x) / max(u.reliefRange.y - u.reliefRange.x, 1.0), 0.0, 1.0);
                color = reliefLUT.sample(lut, float2(pow(t, 0.85), 0.25));
            } else if (mode == 4 && h >= 0.0) {
                // Land under the base layer (no land fills drawn): its tints.
                float t = sqrt(clamp(h / 6000.0, 0.0, 1.0));
                color = reliefLUT.sample(lut, float2(t, 0.75));
            } else if (mode == 4) {
                float t = 1.0 - sqrt(clamp(-h / 8000.0, 0.0, 1.0));
                color = reliefLUT.sample(lut, float2(t, 0.25));
            }
            float shade = hillshade(elevation, linearWrap, lat, lon, u);
            if (mode == 4 && u.reliefRange.z == 0.0) { shade = mix(1.0, shade, 0.35); }
            color.rgb *= shade;
        }
    }

    // Fields: opaque on the base layer, or laid over everything by strength.
    if ((isBase && u.baseMode == 1) || u.fieldOverlay == 2) {
        float v = field.sample(linearWrap, gridUV(lat, lon, u.fieldGrid, u.fieldSizeRange.xy)).r;
        float lo = u.fieldSizeRange.z, hi = u.fieldSizeRange.w;
        float t;
        if (u.fieldScale == 1) {
            t = v < 0.0 ? 0.5 - 0.5 * clamp(v / min(lo, -1e-6), 0.0, 1.0) : 0.5 + 0.5 * clamp(v / max(hi, 1e-6), 0.0, 1.0);
        } else {
            t = clamp((v - lo) / max(hi - lo, 1e-9), 0.0, 1.0);
        }
        float4 c = fieldLUT.sample(lut, float2(t, 0.5));
        if (u.fieldOverlay == 2) {
            if (!isnan(v)) { color.rgb = mix(color.rgb, c.rgb, smoothstep(0.02, 0.85, t) * 0.85); }
        } else {
            color = isnan(v) ? u.oceanColor : c;
        }
    }

    // The graticule, drawn per pixel so it stays crisp at any zoom.
    if (u.graticule.x > 0.0) {
        float step = u.graticule.x;
        float wLat = fwidth(lat);
        // Longitude jumps at ±180°; measure it where it is continuous.
        float lonWrapped = lon < 0.0 ? lon + 360.0 : lon;
        float w1 = fwidth(lon), w2 = fwidth(lonWrapped);
        float lonC = w1 <= w2 ? lon : lonWrapped;
        float wLon = min(w1, w2);
        float lineLat = gridLine(lat, step, wLat, u.graticule.y * 0.5);
        // Meridians fade where they crowd together near the poles.
        float spacing = step / max(wLon, 1e-6);
        float lineLon = wLon < 30.0 ? gridLine(lonC, step, wLon, u.graticule.y * 0.5) * smoothstep(3.0, 8.0, spacing) : 0.0;
        if (abs(lat) > 90.0 - step * 0.5) { lineLon *= abs(fmod(lon + 360.0, 90.0)) < 1e-3 ? 1.0 : 0.0; }
        float g = max(lineLat, lineLon) * u.graticuleColor.a;
        color.rgb = mix(color.rgb, u.graticuleColor.rgb, g);
    }

    // Night: the dark side and civil, nautical and astronomical twilight.
    if (u.sun.w > 0.0) {
        float e = dot(dir, u.sun.xyz);
        float soft = 0.004;
        float night = 0.35 * smoothstep(soft, -soft, e)
                    + 0.22 * smoothstep(-0.1045 + soft, -0.1045 - soft, e)
                    + 0.22 * smoothstep(-0.2079 + soft, -0.2079 - soft, e)
                    + 0.21 * smoothstep(-0.3090 + soft, -0.3090 - soft, e);
        color.rgb = mix(color.rgb, u.nightColor.rgb, night * u.nightColor.a / 1.0);
    }

    // Folding: light the faces; the inside of the shell shows through cuts.
    float3 n = normalize(in.normal);
    if (view.fold > 0.0) {
        float3 l = normalize(view.light.xyz);
        if (n.z < 0.0) {
            float3 inside = u.backfaceColor.rgb * (0.55 + 0.45 * max(dot(-n, l), 0.0));
            color.rgb = mix(color.rgb, inside, smoothstep(0.0, 0.05, view.fold));
        } else {
            float shade = 0.62 + 0.38 * max(dot(n, l), 0.0) + 0.25 * pow(max(dot(reflect(-l, n), float3(0, 0, 1)), 0.0), 24.0);
            color.rgb *= mix(1.0, shade, view.fold);
        }
    }
    return float4(color.rgb * color.a, color.a);
}

// MARK: Lines: instanced quads with analytic antialiasing

struct LineOut {
    float4 position [[position]];
    float2 pixel;
    float2 a [[flat]];
    float2 b [[flat]];
    float4 color [[flat]];
    float halfWidth [[flat]];
    float glow [[flat]];
};

inline float2 toPixels(float4 clip, float2 size) {
    float2 ndc = clip.xy / clip.w;
    return float2((ndc.x * 0.5 + 0.5) * size.x, (0.5 - ndc.y * 0.5) * size.y);
}

inline float4 fromPixels(float2 p, float z, float w, float2 size) {
    float2 ndc = float2(p.x / size.x * 2.0 - 1.0, 1.0 - p.y / size.y * 2.0);
    return float4(ndc * w, z, w);
}

vertex LineOut lineVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device LineInstance *lines [[buffer(0)]],
                          const device FacePose *poses [[buffer(1)]],
                          const device LineStyle *styles [[buffer(2)]],
                          constant ViewUniforms &view [[buffer(3)]]) {
    LineInstance line = lines[iid];
    LineStyle style = styles[line.style];
    FacePose pose = poses[line.face];
    float4 ca = view.viewProjection * float4(worldOf(pose, line.a), 1);
    float4 cb = view.viewProjection * float4(worldOf(pose, line.b), 1);
    float2 pa = toPixels(ca, view.viewportSize), pb = toPixels(cb, view.viewportSize);
    float2 d = pb - pa;
    float len = length(d);
    float2 dir = len > 1e-4 ? d / len : float2(1, 0);
    float2 normal = float2(-dir.y, dir.x);
    float extent = style.width * 0.5 + style.glow + 1.0;
    bool end = (vid & 1) != 0;
    float side = (vid & 2) != 0 ? 1.0 : -1.0;
    float2 p = (end ? pb + dir * extent : pa - dir * extent) + normal * side * extent;
    float z = (end ? cb.z / cb.w : ca.z / ca.w) + view.depthBias;
    LineOut out;
    out.position = fromPixels(p, z, 1.0, view.viewportSize);
    out.pixel = p;
    out.a = pa;
    out.b = pb;
    out.color = style.color;
    out.halfWidth = style.width * 0.5;
    out.glow = style.glow;
    return out;
}

fragment float4 lineFragment(LineOut in [[stage_in]]) {
    float2 ab = in.b - in.a;
    float t = clamp(dot(in.pixel - in.a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    float d = length(in.pixel - (in.a + ab * t));
    float core = clamp(in.halfWidth + 0.5 - d, 0.0, 1.0);
    float halo = in.glow > 0.0 ? exp(-pow(max(d - in.halfWidth, 0.0) / max(in.glow * 0.5, 1e-3), 2.0)) * 0.6 : 0.0;
    float alpha = max(core, halo) * in.color.a;
    if (alpha <= 0.001) { discard_fragment(); }
    return float4(in.color.rgb * alpha, alpha);
}

// MARK: Points: round, optionally glowing sprites

struct PointOut {
    float4 position [[position]];
    float2 offset;
    float4 color [[flat]];
    float radius [[flat]];
    float glow [[flat]];
};

vertex PointOut pointVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            const device PointInstance *points [[buffer(0)]],
                            const device FacePose *poses [[buffer(1)]],
                            const device LineStyle *styles [[buffer(2)]],
                            constant ViewUniforms &view [[buffer(3)]]) {
    PointInstance pt = points[iid];
    LineStyle style = styles[pt.style];
    float4 c = view.viewProjection * float4(worldOf(poses[pt.face], pt.local), 1);
    float2 center = toPixels(c, view.viewportSize);
    float extent = pt.radius + style.glow + 1.0;
    float2 corner = float2((vid & 1) != 0 ? 1.0 : -1.0, (vid & 2) != 0 ? 1.0 : -1.0) * extent;
    PointOut out;
    out.position = fromPixels(center + corner, c.z / c.w + view.depthBias, 1.0, view.viewportSize);
    out.offset = corner;
    out.color = style.color;
    out.radius = pt.radius;
    out.glow = style.glow;
    return out;
}

fragment float4 pointFragment(PointOut in [[stage_in]]) {
    float d = length(in.offset);
    float core = clamp(in.radius + 0.5 - d, 0.0, 1.0);
    float halo = in.glow > 0.0 ? exp(-pow(max(d - in.radius, 0.0) / max(in.glow * 0.5, 1e-3), 2.0)) * 0.7 : 0.0;
    float alpha = max(core, halo) * in.color.a;
    if (alpha <= 0.001) { discard_fragment(); }
    return float4(in.color.rgb * alpha, alpha);
}
"""#
}
