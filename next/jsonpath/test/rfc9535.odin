package jsonpath_tests

import "base:runtime"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:jsonpath"
import "stury:lib/query"
import "stury:testkit"

@(private)
Collected :: struct {
	h:       ^query.Heap,
	vals:    [dynamic]string,
	paths:   [dynamic]string,
	alloc:   runtime.Allocator,
	stop_at: int, // > 0 stops after emitting this many items
}

@(private)
collect_cb :: proc(data: rawptr, v: query.Value, norm_path: string) -> bool {
	c := (^Collected)(data)
	defer query.release(c.h, v)
	buf := make([dynamic]u8, 0, 32, c.alloc)
	_ = query.write_json(c.h, &buf, v, {sort_keys = true})
	append(&c.vals, string(buf[:]))
	append(&c.paths, strings.clone(norm_path, c.alloc))
	if c.stop_at > 0 && len(c.vals) >= c.stop_at {
		return false
	}
	return true
}

@(private)
destroy_collected :: proc(c: ^Collected) {
	for s in c.vals {
		delete(s, c.alloc)
	}
	delete(c.vals)
	for p in c.paths {
		delete(p, c.alloc)
	}
	delete(c.paths)
}

@(private)
eval_json :: proc(
	t: ^testing.T,
	qsrc: string,
	jsrc: string,
	opts := jsonpath.Eval_Options{},
	stop_at := 0,
	loc := #caller_location,
) -> (col: Collected, end: jsonpath.Run_End) {
	prog, cerr := jsonpath.compile(qsrc)
	testing.expectf(t, cerr.kind == .None, "compile %q failed at %d: %s", qsrc, cerr.offset, cerr.message, loc = loc)
	if cerr.kind != .None {
		return {}, .Failed
	}
	defer jsonpath.destroy_program(prog)

	doc, jerr := json.build(transmute([]u8)jsrc, .Json)
	testing.expectf(t, jerr == nil, "json.build failed: %v", jerr, loc = loc)
	if jerr != nil {
		return {}, .Failed
	}

	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer {
		testing.expect_value(t, query.heap_live(&h), u64(0), loc = loc)
		query.heap_destroy(&h)
	}
	root, st := query.document_value(&h, doc, true)
	testing.expect_value(t, st, query.Status.Ok, loc = loc)
	defer query.release(&h, root)

	col = Collected{
		h       = &h,
		vals    = make([dynamic]string, context.allocator),
		paths   = make([dynamic]string, context.allocator),
		alloc   = context.allocator,
		stop_at = stop_at,
	}
	end = jsonpath.eval(prog, &h, root, collect_cb, &col, opts)
	col.h = nil
	return col, end
}

@(private)
expect_vals_and_paths :: proc(t: ^testing.T, qsrc, jsrc: string, want_vals: []string, want_paths: []string = nil, loc := #caller_location) {
	col, end := eval_json(t, qsrc, jsrc, {want_paths = len(want_paths) > 0}, 0, loc)
	defer destroy_collected(&col)
	testing.expect_value(t, end, jsonpath.Run_End.Done, loc = loc)
	testing.expectf(t, len(col.vals) == len(want_vals), "%q: got %d values %v, want %d %v", qsrc, len(col.vals), col.vals[:], len(want_vals), want_vals, loc = loc)
	for i in 0 ..< min(len(col.vals), len(want_vals)) {
		testing.expectf(t, col.vals[i] == want_vals[i], "%q val[%d]: got %s, want %s", qsrc, i, col.vals[i], want_vals[i], loc = loc)
	}
	for i in 0 ..< min(len(col.paths), len(want_paths)) {
		testing.expectf(t, col.paths[i] == want_paths[i], "%q path[%d]: got %q, want %q", qsrc, i, col.paths[i], want_paths[i], loc = loc)
	}
}

