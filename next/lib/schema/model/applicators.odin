// JSON Schema applicator fragments, `unique` item checking, and `.One_Match` union verification
// compiled onto v2 `check.Plan` and evaluated directly via `check.check_document` (zero JSON serialize-reparse!).
package model

import "base:runtime"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

@(private)
Schema_Of :: struct {
	type:     typeid,
	fragment: rules.Description,
}

@(private)
init_desc :: proc(d: ^rules.Description, alloc: runtime.Allocator) -> runtime.Allocator_Error {
	d.allocator, d.nodes.allocator, d.arrays.allocator, d.objects.allocator = alloc, alloc, alloc, alloc
	d.texts.allocator, d.anchors.allocator, d.bases.allocator = alloc, alloc, alloc
	d.names = make(map[rules.Node_Index]string, 4, alloc) or_return
	return nil
}

// Registers a `rules.Description` fragment on type `T` (deep-copied into the registry's arena).
register_schema :: proc(reg: ^Registry, T: typeid, fragment: ^rules.Description) -> runtime.Allocator_Error {
	if fragment == nil { return .Invalid_Argument }
	x := Schema_Of{type = T}
	init_desc(&x.fragment, reg_arena(reg)) or_return
	graft(&x.fragment, fragment, true) or_return
	_, err := append(&reg.schemas, x)
	return err
}

// Iterative deep copy of a `rules.Value` into `arena`, resolving any `Node_Ref` so it never dangles.
@(private)
clone_rules_value :: proc(v: rules.Value, arena, scratch: runtime.Allocator) -> (res: rules.Value, err: runtime.Allocator_Error) {
	Frame :: struct { src: rules.Value, dst: ^rules.Value }
	stack := make([dynamic]Frame, 0, 16, scratch) or_return
	defer delete(stack)
	append(&stack, Frame{v, &res}) or_return

	buf: [128]u8 = ---
	for len(stack) > 0 {
		f := pop(&stack)
		switch x in f.src {
		case rules.Null:        f.dst^ = x
		case bool:              f.dst^ = x
		case i64:               f.dst^ = x
		case u64:               f.dst^ = x
		case f64:               f.dst^ = x
		case rules.Number_Text: f.dst^ = rules.Number_Text{strings.clone(x.text, arena) or_return}
		case string:            f.dst^ = strings.clone(x, arena) or_return
		case []rules.Value:
			out := make([]rules.Value, len(x), arena) or_return
			f.dst^ = out
			for i := len(x) - 1; i >= 0; i -= 1 { append(&stack, Frame{x[i], &out[i]}) or_return }
		case []rules.Member_Value:
			out := make([]rules.Member_Value, len(x), arena) or_return
			f.dst^ = out
			for i := len(x) - 1; i >= 0; i -= 1 {
				out[i].key = strings.clone(x[i].key, arena) or_return
				append(&stack, Frame{x[i].value, &out[i].value}) or_return
			}
		case rules.Node_Ref:
			if x.doc == nil || int(x.node) >= len(x.doc.nodes) { f.dst^ = rules.Null{}; continue }
			switch rules.value_kind(x) {
			case .Null:  f.dst^ = rules.Null{}
			case .False: f.dst^ = false
			case .True:  f.dst^ = true
			case .String:
				s, owned, ok := rules.value_string(x, buf[:], scratch)
				defer if owned { delete(s, scratch) }
				if !ok { return nil, .Out_Of_Memory }
				f.dst^ = strings.clone(s, arena) or_return
			case .Number:
				s, owned, ok := rules.value_number_text(x, buf[:], scratch)
				defer if owned { delete(s, scratch) }
				f.dst^ = rules.Number_Text{strings.clone(s, arena) or_return} if ok else rules.Null{}
			case .Array:
				elems, aok := extract_array(x, scratch)
				if !aok { return nil, .Out_Of_Memory }
				out := make([]rules.Value, len(elems), arena) or_return
				f.dst^ = out
				for i := len(elems) - 1; i >= 0; i -= 1 { append(&stack, Frame{elems[i], &out[i]}) or_return }
			case .Object:
				r := tape.Reader{doc = x.doc}
				ch, p, cerr := tape.children(r, x.node, scratch)
				if cerr != nil { return nil, cerr }
				defer tape.destroy_children(&ch)
				if p != .Found { f.dst^ = rules.Null{}; continue }
				list := make([dynamic]rules.Member_Value, arena)
				for {
					kn, vn, np := tape.next_child(r, &ch, .Last)
					if np != .Found { break }
					ktok := x.doc.nodes[kn] if kn != tape.NO_NODE else tape.cell_key(r, ch)
					ks, kowned, kok := doc_key_text(x.doc, ktok, buf[:], scratch)
					if !kok { return nil, .Out_Of_Memory }
					kc := strings.clone(ks, arena) or_return
					if kowned { delete(ks, scratch) }
					append(&list, rules.Member_Value{kc, rules.Node_Ref{x.doc, vn}}) or_return
				}
				out := list[:]
				f.dst^ = out
				for i := len(out) - 1; i >= 0; i -= 1 { append(&stack, Frame{out[i].value, &out[i].value}) or_return }
			}
		case nil:
			f.dst^ = rules.Null{}
		}
	}
	return res, nil
}

