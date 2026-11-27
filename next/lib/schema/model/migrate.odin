// Versioned models, sequential document/overlay/typed migrations (`v1 -> v2 -> v3`),
// cycle/downgrade/unknown-version validation, and `schema.compare` compatibility checking.
// Zero format imports, zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package model

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import jschema "stury:lib/schema/schema"

Overlay_Migrate_Proc :: proc(ov: ^edit.Overlay, data: rawptr, allocator: runtime.Allocator) -> Error
Doc_Migrate_Proc :: proc(src: ^tape.Document, data: rawptr, allocator: runtime.Allocator) -> (tape.Document, Error)
Version_Extract_Proc :: proc(doc: ^tape.Document, data: rawptr) -> (version: int, ok: bool)

@(private)
Migration_Step_Kind :: enum u8 { Overlay, Document }

@(private)
Migration_Step :: struct { from, to: int, kind: Migration_Step_Kind, overlay_fn: Overlay_Migrate_Proc, doc_fn: Doc_Migrate_Proc, data: rawptr }

@(private)
Version_Schema :: struct { version: int, desc: rules.Description, plan: check.Plan, has_plan: bool }

Migration_Plan :: struct {
	current:        int,
	version_field:  string,
	fallback_field: string,
	extract:        Version_Extract_Proc,
	extract_data:   rawptr,
	steps:          [dynamic]Migration_Step,
	schemas:        [dynamic]Version_Schema,
	arena:          mem.Dynamic_Arena,
	arena_ready:    bool,
	allocator:      runtime.Allocator,
}

Migrate_Opts :: struct {
	skip_source_validation: bool,
	validate_steps:         bool,
	skip_target_validation: bool,
	dups:                   tape.Duplicates,
	budget:                 tape.Budget,
}

Migration_Result :: struct { from_version, to_version, steps_run: int, migrated: bool }

Schema_Compat :: struct {
	from_version, to_version: int,
	backward_compatible:      bool,
	forward_compatible:       bool,
	requires_migration:       bool,
	comparison:               jschema.Comparison,
}

Versioned_Model :: struct($T: typeid) { target: ^Model(T), plan: Migration_Plan }

schema_compat_destroy :: proc(c: ^Schema_Compat) {
	if c == nil { return }
	jschema.comparison_destroy(&c.comparison)
	c^ = {}
}

migration_plan_init :: proc(p: ^Migration_Plan, current_version: int, version_field := "schema_version", fallback_field := "version", allocator := context.allocator) {
	if p == nil { return }
	p^ = {current = current_version, version_field = version_field, fallback_field = fallback_field, allocator = allocator}
	arena := mp_ensure(p)
	if len(version_field) > 0 { if cl, err := strings.clone(version_field, arena); err == nil { p.version_field = cl } }
	if len(fallback_field) > 0 { if cl, err := strings.clone(fallback_field, arena); err == nil { p.fallback_field = cl } }
}

migration_plan_destroy :: proc(p: ^Migration_Plan) {
	if p == nil { return }
	for &vs in p.schemas { if vs.has_plan { check.plan_destroy(&vs.plan) } }
	delete(p.steps); delete(p.schemas)
	if p.arena_ready { mem.dynamic_arena_destroy(&p.arena) }
	p^ = {}
}

@(private)
mp_ensure :: proc(p: ^Migration_Plan) -> runtime.Allocator {
	if !p.arena_ready {
		alloc := p.allocator if p.allocator.procedure != nil else context.allocator
		p.allocator, p.arena_ready = alloc, true
		mem.dynamic_arena_init(&p.arena, alloc, alloc)
		p.steps.allocator, p.schemas.allocator = alloc, alloc
		if len(p.version_field) == 0 { p.version_field = "schema_version" }
		if len(p.fallback_field) == 0 { p.fallback_field = "version" }
	}
	return mem.dynamic_arena_allocator(&p.arena)
}

set_version_extractor :: proc(p: ^Migration_Plan, fn: Version_Extract_Proc, data: rawptr = nil) {
	if p != nil { p.extract, p.extract_data = fn, data }
}

register_migration :: proc { register_overlay_migration, register_doc_migration, register_typed_migration }

@(private)
add_migration_step :: proc(p: ^Migration_Plan, step: Migration_Step) -> Error {
	if step.from == step.to { return Model_Error{kind = .Cyclic_Migration, want = {text = "self-loop"}} }
	_ = mp_ensure(p)
	for s in p.steps {
		if s.from == step.from {
			return Model_Error{kind = .Duplicate_Migration, want = {text = "duplicate step" if s.to == step.to else "ambiguous outgoing migration"}}
		}
	}
	if _, err := append(&p.steps, step); err != nil { return err }
	return nil
}

