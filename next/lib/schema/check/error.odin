// Structured validation errors, sink, result, and options for schema checks.
package check

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

Error_Kind :: rules.Error_Kind

// One validation failure collected during a check.
// All strings and slices are owned by the `Sink` (or `Result`) that holds the error.
Check_Error :: struct {
	kind:              Error_Kind,
	at:                u64,
	instance_location: string,
	keyword_location:  string,
	keyword:           string,
	expected:          string,
	path:              []tape.Step,
	keyword_path:      []tape.Step,
	walk_err:          tape.Error,
}

// Collects every validation failure of a check.
// All error strings and paths are allocated from an internal `mem.Dynamic_Arena` backed by `allocator`,
// so zero allocations escape to `context.temp_allocator` and `sink_destroy` frees everything cleanly.
Sink :: struct {
	entries:     [dynamic]Check_Error,
	base:        string,
	allocator:   runtime.Allocator,
	arena:       mem.Dynamic_Arena,
	arena_ready: bool,
	oom:         bool,
}

// A position in a `Sink` that a speculative arm can roll back to.
Sink_Mark :: struct {
	count: int,
}

// The outcome of a check. For a valid check, `valid` is true and no arena is allocated.
// For a failed check without a sink, `err` holds the first failure (owned by `arena`).
Result :: struct {
	valid:     bool,
	err:       Check_Error,
	walk_err:  tape.Error,
	allocator: runtime.Allocator,
	arena:     ^mem.Dynamic_Arena,
}

// Why `compile` refused a `rules.Description`. Borrows only static strings or strings copied into no heap block.
Compile_Error :: struct {
	kind:    Error_Kind,
	keyword: string,
}

// Options controlling a check run.
Options :: struct {
	dups:    tape.Duplicates,
	budget:  tape.Budget,
	scratch: runtime.Allocator,
}

// Initializes `s` backed by `allocator`.
sink_init :: proc(s: ^Sink, allocator := context.allocator, base := "") {
	s^ = {base = base, allocator = allocator}
	s.entries.allocator = allocator
	mem.dynamic_arena_init(&s.arena, allocator, allocator)
	s.arena_ready = true
}

// Frees all memory owned by `s` and resets it to zero.
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

// Resets `s` for reuse without releasing its arena backing blocks.
sink_clear :: proc(s: ^Sink) {
	if s == nil {
		return
	}
	clear(&s.entries)
	if s.arena_ready {
		mem.dynamic_arena_reset(&s.arena)
	}
	s.oom = false
}

// Ensures `s` has an initialized arena (handles zero-initialized `Sink` passed by callers).
@(private)
sink_ensure :: proc(s: ^Sink, fallback: runtime.Allocator) -> runtime.Allocator {
	if s.allocator.procedure == nil {
		s.allocator = fallback
		s.entries.allocator = fallback
	}
	if !s.arena_ready {
		mem.dynamic_arena_init(&s.arena, s.allocator, s.allocator)
		s.arena_ready = true
	}
	return mem.dynamic_arena_allocator(&s.arena)
}

// Records the current entry count so speculative checks can roll back.
sink_mark :: proc "contextless" (s: ^Sink) -> Sink_Mark {
	if s == nil {
		return {}
	}
	return {count = len(s.entries)}
}

// Truncates `s.entries` back to `mark`.
sink_restore :: proc "contextless" (s: ^Sink, mark: Sink_Mark) {
	if s == nil {
		return
	}
	if mark.count < len(s.entries) {
		resize_raw_len(&s.entries, mark.count)
	}
}

@(private)
resize_raw_len :: #force_inline proc "contextless" (d: ^[dynamic]$T, n: int) {
	(^runtime.Raw_Dynamic_Array)(d).len = n
}

// Frees any arena owned by `r` and resets it to zero.
result_destroy :: proc(r: ^Result) {
	if r == nil {
		return
	}
	if r.arena != nil {
		mem.dynamic_arena_destroy(r.arena)
		free(r.arena, r.allocator)
	}
	r^ = {}
}

