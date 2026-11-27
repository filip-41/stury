// JSON Schema `x-stury-validators` metadata export, import, annotation, and schema-driven document validation.
// Iterative explicit heap stacks (zero unbounded native recursion), OOM-safe, WASM-clean.
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

// One instance-path binding of declarative named validators (`x-stury-validators`).
Validator_Binding :: struct { pointer: string, validators: []string }

// Collection of named-validator bindings extracted from a `Model(T)` or a JSON Schema document.
Schema_Validators :: struct { bindings: []Validator_Binding, allocator: runtime.Allocator }

schema_validators_destroy :: proc(sv: ^Schema_Validators) {
	if sv == nil { return }
	free_validator_bindings(sv.bindings, sv.allocator)
	sv^ = {}
}

@(private)
free_validator_bindings :: proc(bindings: []Validator_Binding, a: runtime.Allocator) {
	for b in bindings {
		delete(b.pointer, a)
		for v in b.validators { delete(v, a) }
		delete(b.validators, a)
	}
	delete(bindings, a)
}

@(require_results)
model_validators :: proc(m: ^Model($T), direction := Direction.Load, allocator := context.allocator) -> (sv: Schema_Validators, err: Error) {
	if m == nil || len(m.plan.nodes) == 0 { return {}, Model_Error{kind = .Bad_Option, want = {text = "model"}} }
	scratch_arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&scratch_arena, allocator, allocator); defer mem.dynamic_arena_destroy(&scratch_arena)
	out := make([dynamic]Validator_Binding, allocator)
	defer if err != nil { free_validator_bindings(out[:], allocator) }
	collect_plan_validators(&m.plan, m.plan.root, direction, &out, allocator, mem.dynamic_arena_allocator(&scratch_arena)) or_return
	return {bindings = out[:], allocator = allocator}, nil
}

