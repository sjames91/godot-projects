class_name TriangleTiling
extends Tiling
## Triangles with base = cell size, in rows of height cs (one tile), so the
## rows line up with square rows and corners land on whole / half tiles.
## (Was: equilateral triangles, side = cell size, rows of height cs*sqrt(3)/2.)
## Triangle (col,row) is centered horizontally at x = col*cs/2 and points up
## when (col+row) is even.

var _h: float


func id() -> String:
	return "triangle"


func display_name() -> String:
	return "Triangle"


func _on_setup() -> void:
	# OLD: _h = cs * sqrt(3.0) * 0.5
	# WHY: equilateral rows are 0.87 of a tile tall and drift off the square
	# grid; one tile tall keeps them lined up.
	_h = cs


func compute_grid() -> Vector2i:
	# OLD: var h := cs * sqrt(3.0) * 0.5
	var h := cs
	return Vector2i(int(ceil(canvas_px.x / (cs * 0.5))) + 2, int(ceil(canvas_px.y / h - 0.001)))


func is_up(c: Vector2i) -> bool:
	return ((c.x + c.y) & 1) == 0


func cell_center(c: Vector2i) -> Vector2:
	var y := c.y * _h + (_h * 2.0 / 3.0 if is_up(c) else _h / 3.0)
	return Vector2(c.x * cs * 0.5, y)


func cell_polygon(c: Vector2i) -> PackedVector2Array:
	var x := c.x * cs * 0.5
	var top := c.y * _h
	var bot := top + _h
	if is_up(c):
		return PackedVector2Array([Vector2(x, top), Vector2(x + cs * 0.5, bot), Vector2(x - cs * 0.5, bot)])
	return PackedVector2Array([Vector2(x - cs * 0.5, top), Vector2(x + cs * 0.5, top), Vector2(x, bot)])


func point_to_cell(p: Vector2) -> Vector2i:
	var fx := p.x / (cs * 0.5)
	var fy := p.y / _h
	var s := int(floor(fx))
	var j := int(floor(fy))
	var u := fx - s
	var v := fy - j
	var right := Vector2i(s + 1, j)
	var inside_right := (u + v > 1.0) if is_up(right) else (u > v)
	return right if inside_right else Vector2i(s, j)


func neighbors(c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var cand: Array[Vector2i] = [c + Vector2i(1, 0), c + Vector2i(-1, 0), c + (Vector2i(0, 1) if is_up(c) else Vector2i(0, -1))]
	for n in cand:
		if in_grid(n):
			out.append(n)
	return out


func inradius() -> float:
	# OLD: return cs / (2.0 * sqrt(3.0))
	# WHY: base cs, height cs: inradius = 2*area / perimeter = cs / (1 + sqrt(5)).
	return cs / (1.0 + sqrt(5.0))


func cell_range_for_rect(r: Rect2) -> Rect2i:
	var a := Vector2i(int(floor(r.position.x / (cs * 0.5))) - 2, int(floor(r.position.y / _h)) - 1)
	var b := Vector2i(int(ceil(r.end.x / (cs * 0.5))) + 2, int(ceil(r.end.y / _h)) + 1)
	return Rect2i(a, b - a)


func rotation_step_deg() -> float:
	# OLD: return 60.0
	# WHY: these triangles aren't equilateral, so only a half turn maps the
	# grid onto itself.
	return 180.0


func staggered_rows() -> bool:
	return true


func snap_pivot(p: Vector2) -> Vector2:
	# 60 degree steps only map the lattice onto itself about a vertex.
	var best := p
	var best_d := INF
	for v in cell_polygon(point_to_cell(p)):
		var d := p.distance_squared_to(v)
		if d < best_d:
			best_d = d
			best = v
	return best


func glsl() -> String:
	return """
bool TL_up(ivec2 c) { return ((c.x + c.y) & 1) == 0; }
ivec2 TL_cell(vec2 p, float cs, vec4 tp) {
	float h = cs;
	float fx = p.x / (cs * 0.5);
	float fy = p.y / h;
	int s = int(floor(fx));
	int j = int(floor(fy));
	float u = fx - float(s);
	float v = fy - float(j);
	ivec2 right = ivec2(s + 1, j);
	bool inside = TL_up(right) ? (u + v > 1.0) : (u > v);
	return inside ? right : ivec2(s, j);
}
vec2 TL_center(ivec2 c, float cs, vec4 tp) {
	float h = cs;
	float y = float(c.y) * h + (TL_up(c) ? h * 2.0 / 3.0 : h / 3.0);
	return vec2(float(c.x) * cs * 0.5, y);
}
float TL_inradius(float cs) { return cs / (1.0 + sqrt(5.0)); }
// Exact signed distance to triangle p0 p1 p2 (Inigo Quilez's sdTriangle).
float TL_sdtri(vec2 p, vec2 p0, vec2 p1, vec2 p2) {
	vec2 e0 = p1 - p0; vec2 e1 = p2 - p1; vec2 e2 = p0 - p2;
	vec2 v0 = p - p0; vec2 v1 = p - p1; vec2 v2 = p - p2;
	vec2 pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
	vec2 pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
	vec2 pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
	float s = sign(e0.x * e2.y - e0.y * e2.x);
	vec2 d = min(min(vec2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
		vec2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
		vec2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
	return -sqrt(d.x) * sign(d.y);
}
// OLD: an equilateral-only distance formula (rows of cs*sqrt(3)/2).
// WHY: rows are now one tile tall. Shrink the triangle toward its incentre
// by inset + rnd (every edge moves in by exactly that), then round by rnd.
float TL_sdf(vec2 p, ivec2 c, float cs, vec4 tp, float inset, float rnd) {
	float h = cs;
	float x = float(c.x) * cs * 0.5;
	float top = float(c.y) * h;
	float bot = top + h;
	float r = cs / (1.0 + sqrt(5.0));
	vec2 a; vec2 b; vec2 d; vec2 ic;
	if (TL_up(c)) { a = vec2(x, top); b = vec2(x + cs * 0.5, bot); d = vec2(x - cs * 0.5, bot); ic = vec2(x, bot - r); }
	else { a = vec2(x - cs * 0.5, top); b = vec2(x + cs * 0.5, top); d = vec2(x, bot); ic = vec2(x, top + r); }
	float s = max((r - inset - rnd) / r, 0.001);
	a = ic + (a - ic) * s; b = ic + (b - ic) * s; d = ic + (d - ic) * s;
	return TL_sdtri(p, a, b, d) - rnd;
}
"""


## No straight columns (or rows, for Voronoi), so brick offsets do not apply.
func staggered_cols() -> bool:
	return true