@(private)
graft :: proc(into, from: ^rules.Description, own: bool) -> (root: rules.Node_Index, err: runtime.Allocator_Error) {
	a := into.allocator
	nb, ab, ob := rules.Node_Index(len(into.nodes)), i32(len(into.arrays)), i32(len(into.objects))
	at :: proc(i, by: rules.Node_Index) -> rules.Node_Index { return i if i == rules.NONE else i + by }
	mat :: proc(i: Maybe(rules.Node_Index), by: rules.Node_Index) -> Maybe(rules.Node_Index) { x, has := i.?; return x + by if has else nil }
	lat :: proc(xs: []rules.Node_Index, by: rules.Node_Index, a: runtime.Allocator) -> (out: []rules.Node_Index, err: runtime.Allocator_Error) {
		if len(xs) == 0 { return nil, nil }
		out = make([]rules.Node_Index, len(xs), a) or_return
		for x, i in xs { out[i] = at(x, by) }
		return out, nil
	}
	tcopy :: proc(s: string, own: bool, a: runtime.Allocator) -> (string, runtime.Allocator_Error) {
		return strings.clone(s, a) if own && len(s) > 0 else s, nil
	}
	rcopy :: proc(r: rules.Rules, own: bool, a: runtime.Allocator) -> (out: rules.Rules, err: runtime.Allocator_Error) {
		out = r
		out.minimum = tcopy(r.minimum, own, a) or_return
		out.maximum = tcopy(r.maximum, own, a) or_return
		out.multiple_of = tcopy(r.multiple_of, own, a) or_return
		out.pattern = tcopy(r.pattern, own, a) or_return
		out.format = tcopy(r.format, own, a) or_return
		return out, nil
	}
	vcopy :: proc(xs: []rules.Value, own: bool, a: runtime.Allocator) -> (out: []rules.Value, err: runtime.Allocator_Error) {
		if len(xs) == 0 { return nil, nil }
		out = make([]rules.Value, len(xs), a) or_return
		for x, i in xs { out[i] = clone_rules_value(x, a, a) or_return if own else x }
		return out, nil
	}

	for n in from.nodes {
		x := n
		x.array, x.object = n.array + ab if n.array >= 0 else -1, n.object + ob if n.object >= 0 else -1
		x.any_of, x.all_of, x.one_of = lat(n.any_of, nb, a) or_return, lat(n.all_of, nb, a) or_return, lat(n.one_of, nb, a) or_return
		x.enum_of, x.examples = vcopy(n.enum_of, own, a) or_return, vcopy(n.examples, own, a) or_return
		x.not, x.ref, x.dynamic_ref = mat(n.not, nb), mat(n.ref, nb), mat(n.dynamic_ref, nb)
		x.cond = {mat(n.cond.test, nb), mat(n.cond.then, nb), mat(n.cond.other, nb)}
		x.unevaluated_items, x.unevaluated_properties, x.resource = mat(n.unevaluated_items, nb), mat(n.unevaluated_properties, nb), at(n.resource, nb)
		x.rules = rcopy(n.rules, own, a) or_return
		x.description, x.title = tcopy(n.description, own, a) or_return, tcopy(n.title, own, a) or_return
		x.content_encoding, x.content_media_type = tcopy(n.content_encoding, own, a) or_return, tcopy(n.content_media_type, own, a) or_return
		if c, has := n.const_of.?; has && own { x.const_of = clone_rules_value(c, a, a) or_return }
		if d, has := n.default_of.?; has && own { x.default_of = clone_rules_value(d, a, a) or_return }
		append(&into.nodes, x) or_return
	}
	for arr in from.arrays {
		x := arr
		x.prefix, x.items, x.contains = lat(arr.prefix, nb, a) or_return, at(arr.items, nb), mat(arr.contains, nb)
		append(&into.arrays, x) or_return
	}
	for o in from.objects {
		x := rules.Object{additional = at(o.additional, nb), keys = at(o.keys, nb)}
		if len(o.members) > 0 {
			x.members = make([]rules.Member, len(o.members), a) or_return
			for m, i in o.members {
				x.members[i] = m
				x.members[i].name = tcopy(m.name, own, a) or_return
				x.members[i].node = at(m.node, nb)
				x.members[i].rules = rcopy(m.rules, own, a) or_return
			}
		}
		if len(o.patterns) > 0 {
			x.patterns = make([]rules.Pattern, len(o.patterns), a) or_return
			for p, i in o.patterns { x.patterns[i] = {tcopy(p.expression, own, a) or_return, at(p.node, nb)} }
		}
		if len(o.dependents) > 0 {
			x.dependents = make([]rules.Dependent, len(o.dependents), a) or_return
			for dep, i in o.dependents {
				reqs: []string
				if len(dep.required) > 0 {
					reqs = make([]string, len(dep.required), a) or_return
					for req, k in dep.required { reqs[k] = tcopy(req, own, a) or_return }
				}
				x.dependents[i] = {tcopy(dep.name, own, a) or_return, reqs, mat(dep.node, nb)}
			}
		}
		append(&into.objects, x) or_return
	}
	for anc in from.anchors { append(&into.anchors, rules.Anchor{tcopy(anc.name, own, a) or_return, at(anc.resource, nb), at(anc.node, nb)}) or_return }
	if into.names == nil { into.names = make(map[rules.Node_Index]string, 4, a) or_return }
	for k, v in from.names { map_insert(&into.names, at(k, nb), tcopy(v, own, a) or_return) or_return }
	return at(from.root, nb), nil
}