@(private)
collect_plan_validators :: proc(plan: ^Type_Plan, root_idx: i32, dir: Direction, out: ^[dynamic]Validator_Binding, allocator, scratch: runtime.Allocator) -> Error {
	Frame :: struct { kind: enum u8 { Enter, Push_Field, Pop_Step, Leave_Node }, node_idx: i32, step: string, refs: []Named_Validator_Ref }
	stack := make([dynamic]Frame, 0, 32, scratch) or_return
	steps := make([dynamic]string, 0, 16, scratch) or_return
	active := make(map[i32]bool, 16, scratch) or_return
	append(&stack, Frame{kind = .Enter, node_idx = root_idx}) or_return

	for visits := 0; len(stack) > 0; {
		fr := pop(&stack)
		switch fr.kind {
		case .Pop_Step:   if len(steps) > 0 { pop(&steps) }
		case .Leave_Node: delete_key(&active, fr.node_idx)
		case .Push_Field:
			append(&steps, fr.step) or_return
			if len(fr.refs) > 0 { push_validator_binding(steps[:], fr.refs, out, allocator) or_return }
			append(&stack, Frame{kind = .Pop_Step}, Frame{kind = .Enter, node_idx = fr.node_idx}) or_return
		case .Enter:
			visits += 1
			if visits > VALIDATOR_WALK_LIMIT { return Model_Error{kind = .Exceeded, want = {text = "validator schema walk"}} }
			if fr.node_idx < 0 || int(fr.node_idx) >= len(plan.nodes) { continue }
			at, _ := unwrap_node(plan, fr.node_idx, false)
			if at < 0 { continue }
			tn := &plan.nodes[at]
			if len(tn.named_validators) > 0 { push_validator_binding(steps[:], tn.named_validators, out, allocator) or_return }
			if active[at] { continue }
			map_insert(&active, at, true) or_return
			append(&stack, Frame{kind = .Leave_Node, node_idx = at}) or_return
			#partial switch tn.kind {
			case .Struct:
				si := &plan.structs[tn.struct_idx]
				for i := len(si.fields) - 1; i >= 0; i -= 1 {
					f := &si.fields[i]
					if (dir == .Dump && .Write_Only in f.flags) || (dir == .Load && .Read_Only in f.flags) { continue }
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
append_unique_validator_names :: proc(existing: []string, refs: []Named_Validator_Ref, a: runtime.Allocator) -> (grown: []string, changed: bool, err: runtime.Allocator_Error) {
	extra := 0
	for ref, i in refs {
		dup := false
		for s in existing { if s == ref.name { dup = true; break } }
		for j := 0; !dup && j < i; j += 1 { if refs[j].name == ref.name { dup = true } }
		if !dup { extra += 1 }
	}
	if extra == 0 { return existing, false, nil }
	out := make([]string, len(existing) + extra, a) or_return
	copied := 0
	defer if err != nil {
		for j in len(existing) ..< len(existing) + copied { delete(out[j], a) }
		delete(out, a)
	}
	copy(out, existing)
	k := len(existing)
	for ref in refs {
		dup := false
		for s in out[:k] { if s == ref.name { dup = true; break } }
		if !dup { out[k] = strings.clone(ref.name, a) or_return; k += 1; copied += 1 }
	}
	return out, true, nil
}

@(private)
push_validator_binding :: proc(steps: []string, refs: []Named_Validator_Ref, out: ^[dynamic]Validator_Binding, a: runtime.Allocator) -> (err: runtime.Allocator_Error) {
	ptr := format_string_pointer(steps, a) or_return
	kept := false
	defer if !kept { delete(ptr, a) }
	for &b in out {
		if b.pointer != ptr { continue }
		grown, changed := append_unique_validator_names(b.validators, refs, a) or_return
		if changed { delete(b.validators, a); b.validators = grown }
		return nil
	}
	names, _ := append_unique_validator_names(nil, refs, a) or_return
	if _, aerr := append(out, Validator_Binding{pointer = ptr, validators = names}); aerr != nil {
		for s in names { delete(s, a) }; delete(names, a); return aerr
	}
	kept = true
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

@(require_results)
annotate_schema_document :: proc(m: ^Model($T), schema_doc: ^tape.Document, direction := Direction.Load, allocator := context.allocator) -> (doc: tape.Document, err: Error) {
	if m == nil { return {}, Model_Error{kind = .Bad_Option, want = {text = "schema"}} }
	return annotate_schema_document_raw(&m.plan, schema_doc, direction, allocator)
}

@(private)
annotate_schema_document_raw :: proc(plan: ^Type_Plan, schema_doc: ^tape.Document, direction: Direction, allocator: runtime.Allocator) -> (doc: tape.Document, err: Error) {
	if plan == nil || schema_doc == nil || len(schema_doc.nodes) == 0 { return {}, Model_Error{kind = .Bad_Option, want = {text = "schema"}} }
	if !plan.has_named_validators {
		cloned, cerr := tape.clone_document(schema_doc, allocator)
		return cloned, cerr if cerr != nil else nil
	}
	ov: edit.Overlay
	if edit.init(&ov, schema_doc, allocator) != nil { return {}, Model_Error{kind = .Bad_Option, want = {text = "overlay"}} }
	defer edit.destroy(&ov)
	root_h, rerr := edit.ensure_root(&ov)
	if rerr != nil { return {}, Model_Error{kind = .Bad_Option, want = {text = "root"}} }

	scratch_arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&scratch_arena, allocator, allocator); defer mem.dynamic_arena_destroy(&scratch_arena)
	annotate_schema_nodes(plan, plan.root, direction, &ov, root_h, mem.dynamic_arena_allocator(&scratch_arena)) or_return
	mat, merr := edit.materialize_subtree(&ov, root_h, allocator = allocator)
	if merr != nil {
		if aerr, is_oom := merr.(runtime.Allocator_Error); is_oom { return {}, aerr }
		return {}, Model_Error{kind = .Unsupported, want = {text = "materialize"}}
	}
	return mat, nil
}

@(require_results)
schema_json :: proc(m: ^Model($T), direction := Direction.Load, wopts := jschema.Write_Options{}, allocator := context.allocator) -> (text: []u8, err: Error) {
	if m == nil { return nil, Model_Error{kind = .Bad_Option, want = {text = "model"}} }
	return schema_json_raw(&m.plan, m.judging, direction, wopts, allocator)
}

@(private)
schema_json_raw :: proc(plan: ^Type_Plan, judging: ^Applied, direction: Direction, wopts: jschema.Write_Options, allocator: runtime.Allocator) -> (text: []u8, err: Error) {
	if plan == nil || len(plan.nodes) == 0 { return nil, Model_Error{kind = .Bad_Option, want = {text = "model"}} }
	desc := describe(plan, direction, allocator, judging) or_return; defer rules.description_destroy(&desc)
	raw, serr := jschema.write_schema(&desc, wopts, allocator)
	if serr.kind != .None { jschema.error_destroy(&serr); return nil, Model_Error{kind = .Unsupported, want = {text = "schema"}} }
	if !plan.has_named_validators { return raw, nil }
	defer delete(raw, allocator)

	scratch_arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&scratch_arena, allocator, allocator); defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)
	tt: write.Token_Tape
	base_doc, pok := jschema.parse_json_to_tape(raw, &tt, scratch)
	if !pok { return nil, Model_Error{kind = .Walk, want = {text = "schema json"}} }
	defer write.token_tape_drop(&tt)
	annotated := annotate_schema_document_raw(plan, &base_doc, direction, scratch) or_return; defer tape.destroy(&annotated)
	out, werr := jschema.tape_to_json(&annotated, wopts, allocator, scratch)
	return out, werr if werr != nil else nil
}

@(private)
overlay_child_handle :: proc(ov: ^edit.Overlay, parent: edit.Handle, key: string) -> edit.Handle {
	h, base, ok := edit.lookup_member(ov, parent, key)
	if !ok { return edit.NO_HANDLE }
	if h != edit.NO_HANDLE { return h }
	if base == tape.NO_NODE { return edit.NO_HANDLE }
	nh, err := edit.handle_for_base(ov, base)
	return nh if err == nil else edit.NO_HANDLE
}

@(private)
schema_resolve_ref_handle :: proc(ov: ^edit.Overlay, root_h, h: edit.Handle, scratch: runtime.Allocator) -> edit.Handle {
	ref_h, ref_base, has_ref := edit.lookup_member(ov, h, "$ref")
	if !has_ref { return h }
	ref_str := ""
	ok := false
	if ref_h != edit.NO_HANDLE {
		if n, nok := edit.get_node(ov, ref_h); nok && n.state == .Replaced && n.val.kind == .String {
			cl, err := strings.clone(n.val.text, scratch); ref_str, ok = cl, err == nil
		}
	} else if ref_base != tape.NO_NODE && ov.base != nil && int(ref_base) < len(ov.base.nodes) && ov.base.nodes[ref_base].kind == .String {
		ref_str, ok = clone_token_text(ov.base, ov.base.nodes[ref_base], scratch)
	}
	if !ok || !strings.has_prefix(ref_str, "#/$defs/") { return h }
	dh := overlay_child_handle(ov, root_h, "$defs")
	if dh == edit.NO_HANDLE { return h }
	th := overlay_child_handle(ov, dh, ref_str[len("#/$defs/"):])
	return th if th != edit.NO_HANDLE else h
}

@(private)
overlay_set_validators :: proc(ov: ^edit.Overlay, obj_h: edit.Handle, refs: []Named_Validator_Ref, scratch: runtime.Allocator) -> Error {
	if len(refs) == 0 || obj_h == edit.NO_HANDLE { return nil }
	names := make([dynamic]string, 0, len(refs) + 2, scratch)
	push_u :: proc(names: ^[dynamic]string, s: string) -> runtime.Allocator_Error {
		for n in names { if n == s { return nil } }
		_, err := append(names, s); return err
	}
	if vh, vbase, found := edit.lookup_member(ov, obj_h, X_STURY_VALIDATORS_KEY); found {
		if vh != edit.NO_HANDLE {
			if n, ok := edit.get_node(ov, vh); ok && n.state == .Replaced && n.val.kind == .Array {
				for eh in n.elems {
					if en, eok := edit.get_node(ov, eh); eok && en.state == .Replaced && en.val.kind == .String {
						push_u(&names, strings.clone(en.val.text, scratch) or_return) or_return
					}
				}
			}
		} else if vbase != tape.NO_NODE && ov.base != nil && int(vbase) < len(ov.base.nodes) && ov.base.nodes[vbase].kind == .Array {
			elems, aok := extract_array(rules.Node_Ref{ov.base, vbase}, scratch)
			if !aok { return runtime.Allocator_Error.Out_Of_Memory }
			buf: [128]u8 = ---
			for elem in elems {
				if rules.value_kind(elem) != .String { continue }
				s, owned, sok := rules.value_string(elem, buf[:], scratch)
				if !sok { return runtime.Allocator_Error.Out_Of_Memory }
				defer if owned { delete(s, scratch) }
				push_u(&names, strings.clone(s, scratch) or_return) or_return
			}
		}
	}
	for ref in refs { push_u(&names, ref.name) or_return }
	elems := make([]edit.Handle, len(names), scratch) or_return
	for name, i in names {
		sh, serr := edit.new_node(ov, edit.val_string(name))
		if serr != nil { return runtime.Allocator_Error.Out_Of_Memory }
		elems[i] = sh
	}
	if _, merr := edit.set_member(ov, obj_h, X_STURY_VALIDATORS_KEY, edit.val_array(elems)); merr != nil {
		if aerr, is_oom := merr.(runtime.Allocator_Error); is_oom { return aerr }
		return Model_Error{kind = .Unsupported, want = {text = X_STURY_VALIDATORS_KEY}}
	}
	return nil
}

@(private)
annotate_schema_nodes :: proc(plan: ^Type_Plan, root_idx: i32, dir: Direction, ov: ^edit.Overlay, root_h: edit.Handle, scratch: runtime.Allocator) -> Error {
	Frame :: struct { kind: enum u8 { Enter, Leave_Node }, node_idx: i32, cur_h: edit.Handle }
	stack := make([dynamic]Frame, 0, 32, scratch) or_return
	active := make(map[i32]bool, 16, scratch) or_return
	append(&stack, Frame{kind = .Enter, node_idx = root_idx, cur_h = root_h}) or_return

	for visits := 0; len(stack) > 0; {
		fr := pop(&stack)
		if fr.kind == .Leave_Node { delete_key(&active, fr.node_idx); continue }
		visits += 1
		if visits > VALIDATOR_WALK_LIMIT { return Model_Error{kind = .Exceeded, want = {text = "validator schema annotate"}} }
		if fr.node_idx < 0 || fr.cur_h == edit.NO_HANDLE { continue }
		at, _ := unwrap_node(plan, fr.node_idx, false)
		if at < 0 { continue }
		tn := &plan.nodes[at]
		target_h := schema_resolve_ref_handle(ov, root_h, fr.cur_h, scratch)
		if len(tn.named_validators) > 0 { overlay_set_validators(ov, target_h, tn.named_validators, scratch) or_return }
		if active[at] { continue }
		map_insert(&active, at, true) or_return
		append(&stack, Frame{kind = .Leave_Node, node_idx = at}) or_return

		#partial switch tn.kind {
		case .Struct:
			ph := overlay_child_handle(ov, target_h, "properties")
			if ph == edit.NO_HANDLE { continue }
			si := &plan.structs[tn.struct_idx]
			for i := len(si.fields) - 1; i >= 0; i -= 1 {
				f := &si.fields[i]
				if (dir == .Dump && .Write_Only in f.flags) || (dir == .Load && .Read_Only in f.flags) { continue }
				field_obj := overlay_child_handle(ov, ph, f.name)
				if field_obj == edit.NO_HANDLE { continue }
				if len(f.named_validators) > 0 { overlay_set_validators(ov, field_obj, f.named_validators, scratch) or_return }
				append(&stack, Frame{kind = .Enter, node_idx = f.node, cur_h = field_obj}) or_return
			}
		case .Slice, .Dynamic, .Array, .Fixed_List, .Map:
			ch := overlay_child_handle(ov, target_h, "additionalProperties" if tn.kind == .Map else "items")
			if ch != edit.NO_HANDLE { append(&stack, Frame{kind = .Enter, node_idx = tn.child, cur_h = ch}) or_return }
		}
	}
	return nil
}

// ============================================================================
// Importing `"x-stury-validators"` from JSON Schema documents & validating
// ============================================================================

@(require_results)
extract_schema_validators :: proc(schema_doc: ^tape.Document, allocator := context.allocator) -> (sv: Schema_Validators, err: Error) {
	if schema_doc == nil || len(schema_doc.nodes) == 0 { return {}, Model_Error{kind = .Bad_Option, want = {text = "schema"}} }
	scratch_arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&scratch_arena, allocator, allocator); defer mem.dynamic_arena_destroy(&scratch_arena)
	out := make([dynamic]Validator_Binding, allocator)
	defer if err != nil { free_validator_bindings(out[:], allocator) }
	extract_schema_nodes(schema_doc, tape.ROOT, &out, allocator, mem.dynamic_arena_allocator(&scratch_arena)) or_return
	return {bindings = out[:], allocator = allocator}, nil
}

