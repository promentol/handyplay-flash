//! SmMatrix — 2D affine transform. Mirrors Skia's `SkMatrix`.
//!
//! Pure-Zig name; the HTML5 `DOMMatrix` class lives JS-side as a thin shim
//! around this struct. Storage is the 6-component 2D affine form:
//!
//!   [ a  c  e ]      m11 m21 m41
//!   [ b  d  f ]  ↔   m12 m22 m42
//!   [ 0  0  1 ]      (last row implicit)
//!
//! Fields are kept as plain scalar f64 so node-zigar reflects them
//! directly to JS as `m.a`, `m.b`, etc. (matches the WebIDL surface that
//! the JS DOMMatrix class re-exposes). Method bodies pack/unpack the
//! six fields into three `@Vector(2, f64)` "columns" for SIMD math:
//!
//!   col0 = (a, b)   — multiplier of x
//!   col1 = (c, d)   — multiplier of y
//!   col2 = (e, f)   — translation
//!
//! Apply-to-point is then one vector mul-add: `col0 * x + col1 * y + col2`.
//! On aarch64 each column op is one `fmla.2d` (NEON v128 = 2 × f64).
//! On WASM SIMD it lowers to a pair of `f64x2` ops. On scalar targets
//! LLVM unpacks back to two f64 ops with no overhead.
//!
//! Construction: `SmMatrix.identity()` / `SmMatrix.components(...)`.
//! Pure value type — no allocator needed.

const std = @import("std");

const SmMatrix = @This();
const V2 = @Vector(2, f64);

a: f64 = 1,
b: f64 = 0,
c: f64 = 0,
d: f64 = 1,
e: f64 = 0,
f: f64 = 0,

// ---------------------------------------------------------------------------
// Static factories (Skia-style — `SkMatrix::I()`, `SkMatrix::MakeAll(...)`).
// node-zigar exposes these as static methods on the JS proxy class because
// the first parameter is not `*Self`. Backs the WebIDL `new DOMMatrix(...)`
// dispatch in src/index.ts.
// ---------------------------------------------------------------------------

/// identity() — returns the identity matrix. Backs JS `new DOMMatrix()`.
pub fn identity() SmMatrix {
    return .{};
}

/// components(a, b, c, d, e, f) — initialise from the six 2D affine
/// components. Backs JS `new DOMMatrix([a, b, c, d, e, f])`.
pub fn components(a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) SmMatrix {
    return .{ .a = a, .b = b, .c = c, .d = d, .e = e, .f = f };
}

// ---------------------------------------------------------------------------
// Internal column-pair accessors. inline so callers see direct register loads
// instead of a function-call boundary.
// ---------------------------------------------------------------------------

inline fn col0(self: *const SmMatrix) V2 { return .{ self.a, self.b }; }
inline fn col1(self: *const SmMatrix) V2 { return .{ self.c, self.d }; }
inline fn col2(self: *const SmMatrix) V2 { return .{ self.e, self.f }; }

inline fn setCol0(self: *SmMatrix, v: V2) void { self.a = v[0]; self.b = v[1]; }
inline fn setCol1(self: *SmMatrix, v: V2) void { self.c = v[0]; self.d = v[1]; }
inline fn setCol2(self: *SmMatrix, v: V2) void { self.e = v[0]; self.f = v[1]; }

// ---------------------------------------------------------------------------
// Instance methods — mutating forms (return *SmMatrix for JS chaining).
// ---------------------------------------------------------------------------

/// Post-multiply self by `other`: self = self · other.
pub fn multiplySelf(self: *SmMatrix, other: *const SmMatrix) *SmMatrix {
    const c0 = self.col0();
    const c1 = self.col1();
    const c2 = self.col2();

    const new_c0 = c0 * @as(V2, @splat(other.a)) + c1 * @as(V2, @splat(other.b));
    const new_c1 = c0 * @as(V2, @splat(other.c)) + c1 * @as(V2, @splat(other.d));
    const new_c2 = c0 * @as(V2, @splat(other.e)) + c1 * @as(V2, @splat(other.f)) + c2;

    self.setCol0(new_c0);
    self.setCol1(new_c1);
    self.setCol2(new_c2);
    return self;
}

