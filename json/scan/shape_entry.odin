package scan

import c "../../core"
import index "index"
import lex "lex"

// Entry points and head probe for the shape walk (`scan_shape`, `scan_shape_lazy`, `shape_skip_walk_pays`).

// Read `src` into `root` along `run.shape`. `lazy` skips, unchecked, every value the shape does not read.
// What it reads is checked in full. A typed fault is `TYPED_FAULT` with `run.fault` set, and anything else is the
// walk's own result, at the offset `validate` gives. `unique` refuses a repeated key (`.Duplicate_Key`), in
// every object the walk reads. Keys past the first KEY_SCRATCH open at once are remembered in
// `context.allocator`, and given back before the return.
scan_shape :: proc(src: []byte, run: ^c.Shape_Run, root: rawptr, lazy: bool, limits: Limits, $dialect: Dialect, $unique: bool) -> Maybe(Error) {
	return shape_read(src, run, root, lazy, limits, dialect, unique, false)
}

// `scan_shape`, or with `pass_unread` the walk of `shape_walk_passing`.
@(private = "file")
shape_read :: proc(src: []byte, run: ^c.Shape_Run, root: rawptr, lazy: bool, limits: Limits, $dialect: Dialect, $unique, $pass_unread: bool) -> Maybe(Error) {
	Q :: bit_set[Walk_Kind]{.Shape} + (bit_set[Walk_Kind]{.Unique} when unique else {}) + (bit_set[Walk_Kind]{.Pass_Unread} when pass_unread else {})
	// Words rather than a `Query_Ctx` local, as in `scan_queries` (`query_ctx_zero`).
	ctx_words: [size_of(Query_Ctx) / 8]u64 = ---
	ctx := (^Query_Ctx)(&ctx_words)
	c.query_ctx_zero(ctx, Q)
	ctx.hooks = &FORMAT_HOOKS
	ctx.shape = run
	run.sp = 0
	run.ops, run.fields = raw_data(run.shape.ops), raw_data(run.shape.fields)
	run.pend_op, run.pend_dest, run.pend_live = run.shape.root, root, true
	when unique {
		key_scratch: Key_Scratch = ---
		keys: Key_Set
		key_set_init(&keys, &key_scratch, context.allocator)
		defer key_set_destroy(&keys)
		ctx.keys = &keys
	}
	s := enter_document(src, limits, MAX_DEPTH)
	ctx.max_depth = s.limits.max_depth
	// JSONC reads every byte: `lazy` does not apply.
	when dialect == .Jsonc {
		jc: Jsonc_Cursor
		jsonc_skip(&s, &jc)
		if err := jsonc_walk(&s, ctx, Q, &jc); err != nil {
			return err
		}
		return jsonc_finish(&s, &jc)
	}
	lex.skip_ws(&s)
	// A passing walk never skips. The `when` keeps the skipping walk out of it.
	if !pass_unread && lazy && u64(len(src)) - s.pos >= SHAPE_LAZY_MIN_BYTES && shape_skip_walk_pays(run, src, s.pos, s.limits.max_depth) {
		when !pass_unread {
			when SCAN_FORCE_SLOW {
				cur: Byte_Cursor
			} else {
				ix: index.Index(VALUES_FACTS) = ---
				cur := index_cursor(&ix, &s, true)
			}
			if err := walk_value_q(&s, ctx, s.limits.max_depth, .Values, Q, &cur, true, false); err != nil {
				return err
			}
		}
	} else {
		cur: Byte_Cursor
		if err := walk_value_q(&s, ctx, s.limits.max_depth, .Values, Q, &cur, false, false); err != nil {
			return err
		}
	}
	return finish(&s)
}

// `scan_shape` under `.Lazy`, for JSON. Above the gate, when the probe declines the skipping walk, the complete
// walk passes unread strings unchecked (`.Pass_Unread`), in its own proc with its own context, since a third
// walk in `scan_shape` moves the spills of its complete walk.
scan_shape_lazy :: proc(src: []byte, run: ^c.Shape_Run, root: rawptr, limits: Limits, $unique: bool) -> Maybe(Error) {
	s := enter_document(src, limits, MAX_DEPTH)
	lex.skip_ws(&s)
	if u64(len(src)) - s.pos >= SHAPE_LAZY_MIN_BYTES {
		run.ops, run.fields = raw_data(run.shape.ops), raw_data(run.shape.fields)
		// A key repeated in a member nothing reads is still a repeat: `unique` skips nothing.
		if unique || !shape_skip_walk_pays(run, src, s.pos, s.limits.max_depth) {
			return shape_walk_passing(src, run, root, limits, unique)
		}
		run.skip_pays = true
	}
	return scan_shape(src, run, root, true, limits, .Json, unique)
}

