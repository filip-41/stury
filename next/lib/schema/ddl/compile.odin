// Compiles SQL `CREATE TABLE` DDL into `stury:lib/schema/rules.Description` and `stury:lib/schema/check.Plan`,
// preserving table metadata (primary key, unique column groups, foreign keys, uncompiled cross-column checks).
// Zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean, OOM-safe.
package ddl

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

Compile_Options :: struct {
	table_name:       string,
	as_array:         bool,
	strict_columns:   Maybe(bool),
	default_optional: Maybe(bool),
	assert_format:    Maybe(bool),
	strict_checks:    bool,
	dups:             tape.Duplicates,
	budget:           tape.Budget,
}

Table_Meta :: struct {
	schema_name:       string,
	table_name:        string,
	primary_key:       []string,
	unique_columns:    [][]string,
	foreign_keys:      []Foreign_Key,
	uncompiled_checks: int,
}

Compiled :: struct {
	description: rules.Description,
	plan:        check.Plan,
	meta:        Table_Meta,
	opts:        Compile_Options,
	arena:       mem.Dynamic_Arena,
	arena_ready: bool,
	allocator:   runtime.Allocator,
}

@(require_results)
compile_description :: proc(src: []u8, opts := Compile_Options{}, allocator := context.allocator) -> (desc: rules.Description, err: Error) {
	parsed, perr := parse_ddl(src, allocator)
	if perr.kind != .None {
		return {}, perr
	}
	defer parsed_destroy(&parsed)

	tbl, terr := select_table(&parsed, opts.table_name, allocator)
	if terr.kind != .None {
		return {}, terr
	}
	return compile_table_description(&parsed, tbl, opts, nil, {}, allocator)
}

@(require_results)
compile_ddl :: proc(src: []u8, opts := Compile_Options{}, allocator := context.allocator) -> (c: ^Compiled, err: Error) {
	parsed, perr := parse_ddl(src, allocator)
	if perr.kind != .None {
		return nil, perr
	}
	defer parsed_destroy(&parsed)

	tbl, terr := select_table(&parsed, opts.table_name, allocator)
	if terr.kind != .None {
		return nil, terr
	}

	aerr: runtime.Allocator_Error
	c, aerr = new(Compiled, allocator)
	if aerr != nil || c == nil {
		return nil, make_error(.No_Memory, "out of memory", allocator = allocator)
	}
	c.allocator = allocator
	c.opts = opts
	mem.dynamic_arena_init(&c.arena, allocator, allocator)
	c.arena_ready = true

	desc, derr := compile_table_description(&parsed, tbl, opts, &c.meta, mem.dynamic_arena_allocator(&c.arena), allocator)
	if derr.kind != .None {
		destroy(c)
		return nil, derr
	}
	c.description = desc

	plan, cerr := check.compile(&c.description, allocator)
	if cerr.kind != .None {
		destroy(c)
		ek: Error_Kind = .No_Memory if cerr.kind == .No_Memory else .Compile
		return nil, Error{kind = ek, message = cerr.keyword, compile_err = cerr}
	}
	c.plan = plan
	return c, {}
}

destroy :: proc(c: ^Compiled) {
	if c == nil {
		return
	}
	a := c.allocator
	check.plan_destroy(&c.plan)
	rules.description_destroy(&c.description)
	if c.arena_ready {
		mem.dynamic_arena_destroy(&c.arena)
	}
	free(c, a)
}

@(require_results)
check_document :: proc(c: ^Compiled, doc: ^tape.Document, sink: ^check.Sink = nil, allocator := context.allocator) -> check.Result {
	if c == nil {
		return {valid = false, err = {kind = .Bad_Option, keyword = "compiled"}}
	}
	return check.check_document(doc, &c.plan, {dups = c.opts.dups, budget = c.opts.budget}, sink, allocator)
}

valid_document :: proc(c: ^Compiled, doc: ^tape.Document, allocator := context.allocator) -> bool {
	res := check_document(c, doc, nil, allocator)
	ok := res.valid
	check.result_destroy(&res)
	return ok
}

// ============================================================================
// Table selection, compiler helpers, and metadata extraction
// ============================================================================

@(private = "file")
select_table :: proc(parsed: ^Parsed, want: string, err_alloc: runtime.Allocator) -> (^Table_Def, Error) {
	if len(parsed.tables) == 0 {
		return nil, make_error(.No_Table, "no CREATE TABLE statement found in SQL DDL", allocator = err_alloc)
	}
	if want == "" {
		return &parsed.tables[0], {}
	}
	dot := strings.index_byte(want, '.')
	want_schema := want[:dot] if dot >= 0 else ""
	want_name := want[dot + 1:] if dot >= 0 else want
	for &t in parsed.tables {
		if ascii_eq_fold(t.name, want_name) && (want_schema == "" || ascii_eq_fold(t.schema_name, want_schema)) {
			return &t, {}
		}
	}
	return nil, make_error(.No_Table, "requested table not found in SQL DDL", table = want, allocator = err_alloc)
}

@(private = "file")
Compiler :: struct {
	parsed:           ^Parsed,
	tbl:              ^Table_Def,
	d:                ^rules.Description,
	opts:             Compile_Options,
	strict_columns:   bool,
	default_optional: bool,
	assert_format:    bool,
	col_not_null:     []bool,
	col_non_null_k:   []rules.Kinds,
	allocator:        runtime.Allocator,
	scratch:          runtime.Allocator,
	uncompiled:       int,
	err:              Error,
	oom:              bool,
}

@(private = "file")
c_failed :: proc "contextless" (c: ^Compiler) -> bool {
	return c.oom || c.err.kind != .None
}

@(private = "file")
c_push :: proc(c: ^Compiler, arr: ^[dynamic]$T, vals: ..T) -> bool {
	if _, err := append(arr, ..vals); err != nil {
		c.oom = true
		return false
	}
	return true
}

@(private = "file")
c_keep :: proc(c: ^Compiler, s: string) -> string {
	if c.oom || s == "" {
		return ""
	}
	cp, err := strings.clone(s, c.allocator)
	if err != nil {
		c.oom = true
		return ""
	}
	if !c_push(c, &c.d.texts, cp) {
		delete(cp, c.allocator)
		return ""
	}
	return cp
}

@(private = "file")
destroy_node_slices :: proc(n: ^rules.Node, a: runtime.Allocator) {
	delete(n.any_of, a)
	delete(n.enum_of, a)
	delete(n.examples, a)
	delete(n.all_of, a)
	delete(n.one_of, a)
	n.any_of, n.enum_of, n.examples, n.all_of, n.one_of = nil, nil, nil, nil, nil
}

@(private = "file")
c_add_node :: proc(c: ^Compiler, n: rules.Node) -> rules.Node_Index {
	n := n
	if c.oom || !c_push(c, &c.d.nodes, n) {
		destroy_node_slices(&n, c.allocator)
		return rules.NONE
	}
	return rules.Node_Index(len(c.d.nodes) - 1)
}

@(private = "file")
c_scalar :: proc(c: ^Compiler, n: rules.Node) -> rules.Node_Index {
	n := n
	n.array = -1
	n.object = -1
	return c_add_node(c, n)
}