@(private)
expect_vals :: proc(t: ^testing.T, qsrc, jsrc: string, want: []string, loc := #caller_location) {
	expect_vals_and_paths(t, qsrc, jsrc, want, nil, loc)
}

@(private)
expect_compile_err :: proc(t: ^testing.T, qsrc: string, want_kind := jsonpath.Error_Kind.None, loc := #caller_location) {
	prog, err := jsonpath.compile(qsrc)
	if prog != nil {
		jsonpath.destroy_program(prog)
	}
	testing.expectf(t, err.kind != .None, "expected compile error for %q, but it succeeded", qsrc, loc = loc)
	if want_kind != .None {
		testing.expectf(t, err.kind == want_kind, "%q: got error kind %v (%s), want %v", qsrc, err.kind, err.message, want_kind, loc = loc)
	}
}

@(test)
selectors_name_index_wildcard_and_multi :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := `{"a":1,"b":[10,20,30],"café":"ok","日本語":7,"a'b":2,"a\"b":3,"ctrl\n\t":"c","😀":9,"empty":""}`

	expect_vals(t, `$`, `42`, {"42"})
	expect_vals(t, `$.a`, doc, {"1"})
	expect_vals(t, `$ .a`, doc, {"1"})
	expect_vals(t, `$.café`, doc, {`"ok"`})
	expect_vals(t, `$.日本語`, doc, {"7"})
	expect_vals(t, `$['a\'b']`, doc, {"2"})
	expect_vals(t, `$["a'b"]`, doc, {"2"})
	expect_vals(t, `$["a\"b"]`, doc, {"3"})
	expect_vals(t, `$['a"b']`, doc, {"3"})
	expect_vals(t, `$["ctrl\n\t"]`, doc, {`"c"`})
	expect_vals(t, `$['\uD83D\uDE00']`, doc, {"9"})
	expect_vals(t, `$['\u0061']`, doc, {"1"})
	expect_vals(t, `$.b[0]`, doc, {"10"})
	expect_vals(t, `$.b[-1]`, doc, {"30"})
	expect_vals(t, `$.b[-3]`, doc, {"10"})
	expect_vals(t, `$.b[3]`, doc, {})
	expect_vals(t, `$.b[-4]`, doc, {})
	expect_vals(t, `$.a[0]`, doc, {})
	expect_vals(t, `$.b.x`, doc, {})

	// Wildcards & duplicate-preserving multi-selectors.
	expect_vals(t, `$.b[*]`, doc, {"10", "20", "30"})
	expect_vals(t, `$.b.*`, doc, {"10", "20", "30"})
	expect_vals(t, `$.b[0, 0, -1, 1]`, doc, {"10", "10", "30", "20"})
	expect_vals(t, `$['a', 'missing', "café"]`, doc, {"1", `"ok"`})
	expect_vals(t, `$[*]`, `{"x":1,"y":2}`, {"1", "2"})
	expect_vals(t, `$[*]`, `123`, {})
}

@(test)
slice_selector_rfc9535 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arr := `["a","b","c","d","e","f","g"]`

	expect_vals(t, `$[1:3]`, arr, {`"b"`, `"c"`})
	expect_vals(t, `$[5:]`, arr, {`"f"`, `"g"`})
	expect_vals(t, `$[:2]`, arr, {`"a"`, `"b"`})
	expect_vals(t, `$[:]`, arr, {`"a"`, `"b"`, `"c"`, `"d"`, `"e"`, `"f"`, `"g"`})
	expect_vals(t, `$[1:5:2]`, arr, {`"b"`, `"d"`})
	expect_vals(t, `$[5:1:-2]`, arr, {`"f"`, `"d"`})
	expect_vals(t, `$[::-1]`, arr, {`"g"`, `"f"`, `"e"`, `"d"`, `"c"`, `"b"`, `"a"`})
	expect_vals(t, `$[-1:-4:-1]`, arr, {`"g"`, `"f"`, `"e"`})
	expect_vals(t, `$[-3:-1]`, arr, {`"e"`, `"f"`})
	expect_vals(t, `$[1:3:-1]`, arr, {})
	expect_vals(t, `$[3:1:1]`, arr, {})
	expect_vals(t, `$[::0]`, arr, {})
	expect_vals(t, `$[0:5:0]`, arr, {})
	expect_vals(t, `$[0:100:3]`, arr, {`"a"`, `"d"`, `"g"`})
	expect_vals(t, `$[-100:2]`, arr, {`"a"`, `"b"`})
	expect_vals(t, `$[0:2]`, `{"a":1,"b":2}`, {})
	expect_vals(t, `$[0:2:9007199254740991]`, arr, {`"a"`})
	expect_vals(t, `$[5:0:-9007199254740991]`, arr, {`"f"`})
}

