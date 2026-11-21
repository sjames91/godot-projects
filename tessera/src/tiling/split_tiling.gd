class_name SplitTiling
extends Tiling
## Half tiles, as a decorator around Square, Hexagon or Triangle.
##
## Every whole tile is cut into wedges from its center: one ray to each corner
## and one to each edge midpoint (8 for a square, 12 for a hexagon, 6 for a
## triangle). Each wedge is a cell, so tools, fill, selection and undo work
## unchanged. Any run of wedges covering half the tile is a half: diagonal or
## straight halves of a square, any of a hexagon's 6 axes, any median of a
## triangle (corner, center and opposite midpoint are always in line).
##
## The ray angles are measured from a real tile, so they don't have to be
## evenly spaced (triangles one tile tall aren't equilateral). Every tile of
## these tilings has the same set of ray angles, up / down triangles included.
##
## Cell coordinates: (whole.x * K + wedge, whole.y).
## Drawing: the layer shader collects which wedges of a tile share a colour
## and passes that mask in tp.z, so a full tile draws as one plain tile and a
## half draws as one shape (no seams inside it).

const SUPPORTED := ["square", "hex", "triangle"]

var inner: Tiling
var k := 8
var rays := PackedFloat32Array()  # K ascending angles (radians), first in (-PI, PI]


static func supports(tiling_id: String) -> bool:
	return tiling_id in SUPPORTED


static func wrap(t: Tiling) -> Tiling:
	var s := SplitTiling.new()
	s.inner = t
	s.rays = _measure_rays(t)
	s.k = s.rays.size()
	s.cs = t.cs
	s.canvas_px = t.canvas_px
	s.params = t.params
	s.grid = Vector2i(t.grid.x * s.k, t.grid.y)
	return s


## Angles from a tile's center to its corners and edge midpoints, sorted.
static func _measure_rays(t: Tiling) -> PackedFloat32Array:
	var c := Vector2i(1, 1)
	var ctr := t.cell_center(c)
	var poly := t.cell_polygon(c)
	var out: Array[float] = []
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		out.append((a - ctr).angle())
		out.append(((a + b) * 0.5 - ctr).angle())
	out.sort()
	return PackedFloat32Array(out)


# ---- identity -----------------------------------------------------------------

func id() -> String:
	return inner.id()


func display_name() -> String:
	return inner.display_name() + " · halves"


func param_defs() -> Array:
	return inner.param_defs()


func shader_key() -> String:
	return inner.shader_key() + "+split"


# ---- pieces -------------------------------------------------------------------

## Ray j for any integer j (wraps around, adding full turns).
func _ray(j: int) -> float:
	var q := floori(float(j) / k)
	return rays[j - q * k] + TAU * q


func pieces_per_cell() -> int:
	return k


func piece_base(c: Vector2i) -> Vector2i:
	return Vector2i(floori(float(c.x) / k), c.y)


func _piece(c: Vector2i) -> int:
	return c.x - piece_base(c).x * k


func _join(b: Vector2i, piece: int) -> Vector2i:
	return Vector2i(b.x * k + posmod(piece, k), b.y)


