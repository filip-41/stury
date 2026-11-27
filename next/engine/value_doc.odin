package engine

import "base:intrinsics"
import "base:runtime"
import "core:encoding/base64"
import "core:io"
import "core:slice"
import "core:unicode/utf8"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import ops_write "stury:lib/ops/write"
import "stury:lib/query"

// Materializes a `query.Value` into a neutral `tape.Document` without recursion, preserving native
// `tape.Kind.Bytes` when `preserve_bytes` is true (binary targets like CBOR/MessagePack) and spelling
// `.Bytes` as RFC 4648 base64 `.String` nodes when `preserve_bytes` is false (text targets).

@(private = "file", rodata)
VALUE_DOC_FORMAT := tape.Format {
	name      = "values",
	id        = 0,
	options   = .None,
	facts     = {},
	caps      = {},
	dups      = .Last,
	number    = proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
		n, _ := spell.number_strict(src, t.lo, t.lo + u64(t.n))
		return n
	},
	same_text = proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
		return t.n == o.n && string(src[t.lo:][:t.n]) == string(other[o.lo:][:o.n])
	},
	key_hash  = proc "contextless" (src: []u8, t: tape.Token) -> u32 {
		return tape.text_hash(src[t.lo:][:t.n])
	},
}

@(require_results)
value_to_document :: proc(
	h: ^query.Heap,
	root: query.Value,
	preserve_bytes := true,
	max_depth := 0,
	double_fmt: proc(buf: []u8, f: f64) -> string = nil,
	allocator := context.allocator,
) -> (
	doc: tape.Document,
	err: ops_write.Error,
) {
	if allocator.procedure == nil {
		return {}, runtime.Allocator_Error.Out_Of_Memory
	}
	depth_cap := max_depth if max_depth > 0 else tape.DEFAULT_DEPTH

	Open_Cont :: struct {
		at:       tape.Node_Index,
		children: u32,
		object:   bool,
	}
	Task :: struct {
		close: bool,
		k, v:  query.Value,
	}

	nodes := make([dynamic]tape.Node, 0, 16, allocator)
	src := make([dynamic]u8, 0, 64, allocator)
	counts := make([dynamic]tape.Child_Count, 0, 0, allocator)
	open := make([dynamic]Open_Cont, 0, 16, allocator)
	stack := make([dynamic]Task, 0, 16, allocator)
	num_buf := make([dynamic]u8, 0, 32, allocator)
	defer {
		for item in stack {
			query.release(h, item.k)
			query.release(h, item.v)
		}
		delete(stack)
		delete(open)
		delete(num_buf)
		if err != nil {
			delete(nodes)
			delete(src)
			delete(counts)
		}
	}

	note_child :: #force_inline proc(open: []Open_Cont, is_key: bool) {
		if len(open) > 0 && open[len(open) - 1].object == is_key {
			open[len(open) - 1].children += 1
		}
	}

	append(&stack, Task{v = query.retain(root)}) or_return

	for len(stack) > 0 {
		t := pop(&stack)
		if t.close {
			closed := pop(&open)
			count := closed.children
			if count >= u32(tape.MAX_CHILDREN) {
				append(&counts, tape.Child_Count{node = closed.at, count = count}) or_return
			}
			n := &nodes[closed.at]
			n.n = u32(len(nodes)) - u32(closed.at)
			n.spelling = u16(min(count, u32(tape.MAX_CHILDREN)))
			continue
		}

		v := t.v
		defer query.release(h, v)
		if t.k.kind != .Absent {
			ks := query.text_of(t.k)
			if !utf8.valid_string(ks) {
				query.release(h, t.k)
				return {}, ops_write.Refused{node = tape.Node_Index(len(nodes)), why = .No_Spelling}
			}
			when size_of(int) > size_of(u32) {
				if len(ks) > int(max(u32)) {
					query.release(h, t.k)
					return {}, runtime.Allocator_Error.Out_Of_Memory
				}
			}
			klo := u64(len(src))
			if _, aerr := append(&src, ks); aerr != nil {
				query.release(h, t.k)
				return {}, aerr
			}
			knode := tape.Node{kind = .String, role = .Key, lo = klo, n = u32(len(ks))}
			query.release(h, t.k)
			append(&nodes, knode) or_return
			note_child(open[:], true)
		}

		switch query.type_of(v) {
		case .Absent, .Null:
			append(&nodes, tape.Node{kind = .Null, role = .Value}) or_return
			note_child(open[:], false)
		case .False:
			append(&nodes, tape.Node{kind = .False, role = .Value}) or_return
			note_child(open[:], false)
		case .True:
			append(&nodes, tape.Node{kind = .True, role = .Value}) or_return
			note_child(open[:], false)
		case .String:
			s := query.text_of(v)
			if !utf8.valid_string(s) {
				return {}, ops_write.Refused{node = tape.Node_Index(len(nodes)), why = .No_Spelling}
			}
			when size_of(int) > size_of(u32) {
				if len(s) > int(max(u32)) {
					return {}, runtime.Allocator_Error.Out_Of_Memory
				}
			}
			lo := u64(len(src))
			append(&src, s) or_return
			append(&nodes, tape.Node{kind = .String, role = .Value, lo = lo, n = u32(len(s))}) or_return
			note_child(open[:], false)
		case .Bytes:
			raw := query.bytes_of(v)
			if preserve_bytes {
				when size_of(int) > size_of(u32) {
					if len(raw) > int(max(u32)) {
						return {}, runtime.Allocator_Error.Out_Of_Memory
					}
				}
				lo := u64(len(src))
				if len(raw) > 0 {
					append(&src, ..raw) or_return
				}
				append(&nodes, tape.Node{kind = .Bytes, role = .Value, lo = lo, n = u32(len(raw))}) or_return
			} else {
				enc_len := base64.encoded_len(raw, base64.Encode_Options{})
				when size_of(int) > size_of(u32) {
					if enc_len > int(max(u32)) {
						return {}, runtime.Allocator_Error.Out_Of_Memory
					}
				}
				lo := u64(len(src))
				if enc_len > 0 {
					old_len := len(src)
					resize(&src, old_len + enc_len) or_return
					if _, berr := base64.encode_into_buf(src[old_len : old_len + enc_len], raw, options = base64.Encode_Options{}); berr != nil {
						return {}, ops_write.Refused{node = tape.Node_Index(len(nodes)), why = .No_Spelling}
					}
				}
				append(&nodes, tape.Node{kind = .String, role = .Value, lo = lo, n = u32(enc_len)}) or_return
			}
			note_child(open[:], false)
		case .Number:
			clear(&num_buf)
			if query.write_json(h, &num_buf, v, {double = double_fmt}) != .Ok {
				return {}, ops_write.Refused{node = tape.Node_Index(len(nodes)), why = .No_Spelling}
			}
			if string(num_buf[:]) == "null" {
				append(&nodes, tape.Node{kind = .Null, role = .Value}) or_return
				note_child(open[:], false)
				continue
			}
			p := raw_data(num_buf)
			end := intrinsics.ptr_offset(p, len(num_buf))
			q, sp, nerr := tape.number_scan(p, end, true, false)
			if nerr != .None || q != end {
				return {}, ops_write.Refused{node = tape.Node_Index(len(nodes)), why = .No_Spelling}
			}
			lo := u64(len(src))
			append(&src, ..num_buf[:]) or_return
			append(&nodes, tape.Node{kind = .Number, role = .Value, lo = lo, n = u32(len(num_buf)), spelling = u16(sp)}) or_return
			note_child(open[:], false)
		case .Array, .Object:
			if len(open) >= depth_cap {
				return {}, ops_write.Refused{node = tape.Node_Index(len(nodes)), why = .Malformed}
			}
			is_obj := query.type_of(v) == .Object
			at := tape.Node_Index(len(nodes))
			append(&nodes, tape.Node{kind = .Object if is_obj else .Array, role = .Value}) or_return
			note_child(open[:], false)
			append(&open, Open_Cont{at = at, object = is_obj}) or_return

			c, cs := query.cursor_open(h, v)
			if cs != .Ok {
				return {}, runtime.Allocator_Error.Out_Of_Memory
			}
			defer query.cursor_close(&c)
			ch := make([dynamic]Task, 0, 8, allocator)
			defer {
				for item in ch {
					query.release(h, item.k)
					query.release(h, item.v)
				}
				delete(ch)
			}
			for {
				ck, cx, more, ns := query.cursor_next(h, &c)
				if ns != .Ok {
					return {}, runtime.Allocator_Error.Out_Of_Memory
				}
				if !more {
					break
				}
				if _, aerr := append(&ch, Task{k = ck if is_obj else query.ABSENT, v = cx}); aerr != nil {
					query.release(h, ck)
					query.release(h, cx)
					return {}, aerr
				}
				if !is_obj {
					query.release(h, ck)
				}
			}
			append(&stack, Task{close = true}) or_return
			#reverse for &item in ch {
				append(&stack, item) or_return
				item = {}
			}
		}
	}

	if len(counts) > 1 {
		slice.sort_by(counts[:], proc(a, b: tape.Child_Count) -> bool { return a.node < b.node })
	}
	src_slice: []u8
	if len(src) > 0 {
		src_slice = src[:]
	} else {
		delete(src)
	}
	counts_slice: []tape.Child_Count
	if len(counts) > 0 {
		counts_slice = counts[:]
	} else {
		delete(counts)
	}
	return tape.Document{
		src       = src_slice,
		nodes     = nodes[:],
		counts    = counts_slice,
		format    = &VALUE_DOC_FORMAT,
		flags     = {.Owns_Src},
		allocator = allocator,
	}, nil
}