// Whether a `.Lazy` read of `src` has nothing worth skipping: it is under the gate, or the probe declines the
// skipping walk. The descent then reads it, checking every value, faster than the walk that passes unread
// strings. A probe that chose the skipping walk is kept for `scan_shape_lazy`.
shape_lazy_reads_all :: proc(src: []byte, run: ^c.Shape_Run, limits: Limits) -> bool {
	s := enter_document(src, limits, MAX_DEPTH)
	lex.skip_ws(&s)
	if u64(len(src)) - s.pos < SHAPE_LAZY_MIN_BYTES {
		return true
	}
	run.ops, run.fields = raw_data(run.shape.ops), raw_data(run.shape.fields)
	run.skip_pays = shape_skip_walk_pays(run, src, s.pos, s.limits.max_depth)
	return !run.skip_pays
}

@(private = "file")
shape_walk_passing :: #force_no_inline proc(src: []byte, run: ^c.Shape_Run, root: rawptr, limits: Limits, $unique: bool) -> Maybe(Error) {
	return shape_read(src, run, root, false, limits, .Json, unique, true)
}

// The smallest document the lazy shape walk may skip in. Below it the index cannot repay its build and the
// probe, so `.Lazy` takes the complete walk.
SHAPE_LAZY_MIN_BYTES :: 16 << 10
// The head of the document `shape_skip_walk_pays` reads: a `1 << SHAPE_PROBE_SHIFT`th of it, up to
// SHAPE_PROBE_BYTES.
SHAPE_PROBE_SHIFT :: 7
SHAPE_PROBE_BYTES :: 4096
// What containers nothing reads must amount to for the skipping walk: a share, in eighths, of the bytes
// probed, values no longer on average than SHAPE_SKIP_VALUE_BYTES, since the complete walk checks a long
// string or number nearly as fast as the index classifies its bytes, and either values in them, in halves per
// value the probe passed, or a share, in eighths, of the bytes the probe passed less unread scalars, since the
// skipping walk's extra cost falls on what is read.
SHAPE_SKIP_EIGHTHS :: 4
SHAPE_SKIP_HALF_VALUES :: 9
SHAPE_SKIP_VALUE_BYTES :: 32
SHAPE_SKIP_READ_EIGHTHS :: 5

// The state of `shape_skip_walk_pays`: a scanner over the head, and what it found to jump.
@(private = "file")
Shape_Probe :: struct {
	s:       Scanner,
	run:     ^c.Shape_Run,
	past:    []byte, // the head and as much again, for an unread container the head cuts
	give_up: u64, // the position, less the bytes below, past which they can no longer reach their share
	skipped: u64, // bytes of containers nothing reads
	inner:   u64, // the values in them
	values:  u64, // values passed whole
	unread:  u64, // bytes of scalars nothing reads
}

// Whether the lazy shape walk's index pays on the document's head: the containers nothing reads are a large
// enough share of it, of short values, and either hold many values or outweigh what is read. A scalar nothing
// reads, and whitespace, count neither as skipped nor as read. The answer only picks a walk, since `.Lazy`
// permits skipping and does not require it: a head holding no whole value keeps the index.
shape_skip_walk_pays :: #force_no_inline proc(run: ^c.Shape_Run, src: []byte, root, max_depth: u64) -> bool {
	if run.skip_pays {
		return true
	}
	head := root + min((u64(len(src)) - root) >> SHAPE_PROBE_SHIFT, SHAPE_PROBE_BYTES)
	give_up := root + (head - root) * (8 - SHAPE_SKIP_EIGHTHS) / 8
	past := src[:min(u64(len(src)), head + (head - root))]
	p := Shape_Probe{s = Scanner{src = src[:head], pos = root}, run = run, past = past, give_up = give_up}
	shape_probe_value(&p, run.shape.root, 0, max_depth)
	read := p.s.pos - root
	if p.values == 0 {
		return true
	}
	many := p.inner * 2 >= p.values * SHAPE_SKIP_HALF_VALUES
	outweigh := p.skipped * 8 >= (read - p.unread) * SHAPE_SKIP_READ_EIGHTHS
	return p.skipped * 8 >= read * SHAPE_SKIP_EIGHTHS && p.inner * SHAPE_SKIP_VALUE_BYTES >= p.skipped &&
		(many || outweigh)
}

