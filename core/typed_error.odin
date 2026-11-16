package core

import "base:runtime"
import "core:io"
import "core:reflect"
import "core:strings"

// The refusals of a typed read or write and their rendered lines, and the entries a check or a load reports.

// How a typed read or write refuses. `.None` is no error. The kinds from `Invalid_Utf8` to `Write_Failed` are a
// write's, and none of them names a byte of a source.
Typed_Error_Kind :: enum u8 {
	None,
	Walk, // the walk's fault, in `inner`
	Wrong_Kind, // a value the target's type does not read
	Out_Of_Range, // a value past what the target holds, other than a number
	Not_A_Member, // a name or number no enum or union member has
	Wrong_Length, // a table's row holds more cells than its type, or a second record where one is read
	Missing_Field, // a `required` member is absent, the last step names it, or for a check `want.text` with the object's path
	Unknown_Field, // a key the type does not name, the last step names it
	Missing_Tag, // an object for a union that reads by tag has no tag member
	Repeated_Tag, // an object for a union that reads by tag has two
	Duplicate_Key, // a read under `.Refuse` met a key that repeats one of its object's, or a YAML read by name one of the same text and another type
	No_Memory,
	Bad_Option, // an option or a target the call cannot take, at no byte, `want.text` saying why where it can
	Plan_Mismatch, // a plan built for another type or format, at no byte
	Unsupported, // a type a plan cannot read or write, the last step names the field
	Ambiguous_Union, // a union whose arms a value's class cannot tell apart
	Bad_Tag, // a field's tag holds a flag no reader knows
	Invalid_Utf8, // a string to write is not UTF-8
	Non_Finite, // a number to write is infinite or not a number
	Too_Deep, // a value to write nests past `MAX_DEPTH`
	Cycle, // a pointer to write leads back to itself
	Bad_Raw, // a `Raw` or `Number_Text` to write is not one value of the format
	Unwritable, // a value the format cannot spell, the last step names it
	Out_Of_Order, // a token call the text's grammar does not allow next, or a text finished before it is whole
	Write_Failed, // the output stream refused bytes, which may have left a prefix in it
	Bad_Schema, // a schema the reader refuses, `want.text` names the keyword and why, the steps lead to it
	Below_Minimum, // a number below a rule's lower bound or the least value its type holds
	Above_Maximum, // a number above a rule's upper bound or the greatest value its type holds
	Not_Multiple, // a number that is no whole multiple of a rule's divisor
	Too_Short, // a string with fewer code points than a rule allows
	Too_Long, // a string with more code points than a rule allows
	No_Match, // a string a rule's pattern does not match
	Pattern_Undecided, // a string a rule's pattern was not searched through, for the search ran out of memory
	Bad_Format, // a string that is no value of a rule's format
	Too_Few, // an array or object with fewer elements or members than a rule or a fixed array allows
	Too_Many, // an array or object with more elements or members than a rule, a fixed array or a fixed capacity allows
	Not_Unique, // an array whose elements repeat where a rule wants them unique
	Not_Allowed, // a value where a rule takes none, or a key a model's struct forbids: one it does not name or a read_only member
	No_Arm, // a value that passes none of a rule's subschemas, or no arm of a model's union takes
	Many_Arms, // a value that passes more than one of a rule's subschemas, where it takes one
	No_Sample, // a description no value passes, or none the bounded search found, `want.text` names the node
	No_Invalid_Sample, // a description every value passes, or one the bounded search found no failing value of
	Custom, // a value a model's validator refused, `want.text` holds its message
	Check_Failed, // a value a model's dump checked fails its rules, the steps lead to the first and `want.text` is its code
}

// The steps a `Typed_Refusal` holds.
MAX_ERROR_STEPS :: 8

// A typed read's or write's refusal, as an `Error` holds it. `at` is the value's byte in the source, 0 for a write and
// for a kind with no byte. `steps` is the path to the value from the target, the innermost `MAX_ERROR_STEPS` when
// `truncated` says more were cut from the front. The path is a slice of an allocator's, so that the union stays small
// on the path of every call that returns nil. A step's name lives as long as `src` or the plan, or for a decoded key as
// long as `context.temp_allocator`'s block. `found` is the kind of the value a `.Wrong_Kind` read. `.Write_Failed` holds
// what the stream answered in `cause`, which is `.Unknown` for most failures of a `core:os` file stream. `detail` holds
// the rest by kind.
Typed_Error :: struct {
	kind:         Typed_Error_Kind,
	truncated:    bool,
	found:        Kind,
	cause:        io.Error,
	at:           u64,
	using detail: Typed_Detail,
	steps:        []Step,
}