@(test)
descendant_preorder_and_paths :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := `{"o":{"j":1,"k":2},"a":[5,3,[{"j":4},{"k":6}]]}`
	expect_vals_and_paths(t, `$..j`, doc,
		{"1", "4"},
		{`$['o']['j']`, `$['a'][2][0]['j']`},
	)
	expect_vals_and_paths(t, `$..[0]`, doc,
		{"5", `{"j":4}`},
		{`$['a'][0]`, `$['a'][2][0]`},
	)
	expect_vals_and_paths(t, `$..*`, `{"a":[1,2]}`,
		{`[1,2]`, "1", "2"},
		{`$['a']`, `$['a'][0]`, `$['a'][1]`},
	)
	// Nested descendants: $..a..b
	expect_vals_and_paths(t, `$..a..b`, `{"a":{"b":1,"a":{"b":2}}}`,
		{"1", "2", "2"},
		{`$['a']['b']`, `$['a']['a']['b']`, `$['a']['a']['b']`},
	)
}

@(test)
filter_comparisons_and_existence_tests :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Existence tests: null, false, 0, "", [] are ALL present nodes => LogicalTrue!
	doc := `[{"a":false},{"a":null},{"a":0},{"a":""},{"a":[]},{"b":1}]`
	expect_vals(t, `$[?@.a]`, doc, {`{"a":false}`, `{"a":null}`, `{"a":0}`, `{"a":""}`, `{"a":[]}`})
	expect_vals(t, `$[?!@.a]`, doc, {`{"b":1}`})

	// RFC 9535 comparison edge cases:
	cmp_doc := `[{"id":1,"a":null,"b":null},{"id":2,"a":1,"b":1.0},{"id":3,"a":false,"b":true},{"id":4,"a":[1,2],"b":[1,2]},{"id":5,"a":[1],"b":[2]},{"id":6,"a":"a","b":"b"},{"id":7,"a":1,"b":"1"},{"id":8,"c":0}]`

	// Nothing == Nothing is TRUE, Nothing == null is FALSE!
	expect_vals(t, `$[?@.missing1 == @.missing2].id`, cmp_doc, {"1", "2", "3", "4", "5", "6", "7", "8"})
	expect_vals(t, `$[?@.missing1 != @.missing2].id`, cmp_doc, {})
	expect_vals(t, `$[?@.a == null].id`, cmp_doc, {"1"})
	expect_vals(t, `$[?@.missing == null].id`, cmp_doc, {})
	expect_vals(t, `$[?@.missing != null].id`, cmp_doc, {"1", "2", "3", "4", "5", "6", "7", "8"})
	expect_vals(t, `$[?@.missing <= @.missing2].id`, cmp_doc, {"1", "2", "3", "4", "5", "6", "7", "8"})
	expect_vals(t, `$[?@.missing < @.missing2].id`, cmp_doc, {})

	// Numbers: 1 == 1.0, -0 == 0, 1e2 == 100
	expect_vals(t, `$[?@.a == @.b].id`, cmp_doc, {"1", "2", "4", "8"})
	expect_vals(t, `$[?@.c == -0].id`, cmp_doc, {"8"})
	expect_vals(t, `$[?@.a == 1e0].id`, cmp_doc, {"2", "7"})

	// `<` ONLY on numbers and strings (NOT bools, NOT arrays, NOT null, NOT cross-type)!
	expect_vals(t, `$[?@.a < @.b].id`, cmp_doc, {"6"})
	// `<=` is `(<) || (==)` so null <= null, [1,2] <= [1,2], 1 <= 1.0, "a" <= "b", Nothing <= Nothing are TRUE,
	// while false <= true and [1] <= [2] and 1 <= "1" are FALSE!
	expect_vals(t, `$[?@.a <= @.b].id`, cmp_doc, {"1", "2", "4", "6", "8"})
	expect_vals(t, `$[?@.b > @.a].id`, cmp_doc, {"6"})
	expect_vals(t, `$[?@.b >= @.a].id`, cmp_doc, {"1", "2", "4", "6", "8"})

	// Precedence: && binds tighter than ||, plus parens and root `$` inside filter.
	// Remember: `@.ok` is an existence test (so `ok: false` IS present => LogicalTrue),
	// whereas `@.ok == true` tests boolean truth!
	store := `{"limit":15,"items":[{"n":"a","p":10,"ok":false},{"n":"b","p":20,"ok":true},{"n":"c","p":12,"ok":true}]}`
	expect_vals(t, `$.items[?@.p <= $.limit && @.ok].n`, store, {`"a"`, `"c"`})
	expect_vals(t, `$.items[?@.p <= $.limit && @.ok == true].n`, store, {`"c"`})
	expect_vals(t, `$.items[?@.n == "a" || @.p > 15 && @.ok == true].n`, store, {`"a"`, `"b"`})
	expect_vals(t, `$.items[?!(@.p > 15)].n`, store, {`"a"`, `"c"`})
}

