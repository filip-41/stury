package tape_test

import "base:runtime"
import "core:mem"
import "core:testing"
import "stury:json"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"
import "stury:xml"
import "stury:yaml"

@(test)
error_message_and_budget_edges :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [128]u8

	// Fault with NO_BYTE omits line:col prefix.
	msg := tape.error_message(buf[:], tape.Fault{at = tape.NO_BYTE, kind = .Bad_Char}, transmute([]u8)string("abc"))
	testing.expect_value(t, msg, "Unexpected character")

	// Multi-byte control_char uses "byte 0x.." instead of "U+00.."; ASCII keeps "U+00..".
	rules := tape.Rules {
		format  = "yaml",
		details = {
			1 = {code = "control_char", message = "Character not allowed"},
		},
	}
	ascii_src := []u8{0x01}
	testing.expect_value(t, tape.error_message(buf[:], tape.Fault{at = 0, rules = &rules, kind = .Bad_Char, detail = 1}, ascii_src), "1:1: Character not allowed U+0001")
	mb_src := []u8{0xC2, 0x80}
	testing.expect_value(t, tape.error_message(buf[:], tape.Fault{at = 0, rules = &rules, kind = .Bad_Char, detail = 1}, mb_src), "1:1: Character not allowed byte 0xC2")

	// Out-of-range enum kinds & Budget_Kind.None do not panic or return empty string.
	testing.expect_value(t, tape.error_message(buf[:], tape.Exceeded{at = tape.NO_BYTE, kind = .None}, nil), "Exceeds limit")
	testing.expect_value(t, tape.error_message(buf[:], tape.Exceeded{at = tape.NO_BYTE, kind = tape.Budget_Kind(99)}, nil), "Exceeds limit")
	testing.expect_value(t, tape.fault_rule(tape.Fault{kind = tape.Fault_Kind(99)}).code, "none")

	// default_expansion overflow safety.
	testing.expect_value(t, tape.default_expansion(0), u64(8 << 20))
	testing.expect_value(t, tape.default_expansion(max(u64)), max(u64))
}

@(test)
runner_fan_and_fan_each_edges :: proc(t: ^testing.T) {
	testkit.deadline(t)

	Counter :: struct {
		calls:  int,
		sum:    int,
		starts: int,
		max_n:  int,
	}
	c := Counter{}
	one :: proc(arg: rawptr) {
		(^Counter)(arg).calls += 1
	}
	each :: proc(arg: rawptr, k: int) {
		p := (^Counter)(arg)
		p.calls += 1
		p.sum += k + 1
	}

	// nil runner and zero Runner{} run safely on the caller thread.
	tape.fan(nil, one, &c)
	zero := tape.Runner{}
	tape.fan(&zero, one, &c)
	testing.expect_value(t, c.calls, 2)

	// Mock runner verifies start is skipped for count <= 1 and capped to min(threads, count - 1).
	mock := tape.Runner {
		data    = &c,
		threads = 8,
		start   = proc(data: rawptr, n: int, task: proc(arg: rawptr), arg: rawptr) {
			p := (^Counter)(data)
			p.starts += 1
			p.max_n = max(p.max_n, n)
			_ = task
			_ = arg
		},
		finish = proc(data: rawptr) {
			_ = data
		},
	}
	c.calls, c.sum = 0, 0
	tape.fan_each(&mock, 0, each, &c)
	tape.fan_each(&mock, -5, each, &c)
	tape.fan_each(&mock, 1, each, &c)
	testing.expect_value(t, c.starts, 0)
	testing.expect_value(t, c.calls, 1)
	testing.expect_value(t, c.sum, 1)

	tape.fan_each(&mock, 3, each, &c)
	testing.expect_value(t, c.starts, 1)
	testing.expect_value(t, c.max_n, 2)
	testing.expect_value(t, c.calls, 4)
	testing.expect_value(t, c.sum, 7)
}

