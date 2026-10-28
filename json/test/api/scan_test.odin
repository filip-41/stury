package json_tests

import "base:runtime"
import json "../.."
import "core:slice"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

// Limits: a zero field means the documented default, and a caller can move
// either scalar cap and the depth cap. Raised caps accept what the defaults
// refuse, lowered caps refuse what the defaults accept.
@(test)
test_limits_dial :: proc(t: ^testing.T) {
	digits_300 := strings.repeat("7", 300)
	defer delete(digits_300)
	token := strings.concatenate({`[`, digits_300, `]`})
	defer delete(token)
	src := transmute([]byte)token

	// Default: 300 mantissa digits is past MAX_SCALAR_DIGITS (256).
	err, has_err := json.validate(src).?
	testing.expect(t, has_err, "300 digits refuses at the default cap")
	if has_err {
		testing.expect_value(t, err.kind, json.Error_Kind.Limit_Digits)
		// Pure-integer shape: the refusal comes from `parse_number_q`'s integer-run cap check, at the token's first byte.
		testing.expect_value(t, err.offset, 1)
	}
	// Raised: the same token is legal.
	_, raised_err := verdict_under(src, .Strict, json.Limits{max_scalar_digits = 512}).?
	testing.expect(t, !raised_err, "300 digits is legal when the cap is raised")
	// Lowered: a 3-digit token refuses at 2.
	low_src := `[123]`
	_, low_err := verdict_under(transmute([]byte)low_src, .Strict, json.Limits{max_scalar_digits = 2}).?
	testing.expect(t, low_err, "3 digits refuses at a cap of 2")

	// Scale cap: 1e4097 is past the default (`test_scalar_caps`).
	scale_bad_src := `[1e4097]`
	_, scale_raised := verdict_under(transmute([]byte)scale_bad_src, .Strict, json.Limits{max_scalar_scale = 8192}).?
	testing.expect(t, !scale_raised, "1e4097 is legal when the scale cap is raised")

	// Depth cap, both directions.
	deep_ok := transmute([]byte)nested_arrays(40)
	_, d_ok := json.validate(deep_ok).?
	testing.expect(t, !d_ok, "40 levels is within the default depth cap")
	derr, d_low := verdict_under(deep_ok, .Strict, json.Limits{max_depth = 8}).?
	testing.expect(t, d_low, "40 levels refuses at a depth cap of 8")
	if d_low {
		testing.expect_value(t, derr.kind, json.Error_Kind.Too_Deep)
	}

	// A zero strictness and zero Limits is the documented default dial.
	def_src := `{"a":1}`
	_, def_err := json.validate(transmute([]byte)def_src).?
	testing.expect(t, !def_err, "validate(src) is the default strictness and caps")
	for refused in ([]struct {
		src:  string,
		kind: json.Error_Kind,
	}{{`[01]`, .Bad_Number}, {`["\x"]`, .Bad_Escape}, {`[truX]`, .Bad_Char}, {`[1e]`, .Bad_Number}}) {
		got, has := json.validate(transmute([]byte)refused.src).?
		testing.expectf(t, has, "validate(%q) with no strictness argument must refuse", refused.src)
		testing.expect_value(t, got.kind, refused.kind)
	}

	// Zero means the documented default on each axis, not "no limit".
	_, z_depth := verdict_under(deep_ok, .Strict, json.Limits{max_depth = 0}).?
	testing.expect(t, !z_depth, "max_depth 0 is MAX_DEPTH, not unlimited")
	_, z_digits := verdict_under(src, .Strict, json.Limits{max_scalar_digits = 0}).?
	testing.expect(t, z_digits, "max_scalar_digits 0 is MAX_SCALAR_DIGITS")
	_, z_scale := verdict_under(transmute([]byte)scale_bad_src, .Strict, json.Limits{max_scalar_scale = 0}).?
	testing.expect(t, z_scale, "max_scalar_scale 0 is MAX_SCALAR_SCALE")
}

