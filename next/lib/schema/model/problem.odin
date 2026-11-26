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
	Missing_Validator, Missing_Version, Unknown_Version, Downgrade_Not_Allowed,
	Cyclic_Migration, Duplicate_Migration, Migration_Failed, Incompatible_Schema,
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
	secret:  bool,
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
	secret:  bool,
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
	_ = sink_ensure(s, allocator)
}

sink_destroy :: proc(s: ^Sink) {
	if s == nil { return }
	delete(s.entries)
	if s.arena_ready { mem.dynamic_arena_destroy(&s.arena) }
	s^ = {}
}

sink_clear :: proc(s: ^Sink) {
	if s == nil { return }
	clear(&s.entries)
	if s.arena_dirty && s.arena_ready {
		mem.dynamic_arena_reset(&s.arena)
		s.arena_dirty = false
	}
	s.truncated, s.oom = false, false
}

@(private)
sink_ensure :: proc(s: ^Sink, fallback: runtime.Allocator) -> runtime.Allocator {
	if s.allocator.procedure == nil { s.allocator, s.entries.allocator = fallback, fallback }
	if !s.arena_ready {
		mem.dynamic_arena_init(&s.arena, s.allocator, s.allocator)
		s.arena_ready = true
	}
	return mem.dynamic_arena_allocator(&s.arena)
}

@(private)
sink_push :: proc(s: ^Sink, fallback: runtime.Allocator, kind: Error_Kind, at: u64, steps: []tape.Step, operand := "", want := Want{}, secret := false) -> bool {
	if s == nil { return false }
	if s.max_errors > 0 && len(s.entries) >= s.max_errors { s.truncated = true; return false }
	arena := sink_ensure(s, fallback)
	s.arena_dirty = true
	safe_op := "" if secret else operand
	safe_wt := DEFAULT_REDACT_MASK if (secret && kind == .Custom) else ("" if secret else want.text)
	entry := Error_Entry{kind = kind, at = at, want = {type = want.type}, secret = secret}
	perr: runtime.Allocator_Error
	if entry.pointer, entry.operand, entry.want.text, perr = alloc_error_strings(arena, steps, safe_op, safe_wt); perr == nil {
		if entry.path, perr = clone_steps(steps, arena); perr == nil { _, perr = append(&s.entries, entry) }
	}
	if perr != nil { s.oom = true; return false }
	return true
}

