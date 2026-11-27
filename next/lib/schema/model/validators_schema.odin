// JSON Schema `x-stury-validators` metadata export, import, annotation, and schema-driven document validation.
// Iterative explicit heap stacks (zero unbounded native recursion), OOM-safe, zero format imports,
// zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package model

import "base:runtime"
import "core:mem"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:lib/ops/write"
import "stury:lib/schema/rules"
import jschema "stury:lib/schema/schema"

@(private)
VALIDATOR_WALK_LIMIT :: 65536

@(private = "file")
_ :: write.Token_Tape

// One instance-path binding of declarative named validators (`x-stury-validators`).
Validator_Binding :: struct {
	// RFC 6901 JSON Pointer path (empty for root; `*` segments match any array index or map key).
	pointer:    string,
	validators: []string,
}

// Collection of named-validator bindings extracted from a `Model(T)` or a JSON Schema document.
Schema_Validators :: struct {
	bindings:  []Validator_Binding,
	allocator: runtime.Allocator,
}

schema_validators_destroy :: proc(sv: ^Schema_Validators) {
	if sv == nil { return }
	a := sv.allocator
	for b in sv.bindings {
		delete(b.pointer, a)
		for v in b.validators { delete(v, a) }
		delete(b.validators, a)
	}
	delete(sv.bindings, a)
	sv^ = {}
}

// Extracts every named validator binding from compiled model `m` as RFC 6901 instance paths.
@(require_results)
model_validators :: proc(m: ^Model($T), direction := Direction.Load, allocator := context.allocator) -> (sv: Schema_Validators, err: Error) {
	if m == nil || len(m.plan.nodes) == 0 { return {}, Model_Error{kind = .Bad_Option, want = {text = "model"}} }
	sv.allocator = allocator
	defer if err != nil { schema_validators_destroy(&sv) }

	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	out := make([dynamic]Validator_Binding, allocator)
	defer if err != nil {
		for b in out {
			delete(b.pointer, allocator)
			for v in b.validators { delete(v, allocator) }
			delete(b.validators, allocator)
		}
		delete(out)
	}

	collect_plan_validators(&m.plan, m.plan.root, direction, &out, allocator, scratch) or_return
	sv.bindings = out[:]
	return sv, nil
}

// Iterative explicit-stack traversal over `Type_Plan` collecting all named validator bindings.
@(private)
collect_plan_validators :: proc(
	plan: ^Type_Plan, root_idx: i32, dir: Direction, out: ^[dynamic]Validator_Binding,
	allocator, scratch: runtime.Allocator,
) -> Error {
	Frame_Kind :: enum u8 { Enter, Push_Field, Pop_Step, Leave_Node }
	Frame :: struct {
		kind:     Frame_Kind,
		node_idx: i32,
		step:     string,
		refs:     []Named_Validator_Ref,
	}
	stack := make([dynamic]Frame, 0, 32, scratch) or_return
	steps := make([dynamic]string, 0, 16, scratch) or_return
	active := make(map[i32]bool, 16, scratch) or_return
	append(&stack, Frame{kind = .Enter, node_idx = root_idx}) or_return

	visits := 0
	for len(stack) > 0 {
		fr := pop(&stack)
		switch fr.kind {
		case .Pop_Step:
			if len(steps) > 0 { pop(&steps) }
		case .Leave_Node:
			delete_key(&active, fr.node_idx)
		case .Push_Field:
			append(&steps, fr.step) or_return
			if len(fr.refs) > 0 {
				push_validator_binding(steps[:], fr.refs, out, allocator) or_return
			}
			append(&stack, Frame{kind = .Pop_Step}) or_return
			append(&stack, Frame{kind = .Enter, node_idx = fr.node_idx}) or_return
		case .Enter:
			visits += 1
			if visits > VALIDATOR_WALK_LIMIT { return Model_Error{kind = .Exceeded, want = {text = "validator schema walk"}} }
			if fr.node_idx < 0 || int(fr.node_idx) >= len(plan.nodes) { continue }
			at, _ := unwrap_node(plan, fr.node_idx, false)
			if at < 0 { continue }
			tn := &plan.nodes[at]

			if len(tn.named_validators) > 0 {
				push_validator_binding(steps[:], tn.named_validators, out, allocator) or_return
			}
			if active[at] { continue }
			map_insert(&active, at, true) or_return
			append(&stack, Frame{kind = .Leave_Node, node_idx = at}) or_return

			#partial switch tn.kind {
			case .Struct:
				si := &plan.structs[tn.struct_idx]
				for i := len(si.fields) - 1; i >= 0; i -= 1 {
					f := &si.fields[i]
					if dir == .Dump && .Write_Only in f.flags { continue }
					if dir == .Load && .Read_Only in f.flags { continue }
					append(&stack, Frame{kind = .Push_Field, node_idx = f.node, step = f.name, refs = f.named_validators}) or_return
				}
			case .Slice, .Dynamic, .Array, .Fixed_List, .Map:
				append(&stack, Frame{kind = .Push_Field, node_idx = tn.child, step = "*"}) or_return
			}
		}
	}
	return nil
}

