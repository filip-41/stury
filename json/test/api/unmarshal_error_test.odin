package json_tests

// `Unmarshal_Error`'s path: which steps a fault names, the truncation, and the refusal matrix.

import json "../.."
import "core:fmt"
import "core:strings"
import "core:testing"

Um_Deep :: struct {
	a: struct {
		b: []int,
		m: map[string]Um_Tagged,
	},
}

// The error's path and kind, `.a.b[2]: Wrong_Kind` (`[*]` for any element or map value), with the walk's
// result in parentheses for `.Syntax`. An empty path leaves the kind alone.
@(private = "file")
path_text :: proc(err: json.Unmarshal_Error) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< int(err.n_steps) {
		switch v in err.steps[i] {
		case json.Name:
			fmt.sbprintf(&b, ".%s", string(v))
		case json.Index:
			fmt.sbprintf(&b, "[%d]", int(v))
		case json.Any:
			strings.write_string(&b, "[*]")
		}
	}
	if err.n_steps > 0 {
		strings.write_string(&b, ": ")
	}
	fmt.sbprint(&b, err.kind)
	if err.kind == .Syntax {
		fmt.sbprintf(&b, "(%v)", err.syntax)
	}
	return strings.to_string(b)
}

// Reads `src` into a fresh `T`: a matrix row's target type.
@(private)
Um_Reader :: proc(src: string, opts: json.Unmarshal_Opts) -> json.Unmarshal_Error

@(private)
into :: proc($T: typeid) -> Um_Reader {
	return proc(src: string, opts: json.Unmarshal_Opts) -> json.Unmarshal_Error {
		v: T
		return um_err(json.unmarshal(transmute([]byte)src, &v, opts, nil, context.temp_allocator))
	}
}

// Reads `src` into a nil `^T`.
@(private = "file")
into_nil :: proc($T: typeid) -> Um_Reader {
	return proc(src: string, opts: json.Unmarshal_Opts) -> json.Unmarshal_Error {
		return um_err(json.unmarshal(transmute([]byte)src, (^T)(nil), opts, nil, context.temp_allocator))
	}
}

// As `into`, through a plan that writes enums as integers.
@(private = "file")
into_ints :: proc($T: typeid) -> Um_Reader {
	return proc(src: string, opts: json.Unmarshal_Opts) -> json.Unmarshal_Error {
		v: T
		return um_err(json.unmarshal(transmute([]byte)src, &v, opts, um_plan(T, {enums = .Int}), context.temp_allocator))
	}
}

// As `into`, through a plan that tags union arms with a `"type"` member.
@(private = "file")
into_tagged :: proc($T: typeid) -> Um_Reader {
	return proc(src: string, opts: json.Unmarshal_Opts) -> json.Unmarshal_Error {
		v: T
		return um_err(json.unmarshal(transmute([]byte)src, &v, opts, um_plan(T, {union_tag = "type"}), context.temp_allocator))
	}
}

// One refusal: the target, the source, the kind, where it sits (`at(src, needle)`), and the error text after
// `1:col: ` (the path, then the kind). Every source is one line.
@(private = "file")
Um_Refusal :: struct {
	read:   Um_Reader,
	src:    string,
	kind:   json.Unmarshal_Error_Kind,
	needle: string,
	text:   string,
	opts:   json.Unmarshal_Opts,
}

@(private = "file")
LEAVES_COL_BLUE :: `{"n":null,"raw":1,"dec":1,"num":1,"cs":"c","r":"r","col":"Blue","wi":0,"wu":0}`

@(private = "file")
LOGS_SECOND_SHORT :: `{"logs":[` + UM_FLAT_TEXT + `,{"name":"x","count":1,"ratio":1,"ok":true,"small":1}]}`

@(private = "file")
LOGS_FIRST_UNKNOWN :: `{"logs":[{"zz":0,"name":"x","count":1,"ratio":1,"ok":true,"small":1,"half":1}]}`