@(private)
Applied :: struct {
	schemas:    []Schema_Of,
	unions:     []typeid,
	judged:     [dynamic]^Judged,
	kept:       mem.Dynamic_Arena,
	kept_ready: bool,
	allocator:  runtime.Allocator,
}

@(private)
Judged :: struct { type: typeid, unique: bool, plan: check.Plan }

@(private)
Judged_Key :: struct { type: typeid, unique: bool }

@(private)
judging_of :: proc(reg: ^Registry, plan: ^Type_Plan, allocator, scratch: runtime.Allocator) -> (j: ^Applied, err: Error) {
	unions_dyn := make([dynamic]typeid, scratch)
	if reg != nil {
		for u in reg.unions { if u.mode == .One_Match { append(&unions_dyn, u.type) or_return } }
	}
	probe := Applied{schemas = reg.schemas[:] if reg != nil else nil, unions = unions_dyn[:]}
	keys := judged_keys(&probe, plan, scratch) or_return
	if len(keys) == 0 { return nil, nil }

	j = new(Applied, allocator) or_return
	j.allocator, j.judged.allocator, j.kept_ready = allocator, allocator, true
	mem.dynamic_arena_init(&j.kept, allocator, allocator)
	kept_alloc := mem.dynamic_arena_allocator(&j.kept)
	defer if err != nil { judging_destroy(j); j = nil }

	if len(unions_dyn) > 0 { j.unions = slice.clone(unions_dyn[:], allocator) or_return }
	if reg != nil && len(reg.schemas) > 0 {
		j.schemas = make([]Schema_Of, len(reg.schemas), allocator) or_return
		for &x, i in reg.schemas {
			j.schemas[i].type = x.type
			init_desc(&j.schemas[i].fragment, kept_alloc) or_return
			graft(&j.schemas[i].fragment, &x.fragment, true) or_return
		}
	}
	for k in keys {
		if perr := pattern_beside_extra(j, plan, k.type, scratch); perr.kind != .None { return j, perr }
		x := new(Judged, allocator) or_return
		append(&j.judged, x) or_return
		x.type, x.unique = k.type, k.unique
		d: rules.Description
		init_desc(&d, scratch) or_return
		build_judged_description(j, plan, k, &d, scratch) or_return
		cp, cerr := check.compile(&d, allocator)
		if cerr.kind != .None { return j, Model_Error{kind = map_rules_kind(cerr.kind), want = {k.type, cerr.keyword}} }
		x.plan = cp
	}
	for &tn in plan.nodes {
		if tn.type != nil { tn.judged = judged_of(j, tn.type, tn.has_unique) != nil || judged_of(j, tn.type, false) != nil }
	}
	return j, nil
}