@(private)
push_validator_binding :: proc(steps: []string, refs: []Named_Validator_Ref, out: ^[dynamic]Validator_Binding, allocator: runtime.Allocator) -> (err: runtime.Allocator_Error) {
	ptr := format_string_pointer(steps, allocator) or_return
	ptr_kept := false
	defer if !ptr_kept { delete(ptr, allocator) }

	// Merge into existing binding for the same pointer if present.
	for &b in out {
		if b.pointer != ptr { continue }
		extra := 0
		for ref, i in refs {
			dup := false
			for existing in b.validators { if existing == ref.name { dup = true; break } }
			if !dup {
				for j in 0 ..< i { if refs[j].name == ref.name { dup = true; break } }
			}
			if !dup { extra += 1 }
		}
		if extra == 0 { return nil }
		grown := make([]string, len(b.validators) + extra, allocator) or_return
		cloned_count := 0
		grown_kept := false
		defer if !grown_kept {
			for j in len(b.validators) ..< len(b.validators) + cloned_count {
				delete(grown[j], allocator)
			}
			delete(grown, allocator)
		}
		copy(grown, b.validators)
		k := len(b.validators)
		for ref in refs {
			dup := false
			for existing in grown[:k] { if existing == ref.name { dup = true; break } }
			if !dup {
				grown[k] = strings.clone(ref.name, allocator) or_return
				k += 1
				cloned_count += 1
			}
		}
		delete(b.validators, allocator)
		b.validators = grown
		grown_kept = true
		return nil
	}

	// Deduplicate incoming `refs` for a fresh binding.
	uniq := 0
	for ref, i in refs {
		dup := false
		for j in 0 ..< i { if refs[j].name == ref.name { dup = true; break } }
		if !dup { uniq += 1 }
	}
	names := make([]string, uniq, allocator) or_return
	cloned_count := 0
	names_kept := false
	defer if !names_kept {
		for j in 0 ..< cloned_count { delete(names[j], allocator) }
		delete(names, allocator)
	}
	k := 0
	for ref, i in refs {
		dup := false
		for j in 0 ..< i { if refs[j].name == ref.name { dup = true; break } }
		if !dup {
			names[k] = strings.clone(ref.name, allocator) or_return
			k += 1
			cloned_count += 1
		}
	}
	append(out, Validator_Binding{pointer = ptr, validators = names}) or_return
	ptr_kept = true
	names_kept = true
	return nil
}

@(private)
format_string_pointer :: proc(steps: []string, allocator: runtime.Allocator) -> (res: string, err: runtime.Allocator_Error) {
	if len(steps) == 0 { return "", nil }
	buf := make([dynamic]u8, 0, 32, allocator) or_return
	defer if err != nil { delete(buf) }
	for s in steps {
		append(&buf, '/') or_return
		for c in transmute([]u8)s {
			switch c {
			case '~': append(&buf, '~', '0') or_return
			case '/': append(&buf, '~', '1') or_return
			case:     append(&buf, c) or_return
			}
		}
	}
	return string(buf[:]), nil
}

// ============================================================================
// Exporting `"x-stury-validators"` into JSON Schema documents and JSON text
// ============================================================================

// Annotates `schema_doc` (a JSON Schema `tape.Document`) with `"x-stury-validators": [...]` metadata
// for every named validator declared on `m`, returning a newly materialized `tape.Document`.
@(require_results)
annotate_schema_document :: proc(m: ^Model($T), schema_doc: ^tape.Document, direction := Direction.Load, allocator := context.allocator) -> (doc: tape.Document, err: Error) {
	if m == nil || schema_doc == nil || len(schema_doc.nodes) == 0 {
		return {}, Model_Error{kind = .Bad_Option, want = {text = "schema"}}
	}
	if !m.plan.has_named_validators {
		cloned, cerr := tape.clone_document(schema_doc, allocator)
		if cerr != nil { return {}, cerr }
		return cloned, nil
	}
	ov: edit.Overlay
	if eerr := edit.init(&ov, schema_doc, allocator); eerr != nil {
		return {}, Model_Error{kind = .Bad_Option, want = {text = "overlay"}}
	}
	defer edit.destroy(&ov)
	root_h, rerr := edit.ensure_root(&ov)
	if rerr != nil { return {}, Model_Error{kind = .Bad_Option, want = {text = "root"}} }

	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	if aerr := annotate_schema_nodes(&m.plan, m.plan.root, direction, &ov, root_h, scratch); aerr != nil {
		return {}, aerr
	}
	mat, merr := edit.materialize_subtree(&ov, root_h, allocator = allocator)
	if merr != nil {
		if aerr, is_oom := merr.(runtime.Allocator_Error); is_oom { return {}, aerr }
		return {}, Model_Error{kind = .Unsupported, want = {text = "materialize"}}
	}
	return mat, nil
}

