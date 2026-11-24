package cbor

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The records of a CBOR text: the items of a sequence (RFC 8742) under `.Concatenated`, and the elements of the root
// array or the members of the root map under `.Elements` and `.Members`. Each record is judged as a read of its bytes
// alone judges them, in place in the text.

// The records of a text of a CBOR spec, which `records_open` makes and each call of `records_validate`, `records_find`
// or `records_scan` reads in batches, as `tape.Records` says.
Records :: struct {
	using records: tape.Records,
	spec:          Spec,
	// Under `.Elements` and `.Members`, the root's elements or members left, `INDEF_COUNT` for an indefinite root.
	left:          u64,
	// Under `.Elements` and `.Members`, the walk's count of `Budget.steps`, which counts the containers of the whole
	// text.
	steps:         u64,
	prev:          [2]u64, // under `.Members` in a spec that orders keys, the span of the last key
	took:          bool, // under `.Members`, the key read for the next record took a tolerance, which that record reports
	item:          Item_Frame, // in a text in pieces, the framing of the item at `pos` across windows
	// Under `.Elements` and `.Members`, the containers the framing is in, the root first and the records' container at
	// `len(path)`: for those outside the one it reads in, at `depth`, the children each has left and in a spec that
	// orders keys the span of the last key read, and in a text in pieces what each holds of their bytes.
	levels:        [ITEM_LEVELS + 1]Path_Level,
	depth:         int,
	// The tags that mark the containers the framing is in, each a level of the walk as a container is.
	tagged:        u64,
	stage:         Stage,
	passed:        int, // the children of the container at `depth` passed, while the framing goes down `path`
	// The records' container has closed, or the text holds none, and the framing reads what follows.
	leaving:       bool,
}

// What the framing reads next in the container at `Records.depth`.
@(private)
Stage :: enum u8 {
	Open, // the container's head at `pos`, past its tags
	Child, // its next child, or its end
	Value, // the value of the member whose key it read
	Tail, // past the root, where the text ends
}

// A container the framing is in. In a text in pieces, `key` spans the last key read in it in `held_bytes`.
@(private)
Path_Level :: struct {
	left: u64,
	prev: [2]u64,
	key:  [2]u64,
	tags: u64, // the tags that mark it
}

// Opens the records of `src`, a text of `spec` framed as `framing`, each read under `opts`. The budget's limits hold
// for each record, but `Budget.steps` under `.Elements` and `.Members`, which counts the containers of the whole text.
// Another format's options and `.Lines`, which CBOR has no reading of, end the records with `tape.Bad_Option` before
// any is read. A fault in a root's elements or members ends them with the fault `validate` gives for the whole text.
// In a text in pieces under `.Elements` and `.Members` a window holds each head, key and value the framing reads
// whole, as it holds a record, and the framing holds the last key read in each map it is in. A root
// of another kind than the framing takes holds no records, and ends them with the verdict `validate` gives for the
// text, nil for a valid one.
// `opts.runner` has no effect on records. A text in pieces opens with its first window, as `tape.Records` says.
records_open :: proc(src: []u8, framing := tape.Framing.Concatenated, spec := Spec.Cbor, opts := Options{}, path: []tape.Step = nil) -> (r: Records) {
	if spec > max(Spec) {
		panic("cbor: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts, r.steps = src, framing, spec, opts, steps_of(opts)
	if opts.pieces != nil {
		r.src = tape.piece_src(src, opts.pieces.from)
	}
	r.path = path
	if err := tape.options_refused(&FORMATS[spec], opts); err != nil {
		r.err, r.at = err, .Done
	} else if err = build.records_path_refused(framing, path); err != nil {
		r.err, r.at = err, .Done
	} else if len(path) > ITEM_LEVELS {
		r.err, r.at = tape.Exceeded{tape.NO_BYTE, .Memory}, .Done
	} else if framing == .Lines {
		r.err, r.at = tape.Bad_Option{"framing"}, .Done
	}
	return
}

// Reads the next records of `r` into `out` and judges each, as `validate` judges its bytes alone. Returns how many it
// filled, and fewer than `len(out)` once the records have ended, when `err` says why, nil at the text's end. Needs
// `READ_STACK` bytes of stack and faults on a thread with less.
@(require_results)
records_validate :: proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	// A record's walk reads a whole item, in a text in pieces too, so the count of steps alone makes it lax.
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Cbor:
		if lax {
			return records_validate_as(r, out, .Cbor, true, allocator)
		}
		return records_validate_as(r, out, .Cbor, false, allocator)
	case .Preferred:
		if lax {
			return records_validate_as(r, out, .Preferred, true, allocator)
		}
		return records_validate_as(r, out, .Preferred, false, allocator)
	case .Deterministic:
		if lax {
			return records_validate_as(r, out, .Deterministic, true, allocator)
		}
		return records_validate_as(r, out, .Deterministic, false, allocator)
	case .Length_First:
		if lax {
			return records_validate_as(r, out, .Length_First, true, allocator)
		}
		return records_validate_as(r, out, .Length_First, false, allocator)
	}
	panic("cbor: spec out of range")
}

