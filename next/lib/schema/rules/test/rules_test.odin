package rules_tests

import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

@(test)
formats_date_time_and_duration :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// date
	testing.expect(t, rules.format_valid(.Date, "2024-02-29"))
	testing.expect(t, rules.format_valid(.Date, "2000-02-29"))
	testing.expect(t, !rules.format_valid(.Date, "2023-02-29"))
	testing.expect(t, !rules.format_valid(.Date, "1900-02-29"))
	testing.expect(t, !rules.format_valid(.Date, "2024-13-01"))
	testing.expect(t, !rules.format_valid(.Date, "2024-04-31"))

	// time (including leap second at UTC 23:59)
	testing.expect(t, rules.format_valid(.Time, "23:59:60Z"))
	testing.expect(t, rules.format_valid(.Time, "00:59:60+01:00"))
	testing.expect(t, rules.format_valid(.Time, "22:59:60-01:00"))
	testing.expect(t, rules.format_valid(.Time, "12:34:56.789123456z"))
	testing.expect(t, !rules.format_valid(.Time, "23:58:60Z"))
	testing.expect(t, !rules.format_valid(.Time, "23:59:60+01:00"))
	testing.expect(t, !rules.format_valid(.Time, "12:34:56.Z"))
	testing.expect(t, !rules.format_valid(.Time, "24:00:00Z"))

	// date-time
	testing.expect(t, rules.format_valid(.Date_Time, "2024-02-29T23:59:60Z"))
	testing.expect(t, rules.format_valid(.Date_Time, "2024-02-29t00:59:60+01:00"))
	testing.expect(t, !rules.format_valid(.Date_Time, "2024-02-29 23:59:59Z"))
	testing.expect(t, !rules.format_valid(.Date_Time, "2023-02-29T00:00:00Z"))

	// duration
	testing.expect(t, rules.format_valid(.Duration, "P3Y6M4DT12H30M5S"))
	testing.expect(t, rules.format_valid(.Duration, "P4W"))
	testing.expect(t, rules.format_valid(.Duration, "PT1S"))
	testing.expect(t, !rules.format_valid(.Duration, "P"))
	testing.expect(t, !rules.format_valid(.Duration, "PT"))
	testing.expect(t, !rules.format_valid(.Duration, "P1Y2W"))
	testing.expect(t, !rules.format_valid(.Duration, "P1DT"))
	testing.expect(t, !rules.format_valid(.Duration, "P1Y2D")) // gap M missing per RFC 3339 Appendix A
}