// Generates Draft 2020-12 JSON Schema text for `m`, including `"x-stury-validators": [...]` metadata
// whenever `m` declares any named validators.
@(require_results)
schema_json :: proc(m: ^Model($T), direction := Direction.Load, wopts := jschema.Write_Options{}, allocator := context.allocator) -> (text: []u8, err: Error) {
	if m == nil || len(m.plan.nodes) == 0 { return nil, Model_Error{kind = .Bad_Option, want = {text = "model"}} }
	desc := schema(m, direction, allocator) or_return
	defer rules.description_destroy(&desc)

	raw, serr := jschema.write_schema(&desc, wopts, allocator)
	if serr.kind != .None {
		jschema.error_destroy(&serr)
		return nil, Model_Error{kind = .Unsupported, want = {text = "schema"}}
	}
	if !m.plan.has_named_validators {
		return raw, nil
	}
	defer delete(raw, allocator)

	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	tt: write.Token_Tape
	base_doc, pok := jschema.parse_json_to_tape(raw, &tt, scratch)
	if !pok { return nil, Model_Error{kind = .Walk, want = {text = "schema json"}} }
	defer write.token_tape_drop(&tt)

	annotated := annotate_schema_document(m, &base_doc, direction, scratch) or_return
	defer tape.destroy(&annotated)
	out, werr := jschema.tape_to_json(&annotated, wopts, allocator, scratch)
	if werr != nil { return nil, werr }
	return out, nil
}

@(private)
schema_resolve_ref_handle :: proc(ov: ^edit.Overlay, root_h, h: edit.Handle, scratch: runtime.Allocator) -> edit.Handle {
	ref_h, ref_base, has_ref := edit.lookup_member(ov, h, "$ref")
	if !has_ref { return h }
	ref_str, ok := overlay_read_string(ov, ref_h, ref_base, scratch)
	if !ok || !strings.has_prefix(ref_str, "#/$defs/") { return h }
	def_name := ref_str[len("#/$defs/"):]
	defs_h, defs_base, has_defs := edit.lookup_member(ov, root_h, "$defs")
	if !has_defs { return h }
	dh := ensure_overlay_handle(ov, defs_h, defs_base)
	if dh == edit.NO_HANDLE { return h }
	target_h, target_base, has_target := edit.lookup_member(ov, dh, def_name)
	if !has_target { return h }
	th := ensure_overlay_handle(ov, target_h, target_base)
	return th if th != edit.NO_HANDLE else h
}

@(private)
ensure_overlay_handle :: proc(ov: ^edit.Overlay, h: edit.Handle, base: tape.Node_Index) -> edit.Handle {
	if h != edit.NO_HANDLE { return h }
	if base == tape.NO_NODE { return edit.NO_HANDLE }
	nh, err := edit.handle_for_base(ov, base)
	return nh if err == nil else edit.NO_HANDLE
}

@(private)
overlay_read_string :: proc(ov: ^edit.Overlay, h: edit.Handle, base: tape.Node_Index, scratch: runtime.Allocator) -> (string, bool) {
	if h != edit.NO_HANDLE {
		if n, ok := edit.get_node(ov, h); ok && n.state == .Replaced && n.val.kind == .String {
			cl, err := strings.clone(n.val.text, scratch)
			return cl, err == nil
		}
	}
	if base != tape.NO_NODE && ov.base != nil && int(base) < len(ov.base.nodes) {
		tok := ov.base.nodes[base]
		if tok.kind == .String {
			return clone_token_text(ov.base, tok, scratch)
		}
	}
	return "", false
}

// Appends any existing `"x-stury-validators"` strings on `obj_h` into `names` before merging new refs.
@(private)
overlay_read_existing_validators :: proc(ov: ^edit.Overlay, obj_h: edit.Handle, names: ^[dynamic]string, scratch: runtime.Allocator) -> runtime.Allocator_Error {
	vh, vbase, found := edit.lookup_member(ov, obj_h, X_STURY_VALIDATORS_KEY)
	if !found { return nil }
	push_unique :: proc(names: ^[dynamic]string, s: string) -> runtime.Allocator_Error {
		for n in names { if n == s { return nil } }
		_, err := append(names, s)
		return err
	}
	if vh != edit.NO_HANDLE {
		if n, ok := edit.get_node(ov, vh); ok && n.state == .Replaced && n.val.kind == .Array {
			for eh in n.elems {
				if en, eok := edit.get_node(ov, eh); eok && en.state == .Replaced && en.val.kind == .String {
					cl := strings.clone(en.val.text, scratch) or_return
					push_unique(names, cl) or_return
				}
			}
			return nil
		}
	}
	if vbase != tape.NO_NODE && ov.base != nil && int(vbase) < len(ov.base.nodes) && ov.base.nodes[vbase].kind == .Array {
		elems, aok := extract_array(rules.Node_Ref{ov.base, vbase}, scratch)
		if !aok { return .Out_Of_Memory }
		buf: [128]u8 = ---
		for elem in elems {
			if rules.value_kind(elem) != .String { continue }
			s, owned, sok := rules.value_string(elem, buf[:], scratch)
			if !sok { return .Out_Of_Memory }
			defer if owned { delete(s, scratch) }
			cl := strings.clone(s, scratch) or_return
			push_unique(names, cl) or_return
		}
	}
	return nil
}