@(private = "file")
c_not :: proc(c: ^Compiler, inner: rules.Node_Index, kinds: rules.Kinds = rules.EVERY_KIND) -> rules.Node_Index {
	return c_scalar(c, rules.Node{kinds = kinds, not = inner})
}

@(private = "file")
c_maybe_not :: proc(c: ^Compiler, inner: rules.Node_Index, negated: bool) -> (rules.Node_Index, bool, Null_Eval) {
	if c.oom {
		return rules.NONE, false, .Unknown
	}
	if !negated {
		return inner, true, .Unknown
	}
	return c_not(c, inner), !c.oom, .Unknown
}

@(private = "file")
c_add_object :: proc(c: ^Compiler, o: rules.Object) -> i32 {
	if c.oom || !c_push(c, &c.d.objects, o) {
		delete(o.members, c.allocator)
		delete(o.patterns, c.allocator)
		for x in o.dependents {
			delete(x.required, c.allocator)
		}
		delete(o.dependents, c.allocator)
		return -1
	}
	return i32(len(c.d.objects) - 1)
}

@(private = "file")
c_add_array :: proc(c: ^Compiler, a: rules.Array) -> i32 {
	if c.oom || !c_push(c, &c.d.arrays, a) {
		return -1
	}
	return i32(len(c.d.arrays) - 1)
}

@(private = "file")
c_find_col :: proc(c: ^Compiler, name: string) -> int {
	for col, i in c.tbl.columns {
		if ascii_eq_fold(col.name, name) {
			return i
		}
	}
	return -1
}

@(private = "file")
c_find_enum :: proc(c: ^Compiler, name: string) -> ([]string, bool) {
	for e in c.parsed.enums {
		if ascii_eq_fold(e.name, name) {
			return e.values, true
		}
	}
	return nil, false
}

@(private = "file")
flatten_and :: proc(c: ^Compiler, root: Expr_Index, work, out: ^[dynamic]Expr_Index) {
	clear(work)
	clear(out)
	_ = c_push(c, work, root)
	for len(work) > 0 && !c.oom {
		idx := pop(work)
		if idx == NO_EXPR {
			continue
		}
		e := c.parsed.exprs[idx]
		if e.kind == .And {
			_ = c_push(c, work, e.rhs, e.lhs)
		} else {
			_ = c_push(c, out, idx)
		}
	}
}

@(private = "file")
compile_table_description :: proc(
	parsed: ^Parsed,
	tbl: ^Table_Def,
	opts: Compile_Options,
	meta: ^Table_Meta,
	meta_alloc: runtime.Allocator,
	allocator: runtime.Allocator,
) -> (rules.Description, Error) {
	d := rules.Description {
		allocator = allocator,
		root      = rules.NONE,
	}
	d.nodes.allocator = allocator
	d.arrays.allocator = allocator
	d.objects.allocator = allocator
	d.texts.allocator = allocator
	d.anchors.allocator = allocator
	d.bases.allocator = allocator

	ok := false
	members: []rules.Member
	members_owned := false
	defer if !ok {
		if members_owned {
			delete(members, allocator)
		}
		rules.description_destroy(&d)
	}

	oom_err :: proc(a: runtime.Allocator) -> Error {
		return make_error(.No_Memory, "out of memory", allocator = a)
	}

	nm, nm_err := make(map[rules.Node_Index]string, 4, allocator)
	if nm_err != nil {
		return {}, oom_err(allocator)
	}
	d.names = nm

	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	col_nn, e1 := make([]bool, len(tbl.columns), scratch)
	col_kinds, e2 := make([]rules.Kinds, len(tbl.columns), scratch)
	col_extras, e3 := make([][dynamic]rules.Node_Index, len(tbl.columns), scratch)
	col_node_ids, e4 := make([]rules.Node_Index, len(tbl.columns), scratch)
	mem_err: runtime.Allocator_Error
	members, mem_err = make([]rules.Member, len(tbl.columns), allocator)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || mem_err != nil {
		delete(members, allocator)
		return {}, oom_err(allocator)
	}
	members_owned = true
	for i in 0 ..< len(tbl.columns) {
		col_extras[i].allocator = scratch
	}

	c := Compiler {
		parsed           = parsed,
		tbl              = tbl,
		d                = &d,
		opts             = opts,
		strict_columns   = opts.strict_columns.? or_else true,
		default_optional = opts.default_optional.? or_else true,
		assert_format    = opts.assert_format.? or_else true,
		col_not_null     = col_nn,
		col_non_null_k   = col_kinds,
		allocator        = allocator,
		scratch          = scratch,
	}

	for col, i in tbl.columns {
		c.col_not_null[i] = col.not_null || col.primary_key
	}
	for pk_col in tbl.primary_key {
		if idx := c_find_col(&c, pk_col); idx >= 0 {
			c.col_not_null[idx] = true
		}
	}

	for &col, i in tbl.columns {
		node_idx := build_column_node(&c, i, &col)
		if c_failed(&c) {
			return {}, c_final_error(&c)
		}
		col_node_ids[i] = node_idx
		c.col_non_null_k[i] = d.nodes[node_idx].kinds - {.Null}

		for chk in col.checks {
			apply_column_check(&c, i, node_idx, chk, &col_extras[i])
			if c_failed(&c) {
				return {}, c_final_error(&c)
			}
		}

		members[i] = {
			name     = c_keep(&c, col.name),
			node     = node_idx,
			required = c.col_not_null[i] && !(c.default_optional && col.has_default),
		}
		if c.oom {
			return {}, oom_err(allocator)
		}
	}

	row_all_of := make([dynamic]rules.Node_Index, scratch)
	tbl_work := make([dynamic]Expr_Index, scratch)
	tbl_conjuncts := make([dynamic]Expr_Index, scratch)
	for chk in tbl.checks {
		flatten_and(&c, chk, &tbl_work, &tbl_conjuncts)
		for conj in tbl_conjuncts {
			if c_failed(&c) {
				break
			}
			if target_col, is_single := check_single_column(&c, conj); is_single {
				apply_column_check(&c, target_col, col_node_ids[target_col], conj, &col_extras[target_col])
			} else if obj_chk, compiled, _ := compile_bool_expr(&c, conj, -1, {}); compiled && obj_chk != rules.NONE {
				_ = c_push(&c, &row_all_of, obj_chk)
			}
		}
		if c_failed(&c) {
			return {}, c_final_error(&c)
		}
	}

	for i in 0 ..< len(tbl.columns) {
		if len(col_extras[i]) == 0 {
			continue
		}
		n := &d.nodes[col_node_ids[i]]
		if len(col_extras[i]) == 1 && can_inline_single_all_of(n, &d.nodes[col_extras[i][0]]) {
			inline_into(n, &d.nodes[col_extras[i][0]], allocator, &c.oom)
		} else if sl, serr := slice.clone(col_extras[i][:], allocator); serr != nil {
			c.oom = true
		} else {
			n.all_of = sl
		}
		if c.oom {
			return {}, oom_err(allocator)
		}
	}

	add_node := c_scalar(&c, rules.Node{kinds = {}}) if c.strict_columns else rules.NONE
	members_owned = false
	obj_idx := c_add_object(&c, rules.Object{members = members, additional = add_node, keys = rules.NONE})
	if c.oom {
		return {}, oom_err(allocator)
	}

	row_node := rules.Node{kinds = {.Object}, array = -1, object = obj_idx, title = c_keep(&c, tbl.name)}
	if len(row_all_of) > 0 {
		if sl, serr := slice.clone(row_all_of[:], allocator); serr != nil {
			c.oom = true
		} else {
			row_node.all_of = sl
		}
	}
	row_idx := c_add_node(&c, row_node)
	if !c.oom {
		tname := c_keep(&c, tbl.name)
		if !c.oom {
			if _, merr := map_insert(&d.names, row_idx, tname); merr != nil {
				c.oom = true
			}
		}
	}
	if c.oom {
		return {}, oom_err(allocator)
	}

	if opts.as_array {
		has_unique := len(tbl.primary_key) > 0 || len(tbl.uniques) > 0
		for col in tbl.columns {
			if col.primary_key || col.unique {
				has_unique = true
				break
			}
		}
		arr_idx := c_add_array(&c, rules.Array{items = row_idx})
		d.root = c_add_node(&c, rules.Node{kinds = {.Array}, array = arr_idx, object = -1, rules = {unique = has_unique}})
		if c.oom {
			return {}, oom_err(allocator)
		}
	} else {
		d.root = row_idx
	}

	if meta != nil && !populate_meta(&c, meta, meta_alloc) {
		return {}, oom_err(allocator)
	}

	ok = true
	return d, {}
}