func pieces_of(b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i in k:
		out.append(_join(b, i))
	return out


## The K/2 wedges (a straight cut through the center) whose middle direction
## is closest to p.
func half_facing(b: Vector2i, p: Vector2) -> Array[Vector2i]:
	var q := p - inner.cell_center(b)
	var want := atan2(q.y, q.x)
	var n := k / 2
	var best_s := 0
	var best_d := INF
	for s in k:
		var mid := (_ray(s) + _ray(s + n)) * 0.5
		var d := absf(angle_difference(mid, want))
		if d < best_d:
			best_d = d
			best_s = s
	var out: Array[Vector2i] = []
	for i in n:
		out.append(_join(b, best_s + i))
	return out


func _wedge_at(b: Vector2i, p: Vector2) -> int:
	var q := p - inner.cell_center(b)
	var a := rays[0] + fposmod(atan2(q.y, q.x) - rays[0], TAU)
	var w := 0
	for j in range(1, k):
		if a >= rays[j]:
			w = j
	return w


## Where the ray from b's center at angle a leaves the tile.
func _ray_point(b: Vector2i, a: float) -> Vector2:
	var ctr := inner.cell_center(b)
	var far := ctr + Vector2(cos(a), sin(a)) * cs * 4.0
	var poly := inner.cell_polygon(b)
	for i in poly.size():
		var hit = Geometry2D.segment_intersects_segment(ctr, far, poly[i], poly[(i + 1) % poly.size()])
		if hit != null:
			return hit
	return ctr + Vector2(cos(a), sin(a)) * inner.inradius()


# ---- geometry -----------------------------------------------------------------

func cell_polygon(c: Vector2i) -> PackedVector2Array:
	var b := piece_base(c)
	var i := _piece(c)
	return PackedVector2Array([inner.cell_center(b), _ray_point(b, _ray(i)), _ray_point(b, _ray(i + 1))])


func cell_center(c: Vector2i) -> Vector2:
	var poly := cell_polygon(c)
	return (poly[0] + poly[1] + poly[2]) / 3.0


func point_to_cell(p: Vector2) -> Vector2i:
	var b := inner.point_to_cell(p)
	if b == INVALID:
		return INVALID
	return _join(b, _wedge_at(b, p))


## Found geometrically: probe just outside each edge of the wedge.
func neighbors(c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var poly := cell_polygon(c)
	var ctr := cell_center(c)
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		for t in [0.25, 0.5, 0.75]:
			var m: Vector2 = a.lerp(b, t)
			var n := point_to_cell(m + (m - ctr).normalized() * 0.25)
			if n != c and in_grid(n) and not out.has(n):
				out.append(n)
	return out


func inradius() -> float:
	return inner.inradius() * 0.4


func cell_range_for_rect(r: Rect2) -> Rect2i:
	var ir := inner.cell_range_for_rect(r)
	return Rect2i(ir.position.x * k, ir.position.y, ir.size.x * k, ir.size.y)


func rotation_step_deg() -> float:
	return inner.rotation_step_deg()


func can_flip_h() -> bool:
	return inner.can_flip_h()


func can_flip_v() -> bool:
	return inner.can_flip_v()


func snap_pivot(p: Vector2) -> Vector2:
	return inner.snap_pivot(p)


func staggered_rows() -> bool:
	return inner.staggered_rows()


func staggered_cols() -> bool:
	return inner.staggered_cols()


# ---- GPU ----------------------------------------------------------------------

func glsl_params() -> Vector4:
	return inner.glsl_params()


## TL_center is the whole tile's center (so resampling into halves copies the
## whole tile's colour into every wedge, and styles centre on the tile).
## TL_pcenter is the wedge's own rough centroid (edge smoothing uses it).
## TL_sdf reads the same-colour wedge mask from tp.z (0 = just this wedge).
func glsl() -> String:
	var chain := ""
	for j in range(k - 1, 0, -1):
		chain += "r == %d ? %.8f : (" % [j, rays[j]]
	chain += "%.8f" % rays[0] + ")".repeat(k - 1)
	return inner.glsl_prefixed("TL_S_") + """
const int TL_SK = %d;
float TL_sray(int j) {
	int q = j >= 0 ? j / TL_SK : -((-j + TL_SK - 1) / TL_SK);
	int r = j - q * TL_SK;
	return (%s) + 6.28318530718 * float(q);
}
int TL_sbx(ivec2 c) { return c.x >= 0 ? c.x / TL_SK : -((-c.x + TL_SK - 1) / TL_SK); }
ivec2 TL_sbase(ivec2 c) { return ivec2(TL_sbx(c), c.y); }
int TL_spiece(ivec2 c) { return c.x - TL_sbx(c) * TL_SK; }
ivec2 TL_cell(vec2 p, float cs, vec4 tp) {
	ivec2 b = TL_S_cell(p, cs, tp);
	vec2 q = p - TL_S_center(b, cs, tp);
	float r0 = TL_sray(0);
	float a = r0 + mod(atan(q.y, q.x) - r0, 6.28318530718);
	int k = 0;
	for (int j = 1; j < TL_SK; j++) { if (a >= TL_sray(j)) { k = j; } }
	return ivec2(b.x * TL_SK + k, b.y);
}
vec2 TL_center(ivec2 c, float cs, vec4 tp) { return TL_S_center(TL_sbase(c), cs, tp); }
vec2 TL_pcenter(ivec2 c, float cs, vec4 tp) {
	int i = TL_spiece(c);
	float m = 0.5 * (TL_sray(i) + TL_sray(i + 1));
	return TL_S_center(TL_sbase(c), cs, tp) + vec2(cos(m), sin(m)) * TL_S_inradius(cs) * 0.6;
}
float TL_inradius(float cs) { return TL_S_inradius(cs); }
float TL_sspan(vec2 q, float A, float L) {
	vec2 dA = vec2(cos(A), sin(A));
	vec2 dB = vec2(cos(A + L), sin(A + L));
	float sA = dA.x * q.y - dA.y * q.x;
	float sB = q.x * dB.y - q.y * dB.x;
	return L <= 3.14159266 ? max(-sA, -sB) : min(-sA, -sB);
}
float TL_sdf(vec2 p, ivec2 c, float cs, vec4 tp, float inset, float rnd) {
	ivec2 b = TL_sbase(c);
	float d = TL_S_sdf(p, b, cs, tp, inset, rnd);
	int full = (1 << TL_SK) - 1;
	int mask = int(tp.z + 0.5);
	if (mask <= 0) { mask = 1 << TL_spiece(c); }
	if (mask == full) { return d; }
	vec2 q = p - TL_S_center(b, cs, tp);
	float best = 1e9;
	for (int s = 0; s < TL_SK; s++) {
		bool on = ((mask >> s) & 1) != 0;
		bool prev = ((mask >> ((s + TL_SK - 1) %% TL_SK)) & 1) != 0;
		if (!on || prev) { continue; }
		int len = 0;
		while (len < TL_SK && ((mask >> ((s + len) %% TL_SK)) & 1) != 0) { len++; }
		float A = TL_sray(s);
		best = min(best, TL_sspan(q, A, TL_sray(s + len) - A));
	}
	return max(d, best + inset);
}
""" % [k, chain]
