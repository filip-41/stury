package msgpack_tests

import "base:runtime"
import "core:testing"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:testkit"

// Enforcement of MessagePack wire rules, `.Compact` canonical shortest-encoding rules,
// UTF-8 validation and tolerance, map key restrictions, resource budgets, and OOM handling.

Case :: struct {
	hex:  string,
	code: string,
}

expect_refused :: proc(t: ^testing.T, c: Case, spec := msgpack.Spec.Msgpack, opts := msgpack.Options{}, loc := #caller_location) {
	src := hex(c.hex)
	err := msgpack.validate(src, spec, opts)
	if !testing.expectf(t, err != nil, "%s was accepted under %v", c.hex, spec, loc = loc) {
		return
	}
	if c.code != "" {
		testing.expectf(t, testkit.code_of(err) == c.code, "%s under %v: want %s, got %s", c.hex, spec, c.code, testkit.code_of(err), loc = loc)
	}
	_, berr := msgpack.build(src, spec, opts, context.temp_allocator)
	testing.expectf(t, testkit.same_refusal(berr, err), "%s: build %v vs validate %v", c.hex, berr, err, loc = loc)
	_, ferr := msgpack.find(src, {tape.Name("zz")}, spec, {}, opts, context.temp_allocator)
	testing.expectf(t, testkit.same_refusal(ferr, err), "%s: find %v vs validate %v", c.hex, ferr, err, loc = loc)
}

expect_read :: proc(t: ^testing.T, text: string, spec := msgpack.Spec.Msgpack, opts := msgpack.Options{}, loc := #caller_location) {
	err := msgpack.validate(hex(text), spec, opts)
	testing.expectf(t, err == nil, "%s under %v: %v", text, spec, err, loc = loc)
}

MALFORMED := [?]Case {
	{"", "no_item"},
	{"c1", "reserved_type"},
	{"91 c1", "reserved_type"},
	{"81 c1 01", "reserved_type"},
	{"81 61 c1", ""},
	// truncated heads & args
	{"cc", "truncated"}, {"cd 00", "truncated"}, {"ce 00 01", "truncated"}, {"cf 00 01 02", "truncated"},
	{"d0", "truncated"}, {"d1 00", "truncated"}, {"d2 00 01", "truncated"}, {"d3 00", "truncated"},
	{"ca 00 00", "truncated"}, {"cb 00 00 00", "truncated"},
	{"a1", "truncated"}, {"d9", "truncated"}, {"d9 02 61", "truncated"}, {"da 00", "truncated"}, {"db 00 00 00", "truncated"},
	{"c4", "truncated"}, {"c4 02 01", "truncated"}, {"c5 00", "truncated"}, {"c6 00 00 00", "truncated"},
	{"d4 01", "truncated"}, {"d5 01 00", "truncated"}, {"d6 01 00 00", "truncated"}, {"d7 01", "truncated"}, {"d8 01", "truncated"},
	{"c7 01", "truncated"}, {"c7 02 01 00", "truncated"}, {"c8 00", "truncated"}, {"c9 00 00 00", "truncated"},
	// containers missing items / count too large
	{"91", "count_too_large"}, {"92 01", "count_too_large"}, {"81", "count_too_large"}, {"81 01", "count_too_large"},
	{"82 01 02 03", "count_too_large"}, {"82 a1 61 01 a1 62", "truncated"},
	{"dc 00 10 01 02", "count_too_large"}, {"dd ff ff ff ff 01", "count_too_large"}, {"df 00 01 00 00 01", "count_too_large"},
	// invalid timestamps (ext -1)
	{"d4 ff 00", "bad_timestamp"},
	{"d5 ff 00 00", "bad_timestamp"},
	{"d8 ff 000102030405060708090a0b0c0d0e0f", "bad_timestamp"},
	{"c7 00 ff", "bad_timestamp"},
	{"c7 05 ff 0000000000", "bad_timestamp"},
	{"d7 ff ee6b2800 00000000", "bad_timestamp"}, // nsec == 1_000_000_000
	{"c7 0c ff 3b9aca00 0000000000000000", "bad_timestamp"}, // nsec == 1_000_000_000
	// trailing bytes
	{"00 00", "trailing"},
	{"92 01 02 03", "trailing"},
}

@(test)
malformed_items_are_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in MALFORMED {
		expect_refused(t, c)
	}
}