@(private)
doc_object_find :: proc(doc: ^tape.Document, obj_node: tape.Node_Index, want_key: string, scratch: runtime.Allocator) -> (tape.Node_Index, bool) {
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
		} else if kcl, ok2 := clone_token_text(doc, ktok, scratch); ok2 && kcl == want_key { return vn, true }
	}
	return tape.NO_NODE, false
}

@(private)
Doc_Child :: struct { node: tape.Node_Index, step: tape.Step }

@(private)
doc_collect_children :: proc(doc: ^tape.Document, parent: tape.Node_Index, out: ^[dynamic]Doc_Child, scratch: runtime.Allocator) -> runtime.Allocator_Error {
	clear(out)
	r := tape.Reader{doc = doc}
	ch, p, cerr := tape.children(r, parent, scratch)
	if cerr != nil { return cerr }
	defer tape.destroy_children(&ch)
	if p != .Found { return nil }
	is_obj := doc.nodes[parent].kind == .Object
	for idx := 0; ; idx += 1 {
		kn, vn, np := tape.next_child(r, &ch, .Last if is_obj else .Default)
		if np != .Found { break }
		st: tape.Step = tape.Index(idx)
		if is_obj {
			ktok := doc.nodes[kn] if kn != tape.NO_NODE else tape.cell_key(r, ch)
			kstr, kok := clone_token_text(doc, ktok, scratch)
			if !kok { return .Out_Of_Memory }
			st = tape.Name(kstr)
		}
		append(out, Doc_Child{node = vn, step = st}) or_return
	}
	return nil
}

