// Iterative native `load`, `load_document`, and `load_value` (ZERO serialize-reparse, O(1) native stack!).
// Supports XML attributes/`#text`/`.Group`, DSV `infer=false`/`infer=true`/`no_header`, CBOR Tag 1/bytes,
// TOML 1.1 omitted seconds, >128-field structs, full `Budget` enforcement, and transactional rollback on error.
package model

import "base:runtime"
import "core:encoding/uuid"
import "core:math"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:time"
import "stury:lib/base/regex"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"
import "stury:lib/schema/rules"

Load_Opts :: struct { dups: tape.Duplicates, budget: tape.Budget, scratch: runtime.Allocator, validators: ^Validator_Registry }

@(private)
resolve_dups :: proc "contextless" (dups: tape.Duplicates, format: ^tape.Format) -> (tape.Duplicates, bool) {
	switch dups {
	case .Default:                       return (.Group if format != nil && format.dups == .Group else .Refuse), true
	case .Refuse, .First, .Last, .Group: return dups, true
	case .All:                           return .Default, false
	}
	return .Default, false
}

@(private)
Scratch_Scope :: struct { rb: hook.Read_Budget, local_mb: hook.Memory_Budget, arena: mem.Dynamic_Arena, has_arena: bool, out, scratch: runtime.Allocator }

@(private)
scratch_begin :: proc(sc: ^Scratch_Scope, opts: Load_Opts, allocator: runtime.Allocator) {
	if opts.scratch.procedure == mem.arena_allocator_proc && opts.budget.memory == 0 { sc.out, sc.scratch = allocator, opts.scratch; return }
	t_opts := tape.Options{budget = opts.budget, scratch = opts.scratch}
	sc.out = hook.read_budget(&sc.rb, t_opts, allocator)
	scr_backing := hook.scratch(t_opts, sc.out, &sc.local_mb)
	block_sz := 64 * 1024
	if opts.budget.memory > 0 && opts.budget.memory < u64(block_sz) { block_sz = max(int(opts.budget.memory / 2), 256) }
	mem.dynamic_arena_init(&sc.arena, scr_backing, scr_backing, block_size = block_sz)
	sc.has_arena, sc.scratch = true, mem.dynamic_arena_allocator(&sc.arena)
}

@(private)
scratch_end :: proc(sc: ^Scratch_Scope) { if sc.has_arena { mem.dynamic_arena_destroy(&sc.arena) } }
@(private)
oob_oom_error :: proc "contextless" (refused: bool) -> Error { return tape.Error(tape.Exceeded{at = tape.NO_BYTE, kind = .Memory}) if refused else runtime.Allocator_Error.Out_Of_Memory }
@(private)
scratch_oom_error :: proc "contextless" (sc: ^Scratch_Scope) -> Error { return oob_oom_error(sc.rb.main.refused || sc.rb.scratch.refused || sc.local_mb.refused) }

@(private)
map_build_fault :: proc(berr: tape.Error, sink: ^Sink, allocator: runtime.Allocator) -> Error {
	if f, is_fault := berr.(tape.Fault); is_fault && f.kind == .Duplicate_Key {
		if sink != nil { _ = sink_push(sink, allocator, .Duplicate_Key, f.at, nil) }
		return Model_Error{kind = .Duplicate_Key, at = f.at}
	}
	return berr
}

@(private)
push_oom :: #force_inline proc(oom: ^bool, s: ^[dynamic]$T, x: T) -> bool { if _, err := append(s, x); err != nil { oom^ = true; return false }; return true }

@(require_results)
load :: proc(m: ^Model($T), src: []u8, format: ^tape.Format, reads: ^tape.Reads, out: ^T, sink: ^Sink = nil, opts := Load_Opts{}, format_opts: tape.Format_Options = nil, allocator := context.allocator) -> Error {
	if format == nil || reads == nil || reads.build == nil || out == nil { return Model_Error{kind = .Bad_Option, want = {text = "format"}} }
	policy, ok := resolve_dups(opts.dups, format); if !ok { return Model_Error{kind = .Bad_Option, want = {text = "dups"}} }
	sc: Scratch_Scope; sp := (^Scratch_Scope)(rawptr(&sc)); scratch_begin(sp, opts, allocator); defer scratch_end(sp)
	doc, berr := reads.build(format, src, {budget = opts.budget, dups = policy, format = format_opts, scratch = sp.scratch}, sp.scratch)
	if berr != nil { return map_build_fault(berr, sink, allocator) }
	defer tape.destroy(&doc)
	if len(doc.nodes) == 0 { return Model_Error{kind = .Bad_Option, want = {text = "document"}} }
	if doc.partial != nil { return Model_Error{kind = .Unsupported, want = {text = "partial"}} }
	if m == nil { return Model_Error{kind = .Bad_Option, want = {text = "target"}} }
	return load_value_scoped_raw(&m.plan, m.judging, rules.Node_Ref{&doc, tape.ROOT}, rawptr(out), type_info_of(T), sink, opts, policy, sp)
}

@(require_results)
load_document :: proc(m: ^Model($T), doc: ^tape.Document, out: ^T, sink: ^Sink = nil, opts := Load_Opts{}, allocator := context.allocator) -> Error {
	if m == nil || doc == nil || out == nil || len(doc.nodes) == 0 { return Model_Error{kind = .Bad_Option, want = {text = "document"}} }
	if doc.partial != nil { return Model_Error{kind = .Unsupported, want = {text = "partial"}} }
	return load_value_raw(&m.plan, m.judging, rules.Node_Ref{doc, tape.ROOT}, rawptr(out), type_info_of(T), sink, opts, allocator)
}

@(require_results)
load_value :: proc(m: ^Model($T), v: rules.Value, out: ^T, sink: ^Sink = nil, opts := Load_Opts{}, allocator := context.allocator) -> Error {
	if m == nil || out == nil { return Model_Error{kind = .Bad_Option, want = {text = "target"}} }
	return load_value_raw(&m.plan, m.judging, v, rawptr(out), type_info_of(T), sink, opts, allocator)
}

@(private, require_results)
load_value_raw :: proc(plan: ^Type_Plan, judging: ^Applied, v: rules.Value, out: rawptr, ti: ^runtime.Type_Info, sink: ^Sink, opts: Load_Opts, allocator: runtime.Allocator) -> Error {
	if plan == nil || out == nil || len(plan.nodes) == 0 { return Model_Error{kind = .Bad_Option, want = {text = "target"}} }
	fmt: ^tape.Format; if ref, is_ref := v.(rules.Node_Ref); is_ref && ref.doc != nil { fmt = ref.doc.format }
	policy, ok := resolve_dups(opts.dups, fmt); if !ok { return Model_Error{kind = .Bad_Option, want = {text = "dups"}} }
	sc: Scratch_Scope; sp := (^Scratch_Scope)(rawptr(&sc)); scratch_begin(sp, opts, allocator); defer scratch_end(sp)
	return load_value_scoped_raw(plan, judging, v, out, ti, sink, opts, policy, sp)
}

@(private)
load_value_scoped_raw :: proc(plan: ^Type_Plan, judging: ^Applied, v: rules.Value, out: rawptr, ti: ^runtime.Type_Info, sink: ^Sink, opts: Load_Opts, policy: tape.Duplicates, sc: ^Scratch_Scope) -> Error {
	if plan == nil || out == nil || len(plan.nodes) == 0 { return Model_Error{kind = .Bad_Option, want = {text = "target"}} }
	mem.zero(out, ti.size)
	from := len(sink.entries) if sink != nil else 0
	l, lerr := loader_make(plan, judging, policy, opts.budget, sink, sc.out, sc.scratch, validators = opts.validators)
	if lerr != nil { return scratch_oom_error(sc) }
	defer loader_cleanup(&l)
	decode_loop(&l, plan.root, v, out, nil, nil)
	if sink != nil { order_sink(sink, from) }
	if err := loader_result_err(&l, sc); err != nil { free_value(out, ti, sc.out); return err }
	return nil
}

@(private)
loader_result_err :: proc(l: ^Loader, sc: ^Scratch_Scope) -> Error {
	if l.budget.exceeded.kind != .None { error_destroy(l.first, sc.out); return tape.Error(l.budget.exceeded) }
	if l.oom { error_destroy(l.first, sc.out); return scratch_oom_error(sc) }
	return l.first if l.first.kind != .None else nil
}

was_set :: proc(m: ^Model($T), $S: typeid, set: Fields_Set, name: string) -> bool {
	if m == nil { return false }
	si := find_struct_info(&m.plan, S)
	if si != nil { for f, i in si.fields { if f.odin_name == name { return fields_set_has(set, i) } } }
	return false
}

// Budget tracker & shared leaf checkers
@(private)
Budget_Tracker :: struct { limit: tape.Budget, max_depth, depth, nodes: u32, steps: u64, exceeded: tape.Exceeded }
@(private)
budget_init :: proc "contextless" (b: ^Budget_Tracker, limit: tape.Budget) { b^ = {limit = limit, max_depth = limit.depth if limit.depth > 0 else tape.DEFAULT_DEPTH} }
@(private)
budget_node :: #force_inline proc "contextless" (b: ^Budget_Tracker, at: u64) -> bool { b.nodes += 1; if b.limit.nodes > 0 && b.nodes > b.limit.nodes { b.exceeded = {at, .Nodes}; return false }; return true }
@(private)
budget_step :: #force_inline proc "contextless" (b: ^Budget_Tracker, at: u64) -> bool { b.steps += 1; if b.limit.steps > 0 && b.steps > b.limit.steps { b.exceeded = {at, .Steps}; return false }; return true }
@(private)
budget_enter :: #force_inline proc "contextless" (b: ^Budget_Tracker, at: u64) -> bool { b.depth += 1; if b.depth > b.max_depth { b.exceeded = {at, .Depth}; return false }; return true }
@(private)
budget_leave :: #force_inline proc "contextless" (b: ^Budget_Tracker) { if b.depth > 0 { b.depth -= 1 } }

