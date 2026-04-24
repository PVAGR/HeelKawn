class_name GameSave
extends Object

## Single-file `store_var` save. Version key lives in the snapshot dict ("v").
const SAVE_VERSION: int = 1
const DEFAULT_PATH: String = "user://heelkawn_colony.sav"

static func get_save_path() -> String:
	return DEFAULT_PATH


static func write_file(path: String, snapshot: Dictionary) -> Error:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var(snapshot, true)
	f.close()
	return OK


static func read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = f.get_var(true)
	f.close()
	if v is Dictionary:
		return v
	return {}