@(private)
pattern_beside_extra :: proc(j: ^Applied, plan: ^Type_Plan, type: typeid, scratch: runtime.Allocator) -> Model_Error {
	si := find_struct_info(plan, type)
	if si == nil || si.capture_idx < 0 || plan.nodes[plan.nodes[si.capture_node].child].kind == .Value { return {} }
	for &x in j.schemas {
		if x.type != type { continue }
		ways, _ := rules.branches(&x.fragment, {x.fragment.root}, false, 64, scratch, scratch)
		for way in ways {
			for i in way {
				if o := x.fragment.nodes[i].object; o >= 0 && len(x.fragment.objects[o].patterns) > 0 {
					return {kind = .Unsupported, want = {type, "patternProperties"}}
				}
			}
		}
	}
	return {}
}

@(private)
judged_keys :: proc(j: ^Applied, plan: ^Type_Plan, scratch: runtime.Allocator) -> (res: []Judged_Key, err: runtime.Allocator_Error) {
	keys := make([dynamic]Judged_Key, scratch)
	add :: proc(keys: ^[dynamic]Judged_Key, k: Judged_Key) -> runtime.Allocator_Error {
		if !slice.contains(keys[:], k) { append(keys, k) or_return }
		return nil
	}
	for &tn in plan.nodes {
		if tn.type == nil { continue }
		if tn.has_unique && tn.kind != .Maybe && tn.kind != .Ptr { add(&keys, {tn.type, true}) or_return }
		if judges(j, tn.type) {
			add(&keys, {tn.type, tn.has_unique}) or_return
			if tn.has_unique { add(&keys, {tn.type, false}) or_return }
		}
	}
	for &si in plan.structs {
		for &f in si.fields {
			if f.has_unique {
				unwrapped, _ := unwrap_node(plan, f.node, f.not_null)
				if ut := plan.nodes[unwrapped].type; ut != nil { add(&keys, {ut, true}) or_return }
			}
		}
	}
	return keys[:], nil
}

