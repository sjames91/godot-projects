class_name ShaderBuilder
extends RefCounted
## Builds canvas_item shaders from a tiling's GLSL snippet. One shader per
## tiling; cell style and features are uniforms (uniform branches are
## coherent across the whole draw, so they cost almost nothing when off).

static var _layer_cache := {}
static var _overlay_cache := {}

const COMMON := """
uniform vec2 canvas_px = vec2(512.0);
uniform vec2 node_origin = vec2(0.0);
uniform vec2 node_size = vec2(512.0);
uniform bool tile_mode = false;

vec2 canvas_point(vec2 uv) {
	vec2 p = node_origin + uv * node_size;
	if (tile_mode) { p = mod(p, canvas_px); }
	return p;
}

vec3 blend_fn(vec3 b, vec3 s, int m) {
	if (m == 1) { return b * s; }
	if (m == 2) { return b + s - b * s; }
	if (m == 3) { return mix(2.0 * b * s, 1.0 - 2.0 * (1.0 - b) * (1.0 - s), step(vec3(0.5), b)); }
	if (m == 4) { return min(b + s, vec3(1.0)); }
	return s;
}

// Straight-alpha source-over with a separable blend mode (W3C compositing).
vec4 composite(vec4 dst, vec4 src, int m) {
	float as_ = clamp(src.a, 0.0, 1.0);
	float ab = clamp(dst.a, 0.0, 1.0);
	vec3 mixed = (1.0 - ab) * src.rgb + ab * blend_fn(dst.rgb, src.rgb, m);
	float ao = as_ + ab * (1.0 - as_);
	vec3 co = as_ * mixed + ab * dst.rgb * (1.0 - as_);
	return ao > 0.00001 ? vec4(co / ao, ao) : vec4(0.0);
}
"""


static func layer_shader(t: Tiling) -> Shader:
	var key := t.shader_key()
	if _layer_cache.has(key):
		return _layer_cache[key]
	var s := Shader.new()
	s.code = layer_shader_code(t)
	_layer_cache[key] = s
	return s


static func overlay_shader(t: Tiling) -> Shader:
	var key := t.shader_key()
	if _overlay_cache.has(key):
		return _overlay_cache[key]
	var s := Shader.new()
	s.code = overlay_shader_code(t)
	_overlay_cache[key] = s
	return s


static var _compositor := {}


## Blends up to n layer textures in one pass. Each slot is sampled either in
## canvas space (cache images) or screen space (live layer viewports).
static func compositor_shader(n: int) -> Shader:
	if _compositor.has(n):
		return _compositor[n]
	var code := "shader_type canvas_item;\nrender_mode blend_disabled, unshaded;\n"
	for i in n:
		code += "uniform sampler2D t%d : filter_nearest, repeat_enable;\n" % i
	code += "uniform int n = 0;\nuniform int space[%d];\nuniform int mode[%d];\nuniform float op[%d];\nuniform vec4 tint[%d];\n" % [n, n, n, n]
	code += COMMON
	code += "void fragment() {\n\tvec2 p = canvas_point(UV);\n\tvec2 uvc = p / canvas_px;\n\tvec4 acc = vec4(0.0);\n\tvec4 s;\n"
	for i in n:
		code += "\tif (n > %d) { s = (space[%d] == 0 ? texture(t%d, uvc) : texture(t%d, SCREEN_UV)) * tint[%d]; s.a *= op[%d]; acc = composite(acc, s, mode[%d]); }\n" % [i, i, i, i, i, i, i]
	code += "\tCOLOR = acc;\n}\n"
	var sh := Shader.new()
	sh.code = code
	_compositor[n] = sh
	return sh


# OLD: static func layer_shader_code(t: Tiling) -> String:
#	return """shader_type canvas_item; ...
# WHY: half tiles add code in two marked spots (//@PIECES, //@MERGE), filled
# in by _pieces_code once the whole string is built.
static func layer_shader_code(t: Tiling) -> String:
	return _pieces_code(t, _layer_shader_text(t))