@(test)
document_and_demand_nil_allocator_safety :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// destroy_document(nil) is a safe no-op.
	tape.destroy_document(nil)

	// clone_document under nil_allocator / zero allocator returns Out_Of_Memory instead of crashing.
	src := transmute([]u8)string(`{"a":1,"b":"hello"}`)
	doc, err := json.build(src, .Json, {}, context.allocator)
	testing.expect_value(t, err, nil)
	defer tape.destroy(&doc)

	_, cerr1 := tape.clone_document(&doc, mem.nil_allocator())
	testing.expect_value(t, cerr1, runtime.Allocator_Error.Out_Of_Memory)
	_, cerr2 := tape.clone_document(&doc, runtime.Allocator{})
	testing.expect_value(t, cerr2, runtime.Allocator_Error.Out_Of_Memory)

	// partial_block rejects negative counts and overflow cleanly.
	_, perr1 := tape.partial_block(-1, 0, 0, 0, 0, .Last, context.allocator)
	testing.expect_value(t, perr1, runtime.Allocator_Error.Invalid_Argument)
	_, perr2 := tape.partial_block(0, max(int) / 2, 0, 0, 0, .Last, context.allocator)
	testing.expect_value(t, perr2, runtime.Allocator_Error.Out_Of_Memory)

	// demand_of under nil_allocator returns Out_Of_Memory cleanly (no self-loop hang).
	path := [1]tape.Step{tape.Name("a")}
	paths := [1][]tape.Step{path[:]}
	_, derr := tape.demand_of(paths[:], nil, nil, false, mem.nil_allocator())
	testing.expect_value(t, derr, runtime.Allocator_Error.Out_Of_Memory)

	// format_reads records() under nil_allocator returns Out_Of_Memory cleanly.
	_, rerr := json.reads(.Json).records(json.as(.Json), src, .Lines, {}, nil, mem.nil_allocator())
	testing.expect_value(t, rerr, runtime.Allocator_Error.Out_Of_Memory)
}

@(test)
read_pieces_records_and_token_safety :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// number_respell guards invalid/empty spans.
	testing.expect_value(t, tape.number_respell(nil, 0, 0), u16(0))
	testing.expect_value(t, tape.number_respell(transmute([]u8)string("12"), 1, 5), u16(0))

	// destroy_pieces(nil) & piece_window overflow guard.
	tape.destroy((^tape.Pieces)(nil))
	p := tape.Pieces{from = u64(max(int)), keep = u64(max(int))}
	_, werr := tape.piece_window(&p, []u8{1, 2, 3, 4})
	testing.expect_value(t, werr, tape.Error(tape.Exceeded{at = u64(max(int)), kind = .Memory}))

	// destroy_records idempotency on stack yaml.Records + nil guards.
	ysrc := transmute([]u8)string("- 1\n- 2\n")
	yr := yaml.records_open(ysrc, .Elements, .Yaml_1_2)
	out: [4]tape.Record
	_ = yaml.records_validate(&yr, out[:], context.allocator)
	tape.destroy_records(&yr)
	tape.destroy_records(&yr)
	testing.expect_value(t, tape.records_validate(nil, out[:]), 0)
	rwerr := tape.records_window(nil, nil)
	testing.expect_value(t, rwerr, tape.Error(tape.Bad_Option{"pieces"}))

	// node_text_read under nil_allocator returns ("", false) and preserves Memory_Budget accounting.
	esrc := transmute([]u8)string(`{"k":"a\nb"}`)
	edoc, eerr := json.build(esrc, .Json, {}, context.allocator)
	testing.expect_value(t, eerr, nil)
	defer tape.destroy(&edoc)
	val, pres := tape.member(tape.Reader{doc = &edoc}, tape.ROOT, "k")
	testing.expect_value(t, pres, tape.Presence.Found)
	tok := edoc.nodes[val]

	_, ok_nil := tape.node_text_read(edoc.format, esrc, tok, mem.nil_allocator())
	testing.expect(t, !ok_nil)

	mb := hook.Memory_Budget{backing = context.allocator, limit = 1024}
	balloc := hook.memory_budget(&mb)
	s, ok_b := tape.node_text_read(edoc.format, esrc, tok, balloc)
	testing.expect(t, ok_b)
	testing.expect_value(t, s, "a\nb")
	delete(s, balloc)
	testing.expect_value(t, mb.held, u64(0))
}