@(private)
extract_schema_nodes :: proc(doc: ^tape.Document, root: tape.Node_Index, out: ^[dynamic]Validator_Binding, allocator, scratch: runtime.Allocator) -> Error {
	Frame :: struct { kind: enum u8 { Enter, Push_Step, Pop_Step, Leave_Node }, node: tape.Node_Index, step: string }
	bad_tag :: proc(steps: []string, want: string, a: runtime.Allocator) -> Error {
		ptr, _ := format_string_pointer(steps, a); wt, _ := strings.clone(want, a)
		return Model_Error{kind = .Bad_Tag, pointer = ptr, want = {text = wt}, owned = len(ptr) > 0 || len(wt) > 0}
	}

	stack := make([dynamic]Frame, 0, 32, scratch) or_return
	steps := make([dynamic]string, 0, 16, scratch) or_return
	active := make(map[tape.Node_Index]bool, 16, scratch) or_return
	props_buf := make([dynamic]Doc_Child, 0, 16, scratch) or_return
	append(&stack, Frame{kind = .Enter, node = root}) or_return

	for visits := 0; len(stack) > 0; {
		fr := pop(&stack)
		switch fr.kind {
		case .Pop_Step:   if len(steps) > 0 { pop(&steps) }
		case .Leave_Node: delete_key(&active, fr.node)
		case .Push_Step:
			append(&steps, fr.step) or_return
			append(&stack, Frame{kind = .Pop_Step}, Frame{kind = .Enter, node = fr.node}) or_return
		case .Enter:
			visits += 1
			if visits > VALIDATOR_WALK_LIMIT { return Model_Error{kind = .Exceeded, want = {text = "validator schema extract"}} }
			node := fr.node
			if node == tape.NO_NODE || int(node) >= len(doc.nodes) || doc.nodes[node].kind != .Object || active[node] { continue }
			map_insert(&active, node, true) or_return
			append(&stack, Frame{kind = .Leave_Node, node = node}) or_return

			if vnode, has_v := doc_object_find(doc, node, X_STURY_VALIDATORS_KEY, scratch); has_v {
				if doc.nodes[vnode].kind != .Array { return bad_tag(steps[:], X_STURY_VALIDATORS_KEY, allocator) }
				elems, aok := extract_array(rules.Node_Ref{doc, vnode}, scratch)
				if !aok { return runtime.Allocator_Error.Out_Of_Memory }
				refs := make([]Named_Validator_Ref, len(elems), scratch) or_return
				buf: [128]u8 = ---
				for elem, i in elems {
					if rules.value_kind(elem) != .String { return bad_tag(steps[:], X_STURY_VALIDATORS_KEY, allocator) }
					s, owned, sok := rules.value_string(elem, buf[:], scratch)
					if !sok { return runtime.Allocator_Error.Out_Of_Memory }
					defer if owned { delete(s, scratch) }
					if !valid_validator_name(s) { return bad_tag(steps[:], s, allocator) }
					refs[i] = {name = strings.clone(s, scratch) or_return}
				}
				if len(refs) > 0 { push_validator_binding(steps[:], refs, out, allocator) or_return }
			}

			if all_node, has_all := doc_object_find(doc, node, "allOf", scratch); has_all && doc.nodes[all_node].kind == .Array {
				elems, aok := extract_array(rules.Node_Ref{doc, all_node}, scratch)
				if !aok { return runtime.Allocator_Error.Out_Of_Memory }
				for i := len(elems) - 1; i >= 0; i -= 1 {
					if ref, is_ref := elems[i].(rules.Node_Ref); is_ref { append(&stack, Frame{kind = .Enter, node = ref.node}) or_return }
				}
			}
			for key in ([2]string{"additionalProperties", "items"}) {
				if sub, has := doc_object_find(doc, node, key, scratch); has && doc.nodes[sub].kind == .Object {
					append(&stack, Frame{kind = .Push_Step, node = sub, step = "*"}) or_return
				}
			}
			if props_node, has_props := doc_object_find(doc, node, "properties", scratch); has_props && doc.nodes[props_node].kind == .Object {
				doc_collect_children(doc, props_node, &props_buf, scratch) or_return
				for i := len(props_buf) - 1; i >= 0; i -= 1 {
					append(&stack, Frame{kind = .Push_Step, node = props_buf[i].node, step = string(props_buf[i].step.(tape.Name))}) or_return
				}
			}
			if ref_node, has_ref := doc_object_find(doc, node, "$ref", scratch); has_ref && doc.nodes[ref_node].kind == .String {
				if ref_text, rok := clone_token_text(doc, doc.nodes[ref_node], scratch); rok {
					if target, tok := resolve_local_def(doc, ref_text, scratch); tok { append(&stack, Frame{kind = .Enter, node = target}) or_return }
				}
			}
		}
	}
	return nil
}