// A `Typed_Error` with its path in line, `steps[:n_steps]`: what a reader, a writer and a sink hold, so that a refusal
// allocates nothing.
Typed_Refusal :: struct {
	kind:         Typed_Error_Kind,
	truncated:    bool,
	n_steps:      u8,
	found:        Kind,
	cause:        io.Error,
	at:           u64,
	using detail: Typed_Detail,
	steps:        [MAX_ERROR_STEPS]Step,
}

// Makes the `Typed_Error` of `e`, whose path lives as long as `allocator`'s block. A path that cannot be copied is left
// out.
@(private)
typed_error_of :: proc(e: Typed_Refusal, allocator: runtime.Allocator) -> Typed_Error {
	e := e
	f := Typed_Error{kind = e.kind, truncated = e.truncated, found = e.found, cause = e.cause, at = e.at, detail = e.detail}
	if e.n_steps > 0 {
		if steps, failed := make([]Step, e.n_steps, allocator); failed == nil {
			copy(steps, e.steps[:e.n_steps])
			f.steps = steps
		}
	}
	return f
}

// The `Typed_Refusal` of `f`, whose path keeps the innermost `MAX_ERROR_STEPS` of `f.steps`.
typed_refusal_of :: proc "contextless" (f: Typed_Error) -> Typed_Refusal {
	e := Typed_Refusal{kind = f.kind, truncated = f.truncated, found = f.found, cause = f.cause, at = f.at, detail = f.detail}
	kept := f.steps[max(0, len(f.steps) - MAX_ERROR_STEPS):]
	e.n_steps = u8(len(kept))
	e.truncated = e.truncated || len(kept) < len(f.steps)
	copy(e.steps[:], kept)
	return e
}

// One error a check or a load reports. `start` and `end` are the failing value's first byte and the byte past it in the
// source (a container the read skips ends at its open token, since the walk passes its close unseen), `record` is the
// index of the record the read was in (0 for a read of one text), `path` the steps to the value from the root, any
// depth, and `keyword_path` the steps through the rules that failed it. `operand` is the rule's operand: what a model's
// failed rule asks, a member's name for `.Missing_Field` and a name rule. The steps' names are the sink's own copies,
// freed by `sink_destroy`.
Error_Entry :: struct {
	kind:         Typed_Error_Kind,
	start, end:   u64,
	record:       i64,
	path:         []Step,
	keyword_path: []Step,
	operand:      Value,
}

// What a refusal names beside its kind: `.Walk`'s fault in `inner`, what a `.Plan_Mismatch` met in `plans`, and
// `want` for the other kinds. The three share their bytes, so a reader reads the one its kind names, as `core:fmt` does
// by the tags.
Typed_Detail :: struct #raw_union {
	inner: Fault `raw_union_tag:"kind=Walk"`,
	want:  Typed_Want `raw_union_tag:"kind=Wrong_Kind,kind=Out_Of_Range,kind=Not_A_Member,kind=Below_Minimum,kind=Above_Maximum,kind=Missing_Field,kind=Bad_Tag,kind=Unsupported,kind=Unwritable,kind=Ambiguous_Union,kind=Bad_Schema,kind=No_Sample,kind=No_Invalid_Sample,kind=Custom,kind=Check_Failed,kind=Bad_Option,kind=Too_Deep"`,
	plans: Plan_Clash `raw_union_tag:"kind=Plan_Mismatch"`,
}

// `type` is the type a `.Wrong_Kind`, `.Out_Of_Range`, `.Not_A_Member`, `.Below_Minimum` or `.Above_Maximum` read
// wanted. `text` is the refused scalar's source text for those kinds, which lives as long as `src`, the flag a
// `.Bad_Tag` names, why a type, an option or an operation is `.Unsupported`, a value `.Unwritable` in the format whose
// writer refused it, a union `.Ambiguous_Union` or an option `.Bad_Option`, or what a `.Too_Deep` limit bounds. Either
// may be empty.
Typed_Want :: struct {
	type: typeid,
	text: string,
}