@(test)
markup_content_bugs_and_fast_paths :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Empty Document{} and out-of-range Node_Index do not panic.
	empty_doc := tape.Document{}
	s0, ok0 := tape.markup_content(&empty_doc, tape.ROOT, context.allocator)
	testing.expect(t, ok0 && s0 == "")
	s1, ok1 := tape.markup_content(&empty_doc, tape.NO_NODE, context.allocator)
	testing.expect(t, ok1 && s1 == "")
	s2, ok2 := tape.markup_content(&empty_doc, tape.Node_Index(99), context.allocator)
	testing.expect(t, ok2 && s2 == "")
	trunc_nodes := [1]tape.Token{{kind = .Object, role = .Value, n = 100}}
	trunc_doc := tape.Document{nodes = trunc_nodes[:]}
	s3, ok3 := tape.markup_content(&trunc_doc, tape.ROOT, context.allocator)
	testing.expect(t, ok3 && s3 == "")

	// 2. mem.nil_allocator() returns ("", false) on non-empty content and ("", true) on empty element.
	plain_src := transmute([]u8)string("<a>hello</a>")
	plain_doc, plain_err := xml.build(plain_src, .Xml, {}, context.allocator)
	testing.expect_value(t, plain_err, nil)
	defer tape.destroy(&plain_doc)
	a_val, a_pres := tape.member(tape.Reader{doc = &plain_doc}, tape.ROOT, "a")
	testing.expect_value(t, a_pres, tape.Presence.Found)
	s_nil, ok_nil := tape.markup_content(&plain_doc, a_val, mem.nil_allocator())
	testing.expect(t, !ok_nil && s_nil == "")

	null_src := transmute([]u8)string("<a/>")
	null_doc, null_err := xml.build(null_src, .Xml, {}, context.allocator)
	testing.expect_value(t, null_err, nil)
	defer tape.destroy(&null_doc)
	null_val, null_pres := tape.member(tape.Reader{doc = &null_doc}, tape.ROOT, "a")
	testing.expect_value(t, null_pres, tape.Presence.Found)
	s_empty, ok_empty := tape.markup_content(&null_doc, null_val, mem.nil_allocator())
	testing.expect(t, ok_empty && s_empty == "" && raw_data(s_empty) == nil)

	// 3. Empty decoded DTD entity frees its scratch buffer and returns ("", true) with nil pointer (zero leaks).
	ent_src := transmute([]u8)string(`<!DOCTYPE a [<!ENTITY e "">]><a>&e;</a>`)
	ent_doc, ent_err := xml.build(ent_src, .Xml, {}, context.allocator)
	testing.expect_value(t, ent_err, nil)
	defer tape.destroy(&ent_doc)
	ent_val, ent_pres := tape.member(tape.Reader{doc = &ent_doc}, tape.ROOT, "a")
	testing.expect_value(t, ent_pres, tape.Presence.Found)
	mb := hook.Memory_Budget{backing = context.allocator, limit = 1024}
	balloc := hook.memory_budget(&mb)
	s_ent, ok_ent := tape.markup_content(&ent_doc, ent_val, balloc)
	testing.expect(t, ok_ent && s_ent == "" && raw_data(s_ent) == nil)
	testing.expect_value(t, mb.held, u64(0))

	// 4. Signed int overflow in size accumulation returns ("", false) without wrapping or allocating.
	ovf_fmt := tape.Format {
		room = proc "contextless" (_: []u8, _: tape.Node, _: ^tape.Format_Ext) -> int {
			return max(int)
		},
	}
	ovf_nodes := [3]tape.Token {
		{kind = .Object, role = .Value, n = 3},
		{lo = 0, n = 1, kind = .String, role = .Value, spelling = tape.SPELLING_DECODE},
		{lo = 0, n = 1, kind = .String, role = .Value, spelling = tape.SPELLING_DECODE},
	}
	ovf_src := []u8{'x'}
	ovf_doc := tape.Document{src = ovf_src, nodes = ovf_nodes[:], format = &ovf_fmt}
	s_ovf, ok_ovf := tape.markup_content(&ovf_doc, tape.ROOT, balloc)
	testing.expect(t, !ok_ovf && s_ovf == "")
	testing.expect_value(t, mb.held, u64(0))

	// 5. Failed node_text decode frees its allocated buffer and returns ("", false).
	fail_fmt := tape.Format {
		room = proc "contextless" (_: []u8, _: tape.Node, _: ^tape.Format_Ext) -> int {
			return 4
		},
		decode = proc "contextless" (_: []u8, _: tape.Node, _: []u8, _: ^tape.Format_Ext) -> (string, bool) {
			return "", false
		},
	}
	fail_nodes := [1]tape.Token {
		{lo = 0, n = 1, kind = .String, role = .Value, spelling = tape.SPELLING_DECODE},
	}
	fail_doc := tape.Document{src = ovf_src, nodes = fail_nodes[:], format = &fail_fmt}
	s_fail, ok_fail := tape.markup_content(&fail_doc, tape.ROOT, balloc)
	testing.expect(t, !ok_fail && s_fail == "")
	testing.expect_value(t, mb.held, u64(0))

	// 6. Plain, decoded, and inferred scalars (numbers/booleans) concatenate cleanly in document order.
	inf_src := transmute([]u8)string("<a><b>42</b><c>true</c><d>hi &amp; bye</d></a>")
	inf_doc, inf_err := xml.build(inf_src, .Xml, {format = tape.Xml_Options{infer = true}}, context.allocator)
	testing.expect_value(t, inf_err, nil)
	defer tape.destroy(&inf_doc)
	inf_val, inf_pres := tape.member(tape.Reader{doc = &inf_doc}, tape.ROOT, "a")
	testing.expect_value(t, inf_pres, tape.Presence.Found)
	s_inf, ok_inf := tape.markup_content(&inf_doc, inf_val, balloc)
	testing.expect(t, ok_inf)
	testing.expect_value(t, s_inf, "42truehi & bye")
	delete(s_inf, balloc)
	testing.expect_value(t, mb.held, u64(0))
}