// `.Structural` is what `Strictness` says: framing, the depth cap and wire UTF-8 refuse as under `.Strict`,
// and no scalar's body is checked, nor are the scalar caps.
@(test)
test_structural_judges_framing_not_scalars :: proc(t: ^testing.T) {
	deep := nested_arrays(1025)
	refused := []struct {
		src:  string,
		kind: json.Error_Kind,
	}{
		{`[1 2]`, .Bad_Char},
		{`[1,]`, .Bad_Char},
		{`{1:2}`, .Bad_Char},
		{`{"a" 1}`, .Bad_Char},
		{`[xyz]`, .Bad_Char},
		{"[\"\xff\"]", .Bad_Char},
		{"[\"\xed\xa0\x80\"]", .Bad_Char},
		{`[1]x`, .Trailing},
		{`[`, .Truncated},
		{deep, .Too_Deep},
	}
	for c in refused {
		e, bad := json.validate(transmute([]byte)c.src, {strictness = .Structural}).?
		testing.expectf(t, bad && e.kind == c.kind, "%.20q: %v, want %v", c.src, e, c.kind)
		testing.expectf(t, json.validate(transmute([]byte)c.src) != nil, "%.20q: .Strict accepted", c.src)
	}
	for src in ([]string{`[tru]`, `[truefalse]`, `[01]`, `[1.]`, `[-]`, `[1e5000]`, `["a\qb"]`, "[\"a\x01b\"]"}) {
		testing.expectf(t, json.validate(transmute([]byte)src, {strictness = .Structural}) == nil, "%q: .Structural refused", src)
		testing.expectf(t, json.validate(transmute([]byte)src) != nil, "%q: .Strict accepted", src)
	}
}

// A path scan at `.Structural` walks every byte of the item, so a value no path reads is checked for wire UTF-8
// as `validate` checks it, at any position and input size. `.Lazy` may leave it unread.
@(test)
test_structural_path_scan_checks_skipped_utf8 :: proc(t: ^testing.T) {
	filler := strings.repeat("1000000,", 20000)
	defer delete(filler)
	long := strings.repeat("abcdefghijklmnopqrstuvwxyz0123456789", 4000)
	defer delete(long)
	big_array := strings.concatenate({`{"a":1,"p":[`, filler, `0],"z":"`, "\xff", `"}`})
	defer delete(big_array)
	big_inside := strings.concatenate({`{"a":1,"p":[`, filler, "\"\xff\"],\"q\":2}"})
	defer delete(big_inside)
	big_string := strings.concatenate({`{"a":1,"z":"`, long, "\xff", `"}`})
	defer delete(big_string)
	docs := []string{
		"{\"a\":1,\"z\":\"\xff\"}",
		"{\"z\":\"\xff\",\"a\":1}",
		"{\"a\":1,\"z\":{\"y\":[\"\xff\"]}}",
		"{\"b\":1,\"z\":\"\xff\"}",
		"{\"a\":1,\"z\":\"\xe2\x82\"}", // a cut sequence
		"{\"a\":1,\"z\":[\"ok\",\"\xed\xa0\x80\"]}", // a surrogate
		"{\"a\":1,\"z\":\xff}", // a bare scalar
		"{\"a\":1,\"\xff\":2}",
		big_array,
		big_inside,
		big_string,
	}
	accepted := []string{
		"{\"a\":1,\"z\":\"\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80\",\"y\":[\"\xc3\xa9\"]}",
		`{"a":1,"z":"\u00ff"}`,
	}
	for dialect in ([]json.Dialect{.Json, .Jsonc}) {
		for src in docs {
			req: json.Request({.Path})
			defer json.destroy(&req)
			_ = request_of(&req, []json.Path{{steps = {json.Name("a")}}}, {strictness = .Structural, dialect = dialect})
			got := json.scan(transmute([]byte)src, &req)
			want := json.validate(transmute([]byte)src, {strictness = .Structural})
			testing.expectf(t, want != nil, "%.30q: validate accepted", src)
			testing.expectf(t, got == source(want), "%.30q (%v): scan %v, validate %v", src, dialect, got, want)
		}
		for src in accepted {
			req: json.Request({.Path})
			defer json.destroy(&req)
			_ = request_of(&req, []json.Path{{steps = {json.Name("a")}}}, {strictness = .Structural, dialect = dialect})
			testing.expect_value(t, json.scan(transmute([]byte)src, &req), nil)
		}
	}
	{
		req: json.Request({.Path})
		defer json.destroy(&req)
		_ = request_of(&req, []json.Path{{steps = {json.Name("a")}}}, {strictness = .Lazy, duplicates = .First})
		testing.expect_value(t, json.scan(transmute([]byte)string("{\"a\":1,\"z\":\"\xff\"}"), &req), nil)
	}
	// The same faults across the index's first regions and at its 16 KB chunk edges.
	for edge in ([]int{64, 192, 448, 960, 16384, 32768}) {
		for pad in edge - 20 ..< edge + 4 {
			spaces := strings.repeat("x", pad)
			defer delete(spaces)
			for c in ([]struct {
				tail: string,
				ok:   bool,
			}{{"\xc3\xa9\xe2\x82\xac", true}, {"\xc3", false}, {"\xe2\x82\xff", false}}) {
				src := strings.concatenate({`{"a":1,"z":["`, spaces, c.tail, `"],"y":[1]}`})
				defer delete(src)
				req: json.Request({.Path})
				defer json.destroy(&req)
				_ = request_of(&req, []json.Path{{steps = {json.Name("a")}}}, {strictness = .Structural})
				got := json.scan(transmute([]byte)src, &req)
				testing.expectf(t, (got == nil) == c.ok, "edge %d pad %d, tail %q: scan %v", edge, pad, c.tail, got)
			}
		}
	}
	// Sequences at every offset across the check's 16- and 64-byte windows.
	for pad in 0 ..< 70 {
		spaces := strings.repeat("x", pad)
		defer delete(spaces)
		for c in ([]struct {
			tail: string,
			ok:   bool,
		}{{"\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80", true}, {"\xe2\x82", false}, {"\xf0\x9f\x98", false}, {"\x80", false}, {"\xc3\xa9\xff", false}}) {
			src := strings.concatenate({`{"a":1,"z":"`, spaces, c.tail, `"}`})
			defer delete(src)
			req: json.Request({.Path})
			defer json.destroy(&req)
			_ = request_of(&req, []json.Path{{steps = {json.Name("a")}}}, {strictness = .Structural})
			got := json.scan(transmute([]byte)src, &req)
			testing.expectf(t, (got == nil) == c.ok, "pad %d, tail %q: scan %v", pad, c.tail, got)
		}
	}
}