@(private)
emit_leaf_fails :: proc(leaf: ^rules.Leaf, fails: bit_set[rules.Error_Kind; u64], members: bool, at: u64, steps: []tape.Step, sink: ^Sink, first: ^Model_Error, oom: ^bool, allocator, scratch: runtime.Allocator, silent: bool, secret := false) -> bool {
	if fails == {} { return true }
	op_buf: [64]u8 = ---
	for fk in fails {
		op, op_heap := "", false
		#partial switch fk {
		case .Too_Short: op = fmt_bound(op_buf[:], "at least ", i64(leaf.min_length), " character", true)
		case .Too_Long:  op = fmt_bound(op_buf[:], "at most ", i64(leaf.max_length), " character", true)
		case .Too_Few:   op = fmt_bound(op_buf[:], "at least ", i64(leaf.min_members if members else leaf.min_items), " member" if members else " element", true)
		case .Too_Many:  op = fmt_bound(op_buf[:], "at most ", i64(leaf.max_members if members else leaf.max_items), " member" if members else " element", true)
		case .Below_Minimum, .Above_Maximum:
			low := fk == .Below_Minimum; x := leaf.minimum if low else leaf.maximum
			if x.whole { op = fmt_bound(op_buf[:], ("greater than " if low else "less than ") if x.exclusive else ("at least " if low else "at most "), x.int, "", false) } else { op = rules.operand_text(leaf, fk, members, scratch); op_heap = true }
		case .Wrong_Kind: op = rules.operand_text(leaf, fk, members, scratch); op_heap = true
		}
		ok := record_failure(sink, first, oom, allocator, map_rules_kind(fk), at, steps, op, {}, silent, secret)
		if op_heap && len(op) > 0 { delete(op, scratch) }
		if !ok { return false }
	}
	return false
}

@(private)
fmt_bound :: proc "contextless" (buf: []u8, pfx: string, v: i64, noun: string, unsigned: bool) -> string #no_bounds_check {
	pos := len(pfx); copy(buf, pfx)
	pos += dump_put_u64(raw_data(buf[pos:]), u64(v)) if unsigned else dump_put_i64(raw_data(buf[pos:]), v)
	if len(noun) > 0 { copy(buf[pos:], noun); pos += len(noun); if v != 1 { buf[pos] = 's'; pos += 1 } }
	return string(buf[:pos])
}

@(private)
check_string_leaf :: proc(plan: ^Type_Plan, re_scratch: ^regex.Scratch, rule_idx: i32, s: string, at: u64, steps: []tape.Step, sink: ^Sink, first: ^Model_Error, oom: ^bool, allocator, scratch: runtime.Allocator, silent: bool, secret := false) -> bool {
	if rule_idx <= 0 { return true }
	leaf := &plan.leaves[rule_idx - 1]; fails, _ := rules.judge_string(leaf, s, re_scratch if leaf.pattern != nil else nil, 0, scratch)
	return emit_leaf_fails(leaf, fails, false, at, steps, sink, first, oom, allocator, scratch, silent, secret)
}
@(private)
check_number_leaf :: proc(plan: ^Type_Plan, rule_idx: i32, text: string, small: Maybe(i64), at: u64, steps: []tape.Step, sink: ^Sink, first: ^Model_Error, oom: ^bool, allocator, scratch: runtime.Allocator, silent: bool, secret := false) -> bool {
	if rule_idx <= 0 { return true }
	leaf := &plan.leaves[rule_idx - 1]
	return emit_leaf_fails(leaf, rules.judge_number(leaf, text, small), false, at, steps, sink, first, oom, allocator, scratch, silent, secret)
}
@(private)
check_count_leaf :: proc(plan: ^Type_Plan, rule_idx: i32, n: u64, members: bool, at: u64, steps: []tape.Step, sink: ^Sink, first: ^Model_Error, oom: ^bool, allocator, scratch: runtime.Allocator, silent: bool, secret := false) -> bool {
	if rule_idx <= 0 { return true }
	leaf := &plan.leaves[rule_idx - 1]
	return emit_leaf_fails(leaf, rules.judge_count(n, leaf.min_members if members else leaf.min_items, leaf.max_members if members else leaf.max_items), members, at, steps, sink, first, oom, allocator, scratch, silent, secret)
}

// Loader state and cross-format value extractors
@(private)
Loader :: struct {
	plan: ^Type_Plan, judging: ^Applied, validators: ^Validator_Registry, policy: tape.Duplicates, sink: ^Sink, first: Model_Error,
	oom, silent: bool, secret_depth: int, fail_count: u64, budget: Budget_Tracker, steps: [dynamic]tape.Step,
	rep: Report, re_scratch: regex.Scratch, allocator, scratch: runtime.Allocator,
}

@(private)
loader_make :: proc(plan: ^Type_Plan, judging: ^Applied, policy: tape.Duplicates, budget: tape.Budget, sink: ^Sink, allocator, scratch: runtime.Allocator, silent := false, validators: ^Validator_Registry = nil) -> (l: Loader, err: runtime.Allocator_Error) {
	rs, rerr := regex.scratch_make(scratch); if rerr.kind != .None { return {}, .Out_Of_Memory }
	l = {plan = plan, judging = judging, validators = validators, policy = policy, sink = sink, silent = silent, re_scratch = rs, allocator = allocator, scratch = scratch}
	budget_init(&l.budget, budget); l.steps.allocator = scratch; report_init(&l.rep, scratch)
	return l, nil
}
@(private)
loader_cleanup :: proc(l: ^Loader) { report_destroy(&l.rep); regex.scratch_destroy(&l.re_scratch) }
@(private)
loader_stopped :: #force_inline proc "contextless" (l: ^Loader) -> bool { return l.oom || l.budget.exceeded.kind != .None || ((l.sink == nil || l.silent) && l.first.kind != .None) }
@(private)
loader_fail :: proc(l: ^Loader, kind: Error_Kind, at: u64, operand := "", want := Want{}) -> bool {
	l.fail_count += 1
	return record_failure(l.sink, &l.first, &l.oom, l.allocator, kind, at, l.steps[:], operand, want, l.silent, l.secret_depth > 0)
}
@(private)
value_offset :: proc "contextless" (v: rules.Value) -> u64 {
	if ref, ok := v.(rules.Node_Ref); ok && ref.doc != nil && int(ref.node) < len(ref.doc.nodes) { return ref.doc.nodes[ref.node].lo }
	return 0
}
@(private)
is_dsv_ref :: proc "contextless" (v: rules.Value) -> bool { ref, ok := v.(rules.Node_Ref); return ok && ref.doc != nil && ref.doc.format != nil && ref.doc.format.options == .Dsv }
@(private)
is_empty_dsv_cell :: proc "contextless" (v: rules.Value) -> bool {
	ref, ok := v.(rules.Node_Ref); if !ok || ref.doc == nil || int(ref.node) >= len(ref.doc.nodes) { return false }
	n := ref.doc.nodes[ref.node]
	return (n.kind == .Plain && n.n == 0) || (ref.doc.format != nil && ref.doc.format.options == .Dsv && n.kind == .String && n.n == 0 && (n.spelling & tape.SPELLING_QUOTED) == 0)
}
@(private)
has_xml_attributes :: proc "contextless" (v: rules.Value) -> bool {
	ref, ok := v.(rules.Node_Ref); if !ok || ref.doc == nil || ref.doc.format == nil || .Attribute not_in ref.doc.format.facts || ref.doc.format.attribute == nil { return false }
	for f in tape.facts_of(ref.doc, ref.node) { if f.kind == .Attribute { return true } }
	return false
}

@(private)
Obj_Entry :: struct { key: string, key_at: u64, val: rules.Value, cap_only: bool }

@(private)
clone_token_text :: proc(doc: ^tape.Document, tok: tape.Token, scratch: runtime.Allocator) -> (string, bool) {
	buf: [128]u8 = ---
	if s, ok := tape.node_text(doc, tok, buf[:]); ok { cl, err := strings.clone(s, scratch); return cl, err == nil }
	room := tape.text_room(doc, tok); if room <= 0 { return "", false }
	heap, err := make([]u8, room, scratch); if err != nil { return "", false }
	return tape.node_text(doc, tok, heap)
}