// The entries of every list a `Document`, its `Partial` and its `Doc_Ext` (including all `Doc_Ext.format` union arms
// such as `Tabular_Ext`, `Markup_Ext`, `Markup_Dtd`, and `Html_Ext`) hold are offsets, indexes and plain values, with
// no address, so a document's lists can be written to a file and read back.
@(test)
document_entries_hold_no_address :: proc(t: ^testing.T) {
	testkit.deadline(t)
	checked := 0
	for holder in ([]^runtime.Type_Info{type_info_of(tape.Document), type_info_of(tape.Partial), type_info_of(tape.Doc_Ext)}) {
		check_holder_lists(t, holder, holder != type_info_of(tape.Document), &checked)
	}
	// Document (4) + Partial (5) + Doc_Ext (1) + Tabular_Ext (3) + Markup_Ext (3) + Markup_Dtd (4) + Html_Ext (3) = 23 lists.
	testing.expect(t, checked >= 23)
}

// Walks structs and unions inside a document holder, verifying every slice element holds no address; when
// `check_scalars` is true (`Partial` and `Doc_Ext`, including all extension union arms), also verifies non-slice
// fields hold no raw pointer, string, map, or procedure.
@(private = "file")
check_holder_lists :: proc(t: ^testing.T, info: ^runtime.Type_Info, check_scalars: bool, checked: ^int) {
	#partial switch v in runtime.type_info_base(info).variant {
	case ^runtime.Type_Info_Struct:
		for i in 0 ..< v.field_count {
			ft := v.types[i]
			#partial switch fv in runtime.type_info_base(ft).variant {
			case ^runtime.Type_Info_Slice:
				checked^ += 1
				testing.expectf(t, holds_no_address(fv.elem), "%v.%s holds an address", info, v.names[i])
			case ^runtime.Type_Info_Struct, ^runtime.Type_Info_Union:
				check_holder_lists(t, ft, check_scalars, checked)
			case:
				if check_scalars {
					testing.expectf(t, holds_no_address(ft), "%v.%s holds an address", info, v.names[i])
				}
			}
		}
	case ^runtime.Type_Info_Union:
		for arm in v.variants {
			check_holder_lists(t, arm, check_scalars, checked)
		}
	}
}

// Whether a value of `info` holds no pointer, slice, string, map, procedure or other address.
@(private = "file")
holds_no_address :: proc(info: ^runtime.Type_Info) -> bool {
	#partial switch v in runtime.type_info_base(info).variant {
	case ^runtime.Type_Info_Struct:
		for i in 0 ..< v.field_count {
			if !holds_no_address(v.types[i]) {
				return false
			}
		}
		return true
	case ^runtime.Type_Info_Union:
		for arm in v.variants {
			if !holds_no_address(arm) {
				return false
			}
		}
		return true
	case ^runtime.Type_Info_Array:
		return holds_no_address(v.elem)
	case ^runtime.Type_Info_Enumerated_Array:
		return holds_no_address(v.elem)
	case ^runtime.Type_Info_Integer, ^runtime.Type_Info_Float, ^runtime.Type_Info_Boolean, ^runtime.Type_Info_Rune, ^runtime.Type_Info_Enum, ^runtime.Type_Info_Bit_Set, ^runtime.Type_Info_Bit_Field:
		return true
	}
	return false
}