@(private = "file")
c_final_error :: proc(c: ^Compiler) -> Error {
	if c.err.kind != .None {
		return c.err
	}
	return make_error(.No_Memory, "out of memory", allocator = c.allocator)
}

@(private = "file")
clone_s :: proc(s: string, a: runtime.Allocator) -> (string, bool) {
	if s == "" {
		return "", true
	}
	cp, err := strings.clone(s, a)
	return cp, err == nil
}

@(private = "file")
clone_ss :: proc(xs: []string, a: runtime.Allocator) -> ([]string, bool) {
	if len(xs) == 0 {
		return nil, true
	}
	out, err := make([]string, len(xs), a)
	if err != nil {
		return nil, false
	}
	for s, i in xs {
		cp, ok := clone_s(s, a)
		if !ok {
			return nil, false
		}
		out[i] = cp
	}
	return out, true
}

@(private = "file")
clone_fk :: proc(fk: Foreign_Key, a: runtime.Allocator) -> (out: Foreign_Key, ok: bool) {
	ok1, ok2, ok3, ok4: bool
	out.name, ok1 = clone_s(fk.name, a)
	out.ref_table, ok2 = clone_s(fk.ref_table, a)
	out.columns, ok3 = clone_ss(fk.columns, a)
	out.ref_columns, ok4 = clone_ss(fk.ref_columns, a)
	return out, ok1 && ok2 && ok3 && ok4
}

@(private = "file")
populate_meta :: proc(c: ^Compiler, meta: ^Table_Meta, a: runtime.Allocator) -> bool {
	ok1, ok2: bool
	meta.schema_name, ok1 = clone_s(c.tbl.schema_name, a)
	meta.table_name, ok2 = clone_s(c.tbl.name, a)
	if !ok1 || !ok2 {
		return false
	}
	meta.uncompiled_checks = c.uncompiled

	if len(c.tbl.primary_key) > 0 {
		pk, ok := clone_ss(c.tbl.primary_key, a)
		if !ok {
			return false
		}
		meta.primary_key = pk
	} else {
		pk_list := make([dynamic]string, a)
		for col in c.tbl.columns {
			if col.primary_key {
				cp, ok := clone_s(col.name, a)
				if !ok {
					return false
				}
				if _, err := append(&pk_list, cp); err != nil {
					return false
				}
			}
		}
		meta.primary_key = pk_list[:]
	}

	ug := make([dynamic][]string, a)
	for col in c.tbl.columns {
		if col.primary_key || col.unique {
			one, ok := clone_ss({col.name}, a)
			if !ok {
				return false
			}
			if _, err := append(&ug, one); err != nil {
				return false
			}
		}
	}
	for u in c.tbl.uniques {
		grp, ok := clone_ss(u.columns, a)
		if !ok {
			return false
		}
		if _, err := append(&ug, grp); err != nil {
			return false
		}
	}
	meta.unique_columns = ug[:]

	fks := make([dynamic]Foreign_Key, a)
	for col in c.tbl.columns {
		if fk, has := col.references.?; has {
			cp, ok := clone_fk(fk, a)
			if !ok {
				return false
			}
			if _, err := append(&fks, cp); err != nil {
				return false
			}
		}
	}
	for fk in c.tbl.foreign_keys {
		cp, ok := clone_fk(fk, a)
		if !ok {
			return false
		}
		if _, err := append(&fks, cp); err != nil {
			return false
		}
	}
	meta.foreign_keys = fks[:]
	return true
}

// ============================================================================
// SQL column type -> rules.Node compilation
// ============================================================================

@(private = "file")
build_column_node :: proc(c: ^Compiler, col_idx: int, col: ^Column_Def) -> rules.Node_Index {
	not_null := c.col_not_null[col_idx]
	elem := build_scalar_type_node(c, col.type, not_null || col.type.is_array)
	if c.oom {
		destroy_node_slices(&elem, c.allocator)
		return rules.NONE
	}

	n := elem
	if col.type.is_array {
		elem_idx := c_add_node(c, elem)
		arr_idx := c_add_array(c, rules.Array{items = elem_idx})
		n = {kinds = {.Array} if not_null else {.Array, .Null}, array = arr_idx, object = -1}
	}
	if col.has_default_lit {
		if val, vok := literal_to_value(c, col.default_lit); vok && value_matches_kinds(val, n.kinds) {
			n.default_of = val
		}
	}
	return c_add_node(c, n)
}

@(private = "file")
Int_Bounds :: struct { smin, smax, umax: string }

@(private = "file")
INT_BOUNDS := [?]struct { kind: Sql_Type_Kind, b: Int_Bounds }{
	{.TinyInt,     {"-128", "127", "255"}},
	{.SmallInt,    {"-32768", "32767", "65535"}},
	{.SmallSerial, {"-32768", "32767", "65535"}},
	{.MediumInt,   {"-8388608", "8388607", "16777215"}},
	{.Int,         {"-2147483648", "2147483647", "4294967295"}},
	{.Serial,      {"-2147483648", "2147483647", "4294967295"}},
	{.BigInt,      {"-9223372036854775808", "9223372036854775807", "18446744073709551615"}},
	{.BigSerial,   {"-9223372036854775808", "9223372036854775807", "18446744073709551615"}},
}

