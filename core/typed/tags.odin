package typed

import "core:reflect"
import "core:strings"
import spell "../spell"
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
	value, found := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), b.p.spelling.tag_key)
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

// Adds the rules a member's `model:` tag spells to the plan's sets, when the plan reads them, and returns the member's
// `Meta.rule_set`. Members with equal rules share a set. An item the tag cannot spell refuses the plan.
@(private)
rules_of :: proc(b: ^Builder, name, tag: string) -> i32 {
	if !b.rule_tags {
		return 0
	}
	value, found := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), "model")
	if !found {
		return 0
	}
	r: rules.Rules
	if bad := parse_tag(value, &r); len(bad) > 0 {
		refuse_plan(b, .Bad_Tag, name, bad)
		return 0
	}
	for x, i in b.rule_sets {
		if x == r {
			return i32(i + 1)
		}
	}
	if _, failed := append(&b.rule_sets, r); failed != nil {
		refuse_plan(b, .No_Memory)
		return 0
	}
	return i32(len(b.rule_sets))
}

// Reads the rules a `model:` tag spells into `r`: items separated by commas, each a bound `>=N`, `>N`, `<=N` or `<N` on
// a number, or the same after `len` on a length, which counts a string's code points, an array's elements and an
// object's members, and is ASCII digits with no leading zero. Returns the first item it cannot read. `r`'s numbers
// borrow `tag`.
@(private)
parse_tag :: proc(tag: string, r: ^rules.Rules) -> (bad: string) {
	rest := tag
	for part in strings.split_iterator(&rest, ",") {
		item := strings.trim_space(part)
		if len(item) == 0 {
			continue
		}
		length := strings.has_prefix(item, "len")
		text := item[3:] if length else item
		op := text[:2] if strings.has_prefix(text, ">=") || strings.has_prefix(text, "<=") else text[:min(len(text), 1)]
		value := text[len(op):]
		if length {
			n: u64
			ok := len(value) > 0 && (value[0] != '0' || len(value) == 1)
			for c in transmute([]u8)value {
				ok &&= c >= '0' && c <= '9' && n <= (max(u64) - u64(c - '0')) / 10
				n = n * 10 + u64(c - '0')
			}
			switch {
			case !ok:
				return item
			case op == ">=" || op == ">" && n < max(u64):
				n += 1 if op == ">" else 0
				r.min_length, r.min_items, r.min_members = n, n, n
			case op == "<=" || op == "<" && n > 0:
				n -= 1 if op == "<" else 0
				r.max_length, r.max_items, r.max_members = n, n, n
			case:
				return item
			}
			continue
		}
		if _, ok := spell.number_strict(transmute([]u8)value, 0, u64(len(value))); !ok {
			return item
		}
		switch op {
		case ">=", ">":
			r.minimum, r.exclusive_minimum = value, op == ">"
		case "<=", "<":
			r.maximum, r.exclusive_maximum = value, op == "<"
		case:
			return item
		}
	}
	return ""
}

// Spells a `snake_case` name as `Plan_Options.rename` says.
@(private)
renamed :: proc(b: ^Builder, name: string) -> string {
	if b.rename == .None {
		return name
	}
	out, failed := make([]u8, len(name))
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return name
	}
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
