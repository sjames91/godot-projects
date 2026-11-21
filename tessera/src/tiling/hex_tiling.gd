class_name HexTiling
extends Tiling
## Flat-top hexagons, flat-to-flat height = cell size, so every column stacks
## at exactly one tile and lines up with square rows (turned 90° they line up
## with square columns instead). Columns are 1.5 * circumradius apart; odd
## columns sit half a tile higher ("even-q" layout). Column 0 / the odd
## columns' row 0 are centered on the canvas' left / top edge so the whole
## canvas is covered with no gaps.
##
## OLD: pointy-top hexagons, flat-to-flat width = cell size, odd rows shifted
## right by half a cell ("odd-r"), rows 0.87 of a tile apart.
## WHY: rows that aren't a whole tile tall drift off the square grid, so
## hexagons couldn't sit next to squares (or self-made tilings) and line up.

var _r: float  # circumradius


func id() -> String:
	return "hex"


func display_name() -> String:
	return "Hexagon"


func _on_setup() -> void:
	_r = cs / sqrt(3.0)


func compute_grid() -> Vector2i:
	# OLD: Vector2i(int(ceil(canvas_px.x / cs)) + 1, int(ceil(canvas_px.y / (1.5 * r))) + 1)
	var r := cs / sqrt(3.0)
	return Vector2i(int(ceil(canvas_px.x / (1.5 * r))) + 1, int(ceil(canvas_px.y / cs - 0.001)) + 1)


## Even columns' tiles start on a tile row; odd columns sit half a tile up.
func _col_shift(x: int) -> float:
	return 0.5 if (x & 1) == 0 else 0.0


func cell_center(c: Vector2i) -> Vector2:
	# OLD: Vector2(cs * (c.x + 0.5 * (c.y & 1)), 1.5 * _r * c.y)
	return Vector2(1.5 * _r * c.x, cs * (c.y + _col_shift(c.x)))


func cell_polygon(c: Vector2i) -> PackedVector2Array:
	var ctr := cell_center(c)
	var pts := PackedVector2Array()
	for i in 6:
		# OLD: var a := deg_to_rad(60.0 * i - 90.0)  (pointy-top)
		var a := deg_to_rad(60.0 * i)
		pts.append(ctr + Vector2(cos(a), sin(a)) * _r)
	return pts


## Offset (col, row) <-> axial (q, r) for this layout.
static func _to_axial(c: Vector2i) -> Vector2i:
	return Vector2i(c.x, c.y - (c.x + (c.x & 1)) / 2)


static func _from_axial(q: int, r: int) -> Vector2i:
	return Vector2i(q, r + (q + (q & 1)) / 2)


func point_to_cell(p: Vector2) -> Vector2i:
	# Shift so (0, 0) sits on the origin, then flat-top pixel -> axial.
	var pp := p - Vector2(0, cs * 0.5)
	var q := (2.0 / 3.0 * pp.x) / _r
	var r := (-pp.x / 3.0 + sqrt(3.0) / 3.0 * pp.y) / _r
	var x := q
	var z := r
	var y := -x - z
	var rx := roundf(x)
	var ry := roundf(y)
	var rz := roundf(z)
	var dx := absf(rx - x)
	var dy := absf(ry - y)
	var dz := absf(rz - z)
	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return _from_axial(int(rx), int(rz))


const _AXIAL_DIRS: Array[Vector2i] = [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]


func neighbors(c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var a := _to_axial(c)
	for d in _AXIAL_DIRS:
		var n := _from_axial(a.x + d.x, a.y + d.y)
		if in_grid(n):
			out.append(n)
	return out


func inradius() -> float:
	return cs * 0.5


func cell_range_for_rect(r: Rect2) -> Rect2i:
	var a := Vector2i(int(floor(r.position.x / (1.5 * _r))) - 2, int(floor(r.position.y / cs)) - 2)
	var b := Vector2i(int(ceil(r.end.x / (1.5 * _r))) + 2, int(ceil(r.end.y / cs)) + 2)
	return Rect2i(a, b - a)


func rotation_step_deg() -> float:
	return 60.0


func staggered_rows() -> bool:
	return true


func glsl() -> String:
	return """
ivec2 TL_cell(vec2 p, float cs, vec4 tp) {
	float R = cs / sqrt(3.0);
	vec2 pp = p - vec2(0.0, cs * 0.5);
	float q = (2.0 / 3.0 * pp.x) / R;
	float r = (-pp.x / 3.0 + sqrt(3.0) / 3.0 * pp.y) / R;
	vec3 cube = vec3(q, -q - r, r);
	vec3 rr = round(cube);
	vec3 d = abs(rr - cube);
	if (d.x > d.y && d.x > d.z) { rr.x = -rr.y - rr.z; }
	else if (d.y > d.z) { rr.y = -rr.x - rr.z; }
	else { rr.z = -rr.x - rr.y; }
	int qi = int(rr.x);
	int ri = int(rr.z);
	return ivec2(qi, ri + (qi + (qi & 1)) / 2);
}
vec2 TL_center(ivec2 c, float cs, vec4 tp) {
	float R = cs / sqrt(3.0);
	return vec2(1.5 * R * float(c.x), cs * (float(c.y) + ((c.x & 1) == 0 ? 0.5 : 0.0)));
}
float TL_inradius(float cs) { return cs * 0.5; }
float TL_sdf(vec2 p, ivec2 c, float cs, vec4 tp, float inset, float rnd) {
	// OLD: vec2 q = (p - TL_center(c, cs, tp)).yx;  (swapped for pointy-top)
	vec2 q = p - TL_center(c, cs, tp);
	float r = max(cs * 0.5 - inset - rnd, 0.0);
	vec3 k = vec3(-0.866025404, 0.5, 0.577350269);
	q = abs(q);
	q -= 2.0 * min(dot(k.xy, q), 0.0) * k.xy;
	q -= vec2(clamp(q.x, -k.z * r, k.z * r), r);
	return length(q) * sign(q.y) - rnd;
}
"""


## No straight columns (or rows, for Voronoi), so brick offsets do not apply.
func staggered_cols() -> bool:
	return true