@(private = "file")
build_scalar_type_node :: proc(c: ^Compiler, t: Sql_Type, not_null: bool) -> (n: rules.Node) {
	n = {array = -1, object = -1}

	switch t.kind {
	case .TinyInt, .SmallInt, .SmallSerial, .MediumInt, .Int, .Serial, .BigInt, .BigSerial:
		n.kinds = {.Integer}
		for entry in INT_BOUNDS {
			if entry.kind == t.kind {
				n.rules.minimum = "0" if t.unsigned else entry.b.smin
				n.rules.maximum = entry.b.umax if t.unsigned else entry.b.smax
				break
			}
		}
	case .Float, .Double:
		n.kinds = {.Number}
		if t.unsigned {
			n.rules.minimum = "0"
		}
	case .Numeric:
		build_numeric_type(c, t, &n)
	case .Bool:
		n.kinds = {.Bool}
	case .Text, .Varchar, .Char:
		n.kinds = {.String}
		if t.has_len && (t.kind != .Text || t.len > 0) {
			n.rules.max_length = t.len
			if t.kind == .Char {
				n.rules.min_length = t.len
			}
		}
	case .Uuid, .Date, .Time, .Timestamp:
		n.kinds = {.String}
		n.rules.assert_format = c.assert_format
		#partial switch t.kind {
		case .Uuid:      n.rules.format = "uuid"
		case .Date:      n.rules.format = "date"
		case .Time:      n.rules.format = "time"
		case .Timestamp: n.rules.format = "date-time"
		}
	case .Bytes:
		n.kinds = {.String}
	case .Enum:
		n.kinds = {.String}
		build_string_enum(c, t.enum_values, not_null, &n)
	case .Named:
		if vals, found := c_find_enum(c, t.named); found {
			n.kinds = {.String}
			build_string_enum(c, vals, not_null, &n)
		} else {
			n.kinds = rules.EVERY_KIND - {.Null}
		}
	case .Json, .Unknown:
		n.kinds = rules.EVERY_KIND - {.Null}
	}

	if !not_null {
		n.kinds += {.Null}
	}
	return
}

@(private = "file")
build_numeric_type :: proc(c: ^Compiler, t: Sql_Type, n: ^rules.Node) {
	n.kinds = {.Number}
	if t.unsigned {
		n.rules.minimum = "0"
	}
	if !t.has_len || t.len == 0 || t.len > 38 {
		return
	}
	scale_u := t.scale if t.has_scale else 0
	if scale_u > t.len {
		return
	}
	p, s := int(t.len), int(scale_u)
	int_digits := p - s

	// Build `max_buf`: `999...` (if s == 0) or `999.999` (or `0.999` if p == s).
	buf: [65]u8 = ---
	buf[0] = '-'
	pos := 1
	if s == 0 {
		n.kinds = {.Integer}
		for _ in 0 ..< p {
			buf[pos] = '9'
			pos += 1
		}
	} else {
		if int_digits == 0 {
			buf[pos] = '0'
			pos += 1
		} else {
			for _ in 0 ..< int_digits {
				buf[pos] = '9'
				pos += 1
			}
		}
		buf[pos] = '.'
		pos += 1
		for _ in 0 ..< s {
			buf[pos] = '9'
			pos += 1
		}
		step: [64]u8 = ---
		step[0], step[1] = '0', '.'
		for i in 0 ..< s - 1 {
			step[2 + i] = '0'
		}
		step[2 + s - 1] = '1'
		n.rules.multiple_of = c_keep(c, string(step[:2 + s]))
	}
	n.rules.maximum = c_keep(c, string(buf[1:pos]))
	if !t.unsigned {
		n.rules.minimum = c_keep(c, string(buf[:pos]))
	}
}

@(private = "file")
build_string_enum :: proc(c: ^Compiler, vals: []string, not_null: bool, n: ^rules.Node) {
	extra := 0 if not_null else 1
	out, err := make([]rules.Value, len(vals) + extra, c.allocator)
	if err != nil {
		c.oom = true
		return
	}
	for v, i in vals {
		out[i] = rules.Value(c_keep(c, v))
		if c.oom {
			delete(out, c.allocator)
			return
		}
	}
	if !not_null {
		out[len(vals)] = rules.Null{}
	}
	n.enum_of = out
	n.has_enum = true
}

@(private = "file")
literal_to_value :: proc(c: ^Compiler, lit: Literal) -> (rules.Value, bool) {
	switch lit.kind {
	case .Null:    return rules.Null{}, true
	case .Bool:    return lit.bool_val, true
	case .Integer: return lit.int_val, true
	case .Decimal:
		txt := c_keep(c, lit.text)
		return rules.Number_Text{text = txt}, !c.oom
	case .String:
		txt := c_keep(c, lit.text)
		return txt, !c.oom
	}
	return nil, false
}

@(private = "file")
value_matches_kinds :: proc "contextless" (v: rules.Value, kinds: rules.Kinds) -> bool {
	#partial switch x in v {
	case rules.Null:   return .Null in kinds
	case bool:         return .Bool in kinds
	case i64, u64:     return .Integer in kinds || .Number in kinds
	case f64:          return .Number in kinds
	case string:       return .String in kinds
	case rules.Number_Text:
		if .Number in kinds {
			return true
		}
		if .Integer in kinds && rules.valid_decimal_text(x.text) {
			d := rules.decimal_of(x.text)
			return d.head == "" || (d.wide == "" && d.point >= i128(len(d.head) + len(d.tail)))
		}
	}
	return false
}

@(private = "file")
expr_matches_col :: proc "contextless" (c: ^Compiler, e: Expr, col_name: string) -> bool {
	return (e.table_qual == "" || ascii_eq_fold(e.table_qual, c.tbl.name)) && ascii_eq_fold(e.ident, col_name)
}

// ============================================================================
// CHECK expression analysis & compilation (explicit stacks, zero recursion)
// ============================================================================

@(private = "file")
check_single_column :: proc(c: ^Compiler, root: Expr_Index) -> (int, bool) {
	stack := make([dynamic]Expr_Index, c.scratch)
	if !c_push(c, &stack, root) {
		return -1, false
	}
	found := -1
	for len(stack) > 0 {
		idx := pop(&stack)
		if idx == NO_EXPR {
			continue
		}
		e := c.parsed.exprs[idx]
		#partial switch e.kind {
		case .Ident, .Length_Call:
			if e.table_qual != "" && !ascii_eq_fold(e.table_qual, c.tbl.name) {
				return -1, false
			}
			ci := c_find_col(c, e.ident)
			if ci < 0 || (found >= 0 && found != ci) {
				return -1, false
			}
			found = ci
		case .Compare, .And, .Or:
			if !c_push(c, &stack, e.lhs, e.rhs) { return -1, false }
		case .Between:
			if !c_push(c, &stack, e.lhs, e.rhs, e.hi) { return -1, false }
		case .In_List, .Is_Null, .Like, .Not:
			if !c_push(c, &stack, e.lhs) { return -1, false }
		}
	}
	return found, found >= 0
}

@(private = "file")
mark_uncompiled :: proc(c: ^Compiler, e: Expr, msg: string) {
	c.uncompiled += 1
	if c.opts.strict_checks && c.err.kind == .None {
		c.err = make_error(.Bad_Check, msg, e.offset, e.line, e.col, table = c.tbl.name, allocator = c.allocator)
	}
}