@(private)
judges :: proc(j: ^Applied, type: typeid) -> bool {
	if j == nil { return false }
	for x in j.schemas { if x.type == type { return true } }
	return one_match(j, type)
}

@(private)
one_match :: proc(j: ^Applied, type: typeid) -> bool { return j != nil && slice.contains(j.unions, type) }

@(private)
build_judged_description :: proc(j: ^Applied, plan: ^Type_Plan, k: Judged_Key, d: ^rules.Description, scratch: runtime.Allocator) -> Error {
	root := rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1}
	root.rules.unique = k.unique
	append(&d.nodes, root) or_return

	if one_match(j, k.type) {
		for &tn in plan.nodes {
			if tn.type == k.type && tn.kind == .Union {
				u := &plan.unions[tn.union_idx]
				sub := Reading{
					plan = plan, d = d, direction = .Load, allocator = d.allocator, scratch = scratch,
					nodes = make(map[Desc_Use]rules.Node_Index, 16, scratch) or_return,
					shapes = make(map[i32]i32, 16, scratch) or_return,
				}
				arms := desc_arms_of(&sub, u, !u.no_nil)
				if sub.failed { return runtime.Allocator_Error.Out_Of_Memory }
				root.one_of = arms
				break
			}
		}
	}
	frags := fragments_of(j, d, k.type) or_return
	if len(frags) > 0 && (len(root.one_of) == 0 || len(d.nodes[frags[0]].one_of) == 0) {
		first := d.nodes[frags[0]]
		first.rules.unique ||= root.rules.unique
		first.any_of = slice.clone(first.any_of, d.allocator) or_return
		first.enum_of = slice.clone(first.enum_of, d.allocator) or_return
		first.examples = slice.clone(first.examples, d.allocator) or_return
		first.one_of = root.one_of if len(root.one_of) > 0 else (slice.clone(first.one_of, d.allocator) or_return)
		if len(first.all_of) > 0 || len(frags) > 1 {
			all_of := make([]rules.Node_Index, len(first.all_of) + len(frags) - 1, d.allocator) or_return
			copy(all_of, first.all_of); copy(all_of[len(first.all_of):], frags[1:])
			first.all_of = all_of
		} else { first.all_of = nil }
		root = first
	} else {
		root.all_of = frags
	}
	d.nodes[0] = root
	return nil
}

@(private)
fragments_of :: proc(j: ^Applied, d: ^rules.Description, type: typeid) -> (roots: []rules.Node_Index, err: runtime.Allocator_Error) {
	if j == nil { return nil, nil }
	count := 0
	for x in j.schemas { if x.type == type { count += 1 } }
	if count == 0 { return nil, nil }
	roots = make([]rules.Node_Index, count, d.allocator) or_return
	idx := 0
	for &x in j.schemas {
		if x.type == type { roots[idx] = graft(d, &x.fragment, false) or_return; idx += 1 }
	}
	return roots, nil
}

@(private)
judged_of :: proc(j: ^Applied, type: typeid, unique: bool) -> ^Judged {
	if j == nil { return nil }
	for x in j.judged { if x.type == type && x.unique == unique { return x } }
	return nil
}

@(private)
judging_destroy :: proc(j: ^Applied) {
	if j == nil { return }
	a := j.allocator
	for x in j.judged { check.plan_destroy(&x.plan); free(x, a) }
	delete(j.judged); delete(j.schemas, a); delete(j.unions, a)
	if j.kept_ready { mem.dynamic_arena_destroy(&j.kept) }
	free(j, a)
}