@(private)
resolve_local_def :: proc(doc: ^tape.Document, ref: string, scratch: runtime.Allocator) -> (tape.Node_Index, bool) {
	key, name := "", ""
	if strings.has_prefix(ref, "#/$defs/") { key, name = "$defs", ref[len("#/$defs/"):] } else if strings.has_prefix(ref, "#/definitions/") { key, name = "definitions", ref[len("#/definitions/"):] } else { return tape.NO_NODE, false }
	defs, ok := doc_object_find(doc, tape.ROOT, key, scratch)
	if !ok { return tape.NO_NODE, false }
	return doc_object_find(doc, defs, name, scratch)
}

@(require_results)
register_schema_validators :: proc(reg: ^Registry, $T: typeid, schema_doc: ^tape.Document, tag := "json") -> Error {
	if reg == nil || schema_doc == nil || len(schema_doc.nodes) == 0 { return Model_Error{kind = .Bad_Option, want = {text = "schema"}} }
	alloc := reg.loads.allocator if reg.loads.allocator.procedure != nil else context.allocator
	sv := extract_schema_validators(schema_doc, alloc) or_return; defer schema_validators_destroy(&sv)
	scratch_arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&scratch_arena, alloc, alloc); defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)
	buf := make([dynamic]u8, 0, 32, scratch) or_return
	for b in sv.bindings {
		if len(b.validators) == 0 { continue }
		clear(&buf)
		for name, i in b.validators {
			if i > 0 { append(&buf, ',') or_return }
			append(&buf, ..transmute([]u8)string("validate=")) or_return
			append(&buf, ..transmute([]u8)name) or_return
		}
		rule_tag := string(buf[:])
		if len(b.pointer) == 0 {
			register_type(reg, Type_Rule{type = T, tag = rule_tag}) or_return
		} else if owner, field_name, matched := resolve_struct_field_path(type_info_of(T), b.pointer, tag, reg, scratch); matched {
			register_field(reg, Field_Rule_Of{type = owner, field = field_name, tag = rule_tag}) or_return
		}
	}
	return nil
}

