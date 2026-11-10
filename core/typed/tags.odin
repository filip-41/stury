package typed

import "base:runtime"
import "core:reflect"
import "core:strings"
import rules "../rules"

// The tag key every format reads where a field has no tag under the format's own key.
@(private)
SHARED_TAG_KEY :: "stury"

@(private)
Field_Tag :: struct {
	name:     string,
	named:    bool,
	keep:     bool,
	required: bool,
	unknown:  bool,
	omit:     bool,
}

// Reads a field's tag: `name,flag,flag`, or `-` to leave the field out. An empty name keeps the field's own, renamed by
// `Plan_Options.rename`. In the name a backslash makes the byte after it literal, so a comma or a backslash is written
// `\,` or `\\`. The flags are `omitempty`, which only a writer reads, `required` and `unknown`. Any other is returned in
// `bad_flag`.
@(private)
field_tag :: proc(b: ^Builder, name, tag: string) -> (t: Field_Tag, bad_flag: string) {
	value, found := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), b.p.readers.tag_key)
	if !found {
		value, found = reflect.struct_tag_lookup(reflect.Struct_Tag(tag), SHARED_TAG_KEY)
	}
	t.keep = true
	if !found {
		t.name = renamed(b, name)
		return t, ""
	}
	if value == "-" {
		return {}, ""
	}
	out, failed := make([dynamic]u8, 0, len(value))
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return {}, ""
	}
	i := 0
	for ; i < len(value) && value[i] != ','; i += 1 {
		if value[i] == '\\' && i + 1 < len(value) {
			i += 1
		}
		append(&out, value[i])
	}
	t.named = len(out) > 0
	t.name = owned(b, out[:]) if t.named else renamed(b, name)
	if !t.named {
		delete(out)
	}
	if i < len(value) {
		flags := value[i + 1:]
		for flag in strings.split_iterator(&flags, ",") {
			switch flag {
			case "":
			case "omitempty":
				t.omit = true
			case "required":
				t.required = true
			case "unknown":
				t.unknown = true
			case:
				return {}, flag
			}
		}
	}
	return t, ""
}

// Adds `r` to the plan's rule sets, with its text copied into the plan, and returns its `Meta.rule_set`. Equal rules share
// a set.
@(private)
rule_set_of :: proc(b: ^Builder, r: rules.Rules) -> i32 {
	for x, i in b.rule_sets {
		if x == r {
			return i32(i + 1)
		}
	}
	r := r
	for text in ([5]^string{&r.minimum, &r.maximum, &r.multiple_of, &r.pattern, &r.format}) {
		if len(text^) > 0 {
			text^ = owned_copy(b, text^)
		}
	}
	if _, failed := append(&b.rule_sets, r); failed != nil {
		refuse_plan(b, .No_Memory)
		return 0
	}
	return i32(len(b.rule_sets))
}

// Spells a `snake_case` name as `Plan_Options.rename` says.
@(private)
renamed :: proc(b: ^Builder, name: string) -> string {
	if b.rename == .None {
		return name
	}
	out, failed := rename_text(name, b.rename, context.allocator)
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return name
	}
	return owned(b, transmute([]u8)out)
}

// A `snake_case` name spelled as `rename` says, in a new string.
rename_text :: proc(name: string, rename: Rename, allocator: runtime.Allocator) -> (text: string, err: runtime.Allocator_Error) {
	out := make([]u8, len(name), allocator) or_return
	n := 0
	upper := rename == .Pascal
	for i in 0 ..< len(name) {
		c := name[i]
		#partial switch rename {
		case .Camel, .Pascal:
			if c == '_' {
				upper = true
				continue
			}
			if upper && c >= 'a' && c <= 'z' {
				c -= 32
			}
			upper = false
		case .Kebab:
			if c == '_' {
				c = '-'
			}
		case .Screaming:
			if c >= 'a' && c <= 'z' {
				c -= 32
			}
		case .Snake:
			if c >= 'A' && c <= 'Z' {
				c += 32
			}
		}
		out[n] = c
		n += 1
	}
	return string(out[:n]), nil
}
