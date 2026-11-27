// Compiles SQL `CREATE TABLE` DDL into `stury:lib/schema/rules.Description` and `stury:lib/schema/check.Plan`,
// preserving table metadata (primary key, unique column groups, foreign keys, uncompiled cross-column checks).
// Compatible with `check.check_document`, `schema.compare`, `schema.sample`, `schema.write_schema`, and
// `schema.write_odin`.
// Zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean, OOM-safe.
package ddl

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

// Options controlling SQL DDL -> `rules.Description` compilation.
// `Maybe(bool)` fields default to `true` when left `nil`, so `Compile_Options{as_array = true}`
// keeps `strict_columns`, `default_optional`, and `assert_format` enabled unless explicitly overridden.
Compile_Options :: struct {
	// Table to compile in multi-table DDL (matches `table` or `schema.table`, case-insensitively).
	// Empty selects the first `CREATE TABLE`.
	table_name:       string,
	// When `false` (default), compiles a single-row object schema `{...}`.
	// When `true`, compiles an array-of-rows schema `[{...}, ...]` (with `uniqueItems` when the table
	// has a `PRIMARY KEY` or `UNIQUE` constraint).
	as_array:         bool,
	// Forbid undeclared columns (`additionalProperties: false`). Defaults to `true` when `nil`.
	strict_columns:   Maybe(bool),
	// Treat `NOT NULL` columns with a `DEFAULT` clause as optional rather than `required`.
	// Defaults to `true` when `nil`.
	default_optional: Maybe(bool),
	// Enable `assert_format` on `UUID`, `DATE`, `TIME`, and `TIMESTAMP`/`DATETIME` columns.
	// Defaults to `true` when `nil`.
	assert_format:    Maybe(bool),
	// When `true`, return `.Bad_Check` if a `CHECK` expression cannot be represented in `rules.Description`
	// (e.g. cross-column `end_date >= start_date`). When `false` (default), skip unrepresentable checks
	// and count them in `Table_Meta.uncompiled_checks`.
	strict_checks:    bool,
	// Duplicate-key policy for `check_document` runs on `Compiled`.
	dups:             tape.Duplicates,
	// Resource budget for `check_document` runs on `Compiled`.
	budget:           tape.Budget,
}

// Relational table metadata extracted from `CREATE TABLE` alongside the compiled `rules.Description`.
Table_Meta :: struct {
	schema_name:       string,
	table_name:        string,
	primary_key:       []string,
	unique_columns:    [][]string,
	foreign_keys:      []Foreign_Key,
	uncompiled_checks: int,
}

// A compiled SQL DDL schema owning its self-contained `rules.Description`, thread-safe `check.Plan`,
// and extracted relational `Table_Meta`. Free with `destroy`.
Compiled :: struct {
	description: rules.Description,
	plan:        check.Plan,
	meta:        Table_Meta,
	opts:        Compile_Options,
	arena:       mem.Dynamic_Arena,
	arena_ready: bool,
	allocator:   runtime.Allocator,
}

// Compiles SQL DDL bytes directly into a self-contained `rules.Description` (borrowing nothing from `src`).
// Free the returned description with `rules.description_destroy`.
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

// Compiles SQL DDL bytes into a `Compiled` handle holding `rules.Description`, `check.Plan`, and `Table_Meta`.
// `src` does NOT need to outlive the returned `^Compiled`. Free with `destroy`.
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
	meta_alloc := mem.dynamic_arena_allocator(&c.arena)

	desc, derr := compile_table_description(&parsed, tbl, opts, &c.meta, meta_alloc, allocator)
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

// Frees all resources owned by `c` and `c` itself.
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

// Checks an already-built `tape.Document` (JSON, CSV, TOML, YAML, XML, CBOR) against compiled DDL `c`.
@(require_results)
check_document :: proc(c: ^Compiled, doc: ^tape.Document, sink: ^check.Sink = nil, allocator := context.allocator) -> check.Result {
	if c == nil {
		return {valid = false, err = {kind = .Bad_Option, keyword = "compiled"}}
	}
	copts := check.Options{dups = c.opts.dups, budget = c.opts.budget}
	return check.check_document(doc, &c.plan, copts, sink, allocator)
}

// Convenience predicate: whether `doc` satisfies compiled DDL `c`.
valid_document :: proc(c: ^Compiled, doc: ^tape.Document, allocator := context.allocator) -> bool {
	res := check_document(c, doc, nil, allocator)
	ok := res.valid
	check.result_destroy(&res)
	return ok
}