@(require_results)
register_overlay_migration :: proc(p: ^Migration_Plan, from, to: int, fn: Overlay_Migrate_Proc, data: rawptr = nil) -> Error {
	if p == nil || fn == nil { return Model_Error{kind = .Bad_Option, want = {text = "migration"}} }
	return add_migration_step(p, {from = from, to = to, kind = .Overlay, overlay_fn = fn, data = data})
}

@(require_results)
register_doc_migration :: proc(p: ^Migration_Plan, from, to: int, fn: Doc_Migrate_Proc, data: rawptr = nil) -> Error {
	if p == nil || fn == nil { return Model_Error{kind = .Bad_Option, want = {text = "migration"}} }
	return add_migration_step(p, {from = from, to = to, kind = .Document, doc_fn = fn, data = data})
}

@(require_results)
register_typed_migration :: proc(p: ^Migration_Plan, from, to: int, from_model: ^Model($A), to_model: ^Model($B), convert: proc(src: ^A, dst: ^B, allocator: runtime.Allocator) -> Error) -> Error {
	if p == nil || from_model == nil || to_model == nil || convert == nil { return Model_Error{kind = .Bad_Option, want = {text = "typed migration"}} }
	Typed_Thunk :: struct { from_m: ^Model(A), to_m: ^Model(B), convert: proc(src: ^A, dst: ^B, allocator: runtime.Allocator) -> Error }
	thunk, aerr := new(Typed_Thunk, mp_ensure(p))
	if aerr != nil { return aerr }
	thunk^ = {from_model, to_model, convert}
	run_typed :: proc(src: ^tape.Document, data: rawptr, allocator: runtime.Allocator) -> (tape.Document, Error) {
		tk := (^Typed_Thunk)(data)
		old_v: A
		if lerr := load_document(tk.from_m, src, &old_v, allocator = allocator); lerr != nil { return {}, lerr }
		defer free_value(&old_v, type_info_of(A), allocator)
		new_v: B
		defer free_value(&new_v, type_info_of(B), allocator)
		if cerr := tk.convert(&old_v, &new_v, allocator); cerr != nil { return {}, cerr }
		return dump_document(tk.to_m, &new_v, allocator = allocator)
	}
	return register_doc_migration(p, from, to, run_typed, thunk)
}

@(require_results)
register_version_schema :: proc(p: ^Migration_Plan, version: int, desc: ^rules.Description) -> Error {
	if p == nil || desc == nil || len(desc.nodes) == 0 { return Model_Error{kind = .Bad_Option, want = {text = "schema"}} }
	arena := mp_ensure(p)
	copy_d: rules.Description
	init_desc(&copy_d, arena) or_return
	copy_d.root = graft(&copy_d, desc, true) or_return
	cp, cerr := check.compile(&copy_d, p.allocator)
	if cerr.kind != .None { return Model_Error{kind = map_rules_kind(cerr.kind), want = {text = cerr.keyword}} }
	for &vs in p.schemas {
		if vs.version == version {
			if vs.has_plan { check.plan_destroy(&vs.plan) }
			vs.desc, vs.plan, vs.has_plan = copy_d, cp, true
			return nil
		}
	}
	if _, err := append(&p.schemas, Version_Schema{version, copy_d, cp, true}); err != nil { check.plan_destroy(&cp); return err }
	return nil
}

@(require_results)
register_version_model :: proc(p: ^Migration_Plan, version: int, m: ^Model($T), direction := Direction.Load) -> Error {
	if p == nil || m == nil { return Model_Error{kind = .Bad_Option, want = {text = "model"}} }
	_ = mp_ensure(p)
	desc := schema(m, direction, p.allocator) or_return; defer rules.description_destroy(&desc)
	return register_version_schema(p, version, &desc)
}

@(private)
find_version_schema :: proc(p: ^Migration_Plan, version: int) -> ^Version_Schema {
	if p != nil { for &vs in p.schemas { if vs.version == version { return &vs } } }
	return nil
}

@(private)
find_outgoing_step :: proc(p: ^Migration_Plan, from: int) -> (^Migration_Step, bool) {
	if p != nil { for &s in p.steps { if s.from == from { return &s, true } } }
	return nil, false
}

