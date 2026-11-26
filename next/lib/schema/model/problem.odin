// Structured model errors, sink, and RFC 9457 Problem documents.
package model

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"

Error_Kind :: enum u8 {
	None, Wrong_Kind, Not_Allowed, Below_Minimum, Above_Maximum, Not_Multiple,
	Too_Short, Too_Long, No_Match, Pattern_Undecided, Bad_Format,
	Too_Few, Too_Many, Not_Unique, Not_A_Member, Missing_Field,
	No_Arm, Many_Arms, Duplicate_Key, Non_Finite, Bad_Tag, Custom,
	Check_Failed, Exceeded, Walk, No_Memory, Bad_Option, Unsupported,
}

Want :: struct {
	type: typeid,
	text: string,
}

Error_Entry :: struct {
	kind:    Error_Kind,
	at:      u64,
	path:    []tape.Step,
	pointer: string,
	operand: string,
	want:    Want,
}

// Structured error returned by model operations. Borrows from `Sink` (`owned == false`) when a sink was
// provided; otherwise owns any allocated strings (`owned == true`), freed by `error_destroy` / `destroy`.
Model_Error :: struct {
	kind:    Error_Kind,
	at:      u64,
	pointer: string,
	operand: string,
	want:    Want,
	owned:   bool,
}

Error :: union {
	Model_Error,
	tape.Error,
	write.Error,
	runtime.Allocator_Error,
}

// Frees heap strings owned by a `Model_Error` inside `err` (a no-op when borrowed from a `Sink` or static).
error_destroy :: proc(err: Error, allocator := context.allocator) {
	me, ok := err.(Model_Error)
	if !ok || !me.owned {
		return
	}
	delete(me.pointer, allocator)
	delete(me.operand, allocator)
	delete(me.want.text, allocator)
}

// Collects every validation/load failure up to `max_errors` (0 = unlimited) in a `mem.Dynamic_Arena`.
Sink :: struct {
	entries:     [dynamic]Error_Entry,
	max_errors:  int,
	truncated:   bool,
	allocator:   runtime.Allocator,
	arena:       mem.Dynamic_Arena,
	arena_ready: bool,
	arena_dirty: bool,
	oom:         bool,
}

sink_init :: proc(s: ^Sink, allocator := context.allocator, max_errors := 0) {
	s^ = {max_errors = max_errors, allocator = allocator}
	s.entries.allocator = allocator
	mem.dynamic_arena_init(&s.arena, allocator, allocator)
	s.arena_ready = true
}

sink_destroy :: proc(s: ^Sink) {
	if s == nil {
		return
	}
	delete(s.entries)
	if s.arena_ready {
		mem.dynamic_arena_destroy(&s.arena)
	}
	s^ = {}
}

sink_clear :: proc(s: ^Sink) {
	if s == nil {
		return
	}
	if len(s.entries) > 0 {
		clear(&s.entries)
	}
	if s.arena_dirty && s.arena_ready {
		mem.dynamic_arena_reset(&s.arena)
		s.arena_dirty = false
	}
	s.truncated, s.oom = false, false
}

@(private)
sink_ensure :: proc(s: ^Sink, fallback: runtime.Allocator) -> runtime.Allocator {
	if s.allocator.procedure == nil {
		s.allocator, s.entries.allocator = fallback, fallback
	}
	if !s.arena_ready {
		mem.dynamic_arena_init(&s.arena, s.allocator, s.allocator)
		s.arena_ready = true
	}
	return mem.dynamic_arena_allocator(&s.arena)
}

@(private)
sink_push :: proc(s: ^Sink, fallback: runtime.Allocator, kind: Error_Kind, at: u64, steps: []tape.Step, operand := "", want := Want{}) -> bool {
	if s == nil {
		return false
	}
	if s.max_errors > 0 && len(s.entries) >= s.max_errors {
		s.truncated = true
		return false
	}
	arena := sink_ensure(s, fallback)
	s.arena_dirty = true
	entry, err := make_sink_entry(arena, kind, at, steps, operand, want)
	if err != nil {
		s.oom = true
		return false
	}
	if _, aerr := append(&s.entries, entry); aerr != nil {
		s.oom = true
		return false
	}
	return true
}