@(private)
resolve_struct_field_path :: proc(ti: ^runtime.Type_Info, pointer, tag_key: string, reg: ^Registry, scratch: runtime.Allocator) -> (owner: typeid, odin_field: string, ok: bool) {
	if ti == nil || len(pointer) == 0 || pointer[0] != '/' { return nil, "", false }
	cur_ti, rest := ti, pointer[1:]
	for {
		slash := strings.index_byte(rest, '/')
		seg, is_last := rest[:slash] if slash >= 0 else rest, slash < 0
		for next := held_type(cur_ti); next != nil; next = held_type(cur_ti) { cur_ti = next }
		base := runtime.type_info_base(cur_ti)
		if seg == "*" {
			#partial switch v in base.variant {
			case ^runtime.Type_Info_Slice:                        cur_ti = v.elem
			case ^runtime.Type_Info_Dynamic_Array:                cur_ti = v.elem
			case ^runtime.Type_Info_Array:                        cur_ti = v.elem
			case ^runtime.Type_Info_Fixed_Capacity_Dynamic_Array: cur_ti = v.elem
			case ^runtime.Type_Info_Map:                          cur_ti = v.value
			case: return nil, "", false
			}
			if is_last { return nil, "", false }
			rest = rest[slash + 1:]; continue
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
			if ft.has_name { wire = ft.name } else if reg != nil && reg.naming.fields != .None {
				if rn, rerr := rename_text(fname, reg.naming.fields, scratch); rerr == nil { wire = rn }
			}
			if pointer_segment_equals(seg, wire) { found_idx = i; break }
		}
		if found_idx < 0 { return nil, "", false }
		if is_last { return cur_ti.id, st.names[found_idx], true }
		cur_ti, rest = st.types[found_idx], rest[slash + 1:]
	}
}