@(private)
extract_object :: proc(l: ^Loader, v: rules.Value) -> ([]Obj_Entry, bool) {
	raw_list, rerr := make([dynamic]Obj_Entry, 0, 8, l.scratch); if rerr != nil { l.oom = true; return nil, false }
	if ref, is_ref := v.(rules.Node_Ref); is_ref && ref.doc != nil && int(ref.node) < len(ref.doc.nodes) {
		if ref.doc.format != nil && .Attribute in ref.doc.format.facts && ref.doc.format.attribute != nil {
			for f in tape.facts_of(ref.doc, ref.node) {
				if f.kind != .Attribute { continue }
				kt, vt := ref.doc.format.attribute(ref.doc, f)
				ks, kok := clone_token_text(ref.doc, kt, l.scratch); vs, vok := clone_token_text(ref.doc, vt, l.scratch)
				if !kok || !vok || !push_oom(&l.oom, &raw_list, Obj_Entry{key = ks, key_at = kt.lo, val = rules.Value(vs)}) { l.oom = true; return nil, false }
			}
		}
		if n := ref.doc.nodes[ref.node]; n.kind == .Object {
			r := tape.Reader{doc = ref.doc}; ch, p, cerr := tape.children(r, ref.node, l.scratch)
			if cerr != nil { l.oom = true; return nil, false }
			defer tape.destroy_children(&ch)
			if p != .Found { return nil, false }
			iter_dups := tape.Duplicates.Group if (l.policy == .Refuse || l.policy == .Group) else l.policy
			for {
				kn, vn, np := tape.next_child(r, &ch, iter_dups)
				if np == .Missing { break }
				if np != .Found { return nil, false }
				ktok := ref.doc.nodes[kn] if kn != tape.NO_NODE else tape.cell_key(r, ch)
				kstr, kok := clone_token_text(ref.doc, ktok, l.scratch)
				if !kok || !push_oom(&l.oom, &raw_list, Obj_Entry{key = kstr, key_at = ktok.lo, val = rules.Node_Ref{ref.doc, vn}}) { l.oom = true; return nil, false }
			}
		} else if len(raw_list) > 0 {
			if n.kind != .Null && !push_oom(&l.oom, &raw_list, Obj_Entry{key = "#text", key_at = n.lo, val = v}) { return nil, false }
		} else { return nil, false }
	} else if members, is_mem := v.([]rules.Member_Value); is_mem {
		for m in members { if !push_oom(&l.oom, &raw_list, Obj_Entry{key = m.key, val = m.value}) { return nil, false } }
	} else { return nil, false }

	if len(raw_list) <= 1 { return raw_list[:], true }
	seen_idx, serr := make(map[string]int, len(raw_list), l.scratch)
	out, oerr := make([dynamic]Obj_Entry, 0, len(raw_list), l.scratch)
	if serr != nil || oerr != nil { l.oom = true; return nil, false }
	groups: map[int][dynamic]rules.Value
	for e in raw_list {
		if prev, dup := seen_idx[e.key]; dup {
			#partial switch l.policy {
			case .Refuse:
				if !push_oom(&l.oom, &l.steps, tape.Step(tape.Name(e.key))) { return nil, false }
				_ = loader_fail(l, .Duplicate_Key, e.key_at); pop(&l.steps); return nil, false
			case .First: continue
			case .Last:  out[prev] = e; continue
			case .Group:
				if groups == nil { gm, gerr := make(map[int][dynamic]rules.Value, 4, l.scratch); if gerr != nil { l.oom = true; return nil, false }; groups = gm }
				if list, exists := &groups[prev]; exists {
					if !push_oom(&l.oom, list, e.val) { return nil, false }
				} else {
					ld, lerr := make([dynamic]rules.Value, 0, 4, l.scratch)
					if lerr != nil || !push_oom(&l.oom, &ld, out[prev].val) || !push_oom(&l.oom, &ld, e.val) { l.oom = true; return nil, false }
					if _, merr := map_insert(&groups, prev, ld); merr != nil { l.oom = true; return nil, false }
				}
				continue
			}
		}
		if _, merr := map_insert(&seen_idx, e.key, len(out)); merr != nil { l.oom = true; return nil, false }
		if !push_oom(&l.oom, &out, e) { return nil, false }
	}
	for idx, list in groups { out[idx].val = list[:] }
	return out[:], true
}

@(private)
extract_array :: proc(v: rules.Value, scratch: runtime.Allocator) -> ([]rules.Value, bool) {
	if elems, is_arr := v.([]rules.Value); is_arr { return elems, true }
	ref, is_ref := v.(rules.Node_Ref); if !is_ref || ref.doc == nil || int(ref.node) >= len(ref.doc.nodes) { return nil, false }
	r := tape.Reader{doc = ref.doc}; ch, p, cerr := tape.children(r, ref.node, scratch)
	if cerr != nil { return nil, false }
	defer tape.destroy_children(&ch)
	if p != .Found { return nil, false }
	out, oerr := make([dynamic]rules.Value, 0, 4, scratch); if oerr != nil { return nil, false }
	for {
		_, vn, np := tape.next_child(r, &ch)
		if np == .Missing { break }
		if np != .Found { return nil, false }
		if _, aerr := append(&out, rules.Node_Ref{ref.doc, vn}); aerr != nil { return nil, false }
	}
	return out[:], true
}

@(private)
check_skipped_dups :: proc(l: ^Loader, root: rules.Value) -> bool {
	if l.policy != .Refuse { return true }
	Frame :: struct { pop_step, has_step: bool, val: rules.Value, step: tape.Step }
	stack, serr := make([dynamic]Frame, 0, 16, l.scratch); if serr != nil { l.oom = true; return false }
	defer delete(stack)
	if !push_oom(&l.oom, &stack, Frame{val = root}) { return false }
	for len(stack) > 0 {
		f := pop(&stack)
		if f.pop_step { if len(l.steps) > 0 { pop(&l.steps) }; continue }
		if f.has_step && (!push_oom(&l.oom, &l.steps, f.step) || !push_oom(&l.oom, &stack, Frame{pop_step = true})) { return false }
		#partial switch rules.value_kind(f.val) {
		case .Object:
			entries, ok := extract_object(l, f.val); if !ok { return false }
			for i := len(entries) - 1; i >= 0; i -= 1 { if !push_oom(&l.oom, &stack, Frame{val = entries[i].val, step = tape.Name(entries[i].key), has_step = true}) { return false } }
		case .Array:
			elems, ok := extract_array(f.val, l.scratch); if !ok { l.oom = true; return false }
			for i := len(elems) - 1; i >= 0; i -= 1 { if !push_oom(&l.oom, &stack, Frame{val = elems[i], step = tape.Index(i), has_step = true}) { return false } }
		}
	}
	return true
}

@(private)
extract_string :: proc(l: ^Loader, v: rules.Value, buf: []u8) -> (s: string, owned, ok: bool) {
	vk := rules.value_kind(v)
	if vk == .String { s, owned, ok = rules.value_string(v, buf, l.scratch); if !ok { l.oom = true }; return }
	if is_dsv_ref(v) {
		#partial switch vk {
		case .True:   return "true", false, true
		case .False:  return "false", false, true
		case .Number: s, owned, ok = rules.value_number_text(v, buf, l.scratch); if !ok { l.oom = true }; return
		}
	}
	return "", false, false
}

@(private)
extract_number_text :: proc(l: ^Loader, v: rules.Value, buf: []u8) -> (s: string, owned, ok, non_finite: bool) {
	vk := rules.value_kind(v)
	if vk == .Number {
		if fv, is_f64 := v.(f64); is_f64 && (math.is_nan(fv) || math.is_inf(fv, 0)) { return "", false, false, true }
		if ref, is_ref := v.(rules.Node_Ref); is_ref && ref.doc != nil && ref.doc.format != nil && ref.doc.format.number != nil {
			if num, nok := tape.node_number(ref.doc, ref.node); nok && num.kind == .Float {
				if f := transmute(f64)num.bits; math.is_nan(f) || math.is_inf(f, 0) { return "", false, false, true }
			}
		}
		s, owned, ok = rules.value_number_text(v, buf, l.scratch)
		if !ok { if ref, is_ref := v.(rules.Node_Ref); is_ref && ref.doc != nil && tape.text_room(ref.doc, ref.node) > len(buf) { l.oom = true } }
		return s, owned, ok, false
	}
	if is_dsv_ref(v) && vk == .String {
		ps, powned, pok := rules.value_string(v, buf, l.scratch); if !pok { l.oom = true; return "", false, false, false }
		if len(ps) > 0 { if _, num_ok := spell.number_strict(transmute([]u8)ps, 0, u64(len(ps))); num_ok { return ps, powned, true, false } }
		if powned { delete(ps, l.scratch) }
	}
	return "", false, false, false
}

// Iterative decoder loop (O(1) native stack!)
@(private)
Load_Frame_Kind :: enum u8 { Node, Struct_Entries, Struct_Finish, Field_After, Node_After, List_Elems, Map_Entries, Map_Insert, Custom_Finish, Union_Tag, Run_Judged, Pop_Step, Leave_Depth }

@(private)
Load_Frame :: struct {
	kind:                                      Load_Frame_Kind,
	node_idx, field_rule_idx:                  i32,
	val:                                       rules.Value,
	dest, patch_existing:                      rawptr,
	field_unique, not_null, is_cap, pop_secret: bool,
	patch_node:                                ^Patch_Node,
	skip_tag_key, cap_key:                     string,
	si:                                        ^Struct_Info,
	fi, idx, count, tag_size:                  int,
	stride, base, tag_offset:                  uintptr,
	start_fails, at:                           u64,
	tag_value:                                 i64,
	seen:                                      ^Fields_Set,
	entries:                                   []Obj_Entry,
	elems:                                     []rules.Value,
	key_buf, val_buf:                          rawptr,
	saved_alloc:                               runtime.Allocator,
	m_info:                                    ^runtime.Map_Info,
	key_ti, val_ti:                            ^runtime.Type_Info,
}

