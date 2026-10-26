package core

// The types and procedures shared by every format, so a caller using several formats writes them once. Each
// format aliases the names it exposes. Files:
//
//	core.odin             `Path_Spec`, `MAX_PATH_STEPS`, `parse_path`; path_parse.odin the path syntax: `Path`, `Step`
//	strictness.odin       `Strictness`; duplicates.odin `Duplicates`
//	input.odin            the supported targets, `bom_len`
//	number.odin           `Number`, `Exactness`, `fold_digits`
//	type_plan.odin        `Type_Plan`, `Plan_Opts`, `Plan_Format`, `Enum_Spelling`, `Tag_Name`, `Unmarshal_Hook`,
//	                      `Type_Hook(W)`, `Hooked_Plan(W)`
//	plan_cache.odin       `Plan_Cache`, `plan_for`, `plan_done`, `plan_cache_clear`; plan_enum.odin enum value
//	                      and member lookup
//	shape.odin            the read shape: `Read_Shape`, `Shape_Op`, `Shape_Kind`, `Value_Class`, `Unknown_Fields`
//	read_shape_lower.odin `read_shape_of`
//	shape_store.odin      the judged scalar stores; shape_load.odin their loads
//	scan_error.odin       `Error`, `Error_Kind`; unmarshal_error.odin `Unmarshal_Error`; render_error.odin their text
//	batch_runner.odin     `Batch_Runner`, `Batch_Cursor`, `Batch_Driver`, `Record_Fault`, `Fault_List`;
//	                      stream_window.odin `Stream_Window`
//	record_read.odin      `Record_Read`, `Record_Source`, `record_read_init`, `unmarshal` of one record
//	answer.odin           `Answer`, `Answer_Outcome`, `NO_OWNER`, `answer_cut`: one path query's answer
//	edit.odin             `Edit`, the byte-span edit that every format's text edits use
//	path_error.odin       `Path_Error`, `Path_Error_Kind`: path procedure (find, set, splice) errors
//	marshal_error.odin    `Marshal_Error`: marshal errors
//
// spell/ formats integers and floats for the writers; bits.odin and bits_utf8.odin hold the bit and UTF-8 kernels.

// `parse_path_fault` with its fault as a `Path_Error`: `.Over_Capacity` when `steps` or `names` cannot hold the
// path, else `.Bad_Path` at the byte of `text` the parser stopped on.
parse_path :: proc(text: string, steps: []Step, names: []u8 = nil) -> (out: Path, err: Maybe(Path_Error)) {
	parsed, fault := parse_path_fault(text, steps, names)
	if f, bad := fault.?; bad {
		return {}, Path_Error{kind = .Over_Capacity if f.error == .Out_Of_Room else .Bad_Path, offset = f.offset}
	}
	return parsed, nil
}

// A path argument: text in the path syntax, or a built `Path`.
Path_Spec :: union {
	string,
	Path,
}

// The maximum number of steps in a path, in every format, so a parsed path fits a fixed array.
MAX_PATH_STEPS :: 32