// ============================================================================
// Table selection & metadata extraction
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
	want_schema := ""
	want_name := want
	if dot >= 0 {
		want_schema = want[:dot]
		want_name = want[dot + 1:]
	}
	for &t in parsed.tables {
		if want_schema != "" {
			if ascii_eq_fold(t.schema_name, want_schema) && ascii_eq_fold(t.name, want_name) {
				return &t, {}
			}
		} else if ascii_eq_fold(t.name, want_name) {
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
c_keep :: proc(c: ^Compiler, s: string) -> string {
	if c.oom || s == "" {
		return ""
	}
	cp, err := strings.clone(s, c.allocator)
	if err != nil {
		c.oom = true
		return ""
	}
	if _, aerr := append(&c.d.texts, cp); aerr != nil {
		delete(cp, c.allocator)
		c.oom = true
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
	n.any_of = nil
	n.enum_of = nil
	n.examples = nil
	n.all_of = nil
	n.one_of = nil
}

@(private = "file")
c_add_node :: proc(c: ^Compiler, n: rules.Node) -> rules.Node_Index {
	n := n
	if c.oom {
		destroy_node_slices(&n, c.allocator)
		return rules.NONE
	}
	if _, err := append(&c.d.nodes, n); err != nil {
		destroy_node_slices(&n, c.allocator)
		c.oom = true
		return rules.NONE
	}
	return rules.Node_Index(len(c.d.nodes) - 1)
}

@(private = "file")
c_add_object :: proc(c: ^Compiler, o: rules.Object) -> i32 {
	if c.oom {
		delete(o.members, c.allocator)
		delete(o.patterns, c.allocator)
		for x in o.dependents {
			delete(x.required, c.allocator)
		}
		delete(o.dependents, c.allocator)
		return -1
	}
	if _, err := append(&c.d.objects, o); err != nil {
		delete(o.members, c.allocator)
		delete(o.patterns, c.allocator)
		for x in o.dependents {
			delete(x.required, c.allocator)
		}
		delete(o.dependents, c.allocator)
		c.oom = true
		return -1
	}
	return i32(len(c.d.objects) - 1)
}

@(private = "file")
c_add_array :: proc(c: ^Compiler, a: rules.Array) -> i32 {
	if c.oom {
		return -1
	}
	if _, err := append(&c.d.arrays, a); err != nil {
		c.oom = true
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
compile_table_description :: proc(
	parsed: ^Parsed,
	tbl: ^Table_Def,
	opts: Compile_Options,
	meta: ^Table_Meta,
	meta_alloc: runtime.Allocator,
	allocator: runtime.Allocator,
) -> (d: rules.Description, err: Error) {
	d.allocator = allocator
	d.nodes.allocator = allocator
	d.arrays.allocator = allocator
	d.objects.allocator = allocator
	d.texts.allocator = allocator
	d.anchors.allocator = allocator
	d.bases.allocator = allocator
	d.root = rules.NONE

	names_map, nm_err := make(map[rules.Node_Index]string, 4, allocator)
	if nm_err != nil {
		rules.description_destroy(&d)
		return {}, make_error(.No_Memory, "out of memory", allocator = allocator)
	}
	d.names = names_map

	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	col_nn, nn_err := make([]bool, len(tbl.columns), scratch)
	col_kinds, ck_err := make([]rules.Kinds, len(tbl.columns), scratch)
	if nn_err != nil || ck_err != nil {
		rules.description_destroy(&d)
		return {}, make_error(.No_Memory, "out of memory", allocator = allocator)
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

	// Effective NOT NULL per column (includes table-level PRIMARY KEY columns).
	for col, i in tbl.columns {
		c.col_not_null[i] = col.not_null || col.primary_key
	}
	for pk_col in tbl.primary_key {
		if idx := c_find_col(&c, pk_col); idx >= 0 {
			c.col_not_null[idx] = true
		}
	}

	// Build each column node and its member entry.
	members, mem_err := make([]rules.Member, len(tbl.columns), allocator)
	if mem_err != nil {
		rules.description_destroy(&d)
		return {}, make_error(.No_Memory, "out of memory", allocator = allocator)
	}

	// Per-column extra `all_of` lists for complex CHECK expressions (populated by both column and single-col table CHECKs).
	col_extras, ce_err := make([][dynamic]rules.Node_Index, len(tbl.columns), scratch)
	if ce_err != nil {
		delete(members, allocator)
		rules.description_destroy(&d)
		return {}, make_error(.No_Memory, "out of memory", allocator = allocator)
	}
	for i in 0 ..< len(tbl.columns) {
		col_extras[i].allocator = scratch
	}

	col_node_ids, cn_err := make([]rules.Node_Index, len(tbl.columns), scratch)
	if cn_err != nil {
		delete(members, allocator)
		rules.description_destroy(&d)
		return {}, make_error(.No_Memory, "out of memory", allocator = allocator)
	}

	for &col, i in tbl.columns {
		node_idx := build_column_node(&c, i, &col)
		if c.oom || c.err.kind != .None {
			delete(members, allocator)
			rules.description_destroy(&d)
			return {}, c_final_error(&c)
		}
		col_node_ids[i] = node_idx
		c.col_non_null_k[i] = d.nodes[node_idx].kinds - {.Null}

		// Compile column-level CHECK constraints.
		for chk in col.checks {
			apply_column_check(&c, i, node_idx, chk, &col_extras[i])
			if c.oom || c.err.kind != .None {
				delete(members, allocator)
				rules.description_destroy(&d)
				return {}, c_final_error(&c)
			}
		}

		members[i] = rules.Member {
			name     = c_keep(&c, col.name),
			node     = node_idx,
			required = c.col_not_null[i] && !(c.default_optional && col.has_default),
		}
		if c.oom {
			delete(members, allocator)
			rules.description_destroy(&d)
			return {}, make_error(.No_Memory, "out of memory", allocator = allocator)
		}
	}

	// Compile table-level CHECK constraints: flatten top-level `AND` chains first so single-column
	// conjuncts fold onto their column node and cross-column unsupported conjuncts never poison sibling conjuncts.
	row_all_of := make([dynamic]rules.Node_Index, scratch)
	tbl_work := make([dynamic]Expr_Index, scratch)
	tbl_conjuncts := make([dynamic]Expr_Index, scratch)
	for chk in tbl.checks {
		clear(&tbl_work)
		clear(&tbl_conjuncts)
		if _, aerr := append(&tbl_work, chk); aerr != nil {
			c.oom = true
		}
		for len(tbl_work) > 0 && !c.oom {
			idx := pop(&tbl_work)
			if idx == NO_EXPR {
				continue
			}
			ex := c.parsed.exprs[idx]
			if ex.kind == .And {
				if _, aerr := append(&tbl_work, ex.rhs, ex.lhs); aerr != nil {
					c.oom = true
					break
				}
			} else {
				if _, aerr := append(&tbl_conjuncts, idx); aerr != nil {
					c.oom = true
					break
				}
			}
		}
		for conj in tbl_conjuncts {
			if c.oom || c.err.kind != .None {
				break
			}
			target_col, is_single := check_single_column(&c, conj)
			if is_single {
				apply_column_check(&c, target_col, col_node_ids[target_col], conj, &col_extras[target_col])
			} else {
				obj_chk, compiled := compile_table_check(&c, conj)
				if compiled && obj_chk != rules.NONE {
					if _, aerr := append(&row_all_of, obj_chk); aerr != nil {
						c.oom = true
					}
				}
			}
		}
		if c.oom || c.err.kind != .None {
			delete(members, allocator)
			rules.description_destroy(&d)
			return {}, c_final_error(&c)
		}
	}

	// Finalize any per-column `all_of` slices into `allocator` (owned by `d`).
	for i in 0 ..< len(tbl.columns) {
		if len(col_extras[i]) == 0 {
			continue
		}
		n := &d.nodes[col_node_ids[i]]
		if len(col_extras[i]) == 1 && can_inline_single_all_of(n, &d.nodes[col_extras[i][0]]) {
			inline_into(n, &d.nodes[col_extras[i][0]], allocator, &c.oom)
		} else {
			sl, serr := slice.clone(col_extras[i][:], allocator)
			if serr != nil {
				c.oom = true
			} else {
				n.all_of = sl
			}
		}
		if c.oom {
			delete(members, allocator)
			rules.description_destroy(&d)
			return {}, make_error(.No_Memory, "out of memory", allocator = allocator)
		}
	}

	// Build row object block.
	add_node := rules.NONE
	if c.strict_columns {
		add_node = c_add_node(&c, rules.Node{kinds = {}, array = -1, object = -1})
	}
	obj_idx := c_add_object(&c, rules.Object{
		members    = members,
		additional = add_node,
		keys       = rules.NONE,
	})
	if c.oom {
		rules.description_destroy(&d)
		return {}, make_error(.No_Memory, "out of memory", allocator = allocator)
	}

	row_node := rules.Node {
		kinds  = {.Object},
		array  = -1,
		object = obj_idx,
		title  = c_keep(&c, tbl.name),
	}
	if len(row_all_of) > 0 {
		sl, serr := slice.clone(row_all_of[:], allocator)
		if serr != nil {
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
		rules.description_destroy(&d)
		return {}, make_error(.No_Memory, "out of memory", allocator = allocator)
	}

	// Determine whether table has any PRIMARY KEY or UNIQUE constraint.
	has_unique := len(tbl.primary_key) > 0 || len(tbl.uniques) > 0
	for col in tbl.columns {
		if col.primary_key || col.unique {
			has_unique = true
			break
		}
	}

	if opts.as_array {
		arr_idx := c_add_array(&c, rules.Array{items = row_idx})
		arr_node := rules.Node {
			kinds = {.Array},
			array = arr_idx,
			object = -1,
			rules = {unique = has_unique},
		}
		root_idx := c_add_node(&c, arr_node)
		if c.oom {
			rules.description_destroy(&d)
			return {}, make_error(.No_Memory, "out of memory", allocator = allocator)
		}
		d.root = root_idx
	} else {
		d.root = row_idx
	}

	if meta != nil {
		if !populate_meta(&c, meta, meta_alloc) {
			rules.description_destroy(&d)
			return {}, make_error(.No_Memory, "out of memory", allocator = allocator)
		}
	}

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
populate_meta :: proc(c: ^Compiler, meta: ^Table_Meta, a: runtime.Allocator) -> bool {
	clone_s :: proc(s: string, a: runtime.Allocator) -> (string, bool) {
		if s == "" {
			return "", true
		}
		cp, err := strings.clone(s, a)
		return cp, err == nil
	}
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

	sn, ok1 := clone_s(c.tbl.schema_name, a)
	tn, ok2 := clone_s(c.tbl.name, a)
	if !ok1 || !ok2 {
		return false
	}
	meta.schema_name = sn
	meta.table_name = tn
	meta.uncompiled_checks = c.uncompiled

	// Primary key
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
				if _, aerr := append(&pk_list, cp); aerr != nil {
					return false
				}
			}
		}
		meta.primary_key = pk_list[:]
	}

	// Unique column groups
	ug := make([dynamic][]string, a)
	for col in c.tbl.columns {
		if col.primary_key || col.unique {
			one, ok := clone_ss({col.name}, a)
			if !ok {
				return false
			}
			if _, aerr := append(&ug, one); aerr != nil {
				return false
			}
		}
	}
	for u in c.tbl.uniques {
		grp, ok := clone_ss(u.columns, a)
		if !ok {
			return false
		}
		if _, aerr := append(&ug, grp); aerr != nil {
			return false
		}
	}
	meta.unique_columns = ug[:]

	// Foreign keys
	fks := make([dynamic]Foreign_Key, a)
	for col in c.tbl.columns {
		if fk, has := col.references.?; has {
			fk_cp, ok := clone_fk(fk, a)
			if !ok {
				return false
			}
			if _, aerr := append(&fks, fk_cp); aerr != nil {
				return false
			}
		}
	}
	for fk in c.tbl.foreign_keys {
		fk_cp, ok := clone_fk(fk, a)
		if !ok {
			return false
		}
		if _, aerr := append(&fks, fk_cp); aerr != nil {
			return false
		}
	}
	meta.foreign_keys = fks[:]
	return true
}

@(private = "file")
clone_fk :: proc(fk: Foreign_Key, a: runtime.Allocator) -> (out: Foreign_Key, ok: bool) {
	if fk.name != "" {
		n, e := strings.clone(fk.name, a)
		if e != nil {
			return {}, false
		}
		out.name = n
	}
	if fk.ref_table != "" {
		rt, e := strings.clone(fk.ref_table, a)
		if e != nil {
			return {}, false
		}
		out.ref_table = rt
	}
	if len(fk.columns) > 0 {
		cols, e := make([]string, len(fk.columns), a)
		if e != nil {
			return {}, false
		}
		for s, i in fk.columns {
			cp, se := strings.clone(s, a)
			if se != nil {
				return {}, false
			}
			cols[i] = cp
		}
		out.columns = cols
	}
	if len(fk.ref_columns) > 0 {
		rcols, e := make([]string, len(fk.ref_columns), a)
		if e != nil {
			return {}, false
		}
		for s, i in fk.ref_columns {
			cp, se := strings.clone(s, a)
			if se != nil {
				return {}, false
			}
			rcols[i] = cp
		}
		out.ref_columns = rcols
	}
	return out, true
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

	n: rules.Node
	if col.type.is_array {
		elem_idx := c_add_node(c, elem)
		arr_idx := c_add_array(c, rules.Array{items = elem_idx})
		n = rules.Node {
			kinds  = {.Array} if not_null else {.Array, .Null},
			array  = arr_idx,
			object = -1,
		}
	} else {
		n = elem
	}

	// Default value annotation (only when literal kind is compatible with column kinds).
	if col.has_default_lit {
		if val, vok := literal_to_value(c, col.default_lit); vok {
			if value_matches_kinds(val, n.kinds) {
				n.default_of = val
			}
		}
	}

	return c_add_node(c, n)
}

@(private = "file")
build_scalar_type_node :: proc(c: ^Compiler, t: Sql_Type, not_null: bool) -> (n: rules.Node) {
	n.array = -1
	n.object = -1

	switch t.kind {
	case .TinyInt:
		n.kinds = {.Integer}
		if t.unsigned {
			n.rules.minimum, n.rules.maximum = "0", "255"
		} else {
			n.rules.minimum, n.rules.maximum = "-128", "127"
		}
	case .SmallInt, .SmallSerial:
		n.kinds = {.Integer}
		if t.unsigned {
			n.rules.minimum, n.rules.maximum = "0", "65535"
		} else {
			n.rules.minimum, n.rules.maximum = "-32768", "32767"
		}
	case .MediumInt:
		n.kinds = {.Integer}
		if t.unsigned {
			n.rules.minimum, n.rules.maximum = "0", "16777215"
		} else {
			n.rules.minimum, n.rules.maximum = "-8388608", "8388607"
		}
	case .Int, .Serial:
		n.kinds = {.Integer}
		if t.unsigned {
			n.rules.minimum, n.rules.maximum = "0", "4294967295"
		} else {
			n.rules.minimum, n.rules.maximum = "-2147483648", "2147483647"
		}
	case .BigInt, .BigSerial:
		n.kinds = {.Integer}
		if t.unsigned {
			n.rules.minimum, n.rules.maximum = "0", "18446744073709551615"
		} else {
			n.rules.minimum, n.rules.maximum = "-9223372036854775808", "9223372036854775807"
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
	case .Text:
		n.kinds = {.String}
		if t.has_len && t.len > 0 {
			n.rules.max_length = t.len
		}
	case .Varchar:
		n.kinds = {.String}
		if t.has_len {
			n.rules.max_length = t.len
		}
	case .Char:
		// Fixed-length SQL `CHAR(N)` enforces exact code-point length N when N is specified.
		n.kinds = {.String}
		if t.has_len {
			n.rules.min_length = t.len
			n.rules.max_length = t.len
		}
	case .Uuid:
		n.kinds = {.String}
		n.rules.format = "uuid"
		n.rules.assert_format = c.assert_format
	case .Date:
		n.kinds = {.String}
		n.rules.format = "date"
		n.rules.assert_format = c.assert_format
	case .Time:
		n.kinds = {.String}
		n.rules.format = "time"
		n.rules.assert_format = c.assert_format
	case .Timestamp:
		n.kinds = {.String}
		n.rules.format = "date-time"
		n.rules.assert_format = c.assert_format
	case .Json:
		n.kinds = rules.EVERY_KIND - {.Null}
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
	case .Unknown:
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
	p := int(t.len)
	s := int(scale_u)
	int_digits := p - s
	if s == 0 {
		n.kinds = {.Integer}
		max_buf: [48]u8 = ---
		for i in 0 ..< p {
			max_buf[i] = '9'
		}
		max_str := c_keep(c, string(max_buf[:p]))
		n.rules.maximum = max_str
		if !t.unsigned {
			min_buf: [49]u8 = ---
			min_buf[0] = '-'
			copy(min_buf[1:], max_buf[:p])
			n.rules.minimum = c_keep(c, string(min_buf[:p + 1]))
		}
		return
	}

	// Decimal with scale `s > 0`: exact bounds `±(10^(p-s) - 10^-s)` and exact `multiple_of = 10^-s`.
	max_buf: [64]u8 = ---
	pos := 0
	if int_digits == 0 {
		max_buf[pos] = '0'
		pos += 1
	} else {
		for _ in 0 ..< int_digits {
			max_buf[pos] = '9'
			pos += 1
		}
	}
	max_buf[pos] = '.'
	pos += 1
	for _ in 0 ..< s {
		max_buf[pos] = '9'
		pos += 1
	}
	n.rules.maximum = c_keep(c, string(max_buf[:pos]))
	if !t.unsigned {
		min_buf: [65]u8 = ---
		min_buf[0] = '-'
		copy(min_buf[1:], max_buf[:pos])
		n.rules.minimum = c_keep(c, string(min_buf[:pos + 1]))
	}

	step_buf: [64]u8 = ---
	step_buf[0] = '0'
	step_buf[1] = '.'
	for i in 0 ..< s - 1 {
		step_buf[2 + i] = '0'
	}
	step_buf[2 + s - 1] = '1'
	n.rules.multiple_of = c_keep(c, string(step_buf[:2 + s]))
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
	case .Null:
		return rules.Null{}, true
	case .Bool:
		return lit.bool_val, true
	case .Integer:
		return lit.int_val, true
	case .Decimal:
		txt := c_keep(c, lit.text)
		if c.oom {
			return nil, false
		}
		return rules.Number_Text{text = txt}, true
	case .String:
		txt := c_keep(c, lit.text)
		if c.oom {
			return nil, false
		}
		return txt, true
	}
	return nil, false
}

@(private = "file")
value_matches_kinds :: proc "contextless" (v: rules.Value, kinds: rules.Kinds) -> bool {
	#partial switch x in v {
	case rules.Null:
		return .Null in kinds
	case bool:
		return .Bool in kinds
	case i64, u64:
		return .Integer in kinds || .Number in kinds
	case f64:
		return .Number in kinds
	case rules.Number_Text:
		if .Number in kinds {
			return true
		}
		if .Integer in kinds && rules.valid_decimal_text(x.text) {
			d := rules.decimal_of(x.text)
			return d.head == "" || (d.wide == "" && d.point >= i128(len(d.head) + len(d.tail)))
		}
		return false
	case string:
		return .String in kinds
	}
	return false
}

// Whether an `.Ident` / `.Length_Call` expression refers to column `col_name` of the current table.
@(private = "file")
expr_matches_col :: proc "contextless" (c: ^Compiler, e: Expr, col_name: string) -> bool {
	if e.table_qual != "" && !ascii_eq_fold(e.table_qual, c.tbl.name) {
		return false
	}
	return ascii_eq_fold(e.ident, col_name)
}

// ============================================================================
// CHECK expression analysis & compilation (explicit stacks, zero recursion)
// ============================================================================

@(private = "file")
check_single_column :: proc(c: ^Compiler, root: Expr_Index) -> (col_idx: int, ok: bool) {
	stack := make([dynamic]Expr_Index, c.scratch)
	if _, aerr := append(&stack, root); aerr != nil {
		c.oom = true
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
			if ci < 0 {
				return -1, false
			}
			if found < 0 {
				found = ci
			} else if found != ci {
				return -1, false
			}
		case .Compare, .And, .Or:
			if _, aerr := append(&stack, e.lhs, e.rhs); aerr != nil {
				c.oom = true
				return -1, false
			}
		case .Between:
			if _, aerr := append(&stack, e.lhs, e.rhs, e.hi); aerr != nil {
				c.oom = true
				return -1, false
			}
		case .In_List, .Is_Null, .Like, .Not:
			if _, aerr := append(&stack, e.lhs); aerr != nil {
				c.oom = true
				return -1, false
			}
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
apply_column_check :: proc(
	c: ^Compiler,
	col_idx: int,
	node_idx: rules.Node_Index,
	root: Expr_Index,
	extras: ^[dynamic]rules.Node_Index,
) {
	// Flatten top-level `AND` chains iteratively so `a >= 0 AND a <= 100 AND LENGTH(s) >= 3` folds cleanly.
	work := make([dynamic]Expr_Index, c.scratch)
	if _, aerr := append(&work, root); aerr != nil {
		c.oom = true
		return
	}
	conjuncts := make([dynamic]Expr_Index, c.scratch)
	for len(work) > 0 {
		idx := pop(&work)
		if idx == NO_EXPR {
			continue
		}
		e := c.parsed.exprs[idx]
		if e.kind == .And {
			if _, aerr := append(&work, e.rhs, e.lhs); aerr != nil {
				c.oom = true
				return
			}
		} else {
			if _, aerr := append(&conjuncts, idx); aerr != nil {
				c.oom = true
				return
			}
		}
	}

	non_null_k := c.col_non_null_k[col_idx]

	for idx in conjuncts {
		not_null := c.col_not_null[col_idx]
		if try_fold_direct_col_pred(c, col_idx, node_idx, idx, not_null) {
			if c.oom || c.err.kind != .None {
				return
			}
			continue
		}
		if c.oom || c.err.kind != .None {
			return
		}
		sub, compiled := compile_col_expr(c, col_idx, idx, non_null_k, !not_null)
		if c.oom || c.err.kind != .None {
			return
		}
		if compiled && sub != rules.NONE {
			if _, aerr := append(extras, sub); aerr != nil {
				c.oom = true
				return
			}
		}
	}
}

// Attempts to fold a simple single-column predicate directly onto `d.nodes[node_idx]`.
// Returns `true` if handled (including when marked uncompiled).
@(private = "file")
try_fold_direct_col_pred :: proc(
	c: ^Compiler,
	col_idx: int,
	node_idx: rules.Node_Index,
	idx: Expr_Index,
	not_null: bool,
) -> bool {
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
			// `col IS NOT NULL`
			n.kinds -= {.Null}
			c.col_not_null[col_idx] = true
			if n.has_enum {
				strip_null_from_enum(n, c.allocator, &c.oom)
			}
		} else {
			// `col IS NULL`
			n.kinds = {.Null}
		}
		return true

	case .Compare:
		return try_fold_compare(c, col_idx, n, e, not_null)

	case .Between:
		if e.negated {
			return false
		}
		return try_fold_between(c, col_idx, n, e)

	case .In_List:
		if e.negated || n.has_enum || n.const_of != nil {
			return false
		}
		lhs := c.parsed.exprs[e.lhs]
		if lhs.kind != .Ident || !expr_matches_col(c, lhs, col_name) {
			return false
		}
		extra := 0 if not_null else 1
		vals, verr := make([]rules.Value, len(e.literals) + extra, c.allocator)
		if verr != nil {
			c.oom = true
			return true
		}
		for lit, i in e.literals {
			v, vok := literal_to_value(c, lit)
			if !vok {
				delete(vals, c.allocator)
				return true
			}
			vals[i] = v
		}
		if !not_null {
			vals[len(e.literals)] = rules.Null{}
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
		if c.oom {
			return true
		}
		n.rules.pattern = pat
		return true
	}

	return false
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
	case .Eq:
		return .Eq
	case .Neq:
		return .Neq
	case .Lt:
		return .Gt
	case .Lte:
		return .Gte
	case .Gt:
		return .Lt
	case .Gte:
		return .Lte
	}
	return op
}

@(private = "file")
normalize_compare :: proc(c: ^Compiler, col_idx: int, e: Expr) -> (target: Expr, op: Cmp_Op, lit: Literal, ok: bool) {
	lhs := c.parsed.exprs[e.lhs]
	rhs := c.parsed.exprs[e.rhs]
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

	// `LENGTH(col) <op> <integer>`
	if target.kind == .Length_Call {
		if lit.kind != .Integer {
			return false
		}
		return apply_length_cmp(&n.rules, op, lit.int_val)
	}

	// `col <op> <literal>`
	switch lit.kind {
	case .Integer, .Decimal:
		#partial switch op {
		case .Gte, .Gt:
			edge := rules.Rules{minimum = c_keep(c, lit.text), exclusive_minimum = op == .Gt}
			if !c.oom {
				merged_r, clash := rules.merged(n, edge)
				if clash == "" {
					n.rules = merged_r
					return true
				}
			}
			return true
		case .Lte, .Lt:
			edge := rules.Rules{maximum = c_keep(c, lit.text), exclusive_maximum = op == .Lt}
			if !c.oom {
				merged_r, clash := rules.merged(n, edge)
				if clash == "" {
					n.rules = merged_r
					return true
				}
			}
			return true
		case .Eq:
			if n.has_enum || n.const_of != nil {
				return false
			}
			v, vok := literal_to_value(c, lit)
			if !vok {
				return true
			}
			if not_null {
				n.const_of = v
			} else {
				vals, verr := make([]rules.Value, 2, c.allocator)
				if verr != nil {
					c.oom = true
					return true
				}
				vals[0] = v
				vals[1] = rules.Null{}
				n.enum_of = vals
				n.has_enum = true
			}
			return true
		case .Neq:
			return false // Handled via `not: {const: N}` in `compile_col_expr`.
		}
	case .String:
		#partial switch op {
		case .Eq:
			if n.has_enum || n.const_of != nil {
				return false
			}
			v, vok := literal_to_value(c, lit)
			if !vok {
				return true
			}
			if not_null {
				n.const_of = v
			} else {
				vals, verr := make([]rules.Value, 2, c.allocator)
				if verr != nil {
					c.oom = true
					return true
				}
				vals[0] = v
				vals[1] = rules.Null{}
				n.enum_of = vals
				n.has_enum = true
			}
			return true
		case .Neq:
			// `col <> ''` / `col != ''` -> `minLength = 1`
			if lit.text == "" {
				n.rules.min_length = max(n.rules.min_length, 1)
				return true
			}
			return false // Handled via `not: {const: S}`
		}
	case .Bool:
		if op == .Eq {
			if n.has_enum || n.const_of != nil {
				return false
			}
			if not_null {
				n.const_of = rules.Value(lit.bool_val)
			} else {
				vals, verr := make([]rules.Value, 2, c.allocator)
				if verr != nil {
					c.oom = true
					return true
				}
				vals[0] = rules.Value(lit.bool_val)
				vals[1] = rules.Null{}
				n.enum_of = vals
				n.has_enum = true
			}
			return true
		}
		if op == .Neq {
			if n.has_enum || n.const_of != nil {
				return false
			}
			flipped := !lit.bool_val
			if not_null {
				n.const_of = rules.Value(flipped)
			} else {
				vals, verr := make([]rules.Value, 2, c.allocator)
				if verr != nil {
					c.oom = true
					return true
				}
				vals[0] = rules.Value(flipped)
				vals[1] = rules.Null{}
				n.enum_of = vals
				n.has_enum = true
			}
			return true
		}
	case .Null:
		return false
	}
	return false
}

@(private = "file")
apply_length_cmp :: proc "contextless" (r: ^rules.Rules, op: Cmp_Op, val: i64) -> bool {
	switch op {
	case .Gte:
		if val > 0 {
			r.min_length = max(r.min_length, u64(val))
		}
		return true
	case .Gt:
		if val >= 0 {
			r.min_length = max(r.min_length, u64(val) + 1)
		}
		return true
	case .Lte:
		if val < 0 {
			return false
		}
		tighten_max_u64(&r.max_length, u64(val))
		return true
	case .Lt:
		if val <= 0 {
			return false
		}
		tighten_max_u64(&r.max_length, u64(val - 1))
		return true
	case .Eq:
		if val < 0 {
			return false
		}
		u := u64(val)
		r.min_length = max(r.min_length, u)
		tighten_max_u64(&r.max_length, u)
		return true
	case .Neq:
		if val == 0 {
			r.min_length = max(r.min_length, 1)
			return true
		}
		return false
	}
	return false
}

@(private = "file")
tighten_max_u64 :: proc "contextless" (slot: ^Maybe(u64), limit: u64) {
	if cur, has := slot^.(u64); has {
		slot^ = min(cur, limit)
	} else {
		slot^ = limit
	}
}

@(private = "file")
try_fold_between :: proc(c: ^Compiler, col_idx: int, n: ^rules.Node, e: Expr) -> bool {
	lhs := c.parsed.exprs[e.lhs]
	lo := c.parsed.exprs[e.rhs]
	hi := c.parsed.exprs[e.hi]
	col_name := c.tbl.columns[col_idx].name

	if lo.kind != .Literal || hi.kind != .Literal {
		return false
	}
	if lhs.kind == .Length_Call && expr_matches_col(c, lhs, col_name) {
		if lo.lit.kind != .Integer || hi.lit.kind != .Integer || hi.lit.int_val < 0 {
			return false
		}
		if lo.lit.int_val > 0 {
			n.rules.min_length = max(n.rules.min_length, u64(lo.lit.int_val))
		}
		tighten_max_u64(&n.rules.max_length, u64(hi.lit.int_val))
		return true
	}
	if lhs.kind == .Ident && expr_matches_col(c, lhs, col_name) {
		if (lo.lit.kind == .Integer || lo.lit.kind == .Decimal) && (hi.lit.kind == .Integer || hi.lit.kind == .Decimal) {
			edge := rules.Rules{minimum = c_keep(c, lo.lit.text), maximum = c_keep(c, hi.lit.text)}
			if !c.oom {
				merged_r, clash := rules.merged(n, edge)
				if clash == "" {
					n.rules = merged_r
					return true
				}
			}
			return true
		}
	}
	return false
}

// Kleene 3-valued truth result when evaluating a single-column CHECK expression on SQL `NULL`.
@(private = "file")
Null_Eval :: enum u8 {
	False,
	Unknown,
	True,
}

@(private = "file")
null_eval_not :: proc "contextless" (v: Null_Eval) -> Null_Eval {
	switch v {
	case .False:
		return .True
	case .True:
		return .False
	case .Unknown:
		return .Unknown
	}
	return .Unknown
}

@(private = "file")
null_eval_and :: proc "contextless" (a, b: Null_Eval) -> Null_Eval {
	if a == .False || b == .False {
		return .False
	}
	if a == .True && b == .True {
		return .True
	}
	return .Unknown
}

@(private = "file")
null_eval_or :: proc "contextless" (a, b: Null_Eval) -> Null_Eval {
	if a == .True || b == .True {
		return .True
	}
	if a == .False && b == .False {
		return .False
	}
	return .Unknown
}

// Wraps `raw_node` so that SQL `NULL` is accepted (flattening into an existing `any_of` safely).
@(private = "file")
wrap_allow_null :: proc(c: ^Compiler, raw_node: rules.Node_Index) -> (rules.Node_Index, bool) {
	rn := &c.d.nodes[raw_node]
	if rn.kinds == {.Null} && rn.rules == {} && !rn.has_enum && rn.const_of == nil && rn.not == nil && len(rn.all_of) == 0 && len(rn.any_of) == 0 {
		return raw_node, true
	}
	if rn.not != nil && rn.kinds == rules.EVERY_KIND && rn.rules == {} && !rn.has_enum && rn.const_of == nil && len(rn.all_of) == 0 && len(rn.any_of) == 0 {
		// If `not` target rejects Null (e.g. `not: {kinds = {.Integer}, ...}` or `not: {const: 5}`),
		// Null already passes `not` without needing an extra `anyOf` wrapper!
		not_target := &c.d.nodes[rn.not.?]
		if .Null not_in not_target.kinds || not_target.const_of != nil || not_target.has_enum {
			return raw_node, true
		}
	}
	if is_pure_any_of(rn) {
		for arm in rn.any_of {
			a := &c.d.nodes[arm]
			if a.kinds == {.Null} && a.rules == {} && !a.has_enum && a.const_of == nil && a.not == nil && len(a.all_of) == 0 && len(a.any_of) == 0 {
				return raw_node, true
			}
		}
	}
	null_arm := c_add_node(c, rules.Node{kinds = {.Null}, array = -1, object = -1})
	if c.oom {
		return rules.NONE, false
	}
	// Re-index `rn` AFTER `c_add_node` because `c.d.nodes` may have reallocated!
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
	arms[0] = raw_node
	arms[1] = null_arm
	wrap := c_add_node(c, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, any_of = arms})
	if c.oom {
		return rules.NONE, false
	}
	return wrap, true
}

// Compiles an arbitrary single-column boolean CHECK expression (`AND`, `OR`, `NOT`, `NOT BETWEEN`,
// `NOT IN`, `<>`, `LIKE`, etc.) into a `rules.Node_Index` using an explicit post-order stack.
@(private = "file")
compile_col_expr :: proc(
	c: ^Compiler,
	col_idx: int,
	root: Expr_Index,
	non_null_k: rules.Kinds,
	nullable: bool,
) -> (node_idx: rules.Node_Index, ok: bool) {
	raw_node, rok, null_eval := compile_col_expr_inner(c, col_idx, root, non_null_k)
	if !rok || raw_node == rules.NONE {
		return rules.NONE, false
	}
	// SQL 3-valued logic: `CHECK (expr)` passes on `NULL` whenever `expr` evaluates to `TRUE` or `UNKNOWN`
	// (fails only when `eval_on_null == .False`).
	if !nullable || null_eval == .False {
		return raw_node, true
	}
	return wrap_allow_null(c, raw_node)
}

@(private = "file")
Eval_Frame :: struct {
	expr:        Expr_Index,
	visited:     bool,
	strict_true: bool, // Kleene polarity for `compile_table_check`: false = pass on T|U, true = pass only on T
}

@(private = "file")
Eval_Result :: struct {
	node:      rules.Node_Index,
	ok:        bool,
	null_eval: Null_Eval,
}

@(private = "file")
compile_col_expr_inner :: proc(
	c: ^Compiler,
	col_idx: int,
	root: Expr_Index,
	non_null_k: rules.Kinds,
) -> (node: rules.Node_Index, ok: bool, null_eval: Null_Eval) {
	stack := make([dynamic]Eval_Frame, c.scratch)
	results := make([dynamic]Eval_Result, c.scratch)
	if _, aerr := append(&stack, Eval_Frame{expr = root}); aerr != nil {
		c.oom = true
		return rules.NONE, false, .Unknown
	}

	for len(stack) > 0 && !c.oom && c.err.kind == .None {
		fr := pop(&stack)
		if fr.expr == NO_EXPR {
			if _, aerr := append(&results, Eval_Result{node = rules.NONE, ok = false, null_eval = .Unknown}); aerr != nil {
				c.oom = true
			}
			continue
		}
		e := c.parsed.exprs[fr.expr]
		if !fr.visited && (e.kind == .And || e.kind == .Or || e.kind == .Not) {
			if _, aerr := append(&stack, Eval_Frame{expr = fr.expr, visited = true}); aerr != nil {
				c.oom = true
				break
			}
			if e.kind == .Not {
				if _, aerr := append(&stack, Eval_Frame{expr = e.lhs}); aerr != nil {
					c.oom = true
					break
				}
			} else {
				if _, aerr := append(&stack, Eval_Frame{expr = e.rhs}, Eval_Frame{expr = e.lhs}); aerr != nil {
					c.oom = true
					break
				}
			}
			continue
		}

		#partial switch e.kind {
		case .Not:
			child := pop(&results)
			ne := null_eval_not(child.null_eval)
			if !child.ok || child.node == rules.NONE {
				if _, aerr := append(&results, Eval_Result{node = rules.NONE, ok = false, null_eval = ne}); aerr != nil {
					c.oom = true
				}
				continue
			}
			nid := c_add_node(c, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, not = child.node})
			if _, aerr := append(&results, Eval_Result{node = nid, ok = !c.oom, null_eval = ne}); aerr != nil {
				c.oom = true
			}

		case .And:
			r_res := pop(&results)
			l_res := pop(&results)
			ne := null_eval_and(l_res.null_eval, r_res.null_eval)
			// Never drop an unsupported conjunct inside a subexpression (an enclosing `NOT` would flip
			// weakening into over-rejection). Top-level `AND` flattening happens in `apply_column_check`.
			if !l_res.ok || !r_res.ok {
				if _, aerr := append(&results, Eval_Result{node = rules.NONE, ok = false, null_eval = ne}); aerr != nil {
					c.oom = true
				}
				continue
			}
			nid := combine_all_of(c, l_res.node, r_res.node)
			if _, aerr := append(&results, Eval_Result{node = nid, ok = !c.oom, null_eval = ne}); aerr != nil {
				c.oom = true
			}

		case .Or:
			r_res := pop(&results)
			l_res := pop(&results)
			ne := null_eval_or(l_res.null_eval, r_res.null_eval)
			if !l_res.ok || !r_res.ok {
				// Cannot drop one arm of OR without rejecting valid values.
				if _, aerr := append(&results, Eval_Result{node = rules.NONE, ok = false, null_eval = ne}); aerr != nil {
					c.oom = true
				}
				continue
			}
			nid := combine_any_of(c, l_res.node, r_res.node)
			if _, aerr := append(&results, Eval_Result{node = nid, ok = !c.oom, null_eval = ne}); aerr != nil {
				c.oom = true
			}

		case:
			atom, aok, atom_ne := compile_col_atom(c, col_idx, e, non_null_k)
			if _, aerr := append(&results, Eval_Result{node = atom, ok = aok, null_eval = atom_ne}); aerr != nil {
				c.oom = true
			}
		}
	}

	if c.oom || c.err.kind != .None || len(results) == 0 {
		return rules.NONE, false, .Unknown
	}
	res := results[len(results) - 1]
	return res.node, res.ok, res.null_eval
}