@(private)
format_pointer_fast :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	if len(steps) == 0 { return "", nil }
	// Fast path: check if any step needs RFC 6901 `~` / `/` escaping or integer formatting.
	n := 0
	simple := true
	for s in steps {
		if nm, is_nm := s.(tape.Name); is_nm {
			n += 1 + len(string(nm))
			for c in transmute([]u8)string(nm) {
				if c == '~' || c == '/' { simple = false; break }
			}
		} else {
			simple = false
			break
		}
	}
	if !simple {
		return check.format_pointer(steps, allocator)
	}
	buf, err := runtime.mem_alloc_non_zeroed(n, 1, allocator)
	if err != nil { return "", err }
	pos := 0
	for s in steps {
		nm := string(s.(tape.Name))
		buf[pos] = '/'
		pos += 1
		if len(nm) > 0 {
			copy(buf[pos:], nm)
			pos += len(nm)
		}
	}
	return string(buf[:n]), nil
}

@(private)
make_sink_entry :: proc(arena: runtime.Allocator, kind: Error_Kind, at: u64, steps: []tape.Step, operand: string, want: Want) -> (e: Error_Entry, err: runtime.Allocator_Error) {
	e = {kind = kind, at = at, want = {type = want.type}}
	e.pointer = format_pointer_fast(steps, arena) or_return
	e.path = clone_steps(steps, arena) or_return
	if len(operand) > 0 {
		e.operand = strings.clone(operand, arena) or_return
	}
	if len(want.text) > 0 {
		e.want.text = strings.clone(want.text, arena) or_return
	}
	return e, nil
}

// Central failure recorder: pushes into `sink` (borrowing its arena strings for `first` with zero UAF)
// or allocates owned `first` strings in `allocator` when `sink == nil`.
@(private)
record_failure :: proc(
	sink: ^Sink, first: ^Model_Error, oom: ^bool, allocator: runtime.Allocator,
	kind: Error_Kind, at: u64, steps: []tape.Step, operand := "", want := Want{}, silent := false,
) -> bool {
	if silent {
		if first.kind == .None {
			first^ = {kind = kind, at = at}
		}
		return false
	}
	if sink != nil {
		prev := len(sink.entries)
		pushed := sink_push(sink, allocator, kind, at, steps, operand, want)
		if sink.oom {
			if oom != nil {
				oom^ = true
			}
			return false
		}
		if first.kind == .None {
			if len(sink.entries) > prev {
				e := sink.entries[len(sink.entries) - 1]
				first^ = {kind = e.kind, at = e.at, pointer = e.pointer, operand = e.operand, want = e.want}
			} else {
				first^ = make_owned_error(kind, at, steps, operand, want, allocator, oom)
			}
		}
		return pushed
	}
	if first.kind == .None {
		first^ = make_owned_error(kind, at, steps, operand, want, allocator, oom)
	}
	return false
}

@(private)
make_owned_error :: proc(kind: Error_Kind, at: u64, steps: []tape.Step, operand: string, want: Want, allocator: runtime.Allocator, oom: ^bool) -> Model_Error {
	ptr, op, wt: string
	if len(steps) > 0 {
		p, err := format_pointer_fast(steps, allocator)
		if err != nil {
			if oom != nil { oom^ = true }
			return {kind = kind, at = at}
		}
		ptr = p
	}
	if len(operand) > 0 {
		o, err := strings.clone(operand, allocator)
		if err != nil {
			delete(ptr, allocator)
			if oom != nil { oom^ = true }
			return {kind = kind, at = at}
		}
		op = o
	}
	if len(want.text) > 0 {
		w, err := strings.clone(want.text, allocator)
		if err != nil {
			delete(ptr, allocator); delete(op, allocator)
			if oom != nil { oom^ = true }
			return {kind = kind, at = at}
		}
		wt = w
	}
	return {kind = kind, at = at, pointer = ptr, operand = op, want = {want.type, wt}, owned = len(ptr) > 0 || len(op) > 0 || len(wt) > 0}
}