// The formats a `.Plan_Mismatch` met, the plan's and the read's, and the plan's type when the formats agree. Both are
// nil where the refusal does not know them.
Plan_Clash :: struct {
	plan, read: ^Readers,
	type:       typeid,
}

@(private, rodata)
TYPED_KIND_RULES := [Typed_Error_Kind]Rule {
	.None          = {"none", "No error"},
	.Walk          = {"walk", "Input does not parse"},
	.Wrong_Kind    = {"wrong_kind", "Value does not fit the field's type"},
	.Out_Of_Range  = {"out_of_range", "Value is out of range for the field's type"},
	.Not_A_Member  = {"not_a_member", "Value is no member of the type"},
	.Wrong_Length  = {"wrong_length", "Wrong number of elements"},
	.Missing_Field = {"missing_field", "Required field is missing"},
	.Unknown_Field = {"unknown_field", "Unknown field"},
	.Missing_Tag   = {"missing_tag", "Object has no tag member"},
	.Repeated_Tag  = {"repeated_tag", "Object repeats its tag member"},
	.Duplicate_Key = {"duplicate_key", "Duplicate key"},
	.No_Memory     = {"no_memory", "Out of memory"},
	.Bad_Option    = {"bad_option", "Invalid option"},
	.Plan_Mismatch = {"plan_mismatch", "Plan does not read this target"},
	.Unsupported   = {"unsupported", "Type is not supported"},
	.Ambiguous_Union = {"ambiguous_union", "Union arms cannot be told apart"},
	.Bad_Tag       = {"bad_tag", "Invalid field tag"},
	.Invalid_Utf8  = {"invalid_utf8", "Invalid UTF-8"},
	.Non_Finite    = {"non_finite", "Number is not finite"},
	.Too_Deep      = {"too_deep", "Exceeds the depth limit"},
	.Cycle         = {"cycle", "Value refers to itself"},
	.Bad_Raw       = {"bad_raw", "Not one value of the format"},
	.Unwritable    = {"unwritable", "Value cannot be written in the format"},
	.Out_Of_Order  = {"out_of_order", "Token written out of order"},
	.Write_Failed  = {"write_failed", "Output refused the bytes"},
	.Bad_Schema    = {"bad_schema", "Schema is refused"},
	.Below_Minimum = {"below_minimum", "Number is below the minimum"},
	.Above_Maximum = {"above_maximum", "Number is above the maximum"},
	.Not_Multiple  = {"not_multiple", "Number is not a multiple of the divisor"},
	.Too_Short     = {"too_short", "String is too short"},
	.Too_Long      = {"too_long", "String is too long"},
	.No_Match      = {"no_match", "String does not match the pattern"},
	.Pattern_Undecided = {"pattern_undecided", "The pattern could not be decided on the string"},
	.Bad_Format    = {"bad_format", "String is not in the format"},
	.Too_Few       = {"too_few", "Too few elements or members"},
	.Too_Many      = {"too_many", "Too many elements or members"},
	.Not_Unique    = {"not_unique", "Elements are not unique"},
	.Not_Allowed   = {"not_allowed", "No value is allowed here"},
	.No_Arm        = {"no_arm", "Value passes none of the subschemas"},
	.Many_Arms     = {"many_arms", "Value passes more than one subschema"},
	.No_Sample     = {"no_sample", "No value passing the description was found"},
	.No_Invalid_Sample = {"no_invalid_sample", "No value failing the description was found"},
	.Custom        = {"custom", "Value is not valid"},
	.Check_Failed  = {"check_failed", "Value fails its model's rules"},
}

// The messages of a schema check's entries, which name keywords and not a type's fields, where they differ.
@(private, rodata)
SCHEMA_MESSAGES := #partial [Typed_Error_Kind]string {
	.Wrong_Kind    = "Value is not of the allowed type",
	.Not_A_Member  = "Value is not one of the allowed values",
	.Missing_Field = "Required member is missing",
	.Bad_Format    = "String is not valid for the asserted format",
}

// The kinds that name no byte of a source.
TYPED_AT_NO_BYTE :: bit_set[Typed_Error_Kind]{.None, .No_Sample, .No_Invalid_Sample, .Bad_Option, .Plan_Mismatch, .Unsupported, .Ambiguous_Union, .Bad_Tag, .Invalid_Utf8, .Non_Finite, .Too_Deep, .Cycle, .Bad_Raw, .Unwritable, .Out_Of_Order, .Write_Failed}