// `n` arrays, or `n` objects of one member `a` around a 1, nested.
@(private = "file")
nested :: proc(n: int, objects: bool) -> []byte {
	if objects {
		return transmute([]byte)strings.concatenate({strings.repeat(`{"a":`, n, context.temp_allocator), "1", strings.repeat("}", n, context.temp_allocator)}, context.temp_allocator)
	}
	return transmute([]byte)nested_arrays(n)
}

// The offset of the `n`th bracket's open (from 0) in `nested`.
@(private = "file")
nested_open :: proc(n: int, objects: bool) -> u64 {
	return u64(n * 5) if objects else u64(n)
}

// A raised `max_depth` past MAX_DEPTH: every entry reads to it, and refuses one level past it at that level's
// bracket.
@(test)
test_raised_depth_cap :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	CAP :: 5000
	limits := json.Limits{max_depth = CAP}
	for objects in ([]bool{false, true}) {
		fits, past := nested(CAP, objects), nested(CAP + 1, objects)
		at := nested_open(CAP, objects)
		for dialect in ([]json.Dialect{.Json, .Jsonc}) {
			for strictness in json.Strictness {
				testing.expectf(t, json.validate(fits, {dialect = dialect, strictness = strictness, limits = limits}) == nil, "%v %v: %d levels fit", dialect, strictness, CAP)
				e, bad := json.validate(past, {dialect = dialect, strictness = strictness, limits = limits}).?
				testing.expectf(t, bad && e.kind == .Too_Deep && e.offset == at, "%v %v: one past is Too_Deep at %d, got %v", dialect, strictness, at, e)
			}
			doc, err := json.build(fits, {dialect = dialect, limits = limits}, context.temp_allocator)
			testing.expectf(t, err == nil, "%v: build at the cap, got %v", dialect, err)
			testing.expect_value(t, len(doc.rows), CAP + 1 if objects else CAP)
			// marshal writes plain JSON past MAX_DEPTH compact, its source without whitespace, and holds every
			// other output to MAX_DEPTH.
			out, merr := json.marshal(&doc, {}, context.temp_allocator)
			if dialect == .Json {
				testing.expectf(t, marshal_kind(merr) == .None && len(out) == len(fits), "%v: %v", dialect, merr)
			} else {
				testing.expect_value(t, marshal_kind(merr), json.Marshal_Error_Kind.Too_Deep)
			}
			_, perr := json.marshal(&doc, {pretty = true}, context.temp_allocator)
			testing.expect_value(t, marshal_kind(perr), json.Marshal_Error_Kind.Too_Deep)
			_, berr := json.build(past, {dialect = dialect, limits = limits}, context.temp_allocator)
			e, bad := berr.?
			testing.expectf(t, bad && e.kind == .Too_Deep && e.offset == at, "%v: build one past, got %v", dialect, berr)
		}
		// A path query, checked whole and lazily with the rest checked after.
		for strictness in json.Strictness {
			req: json.Request({.Path})
			defer json.destroy(&req)
			_ = request_of(&req, []json.Path{{steps = []json.Step{json.Name("a") if objects else json.Index(0)}}}, {strictness = strictness, duplicates = .First if strictness == .Lazy else .Last, limits = limits})
			testing.expect_value(t, json.scan(fits, &req), nil)
			testing.expect_value(t, req.answers[0].outcome, json.Answer_Outcome.Found)
			testing.expect(t, strict_verdict(fits, &req) == nil)
			e, bad := scan_fault(json.scan(past, &req)).?
			if !bad {
				e, bad = strict_verdict(past, &req).?
			}
			testing.expectf(t, bad && e.kind == .Too_Deep && e.offset == at, "%v: path scan one past, got %v", strictness, e)
		}
	}
	// A JSONC comment past MAX_DEPTH is attached to the container it is in.
	commented := strings.concatenate({string(nested(2000, false)[:2000]), "/*c*/", string(nested(2000, false)[2000:])}, context.temp_allocator)
	doc, err := json.build(transmute([]byte)commented, {dialect = .Jsonc, limits = limits}, context.temp_allocator)
	testing.expect(t, err == nil && len(doc.facts) == 1)
	if len(doc.facts) == 1 {
		testing.expect_value(t, doc.facts[0].node, json.Node(1999))
	}
	// The default cap still refuses at MAX_DEPTH.
	e, bad := json.validate(nested(json.MAX_DEPTH + 1, false)).?
	testing.expect(t, bad && e.kind == .Too_Deep && e.offset == json.MAX_DEPTH)
}