@(test)
formats_network_and_idna :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// ipv4
	testing.expect(t, rules.format_valid(.Ipv4, "192.168.0.1"))
	testing.expect(t, rules.format_valid(.Ipv4, "0.0.0.0"))
	testing.expect(t, rules.format_valid(.Ipv4, "255.255.255.255"))
	testing.expect(t, !rules.format_valid(.Ipv4, "01.0.0.1"))
	testing.expect(t, !rules.format_valid(.Ipv4, "256.0.0.1"))
	testing.expect(t, !rules.format_valid(.Ipv4, "1.2.3"))
	testing.expect(t, !rules.format_valid(.Ipv4, "1.2.3.4."))

	// ipv6
	testing.expect(t, rules.format_valid(.Ipv6, "::1"))
	testing.expect(t, rules.format_valid(.Ipv6, "2001:db8::8a2e:370:7334"))
	testing.expect(t, rules.format_valid(.Ipv6, "::ffff:192.0.2.128"))
	testing.expect(t, rules.format_valid(.Ipv6, "fe80::"))
	testing.expect(t, !rules.format_valid(.Ipv6, "2001::db8::1"))
	testing.expect(t, !rules.format_valid(.Ipv6, "1:2:3:4:5:6:7:8:9"))
	testing.expect(t, !rules.format_valid(.Ipv6, "1::2:"))

	// hostname & idn-hostname
	testing.expect(t, rules.format_valid(.Hostname, "example.com"))
	testing.expect(t, rules.format_valid(.Hostname, "sub-1.example.co.uk"))
	testing.expect(t, !rules.format_valid(.Hostname, "-bad.example.com"))
	testing.expect(t, !rules.format_valid(.Hostname, "bad-.example.com"))
	testing.expect(t, !rules.format_valid(.Hostname, "ex_ample.com"))
	testing.expect(t, !rules.format_valid(.Hostname, "bücher.example"))
	testing.expect(t, rules.format_valid(.Idn_Hostname, "bücher.example"))
	testing.expect(t, rules.format_valid(.Idn_Hostname, "xn--bcher-kva.example"))
	testing.expect(t, rules.format_valid(.Idn_Hostname, "日本語.jp"))
	// Context-O middle dot U+00B7 only between 'l' and 'l'
	testing.expect(t, rules.format_valid(.Idn_Hostname, "l\u00B7l.example"))
	testing.expect(t, !rules.format_valid(.Idn_Hostname, "a\u00B7b.example"))
	// Context-O Greek Keraia U+0375 before Greek letter
	testing.expect(t, rules.format_valid(.Idn_Hostname, "\u0375\u03B1.example"))
	testing.expect(t, !rules.format_valid(.Idn_Hostname, "\u0375a.example"))
	// Context-O Hebrew Geresh U+05F3 after Hebrew letter
	testing.expect(t, rules.format_valid(.Idn_Hostname, "\u05D0\u05F3.example"))
	testing.expect(t, !rules.format_valid(.Idn_Hostname, "a\u05F3.example"))
	// Leading combining mark refused
	testing.expect(t, !rules.format_valid(.Idn_Hostname, "\u0300a.example"))
	// Bidi rule: mixing LTR and RTL in one label refused
	testing.expect(t, !rules.format_valid(.Idn_Hostname, "a\u05D0.example"))

	// email & idn-email
	testing.expect(t, rules.format_valid(.Email, "user.name+tag@example.com"))
	testing.expect(t, rules.format_valid(.Email, `"quoted user"@example.com`))
	testing.expect(t, rules.format_valid(.Email, "user@[192.168.0.1]"))
	testing.expect(t, rules.format_valid(.Email, "user@[IPv6:2001:db8::1]"))
	testing.expect(t, !rules.format_valid(.Email, ".leading@example.com"))
	testing.expect(t, !rules.format_valid(.Email, "two..dots@example.com"))
	testing.expect(t, !rules.format_valid(.Email, "üser@bücher.example"))
	testing.expect(t, rules.format_valid(.Idn_Email, "üser@bücher.example"))
}