@(private)
decode_loop :: proc(l: ^Loader, root_idx: i32, root_val: rules.Value, root_dest, patch_existing: rawptr, patch_node: ^Patch_Node, root_rule_idx := i32(0)) {
	stack, serr := make([dynamic]Load_Frame, 0, 32, l.scratch); if serr != nil { l.oom = true; return }
	defer delete(stack)
	if !push_oom(&l.oom, &stack, Load_Frame{kind = .Node, node_idx = root_idx, val = root_val, dest = root_dest, field_rule_idx = root_rule_idx, patch_existing = patch_existing, patch_node = patch_node}) { return }

	for len(stack) > 0 && !loader_stopped(l) {
		top := &stack[len(stack) - 1]
		switch top.kind {
		case .Pop_Step:    f := pop(&stack); if f.pop_secret && l.secret_depth > 0 { l.secret_depth -= 1 }; if len(l.steps) > 0 { pop(&l.steps) }
		case .Leave_Depth: pop(&stack); budget_leave(&l.budget)
		case .Run_Judged:  f := pop(&stack); if !run_node_judged(l, &l.plan.nodes[f.node_idx], f.field_unique, f.val) { l.fail_count += 1 }
		case .Union_Tag:   f := pop(&stack); if l.fail_count == f.start_fails && f.tag_size > 0 { tv := f.tag_value; mem.copy(rawptr(uintptr(f.dest) + f.tag_offset), &tv, f.tag_size) }
		case .Custom_Finish:
			f := pop(&stack); l.allocator = f.saved_alloc; if l.fail_count != f.start_fails { continue }
			c := &l.plan.customs[l.plan.nodes[f.node_idx].custom_idx]
			if kind := c.convert_from(c.from, f.val_buf, f.dest, l.allocator); kind == .No_Memory { l.oom = true; return } else if kind != .None { _ = loader_fail(l, kind, f.at) }
		case .Field_After:
			f := pop(&stack); if l.fail_count != f.start_fails { continue }
			fld := &f.si.fields[f.fi]
			run_after_validators(fld.afters, fld.named_validators, f.dest, l.plan.nodes[fld.node].ti, nil, l.validators, &l.rep, l.steps[:], f.at, l.sink, &l.first, &l.oom, &l.fail_count, l.allocator, l.scratch, l.silent, l.secret_depth > 0)
		case .Node_After:
			f := pop(&stack); if l.fail_count != f.start_fails { continue }
			tn := &l.plan.nodes[f.node_idx]
			if len(tn.named_validators) > 0 {
				run_after_validators(nil, tn.named_validators, f.dest, tn.ti, nil, l.validators, &l.rep, l.steps[:], f.at, l.sink, &l.first, &l.oom, &l.fail_count, l.allocator, l.scratch, l.silent, l.secret_depth > 0)
			}
		case .Struct_Finish:
			f := pop(&stack); si, tn, partial := f.si, &l.plan.nodes[f.node_idx], f.patch_node != nil
			if !partial {
				close_at := max(u64) - 1
				if ref, is_ref := f.val.(rules.Node_Ref); is_ref && ref.doc != nil && int(ref.node) < len(ref.doc.nodes) {
					rn := ref.doc.nodes[ref.node]
					if rn.kind >= .Array && ref.doc.format != nil && ref.doc.format.close_end != nil { if ce, cok := ref.doc.format.close_end(ref.doc, ref.node); cok { close_at = ce } } else if rn.kind < .Array { close_at = rn.lo + u64(rn.n) } else { close_at = u64(len(ref.doc.src)) }
				}
				for fld, fi in si.fields {
					if fields_set_has(f.seen^, fi) || .Read_Only in fld.flags { continue }
					if .Has_Default in fld.flags {
						if fld.make_default(rawptr(uintptr(f.dest) + fld.offset), fld.default_data, l.allocator) != nil { l.oom = true; return }
					} else if .Required in fld.flags {
						if !push_oom(&l.oom, &l.steps, tape.Step(tape.Name(fld.name))) { return }
						if .Secret in fld.flags { l.secret_depth += 1 }
						cont := loader_fail(l, .Missing_Field, close_at)
						if .Secret in fld.flags && l.secret_depth > 0 { l.secret_depth -= 1 }
						pop(&l.steps); if !cont { break }
					}
				}
			}
			if loader_stopped(l) { budget_leave(&l.budget); return }
			if !partial && tn.judged && !run_node_judged(l, tn, false, f.val) { l.fail_count += 1 }
			if loader_stopped(l) { budget_leave(&l.budget); return }
			if !partial && l.fail_count == f.start_fails && len(si.validators) > 0 {
				run_after_validators(si.validators, nil, f.dest, nil, si, l.validators, &l.rep, l.steps[:], f.at, l.sink, &l.first, &l.oom, &l.fail_count, l.allocator, l.scratch, l.silent, l.secret_depth > 0)
			}
			budget_leave(&l.budget)
		case .Struct_Entries:
			if top.idx >= len(top.entries) { pop(&stack); continue }
			e := top.entries[top.idx]; top.idx += 1
			if top.skip_tag_key != "" && e.key == top.skip_tag_key { continue }
			si := top.si; fi := -1 if e.cap_only else struct_find_field(si, e.key)
			if fi < 0 || .Read_Only in si.fields[fi].flags {
				if fi < 0 && si.capture_idx >= 0 {
					cap_tn := &l.plan.nodes[si.capture_node]; val_tn := &l.plan.nodes[cap_tn.child]
					val_buf, verr := runtime.mem_alloc(max(val_tn.size, 1), val_tn.align, l.scratch)
					if verr != nil || !push_oom(&l.oom, &l.steps, tape.Step(tape.Name(e.key))) { l.oom = true; return }
					m_info := runtime.type_info_base(cap_tn.ti).variant.(^runtime.Type_Info_Map)
					if !push_oom(&l.oom, &stack, Load_Frame{kind = .Pop_Step}) ||
					   !push_oom(&l.oom, &stack, Load_Frame{kind = .Map_Insert, dest = rawptr(uintptr(top.dest) + si.capture_offset), val_buf = raw_data(val_buf), val_ti = val_tn.ti, m_info = m_info.map_info, is_cap = true, cap_key = e.key, start_fails = l.fail_count}) ||
					   !push_oom(&l.oom, &stack, Load_Frame{kind = .Node, node_idx = cap_tn.child, val = e.val, dest = raw_data(val_buf)}) { return }
				} else if si.forbid_extra || fi < 0 {
					if !push_oom(&l.oom, &l.steps, tape.Step(tape.Name(e.key))) { return }
					if si.forbid_extra { _ = loader_fail(l, .Not_Allowed, e.key_at) } else { _ = check_skipped_dups(l, e.val) }
					pop(&l.steps)
				}
				continue
			}
			fld, total, partial := &si.fields[fi], len(si.fields), top.patch_node != nil
			if fields_set_set(top.seen, fi, total, l.scratch) != nil ||
			   (si.has_fields_set && fields_set_set((^Fields_Set)(uintptr(top.dest) + si.fields_set_offset), fi, total, l.allocator) != nil) ||
			   (partial && fields_set_set(&top.patch_node.present, fi, total, l.scratch) != nil) { l.oom = true; return }
			if !push_oom(&l.oom, &l.steps, tape.Step(tape.Name(fld.name))) { return }

			field_secret, field_val := .Secret in fld.flags, e.val
			if .Has_Before in fld.flags {
				mat, merr := clone_rules_value(e.val, l.scratch, l.scratch)
				if merr != nil { l.oom = true; pop(&l.steps); return }
				report_reset(&l.rep); field_val = fld.before.call(mat, fld.before.fn, &l.rep)
				if l.rep.failed || l.rep.oom { l.fail_count += 1; _ = emit_report(&l.rep, l.steps[:], value_offset(e.val), nil, l.sink, &l.first, &l.oom, l.allocator, l.scratch, l.silent, field_secret || l.secret_depth > 0); pop(&l.steps); continue }
			}
			child_existing: rawptr; child_patch: ^Patch_Node
			if partial && top.patch_existing != nil {
				if ftn := &l.plan.nodes[fld.node]; (ftn.kind == .Struct && l.plan.structs[ftn.struct_idx].has_fields_set) || (ftn.kind == .Maybe && l.plan.nodes[ftn.child].kind == .Struct) {
					child_existing, child_patch = rawptr(uintptr(top.patch_existing) + fld.offset), alloc_patch_child(top.patch_node, fi, l.scratch)
					if child_patch == nil { l.oom = true; pop(&l.steps); return }
				}
			}
			field_dest := rawptr(uintptr(top.dest) + fld.offset)
			if field_secret { l.secret_depth += 1 }
			if !push_oom(&l.oom, &stack, Load_Frame{kind = .Pop_Step, pop_secret = field_secret}) { return }
			if (len(fld.afters) > 0 || len(fld.named_validators) > 0) && (!partial || .Write_Only in fld.flags) {
				if !push_oom(&l.oom, &stack, Load_Frame{kind = .Field_After, si = si, fi = fi, dest = field_dest, at = value_offset(e.val), start_fails = l.fail_count}) { return }
			}
			if !push_oom(&l.oom, &stack, Load_Frame{kind = .Node, node_idx = fld.node, val = field_val, dest = field_dest, field_rule_idx = fld.rule_idx, field_unique = .Has_Unique in fld.flags, not_null = .Not_Null in fld.flags, patch_existing = child_existing, patch_node = child_patch}) { return }
		case .List_Elems:
			if top.idx >= top.count { pop(&stack); continue }
			i := top.idx; top.idx += 1
			if !push_oom(&l.oom, &l.steps, tape.Step(tape.Index(i))) || !push_oom(&l.oom, &stack, Load_Frame{kind = .Pop_Step}) || !push_oom(&l.oom, &stack, Load_Frame{kind = .Node, node_idx = top.node_idx, val = top.elems[i], dest = rawptr(top.base + uintptr(i) * top.stride)}) { return }
		case .Map_Entries:
			if top.idx >= len(top.entries) { pop(&stack); continue }
			e := top.entries[top.idx]; top.idx += 1
			tn := &l.plan.nodes[top.node_idx]; ktn, vtn := &l.plan.nodes[tn.key_node], &l.plan.nodes[tn.child]
			if !push_oom(&l.oom, &l.steps, tape.Step(tape.Name(e.key))) { return }
			kbuf, kerr := runtime.mem_alloc(max(ktn.size, 1), ktn.align, l.scratch)
			vbuf, verr := runtime.mem_alloc(max(vtn.size, 1), vtn.align, l.scratch)
			if kerr != nil || verr != nil { l.oom = true; pop(&l.steps); return }
			if !decode_map_key(l, ktn, e.key, raw_data(kbuf), e.key_at) { pop(&l.steps); continue }
			m_info := runtime.type_info_base(tn.ti).variant.(^runtime.Type_Info_Map)
			if !push_oom(&l.oom, &stack, Load_Frame{kind = .Pop_Step}) ||
			   !push_oom(&l.oom, &stack, Load_Frame{kind = .Map_Insert, dest = top.dest, key_buf = raw_data(kbuf), val_buf = raw_data(vbuf), key_ti = ktn.ti, val_ti = vtn.ti, m_info = m_info.map_info, start_fails = l.fail_count}) ||
			   !push_oom(&l.oom, &stack, Load_Frame{kind = .Node, node_idx = tn.child, val = e.val, dest = raw_data(vbuf)}) { return }
		case .Map_Insert:
			f := pop(&stack)
			if l.fail_count != f.start_fails { if f.key_buf != nil { free_value(f.key_buf, f.key_ti, l.allocator) }; free_value(f.val_buf, f.val_ti, l.allocator); continue }
			rm := (^runtime.Raw_Map)(f.dest); if rm.allocator.procedure == nil { rm.allocator = l.allocator }
			if f.is_cap {
				k_owned, kerr := strings.clone(f.cap_key, l.allocator)
				if kerr != nil { free_value(f.val_buf, f.val_ti, l.allocator); l.oom = true; return }
				if _, merr := runtime.__dynamic_map_set_without_hash(rm, f.m_info, &k_owned, f.val_buf); merr != nil { delete(k_owned, l.allocator); free_value(f.val_buf, f.val_ti, l.allocator); l.oom = true; return }
			} else if _, merr := runtime.__dynamic_map_set_without_hash(rm, f.m_info, f.key_buf, f.val_buf); merr != nil {
				free_value(f.key_buf, f.key_ti, l.allocator); free_value(f.val_buf, f.val_ti, l.allocator); l.oom = true; return
			}
		case .Node:
			f := pop(&stack); at := value_offset(f.val); if !budget_node(&l.budget, at) { return }
			tn, vk := &l.plan.nodes[f.node_idx], rules.value_kind(f.val)
			rule_idx, has_unique := f.field_rule_idx if f.field_rule_idx > 0 else tn.rule_idx, f.field_unique || tn.has_unique
			if len(tn.named_validators) > 0 && f.patch_node == nil && tn.kind != .Maybe && tn.kind != .Ptr {
				if !push_oom(&l.oom, &stack, Load_Frame{kind = .Node_After, node_idx = f.node_idx, dest = f.dest, at = at, start_fails = l.fail_count}) { return }
			}
			#partial switch tn.kind {
			case .Maybe, .Ptr:
				if vk == .Null || is_empty_dsv_cell(f.val) {
					if f.not_null { _ = loader_fail(l, .Wrong_Kind, at, "", {type = tn.type, text = "non-null"}) } else if tn.kind == .Maybe && f.patch_node != nil { f.patch_node.set_null = true }
					continue
				}
				dest, inner_existing, inner_patch := f.dest, rawptr(nil), (^Patch_Node)(nil)
				if tn.kind == .Maybe {
					if f.patch_node != nil && l.plan.nodes[tn.child].kind == .Struct && f.patch_existing != nil && maybe_is_set(tn, f.patch_existing) {
						inner_existing, inner_patch, f.patch_node.partial_maybe = f.patch_existing, f.patch_node, true
					}
					if !tn.pure_maybe && tn.tag_size > 0 { one := u64(1); mem.copy(rawptr(uintptr(f.dest) + tn.tag_offset), &one, tn.tag_size) }
				} else {
					if !budget_enter(&l.budget, at) { return }
					ctn := &l.plan.nodes[tn.child]
					raw, aerr := runtime.mem_alloc(max(ctn.size, 1), ctn.align, l.allocator); if aerr != nil { l.oom = true; return }
					(^rawptr)(f.dest)^ = raw_data(raw); dest = raw_data(raw)
					if !push_oom(&l.oom, &stack, Load_Frame{kind = .Leave_Depth}) { return }
				}
				if !push_oom(&l.oom, &stack, Load_Frame{kind = .Node, node_idx = tn.child, val = f.val, dest = dest, field_rule_idx = rule_idx, field_unique = has_unique, patch_existing = inner_existing, patch_node = inner_patch}) { return }
			case .Struct:
				si := &l.plan.structs[tn.struct_idx]; entries: []Obj_Entry
				if vk == .Object || has_xml_attributes(f.val) {
					ok: bool; entries, ok = extract_object(l, f.val); if !ok { continue }
				} else if vk == .Array && is_dsv_ref(f.val) {
					elems, ok := extract_array(f.val, l.scratch); if !ok { l.oom = true; return }
					writable := 0; for &fld in si.fields { if .Read_Only not_in fld.flags { writable += 1 } }
					keep := len(elems) if (si.capture_idx >= 0 || si.forbid_extra) else min(len(elems), writable)
					pos, perr := make([]Obj_Entry, keep, l.scratch); if perr != nil { l.oom = true; return }
					col := 0
					for &fld in si.fields { if .Read_Only not_in fld.flags && col < keep { pos[col] = {key = fld.name, key_at = value_offset(elems[col]), val = elems[col]}; col += 1 } }
					kbuf: [24]u8 = ---
					for k in col ..< keep {
						k_cl, kerr := strings.clone(strconv.write_int(kbuf[:], i64(k + 1), 10), l.scratch); if kerr != nil { l.oom = true; return }
						pos[k] = {key = k_cl, key_at = value_offset(elems[k]), val = elems[k], cap_only = true}
					}
					entries = pos
				} else { _ = loader_fail(l, .Wrong_Kind, at, "", {type = tn.type, text = "object"}); continue }
				if !budget_enter(&l.budget, at) || !budget_step(&l.budget, at) { return }
				if f.patch_node != nil { f.patch_node.struct_idx = tn.struct_idx }
				seen_ptr, s2 := new(Fields_Set, l.scratch); if s2 != nil { l.oom = true; return }
				if !push_oom(&l.oom, &stack, Load_Frame{kind = .Struct_Finish, node_idx = f.node_idx, val = f.val, dest = f.dest, si = si, seen = seen_ptr, patch_node = f.patch_node, start_fails = l.fail_count, at = at}) { return }
				if len(entries) > 0 && !push_oom(&l.oom, &stack, Load_Frame{kind = .Struct_Entries, si = si, dest = f.dest, seen = seen_ptr, entries = entries, patch_existing = f.patch_existing, patch_node = f.patch_node, skip_tag_key = f.skip_tag_key}) { return }
			case .Slice, .Dynamic, .Array, .Fixed_List:
				elems: []rules.Value
				if vk == .Array { ok: bool; elems, ok = extract_array(f.val, l.scratch); if !ok { l.oom = true; return } } else if l.policy == .Group && vk != .Null {
					one, oerr := make([]rules.Value, 1, l.scratch); if oerr != nil { l.oom = true; return }; one[0] = f.val; elems = one
				} else { _ = loader_fail(l, .Wrong_Kind, at, "", {type = tn.type, text = "array"}); continue }
				if !budget_enter(&l.budget, at) || !budget_step(&l.budget, at) { return }
				n := len(elems)
				if (tn.kind == .Array && n < tn.count) || ((tn.kind == .Array || tn.kind == .Fixed_List) && n > tn.count) {
					if !loader_fail(l, .Too_Few if n < tn.count else .Too_Many, at) { budget_leave(&l.budget); continue }
				} else if !check_count_leaf(l.plan, rule_idx, u64(n), false, at, l.steps[:], l.sink, &l.first, &l.oom, l.allocator, l.scratch, l.silent, l.secret_depth > 0) {
					l.fail_count += 1; if loader_stopped(l) { budget_leave(&l.budget); return }
				}
				ctn := &l.plan.nodes[tn.child]; elem_base, decode_n := uintptr(f.dest), n
				#partial switch tn.kind {
				case .Slice, .Dynamic:
					if tn.kind == .Dynamic { (^runtime.Raw_Dynamic_Array)(f.dest).allocator = l.allocator }
					if n > 0 {
						raw, aerr := runtime.mem_alloc(n * max(ctn.size, 1), ctn.align, l.allocator); if aerr != nil { l.oom = true; return }
						elem_base = uintptr(raw_data(raw))
						if tn.kind == .Slice { (^runtime.Raw_Slice)(f.dest)^ = {raw_data(raw), n} } else { (^runtime.Raw_Dynamic_Array)(f.dest)^ = {raw_data(raw), n, n, l.allocator} }
					}
				case .Array:      decode_n = min(n, tn.count)
				case .Fixed_List: decode_n = min(n, tn.count); (^int)(uintptr(f.dest) + tn.len_offset)^ = decode_n
				}
				if !push_oom(&l.oom, &stack, Load_Frame{kind = .Leave_Depth}) { return }
				if (has_unique || tn.judged) && !push_oom(&l.oom, &stack, Load_Frame{kind = .Run_Judged, node_idx = f.node_idx, val = f.val, field_unique = has_unique}) { return }
				if decode_n > 0 && !push_oom(&l.oom, &stack, Load_Frame{kind = .List_Elems, node_idx = tn.child, elems = elems, base = elem_base, count = decode_n, stride = uintptr(ctn.size)}) { return }
			case .Map:
				if vk != .Object && !has_xml_attributes(f.val) { _ = loader_fail(l, .Wrong_Kind, at, "", {type = tn.type, text = "object"}); continue }
				entries, ok := extract_object(l, f.val); if !ok { continue }
				if !budget_enter(&l.budget, at) || !budget_step(&l.budget, at) { return }
				if !check_count_leaf(l.plan, rule_idx, u64(len(entries)), true, at, l.steps[:], l.sink, &l.first, &l.oom, l.allocator, l.scratch, l.silent, l.secret_depth > 0) {
					l.fail_count += 1; if loader_stopped(l) { budget_leave(&l.budget); return }
				}
				(^runtime.Raw_Map)(f.dest).allocator = l.allocator
				if !push_oom(&l.oom, &stack, Load_Frame{kind = .Leave_Depth}) { return }
				if tn.judged && !push_oom(&l.oom, &stack, Load_Frame{kind = .Run_Judged, node_idx = f.node_idx, val = f.val}) { return }
				if len(entries) > 0 && !push_oom(&l.oom, &stack, Load_Frame{kind = .Map_Entries, node_idx = f.node_idx, dest = f.dest, entries = entries}) { return }
			case .Custom:
				ctn := &l.plan.nodes[tn.child]
				cbuf, cerr := runtime.mem_alloc(max(ctn.size, 1), ctn.align, l.scratch); if cerr != nil { l.oom = true; return }
				if tn.judged && !push_oom(&l.oom, &stack, Load_Frame{kind = .Run_Judged, node_idx = f.node_idx, val = f.val}) { return }
				saved := l.allocator; l.allocator = l.scratch
				if !push_oom(&l.oom, &stack, Load_Frame{kind = .Custom_Finish, node_idx = f.node_idx, dest = f.dest, val_buf = raw_data(cbuf), saved_alloc = saved, at = at, start_fails = l.fail_count}) ||
				   !push_oom(&l.oom, &stack, Load_Frame{kind = .Node, node_idx = tn.child, val = f.val, dest = raw_data(cbuf), field_rule_idx = rule_idx}) { l.allocator = saved; return }
			case .Union: decode_union_push(l, &stack, f.node_idx, tn, f.val, f.dest, rule_idx, at)
			case:       decode_scalar(l, tn, f.val, f.dest, rule_idx, f.not_null, at); if !loader_stopped(l) && tn.judged && !run_node_judged(l, tn, false, f.val) { l.fail_count += 1 }
			}
		}
	}
}