// A cap past DEPTH_CEILING is held to it.
@(test)
test_raised_depth_ceiling_clamps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	limits := json.Limits{max_depth = 2 * json.DEPTH_CEILING}
	testing.expect(t, json.validate(nested(json.DEPTH_CEILING, false), {limits = limits}) == nil)
	e, bad := json.validate(nested(json.DEPTH_CEILING + 1, false), {limits = limits}).?
	testing.expect(t, bad && e.kind == .Too_Deep && e.offset == json.DEPTH_CEILING)
}

// A raised cap costs nothing until input nests past MAX_DEPTH, and a refused spill is `.Out_Of_Memory` at
// the bracket that needed it.
@(test)
test_raised_depth_allocates_only_past_max_depth :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	shallow, at_max := raw(`{"a":[1,{"b":null}],"c":"d"}`), nested(json.MAX_DEPTH, false)
	deep := nested(json.MAX_DEPTH + 1, true)
	limits := json.Limits{max_depth = 5000}
	{
		context.allocator = runtime.panic_allocator()
		for dialect in ([]json.Dialect{.Json, .Jsonc}) {
			for strictness in json.Strictness {
				testing.expect(t, json.validate(shallow, {dialect = dialect, strictness = strictness, limits = limits}) == nil)
				testing.expect(t, json.validate(at_max, {dialect = dialect, strictness = strictness, limits = limits}) == nil)
			}
		}
	}
	context.allocator = runtime.nil_allocator()
	e, bad := json.validate(deep, {limits = limits}).?
	testing.expect(t, bad && e.kind == .Out_Of_Memory && e.offset == nested_open(json.MAX_DEPTH, true), "a refused spill")
	// The fused array push spills at the same bracket.
	e, bad = json.validate(nested(json.MAX_DEPTH + 1, false), {limits = limits}).?
	testing.expect(t, bad && e.kind == .Out_Of_Memory && e.offset == nested_open(json.MAX_DEPTH, false), "a refused spill of an array nest")
}

// A scale cap with no exponent: a fraction with more digits than `max_scalar_scale` is `.Limit_Scale` at the token,
// once the digit budget holds.
@(test)
test_fraction_scale_cap_is_limit_scale :: proc(t: ^testing.T) {
	limits := json.Limits{max_scalar_digits = 20, max_scalar_scale = 3}
	e, bad := json.validate(raw("0.0001"), {limits = limits}).?
	testing.expect(t, bad && e.kind == .Limit_Scale && e.offset == 0, "four fraction digits at a cap of 3")
	testing.expect(t, json.validate(raw("0.001"), {limits = limits}) == nil, "three fit")
}