@(private)
overlay_set_validators :: proc(ov: ^edit.Overlay, obj_h: edit.Handle, refs: []Named_Validator_Ref, scratch: runtime.Allocator) -> Error {
	if len(refs) == 0 || obj_h == edit.NO_HANDLE { return nil }
	names := make([dynamic]string, 0, len(refs) + 2, scratch)
	overlay_read_existing_validators(ov, obj_h, &names, scratch) or_return
	for ref in refs {
		dup := false
		for n in names { if n == ref.name { dup = true; break } }
		if !dup {
			if _, aerr := append(&names, ref.name); aerr != nil { return aerr }
		}
	}
	elems, eerr := make([]edit.Handle, len(names), scratch)
	if eerr != nil { return eerr }
	for name, i in names {
		sh, serr := edit.new_node(ov, edit.val_string(name))
		if serr != nil { return runtime.Allocator_Error.Out_Of_Memory }
		elems[i] = sh
	}
	_, merr := edit.set_member(ov, obj_h, X_STURY_VALIDATORS_KEY, edit.val_array(elems))
	if merr != nil {
		if aerr, is_oom := merr.(runtime.Allocator_Error); is_oom { return aerr }
		return Model_Error{kind = .Unsupported, want = {text = X_STURY_VALIDATORS_KEY}}
	}
	return nil
}

// Iterative explicit-stack annotation of `ov` with `"x-stury-validators"` from `plan`.
@(private)
annotate_schema_nodes :: proc(
	plan: ^Type_Plan, root_idx: i32, dir: Direction, ov: ^edit.Overlay,
	root_h: edit.Handle, scratch: runtime.Allocator,
) -> Error {
	Frame_Kind :: enum u8 { Enter, Leave_Node }
	Frame :: struct {
		kind:     Frame_Kind,
		node_idx: i32,
		cur_h:    edit.Handle,
	}
	stack := make([dynamic]Frame, 0, 32, scratch) or_return
	active := make(map[i32]bool, 16, scratch) or_return
	append(&stack, Frame{kind = .Enter, node_idx = root_idx, cur_h = root_h}) or_return

	visits := 0
	for len(stack) > 0 {
		fr := pop(&stack)
		switch fr.kind {
		case .Leave_Node:
			delete_key(&active, fr.node_idx)
		case .Enter:
			visits += 1
			if visits > VALIDATOR_WALK_LIMIT { return Model_Error{kind = .Exceeded, want = {text = "validator schema annotate"}} }
			if fr.node_idx < 0 || fr.cur_h == edit.NO_HANDLE { continue }
			at, _ := unwrap_node(plan, fr.node_idx, false)
			if at < 0 { continue }
			tn := &plan.nodes[at]

			target_h := schema_resolve_ref_handle(ov, root_h, fr.cur_h, scratch)
			if len(tn.named_validators) > 0 {
				overlay_set_validators(ov, target_h, tn.named_validators, scratch) or_return
			}
			if active[at] { continue }
			map_insert(&active, at, true) or_return
			append(&stack, Frame{kind = .Leave_Node, node_idx = at}) or_return

			#partial switch tn.kind {
			case .Struct:
				props_h, props_base, has_props := edit.lookup_member(ov, target_h, "properties")
				if !has_props { continue }
				ph := ensure_overlay_handle(ov, props_h, props_base)
				if ph == edit.NO_HANDLE { continue }
				si := &plan.structs[tn.struct_idx]
				for i := len(si.fields) - 1; i >= 0; i -= 1 {
					f := &si.fields[i]
					if dir == .Dump && .Write_Only in f.flags { continue }
					if dir == .Load && .Read_Only in f.flags { continue }
					fh, fbase, has_f := edit.lookup_member(ov, ph, f.name)
					if !has_f { continue }
					field_obj := ensure_overlay_handle(ov, fh, fbase)
					if field_obj == edit.NO_HANDLE { continue }
					if len(f.named_validators) > 0 {
						overlay_set_validators(ov, field_obj, f.named_validators, scratch) or_return
					}
					append(&stack, Frame{kind = .Enter, node_idx = f.node, cur_h = field_obj}) or_return
				}
			case .Slice, .Dynamic, .Array, .Fixed_List:
				ih, ibase, has_i := edit.lookup_member(ov, target_h, "items")
				if has_i {
					item_obj := ensure_overlay_handle(ov, ih, ibase)
					append(&stack, Frame{kind = .Enter, node_idx = tn.child, cur_h = item_obj}) or_return
				}
			case .Map:
				ah, abase, has_a := edit.lookup_member(ov, target_h, "additionalProperties")
				if has_a {
					add_obj := ensure_overlay_handle(ov, ah, abase)
					append(&stack, Frame{kind = .Enter, node_idx = tn.child, cur_h = add_obj}) or_return
				}
			}
		}
	}
	return nil
}

// ============================================================================
// Importing `"x-stury-validators"` from JSON Schema documents & validating
// ============================================================================