@(private = "file")
compile_col_atom :: proc(
	c: ^Compiler,
	col_idx: int,
	e: Expr,
	non_null_k: rules.Kinds,
) -> (node: rules.Node_Index, ok: bool, null_eval: Null_Eval) {
	col_name := c.tbl.columns[col_idx].name

	#partial switch e.kind {
	case .Is_Null:
		lhs := c.parsed.exprs[e.lhs]
		if lhs.kind != .Ident || !expr_matches_col(c, lhs, col_name) {
			mark_uncompiled(c, e, "unsupported IS NULL target in CHECK")
			return rules.NONE, false, .Unknown
		}
		k := rules.EVERY_KIND - {.Null} if e.negated else rules.Kinds{.Null}
		ne: Null_Eval = .False if e.negated else .True
		return c_add_node(c, rules.Node{kinds = k, array = -1, object = -1}), !c.oom, ne

	case .Ident:
		// Bare boolean column: `CHECK (active)` -> `const: true`
		if expr_matches_col(c, e, col_name) && .Bool in non_null_k {
			return c_add_node(c, rules.Node{kinds = {.Bool}, const_of = rules.Value(true), array = -1, object = -1}), !c.oom, .Unknown
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
				eq_n := c_add_node(c, rules.Node{
					kinds = {.String},
					array = -1,
					object = -1,
					rules = {min_length = u64(lit.int_val), max_length = u64(lit.int_val)},
				})
				return c_add_node(c, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, not = eq_n}), !c.oom, .Unknown
			}
			n := rules.Node{kinds = {.String}, array = -1, object = -1}
			if !apply_length_cmp(&n.rules, op, lit.int_val) {
				mark_uncompiled(c, e, "unsatisfiable LENGTH comparison in CHECK")
				return rules.NONE, false, .Unknown
			}
			return c_add_node(c, n), !c.oom, .Unknown
		}
		// `col <op> lit`
		switch lit.kind {
		case .Integer, .Decimal:
			nk := non_null_k & {.Integer, .Number}
			if nk == {} {
				nk = {.Number}
			}
			#partial switch op {
			case .Gte, .Gt:
				return c_add_node(c, rules.Node{
					kinds  = nk,
					array  = -1,
					object = -1,
					rules  = {minimum = c_keep(c, lit.text), exclusive_minimum = op == .Gt},
				}), !c.oom, .Unknown
			case .Lte, .Lt:
				return c_add_node(c, rules.Node{
					kinds  = nk,
					array  = -1,
					object = -1,
					rules  = {maximum = c_keep(c, lit.text), exclusive_maximum = op == .Lt},
				}), !c.oom, .Unknown
			case .Eq:
				v, vok := literal_to_value(c, lit)
				if !vok {
					return rules.NONE, false, .Unknown
				}
				return c_add_node(c, rules.Node{kinds = nk, const_of = v, array = -1, object = -1}), !c.oom, .Unknown
			case .Neq:
				v, vok := literal_to_value(c, lit)
				if !vok {
					return rules.NONE, false, .Unknown
				}
				inner := c_add_node(c, rules.Node{kinds = nk, const_of = v, array = -1, object = -1})
				return c_add_node(c, rules.Node{kinds = rules.EVERY_KIND, not = inner, array = -1, object = -1}), !c.oom, .Unknown
			}
		case .String:
			#partial switch op {
			case .Eq:
				v, vok := literal_to_value(c, lit)
				if !vok {
					return rules.NONE, false, .Unknown
				}
				return c_add_node(c, rules.Node{kinds = {.String}, const_of = v, array = -1, object = -1}), !c.oom, .Unknown
			case .Neq:
				if lit.text == "" {
					return c_add_node(c, rules.Node{kinds = {.String}, rules = {min_length = 1}, array = -1, object = -1}), !c.oom, .Unknown
				}
				v, vok := literal_to_value(c, lit)
				if !vok {
					return rules.NONE, false, .Unknown
				}
				inner := c_add_node(c, rules.Node{kinds = {.String}, const_of = v, array = -1, object = -1})
				return c_add_node(c, rules.Node{kinds = rules.EVERY_KIND, not = inner, array = -1, object = -1}), !c.oom, .Unknown
			}
		case .Bool:
			if op == .Eq || op == .Neq {
				b := lit.bool_val if op == .Eq else !lit.bool_val
				return c_add_node(c, rules.Node{kinds = {.Bool}, const_of = rules.Value(b), array = -1, object = -1}), !c.oom, .Unknown
			}
		case .Null:
			mark_uncompiled(c, e, "comparison with NULL in CHECK (use IS [NOT] NULL)")
			return rules.NONE, false, .Unknown
		}
		mark_uncompiled(c, e, "unsupported comparison operator/type in CHECK")
		return rules.NONE, false, .Unknown

	case .Between:
		lhs := c.parsed.exprs[e.lhs]
		lo := c.parsed.exprs[e.rhs]
		hi := c.parsed.exprs[e.hi]
		if lo.kind != .Literal || hi.kind != .Literal {
			mark_uncompiled(c, e, "non-literal BETWEEN bounds in CHECK")
			return rules.NONE, false, .Unknown
		}
		if lhs.kind == .Length_Call && expr_matches_col(c, lhs, col_name) && lo.lit.kind == .Integer && hi.lit.kind == .Integer && hi.lit.int_val >= 0 {
			inner := c_add_node(c, rules.Node{
				kinds  = {.String},
				array  = -1,
				object = -1,
				rules  = {min_length = u64(max(lo.lit.int_val, 0)), max_length = u64(hi.lit.int_val)},
			})
			if !e.negated {
				return inner, !c.oom, .Unknown
			}
			return c_add_node(c, rules.Node{kinds = rules.EVERY_KIND, not = inner, array = -1, object = -1}), !c.oom, .Unknown
		}
		if lhs.kind == .Ident && expr_matches_col(c, lhs, col_name) &&
			(lo.lit.kind == .Integer || lo.lit.kind == .Decimal) && (hi.lit.kind == .Integer || hi.lit.kind == .Decimal) {
			nk := non_null_k & {.Integer, .Number}
			if nk == {} {
				nk = {.Number}
			}
			inner := c_add_node(c, rules.Node{
				kinds  = nk,
				array  = -1,
				object = -1,
				rules  = {minimum = c_keep(c, lo.lit.text), maximum = c_keep(c, hi.lit.text)},
			})
			if !e.negated {
				return inner, !c.oom, .Unknown
			}
			return c_add_node(c, rules.Node{kinds = rules.EVERY_KIND, not = inner, array = -1, object = -1}), !c.oom, .Unknown
		}
		mark_uncompiled(c, e, "unsupported BETWEEN expression in CHECK")
		return rules.NONE, false, .Unknown

	case .In_List:
		lhs := c.parsed.exprs[e.lhs]
		if lhs.kind != .Ident || !expr_matches_col(c, lhs, col_name) {
			mark_uncompiled(c, e, "unsupported IN target in CHECK")
			return rules.NONE, false, .Unknown
		}
		vals, verr := make([]rules.Value, len(e.literals), c.allocator)
		if verr != nil {
			c.oom = true
			return rules.NONE, false, .Unknown
		}
		for lit, i in e.literals {
			v, vok := literal_to_value(c, lit)
			if !vok {
				delete(vals, c.allocator)
				return rules.NONE, false, .Unknown
			}
			vals[i] = v
		}
		inner := c_add_node(c, rules.Node{kinds = non_null_k, has_enum = true, enum_of = vals, array = -1, object = -1})
		if c.oom {
			return rules.NONE, false, .Unknown
		}
		if !e.negated {
			return inner, true, .Unknown
		}
		return c_add_node(c, rules.Node{kinds = rules.EVERY_KIND, not = inner, array = -1, object = -1}), !c.oom, .Unknown

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
		inner := c_add_node(c, rules.Node{kinds = {.String}, rules = {pattern = pat}, array = -1, object = -1})
		if !e.negated {
			return inner, !c.oom, .Unknown
		}
		return c_add_node(c, rules.Node{kinds = rules.EVERY_KIND, not = inner, array = -1, object = -1}), !c.oom, .Unknown

	case .Unsupported:
		mark_uncompiled(c, e, "unsupported expression in CHECK constraint")
		return rules.NONE, false, .Unknown
	}

	mark_uncompiled(c, e, "unsupported expression in CHECK constraint")
	return rules.NONE, false, .Unknown
}