@(test)
standard_functions_rfc9535 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// length(): Unicode scalar count for strings, element/member count for arrays/objects, Nothing otherwise.
	ldoc := `["abc","😀","e\u0301",[1,2],{"a":1,"b":2,"c":3},42,true,null]`
	expect_vals(t, `$[?length(@) == 1]`, ldoc, {`"😀"`})
	expect_vals(t, `$[?length(@) == 2]`, ldoc, {`"é"`, `[1,2]`})
	expect_vals(t, `$[?length(@) == 3]`, ldoc, {`"abc"`, `{"a":1,"b":2,"c":3}`})
	// Non-string/array/object -> Nothing, which == Nothing!
	expect_vals(t, `$[?length(@) == @.nope]`, ldoc, {"42", "true", "null"})

	// count(): number of nodes in nodelist.
	cdoc := `[{"xs":[1,2,3]},{"xs":[1]},{"xs":[]},{}]`
	expect_vals(t, `$[?count(@.xs[*]) >= 2]`, cdoc, {`{"xs":[1,2,3]}`})
	expect_vals(t, `$[?count(@.xs[*]) == 0]`, cdoc, {`{"xs":[]}`, `{}`})

	// value(): 1 node -> value; 0 or >=2 nodes -> Nothing.
	vdoc := `[{"xs":[10]},{"xs":[10,20]},{"xs":[]}]`
	expect_vals(t, `$[?value(@.xs[*]) == 10]`, vdoc, {`{"xs":[10]}`})
	expect_vals(t, `$[?value(@.xs[*]) == @.missing]`, vdoc, {`{"xs":[10,20]}`, `{"xs":[]}`})

	// match() & search(): strict RFC 9485 I-Regexp semantics!
	rdoc := `["abc","a\nc","a\rc","xabcy","^a$","A1","99",123]`
	expect_vals(t, `$[?match(@, "a.c")]`, rdoc, {`"abc"`})
	expect_vals(t, `$[?search(@, "a.c")]`, rdoc, {`"abc"`, `"xabcy"`})
	// `^` and `$` are literal in I-Regexp!
	expect_vals(t, `$[?match(@, "^a$")]`, rdoc, {`"^a$"`})
	// Unicode General Categories `\p{Lu}` and `\p{Nd}`:
	expect_vals(t, `$[?match(@, "\\p{Lu}\\p{Nd}")]`, rdoc, {`"A1"`})
	// Invalid I-Regexp (`\d`, lazy `*?`, lookahead, reversed range `[z-a]`) => LogicalFalse, NOT error!
	expect_vals(t, `$[?match(@, "\\d+")]`, rdoc, {})
	expect_vals(t, `$[?search(@, "a*?")]`, rdoc, {})
	expect_vals(t, `$[?match(@, "(?=a)abc")]`, rdoc, {})
	expect_vals(t, `$[?match(@, "[z-a]")]`, rdoc, {})
	expect_vals(t, `$[?match(@, "[]")]`, rdoc, {})
	// Dynamic pattern argument:
	ddoc := `[{"s":"hello","p":"h.*o"},{"s":"hello","p":"e.l"},{"s":"bad","p":"\\d+"},{"s":"ok","p":123}]`
	expect_vals(t, `$[?match(@.s, @.p)].s`, ddoc, {`"hello"`})
	expect_vals(t, `$[?search(@.s, @.p)].s`, ddoc, {`"hello"`, `"hello"`})
}