// Extracts all `"x-stury-validators": [...]` declarations from JSON Schema document `schema_doc`.
@(require_results)
extract_schema_validators :: proc(schema_doc: ^tape.Document, allocator := context.allocator) -> (sv: Schema_Validators, err: Error) {
	if schema_doc == nil || len(schema_doc.nodes) == 0 {
		return {}, Model_Error{kind = .Bad_Option, want = {text = "schema"}}
	}
	sv.allocator = allocator
	defer if err != nil { schema_validators_destroy(&sv) }

	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	out := make([dynamic]Validator_Binding, allocator)
	defer if err != nil {
		for b in out {
			delete(b.pointer, allocator)
			for v in b.validators { delete(v, allocator) }
			delete(b.validators, allocator)
		}
		delete(out)
	}

	extract_schema_nodes(schema_doc, tape.ROOT, &out, allocator, scratch) or_return
	sv.bindings = out[:]
	return sv, nil
}

@(private)
doc_object_find :: proc(doc: ^tape.Document, obj_node: tape.Node_Index, want_key: string, scratch: runtime.Allocator) -> (val_node: tape.Node_Index, ok: bool) {
	if doc == nil || int(obj_node) >= len(doc.nodes) || doc.nodes[obj_node].kind != .Object { return tape.NO_NODE, false }
	r := tape.Reader{doc = doc}
	ch, p, cerr := tape.children(r, obj_node, scratch)
	if cerr != nil || p != .Found { return tape.NO_NODE, false }
	defer tape.destroy_children(&ch)
	buf: [128]u8 = ---
	for {
		kn, vn, np := tape.next_child(r, &ch, .Last)
		if np != .Found { break }
		ktok := doc.nodes[kn] if kn != tape.NO_NODE else tape.cell_key(r, ch)
		if ks, kok := tape.node_text(doc, ktok, buf[:]); kok {
			if ks == want_key { return vn, true }
		} else if kcl, ok2 := clone_token_text(doc, ktok, scratch); ok2 {
			if kcl == want_key { return vn, true }
		}
	}
	return tape.NO_NODE, false
}