// Wire UTF-8 and control bytes inside long strings, against a byte-at-a-time oracle: a fault or a stop lands
// anywhere in a 64-byte block, and characters straddle every block edge. Short documents take the index
// cursor and long mostly-string ones the byte cursor's span, so stage 1 is crossed and the span tiers are, in
// whichever width the processor runs them. Only an AVX-512 host runs the 64-byte `span_wide`, elsewhere
// (arm64, Rosetta, CI runners without it) this checks the narrow tiers alone.
@(test)
test_string_wire_against_oracle :: proc(t: ^testing.T) {
	PIECES := [?]string{
		"a", "b c", "word ", `\"`, `\\`, "é", "€", "\U0001f600", "ÿÿ",
		"\x80", "\xc3", "\xc0\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82", "\x01",
	}
	body: [dynamic]u8
	doc: [dynamic]u8
	defer delete(body)
	defer delete(doc)
	// The sweep: each piece from é on at every offset of the first two blocks a span can take, then in strings
	// ending at each length around one block, so a character straddles each edge and a string ends on each
	// side of it. The tail is padded so the vector tiers have their 64 bytes. One document is short (index
	// cursor), the other opens with 1 KiB of string (byte cursor).
	filler := strings.repeat("x", 1100)
	defer delete(filler)
	for piece in PIECES[5:] {
		for off in 0 ..< 128 {
			for tail in ([?]int{0, 1, 2, 7, 30}) {
				clear(&body)
				for _ in 0 ..< off { append(&body, 'a') }
				append(&body, piece)
				for _ in 0 ..< tail { append(&body, 'a') }
				check_wire_sweep(t, body[:], &doc, filler)
			}
		}
		for n in 15 ..= 70 {
			for off in 0 ..= n - len(piece) {
				clear(&body)
				for _ in 0 ..< off { append(&body, 'a') }
				append(&body, piece)
				for len(body) < n { append(&body, 'a') }
				check_wire_sweep(t, body[:], &doc, filler)
			}
		}
	}
	// A document that ends inside its last string, after clean text or partway into a character, in each of
	// the last 64 bytes: the span's end-of-input exits, never a read past `src`.
	for piece in ([?]string{"a", "é", "\xc3", "€", "\xe2\x82", "\U0001f600", "\xf0\x9f\x98"}) {
		for n in 60 ..< 200 {
			clear(&doc)
			append(&doc, `["`)
			for len(doc) < n { append(&doc, 'a') }
			append(&doc, piece)
			testing.expectf(t, json.validate(doc[:]) != nil, "unterminated, %d bytes then %q: strict accepts", n, piece)
			testing.expectf(t, json.validate(doc[:], {strictness = .Structural}) != nil, "unterminated, %d bytes then %q: structural accepts", n, piece)
		}
	}
	// Random strings, of any length up to about 3 KB.
	rng := u64(0x9e3779b97f4a7c15)
	next :: proc(r: ^u64) -> u64 {
		r^ ~= r^ << 13
		r^ ~= r^ >> 7
		r^ ~= r^ << 17
		return r^
	}
	for round in 0 ..< 3000 {
		clear(&body)
		want := 200 + int(next(&rng) % 2800) if round % 2 == 0 else int(next(&rng) % 900)
		// Most strings are clean, so a fault sits alone at a random offset when there is one.
		faulty := next(&rng) % 3 == 0
		for len(body) < want {
			k := int(next(&rng) % 9)
			if faulty && next(&rng) % 64 == 0 {
				k = 9 + int(next(&rng) % 7)
			}
			append(&body, PIECES[k])
		}
		clean_utf8 := utf8.valid_string(string(body[:]))
		has_ctrl := false
		for b in body {
			has_ctrl ||= b < 0x20
		}
		clear(&doc)
		append(&doc, `["`)
		append(&doc, ..body[:])
		append(&doc, `", 1, "tail"]`)
		strict_ok := json.validate(doc[:]) == nil
		testing.expectf(t, strict_ok == (clean_utf8 && !has_ctrl), "round %d (%d bytes): strict says %v", round, len(doc), strict_ok)
		structural_ok := json.validate(doc[:], {strictness = .Structural}) == nil
		testing.expectf(t, structural_ok == clean_utf8, "round %d (%d bytes): structural says %v", round, len(doc), structural_ok)
	}
}