// Reads the next records of `r` into `out`, and for each the first value `path` reaches in it into the same place of
// `answers`, as `find` reads its bytes alone, with every offset from the text's first byte. The walk reads each record
// to its end whatever `read.stop_early` says, as the next starts there. Needs `READ_STACK` bytes of stack and faults on
// a thread with less.
@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	// A record's walk reads a whole item, in a text in pieces too, so the count of steps alone makes it lax.
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Cbor:
		if lax {
			return records_find_as(r, path, out, answers, .Cbor, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Cbor, false, read, allocator)
	case .Preferred:
		if lax {
			return records_find_as(r, path, out, answers, .Preferred, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Preferred, false, read, allocator)
	case .Deterministic:
		if lax {
			return records_find_as(r, path, out, answers, .Deterministic, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Deterministic, false, read, allocator)
	case .Length_First:
		if lax {
			return records_find_as(r, path, out, answers, .Length_First, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Length_First, false, read, allocator)
	}
	panic("cbor: spec out of range")
}

// Reads the next records of `r` into `out`, and for each the document of its nodes the paths of `demand` reach into the
// same place of `docs`, as `scan` reads its bytes alone. The documents are in the records' block, valid until the next
// call or `tape.destroy_records`, as `tape.Record_Block` says. Needs `READ_STACK` bytes of stack and faults on a thread
// with less.
@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	hook.probe_stack(READ_STACK)
	// A record's walk reads a whole item, in a text in pieces too, so the count of steps alone makes it lax.
	lax := r.opts.budget.steps != 0
	switch r.spec {
	case .Cbor:
		if lax {
			return records_scan_as(r, demand, out, docs, .Cbor, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Cbor, false, read, allocator)
	case .Preferred:
		if lax {
			return records_scan_as(r, demand, out, docs, .Preferred, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Preferred, false, read, allocator)
	case .Deterministic:
		if lax {
			return records_scan_as(r, demand, out, docs, .Deterministic, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Deterministic, false, read, allocator)
	case .Length_First:
		if lax {
			return records_scan_as(r, demand, out, docs, .Length_First, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Length_First, false, read, allocator)
	}
	panic("cbor: spec out of range")
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, lo, h, regs, a, ctx, hook.no_hook)
	}
	return build.records_validate(r, out, &FORMATS[S], &RULES, caller, frame, walk)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
		regs: hook.Regs
		return walk_again((^Walk(S, build.Finder, LAX, build.FINDER_CAPS))(h.walk), h.src, lo, &regs, build.finder_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, lo, h, regs, a, ctx, build.finder_hook)
	}
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, respell, rewalk, frame, walk)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Scanner, regs: ^hook.Regs, lo: u64) -> hook.Walk_Result {
		return walk_again((^Walk(S, build.Scanner, LAX, build.SCANNER_CAPS))(h.walk), h.b.doc.src, lo, regs, build.scanner_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame(container_of(r, Records, "records"), S)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walk(container_of(r, Records, "records"), S, LAX, lo, h, regs, a, ctx, build.scanner_hook)
	}
	return build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, rewalk, node_bound, frame, walk)
}

// The next record's first byte and the text's end, which its walk may read to. Under `.Members` the key is read into
// `r.key` and the first byte is the value's. False once the records have ended, and in a text in pieces once the
// window ends before what the framing reads next. A fault in a head, a key, a value passed or what follows the root
// ends them with the fault `validate` gives for the text. The items of a whole sequence, the common case, take no call.
@(private)
record_frame :: #force_inline proc(r: ^Records, $S: Spec) -> (lo, cut: u64, ok: bool) {
	if r.framing == .Concatenated && r.opts.pieces == nil && r.at != .Done {
		n := u64(len(r.src))
		if r.pos >= n {
			r.at = .Done
			return
		}
		return r.pos, n, true
	}
	return record_frame_other(r, S)
}