// Every kind but `None`, `Plan_Mismatch` and `Out_Of_Memory` (the private suite's). Each `.Strict` row is also
// read `.Lazy`, which must agree on kind, offset and path: every fault here sits in a value the type reads.
@(test)
test_unmarshal_refusal_matrix :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	refuse := json.Unmarshal_Opts{unknown_fields = .Refuse}
	dup := json.Unmarshal_Opts{duplicates = .Refuse}
	rows := [?]Um_Refusal{
		{into(Um_Outer), `{"id":1,"inner":{"name":"n",}}`, .Syntax, `}}`, `.inner.name: Syntax(Bad_Char)`, {}},
		{into([][]int), `[[1]]`, .Syntax, `[1]`, `[0]: Syntax(Too_Deep)`, {limits = {max_depth = 1}}},
		{into(Um_Tree), `{"kids":[1]}`, .Syntax, `[1]`, `.kids: Syntax(Too_Deep)`, {limits = {max_depth = 1}}},
		{into(Um_Deep), `{"a":{"b":[1,"x"],"m":{}}}`, .Wrong_Kind, `"x"`, `.a.b[1]: Wrong_Kind`, {}},
		{into([]int), `[1,]`, .Syntax, `]`, `[0]: Syntax(Bad_Char)`, {}},
		{into(Um_Ints), `{"a":"1","b":0,"c":0,"d":0,"e":0}`, .Wrong_Kind, `"1"`, `.a: Wrong_Kind`, {}},
		{into(Um_Maps), `{"by_name":{"a":"x"},"by_id":{},"small":{},"nested":{}}`, .Wrong_Kind, `"x"`, `.by_name.a: Wrong_Kind`, {}},
		{into(Um_Flat), `[1]`, .Wrong_Kind, `[`, `Wrong_Kind`, {}},
		{into(Um_Ints), `{"a":256,"b":0,"c":0,"d":0,"e":0}`, .Out_Of_Range, `256`, `.a: Out_Of_Range`, {}},
		{into(Um_Floats), `{"x":1e400,"y":0,"z":0}`, .Out_Of_Range, `1e400`, `.x: Out_Of_Range`, {}},
		{into(Um_Maps), `{"by_name":{},"by_id":{},"small":{"256":true},"nested":{}}`, .Out_Of_Range, `"256"`, `.small.256: Out_Of_Range`, {}},
		{into(Um_Leaves), LEAVES_COL_BLUE, .Not_A_Member, `"Blue"`, `.col: Not_A_Member`, {}},
		{into(Um_Key_Kinds), `{"by_color":{"Blue":1},"by_wide":{}}`, .Not_A_Member, `"Blue"`, `.by_color.Blue: Not_A_Member`, {}},
		{into_ints(Um_Key_Kinds), `{"by_color":{"9":1},"by_wide":{}}`, .Not_A_Member, `"9"`, `.by_color.9: Not_A_Member`, {}},
		{into([3]int), `[1,2]`, .Wrong_Length, `]`, `Wrong_Length`, {}},
		{into(Um_Seq), `{"ints":[],"names":[],"trio":[1,2,3,4],"by":[5,6],"few":[],"grid":[]}`, .Wrong_Length, `4]`, `.trio[3]: Wrong_Length`, {}},
		{into(Um_Seq), `{"ints":[],"names":[],"trio":[1,2,3],"by":[5,6],"few":[1,2,3,4,5],"grid":[]}`, .Wrong_Length, `5]`, `.few[4]: Wrong_Length`, {}},
		{into(Um_Flat), `{}`, .Missing_Field, `}`, `.name: Missing_Field`, {}},
		{into(Um_Deep), `{"a":{"b":[],"m":{"k":{"e":1}}}}`, .Missing_Field, `}}}`, `.a.m.k.alpha: Missing_Field`, {}},
		{into(Um_Logs), LOGS_SECOND_SHORT, .Missing_Field, `}]}`, `.logs[1].half: Missing_Field`, {}},
		{into(Um_Tagged), `{"alpha":1,"b":"x","e":2}`, .Unknown_Field, `"b"`, `.b: Unknown_Field`, refuse},
		{into(Um_Deep), `{"a":{"b":[],"m":{},"zz":1}}`, .Unknown_Field, `"zz"`, `.a.zz: Unknown_Field`, refuse},
		{into(Um_Logs), LOGS_FIRST_UNKNOWN, .Unknown_Field, `"zz"`, `.logs[0].zz: Unknown_Field`, refuse},
		{into(Um_Outer), `{"id":1,"inner":{"name":"n"},"tail":"t"}`, .Syntax, `{"name"`, `.inner: Syntax(Too_Deep)`, {limits = {max_depth = 1}}},
		{into(Um_Bits), `{`, .Unsupported, ``, `.b: Unsupported`, {}},
		{into(Um_Clash), `{`, .Unsupported, ``, `.a: Unsupported`, {}},
		{into([]Um_Bits), `[`, .Unsupported, ``, `[*].b: Unsupported`, {}},
		{into(map[string]Um_Bits), `{`, .Unsupported, ``, `[*].b: Unsupported`, {}},
		{into(^Um_Bits), `{`, .Unsupported, ``, `.b: Unsupported`, {}},
		{into(Um_Bad_Tag), `{`, .Bad_Tag, ``, `Bad_Tag`, {}},
		{into([]Um_Bad_Tag), `[`, .Bad_Tag, ``, `Bad_Tag`, {}},
		{into(Um_Union), `{`, .Ambiguous_Union, ``, `.u: Ambiguous_Union`, {}},
		{into_tagged(Um_Drawing), `{"shapes":[{"r":1}],"one":"s"}`, .Missing_Tag, `{"r"`, `.shapes[0]: Missing_Tag`, {}},
		{into_tagged(map[string]Um_Shape), `{"a":{"type":"Um_Circle","r":1},"b":{"side":2}}`, .Missing_Tag, `{"side"`, `.b: Missing_Tag`, {}},
		{into_tagged(Um_Drawing), `{"shapes":[{"type":"Um_Circle","r":1,"type":"Um_Square"}],"one":"s"}`, .Repeated_Tag, `"type":"Um_Square"`, `.shapes[0].type: Repeated_Tag`, {}},
		{into_tagged(map[string]Um_Shape), `{"a":{"type":"Um_Square","type":"Um_Square","side":1}}`, .Repeated_Tag, `"type":"Um_Square","side"`, `.a.type: Repeated_Tag`, refuse},
		{into(^Um_Union), `{`, .Ambiguous_Union, ``, `.u: Ambiguous_Union`, {}},
		{into(Um_Tagged), `{"alpha":1,"\u0061lpha":2,"e":2}`, .Duplicate_Key, `"\u0061lpha"`, `.alpha: Duplicate_Key`, dup},
		{into(Um_Maps), `{"by_name":{"a":1,"a":2},"by_id":{},"small":{},"nested":{}}`, .Duplicate_Key, `"a":2`, `.by_name.a: Duplicate_Key`, dup},
		{into(Um_Logs), `{"logs":[{"zz":0,"name":"x","zz":1}]}`, .Duplicate_Key, `"zz":1`, `.logs[0].zz: Duplicate_Key`, dup},
		{into_tagged(Um_Drawing), `{"shapes":[{"type":"Um_Circle","r":1,"type":"Um_Square"}],"one":"s"}`, .Duplicate_Key, `"type":"Um_Square"`, `.shapes[0].type: Duplicate_Key`, dup},
		{into_nil(Um_Flat), UM_FLAT_TEXT, .Bad_Option, ``, `Bad_Option`, {}},
		{into_nil([]int), `[1]`, .Bad_Option, ``, `Bad_Option`, {duplicates = .First}},
		{into(Um_Flat), UM_FLAT_TEXT, .Bad_Option, ``, `Bad_Option`, {strictness = .Structural}},
	}
	rows_per_kind: [json.Unmarshal_Error_Kind]int
	for row in rows {
		rows_per_kind[row.kind] += 1
		lazy := row.opts
		lazy.strictness = .Lazy
		for opts, pass in ([2]json.Unmarshal_Opts{row.opts, lazy}) {
			if pass == 1 && (row.opts.strictness != .Strict || row.kind == .Bad_Option) {
				break
			}
			err := row.read(row.src, opts)
			testing.expectf(t, err.kind == row.kind, "%s (%v): kind %v, want %v", row.src, opts.strictness, err.kind, row.kind)
			testing.expectf(t, err.offset == at(row.src, row.needle), "%s (%v): offset %d, want %d", row.src, opts.strictness, err.offset, at(row.src, row.needle))
			got := path_text(err)
			testing.expectf(t, got == row.text, "%s (%v): %s, want %s", row.src, opts.strictness, got, row.text)
		}
	}
	for n, kind in rows_per_kind {
		if kind != .Plan_Mismatch && kind != .Out_Of_Memory {
			testing.expectf(t, n >= 2, "%v has %d rows", kind, n)
		}
	}
}

