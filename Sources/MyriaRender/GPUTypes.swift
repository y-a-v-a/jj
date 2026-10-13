import Foundation
import simd

// Swift mirrors of the structures in `Shaders.swift`. Field order and
// types must match the Metal declarations exactly.

/// A vertex of a face polygon or of a fill, in face-local coordinates.
struct SurfaceVertex {
    var local: SIMD2<Float>
    /// Direction (face-local) in which the vertex moves when faces are
    /// dilated to seal sub-pixel slits; zero inside a face.
    var outward: SIMD2<Float>
    var face: UInt32
    var paint: UInt32
}

/// The plane of a face in globe coordinates.
struct FaceFrameGPU {
    var origin: SIMD4<Float>
    var xAxis: SIMD4<Float>
    var yAxis: SIMD4<Float>
}

/// Face-local (x, y, 0, 1) → world, as the rows of a 3 × 4 matrix.
struct FacePoseGPU {
    var r0: SIMD4<Float>
    var r1: SIMD4<Float>
    var r2: SIMD4<Float>
}

/// How a surface fragment gets its colour.
struct PaintGPU {
    var color: SIMD4<Float>
    /// 0 solid, 1 hypsometric land relief, 2 solid with hill shading,
    /// 5 translucent tint with hill shading (laid over other fills).
    var mode: UInt32
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

struct LineInstance {
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var face: UInt32
    var style: UInt32
}

struct LineStyleGPU {
    var color: SIMD4<Float>
    /// Width in pixels.
    var width: Float
    /// Extra soft glow around the line, in pixels.
    var glow: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

struct PointInstance {
    var local: SIMD2<Float>
    var face: UInt32
    var style: UInt32
    /// Radius in pixels.
    var radius: Float
    var pad: Float = 0
}

struct ViewUniforms {
    var viewProjection: simd_float4x4
    var viewportSize: SIMD2<Float>
    /// 0 flat … 1 closed globe: how much 3D shading applies.
    var fold: Float
    /// Added to clip-space depth, to keep coplanar layers apart.
    var depthBias: Float
    /// Light direction in view space; w is the dilation in pixels.
    var light: SIMD4<Float>
}

struct SurfaceUniforms {
    var oceanColor: SIMD4<Float>
    var backfaceColor: SIMD4<Float>
    var nightColor: SIMD4<Float>
    var graticuleColor: SIMD4<Float>
    /// Sun direction in globe coordinates; w = 1 when night is shown.
    var sun: SIMD4<Float>
    /// Field grid: lon0, lat0, dlon, dlat (degrees).
    var fieldGrid: SIMD4<Float>
    /// Field size (w, h) and value range (lo, hi).
    var fieldSizeRange: SIMD4<Float>
    /// Elevation grid: lon0, lat0, dlon, dlat.
    var elevationGrid: SIMD4<Float>
    /// Elevation size (w, h), hill shading strength, exaggeration.
    var elevationSize: SIMD4<Float>
    /// Graticule step (degrees, 0 = none), line width (px), fade.
    var graticule: SIMD4<Float>
    /// 0 ocean colour, 1 field, 2 sea relief, 3 per-face paint.
    var baseMode: UInt32
    /// 0 linear, 1 diverging around zero.
    var fieldScale: UInt32
    var hasElevation: UInt32
    /// 0 none, 2 the field is laid over every surface by its strength.
    var fieldOverlay: UInt32
}