// Iterative explicit-stack extraction of `"x-stury-validators"` from a JSON Schema document.
@(private)
extract_schema_nodes :: proc(
	doc: ^tape.Document, root: tape.Node_Index, out: ^[dynamic]Validator_Binding,
	allocator, scratch: runtime.Allocator,
) -> Error {
	Frame_Kind :: enum u8 { Enter, Push_Step, Pop_Step, Leave_Node }
	Frame :: struct {
		kind: Frame_Kind,
		node: tape.Node_Index,
		step: string,
	}
	Prop_Entry :: struct {
		key:  string,
		node: tape.Node_Index,
	}

	stack := make([dynamic]Frame, 0, 32, scratch) or_return
	steps := make([dynamic]string, 0, 16, scratch) or_return
	active := make(map[tape.Node_Index]bool, 16, scratch) or_return
	props_buf := make([dynamic]Prop_Entry, 0, 16, scratch) or_return
	append(&stack, Frame{kind = .Enter, node = root}) or_return

	visits := 0
	for len(stack) > 0 {
		fr := pop(&stack)
		switch fr.kind {
		case .Pop_Step:
			if len(steps) > 0 { pop(&steps) }
		case .Leave_Node:
			delete_key(&active, fr.node)
		case .Push_Step:
			append(&steps, fr.step) or_return
			append(&stack, Frame{kind = .Pop_Step}) or_return
			append(&stack, Frame{kind = .Enter, node = fr.node}) or_return
		case .Enter:
			visits += 1
			if visits > VALIDATOR_WALK_LIMIT { return Model_Error{kind = .Exceeded, want = {text = "validator schema extract"}} }
			node := fr.node
			if node == tape.NO_NODE || int(node) >= len(doc.nodes) || doc.nodes[node].kind != .Object { continue }
			if active[node] { continue }
			map_insert(&active, node, true) or_return
			append(&stack, Frame{kind = .Leave_Node, node = node}) or_return

			// Extract `"x-stury-validators"` on this schema object if present.
			if vnode, has_v := doc_object_find(doc, node, X_STURY_VALIDATORS_KEY, scratch); has_v {
				if doc.nodes[vnode].kind != .Array {
					ptr, _ := format_string_pointer(steps[:], allocator)
					wt, _ := strings.clone(X_STURY_VALIDATORS_KEY, allocator)
					return Model_Error{kind = .Bad_Tag, pointer = ptr, want = {text = wt}, owned = len(ptr) > 0 || len(wt) > 0}
				}
				elems, aok := extract_array(rules.Node_Ref{doc, vnode}, scratch)
				if !aok { return runtime.Allocator_Error.Out_Of_Memory }
				refs, rerr := make([]Named_Validator_Ref, len(elems), scratch)
				if rerr != nil { return rerr }
				buf: [128]u8 = ---
				for elem, i in elems {
					if rules.value_kind(elem) != .String {
						ptr, _ := format_string_pointer(steps[:], allocator)
						wt, _ := strings.clone(X_STURY_VALIDATORS_KEY, allocator)
						return Model_Error{kind = .Bad_Tag, pointer = ptr, want = {text = wt}, owned = len(ptr) > 0 || len(wt) > 0}
					}
					s, owned, sok := rules.value_string(elem, buf[:], scratch)
					if !sok { return runtime.Allocator_Error.Out_Of_Memory }
					defer if owned { delete(s, scratch) }
					if !valid_validator_name(s) {
						ptr, _ := format_string_pointer(steps[:], allocator)
						wt, _ := strings.clone(s, allocator)
						return Model_Error{kind = .Bad_Tag, pointer = ptr, want = {text = wt}, owned = len(ptr) > 0 || len(wt) > 0}
					}
					cloned, cerr := strings.clone(s, scratch)
					if cerr != nil { return cerr }
					refs[i] = Named_Validator_Ref{name = cloned}
				}
				if len(refs) > 0 {
					push_validator_binding(steps[:], refs, out, allocator) or_return
				}
			}

			// Push children in reverse evaluation order (LIFO): allOf, additionalProperties, items, properties, $ref.
			if all_node, has_all := doc_object_find(doc, node, "allOf", scratch); has_all && doc.nodes[all_node].kind == .Array {
				elems, aok := extract_array(rules.Node_Ref{doc, all_node}, scratch)
				if !aok { return runtime.Allocator_Error.Out_Of_Memory }
				for i := len(elems) - 1; i >= 0; i -= 1 {
					if ref, is_ref := elems[i].(rules.Node_Ref); is_ref {
						append(&stack, Frame{kind = .Enter, node = ref.node}) or_return
					}
				}
			}
			if add_node, has_add := doc_object_find(doc, node, "additionalProperties", scratch); has_add && doc.nodes[add_node].kind == .Object {
				append(&stack, Frame{kind = .Push_Step, node = add_node, step = "*"}) or_return
			}
			if items_node, has_items := doc_object_find(doc, node, "items", scratch); has_items && doc.nodes[items_node].kind == .Object {
				append(&stack, Frame{kind = .Push_Step, node = items_node, step = "*"}) or_return
			}
			if props_node, has_props := doc_object_find(doc, node, "properties", scratch); has_props && doc.nodes[props_node].kind == .Object {
				clear(&props_buf)
				r := tape.Reader{doc = doc}
				ch, p, cerr := tape.children(r, props_node, scratch)
				if cerr != nil { return cerr }
				defer tape.destroy_children(&ch)
				if p == .Found {
					for {
						kn, vn, np := tape.next_child(r, &ch, .Last)
						if np != .Found { break }
						ktok := doc.nodes[kn] if kn != tape.NO_NODE else tape.cell_key(r, ch)
						kstr, kok := clone_token_text(doc, ktok, scratch)
						if !kok { return runtime.Allocator_Error.Out_Of_Memory }
						append(&props_buf, Prop_Entry{key = kstr, node = vn}) or_return
					}
					for i := len(props_buf) - 1; i >= 0; i -= 1 {
						append(&stack, Frame{kind = .Push_Step, node = props_buf[i].node, step = props_buf[i].key}) or_return
					}
				}
			}
			if ref_node, has_ref := doc_object_find(doc, node, "$ref", scratch); has_ref && doc.nodes[ref_node].kind == .String {
				if ref_text, rok := clone_token_text(doc, doc.nodes[ref_node], scratch); rok {
					if target, tok := resolve_local_def(doc, ref_text, scratch); tok {
						append(&stack, Frame{kind = .Enter, node = target}) or_return
					}
				}
			}
		}
	}
	return nil
}

@(private)
resolve_local_def :: proc(doc: ^tape.Document, ref: string, scratch: runtime.Allocator) -> (tape.Node_Index, bool) {
	container_key, def_name: string
	if strings.has_prefix(ref, "#/$defs/") {
		container_key, def_name = "$defs", ref[len("#/$defs/"):]
	} else if strings.has_prefix(ref, "#/definitions/") {
		container_key, def_name = "definitions", ref[len("#/definitions/"):]
	} else {
		return tape.NO_NODE, false
	}
	defs, ok := doc_object_find(doc, tape.ROOT, container_key, scratch)
	if !ok { return tape.NO_NODE, false }
	return doc_object_find(doc, defs, def_name, scratch)
}

// Imports `"x-stury-validators"` declarations from JSON Schema document `schema_doc` and registers them
// as `Field_Rule_Of` / `Type_Rule` entries on Odin type `T` (and nested struct fields) in `reg`.
@(require_results)
register_schema_validators :: proc(reg: ^Registry, $T: typeid, schema_doc: ^tape.Document, tag := "json") -> Error {
	if reg == nil || schema_doc == nil || len(schema_doc.nodes) == 0 {
		return Model_Error{kind = .Bad_Option, want = {text = "schema"}}
	}
	alloc := reg.loads.allocator if reg.loads.allocator.procedure != nil else context.allocator
	sv := extract_schema_validators(schema_doc, alloc) or_return
	defer schema_validators_destroy(&sv)

	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, alloc, alloc)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	for b in sv.bindings {
		if len(b.validators) == 0 { continue }
		rule_tag := build_validator_tag(b.validators, scratch) or_return
		if len(b.pointer) == 0 {
			register_type(reg, Type_Rule{type = T, tag = rule_tag}) or_return
			continue
		}
		if owner, field_name, matched := resolve_struct_field_path(type_info_of(T), b.pointer, tag, reg, scratch); matched {
			register_field(reg, Field_Rule_Of{type = owner, field = field_name, tag = rule_tag}) or_return
		}
	}
	return nil
}