@(private = "file")
apply_column_check :: proc(c: ^Compiler, col_idx: int, node_idx: rules.Node_Index, root: Expr_Index, extras: ^[dynamic]rules.Node_Index) {
	work := make([dynamic]Expr_Index, c.scratch)
	conjuncts := make([dynamic]Expr_Index, c.scratch)
	flatten_and(c, root, &work, &conjuncts)
	non_null_k := c.col_non_null_k[col_idx]

	for idx in conjuncts {
		if c_failed(c) {
			return
		}
		not_null := c.col_not_null[col_idx]
		if try_fold_direct_col_pred(c, col_idx, node_idx, idx, not_null) || c_failed(c) {
			continue
		}
		sub, compiled, null_eval := compile_bool_expr(c, idx, col_idx, non_null_k)
		if c_failed(c) || !compiled || sub == rules.NONE {
			continue
		}
		if !not_null && null_eval != .False {
			wok: bool
			sub, wok = wrap_allow_null(c, sub)
			if !wok {
				return
			}
		}
		_ = c_push(c, extras, sub)
	}
}

@(private = "file")
set_const_or_nullable_enum :: proc(c: ^Compiler, n: ^rules.Node, val: rules.Value, not_null: bool) -> bool {
	if n.has_enum || n.const_of != nil {
		return false
	}
	if not_null {
		n.const_of = val
		return true
	}
	vals, verr := make([]rules.Value, 2, c.allocator)
	if verr != nil {
		c.oom = true
		return true
	}
	vals[0], vals[1] = val, rules.Null{}
	n.enum_of = vals
	n.has_enum = true
	return true
}

@(private = "file")
merge_num_edge :: proc(c: ^Compiler, n: ^rules.Node, edge: rules.Rules) -> bool {
	if !c.oom {
		if merged_r, clash := rules.merged(n, edge); clash == "" {
			n.rules = merged_r
		}
	}
	return true
}

@(private = "file")
try_fold_direct_col_pred :: proc(c: ^Compiler, col_idx: int, node_idx: rules.Node_Index, idx: Expr_Index, not_null: bool) -> bool {
	e := c.parsed.exprs[idx]
	n := &c.d.nodes[node_idx]
	col_name := c.tbl.columns[col_idx].name

	#partial switch e.kind {
	case .Unsupported:
		mark_uncompiled(c, e, "unsupported expression in CHECK constraint")
		return true

	case .Is_Null:
		lhs := c.parsed.exprs[e.lhs]
		if lhs.kind != .Ident || !expr_matches_col(c, lhs, col_name) {
			return false
		}
		if e.negated {
			n.kinds -= {.Null}
			c.col_not_null[col_idx] = true
			if n.has_enum {
				strip_null_from_enum(n, c.allocator, &c.oom)
			}
		} else {
			n.kinds = {.Null}
		}
		return true

	case .Compare:
		return try_fold_compare(c, col_idx, n, e, not_null)

	case .Between:
		return !e.negated && try_fold_between(c, col_idx, n, e)

	case .In_List:
		if e.negated || n.has_enum || n.const_of != nil {
			return false
		}
		lhs := c.parsed.exprs[e.lhs]
		if lhs.kind != .Ident || !expr_matches_col(c, lhs, col_name) {
			return false
		}
		vals, vok := make_literal_values(c, e.literals, !not_null)
		if !vok {
			return true
		}
		n.enum_of = vals
		n.has_enum = true
		return true

	case .Like:
		if e.negated || n.rules.pattern != "" {
			return false
		}
		lhs := c.parsed.exprs[e.lhs]
		if lhs.kind != .Ident || !expr_matches_col(c, lhs, col_name) {
			return false
		}
		pat := like_to_ecma(c, e.pattern, e.escape)
		if !c.oom {
			n.rules.pattern = pat
		}
		return true
	}
	return false
}

@(private = "file")
make_literal_values :: proc(c: ^Compiler, lits: []Literal, add_null: bool) -> ([]rules.Value, bool) {
	extra := 1 if add_null else 0
	vals, verr := make([]rules.Value, len(lits) + extra, c.allocator)
	if verr != nil {
		c.oom = true
		return nil, false
	}
	for lit, i in lits {
		v, vok := literal_to_value(c, lit)
		if !vok {
			delete(vals, c.allocator)
			return nil, false
		}
		vals[i] = v
	}
	if add_null {
		vals[len(lits)] = rules.Null{}
	}
	return vals, true
}

@(private = "file")
strip_null_from_enum :: proc(n: ^rules.Node, allocator: runtime.Allocator, oom: ^bool) {
	kept := 0
	for v in n.enum_of {
		if _, is_null := v.(rules.Null); !is_null {
			kept += 1
		}
	}
	if kept == len(n.enum_of) {
		return
	}
	fresh, err := make([]rules.Value, kept, allocator)
	if err != nil {
		oom^ = true
		return
	}
	j := 0
	for v in n.enum_of {
		if _, is_null := v.(rules.Null); !is_null {
			fresh[j] = v
			j += 1
		}
	}
	delete(n.enum_of, allocator)
	n.enum_of = fresh
}

@(private = "file")
flip_cmp :: proc "contextless" (op: Cmp_Op) -> Cmp_Op {
	switch op {
	case .Eq:  return .Eq
	case .Neq: return .Neq
	case .Lt:  return .Gt
	case .Lte: return .Gte
	case .Gt:  return .Lt
	case .Gte: return .Lte
	}
	return op
}

@(private = "file")
normalize_compare :: proc(c: ^Compiler, col_idx: int, e: Expr) -> (Expr, Cmp_Op, Literal, bool) {
	lhs, rhs := c.parsed.exprs[e.lhs], c.parsed.exprs[e.rhs]
	col_name := c.tbl.columns[col_idx].name
	if (lhs.kind == .Ident || lhs.kind == .Length_Call) && expr_matches_col(c, lhs, col_name) && rhs.kind == .Literal {
		return lhs, e.cmp, rhs.lit, true
	}
	if (rhs.kind == .Ident || rhs.kind == .Length_Call) && expr_matches_col(c, rhs, col_name) && lhs.kind == .Literal {
		return rhs, flip_cmp(e.cmp), lhs.lit, true
	}
	return {}, .Eq, {}, false
}

@(private = "file")
try_fold_compare :: proc(c: ^Compiler, col_idx: int, n: ^rules.Node, e: Expr, not_null: bool) -> bool {
	target, op, lit, ok := normalize_compare(c, col_idx, e)
	if !ok {
		return false
	}
	if target.kind == .Length_Call {
		return lit.kind == .Integer && apply_length_cmp(&n.rules, op, lit.int_val)
	}
	switch lit.kind {
	case .Integer, .Decimal:
		#partial switch op {
		case .Gte, .Gt: return merge_num_edge(c, n, {minimum = c_keep(c, lit.text), exclusive_minimum = op == .Gt})
		case .Lte, .Lt: return merge_num_edge(c, n, {maximum = c_keep(c, lit.text), exclusive_maximum = op == .Lt})
		case .Eq:
			if n.has_enum || n.const_of != nil { return false }
			v, vok := literal_to_value(c, lit)
			return !vok || set_const_or_nullable_enum(c, n, v, not_null)
		}
	case .String:
		if op == .Eq {
			if n.has_enum || n.const_of != nil { return false }
			v, vok := literal_to_value(c, lit)
			return !vok || set_const_or_nullable_enum(c, n, v, not_null)
		}
		if op == .Neq && lit.text == "" {
			n.rules.min_length = max(n.rules.min_length, 1)
			return true
		}
	case .Bool:
		if op == .Eq || op == .Neq {
			return set_const_or_nullable_enum(c, n, rules.Value(lit.bool_val if op == .Eq else !lit.bool_val), not_null)
		}
	case .Null:
	}
	return false
}