@(require_results)
migration_plan_validate :: proc(p: ^Migration_Plan) -> Error {
	if p == nil { return Model_Error{kind = .Bad_Option, want = {text = "plan"}} }
	for s in p.steps {
		if s.from == s.to { return Model_Error{kind = .Cyclic_Migration, want = {text = "self-loop"}} }
		cur := s.to
		for hops := 0; ; hops += 1 {
			if cur == s.from || hops > len(p.steps) { return Model_Error{kind = .Cyclic_Migration, want = {text = "cycle"}} }
			next_s, ok := find_outgoing_step(p, cur)
			if !ok { break }
			cur = next_s.to
		}
	}
	for s in p.steps { if s.from > s.to { return Model_Error{kind = .Downgrade_Not_Allowed, want = {text = "downgrade step"}} } }
	return nil
}

@(private)
normalize_member_rules :: proc(src: ^rules.Description, arena: runtime.Allocator) -> (out: rules.Description, err: runtime.Allocator_Error) {
	init_desc(&out, arena) or_return
	out.root = graft(&out, src, true) or_return
	for &obj in out.objects {
		for &m in obj.members {
			if m.rules == {} || m.node == rules.NONE || int(m.node) >= len(out.nodes) { continue }
			base := out.nodes[m.node]
			merged, clash := rules.merged(&base, m.rules)
			if clash != "" { continue }
			base.rules = merged
			for s in ([?]^[]rules.Node_Index{&base.any_of, &base.all_of, &base.one_of}) { if len(s^) > 0 { s^ = slice.clone(s^, arena) or_return } }
			for s in ([?]^[]rules.Value{&base.enum_of, &base.examples}) { if len(s^) > 0 { s^ = slice.clone(s^, arena) or_return } }
			append(&out.nodes, base) or_return
			m.node, m.rules = rules.Node_Index(len(out.nodes) - 1), {}
		}
	}
	return out, nil
}

@(require_results)
check_schema_compat :: proc(old_desc, new_desc: ^rules.Description, from_version := 0, to_version := 0, opts := jschema.Compare_Options{}, allocator := context.allocator) -> (c: Schema_Compat, err: runtime.Allocator_Error) {
	if old_desc == nil || new_desc == nil { return {}, .Invalid_Argument }
	scratch_arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&scratch_arena, allocator, allocator); defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)
	old_norm := normalize_member_rules(old_desc, scratch) or_return
	new_norm := normalize_member_rules(new_desc, scratch) or_return
	comp := jschema.compare(&old_norm, &new_norm, opts, allocator) or_return
	bw := comp.old_in_new.verdict == .Yes
	return {from_version, to_version, bw, comp.new_in_old.verdict == .Yes, !bw, comp}, nil
}

@(require_results)
check_version_compat :: proc(p: ^Migration_Plan, from_version, to_version: int, opts := jschema.Compare_Options{}, allocator := context.allocator) -> (c: Schema_Compat, err: Error) {
	old_s, new_s := find_version_schema(p, from_version), find_version_schema(p, to_version)
	if old_s == nil || new_s == nil { return {}, Model_Error{kind = .Unknown_Version, want = {text = "unregistered version schema"}} }
	res, aerr := check_schema_compat(&old_s.desc, &new_s.desc, from_version, to_version, opts, allocator)
	return res, aerr if aerr != nil else nil
}

@(require_results)
verify_migration_plan_compat :: proc(p: ^Migration_Plan, opts := jschema.Compare_Options{}, allocator := context.allocator) -> Error {
	migration_plan_validate(p) or_return
	if len(p.schemas) <= 1 { return nil }
	versions := make([]int, len(p.schemas), allocator) or_return; defer delete(versions, allocator)
	for vs, i in p.schemas { versions[i] = vs.version }
	slice.sort(versions)
	for i in 0 ..< len(versions) - 1 {
		v_from, v_to := versions[i], versions[i + 1]
		compat := check_version_compat(p, v_from, v_to, opts, allocator) or_return; defer schema_compat_destroy(&compat)
		if compat.requires_migration && !has_migration_path(p, v_from, v_to) {
			return Model_Error{kind = .Incompatible_Schema, want = {text = "breaking schema change without migration"}}
		}
	}
	return nil
}

@(private)
has_migration_path :: proc(p: ^Migration_Plan, from, to: int) -> bool {
	if from == to { return true }
	cur := from
	for hops := 0; hops <= len(p.steps); hops += 1 {
		step, ok := find_outgoing_step(p, cur)
		if !ok { return false }
		if step.to == to { return true }
		cur = step.to
	}
	return false
}