// Compiles a multi-column table-level boolean CHECK expression (`AND`/`OR`/`NOT` over single-column
// predicates) into a partial `rules.Object` node applied to the row object's `all_of`.
// Uses Kleene 3-valued polarity (`strict_true = false` accepts TRUE|UNKNOWN, `strict_true = true` accepts only TRUE)
// so nullable/absent columns follow exact SQL 3VL across arbitrary `AND` / `OR` / `NOT` nesting.
@(private = "file")
compile_table_check :: proc(c: ^Compiler, root: Expr_Index) -> (node: rules.Node_Index, ok: bool) {
	stack := make([dynamic]Eval_Frame, c.scratch)
	results := make([dynamic]Eval_Result, c.scratch)
	if _, aerr := append(&stack, Eval_Frame{expr = root, strict_true = false}); aerr != nil {
		c.oom = true
		return rules.NONE, false
	}

	for len(stack) > 0 && !c.oom && c.err.kind == .None {
		fr := pop(&stack)
		if fr.expr == NO_EXPR {
			if _, aerr := append(&results, Eval_Result{node = rules.NONE, ok = false}); aerr != nil {
				c.oom = true
			}
			continue
		}
		e := c.parsed.exprs[fr.expr]
		if !fr.visited && (e.kind == .And || e.kind == .Or || e.kind == .Not) {
			if _, aerr := append(&stack, Eval_Frame{expr = fr.expr, visited = true, strict_true = fr.strict_true}); aerr != nil {
				c.oom = true
				break
			}
			if e.kind == .Not {
				if _, aerr := append(&stack, Eval_Frame{expr = e.lhs, strict_true = !fr.strict_true}); aerr != nil {
					c.oom = true
					break
				}
			} else {
				if _, aerr := append(&stack, Eval_Frame{expr = e.rhs, strict_true = fr.strict_true}, Eval_Frame{expr = e.lhs, strict_true = fr.strict_true}); aerr != nil {
					c.oom = true
					break
				}
			}
			continue
		}

		#partial switch e.kind {
		case .Not:
			child := pop(&results)
			if !child.ok || child.node == rules.NONE {
				if _, aerr := append(&results, Eval_Result{node = rules.NONE, ok = false}); aerr != nil {
					c.oom = true
				}
				continue
			}
			nid := c_add_node(c, rules.Node{kinds = {.Object}, array = -1, object = -1, not = child.node})
			if _, aerr := append(&results, Eval_Result{node = nid, ok = !c.oom}); aerr != nil {
				c.oom = true
			}

		case .And:
			r_res := pop(&results)
			l_res := pop(&results)
			// Never drop an unsupported conjunct inside a subexpression (top-level `AND` chains are flattened
			// before calling `compile_table_check`).
			if !l_res.ok || !r_res.ok {
				if _, aerr := append(&results, Eval_Result{node = rules.NONE, ok = false}); aerr != nil {
					c.oom = true
				}
				continue
			}
			nid := combine_all_of(c, l_res.node, r_res.node)
			if _, aerr := append(&results, Eval_Result{node = nid, ok = !c.oom}); aerr != nil {
				c.oom = true
			}

		case .Or:
			r_res := pop(&results)
			l_res := pop(&results)
			if !l_res.ok || !r_res.ok {
				if _, aerr := append(&results, Eval_Result{node = rules.NONE, ok = false}); aerr != nil {
					c.oom = true
				}
				continue
			}
			nid := combine_any_of(c, l_res.node, r_res.node)
			if _, aerr := append(&results, Eval_Result{node = nid, ok = !c.oom}); aerr != nil {
				c.oom = true
			}

		case:
			// Leaf predicate: must reference a single known column to compile as a partial object check.
			ci, is_single := check_single_column(c, fr.expr)
			if !is_single {
				mark_uncompiled(c, e, "cross-column CHECK predicate cannot be represented in rules.Description")
				if _, aerr := append(&results, Eval_Result{node = rules.NONE, ok = false}); aerr != nil {
					c.oom = true
				}
				continue
			}
			col_pred, pok, atom_ne := compile_col_atom(c, ci, e, c.col_non_null_k[ci])
			if !pok || col_pred == rules.NONE {
				if _, aerr := append(&results, Eval_Result{node = rules.NONE, ok = false}); aerr != nil {
					c.oom = true
				}
				continue
			}
			// Determine presence & null-handling under Kleene 3-valued polarity:
			// - `IS NULL` (atom_ne == .True): 2-valued, passes iff absent or null (`required = false`).
			// - `IS NOT NULL` (atom_ne == .False): 2-valued, passes iff present and non-null (`required = true`).
			// - Other predicates (atom_ne == .Unknown):
			//   - Under `strict_true == false` (positive polarity): passes when absent, null, or matching predicate.
			//   - Under `strict_true == true` (inside `NOT`): passes ONLY when present, non-null, and matching predicate.
			req := true
			if atom_ne == .True {
				req = false
			} else if atom_ne == .Unknown && !fr.strict_true && !c.col_not_null[ci] {
				req = false
				wrapped, wok := wrap_allow_null(c, col_pred)
				if !wok {
					break
				}
				col_pred = wrapped
			} else if atom_ne == .Unknown && fr.strict_true && !c.col_not_null[ci] && .Null in c.d.nodes[col_pred].kinds {
				not_null_node := c_add_node(c, rules.Node{kinds = c.col_non_null_k[ci], array = -1, object = -1})
				if c.oom {
					break
				}
				col_pred = combine_all_of(c, not_null_node, col_pred)
				if c.oom {
					break
				}
			}
			mems, merr := make([]rules.Member, 1, c.allocator)
			if merr != nil {
				c.oom = true
				break
			}
			mems[0] = rules.Member{name = c_keep(c, c.tbl.columns[ci].name), node = col_pred, required = req}
			if c.oom {
				delete(mems, c.allocator)
				break
			}
			oid := c_add_object(c, rules.Object{members = mems, additional = rules.NONE, keys = rules.NONE})
			if c.oom {
				break
			}
			obj_node := c_add_node(c, rules.Node{kinds = {.Object}, array = -1, object = oid})
			if _, aerr := append(&results, Eval_Result{node = obj_node, ok = !c.oom}); aerr != nil {
				c.oom = true
			}
		}
	}

	if c.oom || c.err.kind != .None || len(results) == 0 {
		return rules.NONE, false
	}
	res := results[len(results) - 1]
	return res.node, res.ok
}

