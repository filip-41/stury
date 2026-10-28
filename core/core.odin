package core

// The types and procedures shared by every format, so a caller using several formats writes them once. Each
// format aliases the names it exposes. Files:
//
//	core.odin             `Path_Spec`, `MAX_PATH_STEPS`, `MAX_PATH_QUERIES`, `parse_path`; path_parse.odin the path syntax:
//	                      `Path`, `Step`
//	strictness.odin       `Strictness`, `Read_Opts`; duplicates.odin `Duplicates`
//	max_depth.odin        `MAX_DEPTH`
//	input.odin            the supported targets, `bom_len`
//	number.odin           `Number`, `Exactness`, `fold_digits`, `fold_int`, `number_span`, `number_of_loose_text`: a decimal's value
//	number_lex.odin       `Number_Lex`, `lex_number_span`, `lex_number_value`, `SCAN_FORCE_SLOW`; number_dom_acc.odin,
//	                      number_el.odin and number_exact.odin decode a long mantissa, Eisel-Lemire, exactness
//	shape_round.odin      `shape_off_halfway`: a decimal's single rounding into f32 or f16
//	type_plan.odin        `Type_Plan`, `Plan_Opts`, `Plan_Format`, `Enum_Spelling`, `Tag_Name`, `Unmarshal_Hook`,
//	                      `Hook_Value`, `Marshal_Out`, `Marshal_Hook`, `marshal_into`, `Type_Hook`, `Hooked_Plan`,
//	                      `Shared_Plan`, `Plan_Mapping`, `SHARED_TAG_KEY`; plan_compile.odin `plan_op`, the per-kind
//	                      compilers and the rollback of a failed compile; plan_layout.odin a struct's field run, a
//	                      union's arms and `arm_tag_name`, and a field tag's spelling
//	plan_cache.odin       `plan_for`, `plan_done`, `plan_cache_clear` over one cache for every format; plan_enum.odin
//	                      enum value, member lookup, `plan_enum_written` and `plan_union_arm`
//	plan_write.odin       `Plan_Writer`, `Plan_Target`: a format's writer's pointers, `any`s, unions, hooks and refusal
//	                      paths, over its value writer
//	shape.odin            the read shape: `Read_Shape`, `Shape_Op`, `Shape_Kind`, `Value_Class`, `Unknown_Fields`
//	read_shape_lower.odin `read_shape_of`
//	shape_store.odin      the judged scalar stores; shape_load.odin their loads
//	shape_run.odin        `Shape_Run`, `Shape_Frame`, `Walk_Error`, `TYPED_FAULT`, the walk classes `VC_*`: the
//	                      typed walk's state; shape_walk.odin its transitions, generic over a format's leaves;
//	                      shape_leaf.odin the leaves every format shares; shape_rows.odin `shape_rows`, the walk
//	                      over a `Document`
//	scan_error.odin       `Error`, `Error_Kind`; unmarshal_error.odin `Unmarshal_Error`, `Unmarshal_Error_Kind`;
//	                      render_error.odin their text and positions (`render_error`, `error_position`)
//	batch_runner.odin     `Batch_Runner`, `Batch_Cursor`, `Batch_Driver`, `piece_fan`, `Record_Fault`, `Fault_List`;
//	                      stream_window.odin `Stream_Window`
//	record_read.odin      `Unmarshal_Opts`, `Record_Read`, `Record_Source`, `record_read_init`, `unmarshal` of one
//	                      record, `record_read_destroy`
//	answer.odin           `Answer`, `Answer_Outcome`, `Kind`, `Node`, `NO_NODE`, `NO_OWNER`, `answer_cut`,
//	                      `per_element_outcome`, `steps_have_any`: one path query's answer
//	rows.odin             the row tree: `Row`, `Row_Flags`, `Row_Payload`, `SPELLED_NUMBER`, `Fact`, `Fact_Place`,
//	                      `NO_KEY`, `ROOT`, `MAX_ROW_SOURCE` and the tape navigation (`dom_*`)
//	row_spelling.odin     `Row_Spelling`: how a format variant's flagged rows are read
//	row_document.odin     `Document` and its two tiers, `Row_Cache` (`row_cache`), `kind`, `child_count`,
//	                      `child_by_index`, `members_of`, `children_next`, `Members`, `get_raw`, `facts`;
//	                      name_arena.odin `Name_Arena`, the store of names decoded on read
//	row_read.odin         the scalar reads: `get_string`, `get_key`, `get_number`, `get_int`, `get_float`,
//	                      `get_bool`, `row_key_equals`; row_number.odin a plain number row's decode (`number_token`,
//	                      `int_token`, `int_span`)
//	row_walk.odin         `child`, `child_by_key`, `children`, `members`, `members_next`, `pointer`
//	row_query.odin        `query`, `query_in`, `Query_Walk`, `query_from`, `holder_of`: a path over a document
//	request.odin          `Request`, `request_init`, `answers`, `Route`, `Route_Class`: what every format's
//	                      request shares
//	edit.odin             `Edit`, the byte-span edit that every format's text edits use, `Insert_At`, `APPEND`;
//	                      `Edits` and `path_edit`, the path edits over a format's half of them
//	path_error.odin       `Path_Error`, `Path_Error_Kind`: path procedure (find, set, splice) errors
//	marshal_error.odin    `Marshal_Error`, `Marshal_Error_Kind`: marshal errors
//
// spell/ formats integers and floats for the writers and holds their put layer (put.odin); bits.odin and
// bits_utf8.odin hold the bit and UTF-8 kernels.

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

// The most paths one request is sure to answer in one pass, in every format. A format may refuse more as
// `.Over_Capacity` before reading a byte; JSON answers more when some are names its matcher serves.
MAX_PATH_QUERIES :: 16