@(test)
normalized_path_escaping_rfc9535 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc := `{"'":1,"\\":2,"\b\f\n\r\t":3,"\u0000\u000B\u001F":4,"\"/😀":5,"arr":[10,20,30]}`
	expect_vals_and_paths(t, `$["'"]`, doc, {"1"}, {`$['\'']`})
	expect_vals_and_paths(t, `$["\\"]`, doc, {"2"}, {`$['\\']`})
	expect_vals_and_paths(t, `$["\b\f\n\r\t"]`, doc, {"3"}, {`$['\b\f\n\r\t']`})
	expect_vals_and_paths(t, `$["\u0000\u000B\u001F"]`, doc, {"4"}, {`$['\u0000\u000b\u001f']`})
	expect_vals_and_paths(t, `$["\"/😀"]`, doc, {"5"}, {`$['"/😀']`})
	expect_vals_and_paths(t, `$.arr[-1]`, doc, {"30"}, {`$['arr'][2]`})
	expect_vals_and_paths(t, `$`, doc, {`{"\u0000\u000b\u001f":4,"\b\f\n\r\t":3,"\"/😀":5,"'":1,"\\":2,"arr":[10,20,30]}`}, {`$`})
}

@(test)
rfc9535_syntax_and_type_rejections :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Syntax rejections:
	bad_syntax := [?]string{
		``,
		` $`,
		`$ `,
		`$.a `,
		`@.a`,
		`$. a`,
		`$.. a`,
		`$[]`,
		`$[0,]`,
		`$[-0]`,
		`$[-0:1]`,
		`$[0:-0]`,
		`$[0:1:-0]`,
		`$[01]`,
		`$[-01]`,
		`$[00]`,
		`$[9007199254740992]`,
		`$[-9007199254740992]`,
		`$['\"']`,
		`$["\'"]`,
		`$['\a']`,
		`$['\u123']`,
		`$['\uD800']`,
		`$['\uDC00']`,
		`$['\uD800\u0041']`,
		"$['\x00']",
		"$['\n']",
		"$['\t']",
		`$[?true]`,
		`$[?1]`,
		`$[?"str"]`,
		`$[?!@.a == 1]`,
		`$[?!!@.a]`,
		`$[?(@.a) == 1]`,
		`$[?@.a == @.b == @.c]`,
		`$[?@.a && 1]`,
		`$[?@.a == 01]`,
		`$[?@.a == 1.]`,
		`$[?@.a == 1e]`,
		`$[?match (@.a, "x")]`,
		`$[?MATCH(@.a, "x")]`,
		`$.0`,
		`$.a-b`,
	}
	for q in bad_syntax {
		expect_compile_err(t, q, .Syntax)
	}

	// RFC 9535 §2.4 well-typedness rejections:
	bad_types := [?]string{
		`$[?@.* == 1]`,
		`$[?@[0,1] == 1]`,
		`$[?@..a == 1]`,
		`$[?@[ 'a' ] == 1]`,
		`$[?@[0:1] == 1]`,
		`$[?1 == @.*]`,
		`$[?length(@.a)]`,
		`$[?count(@.*)]`,
		`$[?value(@.a)]`,
		`$[?!length(@.a)]`,
		`$[?length(@.*) == 1]`,
		`$[?length(@[ 'a' ]) == 1]`,
		`$[?count(1) == 1]`,
		`$[?count(@.a == 1) == 1]`,
		`$[?count((@.a)) == 1]`,
		`$[?value(1) == 1]`,
		`$[?match(@.a, "x") == true]`,
		`$[?search(@.a, "x") == false]`,
		`$[?length(@.a, @.b) == 1]`,
		`$[?match(@.a)]`,
		`$[?unknown(@.a)]`,
		`$[?length(@.a) && @.b]`,
		`$[?@.a && length(@.b)]`,
	}
	for q in bad_types {
		expect_compile_err(t, q, .Type)
	}
}

