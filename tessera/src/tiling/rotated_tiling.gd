class_name RotatedTiling
extends Tiling
## Rotation (Layer Settings · Tiling) as a decorator around any tiling,
## including Offset and half tiles. The grid turns about the canvas center.
##
## The wrapped tiling is built over a square as wide as the canvas diagonal,
## so the turned grid still covers every corner. Cells keep the wrapped
## tiling's coordinates; only the mapping between canvas and grid turns.
## The angle is baked into the GLSL as constants (shader_key changes with it).

var inner: Tiling
var angle := 0.0  # radians
var c_canvas := Vector2.ZERO  # canvas center
var c_inner := Vector2.ZERO   # center of the wrapped tiling's square


static func wrap(t: Tiling, degrees: float, canvas_size_px: Vector2) -> Tiling:
	var r := RotatedTiling.new()
	r.inner = t
	r.angle = deg_to_rad(degrees)
	r.cs = t.cs
	r.canvas_px = canvas_size_px
	r.params = t.params
	r.grid = t.grid
	# OLD: r.c_canvas = canvas_size_px * 0.5
	#      r.c_inner = t.canvas_px * 0.5
	# WHY: turning about the exact canvas center, with the wrapped tiling
	# centred on a square that wasn't a whole number of cells, put the turned
	# grid lines a fraction of a cell off the square grid even at 90°. Turning
	# about a grid corner, onto a grid corner of the wrapped tiling, maps grid
	# lines onto grid lines at every quarter turn.
	r.c_canvas = (canvas_size_px * 0.5 / t.cs).round() * t.cs
	r.c_inner = (t.canvas_px * 0.5 / t.cs).round() * t.cs
	return r


## Size of the area the wrapped tiling must cover for any rotation: a whole,
## even number of cells (so its center is a grid corner), with a margin for
## the pivot being up to half a cell off the canvas center.
# OLD: static func cover_size(canvas_size_px: Vector2) -> Vector2:
#	var d := ceilf(canvas_size_px.length())
static func cover_size(canvas_size_px: Vector2, cell_size: float) -> Vector2:
	var n := int(ceil(canvas_size_px.length() / cell_size)) + 2
	if n % 2 == 1:
		n += 1
	var d := n * cell_size
	return Vector2(d, d)


func _to_inner(p: Vector2) -> Vector2:
	return (p - c_canvas).rotated(-angle) + c_inner


func _to_canvas(q: Vector2) -> Vector2:
	return (q - c_inner).rotated(angle) + c_canvas


# ---- identity -----------------------------------------------------------------

func id() -> String:
	return inner.id()


func display_name() -> String:
	return inner.display_name() + " (%d°)" % roundi(rad_to_deg(angle))


func param_defs() -> Array:
	return inner.param_defs()


func shader_key() -> String:
	# OLD: return "%s+rot%.4f_%s" % [inner.shader_key(), angle, canvas_px]
	# WHY: the baked pivot now depends on the cell size too.
	return "%s+rot%.4f_%s_%s" % [inner.shader_key(), angle, canvas_px, cs]


# ---- pieces (pass through to half tiles) ----------------------------------------

func pieces_per_cell() -> int:
	return inner.pieces_per_cell()


func piece_base(c: Vector2i) -> Vector2i:
	return inner.piece_base(c)


func pieces_of(b: Vector2i) -> Array[Vector2i]:
	return inner.pieces_of(b)


func half_facing(b: Vector2i, p: Vector2) -> Array[Vector2i]:
	return inner.half_facing(b, _to_inner(p))


# ---- geometry -----------------------------------------------------------------

func cell_center(c: Vector2i) -> Vector2:
	return _to_canvas(inner.cell_center(c))


func cell_polygon(c: Vector2i) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in inner.cell_polygon(c):
		out.append(_to_canvas(v))
	return out


func point_to_cell(p: Vector2) -> Vector2i:
	return inner.point_to_cell(_to_inner(p))


func neighbors(c: Vector2i) -> Array[Vector2i]:
	return inner.neighbors(c)


func inradius() -> float:
	return inner.inradius()


func cell_range_for_rect(r: Rect2) -> Rect2i:
	var a := _to_inner(r.position)
	var bb := Rect2(a, Vector2.ZERO)
	for corner in [Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		bb = bb.expand(_to_inner(corner))
	return inner.cell_range_for_rect(bb)


func rotation_step_deg() -> float:
	return inner.rotation_step_deg()


func can_flip_h() -> bool:
	return inner.can_flip_h()


func can_flip_v() -> bool:
	return inner.can_flip_v()


func snap_pivot(p: Vector2) -> Vector2:
	return _to_canvas(inner.snap_pivot(_to_inner(p)))


func staggered_rows() -> bool:
	return inner.staggered_rows()


func staggered_cols() -> bool:
	return inner.staggered_cols()


# ---- GPU ----------------------------------------------------------------------

func glsl_params() -> Vector4:
	return inner.glsl_params()


func glsl() -> String:
	var code := inner.glsl_prefixed("TL_R_") + """
const vec2 TL_RC = vec2(%.6f, %.6f);
const vec2 TL_RI = vec2(%.6f, %.6f);
const float TL_RCOS = %.8f;
const float TL_RSIN = %.8f;
vec2 TL_rin(vec2 p) { vec2 d = p - TL_RC; return vec2(TL_RCOS * d.x + TL_RSIN * d.y, -TL_RSIN * d.x + TL_RCOS * d.y) + TL_RI; }
vec2 TL_rout(vec2 q) { vec2 d = q - TL_RI; return vec2(TL_RCOS * d.x - TL_RSIN * d.y, TL_RSIN * d.x + TL_RCOS * d.y) + TL_RC; }
ivec2 TL_cell(vec2 p, float cs, vec4 tp) { return TL_R_cell(TL_rin(p), cs, tp); }
vec2 TL_center(ivec2 c, float cs, vec4 tp) { return TL_rout(TL_R_center(c, cs, tp)); }
float TL_inradius(float cs) { return TL_R_inradius(cs); }
float TL_sdf(vec2 p, ivec2 c, float cs, vec4 tp, float inset, float rnd) { return TL_R_sdf(TL_rin(p), c, cs, tp, inset, rnd); }
""" % [c_canvas.x, c_canvas.y, c_inner.x, c_inner.y, cos(angle), sin(angle)]
	if inner.pieces_per_cell() > 1:
		code += "vec2 TL_pcenter(ivec2 c, float cs, vec4 tp) { return TL_rout(TL_R_pcenter(c, cs, tp)); }\n"
	return code