@(private = "file")
combine_logic :: proc(c: ^Compiler, a, b: rules.Node_Index, is_all: bool) -> rules.Node_Index {
	na := &c.d.nodes[a]
	nb := &c.d.nodes[b]
	a_flat := is_pure_all_of(na) if is_all else is_pure_any_of(na)
	b_flat := is_pure_all_of(nb) if is_all else is_pure_any_of(nb)
	a_list := na.all_of if is_all else na.any_of
	b_list := nb.all_of if is_all else nb.any_of
	total := (len(a_list) if a_flat else 1) + (len(b_list) if b_flat else 1)
	list, err := make([]rules.Node_Index, total, c.allocator)
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
	node := rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1}
	if is_all {
		node.all_of = list
	} else {
		node.any_of = list
	}
	nid := c_add_node(c, node)
	if c.oom {
		return rules.NONE
	}
	return nid
}

@(private = "file")
combine_all_of :: proc(c: ^Compiler, a, b: rules.Node_Index) -> rules.Node_Index {
	return combine_logic(c, a, b, true)
}

@(private = "file")
combine_any_of :: proc(c: ^Compiler, a, b: rules.Node_Index) -> rules.Node_Index {
	return combine_logic(c, a, b, false)
}

@(private = "file")
is_pure_all_of :: proc "contextless" (n: ^rules.Node) -> bool {
	return len(n.all_of) > 0 && n.kinds == rules.EVERY_KIND && n.rules == {} && n.array < 0 && n.object < 0 &&
		!n.has_enum && n.const_of == nil && len(n.any_of) == 0 && len(n.one_of) == 0 && n.not == nil
}

