class_name Exporter
extends RefCounted
## PLACEHOLDER. The real exporter (registry + GIF / APNG encoders) was written
## in the cloud session but never pushed: the .gitignore rule `export/` also
## matched this src/export/ folder. This stub only lets main.gd load so the
## editor runs. Replace it with the real file once it's recovered.

const FORMATS: Array = [
	{"id": "png", "name": "PNG (export unavailable)", "ext": "png"},
]


static func default_options() -> Dictionary:
	return {"format": 0, "scale": 1, "raw": false, "only_selected": false, "repeat": 1}


static func render_frame(_main: Node, _hub: Object, _from: int, _to: int, _opts: Dictionary) -> Image:
	return null


static func write(_main: Node, _hub: Object, _path: String, _opts: Dictionary) -> String:
	return "Export isn't available: the exporter code is missing (placeholder in src/export/exporter.gd)."