// Formats `steps` as an RFC 6901 JSON Pointer (`""` for empty, `"/a/0/b~1c"` otherwise).
format_pointer :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	if len(steps) == 0 {
		return "", nil
	}
	b, err := strings.builder_make(0, len(steps) * 8, allocator)
	if err != nil {
		return "", err
	}
	for s in steps {
		if _, werr := strings.write_byte(&b, '/'); werr != nil {
			strings.builder_destroy(&b)
			return "", werr
		}
		#partial switch v in s {
		case tape.Name:
			if !write_pointer_token(&b, string(v)) {
				strings.builder_destroy(&b)
				return "", .Out_Of_Memory
			}
		case tape.Index:
			strings.write_int(&b, int(v))
		}
	}
	return strings.to_string(b), nil
}

@(private = "file")
write_pointer_token :: proc(b: ^strings.Builder, name: string) -> bool {
	for c in transmute([]u8)name {
		switch c {
		case '~':
			if strings.write_string(b, "~0") != 2 {
				return false
			}
		case '/':
			if strings.write_string(b, "~1") != 2 {
				return false
			}
		case:
			if _, werr := strings.write_byte(b, c); werr != nil {
				return false
			}
		}
	}
	return true
}

// Clones `steps` and any `Name` strings into `allocator`.
@(private)
clone_steps :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> ([]tape.Step, runtime.Allocator_Error) {
	if len(steps) == 0 {
		return nil, nil
	}
	out, err := make([]tape.Step, len(steps), allocator)
	if err != nil {
		return nil, err
	}
	for s, i in steps {
		#partial switch v in s {
		case tape.Name:
			cloned, cerr := strings.clone(string(v), allocator)
			if cerr != nil {
				return nil, cerr
			}
			out[i] = tape.Name(cloned)
		case tape.Index:
			out[i] = v
		}
	}
	return out, nil
}

// The JSON Schema keyword name corresponding to a leaf error kind.
@(private)
keyword_of_kind :: proc "contextless" (kind: Error_Kind, l: ^rules.Leaf, members: bool) -> string {
	#partial switch kind {
	case .Wrong_Kind:        return "type"
	case .Not_Allowed:       return "false"
	case .Below_Minimum:
		if l != nil && l.minimum.exclusive {
			return "exclusiveMinimum"
		}
		return "minimum"
	case .Above_Maximum:
		if l != nil && l.maximum.exclusive {
			return "exclusiveMaximum"
		}
		return "maximum"
	case .Not_Multiple:      return "multipleOf"
	case .Too_Short:         return "minLength"
	case .Too_Long:          return "maxLength"
	case .No_Match:          return "pattern"
	case .Pattern_Undecided: return "pattern"
	case .Bad_Format:        return "format"
	case .Too_Few:           return "minProperties" if members else "minItems"
	case .Too_Many:          return "maxProperties" if members else "maxItems"
	case .Not_Unique:        return "uniqueItems"
	case .Not_A_Member:      return "const" if l != nil && l.constant else "enum"
	case .Missing_Field:     return "required"
	case .No_Arm:            return "anyOf"
	case .Many_Arms:         return "oneOf"
	case .Duplicate_Key:     return "duplicateKey"
	}
	return ""
}

// Sorts entries added to `sink` from `from` onwards deterministically by source offset, instance pointer, and keyword pointer.
@(private)
order_entries :: proc(sink: ^Sink, from: int) {
	if sink == nil || len(sink.entries) - from <= 1 {
		return
	}
	slice.sort_by(sink.entries[from:], proc(a, b: Check_Error) -> bool {
		if a.at != b.at {
			return a.at < b.at
		}
		if c := strings.compare(a.instance_location, b.instance_location); c != 0 {
			return c < 0
		}
		if c := strings.compare(a.keyword_location, b.keyword_location); c != 0 {
			return c < 0
		}
		if a.kind != b.kind {
			return a.kind < b.kind
		}
		return strings.compare(a.expected, b.expected) < 0
	})
}