@(private = "file")
apply_length_cmp :: proc "contextless" (r: ^rules.Rules, op: Cmp_Op, val: i64) -> bool {
	tighten :: proc "contextless" (slot: ^Maybe(u64), limit: u64) {
		if cur, has := slot^.(u64); has {
			slot^ = min(cur, limit)
		} else {
			slot^ = limit
		}
	}
	switch op {
	case .Gte:
		if val > 0 { r.min_length = max(r.min_length, u64(val)) }
		return true
	case .Gt:
		if val >= 0 { r.min_length = max(r.min_length, u64(val) + 1) }
		return true
	case .Lte:
		if val < 0 { return false }
		tighten(&r.max_length, u64(val))
		return true
	case .Lt:
		if val <= 0 { return false }
		tighten(&r.max_length, u64(val - 1))
		return true
	case .Eq:
		if val < 0 { return false }
		r.min_length = max(r.min_length, u64(val))
		tighten(&r.max_length, u64(val))
		return true
	case .Neq:
		if val == 0 {
			r.min_length = max(r.min_length, 1)
			return true
		}
	}
	return false
}

@(private = "file")
try_fold_between :: proc(c: ^Compiler, col_idx: int, n: ^rules.Node, e: Expr) -> bool {
	lhs, lo, hi := c.parsed.exprs[e.lhs], c.parsed.exprs[e.rhs], c.parsed.exprs[e.hi]
	col_name := c.tbl.columns[col_idx].name
	if lo.kind != .Literal || hi.kind != .Literal || !expr_matches_col(c, lhs, col_name) {
		return false
	}
	if lhs.kind == .Length_Call && lo.lit.kind == .Integer && hi.lit.kind == .Integer && hi.lit.int_val >= 0 {
		_ = apply_length_cmp(&n.rules, .Gte, lo.lit.int_val)
		return apply_length_cmp(&n.rules, .Lte, hi.lit.int_val)
	}
	if lhs.kind == .Ident && (lo.lit.kind == .Integer || lo.lit.kind == .Decimal) && (hi.lit.kind == .Integer || hi.lit.kind == .Decimal) {
		return merge_num_edge(c, n, {minimum = c_keep(c, lo.lit.text), maximum = c_keep(c, hi.lit.text)})
	}
	return false
}

@(private = "file")
Null_Eval :: enum u8 { False, Unknown, True }

@(private = "file")
is_pure_null :: proc "contextless" (n: ^rules.Node) -> bool {
	return n.kinds == {.Null} && is_bare_node(n) && len(n.all_of) == 0 && len(n.any_of) == 0 && n.not == nil
}

@(private = "file")
wrap_allow_null :: proc(c: ^Compiler, raw_node: rules.Node_Index) -> (rules.Node_Index, bool) {
	rn := &c.d.nodes[raw_node]
	if is_pure_null(rn) {
		return raw_node, true
	}
	if rn.not != nil && rn.kinds == rules.EVERY_KIND && is_bare_node(rn) && len(rn.all_of) == 0 && len(rn.any_of) == 0 {
		not_target := &c.d.nodes[rn.not.?]
		if .Null not_in not_target.kinds || not_target.const_of != nil || not_target.has_enum {
			return raw_node, true
		}
	}
	if is_pure_any_of(rn) {
		for arm in rn.any_of {
			if is_pure_null(&c.d.nodes[arm]) {
				return raw_node, true
			}
		}
	}
	null_arm := c_scalar(c, rules.Node{kinds = {.Null}})
	if c.oom {
		return rules.NONE, false
	}
	rn = &c.d.nodes[raw_node]
	if is_pure_any_of(rn) {
		arms, aerr := make([]rules.Node_Index, len(rn.any_of) + 1, c.allocator)
		if aerr != nil {
			c.oom = true
			return rules.NONE, false
		}
		copy(arms, rn.any_of)
		arms[len(rn.any_of)] = null_arm
		delete(rn.any_of, c.allocator)
		rn.any_of = arms
		return raw_node, true
	}
	arms, aerr := make([]rules.Node_Index, 2, c.allocator)
	if aerr != nil {
		c.oom = true
		return rules.NONE, false
	}
	arms[0], arms[1] = raw_node, null_arm
	wrap := c_scalar(c, rules.Node{kinds = rules.EVERY_KIND, any_of = arms})
	return wrap, !c.oom
}

@(private = "file")
Eval_Frame :: struct {
	expr:        Expr_Index,
	visited:     bool,
	strict_true: bool,
}

@(private = "file")
Eval_Result :: struct {
	node:      rules.Node_Index,
	ok:        bool,
	null_eval: Null_Eval,
}

// Unified explicit-stack post-order compiler for both single-column (`col_idx >= 0`) and
// multi-column table-level (`col_idx < 0`) boolean CHECK expressions under SQL 3-valued logic.
@(private = "file")
compile_bool_expr :: proc(
	c: ^Compiler,
	root: Expr_Index,
	col_idx: int,
	non_null_k: rules.Kinds,
) -> (rules.Node_Index, bool, Null_Eval) {
	is_table := col_idx < 0
	stack := make([dynamic]Eval_Frame, c.scratch)
	results := make([dynamic]Eval_Result, c.scratch)
	if !c_push(c, &stack, Eval_Frame{expr = root}) {
		return rules.NONE, false, .Unknown
	}

	for len(stack) > 0 && !c_failed(c) {
		fr := pop(&stack)
		if fr.expr == NO_EXPR {
			_ = c_push(c, &results, Eval_Result{node = rules.NONE, null_eval = .Unknown})
			continue
		}
		e := c.parsed.exprs[fr.expr]
		if !fr.visited && (e.kind == .And || e.kind == .Or || e.kind == .Not) {
			_ = c_push(c, &stack, Eval_Frame{expr = fr.expr, visited = true, strict_true = fr.strict_true})
			if e.kind == .Not {
				_ = c_push(c, &stack, Eval_Frame{expr = e.lhs, strict_true = !fr.strict_true})
			} else {
				_ = c_push(c, &stack, Eval_Frame{expr = e.rhs, strict_true = fr.strict_true}, Eval_Frame{expr = e.lhs, strict_true = fr.strict_true})
			}
			continue
		}

		#partial switch e.kind {
		case .Not:
			child := pop(&results)
			ne: Null_Eval = .True if child.null_eval == .False else (.False if child.null_eval == .True else .Unknown)
			if !child.ok || child.node == rules.NONE {
				_ = c_push(c, &results, Eval_Result{node = rules.NONE, null_eval = ne})
			} else {
				nid := c_not(c, child.node, {.Object} if is_table else rules.EVERY_KIND)
				_ = c_push(c, &results, Eval_Result{node = nid, ok = !c.oom, null_eval = ne})
			}

		case .And, .Or:
			r_res, l_res := pop(&results), pop(&results)
			ne: Null_Eval = .Unknown
			if e.kind == .And {
				if l_res.null_eval == .False || r_res.null_eval == .False { ne = .False } else if l_res.null_eval == .True && r_res.null_eval == .True { ne = .True }
			} else {
				if l_res.null_eval == .True || r_res.null_eval == .True { ne = .True } else if l_res.null_eval == .False && r_res.null_eval == .False { ne = .False }
			}
			if !l_res.ok || !r_res.ok {
				_ = c_push(c, &results, Eval_Result{node = rules.NONE, null_eval = ne})
			} else {
				nid := combine_logic(c, l_res.node, r_res.node, e.kind == .And)
				_ = c_push(c, &results, Eval_Result{node = nid, ok = !c.oom, null_eval = ne})
			}

		case:
			if !is_table {
				atom, aok, ane := compile_col_atom(c, col_idx, e, non_null_k)
				_ = c_push(c, &results, Eval_Result{node = atom, ok = aok, null_eval = ane})
			} else {
				res := compile_table_leaf(c, fr.expr, e, fr.strict_true)
				_ = c_push(c, &results, res)
			}
		}
	}

	if c_failed(c) || len(results) == 0 {
		return rules.NONE, false, .Unknown
	}
	res := results[len(results) - 1]
	return res.node, res.ok, res.null_eval
}