## Fills the two half-tile hooks. Without halves they become a plain cell
## center and nothing, so the shader is the same as before.
static func _pieces_code(t: Tiling, code: String) -> String:
	var k := t.pieces_per_cell()
	if k <= 1:
		code = code.replace("//@PIECES", """const int TILE_PIECES = 1;
ivec2 tile_of(ivec2 c) { return c; }
ivec2 tile_piece(ivec2 t, int k) { return t; }
vec2 piece_center(ivec2 c) { return TL_center(c, ucs, utp); }""")
		return code.replace("//@MERGE", "")
	code = code.replace("//@PIECES", """const int TILE_PIECES = %d;
ivec2 tile_of(ivec2 c) { return ivec2((c.x >= 0 ? c.x / %d : -((-c.x + %d) / %d)) * %d, c.y); }
ivec2 tile_piece(ivec2 t, int k) { return ivec2(t.x + k, t.y); }
vec2 piece_center(ivec2 c) { return TL_pcenter(c, ucs, utp); }""" % [k, k, k - 1, k, k])
	# Which wedges of this tile share its colour -> tp.z, so TL_sdf draws them
	# as one shape. hc_c (used for per-tile random values) becomes the tile.
	return code.replace("//@MERGE", """if (v > 0) {
		int sbx = c.x / %d;
		int m = 0;
		for (int k = 0; k < %d; k++) { if (cell_val(ivec2(sbx * %d + k, c.y)) == v) { m |= 1 << k; } }
		utp_m.z = float(m);
		hc_c = ivec2(sbx * %d, c.y);
	}""" % [k, k, k, k])


