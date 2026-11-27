// Structured validation errors, sink, result, and options for schema checks.
package check

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

Error_Kind :: rules.Error_Kind

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

// Collects every validation failure of a check inside an owned `mem.Dynamic_Arena`.
Sink :: struct {
	entries:     [dynamic]Check_Error,
	base:        string,
	allocator:   runtime.Allocator,
	arena:       mem.Dynamic_Arena,
	arena_ready: bool,
	oom:         bool,
}

Sink_Mark :: struct {
	count: int,
}

Result :: struct {
	valid:     bool,
	err:       Check_Error,
	walk_err:  tape.Error,
	allocator: runtime.Allocator,
	arena:     ^mem.Dynamic_Arena,
}

Compile_Error :: struct {
	kind:    Error_Kind,
	keyword: string,
}

Options :: struct {
	dups:    tape.Duplicates,
	budget:  tape.Budget,
	scratch: runtime.Allocator,
}

sink_init :: proc(s: ^Sink, allocator := context.allocator, base := "") {
	s^ = {base = base, allocator = allocator}
	s.entries.allocator = allocator
	mem.dynamic_arena_init(&s.arena, allocator, allocator)
	s.arena_ready = true
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
	if s.arena_ready { mem.dynamic_arena_reset(&s.arena) }
	s.oom = false
}

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

sink_mark :: proc "contextless" (s: ^Sink) -> Sink_Mark {
	return {count = len(s.entries)} if s != nil else {}
}

sink_restore :: proc "contextless" (s: ^Sink, mark: Sink_Mark) {
	if s != nil && mark.count < len(s.entries) { (^runtime.Raw_Dynamic_Array)(&s.entries).len = mark.count }
}

result_destroy :: proc(r: ^Result) {
	if r == nil { return }
	if r.arena != nil {
		mem.dynamic_arena_destroy(r.arena)
		free(r.arena, r.allocator)
	}
	r^ = {}
}

// Formats `steps` as an RFC 6901 JSON Pointer (`""` for empty, `"/a/0/b~1c"` otherwise).
format_pointer :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	if len(steps) == 0 { return "", nil }
	b, err := strings.builder_make(0, len(steps) * 8, allocator)
	if err != nil { return "", err }
	for s in steps {
		if _, werr := strings.write_byte(&b, '/'); werr != nil {
			strings.builder_destroy(&b)
			return "", werr
		}
		#partial switch v in s {
		case tape.Name:
			for c in transmute([]u8)string(v) {
				ok := true
				switch c {
				case '~': ok = strings.write_string(&b, "~0") == 2
				case '/': ok = strings.write_string(&b, "~1") == 2
				case:
					_, werr := strings.write_byte(&b, c)
					ok = werr == nil
				}
				if !ok {
					strings.builder_destroy(&b)
					return "", .Out_Of_Memory
				}
			}
		case tape.Index:
			strings.write_int(&b, int(v))
		}
	}
	return strings.to_string(b), nil
}

@(private)
clone_steps :: proc(steps: []tape.Step, allocator: runtime.Allocator) -> ([]tape.Step, runtime.Allocator_Error) {
	if len(steps) == 0 { return nil, nil }
	out, err := make([]tape.Step, len(steps), allocator)
	if err != nil { return nil, err }
	for s, i in steps {
		#partial switch v in s {
		case tape.Name:
			cloned, cerr := strings.clone(string(v), allocator)
			if cerr != nil { return nil, cerr }
			out[i] = tape.Name(cloned)
		case tape.Index:
			out[i] = v
		}
	}
	return out, nil
}

@(private)
keyword_of_kind :: proc "contextless" (kind: Error_Kind, l: ^rules.Leaf, members: bool) -> string {
	#partial switch kind {
	case .Wrong_Kind:        return "type"
	case .Not_Allowed:       return "false"
	case .Below_Minimum:     return "exclusiveMinimum" if l != nil && l.minimum.exclusive else "minimum"
	case .Above_Maximum:     return "exclusiveMaximum" if l != nil && l.maximum.exclusive else "maximum"
	case .Not_Multiple:      return "multipleOf"
	case .Too_Short:         return "minLength"
	case .Too_Long:          return "maxLength"
	case .No_Match, .Pattern_Undecided: return "pattern"
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

@(private)
order_entries :: proc(sink: ^Sink, from: int) {
	if sink == nil || len(sink.entries) - from <= 1 { return }
	slice.sort_by(sink.entries[from:], proc(a, b: Check_Error) -> bool {
		if a.at != b.at { return a.at < b.at }
		if c := strings.compare(a.instance_location, b.instance_location); c != 0 { return c < 0 }
		if c := strings.compare(a.keyword_location, b.keyword_location); c != 0 { return c < 0 }
		if a.kind != b.kind { return a.kind < b.kind }
		return strings.compare(a.expected, b.expected) < 0
	})
}