@(require_results)
extract_document_version :: proc(p: ^Migration_Plan, doc: ^tape.Document) -> (version: int, err: Error) {
	if doc == nil || len(doc.nodes) == 0 { return 0, Model_Error{kind = .Bad_Option, want = {text = "document"}} }
	if p != nil && p.extract != nil {
		v, ok := p.extract(doc, p.extract_data)
		return v, nil if ok else Model_Error{kind = .Missing_Version, want = {text = "extractor"}}
	}
	primary := p.version_field if (p != nil && len(p.version_field) > 0) else "schema_version"
	fallback := p.fallback_field if p != nil else "version"
	alloc := p.allocator if (p != nil && p.allocator.procedure != nil) else context.allocator
	scratch_arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&scratch_arena, alloc, alloc); defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	vnode, found := doc_object_find(doc, tape.ROOT, primary, scratch)
	field_used := primary
	if !found && len(fallback) > 0 && fallback != primary { vnode, found = doc_object_find(doc, tape.ROOT, fallback, scratch); field_used = fallback }
	if !found { return 0, Model_Error{kind = .Missing_Version, want = {text = primary}} }
	v, ok := parse_version_token(doc, vnode, scratch)
	if !ok { return 0, Model_Error{kind = .Missing_Version, pointer = field_used, want = {text = "integer version"}} }
	return v, nil
}

@(private)
parse_strict_version_digits :: proc "contextless" (s: string) -> (int, bool) {
	if len(s) == 0 { return 0, false }
	n, limit := u64(0), u64(max(int))
	for c in transmute([]u8)s {
		if c < '0' || c > '9' { return 0, false }
		d := u64(c - '0')
		if n > (limit - d) / 10 { return 0, false }
		n = n * 10 + d
	}
	return int(n), true
}

@(private)
parse_version_token :: proc(doc: ^tape.Document, node: tape.Node_Index, scratch: runtime.Allocator) -> (int, bool) {
	if node == tape.NO_NODE || int(node) >= len(doc.nodes) { return 0, false }
	buf: [64]u8 = ---
	#partial switch doc.nodes[node].kind {
	case .Number:
		s, owned, ok := rules.value_number_text(rules.Node_Ref{doc, node}, buf[:], scratch)
		if !ok { return 0, false }
		defer if owned { delete(s, scratch) }
		return parse_strict_version_digits(s)
	case .String:
		s, owned, ok := rules.value_string(rules.Node_Ref{doc, node}, buf[:], scratch)
		if !ok { return 0, false }
		defer if owned { delete(s, scratch) }
		t := strings.trim_space(s)
		if len(t) > 1 && (t[0] == 'v' || t[0] == 'V') { t = t[1:] }
		return parse_strict_version_digits(t)
	}
	return 0, false
}

@(private)
validate_doc_against_version :: proc(p: ^Migration_Plan, version: int, doc: ^tape.Document, opts: Migrate_Opts, sink: ^Sink, allocator: runtime.Allocator) -> Error {
	policy, ok := resolve_dups(opts.dups, doc.format)
	if !ok { return Model_Error{kind = .Bad_Option, want = {text = "dups"}} }
	vs := find_version_schema(p, version)
	if vs == nil || !vs.has_plan { return nil }
	scratch_arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&scratch_arena, allocator, allocator); defer mem.dynamic_arena_destroy(&scratch_arena)
	first: Model_Error; oom := false; exc: tape.Exceeded; walk_err: tape.Error
	if run_check_plan(&vs.plan, doc, policy, opts.budget, nil, sink, &first, &oom, &exc, &walk_err, allocator, mem.dynamic_arena_allocator(&scratch_arena), .Check_Failed) { return nil }
	if exc.kind != .None { error_destroy(first, allocator); return tape.Error(exc) }
	if walk_err != nil { error_destroy(first, allocator); return walk_err }
	if oom { error_destroy(first, allocator); return runtime.Allocator_Error.Out_Of_Memory }
	return first if first.kind != .None else Model_Error{kind = .Check_Failed}
}