@(private = "file")
Um_Head :: struct {
	name: string,
	port: int,
}

// A number nothing reads is checked as `validate` checks it: refused at the same byte and kind, or read. Each
// token sits in a member the type skips, before a known one, last, nested and cut off, with `,"`, white space
// and `}` after it, under the default caps and a digit cap the skip has to keep.
@(test)
test_unmarshal_checks_unread_numbers_as_validate_does :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	tokens := []string{
		"0", "-0", "7", "-7", "12345678", "123456789", "1234567890", "123456781234567", "1234567812345678",
		"12345678123456789", "18446744073709551615", "18446744073709551616", "1.5", "-0.0", "1e400", "1E-400",
		"1e+5", "1.5e3", "123456789012345678901234567890",
		"01", "00", "-01", "-", "--1", "-a", "+1", "1.", "1.e5", ".5", "1e", "1e+", "1E-", "1e5.5", "1.5.5",
		"1x", "1.5x", "1e5x", "12345678x", "1234567812345678x", "0x10", "1-", "1+", "1e99999", "1e-99999",
		"1.0e4097", "0.", "-.5", "1e400000000000000000000", "1\x80", "123456789\xff",
	}
	digits_cap := json.Limits{max_scalar_digits = 5}
	for tok in tokens {
		// Concatenated: `fmt` reads a brace as a format argument.
		cat :: proc(parts: ..string) -> string {return strings.concatenate(parts, context.temp_allocator)}
		docs := []string{
			cat(`{"skip":`, tok, `,"name":"s","port":1}`),
			cat(`{"name":"s","port":1,"skip":`, tok, `}`),
			cat(`{"name":"s","skip":`, tok, ` ,"k2":`, tok, `}`),
			cat(`{"skip":{"in":[`, tok, `]},"port":1}`),
			cat(`{"skip":`, tok),
		}
		for doc in docs {
			src := transmute([]byte)doc
			for limits in ([]json.Limits{{}, digits_cap}) {
				opts := json.Unmarshal_Opts{limits = limits}
				want, refused := json.validate(src, {limits = limits}).?
				v: Um_Head
				read := um_err(json.unmarshal(src, &v, opts, nil, context.temp_allocator))
				checked := um_err(json.unmarshal_check(src, Um_Head, opts))
				for err, arm in ([2]json.Unmarshal_Error{read, checked}) {
					if refused {
						testing.expectf(t, err.kind == .Syntax && err.syntax == want.kind && err.offset == want.offset,
							"%s (cap %d, arm %d): %v %v at %d, want %v at %d", doc, limits.max_scalar_digits, arm, err.kind, err.syntax, err.offset, want.kind, want.offset)
					} else {
						testing.expectf(t, err == {}, "%s (cap %d, arm %d): %v", doc, limits.max_scalar_digits, arm, err.kind)
					}
				}
			}
		}
	}
}