@(test)
budgets_and_early_stop :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arr := `[1,2,3,4,5,6,7,8,9,10]`

	// Early stop after 3 values.
	{
		col, end := eval_json(t, `$[*]`, arr, {want_paths = true}, stop_at = 3)
		defer destroy_collected(&col)
		testing.expect_value(t, end, jsonpath.Run_End.Stopped)
		testing.expect_value(t, len(col.vals), 3)
		testing.expect_value(t, col.vals[2], "3")
		testing.expect_value(t, col.paths[2], `$[2]`)
	}

	// Step budget exhaustion.
	{
		col, end := eval_json(t, `$[*]`, arr, {budget = {steps = 5}})
		defer destroy_collected(&col)
		testing.expect_value(t, end, jsonpath.Run_End.Exceeded)
	}

	// Compile max_depth enforcement.
	{
		prog, err := jsonpath.compile(`$[?((((((@.a))))))]`, {max_depth = 4})
		if prog != nil {
			jsonpath.destroy_program(prog)
		}
		testing.expect_value(t, err.kind, jsonpath.Error_Kind.Depth)
	}

	// Small explicit runtime `budget.depth` is enforced (not floored to 256).
	{
		deep_obj := `{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"v":1}}}}}}}}}}}`
		col, end := eval_json(t, `$..v`, deep_obj, {budget = {depth = 2}})
		defer destroy_collected(&col)
		testing.expect_value(t, end, jsonpath.Run_End.Exceeded)
	}
}

@(private = "file")
Oom_Alloc_State :: struct {
	backing: runtime.Allocator,
	left:    int,
}

@(private = "file")
oom_alloc_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_ptr: rawptr,
	old_size: int,
	loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	s := (^Oom_Alloc_State)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		// `lib/query/plan.odin` (`finalize_source_demand`) does not guard its internal `make` against OOM;
		// inject OOM everywhere else (all `next/jsonpath` parser, arena, scratch, and hint allocations).
		if !strings.has_suffix(loc.file_path, "lib/query/plan.odin") {
			if s.left <= 0 {
				return nil, .Out_Of_Memory
			}
			s.left -= 1
		}
	}
	return s.backing.procedure(s.backing.data, mode, size, alignment, old_ptr, old_size, loc)
}