@(private = "file")
is_pure_any_of :: proc "contextless" (n: ^rules.Node) -> bool {
	return len(n.any_of) > 0 && n.kinds == rules.EVERY_KIND && n.rules == {} && n.array < 0 && n.object < 0 &&
		!n.has_enum && n.const_of == nil && len(n.all_of) == 0 && len(n.one_of) == 0 && n.not == nil
}

// Inline a single `any_of` or `not` node directly onto a column node when there are no clashes.
@(private = "file")
can_inline_single_all_of :: proc "contextless" (dst, src: ^rules.Node) -> bool {
	if src.kinds != rules.EVERY_KIND || src.rules != {} || src.array >= 0 || src.object >= 0 || src.has_enum || src.const_of != nil || len(src.all_of) > 0 || len(src.one_of) > 0 {
		return false
	}
	if len(src.any_of) > 0 && len(dst.any_of) == 0 && src.not == nil {
		return true
	}
	if src.not != nil && dst.not == nil && len(src.any_of) == 0 {
		return true
	}
	return false
}

@(private = "file")
inline_into :: proc(dst, src: ^rules.Node, allocator: runtime.Allocator, oom: ^bool) {
	if len(src.any_of) > 0 {
		cl, err := slice.clone(src.any_of, allocator)
		if err != nil {
			oom^ = true
			return
		}
		dst.any_of = cl
		return
	}
	if src.not != nil {
		dst.not = src.not
	}
}

