package tape_test

import "base:runtime"
import "core:mem"
import "core:testing"
import "stury:json"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:testkit"
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