@(private)
maybe_is_set :: proc(tn: ^Type_Node, ptr: rawptr) -> bool {
	if ptr == nil { return false }
	if tn.pure_maybe { return (^rawptr)(ptr)^ != nil }
	tag := u64(0); mem.copy(&tag, rawptr(uintptr(ptr) + tn.tag_offset), tn.tag_size)
	return tag != 0
}

// Unified scalar decoder shared by `load.odin` and `stream.odin`
@(private)
Scalar_Kind :: enum u8 { Wrong, Null, String, Number, True, False, Non_Finite }

@(private)
Scalar_Env :: struct {
	plan: ^Type_Plan, re_scratch: ^regex.Scratch, stream: ^Stream_Loader, stream_sf: ^Stream_Field,
	steps: []tape.Step, sink: ^Sink, first: ^Model_Error, oom: ^bool, fail_count: ^u64,
	allocator, scratch: runtime.Allocator, silent, secret, has_val, opt_sec, wrote: bool,
}

@(private)
scalar_want_text :: proc(plan: ^Type_Plan, tn: ^Type_Node) -> string {
	#partial switch tn.kind {
	case .Uuid:              return "uuid"
	case .Base64:            return "base64"
	case .Hex:               return "hex"
	case .Time:              return "date-time"
	case .Decimal:           return "decimal"
	case .Number_Text:       return "number"
	case .Bool, .Bool_Wide:  return "bool"
	case .Enum:              return "string" if plan.enums[tn.enum_idx].by_name else "integer"
	case .I8 ..= .F64:       return type_name_short(tn.ti)
	}
	return "string"
}