// Converts a SQL `LIKE` pattern (`%` -> `.*`, `_` -> `.`, optional `ESCAPE` char) into an anchored ECMA regex.
@(private = "file")
like_to_ecma :: proc(c: ^Compiler, pat: string, esc: u8) -> string {
	b, berr := strings.builder_make(0, len(pat) * 2 + 2, c.scratch)
	if berr != nil {
		c.oom = true
		return ""
	}
	defer strings.builder_destroy(&b)

	if _, err := strings.write_byte(&b, '^'); err != nil {
		c.oom = true
		return ""
	}
	i := 0
	for i < len(pat) {
		ch := pat[i]
		if esc != 0 && ch == esc && i + 1 < len(pat) {
			i += 1
			if !write_escaped_regex_byte(&b, pat[i]) {
				c.oom = true
				return ""
			}
			i += 1
			continue
		}
		if ch == '%' {
			if _, err := strings.write_string(&b, `[\s\S]*`); err != nil {
				c.oom = true
				return ""
			}
		} else if ch == '_' {
			if _, err := strings.write_string(&b, `[\s\S]`); err != nil {
				c.oom = true
				return ""
			}
		} else {
			if !write_escaped_regex_byte(&b, ch) {
				c.oom = true
				return ""
			}
		}
		i += 1
	}
	if _, err := strings.write_byte(&b, '$'); err != nil {
		c.oom = true
		return ""
	}
	return c_keep(c, strings.to_string(b))
}

@(private = "file")
write_escaped_regex_byte :: proc(b: ^strings.Builder, ch: u8) -> bool {
	switch ch {
	case '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\', '/':
		if _, err := strings.write_byte(b, '\\'); err != nil {
			return false
		}
	}
	_, err := strings.write_byte(b, ch)
	return err == nil
}