// Moves the bytes of the source `e` names by `by`, for an error found in a text that starts `by` bytes in.
move_typed_error :: proc(e: ^Typed_Refusal, by: u64) {
	if e.kind not_in TYPED_AT_NO_BYTE && (e.kind != .Walk || e.inner.kind not_in AT_NO_BYTE) {
		e.at += by
		if e.kind == .Walk {
			e.inner.at += by
		}
	}
}

// Writes `line:col: message at path` for `e`, the position left out where the kind has no byte. `.Walk` writes its
// fault. `lines` is as in `render_fault`.
@(private)
render_typed :: proc(w: io.Writer, src: []u8, e: Typed_Refusal, lines: ^Lines = nil) -> io.Error {
	if e.kind == .Walk {
		return render_fault(w, src, e.inner, lines)
	}
	if e.kind not_in TYPED_AT_NO_BYTE {
		write_position(w, src, e.at, lines) or_return
	}
	write_typed_message(w, e) or_return
	if e.cause != .None {
		io.write_string(w, " (") or_return
		io.write_string(w, reflect.enum_string(e.cause)) or_return
		io.write_byte(w, ')') or_return
	}
	if e.n_steps == 0 {
		return nil
	}
	io.write_string(w, " at ") or_return
	if e.truncated {
		io.write_string(w, "...") or_return
	}
	e := e
	return write_steps(w, e.steps[:e.n_steps], !e.truncated)
}

// Writes `e`'s message, naming what `e.detail` holds where its kind has one.
@(private)
write_typed_message :: proc(w: io.Writer, e: Typed_Refusal) -> io.Error {
	#partial switch e.kind {
	case .Wrong_Kind:
		if e.want.type != nil {
			io.write_string(w, "Expected ") or_return
			reflect.write_typeid(w, e.want.type) or_return
			io.write_string(w, ", found ") or_return
			// A plain value, as a dsv cell, has no kind of its own to name, so its text stands in quotes.
			if e.found == .Plain && len(e.want.text) > 0 {
				quoted := e.want.text[0] == '"'
				if !quoted {
					io.write_byte(w, '"') or_return
				}
				write_shown(w, e.want.text) or_return
				return nil if quoted else io.write_byte(w, '"')
			}
			return write_kind_word(w, e.found)
		}
	case .Out_Of_Range, .Below_Minimum, .Above_Maximum:
		if e.want.type != nil && len(e.want.text) > 0 {
			write_shown(w, e.want.text) or_return
			io.write_string(w, " is out of range for ") or_return
			_, err := reflect.write_typeid(w, e.want.type)
			return err
		}
	case .Not_A_Member:
		if e.want.type != nil {
			if len(e.want.text) > 0 {
				write_shown(w, e.want.text) or_return
				io.write_string(w, " is not a ") or_return
			} else {
				io.write_string(w, "Value is no member of ") or_return
			}
			_, err := reflect.write_typeid(w, e.want.type)
			return err
		}
	case .Plan_Mismatch:
		if p := e.plans; p.plan != nil && p.read != nil && p.plan.format != p.read.format {
			io.write_string(w, "Plan is for ") or_return
			io.write_string(w, p.plan.tag_key) or_return
			io.write_string(w, ", the read is ") or_return
			_, err := io.write_string(w, p.read.tag_key)
			return err
		} else if p.type != nil {
			io.write_string(w, "Plan is for ") or_return
			reflect.write_typeid(w, p.type) or_return
			_, err := io.write_string(w, ", not the target's type")
			return err
		}
	case .Bad_Tag:
		if len(e.want.text) > 0 {
			io.write_string(w, "Field tag flag \"") or_return
			io.write_string(w, e.want.text) or_return
			io.write_string(w, "\" is not one the field takes") or_return
			if e.want.type != nil {
				io.write_string(w, " in ") or_return
				reflect.write_typeid(w, e.want.type) or_return
			}
			if strings.has_prefix(e.want.text, "pattern") && strings.contains_rune(e.want.text, ',') {
				_, err := io.write_string(w, ": pattern= takes the rest of the tag, commas included, so put it last or add the rule with register_field")
				return err
			}
			return nil
		}
	case .Custom:
		if len(e.want.text) > 0 {
			_, err := io.write_string(w, e.want.text)
			return err
		}
	case .Unsupported, .Unwritable, .Ambiguous_Union, .Bad_Schema, .No_Sample, .No_Invalid_Sample, .Bad_Option, .Too_Deep:
		io.write_string(w, TYPED_KIND_RULES[e.kind].message) or_return
		if len(e.want.text) > 0 {
			io.write_string(w, ": ") or_return
			io.write_string(w, e.want.text) or_return
		}
		return nil
	}
	_, err := io.write_string(w, TYPED_KIND_RULES[e.kind].message)
	return err
}