@(require_results)
validate_schema_validators :: proc(doc: ^tape.Document, sv: ^Schema_Validators, vr: ^Validator_Registry, sink: ^Sink = nil, allocator := context.allocator) -> Error {
	if doc == nil || len(doc.nodes) == 0 || sv == nil { return Model_Error{kind = .Bad_Option, want = {text = "document"}} }
	if len(sv.bindings) == 0 { return nil }
	scratch_arena: mem.Dynamic_Arena; mem.dynamic_arena_init(&scratch_arena, allocator, allocator); defer mem.dynamic_arena_destroy(&scratch_arena)
	scratch := mem.dynamic_arena_allocator(&scratch_arena)
	from := len(sink.entries) if sink != nil else 0
	first: Model_Error; oom := false; rep: Report; report_init(&rep, scratch); defer report_destroy(&rep)
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

@(private)
run_binding_on_doc :: proc(
	doc: ^tape.Document, root: tape.Node_Index, root_pattern: string, validators: []string, vr: ^Validator_Registry,
	steps: ^[dynamic]tape.Step, rep: ^Report, sink: ^Sink, first: ^Model_Error, oom: ^bool, allocator, scratch: runtime.Allocator,
) {
	Frame :: struct { kind: enum u8 { Enter, Push_Step, Pop_Step }, node: tape.Node_Index, pattern: string, step: tape.Step }
	stack, serr := make([dynamic]Frame, 0, 32, scratch)
	children_buf, cerr := make([dynamic]Doc_Child, 0, 16, scratch)
	if serr != nil || cerr != nil || !push_oom(oom, &stack, Frame{kind = .Enter, node = root, pattern = root_pattern}) { oom^ = true; return }

	for len(stack) > 0 && !oom^ && !(sink == nil && first.kind != .None) {
		fr := pop(&stack)
		switch fr.kind {
		case .Pop_Step: if len(steps^) > 0 { pop(steps) }
		case .Push_Step:
			if !push_oom(oom, steps, fr.step) || !push_oom(oom, &stack, Frame{kind = .Pop_Step}) || !push_oom(oom, &stack, Frame{kind = .Enter, node = fr.node, pattern = fr.pattern}) { return }
		case .Enter:
			node, pattern := fr.node, fr.pattern
			if node == tape.NO_NODE || int(node) >= len(doc.nodes) { continue }
			if len(pattern) == 0 {
				val, at := rules.Value(rules.Node_Ref{doc, node}), doc.nodes[node].lo
				for vname in validators {
					nv, found := lookup_named_validator(vr, vname)
					if !found {
						_ = record_failure(sink, first, oom, allocator, .Missing_Validator, at, steps^[:], "", {text = vname})
						if oom^ || sink == nil { return }
						continue
					}
					report_reset(rep)
					if nv.vfn != nil { nv.vfn(val, rep, nv.data) } else if nv.fn != nil { nv.fn(any{&val, typeid_of(rules.Value)}, rep, nv.data) }
					if (rep.failed || rep.oom) && !emit_report(rep, steps^[:], at, nil, sink, first, oom, allocator, scratch) { return }
				}
				continue
			}
			if pattern[0] != '/' { continue }
			rest := pattern[1:]
			slash := strings.index_byte(rest, '/')
			seg, next_pat := rest[:slash] if slash >= 0 else rest, rest[slash:] if slash >= 0 else ""
			nk := doc.nodes[node].kind
			if nk != .Object && nk != .Array { continue }
			if doc_collect_children(doc, node, &children_buf, scratch) != nil { oom^ = true; return }
			if seg == "*" {
				for i := len(children_buf) - 1; i >= 0; i -= 1 {
					if !push_oom(oom, &stack, Frame{kind = .Push_Step, node = children_buf[i].node, pattern = next_pat, step = children_buf[i].step}) { return }
				}
			} else if nk == .Object {
				for c in children_buf {
					if pointer_segment_equals(seg, string(c.step.(tape.Name))) {
						if !push_oom(oom, &stack, Frame{kind = .Push_Step, node = c.node, pattern = next_pat, step = c.step}) { return }
						break
					}
				}
			} else if want_idx, iok := strconv.parse_int(seg); iok && want_idx >= 0 && want_idx < len(children_buf) {
				if !push_oom(oom, &stack, Frame{kind = .Push_Step, node = children_buf[want_idx].node, pattern = next_pat, step = children_buf[want_idx].step}) { return }
			}
		}
	}
}