@(require_results)
is_binary_spec :: proc "contextless" (spec: Spec) -> bool {
	e, ok := entry_of_spec(spec)
	return ok && e.format != nil && .Binary in e.format.caps
}

// Writes `v` in target format `to`, emitting native `.Bytes` for binary formats (CBOR/MessagePack)
// and RFC 4648 base64 strings for text formats.
@(require_results)
write_value :: proc(
	h: ^query.Heap,
	v: query.Value,
	to: Spec,
	opts := ops_write.Options{},
	double_fmt: proc(buf: []u8, f: f64) -> string = nil,
	allocator := context.allocator,
) -> (
	text: []u8,
	err: ops_write.Error,
) {
	doc := value_to_document(h, v, preserve_bytes = is_binary_spec(to), double_fmt = double_fmt, allocator = allocator) or_return
	defer tape.destroy_document(&doc)
	text, _, err = write(&doc, to, opts, allocator)
	return text, err
}

// Streams `v` in target format `to` into `sink`, emitting native `.Bytes` for binary formats
// (CBOR/MessagePack) and RFC 4648 base64 strings for text formats.
@(require_results)
write_value_to :: proc(
	sink: io.Writer,
	h: ^query.Heap,
	v: query.Value,
	to: Spec,
	opts := ops_write.Options{},
	double_fmt: proc(buf: []u8, f: f64) -> string = nil,
	allocator := context.allocator,
) -> ops_write.Error {
	doc := value_to_document(h, v, preserve_bytes = is_binary_spec(to), double_fmt = double_fmt, allocator = allocator) or_return
	defer tape.destroy_document(&doc)
	_, err := write_to(sink, &doc, to, opts, allocator)
	return err
}