@(private)
scalar_emit_fails :: proc(e: ^Scalar_Env, leaf: ^rules.Leaf, fails: bit_set[rules.Error_Kind; u64], at: u64) -> bool {
	if fails == {} { return true }
	if e.stream != nil { return stream_emit_leaf_fails(e.stream, e.stream.sp, leaf, fails, false, at, e.stream_sf) }
	e.fail_count^ += 1
	return emit_leaf_fails(leaf, fails, false, at, e.steps, e.sink, e.first, e.oom, e.allocator, e.scratch, e.silent, e.secret)
}

@(private)
scalar_fail :: proc(e: ^Scalar_Env, kind: Error_Kind, at: u64, want := Want{}) -> bool {
	if e.stream != nil { return stream_fail(e.stream, kind, at, "", want, sf = e.stream_sf) }
	e.fail_count^ += 1
	return record_failure(e.sink, e.first, e.oom, e.allocator, kind, at, e.steps, "", want, e.silent, e.secret)
}

@(private)
scalar_check_string :: proc(e: ^Scalar_Env, rule_idx: i32, s: string, at: u64) -> bool {
	if rule_idx <= 0 { return true }
	leaf := &e.plan.leaves[rule_idx - 1]; rs: ^regex.Scratch
	if leaf.pattern != nil { if e.stream != nil && !stream_ensure_re(e.stream) { return false }; rs = e.re_scratch }
	fails, _ := rules.judge_string(leaf, s, rs, 0, e.scratch)
	return scalar_emit_fails(e, leaf, fails, at)
}

@(private)
scalar_check_number :: proc(e: ^Scalar_Env, rule_idx: i32, text: string, small: Maybe(i64), at: u64) -> bool {
	if rule_idx <= 0 { return true }
	leaf := &e.plan.leaves[rule_idx - 1]
	return scalar_emit_fails(e, leaf, rules.judge_number(leaf, text, small), at)
}

@(private)
decode_time_stored :: proc(e: ^Scalar_Env, tm: time.Time, dest: rawptr, rule_idx: i32, at: u64) -> bool {
	(^time.Time)(dest)^ = tm
	if rule_idx <= 0 { return true }
	fbuf: [40]u8 = ---
	if canon, cok := format_rfc3339_utc(tm, &fbuf); cok { return scalar_check_string(e, rule_idx, canon, at) }
	return true
}

@(private)
decode_scalar_common :: proc(e: ^Scalar_Env, tn: ^Type_Node, dest: rawptr, rule_idx: i32, not_null: bool, at: u64, vk: Scalar_Kind, text: string) -> bool {
	if (tn.kind == .Cstring || tn.kind == .Number_Text) && vk == .Null {
		if not_null { _ = scalar_fail(e, .Wrong_Kind, at, {tn.type, scalar_want_text(e.plan, tn)}); return false }
		return true
	}
	want_num := (tn.kind >= .I8 && tn.kind <= .F64) || tn.kind == .Number_Text || (tn.kind == .Enum && !e.plan.enums[tn.enum_idx].by_name)
	want_str := tn.kind == .String || tn.kind == .Email || tn.kind == .Cstring || tn.kind == .Bytes || tn.kind == .Uuid || tn.kind == .Base64 || tn.kind == .Hex || tn.kind == .Time || (tn.kind == .Enum && e.plan.enums[tn.enum_idx].by_name)
	if (want_num || tn.kind == .Decimal) && vk == .Non_Finite { _ = scalar_fail(e, .Non_Finite, at); return false }
	if (want_num && vk != .Number) || (want_str && vk != .String) || (tn.kind == .Decimal && vk != .Number && vk != .String) || ((tn.kind == .Bool || tn.kind == .Bool_Wide) && vk != .True && vk != .False) {
		_ = scalar_fail(e, .Wrong_Kind, at, {tn.type, scalar_want_text(e.plan, tn)}); return false
	}

	#partial switch tn.kind {
	case .Bool, .Bool_Wide:
		bv := vk == .True
		switch tn.size {
		case 1: (^bool)(dest)^ = bv
		case 2: (^b16)(dest)^ = b16(bv)
		case 4: (^b32)(dest)^ = b32(bv)
		case 8: (^b64)(dest)^ = b64(bv)
		}
		return true
	case .String, .Email, .Cstring, .Bytes, .Uuid, .Base64, .Hex:
		if !scalar_check_string(e, rule_idx, text, at) { return false }
		ck := Error_Kind.None
		#partial switch tn.kind {
		case .String, .Email:
			if (e.first.kind == .None || e.has_val) && len(text) > 0 { cl, cerr := strings.clone(text, e.allocator); if cerr != nil { e.oom^ = true; return false }; (^string)(dest)^ = cl; e.wrote = true }
		case .Cstring:
			if e.first.kind == .None || e.has_val { cs, cerr := strings.clone_to_cstring(text, e.allocator); if cerr != nil { e.oom^ = true; return false }; (^cstring)(dest)^ = cs; e.wrote = true }
		case .Uuid:
			id: uuid.Identifier; id, ck = decode_uuid(text); if ck == .None && (e.first.kind == .None || e.has_val) { (^uuid.Identifier)(dest)^ = id }
		case .Hex:
			hx: Hex; hx, ck = decode_hex(text, e.allocator); if ck == .None { (^Hex)(dest)^ = hx; if len(hx) > 0 { e.wrote = true } }
		case .Bytes, .Base64:
			b64: Base64; b64, ck = decode_base64(text, e.allocator); if ck == .None { if tn.kind == .Bytes { (^[]u8)(dest)^ = ([]u8)(b64) } else { (^Base64)(dest)^ = b64 }; if len(b64) > 0 { e.wrote = true } }
		}
		if ck == .No_Memory { e.oom^ = true; return false }
		if ck != .None { _ = scalar_fail(e, ck, at); return false }
		return true
	case .I8 ..= .U64:
		small, k := parse_int_decimal(tn, text, dest)
		if k != .None { _ = scalar_fail(e, k, at, {tn.type, type_name_short(tn.ti)} if k == .Wrong_Kind else {}); return false }
		return scalar_check_number(e, rule_idx, text, small, at)
	case .F32, .F64:
		bad := false
		if tn.kind == .F32 { v, fok := strconv.parse_f32(text); bad = !fok || math.is_nan(v) || math.is_inf(v, 0); if !bad { (^f32)(dest)^ = v } } else { v, fok := strconv.parse_f64(text); bad = !fok || math.is_nan(v) || math.is_inf(v, 0); if !bad { (^f64)(dest)^ = v } }
		if bad { _ = scalar_fail(e, .Below_Minimum if strings.has_prefix(text, "-") else .Above_Maximum, at); return false }
		return scalar_check_number(e, rule_idx, text, nil, at)
	case .Number_Text, .Decimal:
		if tn.kind == .Decimal && vk == .String && (!rules.valid_decimal_text(text) || !scalar_check_string(e, rule_idx, text, at)) {
			if !rules.valid_decimal_text(text) { _ = scalar_fail(e, .No_Match, at) }
			return false
		}
		if !scalar_check_number(e, rule_idx, text, nil, at) { return false }
		if e.first.kind == .None || e.has_val {
			cl, cerr := strings.clone(text, e.allocator); if cerr != nil { e.oom^ = true; return false }
			(^Number_Text)(dest)^ = {text = cl, value = parse_f64_approx(cl)}; e.wrote = true
		}
		return true
	case .Time:
		tm, tk := decode_time(text, e.opt_sec); if tk != .None { _ = scalar_fail(e, tk, at); return false }
		return decode_time_stored(e, tm, dest, rule_idx, at)
	case .Enum:
		if k := parse_enum_text(&e.plan.enums[tn.enum_idx], tn.size, text, dest, true); k != .None {
			_ = scalar_fail(e, k, at, {tn.type, "integer"} if k == .Wrong_Kind else {}); return false
		}
		return true
	}
	_ = scalar_fail(e, .Unsupported, at)
	return false
}