@(private)
run_judged_on_doc :: proc(j: ^Judged, doc: ^tape.Document, node: tape.Node_Index, dups: tape.Duplicates, budget: tape.Budget, prefix_steps: []tape.Step, sink: ^Sink, first: ^Model_Error, oom: ^bool, exceeded: ^tape.Exceeded, allocator, scratch: runtime.Allocator, silent := false) -> bool {
	if j == nil || doc == nil || int(node) >= len(doc.nodes) { return true }
	sub_doc: tape.Document
	tt: write.Token_Tape
	used_tape := false
	defer if used_tape { write.token_tape_drop(&tt) }

	if node == 0 {
		sub_doc = doc^
	} else if len(doc.counts) == 0 && doc.ext == nil && len(doc.facts) == 0 {
		n := doc.nodes[node]
		sub_doc = doc^
		sub_doc.nodes = doc.nodes[node : node + tape.Node_Index(u32(1) if n.kind <= .Plain else n.n)]
	} else {
		if write.token_tape_start(&tt, false, 0, scratch) != nil { oom^ = true; return false }
		used_tape = true
		if write.tokens_of(doc, node, &tt, write.token_tape_take, scratch) != nil { oom^ = true; return false }
		td, terr := write.token_tape_document(&tt)
		if terr != nil { oom^ = true; return false }
		sub_doc = td
	}
	return run_judged_on_subdoc(j, &sub_doc, dups, budget, prefix_steps, sink, first, oom, exceeded, allocator, scratch, silent)
}

@(private)
run_judged_on_value :: proc(j: ^Judged, v: rules.Value, dups: tape.Duplicates, budget: tape.Budget, prefix_steps: []tape.Step, sink: ^Sink, first: ^Model_Error, oom: ^bool, exceeded: ^tape.Exceeded, allocator, scratch: runtime.Allocator, silent := false) -> bool {
	if j == nil { return true }
	if ref, is_ref := v.(rules.Node_Ref); is_ref && ref.doc != nil {
		return run_judged_on_doc(j, ref.doc, ref.node, dups, budget, prefix_steps, sink, first, oom, exceeded, allocator, scratch, silent)
	}
	tt: write.Token_Tape
	if write.token_tape_start(&tt, false, 0, scratch) != nil { oom^ = true; return false }
	defer write.token_tape_drop(&tt)
	if eerr := emit_rules_value_tokens(&tt, v, scratch); eerr != nil {
		if me, is_me := eerr.(Model_Error); is_me {
			return record_failure(sink, first, oom, allocator, me.kind, 0, prefix_steps, "", me.want, silent)
		}
		oom^ = true
		return false
	}
	sub_doc, terr := write.token_tape_document(&tt)
	if terr != nil { oom^ = true; return false }
	return run_judged_on_subdoc(j, &sub_doc, dups, budget, prefix_steps, sink, first, oom, exceeded, allocator, scratch, silent)
}

@(private)
run_judged_on_subdoc :: proc(j: ^Judged, sub_doc: ^tape.Document, dups: tape.Duplicates, budget: tape.Budget, prefix_steps: []tape.Step, sink: ^Sink, first: ^Model_Error, oom: ^bool, exceeded: ^tape.Exceeded, allocator, scratch: runtime.Allocator, silent := false) -> bool {
	chk_sink: check.Sink
	if sink != nil && !silent { check.sink_init(&chk_sink, scratch) }
	defer check.sink_destroy(&chk_sink)

	res := check.check_document(sub_doc, &j.plan, {dups = dups, budget = budget, scratch = scratch}, &chk_sink if (sink != nil && !silent) else nil, scratch)
	defer check.result_destroy(&res)
	if res.valid { return true }
	if res.walk_err != nil {
		if exc, is_exc := res.walk_err.(tape.Exceeded); is_exc { if exceeded != nil { exceeded^ = exc }; return false }
		if _, is_oom := res.walk_err.(runtime.Allocator_Error); is_oom { oom^ = true; return false }
	}
	if res.err.kind == .No_Memory || chk_sink.oom { oom^ = true; return false }
	if res.err.kind == .Exceeded { if exceeded != nil { exceeded^ = {at = res.err.at, kind = .Steps} }; return false }

	steps, serr := make([dynamic]tape.Step, 0, len(prefix_steps) + 4, scratch)
	if serr != nil { oom^ = true; return false }
	defer delete(steps)

	if sink == nil || silent || len(chk_sink.entries) == 0 {
		k := map_rules_kind(res.err.kind)
		if k == .None { k = .Wrong_Kind }
		if _, aerr := append(&steps, ..prefix_steps); aerr != nil { oom^ = true; return false }
		if _, aerr := append(&steps, ..res.err.path); aerr != nil { oom^ = true; return false }
		return record_failure(sink, first, oom, allocator, k, res.err.at, steps[:], res.err.expected, {text = res.err.keyword}, silent)
	}
	for e in chk_sink.entries {
		k := map_rules_kind(e.kind)
		if k == .None { k = .Wrong_Kind }
		clear(&steps)
		if _, aerr := append(&steps, ..prefix_steps); aerr != nil { oom^ = true; return false }
		if _, aerr := append(&steps, ..e.path); aerr != nil { oom^ = true; return false }
		if !record_failure(sink, first, oom, allocator, k, e.at, steps[:], e.expected, {text = e.keyword}, false) { return false }
	}
	return true
}