@(test)
compact_rules_are_enforced :: proc(t: ^testing.T) {
	testkit.deadline(t)
	non_compact := [?]string {
		// Non-minimal unsigned ints
		"cc 00", "cc 7f", "cd 00 ff", "ce 00 00 ff ff", "cf 00 00 00 00 ff ff ff ff",
		// Non-minimal signed ints (and non-negative in signed encoding)
		"d0 00", "d0 7f", "d0 e0", "d0 ff", "d1 ff 80", "d1 00 01", "d2 ff ff 80 00", "d3 ff ff ff ff 80 00 00 00", "d3 00 00 00 00 00 00 00 01",
		// Non-minimal str
		"d9 00", "d9 1f 61 61 61", "da 00 20 61", "da 00 00", "db 00 00 ff ff",
		// Non-minimal bin
		"c5 00 00", "c5 00 ff", "c6 00 00 ff ff",
		// Non-minimal containers
		"dc 00 00", "dc 00 0f", "dd 00 00 ff ff", "de 00 00", "de 00 0f", "df 00 00 ff ff",
		// Non-minimal ext heads (should use fixext 1/2/4/8/16 or ext 8/16)
		"c7 01 05 aa", "c7 02 05 aabb", "c7 04 05 aabbccdd", "c7 08 05 0011223344556677", "c7 10 05 000102030405060708090a0b0c0d0e0f",
		"c8 00 03 05 010203", "c9 00 00 00 03 05 010203",
		// Binary64 fitting losslessly in binary32
		"cb 3ff8000000000000", // 1.5
		"cb 8000000000000000", // -0.0
		"cb 7ff0000000000000", // +Inf
		"cb fff0000000000000", // -Inf
		"cb 7ff8000000000000", // canonical qNaN
		// Non-compact Timestamps
		"d7 ff 00000000 00000000", // TS64 with nsec=0 & 32-bit sec -> should be TS32
		"c7 0c ff 00000000 0000000000000001", // TS96 fitting TS32
		"c7 0c ff 00000001 0000000000000001", // TS96 fitting TS64
	}
	// Note `da 00 20` above would need 32 payload bytes; test shorter non-compact str length 5 with da:
	valid_in_msgpack_only := [?]string {
		"da 00 05 68656c6c6f",
	}
	for s in valid_in_msgpack_only {
		expect_read(t, s, .Msgpack)
		expect_refused(t, {s, "not_preferred"}, .Compact)
	}
	for s in non_compact {
		if s == "da 00 20 61" || s == "d9 1f 61 61 61" || s == "db 00 00 ff ff" || s == "c5 00 ff" || s == "c6 00 00 ff ff" || s == "dc 00 0f" || s == "dd 00 00 ff ff" || s == "de 00 0f" || s == "df 00 00 ff ff" {
			// Skip incomplete sample payloads handled separately with exact length payloads below.
			continue
		}
		expect_read(t, s, .Msgpack)
		expect_refused(t, {s, "not_preferred"}, .Compact)
	}
	// Complete payload non-compact containers/strings/bins
	exact_non_compact := [?]Case {
		{"d9 03 616263", "not_preferred"},
		{"da 00 03 616263", "not_preferred"},
		{"db 00 00 00 03 616263", "not_preferred"},
		{"c5 00 02 0102", "not_preferred"},
		{"c6 00 00 00 02 0102", "not_preferred"},
		{"dc 00 01 01", "not_preferred"},
		{"dd 00 00 00 01 01", "not_preferred"},
		{"de 00 01 01 02", "not_preferred"},
		{"df 00 00 00 01 01 02", "not_preferred"},
	}
	for c in exact_non_compact {
		expect_read(t, c.hex, .Msgpack)
		expect_refused(t, c, .Compact)
	}
}

@(test)
utf8_validation_and_tolerance :: proc(t: ^testing.T) {
	testkit.deadline(t)
	bad_utf8 := [?]string{"a2 c3 28", "a1 80", "a3 ed a0 80", "d9 02 c0 80"}
	for s in bad_utf8 {
		expect_refused(t, {s, "invalid_utf8"})
	}
	lax := msgpack.Options{tolerate = {.Invalid_Utf8}}
	doc, err := msgpack.build(hex("a2 c3 28"), .Msgpack, lax)
	testing.expect_value(t, err, nil)
	defer msgpack.destroy(&doc)
	testing.expect(t, .Tolerated in doc.flags)
	got, _ := text_of(&doc, msgpack.ROOT)
	testing.expect_value(t, got, "\ufffd(")
	// Binary `0xc4..0xc6` holds arbitrary bytes without UTF-8 check
	expect_read(t, "c4 02 c3 28")
}