@(private)
clone_steps :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> (out: []tape.Step, err: runtime.Allocator_Error) {
	if len(steps) == 0 {
		return nil, nil
	}
	out = make([]tape.Step, len(steps), allocator) or_return
	for s, i in steps {
		#partial switch v in s {
		case tape.Name:  out[i] = tape.Name(strings.clone(string(v), allocator) or_return)
		case tape.Index: out[i] = v
		}
	}
	return out, nil
}

@(private)
order_sink :: proc(s: ^Sink, from: int) {
	if s == nil || len(s.entries) - from <= 1 {
		return
	}
	slice.sort_by(s.entries[from:], proc(a, b: Error_Entry) -> bool {
		if a.at != b.at { return a.at < b.at }
		if c := strings.compare(a.pointer, b.pointer); c != 0 { return c < 0 }
		if a.kind != b.kind { return a.kind < b.kind }
		return strings.compare(a.operand, b.operand) < 0
	})
}

@(private, rodata)
RULES_KIND_MAP := [rules.Error_Kind]Error_Kind{
	.None = .None, .Wrong_Kind = .Wrong_Kind, .Not_Allowed = .Not_Allowed,
	.Below_Minimum = .Below_Minimum, .Above_Maximum = .Above_Maximum, .Not_Multiple = .Not_Multiple,
	.Too_Short = .Too_Short, .Too_Long = .Too_Long, .No_Match = .No_Match,
	.Pattern_Undecided = .Pattern_Undecided, .Bad_Format = .Bad_Format,
	.Too_Few = .Too_Few, .Too_Many = .Too_Many, .Not_Unique = .Not_Unique,
	.Not_A_Member = .Not_A_Member, .Missing_Field = .Missing_Field,
	.No_Arm = .No_Arm, .Many_Arms = .Many_Arms, .Duplicate_Key = .Duplicate_Key,
	.Exceeded = .Exceeded, .Walk = .Walk, .No_Memory = .No_Memory,
	.Bad_Option = .Bad_Option, .Unsupported = .Unsupported,
}

@(private)
map_rules_kind :: proc "contextless" (k: rules.Error_Kind) -> Error_Kind {
	return RULES_KIND_MAP[k] if k <= max(rules.Error_Kind) else .Wrong_Kind
}

@(private, rodata)
ERROR_CODES := [Error_Kind]string{
	.None = "none", .Wrong_Kind = "wrong_kind", .Not_Allowed = "not_allowed",
	.Below_Minimum = "below_minimum", .Above_Maximum = "above_maximum", .Not_Multiple = "not_multiple",
	.Too_Short = "too_short", .Too_Long = "too_long", .No_Match = "no_match",
	.Pattern_Undecided = "pattern_undecided", .Bad_Format = "bad_format",
	.Too_Few = "too_few", .Too_Many = "too_many", .Not_Unique = "not_unique",
	.Not_A_Member = "not_a_member", .Missing_Field = "missing_field",
	.No_Arm = "no_arm", .Many_Arms = "many_arms", .Duplicate_Key = "duplicate_key",
	.Non_Finite = "non_finite", .Bad_Tag = "bad_tag", .Custom = "custom",
	.Check_Failed = "check_failed", .Exceeded = "exceeded", .Walk = "walk",
	.No_Memory = "no_memory", .Bad_Option = "bad_option", .Unsupported = "unsupported",
}