@(test)
formats_uri_iri_uuid_pointer_regex :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// uri & uri-reference
	testing.expect(t, rules.format_valid(.Uri, "https://example.com:8080/a/b?x=1#frag"))
	testing.expect(t, rules.format_valid(.Uri, "http://[v1.fe80::a+en1]/"))
	testing.expect(t, !rules.format_valid(.Uri, "/relative/path"))
	testing.expect(t, !rules.format_valid(.Uri, "https://example.com/bad%2"))
	testing.expect(t, rules.format_valid(.Uri_Reference, "/relative/path"))
	testing.expect(t, rules.format_valid(.Uri_Reference, "#frag"))
	testing.expect(t, rules.format_valid(.Uri_Reference, "a:b/c"))
	testing.expect(t, !rules.format_valid(.Uri_Reference, "1a:b")) // invalid scheme starting with digit

	// iri & iri-reference
	testing.expect(t, rules.format_valid(.Iri, "https://bücher.example/über?q=日本語"))
	testing.expect(t, !rules.format_valid(.Uri, "https://bücher.example/über"))
	testing.expect(t, rules.format_valid(.Iri_Reference, "/über/straße"))

	// uri-template
	testing.expect(t, rules.format_valid(.Uri_Template, "https://example.com/{id}/search{?q,lang}"))
	testing.expect(t, rules.format_valid(.Uri_Template, "https://example.com/{var:3}/{list*}"))
	testing.expect(t, !rules.format_valid(.Uri_Template, "https://example.com/{unclosed"))
	testing.expect(t, !rules.format_valid(.Uri_Template, "https://example.com/{var:0}"))
	testing.expect(t, !rules.format_valid(.Uri_Template, "https://example.com/{var,}"))

	// uuid
	testing.expect(t, rules.format_valid(.Uuid, "550e8400-e29b-41d4-a716-446655440000"))
	testing.expect(t, rules.format_valid(.Uuid, "550E8400-E29B-41D4-A716-446655440000"))
	testing.expect(t, !rules.format_valid(.Uuid, "550e8400-e29b-41d4-a716-44665544000"))
	testing.expect(t, !rules.format_valid(.Uuid, "550e8400-e29b-41d4-a716-44665544000g"))

	// json-pointer & relative-json-pointer
	testing.expect(t, rules.format_valid(.Json_Pointer, ""))
	testing.expect(t, rules.format_valid(.Json_Pointer, "/a/b~0c/d~1e"))
	testing.expect(t, !rules.format_valid(.Json_Pointer, "a/b"))
	testing.expect(t, !rules.format_valid(.Json_Pointer, "/a~2b"))
	testing.expect(t, !rules.format_valid(.Json_Pointer, "/a~"))
	testing.expect(t, rules.format_valid(.Relative_Json_Pointer, "0#"))
	testing.expect(t, rules.format_valid(.Relative_Json_Pointer, "1/foo/0"))
	testing.expect(t, rules.format_valid(.Relative_Json_Pointer, "2+1/bar"))
	testing.expect(t, !rules.format_valid(.Relative_Json_Pointer, "01/a"))
	testing.expect(t, !rules.format_valid(.Relative_Json_Pointer, "/a"))

	// regex (ECMA-262)
	testing.expect(t, rules.format_valid(.Regex, `^[a-z]+\d{2,4}$`))
	testing.expect(t, rules.format_valid(.Regex, `\p{Script=Greek}+`))
	testing.expect(t, !rules.format_valid(.Regex, `[unclosed`))
	testing.expect(t, !rules.format_valid(.Regex, `(`))

	// format_of lookup
	testing.expect_value(t, rules.format_of("date-time"), rules.String_Format.Date_Time)
	testing.expect_value(t, rules.format_of("idn-hostname"), rules.String_Format.Idn_Hostname)
	testing.expect_value(t, rules.format_of("unknown-format"), rules.String_Format.None)
}

@(test)
decimals_exact_and_multiple_of :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, rules.decimal_compare(rules.decimal_of("1"), rules.decimal_of("1.00")), 0)
	testing.expect_value(t, rules.decimal_compare(rules.decimal_of("1e2"), rules.decimal_of("100")), 0)
	testing.expect_value(t, rules.decimal_compare(rules.decimal_of("-0.0"), rules.decimal_of("0")), 0)
	testing.expect_value(t, rules.decimal_compare(rules.decimal_of("-1e-400"), rules.decimal_of("0")), -1)
	testing.expect_value(t, rules.decimal_compare(rules.decimal_of("1e100000000000000000000000000000000"), rules.decimal_of("1e99999999999999999999999999999999")), 1)

	mult, exact := rules.decimal_multiple_of(rules.decimal_of("0.3"), rules.decimal_of("0.1"))
	testing.expect(t, mult && exact)
	mult, exact = rules.decimal_multiple_of(rules.decimal_of("0.35"), rules.decimal_of("0.1"))
	testing.expect(t, !mult && exact)
	mult, exact = rules.decimal_multiple_of(rules.decimal_of("1e400"), rules.decimal_of("0.25"))
	testing.expect(t, mult && exact)

	testing.expect(t, rules.integral(rules.decimal_of("1.00")))
	testing.expect(t, rules.integral(rules.decimal_of("1e2")))
	testing.expect(t, !rules.integral(rules.decimal_of("1.5")))

	b := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&b)
	rules.write_decimal(&b, rules.decimal_of("12.3400"))
	testing.expect_value(t, strings.to_string(b), "12.34")
}