@(private)
build_validator_tag :: proc(names: []string, scratch: runtime.Allocator) -> (res: string, err: runtime.Allocator_Error) {
	buf := make([dynamic]u8, 0, 32, scratch) or_return
	for name, i in names {
		if i > 0 { append(&buf, ',') or_return }
		append(&buf, ..transmute([]u8)string("validate=")) or_return
		append(&buf, ..transmute([]u8)name) or_return
	}
	return string(buf[:]), nil
}

@(private)
resolve_struct_field_path :: proc(ti: ^runtime.Type_Info, pointer, tag_key: string, reg: ^Registry, scratch: runtime.Allocator) -> (owner: typeid, odin_field: string, ok: bool) {
	if ti == nil || len(pointer) == 0 || pointer[0] != '/' { return nil, "", false }
	cur_ti := ti
	rest := pointer[1:]
	for {
		slash := strings.index_byte(rest, '/')
		seg := rest[:slash] if slash >= 0 else rest
		is_last := slash < 0

		// Unwrap Maybe/pointer wrappers.
		for next := held_type(cur_ti); next != nil; next = held_type(cur_ti) { cur_ti = next }
		base := runtime.type_info_base(cur_ti)
		if seg == "*" {
			#partial switch v in base.variant {
			case ^runtime.Type_Info_Slice:                         cur_ti = v.elem
			case ^runtime.Type_Info_Dynamic_Array:                 cur_ti = v.elem
			case ^runtime.Type_Info_Array:                         cur_ti = v.elem
			case ^runtime.Type_Info_Fixed_Capacity_Dynamic_Array:  cur_ti = v.elem
			case ^runtime.Type_Info_Map:                           cur_ti = v.value
			case:                                                  return nil, "", false
			}
			if is_last { return nil, "", false }
			rest = rest[slash + 1:]
			continue
		}
		st, is_st := base.variant.(^runtime.Type_Info_Struct)
		if !is_st { return nil, "", false }

		found_idx := -1
		for i in 0 ..< int(st.field_count) {
			fname := st.names[i]
			if fname == "_" { continue }
			ft := parse_format_tag(st.tags[i], tag_key)
			if ft.skip { continue }
			wire := fname
			if ft.has_name {
				wire = ft.name
			} else if reg != nil && reg.naming.fields != .None {
				if rn, rerr := rename_text(fname, reg.naming.fields, scratch); rerr == nil { wire = rn }
			}
			if pointer_segment_equals(seg, wire) {
				found_idx = i
				break
			}
		}
		if found_idx < 0 { return nil, "", false }
		if is_last { return cur_ti.id, st.names[found_idx], true }
		cur_ti = st.types[found_idx]
		rest = rest[slash + 1:]
	}
}

// Runs extracted `x-stury-validators` bindings from `sv` directly against any `tape.Document` using `vr`.
@(require_results)
validate_schema_validators :: proc(doc: ^tape.Document, sv: ^Schema_Validators, vr: ^Validator_Registry, sink: ^Sink = nil, allocator := context.allocator) -> Error {
	if doc == nil || len(doc.nodes) == 0 || sv == nil { return Model_Error{kind = .Bad_Option, want = {text = "document"}} }
	if len(sv.bindings) == 0 { return nil }

	scratch_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch_arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)

	from := len(sink.entries) if sink != nil else 0
	first: Model_Error
	oom := false
	rep: Report
	report_init(&rep, scratch)
	defer report_destroy(&rep)
	steps := make([dynamic]tape.Step, 0, 16, scratch)

	for b in sv.bindings {
		clear(&steps)
		run_binding_on_doc(doc, tape.ROOT, b.pointer, b.validators, vr, &steps, &rep, sink, &first, &oom, allocator, scratch)
		if oom || (sink == nil && first.kind != .None) { break }
	}
	if sink != nil { order_sink(sink, from) }
	if oom { error_destroy(first, allocator); return runtime.Allocator_Error.Out_Of_Memory }
	return first if first.kind != .None else nil
}