@(private = "file")
compile_table_leaf :: proc(c: ^Compiler, expr_idx: Expr_Index, e: Expr, strict_true: bool) -> Eval_Result {
	ci, is_single := check_single_column(c, expr_idx)
	if !is_single {
		mark_uncompiled(c, e, "cross-column CHECK predicate cannot be represented in rules.Description")
		return {node = rules.NONE}
	}
	col_pred, pok, atom_ne := compile_col_atom(c, ci, e, c.col_non_null_k[ci])
	if !pok || col_pred == rules.NONE {
		return {node = rules.NONE}
	}
	req := atom_ne != .True
	if atom_ne == .Unknown && !c.col_not_null[ci] {
		if !strict_true {
			req = false
			wok: bool
			col_pred, wok = wrap_allow_null(c, col_pred)
			if !wok {
				return {node = rules.NONE}
			}
		} else if .Null in c.d.nodes[col_pred].kinds {
			not_null_node := c_scalar(c, rules.Node{kinds = c.col_non_null_k[ci]})
			col_pred = combine_logic(c, not_null_node, col_pred, true)
			if c.oom {
				return {node = rules.NONE}
			}
		}
	}
	mems, merr := make([]rules.Member, 1, c.allocator)
	if merr != nil {
		c.oom = true
		return {node = rules.NONE}
	}
	mems[0] = {name = c_keep(c, c.tbl.columns[ci].name), node = col_pred, required = req}
	if c.oom {
		delete(mems, c.allocator)
		return {node = rules.NONE}
	}
	oid := c_add_object(c, rules.Object{members = mems, additional = rules.NONE, keys = rules.NONE})
	if c.oom {
		return {node = rules.NONE}
	}
	return {node = c_add_node(c, rules.Node{kinds = {.Object}, array = -1, object = oid}), ok = !c.oom}
}

@(private = "file")
col_num_kinds :: proc "contextless" (non_null_k: rules.Kinds) -> rules.Kinds {
	nk := non_null_k & {.Integer, .Number}
	return nk if nk != {} else {.Number}
}

@(private = "file")
compile_col_atom :: proc(c: ^Compiler, col_idx: int, e: Expr, non_null_k: rules.Kinds) -> (rules.Node_Index, bool, Null_Eval) {
	col_name := c.tbl.columns[col_idx].name

	#partial switch e.kind {
	case .Is_Null:
		lhs := c.parsed.exprs[e.lhs]
		if lhs.kind != .Ident || !expr_matches_col(c, lhs, col_name) {
			mark_uncompiled(c, e, "unsupported IS NULL target in CHECK")
			return rules.NONE, false, .Unknown
		}
		k := rules.EVERY_KIND - {.Null} if e.negated else rules.Kinds{.Null}
		return c_scalar(c, rules.Node{kinds = k}), !c.oom, .False if e.negated else .True

	case .Ident:
		if expr_matches_col(c, e, col_name) && .Bool in non_null_k {
			return c_scalar(c, rules.Node{kinds = {.Bool}, const_of = rules.Value(true)}), !c.oom, .Unknown
		}
		mark_uncompiled(c, e, "unsupported identifier predicate in CHECK")
		return rules.NONE, false, .Unknown

	case .Compare:
		target, op, lit, cok := normalize_compare(c, col_idx, e)
		if !cok {
			mark_uncompiled(c, e, "unsupported comparison in CHECK constraint")
			return rules.NONE, false, .Unknown
		}
		if target.kind == .Length_Call {
			if lit.kind != .Integer {
				mark_uncompiled(c, e, "non-integer LENGTH comparison in CHECK")
				return rules.NONE, false, .Unknown
			}
			if op == .Neq && lit.int_val > 0 {
				eq_n := c_scalar(c, rules.Node{kinds = {.String}, rules = {min_length = u64(lit.int_val), max_length = u64(lit.int_val)}})
				return c_maybe_not(c, eq_n, true)
			}
			n := rules.Node{kinds = {.String}}
			if !apply_length_cmp(&n.rules, op, lit.int_val) {
				mark_uncompiled(c, e, "unsatisfiable LENGTH comparison in CHECK")
				return rules.NONE, false, .Unknown
			}
			return c_scalar(c, n), !c.oom, .Unknown
		}
		switch lit.kind {
		case .Integer, .Decimal:
			nk := col_num_kinds(non_null_k)
			#partial switch op {
			case .Gte, .Gt: return c_scalar(c, rules.Node{kinds = nk, rules = {minimum = c_keep(c, lit.text), exclusive_minimum = op == .Gt}}), !c.oom, .Unknown
			case .Lte, .Lt: return c_scalar(c, rules.Node{kinds = nk, rules = {maximum = c_keep(c, lit.text), exclusive_maximum = op == .Lt}}), !c.oom, .Unknown
			case .Eq, .Neq:
				v, vok := literal_to_value(c, lit)
				if !vok { return rules.NONE, false, .Unknown }
				return c_maybe_not(c, c_scalar(c, rules.Node{kinds = nk, const_of = v}), op == .Neq)
			}
		case .String:
			if op == .Neq && lit.text == "" {
				return c_scalar(c, rules.Node{kinds = {.String}, rules = {min_length = 1}}), !c.oom, .Unknown
			}
			if op == .Eq || op == .Neq {
				v, vok := literal_to_value(c, lit)
				if !vok { return rules.NONE, false, .Unknown }
				return c_maybe_not(c, c_scalar(c, rules.Node{kinds = {.String}, const_of = v}), op == .Neq)
			}
		case .Bool:
			if op == .Eq || op == .Neq {
				return c_scalar(c, rules.Node{kinds = {.Bool}, const_of = rules.Value(lit.bool_val if op == .Eq else !lit.bool_val)}), !c.oom, .Unknown
			}
		case .Null:
			mark_uncompiled(c, e, "comparison with NULL in CHECK (use IS [NOT] NULL)")
			return rules.NONE, false, .Unknown
		}
		mark_uncompiled(c, e, "unsupported comparison operator/type in CHECK")
		return rules.NONE, false, .Unknown

	case .Between:
		lhs, lo, hi := c.parsed.exprs[e.lhs], c.parsed.exprs[e.rhs], c.parsed.exprs[e.hi]
		if lo.kind != .Literal || hi.kind != .Literal || !expr_matches_col(c, lhs, col_name) {
			mark_uncompiled(c, e, "unsupported BETWEEN expression in CHECK")
			return rules.NONE, false, .Unknown
		}
		if lhs.kind == .Length_Call && lo.lit.kind == .Integer && hi.lit.kind == .Integer && hi.lit.int_val >= 0 {
			inner := c_scalar(c, rules.Node{kinds = {.String}, rules = {min_length = u64(max(lo.lit.int_val, 0)), max_length = u64(hi.lit.int_val)}})
			return c_maybe_not(c, inner, e.negated)
		}
		if lhs.kind == .Ident && (lo.lit.kind == .Integer || lo.lit.kind == .Decimal) && (hi.lit.kind == .Integer || hi.lit.kind == .Decimal) {
			inner := c_scalar(c, rules.Node{kinds = col_num_kinds(non_null_k), rules = {minimum = c_keep(c, lo.lit.text), maximum = c_keep(c, hi.lit.text)}})
			return c_maybe_not(c, inner, e.negated)
		}
		mark_uncompiled(c, e, "unsupported BETWEEN expression in CHECK")
		return rules.NONE, false, .Unknown

	case .In_List:
		lhs := c.parsed.exprs[e.lhs]
		if lhs.kind != .Ident || !expr_matches_col(c, lhs, col_name) {
			mark_uncompiled(c, e, "unsupported IN target in CHECK")
			return rules.NONE, false, .Unknown
		}
		vals, vok := make_literal_values(c, e.literals, false)
		if !vok {
			return rules.NONE, false, .Unknown
		}
		return c_maybe_not(c, c_scalar(c, rules.Node{kinds = non_null_k, has_enum = true, enum_of = vals}), e.negated)

	case .Like:
		lhs := c.parsed.exprs[e.lhs]
		if lhs.kind != .Ident || !expr_matches_col(c, lhs, col_name) {
			mark_uncompiled(c, e, "unsupported LIKE target in CHECK")
			return rules.NONE, false, .Unknown
		}
		pat := like_to_ecma(c, e.pattern, e.escape)
		if c.oom {
			return rules.NONE, false, .Unknown
		}
		return c_maybe_not(c, c_scalar(c, rules.Node{kinds = {.String}, rules = {pattern = pat}}), e.negated)
	}

	mark_uncompiled(c, e, "unsupported expression in CHECK constraint")
	return rules.NONE, false, .Unknown
}