// The value at the probe's position, read as op `op_i` would read it at depth `depth`. False when the head or
// the share's being out of reach cut it off.
@(private = "file")
shape_probe_value :: proc(p: ^Shape_Probe, op_i: u32, depth, max_depth: u64) -> bool {
	b := lex.skip_peek(&p.s)
	if b < 0 {
		return false
	}
	op := &p.run.ops[op_i]
	vc := lex.VCLASS[b]
	for (op.kind == .Pointer || op.kind == .Union) && b != 'n' && vc != VC_NONE {
		if op.kind == .Pointer {
			op = &p.run.ops[op.elem]
		} else if arm := op.arm_of[vc]; arm != 0 {
			op = &p.run.ops[p.run.fields[op.elem + u32(arm) - 1].op]
		} else {
			break
		}
	}
	if depth + 1 < max_depth && ((vc == VC_OBJECT && op.kind == .Struct) || (vc == VC_ARRAY && op.kind in SHAPE_SEQUENCES)) {
		p.s.pos += 1
		closer := int(b) + 2 // `{` + 2 is `}`, `[` + 2 is `]`
		for first := true; ; first = false {
			if p.s.pos - p.skipped > p.give_up {
				return false
			}
			b = lex.skip_peek(&p.s)
			if b == closer {
				p.s.pos += 1
				p.values += 1
				return true
			}
			if !first {
				if b != ',' {
					return false
				}
				p.s.pos += 1
			}
			if vc == VC_ARRAY {
				if !shape_probe_value(p, op.elem, depth + 1, max_depth) {
					return false
				}
				continue
			}
			if lex.skip_peek(&p.s) != '"' {
				return false
			}
			lo := int(p.s.pos)
			key_end := lex.value_end(p.s.src, lo, VC_STRING, 0)
			if key_end < 0 {
				return false
			}
			// By text: an escaped key may read as unknown, which only weighs toward skipping.
			key := string(p.s.src[lo + 1:key_end - 1])
			field := -1
			if shape_first_has(op.first, p.s.src[lo + 1]) {
				for f, i in p.run.fields[op.elem:][:op.count] {
					if f.name == key {
						field = i
						break
					}
				}
			}
			p.s.pos = u64(key_end)
			if lex.skip_peek(&p.s) != ':' {
				return false
			}
			p.s.pos += 1
			if field >= 0 {
				if !shape_probe_value(p, p.run.fields[op.elem + u32(field)].op, depth + 1, max_depth) {
					return false
				}
				continue
			}
			vb := lex.skip_peek(&p.s)
			if vb < 0 {
				return false
			}
			vvc := lex.VCLASS[vb]
			lo = int(p.s.pos)
			if vvc == VC_OBJECT || vvc == VC_ARRAY {
				end, inner := shape_probe_skip(p.past, lo, len(p.s.src))
				p.skipped += u64(end - lo)
				p.inner += inner
				p.s.pos = u64(end)
				if end >= len(p.s.src) {
					return false
				}
			} else {
				end := lex.value_end(p.s.src, lo, vvc, 0)
				if end < 0 {
					return false
				}
				p.unread += u64(end) - p.s.pos
				p.s.pos = u64(end)
			}
			p.values += 1
		}
	}
	end := lex.value_end(p.s.src, int(p.s.pos), vc, int(max_depth - depth))
	if end < 0 {
		return false
	}
	p.s.pos = u64(end)
	p.values += 1
	return true
}

// Where the container at `src[lo]` that nothing reads ends, and the values in it, by its commas and open
// brackets outside strings, or where it is cut: by the end of `src`, or past `head` once its values are too
// long on average to pay. Its brackets are counted, not matched, and its depth is not limited: the probe only
// picks a walk, and the walk checks or skips the container itself.
@(private = "file")
shape_probe_skip :: proc(src: []byte, lo, head: int) -> (end: int, inner: u64) {
	depth := 0
	in_string, escaped := false, false
	for i in lo ..< len(src) {
		b := src[i]
		if in_string {
			if escaped {
				escaped = false
			} else if b == '\\' {
				escaped = true
			} else if b == '"' {
				in_string = false
			}
		} else if b == '"' {
			in_string = true
		} else if b == ',' {
			inner += 1
			if i >= head && inner * SHAPE_SKIP_VALUE_BYTES < u64(i - lo) {
				return i, inner
			}
		} else if b | 0x20 == '{' {
			depth += 1
			inner += 1
		} else if b | 0x20 == '}' {
			depth -= 1
			if depth == 0 {
				return i + 1, inner
			}
		}
	}
	return len(src), inner
}