// `record_frame` for the elements and members of a container, and for a sequence in pieces. Under `.Elements` and
// `.Members` it goes down `path` to the records' container, reads its children, then what follows them to the text's
// end, each step taken once the window holds what it reads. A text with no such container holds no records: its
// verdict is the one `validate` gives, which in pieces the framing reaches by passing the rest of the text.
@(private)
record_frame_other :: proc(r: ^Records, $S: Spec) -> (lo, cut: u64, ok: bool) {
	if r.at == .Done {
		return
	}
	n := u64(len(r.src))
	if r.framing == .Concatenated {
		if r.opts.pieces != nil {
			return record_frame_window(r)
		}
		if r.pos >= n {
			r.at = .Done
			return
		}
		return r.pos, n, true
	}
	pieces := r.opts.pieces != nil
	for {
		switch r.stage {
		case .Open:
			if !r.leaving {
				if r.depth > 0 || u64(len(r.path)) < build.read_depth(r.opts) {
					framed(r, .Heads) or_return
					from, steps := r.pos, r.steps
					if tags, opened := root_open(r, S, level_object(r, r.depth)); opened {
						level_open(r, tags)
						r.stage = .Child
						continue
					}
					r.pos, r.steps = from, steps
				}
				if !pieces {
					records_refuse(r, nil)
					return
				}
				// The text holds no records, and the value is passed.
				r.leaving = true
			}
			framed(r, .Item) or_return
			e: tape.Error
			if r.depth == 0 && n == 0 {
				// An empty text holds no item, which `validate` says before it walks one.
				e = tape.Fault{rules = &RULES, kind = .Truncated, detail = u8(Detail.No_Item)}
			} else {
				e = path_pass(r, S, u64(r.depth))
			}
			if e != nil {
				frame_refuse(r, e)
				return
			}
			level_up(r, false)
		case .Child:
			if r.left == INDEF_COUNT {
				framed(r, .Byte) or_return
			}
			if r.left == 0 || r.left == INDEF_COUNT && r.pos < n && r.src[r.pos] == 0xff {
				r.pos += u64(r.left != 0)
				if !r.leaving && r.depth < len(r.path) && !pieces {
					records_refuse(r, nil)
					return
				}
				r.leaving = true
				level_up(r, true)
				continue
			}
			object := level_object(r, r.depth)
			if object {
				framed(r, .Item) or_return
			}
			if r.left != INDEF_COUNT {
				r.left -= 1
			}
			if object {
				if e := record_key(r, S); e != nil {
					frame_refuse(r, e)
					return
				}
			}
			r.stage = .Value
			if !r.leaving && r.depth < len(r.path) {
				step := r.path[r.depth]
				name, named := step.(tape.Name)
				taken := tape.key_names(&FORMATS[S], r.src, r.key, string(name)) if named else r.passed == int(step.(tape.Index))
				r.passed += 1
				if taken {
					r.levels[r.depth].left, r.levels[r.depth].prev = r.left, r.prev
					r.depth += 1
					r.stage = .Open
				}
			}
		case .Value:
			framed(r, .Item) or_return
			if !r.leaving && r.depth == len(r.path) {
				r.stage = .Child
				return r.pos, n, true
			}
			if e := path_pass(r, S, u64(r.depth) + 1); e != nil {
				frame_refuse(r, e)
				return
			}
			r.stage = .Child
		case .Tail:
			framed(r, .Byte) or_return
			if r.pos != n {
				_, e, _ := hook.walk_error(fault(r.pos, .Bad_Char, .Trailing), &RULES)
				frame_refuse(r, e)
				return
			}
			r.key, r.at = {}, .Done
			return
		}
	}
}

// Whether the container at level `depth` of the framing is a map.
@(private)
level_object :: #force_inline proc "contextless" (r: ^Records, depth: int) -> bool {
	if depth < len(r.path) {
		_, named := r.path[depth].(tape.Name)
		return named
	}
	return r.framing == .Members
}

// Starts the level of the container `root_open` read, which `tags` tags mark. In a text in pieces its last key is held
// past the bytes held for the levels around it.
@(private)
level_open :: proc(r: ^Records, tags: u64) {
	r.prev, r.passed = {}, 0
	if r.depth == len(r.path) {
		r.key, r.took = {}, false
	}
	at: u64
	if held := held_bytes(r); held != nil {
		at = u64(len(held^))
	}
	r.levels[r.depth] = {key = {at, at}, tags = tags}
	r.tagged += tags
}

// Leaves the container at level `depth`, `opened` when `level_open` started it, for the one around it, or for what
// follows the root.
@(private)
level_up :: proc(r: ^Records, opened: bool) {
	if opened {
		r.tagged -= r.levels[r.depth].tags
	}
	if r.depth == 0 {
		r.stage = .Tail
		return
	}
	r.depth -= 1
	lv := &r.levels[r.depth]
	r.left, r.prev, r.stage = lv.left, lv.prev, .Child
	if held := held_bytes(r); held != nil {
		resize(held, int(lv.key[1]))
	}
}