@(private, rodata)
ERROR_MESSAGES := [Error_Kind]string{
	.None = "No error", .Wrong_Kind = "Value does not fit the field's type",
	.Not_Allowed = "Field is not allowed", .Below_Minimum = "Number is below minimum",
	.Above_Maximum = "Number is above maximum", .Not_Multiple = "Number is not a multiple",
	.Too_Short = "String is too short", .Too_Long = "String is too long",
	.No_Match = "String does not match pattern", .Pattern_Undecided = "Pattern evaluation exceeded step limit",
	.Bad_Format = "String does not match required format", .Too_Few = "Too few items",
	.Too_Many = "Too many items", .Not_Unique = "Items must be unique",
	.Not_A_Member = "Value is not an allowed member", .Missing_Field = "Required field is missing",
	.No_Arm = "Value matches no union arm", .Many_Arms = "Value matches more than one union arm",
	.Duplicate_Key = "Duplicate key", .Non_Finite = "Number is not finite",
	.Bad_Tag = "Invalid model tag or rule", .Custom = "Validation failed",
	.Check_Failed = "Validation check failed", .Exceeded = "Budget exceeded",
	.Walk = "Parse error", .No_Memory = "Out of memory",
	.Bad_Option = "Invalid option", .Unsupported = "Unsupported operation",
}

error_code :: proc "contextless" (kind: Error_Kind) -> string {
	return ERROR_CODES[kind] if kind <= max(Error_Kind) else "unknown"
}

entry_message :: proc(e: Error_Entry, allocator := context.allocator) -> (msg: string, err: runtime.Allocator_Error) {
	if e.kind == .Custom && len(e.want.text) > 0 {
		return strings.clone(e.want.text, allocator)
	}
	b := strings.builder_make(0, 64, allocator) or_return
	strings.write_string(&b, ERROR_MESSAGES[e.kind] if e.kind <= max(Error_Kind) else "Validation failed")
	if len(e.operand) > 0 {
		strings.write_string(&b, ", "); strings.write_string(&b, e.operand)
	} else if len(e.want.text) > 0 {
		strings.write_string(&b, ", expected "); strings.write_string(&b, e.want.text)
	}
	return strings.to_string(b), nil
}

Problem :: struct {
	type:   string `stury:"type,omitempty"`,
	title:  string,
	status: int,
	errors: []Problem_Error,
}

Problem_Error :: struct {
	pointer: string,
	code:    string,
	message: string,
}

problem :: proc(entries: []Error_Entry, title: string, status: int, type := "", allocator := context.allocator) -> (p: Problem, err: runtime.Allocator_Error) {
	p = {type = type, title = title, status = status}
	p.errors = make([]Problem_Error, len(entries), allocator) or_return
	defer if err != nil {
		problem_destroy(p, allocator)
	}
	for e, i in entries {
		p.errors[i] = {
			code    = error_code(e.kind),
			pointer = strings.clone(e.pointer, allocator) or_return,
			message = entry_message(e, allocator) or_return,
		}
	}
	return p, nil
}

problem_destroy :: proc(p: Problem, allocator := context.allocator) {
	for e in p.errors {
		delete(e.pointer, allocator)
		delete(e.message, allocator)
	}
	delete(p.errors, allocator)
}

write_problem_tokens :: proc(t: ^write.Token_Tape, entries: []Error_Entry, p: Problem, truncated := false, scratch := context.allocator) -> write.Error {
	kv :: proc(t: ^write.Token_Tape, k: string, kind: write.Token_Kind, v: string) -> write.Error {
		write.token_tape_take(t, .Key, k) or_return
		return write.token_tape_take(t, kind, v)
	}
	write.token_tape_take(t, .Object, "") or_return
	if p.type != "" {
		kv(t, "type", .String, p.type) or_return
	}
	kv(t, "title", .String, p.title) or_return
	sbuf: [24]u8 = ---
	kv(t, "status", .Number, strconv.write_int(sbuf[:], i64(p.status), 10)) or_return
	kv(t, "errors", .Array, "") or_return
	for e in entries {
		write.token_tape_take(t, .Object, "") or_return
		kv(t, "pointer", .String, e.pointer) or_return
		kv(t, "code", .String, error_code(e.kind)) or_return
		msg, merr := entry_message(e, scratch)
		if merr != nil {
			return merr
		}
		defer delete(msg, scratch)
		kv(t, "message", .String, msg) or_return
		write.token_tape_take(t, .Close, "") or_return
	}
	write.token_tape_take(t, .Close, "") or_return
	if truncated {
		kv(t, "truncated", .True, "") or_return
	}
	return write.token_tape_take(t, .Close, "")
}