// `text_is_ascii` short-circuits in O(1) on `SPELLING_ASCII` for `.String` and `.Plain` without scanning source bytes,
// never falsely short-circuits on non-string kinds whose spelling bits overlap bit 4, and `Options` exposes the v2
// `cancel` and `shape_hint` seams with zero-initialized defaults.
@(test)
text_is_ascii_fast_path_and_options_seams :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Non-ASCII bytes in `src` prove the `SPELLING_ASCII` branch returns immediately without scanning.
	non_ascii := []u8{0xC3, 0xA9, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'}
	nodes := [?]tape.Token {
		{lo = 0, n = u32(len(non_ascii)), kind = .String, role = .Value, spelling = tape.SPELLING_ASCII},
		{lo = 0, n = u32(len(non_ascii)), kind = .Plain, role = .Value, spelling = tape.SPELLING_ASCII},
		{lo = 0, n = u32(len(non_ascii)), kind = .String, role = .Value, spelling = 0},
		{lo = 2, n = 8, kind = .String, role = .Value, spelling = 0},
		// Number with `int_digits == 1` has bit 4 (`1 << 4 == SPELLING_ASCII`) set; must not take string fast path.
		{lo = 0, n = 2, kind = .Number, role = .Value, spelling = tape.number_spelling(0, 1, 0)},
		// Null with bit 4 set must still report `ok = false`.
		{lo = 0, n = 4, kind = .Null, role = .Value, spelling = tape.SPELLING_ASCII},
	}
	fmt := tape.Format{}
	doc := tape.Document{src = non_ascii, nodes = nodes[:], format = &fmt}

	// Short-circuit on `.String` and `.Plain` with `SPELLING_ASCII` (even without touching `src`).
	ascii, ok := tape.text_is_ascii(&doc, 0, nil)
	testing.expect(t, ok && ascii)
	ascii, ok = tape.text_is_ascii(&doc, 1, nil)
	testing.expect(t, ok && ascii)

	// Unflagged `.String` scans source bytes accurately (non-ASCII vs ASCII).
	ascii, ok = tape.text_is_ascii(&doc, 2, nil)
	testing.expect(t, ok && !ascii)
	ascii, ok = tape.text_is_ascii(&doc, 3, nil)
	testing.expect(t, ok && ascii)

	// `.Number` with bit 4 set still scans via `node_text_token` (sees non-ASCII bytes -> false, true).
	ascii, ok = tape.text_is_ascii(&doc, 4, nil)
	testing.expect(t, ok && !ascii)

	// `.Null` and `NO_NODE` return `(false, false)`.
	ascii, ok = tape.text_is_ascii(&doc, 5, nil)
	testing.expect(t, !ok && !ascii)
	ascii, ok = tape.text_is_ascii(&doc, tape.NO_NODE, nil)
	testing.expect(t, !ok && !ascii)

	// Reserved v2 seams on `Options` default to nil and `is_canceled` reads relaxed atomics cleanly.
	def_opts := tape.Options{}
	testing.expect(t, def_opts.cancel == nil && def_opts.shape_hint == nil)
	testing.expect(t, !tape.is_canceled(nil))
	flag: u32 = 0
	testing.expect(t, !tape.is_canceled(&flag))
	flag = 1
	testing.expect(t, tape.is_canceled(&flag))
	hint := tape.Shape_Hint{schema = 0x1234, nodes = 64, flags = {.Flat, .Ascii_Text}, depth = 2, keys = 4}
	opts := tape.Options{cancel = &flag, shape_hint = &hint}
	testing.expect(t, tape.is_canceled(opts.cancel))
	testing.expect_value(t, opts.shape_hint.nodes, u32(64))
}

// Layout sizes, which change only on purpose.
@(test)
layout_sizes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, size_of(tape.Budget), 32)
	testing.expect_value(t, size_of(tape.Caps), 4)
	testing.expect_value(t, size_of(tape.Shape_Hint), 16)
	testing.expect_value(t, size_of(tape.Token), 16)
	testing.expect_value(t, size_of(tape.Fact), 24)
	testing.expect_value(t, size_of(tape.Table), 32)
	when size_of(uintptr) == 8 {
		testing.expect_value(t, size_of(tape.Document), 120)
	}
}