@(private)
decode_scalar :: proc(l: ^Loader, tn: ^Type_Node, v: rules.Value, dest: rawptr, rule_idx: i32, not_null: bool, at: u64) {
	vk := rules.value_kind(v)
	env := Scalar_Env{plan = l.plan, re_scratch = &l.re_scratch, steps = l.steps[:], sink = l.sink, first = &l.first, oom = &l.oom, fail_count = &l.fail_count, allocator = l.allocator, scratch = l.scratch, silent = l.silent, secret = l.secret_depth > 0, has_val = l.sink != nil && !l.silent}
	buf: [256]u8 = ---
	#partial switch tn.kind {
	case .Bytes:
		if ref, is_ref := v.(rules.Node_Ref); is_ref && ref.doc != nil && int(ref.node) < len(ref.doc.nodes) && ref.doc.nodes[ref.node].kind == .Bytes {
			s, owned, ok := rules.value_string(v, buf[:], l.scratch); defer if owned { delete(s, l.scratch) }
			if !ok { l.oom = true; return }
			if len(s) > 0 { cp, cerr := make([]u8, len(s), l.allocator); if cerr != nil { l.oom = true; return }; copy(cp, s); (^[]u8)(dest)^ = cp }
			return
		}
	case .Time:
		if ref, is_ref := v.(rules.Node_Ref); is_ref && ref.doc != nil && ref.doc.format != nil { env.opt_sec = ref.doc.format.id == tape.FORMAT_ID_TOML + 1 }
		if vk == .Number {
			tm: time.Time; tk := Error_Kind.Wrong_Kind
			if ref, is_ref := v.(rules.Node_Ref); is_ref && ref.doc != nil && int(ref.node) < len(ref.doc.nodes) {
				for fact in tape.facts_of(ref.doc, ref.node) {
					if fact.kind == .Tag {
						if tn_num, tok := tape.fact_number(ref.doc, fact); tok && (tn_num.kind == .Uint || tn_num.kind == .Int) && tn_num.bits == 1 {
							if num, nok := tape.node_number(ref.doc, ref.node); nok { tm, tk = decode_epoch_time(num) }
							break
						}
					}
				}
			}
			if tk != .None { _ = loader_fail(l, tk, at, "", {type = tn.type, text = "date-time"} if tk == .Wrong_Kind else {}); return }
			_ = decode_time_stored(&env, tm, dest, rule_idx, at); return
		}
	case .Bit_Set: decode_bit_set(l, tn, v, dest, rule_idx, at); return
	case .Raw:
		if ref, is_ref := v.(rules.Node_Ref); is_ref && ref.doc != nil && int(ref.node) < len(ref.doc.nodes) {
			n := ref.doc.nodes[ref.node]; sb, eb := n.lo, n.lo + u64(n.n)
			if n.kind >= .Array && ref.doc.format != nil && ref.doc.format.close_end != nil { if ce, cok := ref.doc.format.close_end(ref.doc, ref.node); cok { eb = ce } } else if n.kind < .Array && ref.doc.format != nil && ref.doc.format.bounds != nil { head, tail := ref.doc.format.bounds(ref.doc.src, n); sb, eb = n.lo - u64(head), n.lo + u64(n.n) + u64(tail) }
			if sb <= eb && eb <= u64(len(ref.doc.src)) { raw_s, cerr := strings.clone(string(ref.doc.src[sb:eb]), l.allocator); if cerr != nil { l.oom = true; return }; (^typed.Raw)(dest)^ = typed.Raw(raw_s) }
		}
		return
	case .Value: cv, cerr := clone_rules_value(v, l.allocator, l.scratch); if cerr != nil { l.oom = true; return }; (^rules.Value)(dest)^ = cv; return
	}

	sk, text, owned := Scalar_Kind.Wrong, "", false
	if (tn.kind == .Cstring || tn.kind == .Number_Text) && (vk == .Null || is_empty_dsv_cell(v)) {
		sk = .Null
	} else if tn.kind == .Bool || tn.kind == .Bool_Wide {
		if vk == .True || vk == .False { sk = .True if vk == .True else .False } else if is_dsv_ref(v) && vk == .String {
			if bs, bown, bok := rules.value_string(v, buf[:8], l.scratch); bok {
				if bs == "true" || bs == "false" { sk = .True if bs == "true" else .False }
				if bown { delete(bs, l.scratch) }
			}
		}
	} else if (tn.kind >= .I8 && tn.kind <= .F64) || tn.kind == .Number_Text || (tn.kind == .Enum && !l.plan.enums[tn.enum_idx].by_name) || (tn.kind == .Decimal && vk == .Number) {
		nf, nok: bool; text, owned, nok, nf = extract_number_text(l, v, buf[:])
		if l.oom { if owned { delete(text, l.scratch) }; return }
		sk = .Non_Finite if nf else (.Number if nok else .Wrong)
	} else {
		sok: bool; text, owned, sok = extract_string(l, v, buf[:])
		if l.oom { if owned { delete(text, l.scratch) }; return }
		if sok { sk = .String }
	}
	defer if owned { delete(text, l.scratch) }
	_ = decode_scalar_common(&env, tn, dest, rule_idx, not_null, at, sk, text)
}

@(private)
parse_int_decimal :: proc(tn: ^Type_Node, text: string, dest: rawptr) -> (small: Maybe(i64), kind: Error_Kind) {
	if !rules.valid_decimal_text(text) { return nil, .Wrong_Kind }
	d := rules.decimal_of(text); if !rules.integral(d) { return nil, .Wrong_Kind }
	lim := LIMITS[int(tn.kind) - int(Type_Kind.I8)]
	if rules.decimal_compare(d, rules.decimal_of(lim[0])) < 0 { return nil, .Below_Minimum }
	if rules.decimal_compare(d, rules.decimal_of(lim[1])) > 0 { return nil, .Above_Maximum }
	if tn.kind <= .I64 { iv, _ := rules.decimal_i64(d); small = iv; stream_store_int(uintptr(dest), u64(iv), tn.kind) } else {
		uv := u64(0); if iv, fits := rules.decimal_i64(d); fits && iv >= 0 { uv, small = u64(iv), iv } else { uv = decimal_u64(d) }
		stream_store_int(uintptr(dest), uv, tn.kind)
	}
	return small, .None
}

@(private)
parse_enum_text :: proc(ei: ^Enum_Info, size: int, text: string, dest: rawptr, allow_decimal: bool) -> Error_Kind {
	if ei.by_name {
		for name, i in ei.names { if name == text { store_enum_value(dest, size, ei.values[i]); return .None } }
		return .Not_A_Member
	}
	if allow_decimal {
		d := rules.decimal_of(text); if !rules.integral(d) { return .Wrong_Kind }
		if ei.is_unsigned {
			if !d.neg && rules.decimal_compare(d, rules.decimal_of("18446744073709551615")) <= 0 {
				uv := decimal_u64(d); for ev in ei.values { if u64(ev) == uv { store_enum_value(dest, size, i64(uv)); return .None } }
			}
		} else if iv, fits := rules.decimal_i64(d); fits {
			for ev in ei.values { if ev == iv { store_enum_value(dest, size, iv); return .None } }
		}
		return .Not_A_Member
	}
	if ei.is_unsigned {
		uv, ok := strconv.parse_u64_of_base(text, 10); if !ok { return .Wrong_Kind }
		for ev in ei.values { if u64(ev) == uv { store_enum_value(dest, size, i64(uv)); return .None } }
	} else {
		iv, ok := strconv.parse_i64_of_base(text, 10); if !ok { return .Wrong_Kind }
		for ev in ei.values { if ev == iv { store_enum_value(dest, size, iv); return .None } }
	}
	return .Not_A_Member
}

@(private)
parse_map_key_text :: proc(plan: ^Type_Plan, key_tn: ^Type_Node, text: string, dest: rawptr, allocator: runtime.Allocator) -> Error_Kind {
	#partial switch key_tn.kind {
	case .String:      s, err := strings.clone(text, allocator); if err != nil { return .No_Memory }; (^string)(dest)^ = s; return .None
	case .Cstring:     cs, err := strings.clone_to_cstring(text, allocator); if err != nil { return .No_Memory }; (^cstring)(dest)^ = cs; return .None
	case .Enum:        return parse_enum_text(&plan.enums[key_tn.enum_idx], key_tn.size, text, dest, false)
	case .I8 ..= .U64: _, k := parse_int_decimal(key_tn, text, dest); return k
	}
	return .Unsupported
}