// Writes the kind of a value as a word: `null`, `true`, `number`, `object`.
@(private)
write_kind_word :: proc(w: io.Writer, k: Kind) -> io.Error {
	name := reflect.enum_string(k)
	for i in 0 ..< len(name) {
		c := name[i]
		io.write_byte(w, c + 32 if c >= 'A' && c <= 'Z' else c) or_return
	}
	return nil
}

// The kinds whose entry, outside a keyword path, holds in its operand what the failed rule asks.
@(private)
ENTRY_OPERAND_KINDS :: bit_set[Typed_Error_Kind]{.Wrong_Kind, .Below_Minimum, .Above_Maximum, .Too_Short, .Too_Long, .Too_Few, .Too_Many, .Too_Deep}

// The message of a check's entry `e`, in a schema's words where the entry has a keyword path and the kind has such words.
// A missing member is named, which only the entry's operand does, and so is the member whose name failed a name rule.
write_entry_message :: proc(w: io.Writer, e: Error_Entry) -> io.Error {
	if text, named := e.operand.(string); named && e.kind == .Custom {
		_, err := io.write_string(w, text)
		return err
	}
	if name, named := e.operand.(string); named && e.kind == .Missing_Field {
		io.write_string(w, "Required member ") or_return
		io.write_quoted_string(w, name) or_return
		io.write_string(w, " is missing") or_return
		return nil
	}
	message := TYPED_KIND_RULES[e.kind].message
	if len(e.keyword_path) > 0 && SCHEMA_MESSAGES[e.kind] != "" {
		message = SCHEMA_MESSAGES[e.kind]
	}
	last: Step
	if len(e.keyword_path) > 0 {
		last = e.keyword_path[len(e.keyword_path) - 1]
	}
	if e.kind == .Not_Allowed && last == Step(Name("not")) {
		message = "Value passes the subschema that not refuses"
	}
	if (e.kind == .Too_Few || e.kind == .Too_Many) && (last == Step(Name("contains")) || last == Step(Name("minContains")) || last == Step(Name("maxContains"))) {
		message = "Too few elements pass contains" if e.kind == .Too_Few else "Too many elements pass contains"
	}
	io.write_string(w, message) or_return
	if text, named := e.operand.(string); named && e.kind in ENTRY_OPERAND_KINDS && !names_member(e) {
		// What the failed rule asks, after the message: "String is too short, at least 2 characters".
		io.write_string(w, ", ") or_return
		if e.kind == .Wrong_Kind {
			io.write_string(w, "expected ") or_return
		}
		_, err := io.write_string(w, text)
		return err
	}
	if name, named := e.operand.(string); named {
		io.write_string(w, " in the member name ") or_return
		io.write_quoted_string(w, name) or_return
	}
	return nil
}

// Whether the operand of a schema's entry `e` is the member name a `propertyNames` rule failed on.
@(private)
names_member :: proc(e: Error_Entry) -> bool {
	for step in e.keyword_path {
		if step == Step(Name("propertyNames")) {
			return true
		}
	}
	return false
}

// The stable code of a check's entry `e`, which a problem document and a caller match on.
entry_code :: proc(e: Error_Entry) -> string {
	return TYPED_KIND_RULES[e.kind].code
}

// Writes the rendered line of a check's entry `e` in `src`, as `line:col: message at path`, with the keyword path after
// it in parentheses and the message in a schema's words where the entry has one. `lines` is as in `render_fault`.
render_entry :: proc(w: io.Writer, src: []u8, e: Error_Entry, lines: ^Lines = nil) -> io.Error {
	write_position(w, src, e.start, lines) or_return
	write_entry_message(w, e) or_return
	if len(e.path) > 0 {
		io.write_string(w, " at ") or_return
		write_steps(w, e.path, true) or_return
	}
	if len(e.keyword_path) > 0 {
		io.write_string(w, " (") or_return
		write_steps(w, e.keyword_path, false) or_return
		io.write_byte(w, ')') or_return
	}
	return nil
}