@(test)
mapped_nodes_reserve_trim_clone_destroy :: proc(t: ^testing.T) {
	testkit.deadline(t)
	when size_of(uintptr) == 8 {
		testing.expect_value(t, size_of(tape.Document), 120)
	}

	// 1. Direct reserve -> commit -> write -> trim_tail -> clone_document -> destroy_document.
	buf, reserved, ok := tape.nodes_reserve(262_144)
	when size_of(uintptr) == 8 && (ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD || ODIN_OS == .Windows) {
		testing.expect(t, ok && len(buf) == 262_144 && reserved >= 262_144 * size_of(tape.Node))
	}
	if ok {
		committed := 0
		testing.expect(t, tape.nodes_commit(buf, &committed, 1024))
		testing.expect(t, committed >= 1024 * size_of(tape.Node))
		testing.expect(t, !tape.nodes_commit(buf, &committed, len(buf) + 1))

		used := 512
		buf[0] = {kind = .Array, role = .Value, n = u32(used), spelling = u16(used - 1)}
		for i in 1 ..< used {
			buf[i] = {lo = u64(i), n = 1, kind = .Number, role = .Value}
		}
		trimmed := tape.nodes_trim_tail(buf, used, reserved, committed)
		testing.expect_value(t, len(trimmed), used)
		testing.expect_value(t, trimmed[0].n, u32(used))
		testing.expect_value(t, trimmed[used - 1].lo, u64(used - 1))

		mapped_doc := tape.Document {
			nodes     = trimmed,
			flags     = {.Mapped_Nodes},
			allocator = context.allocator,
		}
		cloned, cerr := tape.clone_document(&mapped_doc, context.allocator)
		testing.expect_value(t, cerr, nil)
		testing.expect(t, .Mapped_Nodes not_in cloned.flags)
		testing.expect_value(t, len(cloned.nodes), used)
		testing.expect_value(t, cloned.nodes[used - 1].lo, u64(used - 1))

		tape.destroy_document(&mapped_doc)
		testing.expect(t, raw_data(mapped_doc.nodes) == nil && mapped_doc.flags == {})
		tape.destroy_document(&cloned)
		testing.expect(t, raw_data(cloned.nodes) == nil)
	}

	// 2. Zero-node trim unmaps the entire reservation and returns nil.
	zbuf, zres, zok := tape.nodes_reserve(65_536)
	if zok {
		zcom := 0
		testing.expect(t, tape.nodes_commit(zbuf, &zcom, 64))
		ztrimmed := tape.nodes_trim_tail(zbuf, 0, zres, zcom)
		testing.expect(t, ztrimmed == nil && raw_data(ztrimmed) == nil)
	}

	// 3. End-to-end build: Tracking_Allocator never bypasses heap; default_allocator activates OS reservation.
	count :: 70_000
	src_buf := make([]u8, 2 + count * 2, context.allocator)
	defer delete(src_buf, context.allocator)
	src_buf[0] = '['
	pos := 1
	for i in 0 ..< count {
		if i > 0 {
			src_buf[pos] = ','
			pos += 1
		}
		src_buf[pos] = '1'
		pos += 1
	}
	src_buf[pos] = ']'
	pos += 1
	src := src_buf[:pos]

	tracked, terr := json.build(src, .Json, {}, context.allocator)
	testing.expect_value(t, terr, nil)
	defer tape.destroy(&tracked)
	testing.expect(t, .Mapped_Nodes not_in tracked.flags)
	testing.expect_value(t, len(tracked.nodes), count + 1)

	mapped, merr := json.build(src, .Json, {}, runtime.default_allocator())
	testing.expect_value(t, merr, nil)
	defer tape.destroy(&mapped)
	when size_of(uintptr) == 8 && (ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD || ODIN_OS == .Windows) {
		testing.expect(t, .Mapped_Nodes in mapped.flags)
	}
	testing.expect_value(t, len(mapped.nodes), len(tracked.nodes))
	testing.expect_value(t, mapped.nodes[0], tracked.nodes[0])
	testing.expect_value(t, mapped.nodes[count], tracked.nodes[count])

	mclone, mcerr := tape.clone_document(&mapped, context.allocator)
	testing.expect_value(t, mcerr, nil)
	defer tape.destroy(&mclone)
	testing.expect(t, .Mapped_Nodes not_in mclone.flags)
	testing.expect_value(t, len(mclone.nodes), len(tracked.nodes))
}