@(private)
format_pointer_fast :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	if len(steps) == 0 { return "", nil }
	// Fast path: single allocation + copy when every step is an unescaped Name.
	n := 0
	for s in steps {
		nm, is_nm := s.(tape.Name)
		if !is_nm { return check.format_pointer(steps, allocator) }
		n += 1 + len(string(nm))
		for c in transmute([]u8)string(nm) {
			if c == '~' || c == '/' { return check.format_pointer(steps, allocator) }
		}
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
alloc_error_strings :: proc(allocator: runtime.Allocator, steps: []tape.Step, operand, want_text: string) -> (ptr, op, wt: string, err: runtime.Allocator_Error) {
	defer if err != nil {
		delete(ptr, allocator)
		delete(op, allocator)
		delete(wt, allocator)
	}
	ptr = format_pointer_fast(steps, allocator) or_return
	if len(operand) > 0 { op = strings.clone(operand, allocator) or_return }
	if len(want_text) > 0 { wt = strings.clone(want_text, allocator) or_return }
	return ptr, op, wt, nil
}

@(private)
record_failure :: proc(
	sink: ^Sink, first: ^Model_Error, oom: ^bool, allocator: runtime.Allocator,
	kind: Error_Kind, at: u64, steps: []tape.Step, operand := "", want := Want{}, silent := false, secret := false,
) -> bool {
	if silent { if first.kind == .None { first^ = {kind = kind, at = at, secret = secret} }; return false }
	pushed := sink_push(sink, allocator, kind, at, steps, operand, want, secret) if sink != nil else false
	if sink != nil && sink.oom { if oom != nil { oom^ = true }; return false }
	if first.kind == .None {
		if pushed {
			e := sink.entries[len(sink.entries) - 1]
			first^ = {kind = e.kind, at = e.at, pointer = e.pointer, operand = e.operand, want = e.want, secret = e.secret}
		} else {
			safe_op := "" if secret else operand
			safe_wt := DEFAULT_REDACT_MASK if (secret && kind == .Custom) else ("" if secret else want.text)
			ptr, op, wt, err := alloc_error_strings(allocator, steps, safe_op, safe_wt)
			if err != nil { if oom != nil { oom^ = true }; first^ = {kind = kind, at = at, secret = secret} } else {
				first^ = {kind = kind, at = at, pointer = ptr, operand = op, want = {want.type, wt}, owned = len(ptr) > 0 || len(op) > 0 || len(wt) > 0, secret = secret}
			}
		}
	}
	return pushed
}

@(private)
clone_steps :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> (out: []tape.Step, err: runtime.Allocator_Error) {
	if len(steps) == 0 { return nil, nil }
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
	if s == nil || len(s.entries) - from <= 1 { return }
	slice.sort_by(s.entries[from:], proc(a, b: Error_Entry) -> bool {
		if a.at != b.at { return a.at < b.at }
		if c := strings.compare(a.pointer, b.pointer); c != 0 { return c < 0 }
		if a.kind != b.kind { return a.kind < b.kind }
		return strings.compare(a.operand, b.operand) < 0
	})
}

@(private, rodata)
RULES_KIND_MAP := [rules.Error_Kind]Error_Kind{
	.None = .None, .Wrong_Kind = .Wrong_Kind, .Not_Allowed = .Not_Allowed, .Below_Minimum = .Below_Minimum, .Above_Maximum = .Above_Maximum,
	.Not_Multiple = .Not_Multiple, .Too_Short = .Too_Short, .Too_Long = .Too_Long, .No_Match = .No_Match, .Pattern_Undecided = .Pattern_Undecided,
	.Bad_Format = .Bad_Format, .Too_Few = .Too_Few, .Too_Many = .Too_Many, .Not_Unique = .Not_Unique, .Not_A_Member = .Not_A_Member,
	.Missing_Field = .Missing_Field, .No_Arm = .No_Arm, .Many_Arms = .Many_Arms, .Duplicate_Key = .Duplicate_Key,
	.Exceeded = .Exceeded, .Walk = .Walk, .No_Memory = .No_Memory, .Bad_Option = .Bad_Option, .Unsupported = .Unsupported,
}

@(private)
map_rules_kind :: proc "contextless" (k: rules.Error_Kind) -> Error_Kind {
	return RULES_KIND_MAP[k] if k <= max(rules.Error_Kind) else .Wrong_Kind
}

@(private)
Error_Meta :: struct { code, msg: string }

@(private, rodata)
ERROR_META := [Error_Kind]Error_Meta{
	.None = {"none", "No error"}, .Wrong_Kind = {"wrong_kind", "Value does not fit the field's type"},
	.Not_Allowed = {"not_allowed", "Field is not allowed"}, .Below_Minimum = {"below_minimum", "Number is below minimum"},
	.Above_Maximum = {"above_maximum", "Number is above maximum"}, .Not_Multiple = {"not_multiple", "Number is not a multiple"},
	.Too_Short = {"too_short", "String is too short"}, .Too_Long = {"too_long", "String is too long"},
	.No_Match = {"no_match", "String does not match pattern"}, .Pattern_Undecided = {"pattern_undecided", "Pattern evaluation exceeded step limit"},
	.Bad_Format = {"bad_format", "String does not match required format"}, .Too_Few = {"too_few", "Too few items"},
	.Too_Many = {"too_many", "Too many items"}, .Not_Unique = {"not_unique", "Items must be unique"},
	.Not_A_Member = {"not_a_member", "Value is not an allowed member"}, .Missing_Field = {"missing_field", "Required field is missing"},
	.No_Arm = {"no_arm", "Value matches no union arm"}, .Many_Arms = {"many_arms", "Value matches more than one union arm"},
	.Duplicate_Key = {"duplicate_key", "Duplicate key"}, .Non_Finite = {"non_finite", "Number is not finite"},
	.Bad_Tag = {"bad_tag", "Invalid model tag or rule"}, .Custom = {"custom", "Validation failed"},
	.Check_Failed = {"check_failed", "Validation check failed"}, .Exceeded = {"exceeded", "Budget exceeded"},
	.Walk = {"walk", "Parse error"}, .No_Memory = {"no_memory", "Out of memory"},
	.Bad_Option = {"bad_option", "Invalid option"}, .Unsupported = {"unsupported", "Unsupported operation"},
	.Missing_Validator = {"missing_validator", "Required named validator is not registered"},
	.Missing_Version = {"missing_version", "Document version is missing or invalid"},
	.Unknown_Version = {"unknown_version", "Unknown schema version or no migration path"},
	.Downgrade_Not_Allowed = {"downgrade_not_allowed", "Downgrade migration is not allowed"},
	.Cyclic_Migration = {"cyclic_migration", "Migration plan contains a cycle"},
	.Duplicate_Migration = {"duplicate_migration", "Duplicate migration step registered"},
	.Migration_Failed = {"migration_failed", "Migration step failed"},
	.Incompatible_Schema = {"incompatible_schema", "Schemas are not compatible without a migration"},
}

error_code :: proc "contextless" (kind: Error_Kind) -> string {
	return ERROR_META[kind].code if kind <= max(Error_Kind) else "unknown"
}

entry_message :: proc(e: Error_Entry, allocator := context.allocator, opts := Problem_Opts{}) -> (msg: string, err: runtime.Allocator_Error) {
	redacted := e.secret || redact_pointer_matches(e.pointer, opts.redact_paths)
	if redacted {
		mask := resolve_redact_mask(opts.redact_mask)
		b := strings.builder_make(0, 64, allocator) or_return
		strings.write_string(&b, ERROR_META[e.kind].msg if e.kind <= max(Error_Kind) else "Validation failed")
		strings.write_string(&b, " (")
		strings.write_string(&b, mask)
		strings.write_byte(&b, ')')
		return strings.to_string(b), nil
	}
	if e.kind == .Custom && len(e.want.text) > 0 { return strings.clone(e.want.text, allocator) }
	b := strings.builder_make(0, 64, allocator) or_return
	strings.write_string(&b, ERROR_META[e.kind].msg if e.kind <= max(Error_Kind) else "Validation failed")
	if len(e.operand) > 0 { strings.write_string(&b, ", "); strings.write_string(&b, e.operand) } else if len(e.want.text) > 0 { strings.write_string(&b, ", expected "); strings.write_string(&b, e.want.text) }
	return strings.to_string(b), nil
}

Problem :: struct { type: string `stury:"type,omitempty"`, title: string, status: int, errors: []Problem_Error }
Problem_Error :: struct { pointer, code, message: string }

problem :: proc(entries: []Error_Entry, title: string, status: int, type := "", allocator := context.allocator, opts := Problem_Opts{}) -> (p: Problem, err: runtime.Allocator_Error) {
	p = {type = type, title = title, status = status}
	p.errors = make([]Problem_Error, len(entries), allocator) or_return
	defer if err != nil { problem_destroy(p, allocator) }
	for e, i in entries {
		p.errors[i].code = error_code(e.kind)
		p.errors[i].pointer = strings.clone(e.pointer, allocator) or_return
		p.errors[i].message = entry_message(e, allocator, opts) or_return
	}
	return p, nil
}

problem_destroy :: proc(p: Problem, allocator := context.allocator) {
	for e in p.errors { delete(e.pointer, allocator); delete(e.message, allocator) }
	delete(p.errors, allocator)
}

write_problem_tokens :: proc(t: ^write.Token_Tape, entries: []Error_Entry, p: Problem, truncated := false, scratch := context.allocator, opts := Problem_Opts{}) -> write.Error {
	kv :: proc(t: ^write.Token_Tape, k: string, kind: write.Token_Kind, v: string) -> write.Error {
		write.token_tape_take(t, .Key, k) or_return
		return write.token_tape_take(t, kind, v)
	}
	write.token_tape_take(t, .Object, "") or_return
	if p.type != "" { kv(t, "type", .String, p.type) or_return }
	kv(t, "title", .String, p.title) or_return
	sbuf: [24]u8 = ---
	kv(t, "status", .Number, strconv.write_int(sbuf[:], i64(p.status), 10)) or_return
	kv(t, "errors", .Array, "") or_return
	for e in entries {
		write.token_tape_take(t, .Object, "") or_return
		kv(t, "pointer", .String, e.pointer) or_return
		kv(t, "code", .String, error_code(e.kind)) or_return
		msg := entry_message(e, scratch, opts) or_return
		defer delete(msg, scratch)
		kv(t, "message", .String, msg) or_return
		write.token_tape_take(t, .Close, "") or_return
	}
	write.token_tape_take(t, .Close, "") or_return
	if truncated { kv(t, "truncated", .True, "") or_return }
	return write.token_tape_take(t, .Close, "")
}