static func _layer_shader_text(t: Tiling) -> String:
	return """shader_type canvas_item;
render_mode blend_disabled, unshaded;

uniform sampler2D cells_tex : filter_nearest, repeat_disable;
uniform sampler2D palette_tex : filter_nearest, repeat_disable;
uniform float ucs = 8.0;
uniform vec4 utp = vec4(0.0);
uniform ivec2 grid = ivec2(1);
uniform int output_mode = 1;   // layers always output straight alpha; the compositor blends
uniform float opacity = 1.0;   // applied by the compositor
uniform int blend_mode = 0;    // applied by the compositor
uniform bool raw_mode = false;

uniform int cell_style = 0;
uniform float dot_size = 0.8;
uniform float stamp_thickness = 0.3;
uniform bool rounding_on = false;
uniform float rounding = 0.4;
uniform bool rounding_color_aware = false;
uniform bool smooth_edges_on = false;
uniform float smooth_edges = 0.5;
uniform bool rounding_inner = false;
uniform bool gap_on = false;
uniform float gap = 0.15;
uniform bool grout_on = true;
uniform vec4 grout_color : source_color = vec4(0.1, 0.1, 0.12, 1.0);
uniform int boundary_mode = 0;
uniform float boundary_width = 0.5;
uniform bool jitter_on = false;
uniform float jitter_pos = 0.25;
uniform float jitter_size = 0.2;
uniform float jitter_rot = 0.2;
uniform float jitter_seed = 1.0;
uniform int jitter_source = 0;   // 0 random, 1 flow, 2 pattern
uniform bool flow_on = false;
uniform sampler2D flow_tex : filter_linear, repeat_disable;
uniform float flow_strength = 1.0;
uniform bool flow_stamp_rot = false;
uniform bool flow_cell_rot = false;
uniform bool flow_patterns = false;
uniform float flow_drift = 0.0;
uniform float flow_stretch = 0.0;
uniform float flow_size_start = 1.0;
uniform float flow_size_end = 1.0;
uniform float flow_color_shift = 0.0;
uniform bool flow_prog_on = false;
uniform sampler2D flow_prog_tex : filter_linear, repeat_disable;
// Removed: CRT uniforms (scanlines, phosphor mask, beam spot, bleed), to be rebuilt.
uniform int pal_count = 1;
uniform sampler2D stamp_tex : filter_linear, repeat_disable;
uniform bool stamp_on = false;
uniform int pat_count = 0;
uniform int pat_view = -1;
uniform int pat_flags[4];
uniform int pat_src[4];
uniform int pat_filter[32];
uniform int pat_filtered[4];
uniform vec4 pat_styles[4];
uniform vec2 pat_size[4];
uniform vec2 pat_rot[4];
uniform vec2 pat_round[4];
uniform vec2 pat_gap[4];
uniform vec2 pat_jit[4];
uniform vec2 pat_shift[4];
uniform float pat_vis[4];
uniform float pat_fine[4];
uniform vec4 pat_a[4];
uniform vec4 pat_b[4];
uniform sampler2D pat0 : filter_nearest, repeat_disable;
uniform sampler2D pat1 : filter_nearest, repeat_disable;
uniform sampler2D pat2 : filter_nearest, repeat_disable;
uniform sampler2D pat3 : filter_nearest, repeat_disable;
uniform sampler2D patr0 : filter_linear, repeat_enable;
uniform sampler2D patr1 : filter_linear, repeat_enable;
uniform sampler2D patr2 : filter_linear, repeat_enable;
uniform sampler2D patr3 : filter_linear, repeat_enable;
""" + COMMON + t.glsl() + OkLab.GLSL + Patterns.GLSL + """

int cell_val(ivec2 c) {
	if (c.x < 0 || c.y < 0 || c.x >= grid.x || c.y >= grid.y) { return 0; }
	return int(round(texelFetch(cells_tex, c, 0).r * 255.0));
}

vec4 pal(int v) { return texelFetch(palette_tex, ivec2(v - 1, 0), 0); }

//@PIECES

// Smooth outer edges. Every tile near p votes "filled" or "empty", weighted
// by distance from its center (smooth falloff, zero at radius R). The outline
// is where the vote is 50/50, so staircases become curves. Only filled vs
// empty is averaged; where two colours meet, each pixel keeps its own tile's
// colour. Returns colour (rgb) + coverage (a).
vec4 smooth_shape(vec2 p, float aa) {
	float inr = TL_inradius(ucs);
	float R = ucs * (0.6 + 1.4 * clamp(smooth_edges, 0.0, 1.0));
	float step_r = 0.75 * inr;
	ivec2 seen[48];
	int n = 0;
	float wsum = 0.0; float fsum = 0.0;
	vec2 gw = vec2(0.0); vec2 gf = vec2(0.0);
	float best_w = -1.0; int best_v = 0;
	int rings = int(ceil((R + inr) / step_r));
	for (int ri = 0; ri <= rings; ri++) {
		float rad = float(ri) * step_r;
		int cnt = ri == 0 ? 1 : max(6, int(ceil(6.2832 * rad / step_r)));
		for (int k = 0; k < cnt; k++) {
			float a = (float(k) + 0.5 * float(ri & 1)) * 6.2832 / float(cnt);
			// Collect whole tiles, then vote with every piece of each tile
			// (half tiles have many small wedges; sampling could miss some).
			ivec2 tl = tile_of(TL_cell(p + vec2(cos(a), sin(a)) * rad, ucs, utp));
			bool dup = false;
			for (int i = 0; i < n; i++) { if (seen[i] == tl) { dup = true; break; } }
			if (dup || n >= 48) { continue; }
			seen[n] = tl; n++;
			for (int pk = 0; pk < TILE_PIECES; pk++) {
				ivec2 c = tile_piece(tl, pk);
				vec2 d = p - piece_center(c);
				float t = 1.0 - dot(d, d) / (R * R);
				if (t <= 0.0) { continue; }
				float w = t * t;
				vec2 dw = -4.0 * t * d / (R * R);
				int cv = cell_val(c);
				float f = cv > 0 ? 1.0 : 0.0;
				wsum += w; fsum += w * f;
				gw += dw; gf += dw * f;
				if (cv > 0 && w > best_w) { best_w = w; best_v = cv; }
			}
		}
	}
	if (wsum <= 1e-6 || best_v == 0) { return vec4(0.0); }
	float occ = fsum / wsum;
	vec2 g = (gf - occ * gw) / wsum;
	float sd = (occ - 0.5) / max(length(g), 1e-4);
	int own = cell_val(TL_cell(p, ucs, utp));
	int v = own > 0 ? own : best_v;
	return vec4(pal(v).rgb, pal(v).a * smoothstep(-aa, aa, sd));
}

float pat_value(int i, ivec2 c) {
	if (i == 0) { return texelFetch(pat0, c, 0).r; }
	if (i == 1) { return texelFetch(pat1, c, 0).r; }
	if (i == 2) { return texelFetch(pat2, c, 0).r; }
	return texelFetch(pat3, c, 0).r;
}

float pat_raster(int i, vec2 uv) {
	if (i == 0) { return texture(patr0, uv).r; }
	if (i == 1) { return texture(patr1, uv).r; }
	if (i == 2) { return texture(patr2, uv).r; }
	return texture(patr3, uv).r;
}

// Does pattern slot i apply to palette entry v (colour filter)?
bool pat_applies(int i, int v) {
	if (i >= pat_count) { return false; }
	if (pat_filtered[i] == 0) { return true; }
	int word = pat_filter[i * 8 + (v >> 5)];
	return ((word >> (v & 31)) & 1) != 0;
}

vec3 cell_hash(ivec2 c, float salt) {
	uint h = uint(c.x) * 73856093u ^ uint(c.y) * 19349663u ^ uint(jitter_seed * 977.0 + salt) * 83492791u;
	h = (h ^ (h >> 13u)) * 1274126177u;
	h = h ^ (h >> 16u);
	return vec3(float(h & 1023u), float((h >> 10u) & 1023u), float((h >> 20u) & 1023u)) / 1023.0;
}

vec2 rot2(vec2 v, float a) { float c = cos(a); float s = sin(a); return vec2(c * v.x - s * v.y, s * v.x + c * v.y); }

float sd_segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a; vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h);
}

float bayer8(ivec2 p) {
	int x = p.x & 7; int y = p.y & 7; int xy = x ^ y;
	int v = ((xy & 1) << 5) | ((x & 1) << 4) | ((xy & 2) << 2) | ((x & 2) << 1) | ((xy & 4) >> 1) | ((x & 4) >> 2);
	return (float(v) + 0.5) / 64.0;
}

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

// Normal of the cell edge facing p: gradient of the cell inflated far past
// p, so it is the edge's own normal even beside a corner (straight runs of
// neighbouring cells then give exactly parallel normals).
vec2 sdf_grad(vec2 p, ivec2 c) {
	float e = 0.35;
	float infl = -2.0 * ucs;
	float d0 = TL_sdf(p, c, ucs, utp, infl, 0.0);
	return vec2(TL_sdf(p + vec2(e, 0.0), c, ucs, utp, infl, 0.0) - d0, TL_sdf(p + vec2(0.0, e), c, ucs, utp, infl, 0.0) - d0);
}

// Nearby cells around p (found by probing points on two rings).
int gather(vec2 p, ivec2 self_c, inout ivec2 found[17]) {
	int n = 0;
	float inr = TL_inradius(ucs);
	for (int ring = 0; ring < 2; ring++) {
		float rad = inr * (ring == 0 ? 0.7 : 1.45);
		for (int k = 0; k < 8; k++) {
			float a = (float(k) + 0.5 * float(ring)) * TAU / 8.0;
			ivec2 c = TL_cell(p + vec2(cos(a), sin(a)) * rad, ucs, utp);
			if (c == self_c) { continue; }
			bool dup = false;
			for (int i = 0; i < n; i++) { if (found[i] == c) { dup = true; } }
			if (!dup && n < 16) { found[n] = c; n++; }
		}
	}
	return n;
}

// Distances from p to nearby cells whose colour test matches:
// x = nearest distance overall; y, z = the two nearest *edges* that are not
// collinear (cells whose closest feature to p is a vertex are not edges).
vec3 constraints(vec2 p, ivec2 found[17], int n, int v, bool want_equal) {
	float dmin = 1e9;
	float e1 = 1e9; vec2 g1 = vec2(0.0);
	float ds[16]; vec2 gs[16]; bool edge[16];
	for (int i = 0; i < n; i++) {
		int cv = cell_val(found[i]);
		bool ok = want_equal ? (cv == v) : (cv != v);
		ds[i] = 1e9; edge[i] = false;
		if (!ok) { continue; }
		float d = TL_sdf(p, found[i], ucs, utp, 0.0, 0.0);
		float h = TL_sdf(p, found[i], ucs, utp, -2.0 * ucs, 0.0) + 2.0 * ucs;
		ds[i] = d;
		dmin = min(dmin, d);
		edge[i] = abs(d - h) < 0.02 * ucs;
		gs[i] = normalize(sdf_grad(p, found[i]) + vec2(1e-6));
		if (edge[i] && d < e1) { e1 = d; g1 = gs[i]; }
	}
	float e2 = 1e9;
	for (int i = 0; i < n; i++) {
		if (edge[i] && dot(gs[i], g1) < 0.95) { e2 = min(e2, ds[i]); }
	}
	return vec3(dmin, e1, e2);
}

// Signed coverage distance (positive = inside): the region within dmin of
// the boundary, with the convex corner between two edges rounded by r.
float corner_sd(vec3 c, float inset, float r) {
	float dmin = c.x - inset;
	float e1 = c.y - inset;
	float e2 = c.z - inset;
	if (r > 0.0 && e1 < r && e2 < r) { return min(r - length(vec2(r - e1, r - e2)), dmin); }
	return dmin;
}

// Removed: crt_post (scanlines + phosphor mask).

vec4 layer_color(vec2 p, float aa) {
	ivec2 c = TL_cell(p, ucs, utp);
	int v = cell_val(c);
	if (raw_mode) { return v > 0 ? pal(v) : vec4(0.0); }
	if (smooth_edges_on) {
		vec4 sm = smooth_shape(p, aa);
		if (sm.a <= 0.0) { return vec4(0.0); }
		return sm;
	}
	// utp_m: utp plus (for half tiles) which wedges share this tile's colour.
	// hc_c: the cell used for per-tile random values (the whole tile for halves).
	vec4 utp_m = utp;
	ivec2 hc_c = c;
	//@MERGE
	float inr = TL_inradius(ucs);
	float gap_px = gap_on ? gap * inr : 0.0;
	float rnd_px = rounding_on ? rounding * max(inr - gap_px, 0.0) : 0.0;

	// Colour-aware rounding: same-coloured neighbours merge into one shape.
	if (rounding_on && rounding_color_aware) {
		ivec2 found[17];
		int n = gather(p, c, found);
		vec4 outc = vec4(0.0);
		if (v > 0) {
			float sd = corner_sd(constraints(p, found, n, v, false), gap_px, rnd_px);
			float cover = smoothstep(-aa, aa, sd);
			outc = vec4(pal(v).rgb, pal(v).a * cover);
		}
		if (rounding_inner && outc.a < 0.999) {
			// Fill concave corners of neighbouring colour regions.
			for (int i = 0; i < n; i++) {
				int u = cell_val(found[i]);
				if (u == 0 || u == v) { continue; }
				vec3 fc = constraints(p, found, n, u, true);
				vec2 f = fc.yz - vec2(gap_px);
				float r = rnd_px;
				if (fc.z < 1e8 && f.x < r && f.y < r) {
					float sd = length(vec2(r - f.x, r - f.y)) - r;
					float cov = smoothstep(-aa, aa, sd);
					if (cov > 0.0) { outc = composite(vec4(pal(u).rgb, cov), outc, 0); }
					break;
				}
			}
		}
		if (gap_on && grout_on && (v > 0 || outc.a > 0.0)) { outc = composite(grout_color, outc, 0); }
		return outc;
	}

	if (v == 0) { return vec4(0.0); }

	// Patterns: per-cell maps decide this cell's style and properties.
	float pv[4];
	bool pin[4];
	int style = cell_style;
	float size_mul = 1.0; float rot_add = 0.0; float jit_mul = 1.0;
	bool rnd_over = false; float rnd_v = 0.0; bool gap_over = false; float gap_v = 0.0;
	int v0 = v;
	for (int i = 0; i < 4; i++) {
		pin[i] = pat_applies(i, v0);
		pv[i] = pin[i] ? pat_value(i, c) : 0.0;
		if (!pin[i]) { continue; }
		int fl = pat_flags[i];
		float x = pv[i];
		if ((fl & 128) != 0 && x < pat_vis[i] && pat_view < 0) { return vec4(0.0); }
		if ((fl & 64) != 0) { v = clamp(v + int(round(mix(pat_shift[i].x, pat_shift[i].y, x))), 1, pal_count); }
		if ((fl & 1) != 0) {
			int n = max(int(pat_styles[i].w), 1);
			int k = clamp(int(x * float(n)), 0, n - 1);
			style = int(k == 0 ? pat_styles[i].x : (k == 1 ? pat_styles[i].y : pat_styles[i].z));
		}
		if ((fl & 2) != 0) { size_mul *= max(mix(pat_size[i].x, pat_size[i].y, x), 0.0); }
		if ((fl & 4) != 0) { rot_add += mix(pat_rot[i].x, pat_rot[i].y, x) * PI; }
		if ((fl & 8) != 0) { rnd_over = true; rnd_v = mix(pat_round[i].x, pat_round[i].y, x); }
		if ((fl & 16) != 0) { gap_over = true; gap_v = mix(pat_gap[i].x, pat_gap[i].y, x); }
		if ((fl & 32) != 0) { jit_mul *= mix(pat_jit[i].x, pat_jit[i].y, x); }
	}
	if (jitter_source == 2 && pin[0]) { jit_mul *= pv[0]; }
	if (gap_over) { gap_px = clamp(gap_v, 0.0, 1.0) * inr; }
	if (rnd_over) { rnd_px = clamp(rnd_v, 0.0, 1.0) * max(inr - gap_px, 0.0); }
	else if (rounding_on) { rnd_px = rounding * max(inr - gap_px, 0.0); }

	// Along the arrows: how far along (prog) and how much flow is here (fw).
	vec2 fctr = TL_center(c, ucs, utp_m);
	vec2 fdir = flow_on ? texture(flow_tex, fctr / canvas_px).rg : vec2(0.0);
	float fw = clamp(length(fdir), 0.0, 1.0) * flow_strength;
	float prog = flow_prog_on ? texture(flow_prog_tex, fctr / canvas_px).r : 0.0;
	if (flow_prog_on && fw > 0.0 && flow_color_shift != 0.0) {
		v = clamp(v + int(round(flow_color_shift * prog * fw)), 1, pal_count);
	}

	vec4 col = pal(v);
	vec2 ctr = TL_center(c, ucs, utp_m);

	if (boundary_mode == 1) {
		float d0 = -TL_sdf(p, c, ucs, utp_m, 0.0, 0.0);
		float w = max(boundary_width * inr, 0.001);
		if (d0 < w) {
			vec2 g = normalize(sdf_grad(p, c) + vec2(1e-6));
			int nv = cell_val(TL_cell(p + g * (d0 + 0.6), ucs, utp_m));
			if (nv > 0 && nv != v) {
				float t = 0.5 * (1.0 - d0 / w);
				if (bayer8(ivec2(floor(p))) < t) { col = pal(nv); }
			}
		}
	}

	// Removed: horizontal bleed (CRT).

	vec2 q = p;
	float scl = 1.0;
	float stamp_rot = 0.0;
	if (flow_on && (flow_cell_rot || flow_stamp_rot)) {
		vec2 fc = texture(flow_tex, ctr / canvas_px).rg;
		if (dot(fc, fc) > 1e-6) {
			float fa = atan(fc.y, fc.x) * flow_strength * clamp(length(fc), 0.0, 1.0);
			if (flow_cell_rot) { rot_add += fa; } else { stamp_rot = fa; }
		}
	}
	scl *= max(size_mul, 0.001);
	if (flow_prog_on && fw > 0.0) {
		scl *= max(mix(1.0, mix(flow_size_start, flow_size_end, prog), fw), 0.001);
	}
	// Removed: beam spot size (CRT).
	if (jitter_on) {
		vec3 h = cell_hash(hc_c, 0.0);
		vec3 h2 = cell_hash(hc_c, 31.0);
		vec2 off = (h.xy - 0.5) * 2.0 * jitter_pos * jit_mul * inr;
		scl *= max(0.05, 1.0 + (h.z - 0.5) * 2.0 * jitter_size * jit_mul);
		float ang = (h2.x - 0.5) * 2.0 * jitter_rot * jit_mul * PI;
		if (jitter_source == 1 && flow_on) {
			// Follow the linked Direction Layer: slide along the flow and
			// turn toward it (rotation amount 1 = fully aligned).
			vec2 f = texture(flow_tex, ctr / canvas_px).rg;
			if (dot(f, f) > 1e-6) {
				off = f * jitter_pos * jit_mul * inr * (0.5 + h.x) * flow_strength;
				ang = atan(f.y, f.x) * jitter_rot * flow_strength;
			}
		}
		q = ctr + rot2(p - ctr - off, -ang);
	}
	// Stretch along the flow: longer along the arrow, thinner across it.
	// Shapes are clipped to their own cell, so mostly the thinning shows.
	if (flow_on && flow_stretch > 0.0 && fw > 0.0) {
		float fa2 = atan(fdir.y, fdir.x);
		float k = 1.0 + flow_stretch * fw;
		vec2 u = rot2(q - ctr, -fa2);
		u = vec2(u.x / k, u.y * k);
		q = ctr + rot2(u, fa2);
	}
	if (rot_add != 0.0) { q = ctr + rot2(q - ctr, -rot_add); }
	q = ctr + (q - ctr) / scl;
	vec2 l = q - ctr;
	if (stamp_rot != 0.0 && ((style >= 1 && style <= 5) || style == 8)) { l = rot2(l, -stamp_rot); }
	float tile_d = TL_sdf(q, c, ucs, utp_m, gap_px, rnd_px) * scl;
	float shape_d = tile_d;
	vec3 rgb = col.rgb;
	float alpha_mul = 1.0;
	float body = max(inr - gap_px, 0.0);
	vec3 hc = cell_hash(hc_c, 7.0);

	if (style == 1) {
		shape_d = (length(l) - dot_size * body) * scl;
	} else if (style == 2) {
		float a = body * 0.92 * dot_size / 0.8;
		float th = max(stamp_thickness * body * 0.6, 0.3);
		float d1 = sd_segment(l, vec2(-a, -a) * 0.7071, vec2(a, a) * 0.7071);
		float d2 = sd_segment(l, vec2(-a, a) * 0.7071, vec2(a, -a) * 0.7071);
		bool top = d2 < d1 + 0.001;
		float d = min(d1, d2) - th;
		shape_d = d * scl;
		float across = clamp(-(d) / th, 0.0, 1.0);
		rgb *= mix(0.65, 1.12, sqrt(across)) * (top ? 1.0 : 0.85);
	} else if (style == 3) {
		float r = max(dot_size * body, 0.5);
		float dist = length(l);
		float core = 1.0 - smoothstep(r * 0.45, r, dist);
		float glow = exp(-max(dist - r * 0.5, 0.0) / (r * 0.45)) * 0.65;
		rgb = rgb * (0.4 + 0.8 * core) + vec3(pow(core, 4.0) * 0.25);
		alpha_mul = clamp(core + glow, 0.0, 1.0);
	} else if (style == 4) {
		float r = max(dot_size * body, 0.5);
		vec2 lp = l;
		float dist = length(lp);
		float peg = 1.0 - smoothstep(r - aa, r + aa, dist);
		float shade = 0.55 + 0.6 * (1.0 - dist / r);
		float spec = (1.0 - smoothstep(0.0, r * 0.35, length(lp - vec2(-0.32, -0.38) * r))) * 0.6;
		vec3 pegc = rgb * shade + vec3(spec);
		rgb = mix(vec3(0.03, 0.03, 0.035), pegc, peg);
	} else if (style == 5) {
		float r = max(dot_size * body, 0.5);
		float ang = atan(l.y, l.x);
		float rr = r * (1.0 + 0.12 * sin(ang * 3.0 + hc.x * 6.283) + 0.07 * sin(ang * 7.0 + hc.y * 12.0));
		vec2 lr = rot2(l, hc.z * 6.283);
		shape_d = (length(lr * vec2(1.0, 1.2)) - rr) * scl;
		rgb *= 0.86 + 0.14 * sin(lr.y / max(inr, 0.5) * 16.0 + hc.x * 4.0);
	} else if (style == 6) {
		float g2 = gap_px + 0.06 * inr;
		float r2 = max(rnd_px, 0.18 * inr);
		shape_d = TL_sdf(q, c, ucs, utp_m, g2, r2) * scl;
		float e = 0.35;
		vec2 grad = vec2(TL_sdf(q + vec2(e, 0.0), c, ucs, utp_m, g2, r2) - TL_sdf(q - vec2(e, 0.0), c, ucs, utp_m, g2, r2),
			TL_sdf(q + vec2(0.0, e), c, ucs, utp_m, g2, r2) - TL_sdf(q - vec2(0.0, e), c, ucs, utp_m, g2, r2));
		vec2 nrm = normalize(grad + vec2(1e-6));
		float edge = smoothstep(-0.3 * inr, 0.0, shape_d);
		rgb *= (0.92 + 0.16 * hc.x) * (1.0 + edge * dot(nrm, vec2(-0.7071, -0.7071)) * 0.45);
	} else if (style == 8) {
		// SVG stamp: library shape scaled to fit inside the tile.
		float half_box = max(dot_size * body, 0.5);
		vec2 suv = l / (2.0 * half_box) + 0.5;
		float sd = stamp_on ? texture(stamp_tex, clamp(suv, vec2(0.0), vec2(1.0))).r * 2.0 * half_box : (length(l) - half_box);
		if (any(lessThan(suv, vec2(0.0))) || any(greaterThan(suv, vec2(1.0)))) { sd = max(sd, 0.5); }
		shape_d = sd * scl;
	} else if (style == 7) {
		float wcell = 2.0 * body;
		float fx = clamp(l.x / max(wcell, 0.001) + 0.5, 0.0, 0.9999);
		int k = int(floor(fx * 3.0));
		float sub = fract(fx * 3.0) - 0.5;
		float inten = k == 0 ? rgb.r : (k == 1 ? rgb.g : rgb.b);
		// OLD: float spot = beam_on ? mix(1.0, 0.35 + 0.65 * inten, beam_amount) : 1.0;
		// WHY: beam spot (CRT) was removed; the phosphor cell style stays.
		float spot = 1.0;
		vec2 sp = vec2(sub * wcell / 3.0, l.y);
		vec2 hb = vec2(wcell / 3.0 * 0.36 * spot, body * 0.9 * spot);
		vec2 dd = abs(sp) - hb + vec2(hb.x * 0.5);
		float sd = length(max(dd, vec2(0.0))) + min(max(dd.x, dd.y), 0.0) - hb.x * 0.5;
		float lit = 1.0 - smoothstep(-aa, aa, sd * scl);
		vec3 ch = vec3(k == 0 ? 1.0 : 0.0, k == 1 ? 1.0 : 0.0, k == 2 ? 1.0 : 0.0);
		rgb = ch * inten * 1.25 * lit;
	}

	float cover = (1.0 - smoothstep(-aa, aa, shape_d)) * alpha_mul;
	vec4 outc = vec4(rgb, col.a * cover);
	if (style == 4 || style == 7) {
		outc.a = col.a * (1.0 - smoothstep(-aa, aa, tile_d));
	}
	// Fine texture: pattern drawn inside the cell at canvas coordinates.
	float Lc = rgb_to_oklab(col.rgb).x;
	for (int i = 0; i < 4; i++) {
		if (!pin[i] || pat_fine[i] <= 0.0) { continue; }
		vec4 fl = vec4(0.0);
		if (flow_on && flow_patterns) { fl = vec4(texture(flow_tex, p / canvas_px).rg, flow_strength, flow_drift); }
		float tv = pat_src[i] == 0 ? pat_raster(i, p / canvas_px) : pattern_eval(pat_src[i], p, ucs, pat_a[i], pat_b[i], Lc, fl);
		outc.rgb *= mix(1.0, 0.45 + 1.1 * tv, pat_fine[i]);
	}
	if ((gap_on || gap_over) && grout_on) {
		outc = composite(grout_color, outc, 0);
	}
	if (pat_view >= 0 && pat_view < pat_count && pin[pat_view]) {
		outc = vec4(mix(outc.rgb, vec3(pv[pat_view]), 0.85), 1.0);
	}
	return outc;
}

void fragment() {
	vec2 p = canvas_point(UV);
	vec2 fw = fwidth(node_origin + UV * node_size);
	float aa = max(max(fw.x, fw.y) * 0.5, 0.02);
	COLOR = layer_color(p, aa);
}
"""