// The bytes the framing of a text in pieces holds, in the pieces' state: the last key read in each container it is in.
// Nil for a text not in pieces, and when memory for them is refused.
@(private)
held_bytes :: proc(r: ^Records) -> ^[dynamic]u8 {
	p := r.opts.pieces
	if p == nil {
		return nil
	}
	s, err := hook.piece_state(p, hook.Piece_State)
	if err != nil {
		return nil
	}
	if s.names.allocator.procedure == nil {
		s.names.allocator = p.allocator
	}
	return &s.names
}

// Holds the key `src[lo:hi]` read in the container at `r.depth` of a text in pieces as its last key. In a spec that
// orders keys a key that does not follow the last is the fault the walk gives for it.
@(private)
key_hold :: proc(r: ^Records, $S: Spec, lo, hi: u64) -> tape.Error {
	held := held_bytes(r)
	if held == nil {
		return runtime.Allocator_Error.Out_Of_Memory
	}
	lv := &r.levels[r.depth]
	n := hi - lo
	resize(held, int(lv.key[1]))
	if _, err := append(held, ..r.src[lo:hi]); err != nil {
		return err
	}
	when S >= .Deterministic {
		key := [2]u64{lv.key[1], lv.key[1] + n}
		if lv.key[1] > lv.key[0] && !key_before(held[:], lv.key, key, S) {
			res := key_fault(held[:], lv.key, key[0], key[1], r.opts.dups == .Refuse)
			_, e, _ := hook.walk_error(hook.Walk_Result(lo << 16 | u64(res) & 0xffff), &RULES)
			return e
		}
	}
	copy(held[lv.key[0]:], held[lv.key[1]:])
	resize(held, int(lv.key[0] + n))
	lv.key = {lv.key[0], lv.key[0] + n}
	return nil
}

// Ends the records with the error `validate` gives for the text, or `err` when it gives none. In a text in pieces,
// whose bytes before the window are gone, it is `err`, the fault of the head, key or value the framing read in the
// window that holds it whole, as every byte before it was judged and every count before it holds.
@(private, cold)
frame_refuse :: proc(r: ^Records, err: tape.Error) {
	if r.opts.pieces == nil {
		records_refuse(r, err)
		return
	}
	r.err, r.at = err, .Done
}

// Reads the head of a container, a map for `object` and else an array, past the tags that mark it, and returns how
// many tags do, false when the text holds no such head of spec `S`, its count is more than the bytes left hold, or it
// and its tags nest past the depth the walk takes. A tag
// that folds the number it marks (2 to 5) leaves no container. The container takes a step, as each container does.
@(private)
root_open :: proc "contextless" (r: ^Records, $S: Spec, object: bool) -> (tags: u64, ok: bool) {
	n := u64(len(r.src))
	at := r.pos
	for at < n && r.src[at] >> 5 == 6 {
		tags += 1
		// A head of additional information 28 to 31 is no tag head, and has no length to step by.
		if r.src[at] & 31 > 27 {
			return
		}
		tag, hl, read := read_head(r.src, at, r.src[at] & 31)
		if !read || tag >= 2 && tag <= 5 || S != .Cbor && !shortest(r.src[at] & 31, tag) {
			return
		}
		at += hl
	}
	if at >= n || u64(r.depth) + 1 + r.tagged + tags > build.read_depth(r.opts) {
		return
	}
	b := r.src[at]
	major := u8(5 if object else 4)
	if b >> 5 != major || b & 31 > 27 && b & 31 != 31 {
		return
	}
	r.steps -= 1
	if r.steps == 0 {
		return
	}
	r.at = .Open
	if b & 31 == 31 {
		r.left, r.pos = INDEF_COUNT, at + 1
		return tags, S == .Cbor
	}
	arg, hl, read := read_head(r.src, at, b & 31)
	if !read || S != .Cbor && !shortest(b & 31, arg) || arg > (n - at - hl) >> (major - 4) {
		return
	}
	r.left, r.pos = arg, at + hl
	return tags, true
}