@(private)
decode_map_key :: proc(l: ^Loader, key_tn: ^Type_Node, text: string, dest: rawptr, at: u64) -> bool {
	k := parse_map_key_text(l.plan, key_tn, text, dest, l.allocator)
	if k == .None { return true }
	if k == .No_Memory { l.oom = true; return false }
	return loader_fail(l, k, at, "", {key_tn.type, type_name_short(key_tn.ti)} if (k == .Wrong_Kind && key_tn.kind >= .I8 && key_tn.kind <= .U64) else {})
}

@(private)
decimal_u64 :: proc "contextless" (d: rules.Decimal) -> u64 {
	if d.head == "" || d.neg { return 0 }
	n := u64(0)
	for i in 0 ..< int(d.point) { ch := d.head[i] if i < len(d.head) else (d.tail[i - len(d.head)] if i - len(d.head) < len(d.tail) else u8('0')); n = n * 10 + u64(ch - '0') }
	return n
}

@(private)
store_enum_value :: proc(dest: rawptr, size: int, val: i64) { v := val; mem.copy(dest, &v, min(size, size_of(i64))) }

@(private)
decode_bit_set :: proc(l: ^Loader, tn: ^Type_Node, v: rules.Value, dest: rawptr, rule_idx: i32, at: u64) {
	if rules.value_kind(v) != .Array { _ = loader_fail(l, .Wrong_Kind, at, "", {type = tn.type, text = "array"}); return }
	elems, ok := extract_array(v, l.scratch); if !ok { l.oom = true; return }
	if !check_count_leaf(l.plan, rule_idx, u64(len(elems)), false, at, l.steps[:], l.sink, &l.first, &l.oom, l.allocator, l.scratch, l.silent, l.secret_depth > 0) {
		l.fail_count += 1; if loader_stopped(l) { return }
	}
	bytes := ([^]u8)(dest)[:tn.size]; buf: [128]u8 = ---
	for elem, i in elems {
		if !push_oom(&l.oom, &l.steps, tape.Step(tape.Index(i))) { return }
		bit_val: i64; fail_kind := Error_Kind.None
		if tn.enum_idx >= 0 && l.plan.enums[tn.enum_idx].by_name {
			s, owned, sok := extract_string(l, elem, buf[:])
			if !sok { fail_kind = .Wrong_Kind } else {
				ei, found := &l.plan.enums[tn.enum_idx], false
				for name, k in ei.names { if name == s { bit_val, found = ei.values[k], true; break } }
				if !found { fail_kind = .Not_A_Member }
			}
			if owned { delete(s, l.scratch) }
		} else {
			ns, owned, nok, nf := extract_number_text(l, elem, buf[:])
			if nf { fail_kind = .Non_Finite } else if !nok { fail_kind = .Wrong_Kind } else {
				d := rules.decimal_of(ns); iv, fits := rules.decimal_i64(d)
				if !rules.integral(d) || !fits { fail_kind = .Not_A_Member } else if tn.enum_idx >= 0 {
					found := false; for ev in l.plan.enums[tn.enum_idx].values { if ev == iv { bit_val, found = iv, true; break } }; if !found { fail_kind = .Not_A_Member }
				} else if iv < tn.bit_lower || iv >= tn.bit_lower + i64(tn.count) { fail_kind = .Not_A_Member } else { bit_val = iv }
			}
			if owned { delete(ns, l.scratch) }
		}
		if fail_kind != .None { if !l.oom { _ = loader_fail(l, fail_kind, value_offset(elem)) }; pop(&l.steps); if loader_stopped(l) { return }; continue }
		pop(&l.steps)
		bit_idx := u64(bit_val - tn.bit_lower); bytes[bit_idx / 8] |= u8(1) << uint(bit_idx % 8)
	}
}

@(private)
probe_union_arm :: proc(l: ^Loader, arm_node: i32, v: rules.Value, probe_buf: []u8, rule_idx: i32) -> bool {
	mem.zero(raw_data(probe_buf), len(probe_buf))
	probe, mk_err := loader_make(l.plan, l.judging, l.policy, l.budget.limit, nil, l.scratch, l.scratch, true, l.validators)
	if mk_err != nil { l.oom = true; return false }
	probe.budget.depth = l.budget.depth
	decode_loop(&probe, arm_node, v, raw_data(probe_buf), nil, nil, rule_idx)
	oom, exc, ok := probe.oom, probe.budget.exceeded, !probe.oom && probe.budget.exceeded.kind == .None && probe.first.kind == .None
	loader_cleanup(&probe)
	if oom { l.oom = true; return false }
	if exc.kind != .None { l.budget.exceeded = exc; return false }
	return ok
}

@(private)
decode_union_push :: proc(l: ^Loader, stack: ^[dynamic]Load_Frame, node_idx: i32, tn: ^Type_Node, v: rules.Value, dest: rawptr, rule_idx: i32, at: u64) {
	u, vk := &l.plan.unions[tn.union_idx], rules.value_kind(v)
	if vk == .Null || is_empty_dsv_cell(v) { if u.no_nil { _ = loader_fail(l, .Wrong_Kind, at, "", {type = tn.type, text = "non-null"}) }; return }
	push_arm :: proc(l: ^Loader, stack: ^[dynamic]Load_Frame, node_idx: i32, tn: ^Type_Node, u: ^Union_Info, arm: Union_Arm, v: rules.Value, dest: rawptr, rule_idx: i32, skip_tag: string) {
		if tn.judged && !push_oom(&l.oom, stack, Load_Frame{kind = .Run_Judged, node_idx = node_idx, val = v}) { return }
		if !push_oom(&l.oom, stack, Load_Frame{kind = .Union_Tag, dest = dest, tag_offset = u.tag_offset, tag_size = u.tag_size, tag_value = arm.tag_value, start_fails = l.fail_count}) { return }
		_ = push_oom(&l.oom, stack, Load_Frame{kind = .Node, node_idx = arm.node, val = v, dest = dest, field_rule_idx = rule_idx, skip_tag_key = skip_tag})
	}
	if u.mode == .Tag && vk == .Object && u.tag_key != "" {
		entries, ok := extract_object(l, v); if !ok { return }
		tag_name, has_tag := "", false; buf: [128]u8 = ---
		for e in entries {
			if e.key == u.tag_key {
				if ts, towned, tok := extract_string(l, e.val, buf[:]); tok {
					if towned { tag_name = ts } else { cl, cerr := strings.clone(ts, l.scratch); if cerr != nil { l.oom = true; return }; tag_name = cl }
					has_tag = true
				}
				break
			}
		}
		if has_tag { for arm in u.arms { if arm.is_struct && arm.name == tag_name { push_arm(l, stack, node_idx, tn, u, arm, v, dest, rule_idx, u.tag_key); return } } }
		_ = loader_fail(l, .No_Arm, at); return
	}
	if u.mode == .Tag {
		first_match, kind_matches := -1, 0
		for arm, ai in u.arms { if arm_matches_kind(l.plan, arm.node, vk) { if first_match < 0 { first_match = ai }; kind_matches += 1 } }
		if kind_matches == 0 { _ = loader_fail(l, .No_Arm, at); return }
		if kind_matches == 1 { push_arm(l, stack, node_idx, tn, u, u.arms[first_match], v, dest, rule_idx, ""); return }
	}
	probe_buf, perr := runtime.mem_alloc(max(tn.size, 1), tn.align, l.scratch); if perr != nil { l.oom = true; return }
	matched, matches := -1, 0
	for arm, ai in u.arms {
		if u.mode == .Tag && !arm_matches_kind(l.plan, arm.node, vk) { continue }
		if probe_union_arm(l, arm.node, v, probe_buf, rule_idx) { if matched < 0 { matched = ai }; matches += 1; if u.mode != .One_Match { break } }
		if l.oom || l.budget.exceeded.kind != .None { return }
	}
	if matches == 0 { _ = loader_fail(l, .No_Arm, at); return }
	if u.mode == .One_Match && matches > 1 { _ = loader_fail(l, .Many_Arms, at); return }
	push_arm(l, stack, node_idx, tn, u, u.arms[matched], v, dest, rule_idx, "")
}

@(private)
arm_matches_kind :: proc(plan: ^Type_Plan, node_idx: i32, vk: rules.Value_Kind) -> bool {
	for cur := node_idx; cur >= 0; {
		tn := &plan.nodes[cur]
		#partial switch tn.kind {
		case .Maybe, .Ptr, .Custom:                             cur = tn.child; continue
		case .Struct, .Map:                                     return vk == .Object
		case .Slice, .Dynamic, .Array, .Fixed_List, .Bit_Set:   return vk == .Array
		case .Bool, .Bool_Wide:                                 return vk == .True || vk == .False
		case .I8 ..= .F64, .Number_Text:                        return vk == .Number
		case .Decimal:                                          return vk == .Number || vk == .String
		case .String, .Cstring, .Bytes, .Email, .Time, .Uuid, .Base64, .Hex: return vk == .String
		case .Enum:                                             return vk == .String if plan.enums[tn.enum_idx].by_name else vk == .Number
		case .Raw, .Value:                                      return true
		}
		break
	}
	return false
}

@(private)
run_node_judged :: proc(l: ^Loader, tn: ^Type_Node, unique: bool, v: rules.Value) -> bool {
	if l.judging == nil { return true }
	j := judged_of(l.judging, tn.type, unique); if j == nil && unique { j = judged_of(l.judging, tn.type, false) }; if j == nil { return true }
	return run_judged_on_value(j, v, l.policy, l.budget.limit, l.steps[:], l.sink, &l.first, &l.oom, &l.budget.exceeded, l.allocator, l.scratch, l.silent, l.secret_depth > 0)
}