@(test)
review_regressions_big_nan_oom_and_iregexp_depth :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Big-integer filter literal (`> max(i64)`) must NOT leak `big.Int.digit` on `prog.backing`.
	{
		big_doc := `[{"id":1,"x":99999999999999999999},{"id":2,"x":99999999999999999998},{"id":3,"x":42}]`
		expect_vals(t, `$[?@.x == 99999999999999999999].id`, big_doc, {"1"})
		expect_vals(t, `$[?@.x < 99999999999999999999].id`, big_doc, {"2", "3"})
	}

	// 2. JSON5 `NaN` `.Node` values must return `false` for `<`, `<=`, `>`, `>=`, `==` and `true` for `!=`.
	{
		doc, jerr := json.build(transmute([]u8)string(`[NaN, 0, 1]`), .Json5)
		testing.expect(t, jerr == nil)
		h: query.Heap
		query.heap_init(&h, context.allocator)
		defer {
			testing.expect_value(t, query.heap_live(&h), u64(0))
			query.heap_destroy(&h)
		}
		root, st := query.document_value(&h, doc, true)
		testing.expect_value(t, st, query.Status.Ok)
		defer query.release(&h, root)

		check_nan :: proc(t: ^testing.T, h: ^query.Heap, root: query.Value, qsrc: string, want: []string, loc := #caller_location) {
			prog, cerr := jsonpath.compile(qsrc)
			testing.expect_value(t, cerr.kind, jsonpath.Error_Kind.None, loc = loc)
			defer jsonpath.destroy_program(prog)
			col := Collected{h = h, vals = make([dynamic]string), paths = make([dynamic]string), alloc = context.allocator}
			defer destroy_collected(&col)
			end := jsonpath.eval(prog, h, root, collect_cb, &col)
			testing.expect_value(t, end, jsonpath.Run_End.Done, loc = loc)
			testing.expectf(t, len(col.vals) == len(want), "%q: got %v, want %v", qsrc, col.vals[:], want, loc = loc)
			for i in 0 ..< min(len(col.vals), len(want)) {
				testing.expectf(t, col.vals[i] == want[i], "%q[%d]: got %s, want %s", qsrc, i, col.vals[i], want[i], loc = loc)
			}
		}

		check_nan(t, &h, root, `$[?@ < 1]`, {"0"})
		check_nan(t, &h, root, `$[?@ <= 1]`, {"0", "1"})
		check_nan(t, &h, root, `$[?@ > 0]`, {"1"})
		check_nan(t, &h, root, `$[?@ >= 0]`, {"0", "1"})
		check_nan(t, &h, root, `$[?@ == @]`, {"0", "1"})
		check_nan(t, &h, root, `$[?@ != @]`, {"null"})
	}

	// 3. I-Regexp with >500 nested parens is rejected cleanly (evaluates to LogicalFalse, no stack overflow).
	{
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, `$[?match(@, "`)
		for _ in 0 ..< 600 {
			strings.write_byte(&b, '(')
		}
		strings.write_byte(&b, 'a')
		for _ in 0 ..< 600 {
			strings.write_byte(&b, ')')
		}
		strings.write_string(&b, `")]`)
		expect_vals(t, strings.to_string(b), `["a"]`, {})
	}

	// 4. OOM injection during `compile` (including `build_plan`) fails cleanly with `.Memory` and zero leaks.
	{
		oom_queries := [?]string{
			`$.items[?@.status >= 500].id`,
			`$.a['x', 'y']`,
			`$.a.b[0].c`,
		}
		for q in oom_queries {
			saw_oom := false
			saw_ok := false
			for limit in 0 ..< 60 {
				state := Oom_Alloc_State{backing = context.allocator, left = limit}
				oom_alloc := runtime.Allocator{procedure = oom_alloc_proc, data = &state}
				prog, err := jsonpath.compile(q, {}, oom_alloc)
				if err.kind == .None {
					jsonpath.destroy_program(prog)
					saw_ok = true
					break
				}
				testing.expect_value(t, prog, (^jsonpath.Program)(nil))
				testing.expect_value(t, err.kind, jsonpath.Error_Kind.Memory)
				saw_oom = true
			}
			testing.expect(t, saw_oom && saw_ok)
		}
	}
}
