#+build darwin, linux, freebsd, openbsd, netbsd
package jsonpath_tests

import "core:strings"
import "core:testing"
import "stury:json"
import "stury:jsonpath"
import "stury:lib/query"
import "stury:testkit"

// Zero-recursion verification: 100,000-deep queries and 100,000-deep documents evaluated on a 1 MiB thread stack.
@(private = "file")
DEEP_LEVELS :: 100_000

@(private = "file")
Count_Only :: struct {
	h:     ^query.Heap,
	count: int,
	last:  i64,
}

@(private = "file")
count_cb :: proc(data: rawptr, v: query.Value, _: string) -> bool {
	c := (^Count_Only)(data)
	if i, ok := query.as_i64(v); ok {
		c.last = i
	}
	c.count += 1
	query.release(c.h, v)
	return true
}

@(test)
deep_parse_and_eval_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 4 cases on a 1 MiB thread stack:
	// 0: compile 100,000 chained `.a` segments
	// 1: compile 100,000 nested `((((...))))` parens in filter (default depth rejects with .Depth; lifted succeeds)
	// 2: eval `$..v` on a 100,000-deep nested object `{"a":{"a":...{"v":42}...}}` (default depth rejects with .Exceeded; lifted succeeds)
	// 3: eval `$..[0]` on a 100,000-deep nested array `[[[...[99]...]]]`
	testkit.expect_reads_on_thread(t, 1 << 20, 4, nil, "jsonpath_deep", proc(shape: int, _: []u8) -> bool {
		switch shape {
		case 0:
			b := strings.builder_make()
			defer strings.builder_destroy(&b)
			strings.write_byte(&b, '$')
			for _ in 0 ..< DEEP_LEVELS {
				strings.write_string(&b, ".a")
			}
			prog, err := jsonpath.compile(strings.to_string(b), {max_depth = DEEP_LEVELS * 4})
			defer jsonpath.destroy_program(prog)
			return err.kind == .None

		case 1:
			b := strings.builder_make()
			defer strings.builder_destroy(&b)
			strings.write_string(&b, "$[?")
			for _ in 0 ..< DEEP_LEVELS {
				strings.write_byte(&b, '(')
			}
			strings.write_string(&b, "@.a == 1")
			for _ in 0 ..< DEEP_LEVELS {
				strings.write_byte(&b, ')')
			}
			strings.write_byte(&b, ']')
			src := strings.to_string(b)
			p_def, err_def := jsonpath.compile(src)
			jsonpath.destroy_program(p_def)
			if err_def.kind != .Depth {
				return false
			}
			prog, err := jsonpath.compile(src, {max_depth = DEEP_LEVELS * 8})
			defer jsonpath.destroy_program(prog)
			return err.kind == .None

		case 2:
			b := strings.builder_make()
			defer strings.builder_destroy(&b)
			for _ in 0 ..< DEEP_LEVELS {
				strings.write_string(&b, `{"a":`)
			}
			strings.write_string(&b, `{"v":42}`)
			for _ in 0 ..< DEEP_LEVELS {
				strings.write_byte(&b, '}')
			}
			doc, derr := json.build(transmute([]u8)strings.to_string(b), .Json, {budget = {depth = DEEP_LEVELS + 16}})
			if derr != nil {
				return false
			}
			prog, cerr := jsonpath.compile(`$..v`)
			if cerr.kind != .None {
				return false
			}
			defer jsonpath.destroy_program(prog)

			// Default depth rejects cleanly with .Exceeded.
			h_def: query.Heap
			query.heap_init(&h_def, context.allocator)
			defer query.heap_destroy(&h_def)
			root_def, st_def := query.document_value(&h_def, doc, false)
			if st_def != .Ok {
				return false
			}
			cnt_def := Count_Only{h = &h_def}
			end_def := jsonpath.eval(prog, &h_def, root_def, count_cb, &cnt_def)
			query.release(&h_def, root_def)
			if end_def != .Exceeded {
				return false
			}

			// Lifted depth evaluates all 100,000 levels cleanly.
			h: query.Heap
			query.heap_init(&h, context.allocator, depth = DEEP_LEVELS + 16)
			defer query.heap_destroy(&h)
			root, st := query.document_value(&h, doc, true)
			if st != .Ok {
				return false
			}
			defer query.release(&h, root)
			cnt := Count_Only{h = &h}
			end := jsonpath.eval(prog, &h, root, count_cb, &cnt, {budget = {depth = DEEP_LEVELS + 16}})
			return end == .Done && cnt.count == 1 && cnt.last == 42

		case 3:
			b := strings.builder_make()
			defer strings.builder_destroy(&b)
			for _ in 0 ..< DEEP_LEVELS {
				strings.write_byte(&b, '[')
			}
			strings.write_string(&b, `99`)
			for _ in 0 ..< DEEP_LEVELS {
				strings.write_byte(&b, ']')
			}
			doc, derr := json.build(transmute([]u8)strings.to_string(b), .Json, {budget = {depth = DEEP_LEVELS + 16}})
			if derr != nil {
				return false
			}
			prog, cerr := jsonpath.compile(`$..[0]`)
			if cerr.kind != .None {
				return false
			}
			defer jsonpath.destroy_program(prog)
			h: query.Heap
			query.heap_init(&h, context.allocator, depth = DEEP_LEVELS + 16)
			defer query.heap_destroy(&h)
			root, st := query.document_value(&h, doc, true)
			if st != .Ok {
				return false
			}
			defer query.release(&h, root)
			cnt := Count_Only{h = &h}
			end := jsonpath.eval(prog, &h, root, count_cb, &cnt, {budget = {depth = DEEP_LEVELS + 16}})
			return end == .Done && cnt.count == DEEP_LEVELS && cnt.last == 99
		}
		return false
	})
}