@(test)
values_equal_and_hash :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Mathematical numeric equality & hash identity across representations
	nums := [?]rules.Value{i64(42), u64(42), f64(42.0), rules.Number_Text{"42.00"}, rules.Number_Text{"4.2e1"}}
	h0, herr0 := rules.value_hash(nums[0])
	testing.expect(t, herr0 == nil)
	for n in nums[1:] {
		eq, eerr := rules.value_equal(nums[0], n)
		testing.expect(t, eerr == nil && eq)
		hn, herr := rules.value_hash(n)
		testing.expect(t, herr == nil && hn == h0)
	}
	eq_diff, derr := rules.value_equal(i64(42), i64(43))
	testing.expect(t, derr == nil && !eq_diff)

	// Unordered object equality & Node_Ref cross-equality
	doc, err := json.build(transmute([]u8)string(`{"b": [1.0, true], "a": "hi"}`))
	testing.expect(t, err == nil)
	defer tape.destroy(&doc)

	arr_elems := [?]rules.Value{i64(1), true}
	obj_mems := [?]rules.Member_Value{{"a", "hi"}, {"b", arr_elems[:]}}
	prog_val: rules.Value = obj_mems[:]
	doc_val: rules.Value = rules.Node_Ref{&doc, tape.ROOT}
	eq_obj, oerr := rules.value_equal(prog_val, doc_val)
	testing.expect(t, oerr == nil && eq_obj)
	hp, hperr := rules.value_hash(prog_val)
	hd, hderr := rules.value_hash(doc_val)
	testing.expect(t, hperr == nil && hderr == nil && hp == hd)

	// Leaf regex + steps budget
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
	defer mem.dynamic_arena_destroy(&arena)
	leaf, refused := rules.rules_leaf({pattern = `^(a+)+$`, min_length = 2}, {.String}, mem.dynamic_arena_allocator(&arena))
	testing.expect_value(t, refused, "")
	scratch, serr := regex.scratch_make(context.allocator)
	testing.expect_value(t, serr.kind, regex.Error_Kind.None)
	defer regex.scratch_destroy(&scratch)
	fails, rerr := rules.judge_string(&leaf, "aaa", &scratch)
	testing.expect(t, fails == {} && rerr.kind == .None)
	fails, rerr = rules.judge_string(&leaf, "a", &scratch)
	testing.expect(t, .Too_Short in fails && rerr.kind == .None)
}