static func overlay_shader_code(t: Tiling) -> String:
	return """shader_type canvas_item;
render_mode blend_mix, unshaded;
uniform sampler2D sel_tex : filter_nearest, repeat_disable;
uniform bool has_sel = false;
uniform bool grid_on = true;
uniform vec4 grid_color : source_color = vec4(1.0, 1.0, 1.0, 0.18);
uniform float ucs = 8.0;
uniform vec4 utp = vec4(0.0);
uniform ivec2 grid = ivec2(1);
""" + COMMON + t.glsl() + """
bool sel_at(ivec2 c) {
	if (c.x < 0 || c.y < 0 || c.x >= grid.x || c.y >= grid.y) { return false; }
	return texelFetch(sel_tex, c, 0).r > 0.5;
}
void fragment() {
	vec2 raw = node_origin + UV * node_size;
	vec2 p = canvas_point(UV);
	vec2 px = fwidth(raw);
	ivec2 c0 = TL_cell(p, ucs, utp);
	ivec2 cx = TL_cell(p + vec2(px.x, 0.0), ucs, utp);
	ivec2 cy = TL_cell(p + vec2(0.0, px.y), ucs, utp);
	vec4 col = vec4(0.0);
	float density = ucs / max(px.x, 1e-4);
	if (grid_on && density > 5.0 && (c0 != cx || c0 != cy)) {
		col = grid_color;
		col.a *= clamp((density - 5.0) / 6.0, 0.0, 1.0);
	}
	if (has_sel) {
		bool s0 = sel_at(c0);
		if (s0 != sel_at(cx) || s0 != sel_at(cy)) {
			float ants = step(0.5, fract((raw.x + raw.y) / px.x / 10.0 - TIME * 1.5));
			col = vec4(vec3(ants), 1.0);
		} else if (s0) {
			col = mix(col, vec4(0.35, 0.65, 1.0, 1.0), 0.14);
			col.a = max(col.a, 0.14);
		}
	}
	COLOR = col;
}
"""