// Iterative explicit-stack binding evaluator against `doc` (supporting exact pointers and `*` wildcards).
@(private)
run_binding_on_doc :: proc(
	doc: ^tape.Document, root: tape.Node_Index, root_pattern: string, validators: []string, vr: ^Validator_Registry,
	steps: ^[dynamic]tape.Step, rep: ^Report, sink: ^Sink, first: ^Model_Error, oom: ^bool,
	allocator, scratch: runtime.Allocator,
) {
	Frame_Kind :: enum u8 { Enter, Push_Step, Pop_Step }
	Frame :: struct {
		kind:    Frame_Kind,
		node:    tape.Node_Index,
		pattern: string,
		step:    tape.Step,
	}
	Child_Entry :: struct {
		node: tape.Node_Index,
		step: tape.Step,
	}
	stack, serr := make([dynamic]Frame, 0, 32, scratch)
	if serr != nil { oom^ = true; return }
	children_buf, cerr := make([dynamic]Child_Entry, 0, 16, scratch)
	if cerr != nil { oom^ = true; return }
	if !push_oom(oom, &stack, Frame{kind = .Enter, node = root, pattern = root_pattern}) { return }

	for len(stack) > 0 && !oom^ && !(sink == nil && first.kind != .None) {
		fr := pop(&stack)
		switch fr.kind {
		case .Pop_Step:
			if len(steps^) > 0 { pop(steps) }
		case .Push_Step:
			if !push_oom(oom, steps, fr.step) { return }
			if !push_oom(oom, &stack, Frame{kind = .Pop_Step}) { return }
			if !push_oom(oom, &stack, Frame{kind = .Enter, node = fr.node, pattern = fr.pattern}) { return }
		case .Enter:
			node := fr.node
			pattern := fr.pattern
			if node == tape.NO_NODE || int(node) >= len(doc.nodes) { continue }
			if len(pattern) == 0 {
				val := rules.Value(rules.Node_Ref{doc, node})
				at := doc.nodes[node].lo
				for vname in validators {
					nv, found := lookup_named_validator(vr, vname)
					if !found {
						_ = record_failure(sink, first, oom, allocator, .Missing_Validator, at, steps^[:], "", {text = vname})
						if oom^ || sink == nil { return }
						continue
					}
					report_reset(rep)
					if nv.vfn != nil {
						nv.vfn(val, rep, nv.data)
					} else if nv.fn != nil {
						nv.fn(any{&val, typeid_of(rules.Value)}, rep, nv.data)
					}
					if rep.failed || rep.oom {
						if !emit_report(rep, steps^[:], at, nil, sink, first, oom, allocator, scratch) { return }
					}
				}
				continue
			}
			if pattern[0] != '/' { continue }
			rest := pattern[1:]
			slash := strings.index_byte(rest, '/')
			seg := rest[:slash] if slash >= 0 else rest
			next_pat := rest[slash:] if slash >= 0 else ""

			n := doc.nodes[node]
			if seg == "*" {
				clear(&children_buf)
				if n.kind == .Array {
					r := tape.Reader{doc = doc}
					ch, p, ch_err := tape.children(r, node, scratch)
					if ch_err != nil { oom^ = true; return }
					defer tape.destroy_children(&ch)
					if p != .Found { continue }
					idx := 0
					for {
						_, vn, np := tape.next_child(r, &ch)
						if np != .Found { break }
						if !push_oom(oom, &children_buf, Child_Entry{node = vn, step = tape.Index(idx)}) { return }
						idx += 1
					}
				} else if n.kind == .Object {
					r := tape.Reader{doc = doc}
					ch, p, ch_err := tape.children(r, node, scratch)
					if ch_err != nil { oom^ = true; return }
					defer tape.destroy_children(&ch)
					if p != .Found { continue }
					for {
						kn, vn, np := tape.next_child(r, &ch, .Last)
						if np != .Found { break }
						ktok := doc.nodes[kn] if kn != tape.NO_NODE else tape.cell_key(r, ch)
						kstr, kok := clone_token_text(doc, ktok, scratch)
						if !kok { oom^ = true; return }
						if !push_oom(oom, &children_buf, Child_Entry{node = vn, step = tape.Name(kstr)}) { return }
					}
				}
				for i := len(children_buf) - 1; i >= 0; i -= 1 {
					if !push_oom(oom, &stack, Frame{kind = .Push_Step, node = children_buf[i].node, pattern = next_pat, step = children_buf[i].step}) { return }
				}
				continue
			}

			if n.kind == .Object {
				r := tape.Reader{doc = doc}
				ch, p, ch_err := tape.children(r, node, scratch)
				if ch_err != nil { oom^ = true; return }
				defer tape.destroy_children(&ch)
				if p != .Found { continue }
				for {
					kn, vn, np := tape.next_child(r, &ch, .Last)
					if np != .Found { break }
					ktok := doc.nodes[kn] if kn != tape.NO_NODE else tape.cell_key(r, ch)
					kstr, kok := clone_token_text(doc, ktok, scratch)
					if !kok { oom^ = true; return }
					if pointer_segment_equals(seg, kstr) {
						if !push_oom(oom, &stack, Frame{kind = .Push_Step, node = vn, pattern = next_pat, step = tape.Name(kstr)}) { return }
						break
					}
				}
			} else if n.kind == .Array {
				want_idx, iok := strconv.parse_int(seg)
				if !iok || want_idx < 0 { continue }
				r := tape.Reader{doc = doc}
				ch, p, ch_err := tape.children(r, node, scratch)
				if ch_err != nil { oom^ = true; return }
				defer tape.destroy_children(&ch)
				if p != .Found { continue }
				idx := 0
				for {
					_, vn, np := tape.next_child(r, &ch)
					if np != .Found { break }
					if idx == want_idx {
						if !push_oom(oom, &stack, Frame{kind = .Push_Step, node = vn, pattern = next_pat, step = tape.Index(idx)}) { return }
						break
					}
					idx += 1
				}
			}
		}
	}
}