@(test)
keys_are_restricted_to_scalars :: proc(t: ^testing.T) {
	testkit.deadline(t)
	bad_keys := [?]Case {
		{"81 90 01", "bad_key"},
		{"81 80 01", "bad_key"},
		{"81 c0 01", "bad_key"},
		{"81 c2 01", "bad_key"},
		{"81 c3 01", "bad_key"},
		{"81 ca 3f800000 01", "bad_key"},
		{"81 cb 3ff0000000000000 01", "bad_key"},
		{"81 d4 05 aa 01", "bad_key"},
		{"81 d6 ff 00000000 01", "bad_key"},
		{"81 c7 01 05 aa 01", "bad_key"},
		{"81 c1 01", "reserved_type"},
	}
	for c in bad_keys {
		expect_refused(t, c)
	}
	for text in ([?]string{"81 01 02", "81 ff 02", "81 c4 01 01 02", "81 a1 61 02"}) {
		expect_read(t, text)
	}
}

@(test)
budgets_and_oom_are_enforced :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)

	// Depth limit
	nest := proc(depth: int) -> []u8 {
		b := make([]u8, depth + 1, context.temp_allocator)
		for i in 0 ..< depth {
			b[i] = 0x91
		}
		b[depth] = 0
		return b
	}
	testing.expect_value(t, msgpack.validate(nest(10), .Compact, {budget = {depth = 10}}), nil)
	derr := msgpack.validate(nest(11), .Compact, {budget = {depth = 10}})
	ex, is_ex := derr.(tape.Exceeded)
	testing.expect(t, is_ex && ex.kind == .Depth)

	// Steps limit across validate/build/find/scan
	src := hex("83 a1 61 92 81 a1 62 01 81 a1 62 02 a1 63 81 a1 64 91 03 a1 65 04")
	CONTAINERS :: 6
	path := []tape.Step{tape.Name("e")}
	for steps in u64(1) ..= CONTAINERS + 1 {
		opts := msgpack.Options{budget = {steps = steps}}
		over := steps < CONTAINERS
		verr := msgpack.validate(src, .Msgpack, opts)
		_, berr := msgpack.build(src, .Msgpack, opts, context.temp_allocator)
		_, ferr := msgpack.find(src, path, .Msgpack, {}, opts)
		dem, _ := tape.demand_of({path}, allocator = context.temp_allocator)
		_, serr := msgpack.scan(src, &dem, .Msgpack, {}, opts, context.temp_allocator)
		for err in ([?]tape.Error{verr, berr, ferr, serr}) {
			e, exceeded := err.(tape.Exceeded)
			testing.expectf(t, exceeded == over && (!over || e.kind == .Steps), "steps %d: %v", steps, err)
		}
	}

	// Nodes budget
	_, nerr := msgpack.build(src, .Msgpack, {budget = {nodes = 4}}, context.temp_allocator)
	nex, is_nex := nerr.(tape.Exceeded)
	testing.expect(t, is_nex && nex.kind == .Nodes)

	// Memory budget
	_, merr := msgpack.build(src, .Msgpack, {budget = {memory = 64}}, context.allocator)
	mex, is_mex := merr.(tape.Exceeded)
	testing.expectf(t, is_mex && mex.kind == .Memory, "memory budget got %v", merr)
	mem_text := make([]u8, 600, context.temp_allocator)
	mem_text[0], mem_text[1], mem_text[2] = 0xdc, 0x02, 0x55
	_, merr2 := msgpack.build(mem_text, .Compact, {budget = {memory = 1}}, context.allocator)
	mex2, is_mex2 := merr2.(tape.Exceeded)
	testing.expectf(t, is_mex2 && mex2.kind == .Memory, "tight memory budget got %v", merr2)

	// Early finds still judge skipped bytes
	for c in MALFORMED {
		msrc := hex(c.hex)
		want := msgpack.validate(msrc)
		for p in ([][]tape.Step{{tape.Name("a")}, {tape.Index(0)}}) {
			_, err := msgpack.find(msrc, p, .Msgpack, {stop_early = true})
			testing.expectf(t, err == nil || testkit.same_refusal(err, want), "%s: %v vs %v", c.hex, err, want)
		}
	}

	// OOM sweep across build and parallel plan/build
	big := long_text(0, 64)
	defer delete(big)
	Oom_Ctx :: struct {
		src: []u8,
	}
	run_build :: proc(data: rawptr, a: runtime.Allocator) {
		oc := (^Oom_Ctx)(data)
		doc, err := msgpack.build(oc.src, .Msgpack, {}, a)
		if err == nil {
			msgpack.destroy(&doc)
		} else {
			_ = err.(runtime.Allocator_Error)
		}
	}
	oc := Oom_Ctx{big}
	sw := testkit.sweep_failures(run_build, &oc)
	testing.expectf(t, sw.bad == 0 && sw.refused >= 1, "build OOM sweep: %v", sw)
}