@(require_results)
migrate_document :: proc(p: ^Migration_Plan, doc: ^tape.Document, target_version := 0, opts := Migrate_Opts{}, sink: ^Sink = nil, allocator := context.allocator) -> (out_doc: tape.Document, res: Migration_Result, err: Error) {
	if p == nil || doc == nil || len(doc.nodes) == 0 { return {}, {}, Model_Error{kind = .Bad_Option, want = {text = "document"}} }
	if _, ok := resolve_dups(opts.dups, doc.format); !ok { return {}, {}, Model_Error{kind = .Bad_Option, want = {text = "dups"}} }
	migration_plan_validate(p) or_return

	target := target_version if target_version != 0 else p.current
	src_ver := extract_document_version(p, doc) or_return
	res = {from_version = src_ver, to_version = target}
	if src_ver > target { return {}, res, Model_Error{kind = .Downgrade_Not_Allowed, want = {text = "target < source"}} }
	if src_ver == target {
		if !opts.skip_target_validation { validate_doc_against_version(p, target, doc, opts, sink, allocator) or_return }
		cloned, cerr := tape.clone_document(doc, allocator)
		return cloned, res, cerr if cerr != nil else nil
	}

	chain := make([dynamic]^Migration_Step, 0, len(p.steps), allocator); defer delete(chain)
	for cur_v := src_ver; cur_v != target; {
		step, ok := find_outgoing_step(p, cur_v)
		if !ok { return {}, res, Model_Error{kind = .Unknown_Version, want = {text = "no migration path"}} }
		if len(chain) >= len(p.steps) { return {}, res, Model_Error{kind = .Cyclic_Migration, want = {text = "cycle"}} }
		append(&chain, step) or_return
		cur_v = step.to
	}
	if !opts.skip_source_validation { validate_doc_against_version(p, src_ver, doc, opts, sink, allocator) or_return }

	cur_doc, owns_cur := doc^, false
	defer if owns_cur { tape.destroy(&cur_doc) }
	for step, idx in chain {
		next_doc: tape.Document
		switch step.kind {
		case .Overlay:
			ov: edit.Overlay
			if edit.init(&ov, &cur_doc, allocator) != nil { return {}, res, Model_Error{kind = .Migration_Failed, want = {text = "overlay init"}} }
			defer edit.destroy(&ov)
			step.overlay_fn(&ov, step.data, allocator) or_return
			root_h, rerr := edit.ensure_root(&ov)
			if rerr != nil { return {}, res, Model_Error{kind = .Migration_Failed, want = {text = "overlay root"}} }
			mat, merr := edit.materialize_subtree(&ov, root_h, allocator = allocator)
			if merr != nil {
				if aerr, is_oom := merr.(runtime.Allocator_Error); is_oom { return {}, res, aerr }
				return {}, res, Model_Error{kind = .Migration_Failed, want = {text = "materialize"}}
			}
			next_doc = mat
		case .Document:
			next_doc = step.doc_fn(&cur_doc, step.data, allocator) or_return
		}
		if owns_cur { tape.destroy(&cur_doc) }
		cur_doc, owns_cur, res.steps_run = next_doc, true, res.steps_run + 1
		if idx < len(chain) - 1 && opts.validate_steps { validate_doc_against_version(p, step.to, &cur_doc, opts, sink, allocator) or_return }
	}
	if !opts.skip_target_validation { validate_doc_against_version(p, target, &cur_doc, opts, sink, allocator) or_return }
	res.migrated, owns_cur = true, false
	return cur_doc, res, nil
}

@(require_results)
versioned_load_document :: proc(vm: ^Versioned_Model($T), doc: ^tape.Document, out: ^T, sink: ^Sink = nil, load_opts := Load_Opts{}, migrate_opts := Migrate_Opts{}, allocator := context.allocator) -> (res: Migration_Result, err: Error) {
	if vm == nil || vm.target == nil || doc == nil || out == nil { return {}, Model_Error{kind = .Bad_Option, want = {text = "versioned_model"}} }
	if _, ok := resolve_dups(migrate_opts.dups, doc.format); !ok { return {}, Model_Error{kind = .Bad_Option, want = {text = "dups"}} }
	migration_plan_validate(&vm.plan) or_return
	src_ver, target := extract_document_version(&vm.plan, doc) or_return, vm.plan.current
	res = {from_version = src_ver, to_version = target}
	if src_ver == target {
		if !migrate_opts.skip_target_validation { validate_doc_against_version(&vm.plan, target, doc, migrate_opts, sink, allocator) or_return }
		load_document(vm.target, doc, out, sink, load_opts, allocator) or_return
		return res, nil
	}
	migrated, mres, merr := migrate_document(&vm.plan, doc, target, migrate_opts, sink, allocator)
	if merr != nil { return mres, merr }
	defer tape.destroy(&migrated)
	load_document(vm.target, &migrated, out, sink, load_opts, allocator) or_return
	return mres, nil
}