@(private = "file")
combine_logic :: proc(c: ^Compiler, a, b: rules.Node_Index, is_all: bool) -> rules.Node_Index {
	na, nb := &c.d.nodes[a], &c.d.nodes[b]
	a_flat := is_pure_all_of(na) if is_all else is_pure_any_of(na)
	b_flat := is_pure_all_of(nb) if is_all else is_pure_any_of(nb)
	a_list := na.all_of if is_all else na.any_of
	b_list := nb.all_of if is_all else nb.any_of
	list, err := make([]rules.Node_Index, (len(a_list) if a_flat else 1) + (len(b_list) if b_flat else 1), c.allocator)
	if err != nil {
		c.oom = true
		return rules.NONE
	}
	pos := 0
	if a_flat {
		copy(list[pos:], a_list)
		pos += len(a_list)
	} else {
		list[pos] = a
		pos += 1
	}
	if b_flat {
		copy(list[pos:], b_list)
	} else {
		list[pos] = b
	}
	node := rules.Node{kinds = rules.EVERY_KIND}
	if is_all { node.all_of = list } else { node.any_of = list }
	return c_scalar(c, node)
}

@(private = "file")
is_bare_node :: proc "contextless" (n: ^rules.Node) -> bool {
	return n.rules == {} && n.array < 0 && n.object < 0 && !n.has_enum && n.const_of == nil && len(n.one_of) == 0
}

@(private = "file")
is_pure_all_of :: proc "contextless" (n: ^rules.Node) -> bool {
	return len(n.all_of) > 0 && n.kinds == rules.EVERY_KIND && is_bare_node(n) && len(n.any_of) == 0 && n.not == nil
}

@(private = "file")
is_pure_any_of :: proc "contextless" (n: ^rules.Node) -> bool {
	return len(n.any_of) > 0 && n.kinds == rules.EVERY_KIND && is_bare_node(n) && len(n.all_of) == 0 && n.not == nil
}

@(private = "file")
can_inline_single_all_of :: proc "contextless" (dst, src: ^rules.Node) -> bool {
	if src.kinds != rules.EVERY_KIND || !is_bare_node(src) || len(src.all_of) > 0 {
		return false
	}
	return (len(src.any_of) > 0 && len(dst.any_of) == 0 && src.not == nil) ||
		(src.not != nil && dst.not == nil && len(src.any_of) == 0)
}

@(private = "file")
inline_into :: proc(dst, src: ^rules.Node, allocator: runtime.Allocator, oom: ^bool) {
	if len(src.any_of) > 0 {
		if cl, err := slice.clone(src.any_of, allocator); err != nil {
			oom^ = true
		} else {
			dst.any_of = cl
		}
	} else if src.not != nil {
		dst.not = src.not
	}
}

@(private = "file")
like_to_ecma :: proc(c: ^Compiler, pat: string, esc: u8) -> string {
	buf := make([dynamic]u8, 0, len(pat) * 2 + 2, c.scratch)
	push_esc :: proc(c: ^Compiler, buf: ^[dynamic]u8, ch: u8) {
		switch ch {
		case '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\', '/':
			_ = c_push(c, buf, '\\')
		}
		_ = c_push(c, buf, ch)
	}
	_ = c_push(c, &buf, '^')
	for i := 0; i < len(pat) && !c.oom; i += 1 {
		ch := pat[i]
		if esc != 0 && ch == esc && i + 1 < len(pat) {
			i += 1
			push_esc(c, &buf, pat[i])
		} else if ch == '%' {
			_ = c_push(c, &buf, '[', '\\', 's', '\\', 'S', ']', '*')
		} else if ch == '_' {
			_ = c_push(c, &buf, '[', '\\', 's', '\\', 'S', ']')
		} else {
			push_esc(c, &buf, ch)
		}
	}
	_ = c_push(c, &buf, '$')
	if c.oom {
		return ""
	}
	return c_keep(c, string(buf[:]))
}
