package typed

import "core:reflect"
import "core:strings"

// The tag key every format reads where a field has no tag under the format's own key.
SHARED_TAG_KEY :: "stury"

@(private)
Field_Tag :: struct {
	name:     string,
	named:    bool,
	keep:     bool,
	required: bool,
	unknown:  bool,
}

// Reads a field's tag: `name,flag,flag`, or `-` to leave the field out. An empty name keeps the field's own, renamed by
// `Plan_Options.rename`. In the name a backslash makes the byte after it literal, so a comma or a backslash is written
// `\,` or `\\`. The flags are `omitempty`, which only a writer reads, `required` and `unknown`. Any other is a refusal.
@(private)
field_tag :: proc(b: ^Builder, name, tag: string) -> (t: Field_Tag, ok: bool) {
	value, found := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), b.p.spelling.tag_key)
	if !found {
		value, found = reflect.struct_tag_lookup(reflect.Struct_Tag(tag), SHARED_TAG_KEY)
	}
	t.keep = true
	if !found {
		t.name = renamed(b, name)
		return t, true
	}
	if value == "-" {
		return {}, true
	}
	out := make([dynamic]u8, 0, len(value))
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
			case "", "omitempty":
			case "required":
				t.required = true
			case "unknown":
				t.unknown = true
			case:
				return {}, false
			}
		}
	}
	return t, true
}

// Spells a `snake_case` name as `Plan_Options.rename` says.
@(private)
renamed :: proc(b: ^Builder, name: string) -> string {
	if b.rename == .None {
		return name
	}
	out := make([]u8, len(name))
	n := 0
	upper := b.rename == .Pascal
	for i in 0 ..< len(name) {
		c := name[i]
		#partial switch b.rename {
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
		}
		out[n] = c
		n += 1
	}
	return owned(b, out[:n])
}