// `body` as a string in a short document and in one opening with 1 KiB of string, against the oracle.
@(private = "file")
check_wire_sweep :: proc(t: ^testing.T, body: []u8, doc: ^[dynamic]u8, filler: string) {
	clean_utf8 := utf8.valid_string(string(body))
	has_ctrl := false
	for b in body {
		has_ctrl ||= b < 0x20
	}
	for long in ([2]bool{false, true}) {
		clear(doc)
		append(doc, `["`)
		append(doc, ..body)
		append(doc, `", "`)
		append(doc, filler if long else filler[:80])
		append(doc, `"]`)
		strict_ok := json.validate(doc[:]) == nil
		testing.expectf(t, strict_ok == (clean_utf8 && !has_ctrl), "sweep %q (long %v): strict says %v", string(body), long, strict_ok)
		// Structural does not stop on a control byte, so only the encoding decides.
		structural_ok := json.validate(doc[:], {strictness = .Structural}) == nil
		testing.expectf(t, structural_ok == clean_utf8, "sweep %q (long %v): structural says %v", string(body), long, structural_ok)
	}
}

// A document that starts like pretty-printer output is validated and built on the pretty cursor, with the same
// results as the compact walk. The compact copy has a tab in its first indent, so `pretty_head` rejects it. Both
// copies get the same verdict for every planted fault, at both levels that read every value, and build the same
// document. A planted space or newline breaks the predicted indent, and the nesting under "deep" indents past one
// 16-byte vector.
@(test)
test_pretty_walk_agrees_with_the_compact_walk :: proc(t: ^testing.T) {
	item := "    {\n      \"id\": 1,\n      \"name\": \"a \\\"b\\\" \\\\ c\",\n      \"tags\": [\n        \"x\",\n        \"y\"\n      ],\n      \"deep\": {\n        \"a\": {\n          \"b\": {\n            \"c\": {\n              \"d\": [\n                {\n                  \"e\": 1\n                }\n              ]\n            }\n          }\n        }\n      },\n      \"ok\": true,\n      \"none\": null,\n      \"empty\": {},\n      \"list\": [],\n      \"n\": -12.5e3\n    }"
	items: [12]string
	for &s in items {
		s = item
	}
	body := strings.join(items[:], ",\n")
	defer delete(body)
	text := strings.concatenate({"{\n  \"items\": [\n", body, "\n  ],\n  \"last\": \"end\"\n}\n"})
	defer delete(text)
	pretty := transmute([]byte)strings.clone(text)
	defer delete(pretty)
	plain := transmute([]byte)strings.clone(text)
	defer delete(plain)
	plain[2] = '\t'
	testing.expect(t, len(pretty) >= 1024)
	for level in ([]json.Strictness{.Strict, .Structural}) {
		testing.expect_value(t, json.validate(pretty, {strictness = level}), nil)
		// Faults start at byte 3, so the tab at byte 2 stays: the compact copy is never detected as pretty, and
		// no earlier fault opens a string that would contain the tab.
		for i in 3 ..< len(pretty) {
			was := pretty[i]
			for bad in ([]byte{'x', 0x01, '"', ']', '}', ',', ':', 0xff, ' ', '\n'}) {
				pretty[i], plain[i] = bad, bad
				got, want := json.validate(pretty, {strictness = level}), json.validate(plain, {strictness = level})
				testing.expectf(t, got == want, "%v: byte %d set to %q: pretty %v, compact %v", level, i, bad, got, want)
				if level == .Strict {
					builds_agree(t, pretty, plain, i, bad)
				}
			}
			pretty[i], plain[i] = was, was
		}
	}
}

// Checks that the DOM walks of `pretty` (pretty cursor) and `plain` (byte cursor) fail at the same byte or write
// the same rows. The two texts differ only in one byte of whitespace.
builds_agree :: proc(t: ^testing.T, pretty, plain: []byte, i: int, bad: byte) {
	got, gerr := json.build(pretty)
	defer json.destroy(&got)
	want, werr := json.build(plain)
	defer json.destroy(&want)
	testing.expectf(t, gerr == werr, "build: byte %d set to %q: pretty %v, compact %v", i, bad, gerr, werr)
	if gerr == nil && werr == nil {
		testing.expectf(t, slice.equal(got.rows[:], want.rows[:]) && slice.equal(got.values[:], want.values[:]), "build: byte %d set to %q: the rows differ", i, bad)
	}
}