// Judges the value at `r.pos` alone, inside `depth` containers and the tags that mark them, as the walk of the whole text judges it, and moves
// `r.pos` past it. Returns the fault, nil for none.
@(private)
path_pass :: proc(r: ^Records, $S: Spec, depth: u64) -> tape.Error {
	none: hook.No_Hooks
	regs: hook.Regs
	ctx := context
	res: hook.Walk_Result
	left: u64
	if build.read_lax(r.opts) {
		res, _, left = walk_item(r.src, r.pos, S, true, r.opts, build.read_depth(r.opts) - depth - r.tagged, r.steps, &none, &regs, context.allocator, &ctx, hook.no_hook)
	} else {
		res, _, left = walk_item(r.src, r.pos, S, false, r.opts, build.read_depth(r.opts) - depth - r.tagged, r.steps, &none, &regs, context.allocator, &ctx, hook.no_hook)
	}
	if u8(res) != 0 {
		_, err, _ := hook.walk_error(res, &RULES)
		return err
	}
	r.steps, r.pos = left, u64(res) >> 16
	return nil
}

// The hook of the walk that reads a member's key, which keeps the key and stops the walk.
@(private)
Member_Key :: struct {
	protocol: hook.Protocol(hook.NO_HOOKS_CAPS, hook.Unused, hook.Unused, hook.Unused),
	key:      tape.Token,
}

@(private)
member_key_hook :: proc "contextless" (h: ^Member_Key, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.key = t
	return s, .Stop
}

// Reads the key of the member at `r.pos` into `r.key`, as the walk reads a key in a map, and moves `r.pos` to its
// value. Returns the fault of a key that fails or, in a spec that orders keys, does not follow the last, nil for none.
// In a text in pieces the key's bytes are held as the last key of the container at `r.depth`.
@(private)
record_key :: proc(r: ^Records, $S: Spec) -> tape.Error {
	h: Member_Key
	regs: hook.Regs
	levels: [2]Level(S)
	w: Walk(S, Member_Key, false, hook.NO_HOOKS_CAPS)
	walk_init(&w, r.src, &h, raw_data(levels[:]), 2, 2, r.opts)
	w.depth = 2
	res := run(&w, r.pos, 1, FLAG_OBJECT | 2, &regs, member_key_hook)
	if u8(res) != hook.WALK_STOPPED {
		_, err, _ := hook.walk_error(res, &RULES)
		return err if err != nil else tape.Error(tape.Fault{at = u64(res) >> 16, rules = &RULES, kind = .Truncated})
	}
	end := u64(res) >> 16
	if r.opts.pieces != nil {
		key_hold(r, S, r.pos, end) or_return
	} else {
		when S >= .Deterministic {
			if !keys_ordered(r.src, &r.prev, r.pos, end, S) {
				_, err, _ := hook.walk_error(key_fault(r.src, r.prev, r.pos, end, r.opts.dups == .Refuse), &RULES)
				return err
			}
		}
	}
	r.key, r.pos, r.took = h.key, end, w.tolerated
	return nil
}

// Ends the records with the error `validate` gives for the text, or `err` when it gives none.
@(private, cold)
records_refuse :: proc(r: ^Records, err: tape.Error) {
	r.err = validate(r.src, r.spec, r.opts)
	if r.err == nil {
		r.err = err
	}
	r.at = .Done
}

// Walks the record at `lo` for hook `h` from registers `regs`. Returns the walk's result `res` and whether it took a
// tolerance, the record's end as `hi`, and `ok` false once the records have ended, as a fault in a record ends them:
// under `.Concatenated` with the record's fault, as no next item can be found past it, and under the other framings
// with the fault `validate` gives for the text.
@(private)
record_walk :: proc(r: ^Records, $S: Spec, $LAX: bool, lo: u64, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	concatenated := r.framing == .Concatenated
	limit := build.read_depth(r.opts) - (0 if concatenated else 1 + u64(len(r.path)) + r.tagged)
	steps := steps_of(r.opts) if concatenated else r.steps
	res, tolerated, left := walk_item(r.src, lo, S, LAX, r.opts, limit, steps, h, regs, allocator, ctx, on)
	walked.res, walked.tolerated = res, tolerated || r.took
	r.took = false
	end := res
	if u8(res) == hook.WALK_STOPPED {
		// The hook stopped the walk before the record's end. A walk with no hook finds the end, and `res` keeps the
		// stop for the caller.
		none: hook.No_Hooks
		none_regs: hook.Regs
		end, _, left = walk_item(r.src, lo, S, LAX, r.opts, limit, steps, &none, &none_regs, allocator, ctx, hook.no_hook)
	}
	if u8(end) != 0 {
		_, err, _ := hook.walk_error(end, &RULES)
		if concatenated {
			r.err, r.at = err, .Done
		} else {
			frame_refuse(r, err)
		}
		return
	}
	if !concatenated {
		r.steps = left
	}
	walked.hi, walked.ok = u64(end) >> 16, true
	r.pos, r.at = walked.hi, .After
	return
}