/// Pre-multiply self by `other`: self = other · self.
pub fn preMultiplySelf(self: *SmMatrix, other: *const SmMatrix) *SmMatrix {
    const o0 = other.col0();
    const o1 = other.col1();
    const o2 = other.col2();

    const new_c0 = o0 * @as(V2, @splat(self.a)) + o1 * @as(V2, @splat(self.b));
    const new_c1 = o0 * @as(V2, @splat(self.c)) + o1 * @as(V2, @splat(self.d));
    const new_c2 = o0 * @as(V2, @splat(self.e)) + o1 * @as(V2, @splat(self.f)) + o2;

    self.setCol0(new_c0);
    self.setCol1(new_c1);
    self.setCol2(new_c2);
    return self;
}

/// Translate: post-multiply self by the translation matrix for (tx, ty).
pub fn translateSelf(self: *SmMatrix, tx: f64, ty: f64) *SmMatrix {
    const new_c2 = self.col2() +
        self.col0() * @as(V2, @splat(tx)) +
        self.col1() * @as(V2, @splat(ty));
    self.setCol2(new_c2);
    return self;
}

/// Scale: post-multiply self by a scaling matrix with (sx, sy).
pub fn scaleSelf(self: *SmMatrix, sx: f64, sy: f64) *SmMatrix {
    self.setCol0(self.col0() * @as(V2, @splat(sx)));
    self.setCol1(self.col1() * @as(V2, @splat(sy)));
    return self;
}

/// Rotate: post-multiply self by a rotation matrix for `angleDegrees`.
pub fn rotateSelf(self: *SmMatrix, angleDegrees: f64) *SmMatrix {
    const radians = angleDegrees * (std.math.pi / 180.0);
    const cos = @cos(radians);
    const sin = @sin(radians);
    const c0 = self.col0();
    const c1 = self.col1();
    const new_c0 = c0 * @as(V2, @splat(cos)) + c1 * @as(V2, @splat(sin));
    const new_c1 = c0 * @as(V2, @splat(-sin)) + c1 * @as(V2, @splat(cos));
    self.setCol0(new_c0);
    self.setCol1(new_c1);
    return self;
}

/// SkewX: post-multiply self by the X-axis skew matrix for `angleDegrees`.
/// `M_x = (1, 0, tan, 1, 0, 0)`. Closed form: c += a·t, d += b·t.
pub fn skewXSelf(self: *SmMatrix, angleDegrees: f64) *SmMatrix {
    const t = @tan(angleDegrees * (std.math.pi / 180.0));
    const new_c1 = self.col1() + self.col0() * @as(V2, @splat(t));
    self.setCol1(new_c1);
    return self;
}

/// SkewY: post-multiply self by the Y-axis skew matrix for `angleDegrees`.
/// `M_y = (1, tan, 0, 1, 0, 0)`. Closed form: a += c·t, b += d·t.
pub fn skewYSelf(self: *SmMatrix, angleDegrees: f64) *SmMatrix {
    const t = @tan(angleDegrees * (std.math.pi / 180.0));
    const new_c0 = self.col0() + self.col1() * @as(V2, @splat(t));
    self.setCol0(new_c0);
    return self;
}

/// Invert self in place using the closed-form 2D affine inverse.
///
/// det = a*d − b*c. If |det| < 1e-12 (singular), all components → NaN per MDN.
pub fn invertSelf(self: *SmMatrix) *SmMatrix {
    const det = self.a * self.d - self.b * self.c;
    if (@abs(det) < 1e-12) {
        const nan = std.math.nan(f64);
        self.a = nan; self.b = nan;
        self.c = nan; self.d = nan;
        self.e = nan; self.f = nan;
        return self;
    }
    const inv_det_v: V2 = @splat(1.0 / det);
    const old_a = self.a;
    const old_b = self.b;
    const old_c = self.c;
    const old_d = self.d;
    const old_e = self.e;
    const old_f = self.f;

    const new_c0: V2 = .{ old_d, -old_b };
    const new_c1: V2 = .{ -old_c, old_a };
    const new_c2: V2 = .{
        old_c * old_f - old_d * old_e,
        old_b * old_e - old_a * old_f,
    };
    self.setCol0(new_c0 * inv_det_v);
    self.setCol1(new_c1 * inv_det_v);
    self.setCol2(new_c2 * inv_det_v);
    return self;
}

// ---------------------------------------------------------------------------
// Internal helper — applies this matrix to a single point.
// Used Zig-side by SmPath.addPathTransform; not exposed to JS.
// ---------------------------------------------------------------------------

pub fn applyToPoint(self: *const SmMatrix, x: f64, y: f64) V2 {
    return self.col0() * @as(V2, @splat(x)) +
        self.col1() * @as(V2, @splat(y)) +
        self.col2();
}