@(private)
emit_rules_value_tokens :: proc(tt: ^write.Token_Tape, v: rules.Value, scratch: runtime.Allocator) -> Error {
	Frame :: struct { kind: enum u8 { Val, Key, Close }, val: rules.Value, key: string }
	stack, serr := make([dynamic]Frame, 0, 16, scratch)
	if serr != nil { return serr }
	defer delete(stack)
	if _, aerr := append(&stack, Frame{kind = .Val, val = v}); aerr != nil { return aerr }

	take :: #force_inline proc(tt: ^write.Token_Tape, k: write.Token_Kind, t: string) -> Error {
		werr := write.token_tape_take(tt, k, t)
		return werr if werr != nil else nil
	}
	buf: [128]u8 = ---
	for len(stack) > 0 {
		f := pop(&stack)
		switch f.kind {
		case .Key:   take(tt, .Key, f.key) or_return; continue
		case .Close: take(tt, .Close, "") or_return; continue
		case .Val:
		}
		switch x in f.val {
		case rules.Null: take(tt, .Null, "") or_return
		case bool:       take(tt, .True if x else .False, "") or_return
		case i64, u64, f64, rules.Number_Text:
			if fv, is_f64 := x.(f64); is_f64 && (math.is_nan(fv) || math.is_inf(fv, 0)) { return Model_Error{kind = .Non_Finite} }
			s, owned, ok := rules.value_number_text(f.val, buf[:], scratch)
			defer if owned { delete(s, scratch) }
			if !ok { return Model_Error{kind = .Non_Finite} }
			take(tt, .Number, s) or_return
		case string: take(tt, .String, x) or_return
		case []rules.Value:
			take(tt, .Array, "") or_return
			if _, aerr := append(&stack, Frame{kind = .Close}); aerr != nil { return aerr }
			for i := len(x) - 1; i >= 0; i -= 1 {
				if _, aerr := append(&stack, Frame{kind = .Val, val = x[i]}); aerr != nil { return aerr }
			}
		case []rules.Member_Value:
			take(tt, .Object, "") or_return
			if _, aerr := append(&stack, Frame{kind = .Close}); aerr != nil { return aerr }
			for i := len(x) - 1; i >= 0; i -= 1 {
				if _, aerr := append(&stack, Frame{kind = .Val, val = x[i].value}); aerr != nil { return aerr }
				if _, aerr := append(&stack, Frame{kind = .Key, key = x[i].key}); aerr != nil { return aerr }
			}
		case rules.Node_Ref:
			if x.doc == nil || int(x.node) >= len(x.doc.nodes) { take(tt, .Null, "") or_return } else if werr := write.tokens_of(x.doc, x.node, tt, write.token_tape_take, scratch); werr != nil { return werr }
		case nil: take(tt, .Null, "") or_return
		}
	}
	return nil
}