@(test)
review_regressions_rules :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// A-C1: heap-allocated decimal bounds cloned into leaf arena survive freeing source strings (ASan check)
	{
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena, context.allocator, context.allocator)
		defer mem.dynamic_arena_destroy(&arena)
		min_s := strings.clone("0.5")
		max_s := strings.clone("10.25")
		mul_s := strings.clone("0.25")
		leaf, refused := rules.rules_leaf({minimum = min_s, maximum = max_s, multiple_of = mul_s}, {.Number}, mem.dynamic_arena_allocator(&arena))
		delete(min_s)
		delete(max_s)
		delete(mul_s)
		testing.expect_value(t, refused, "")
		testing.expect(t, rules.judge_number(&leaf, "1.25", nil) == {})
		testing.expect(t, .Below_Minimum in rules.judge_number(&leaf, "0.25", nil))
		testing.expect(t, .Not_Multiple in rules.judge_number(&leaf, "1.1", nil))
	}

	// A-C4 & A-M4: merged refuses conflicting asserted formats & conflicting markup, compares multiple_of numerically
	{
		n := rules.Node{kinds = {.String}, rules = {format = "email", assert_format = true}, array = -1, object = -1}
		_, clash := rules.merged(&n, {format = "ipv4", assert_format = true})
		testing.expect_value(t, clash, "format")

		nm := rules.Node{kinds = {.String}, rules = {markup = .Element}, array = -1, object = -1}
		_, mclash := rules.merged(&nm, {markup = .Attribute})
		testing.expect_value(t, mclash, "markup")

		n_mul := rules.Node{kinds = {.Number}, rules = {multiple_of = "0.5"}, array = -1, object = -1}
		_, mul_clash := rules.merged(&n_mul, {multiple_of = "0.50"})
		testing.expect_value(t, mul_clash, "")
		_, mul_clash2 := rules.merged(&n_mul, {multiple_of = "0.25"})
		testing.expect_value(t, mul_clash2, "multipleOf")
	}

	// A-C5: XML `.Group` repeated sibling elements equal virtual []Value arrays
	{
		xdoc, xerr := xml.build(transmute([]u8)string(`<root><x>1</x><x>2</x></root>`))
		testing.expect(t, xerr == nil)
		defer tape.destroy(&xdoc)
		xdoc2, xerr2 := xml.build(transmute([]u8)string(`<root><x>1</x><x>3</x></root>`))
		testing.expect(t, xerr2 == nil)
		defer tape.destroy(&xdoc2)
		eq_diff, e1 := rules.value_equal(rules.Node_Ref{&xdoc, tape.ROOT}, rules.Node_Ref{&xdoc2, tape.ROOT})
		testing.expect(t, e1 == nil && !eq_diff, "XML .Group repeated elements with different second child must not compare equal")
		eq_same, e2 := rules.value_equal(rules.Node_Ref{&xdoc, tape.ROOT}, rules.Node_Ref{&xdoc, tape.ROOT})
		testing.expect(t, e2 == nil && eq_same)
	}

	// A-H1: NaN != NaN, +Inf == +Inf, -Inf == -Inf, TOML underscored float exact decimal equality
	{
		nan_v: rules.Value = math.nan_f64()
		pinf_v: rules.Value = math.inf_f64(1)
		ninf_v: rules.Value = math.inf_f64(-1)
		eq_nan, _ := rules.value_equal(nan_v, nan_v)
		testing.expect(t, !eq_nan)
		eq_pinf, _ := rules.value_equal(pinf_v, pinf_v)
		testing.expect(t, eq_pinf)
		eq_infs, _ := rules.value_equal(pinf_v, ninf_v)
		testing.expect(t, !eq_infs)

		tdoc, terr := toml.build(transmute([]u8)string("v = 1_000.25\n"))
		testing.expect(t, terr == nil)
		defer tape.destroy(&tdoc)
		m := [1]rules.Member_Value{{key = "v", value = rules.Number_Text{"1000.25"}}}
		eq_t, et := rules.value_equal(rules.Value(m[:]), rules.Node_Ref{&tdoc, tape.ROOT})
		testing.expect(t, et == nil && eq_t)
	}

	// A-M2 & A-M3: idn-hostname ab--cd, C1 controls in mailbox, single quote in uri-template
	{
		testing.expect(t, !rules.format_valid(.Idn_Hostname, "ab--cd.example"))
		testing.expect(t, !rules.format_valid(.Idn_Email, "bad\u0085user@example.com"))
		bad_utf8 := [?]u8{'a', 0xff, '@', 'b', '.', 'c'}
		testing.expect(t, !rules.format_valid(.Idn_Email, string(bad_utf8[:])))
		testing.expect(t, !rules.format_valid(.Uri_Template, "https://example.com/it's/{id}"))
	}

	// Polish B1: combined `const` + `enum` with container operands must refuse cleanly (NOT compile to an unsatisfiable enum)!
	{
		obj_a := [1]rules.Member_Value{{key = "a", value = i64(1)}}
		obj_b := [1]rules.Member_Value{{key = "b", value = i64(2)}}
		enum_vals := [2]rules.Value{rules.Value(obj_a[:]), rules.Value(obj_b[:])}
		n := rules.Node{
			kinds = rules.EVERY_KIND,
			const_of = rules.Value(obj_a[:]),
			has_enum = true,
			enum_of = enum_vals[:],
			array = -1,
			object = -1,
		}
		_, refused := rules.leaf_of(&n, {})
		testing.expect_value(t, refused, "const")

		// Scalar `const` + `enum` containing a container also refuses cleanly as "enum".
		mix_vals := [2]rules.Value{i64(1), rules.Value(obj_a[:])}
		n2 := rules.Node{
			kinds = rules.EVERY_KIND,
			const_of = i64(1),
			has_enum = true,
			enum_of = mix_vals[:],
			array = -1,
			object = -1,
		}
		_, refused2 := rules.leaf_of(&n2, {})
		testing.expect_value(t, refused2, "enum")

		// Combined scalar `const` + `enum`: matching stays satisfiable, disjoint is unsatisfiable.
		sc_vals := [2]rules.Value{i64(1), i64(2)}
		n3 := rules.Node{
			kinds = rules.EVERY_KIND,
			const_of = i64(1),
			has_enum = true,
			enum_of = sc_vals[:],
			array = -1,
			object = -1,
		}
		l3, r3 := rules.leaf_of(&n3, {})
		defer delete(l3.enum_keys)
		defer for k in l3.enum_keys { delete(k) }
		testing.expect_value(t, r3, "")
		testing.expect(t, rules.enum_has(&l3, .Number, "1"))
		testing.expect(t, !rules.enum_has(&l3, .Number, "2"))
	}
}
