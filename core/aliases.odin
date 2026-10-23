package core

// What every format shares, and the names a caller working with several formats writes once. Each format
// aliases the ones it exposes. Where they live:
//
//	aliases.odin          paths: `Path`, `Path_Spec`, `Step`, `parse_path`, `MAX_PATH_STEPS` (syntax in path/)
//	strictness.odin       `Strictness`; duplicates.odin `Duplicates`
//	input.odin            the supported targets, `bom_len`
//	number.odin           `Number`, `Exactness`, `fold_digits`
//	type_plan.odin        `Type_Plan`, `Plan_Opts`, `Plan_Format`, `Enum_Spelling`, `Tag_Name`, `Unmarshal_Hook`,
//	                      `Type_Hook(W)`, `Hooked_Plan(W)`
//	plan_cache.odin       `Plan_Cache`, `plan_for`, `plan_done`, `plan_cache_clear`; plan_enum.odin an enum
//	                      field's value and member
//	shape.odin            the read shape: `Read_Shape`, `Shape_Op`, `Shape_Kind`, `Value_Class`, `Unknown_Fields`
//	read_shape_lower.odin `read_shape_of`
//	shape_store.odin      the judged scalar stores; shape_load.odin their loads
//	scan_error.odin       `Error`, `Error_Kind`; unmarshal_error.odin `Unmarshal_Error`; render_error.odin their text
//	batch_runner.odin     `Batch_Runner`, `Batch_Cursor`; stream_window.odin `Stream_Window`
//	edit.odin             `Edit`, the byte-span edit every format's text edits apply
//	path_error.odin       `Path_Error`, `Path_Error_Kind`: why a path procedure (find, set, splice) refused
//	marshal_error.odin    `Marshal_Error`: why a marshal refused
//
// spell/ spells integers and floats for the writers; bits/ holds the bit and UTF-8 kernels.

import p "path"

Step :: p.Step
Name :: p.Name
Index :: p.Index
Any :: p.Any
Path :: p.Path
Parse_Error :: p.Parse_Error
Parse_Fault :: p.Parse_Fault

parse_path :: p.parse_path

// A path as a procedure takes it: text in the path syntax, or a built `Path`.
Path_Spec :: union {
	string,
	Path,
}

// The most steps a path may hold wherever a format reads one, so a parsed path fits a fixed array of steps.
MAX_PATH_STEPS :: 32
