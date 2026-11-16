package core

import "base:runtime"
import "core:slice"

// A piece of a commit's output that its edits wrote: `lo` through `hi` of the output, in place of the source bytes
// that end at `src_hi`. The output past it, up to the next piece, is the source's bytes from `src_hi` on.
Written :: struct {
	lo, hi, src_hi: u64,
}

// Whether `out`, a text a commit of `list` made, read through `walk` (which passes each token to `written_hook`), holds
// the document the edits make, judged as `reads_as_edited` judges a read of it. `written` are the pieces the edits
// wrote, sorted, and every other byte is the source's. `known` is false where an edit holds no value to read back.
// Works in the context allocator.
reads_written :: proc(list: ^Edit_List, out: []u8, as: As, written: []Written, walk: proc(src: []u8, as: As, w: ^Written_Read) -> Maybe(Fault)) -> (err: Document_Error, known: bool) {
	w := Written_Read{view = {src = out, as = as}, written = written, pending = -1, ctx = context}
	w.a = applied_of(list, ways = false) or_return
	touched := make([]Node_Index, len(list.edits))
	for e, i in list.edits {
		touched[i] = e.node
	}
	if !slice.is_sorted(touched) {
		slice.sort(touched)
	}
	w.touched = touched
	append(&w.frames, Written_Frame{node = NO_NODE, end = Node_Index(subtree_size(list.doc, ROOT)), ins = len(w.a.inserts)})
	if fault, bad := walk(out, as, &w).?; bad {
		return {kind = .No_Memory} if fault.kind == .No_Memory else {kind = .Bad_Result, inner = fault}, true
	}
	if w.failed || len(w.frames) != 1 || w.frames[0].c != w.frames[0].end {
		return {kind = .Bad_Result, reason = .Reads_Back_Other}, true
	}
	return {}, true
}

// Where `reads_written` stands in the output: the containers open, the written piece the next token meets and the
// distance from a source byte to the output byte that copies it.
Written_Read :: struct {
	a:       Applied,
	view:    Token_View, // the output's
	written: []Written,
	next:    int, // the first of `written` that does not end at or before the token read
	shift:   i64, // an output byte past `written[next - 1]` less the source byte it copies
	pending: int, // the insert into an object whose key was read and whose value comes next, -1 if none
	touched:    []Node_Index, // the node of each edit, sorted
	touched_at: int, // the first of `touched` at or past the last container read
	frames:  [dynamic]Written_Frame,
	failed:  bool,
	ctx:     runtime.Context,
}

// An open container of the output as the source holds it: `c` the next source node of its members, `at` the index of
// the member `c` starts, and `ins` the next of the inserts, sorted by container and index, that the container takes.
// The frame below the root has no container and takes no insert.
@(private = "file")
Written_Frame :: struct {
	node, c, end:     Node_Index,
	at:               u32,
	ins:              int,
	object, key_next: bool,
}

// The hook a format's walk runs `reads_written` with. It stops the walk at the first token that does not read as
// edited.
written_hook :: proc "contextless" (w: ^Written_Read, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	if t.role != .Value && t.role != .Key {
		return s, .Next
	}
	action := written_reads(w, t)
	if action == .Stop {
		w.failed = true
	}
	return s, action
}

// The walk of a copied value stays off the context, which only a written value and a container's frame need.
@(private = "file")
written_reads :: #force_inline proc "contextless" (w: ^Written_Read, t: Token) -> Action #no_bounds_check {
	doc := w.a.doc
	f := &w.frames[len(w.frames) - 1]
	if t.kind == .End {
		kept_gone(w, f)
		if w.pending >= 0 || f.c != f.end || (f.ins < len(w.a.inserts) && w.a.inserts[f.ins].node == f.node) {
			return .Stop
		}
		context = w.ctx
		pop(&w.frames)
		return .Next if len(w.frames) > 0 else .Stop
	}
	open := t.kind == .Array || t.kind == .Object
	lo, hi := scalar_ends(t)
	for w.next < len(w.written) && w.written[w.next].hi <= lo {
		x := w.written[w.next]
		w.shift = i64(x.hi) - i64(x.src_hi)
		w.next += 1
	}
	if w.next < len(w.written) && w.written[w.next].lo <= lo {
		context = w.ctx
		return .Next if !open && hi <= w.written[w.next].hi && written_token(w, f, t) else .Stop
	}
	if w.pending >= 0 || (w.next < len(w.written) && (hi if !open else lo + 1) > w.written[w.next].lo) {
		return .Stop
	}
	if !f.object || f.key_next {
		if _, due := kept_gone(w, f); due {
			return .Stop
		}
	}
	c := f.c
	if c >= f.end || has(w.a.is_set, c) {
		return .Stop
	}
	n := doc.nodes[c]
	if i64(t.lo) - w.shift != i64(n.lo) || t.kind != n.kind || (!open && t.n != n.n) {
		return .Stop
	}
	if f.object && f.key_next {
		f.c, f.key_next = c + 1, false
		return .Next
	}
	f.c, f.at, f.key_next = c + Node_Index(n.n if open else 1), f.at + 1, f.object
	if !open {
		return .Next
	}
	// A container no edit reaches whose source bytes, up to the next node's, hold no written piece is the source's
	// bytes, which the walk judges past with no token given.
	end := f.c
	for w.touched_at < len(w.touched) && w.touched[w.touched_at] < c {
		w.touched_at += 1
	}
	past := doc.nodes[end].lo if int(end) < len(doc.nodes) else u64(len(doc.src))
	if (w.touched_at == len(w.touched) || w.touched[w.touched_at] >= end) && (w.next == len(w.written) || i64(w.written[w.next].lo) - w.shift >= i64(past)) {
		return .Skip
	}
	context = w.ctx
	append(&w.frames, Written_Frame{node = c, c = c + 1, end = end, ins = lower_node(w.a.inserts, c), object = t.kind == .Object, key_next = t.kind == .Object})
	return .Next
}

// Whether `t`, a token in a piece an edit wrote, is the next key or value an edit writes in frame `f`, and reads as it.
@(private = "file")
written_token :: proc(w: ^Written_Read, f: ^Written_Frame, t: Token) -> bool {
	doc := w.a.doc
	if p := w.pending; p >= 0 {
		w.pending = -1
		return t.role == .Value && written_as(w, t, w.a.inserts[p].v)
	}
	if !f.object || f.key_next {
		if p, due := kept_gone(w, f); due {
			f.ins += 1
			if !f.object {
				return written_as(w, t, w.a.inserts[p].v)
			}
			w.pending = p
			return written_key(w, t, w.a.inserts[p].key)
		}
	}
	c := f.c
	if c >= f.end || !has(w.a.is_set, c) {
		return false
	}
	if f.object && f.key_next {
		renamed, is_renamed := entry_of(w.a.renames, c + 1)
		f.c, f.key_next = c + 1, false
		return is_renamed && written_key(w, t, renamed.key)
	}
	f.c, f.at, f.key_next = c + Node_Index(subtree_size(doc, c)), f.at + 1, f.object
	return t.role == .Value && written_as(w, t, set_of(&w.a, c))
}

// Steps frame `f` past the members that edits remove, up to the next insert, and returns whether that insert is due.
@(private = "file")
kept_gone :: proc "contextless" (w: ^Written_Read, f: ^Written_Frame) -> (insert: int, due: bool) {
	for {
		if insert, due = insert_due(w, f); due || f.c >= f.end {
			return
		}
		v := f.c + 1 if f.object else f.c
		if !has(w.a.gone, v) {
			return
		}
		f.c, f.at = v + Node_Index(subtree_size(w.a.doc, v)), f.at + 1
	}
}

// The next insert frame `f` takes, when its index is the member the frame stands at.
@(private = "file")
insert_due :: #force_inline proc "contextless" (w: ^Written_Read, f: ^Written_Frame) -> (int, bool) {
	if f.ins < len(w.a.inserts) && w.a.inserts[f.ins].node == f.node && w.a.inserts[f.ins].at <= f.at {
		return f.ins, true
	}
	return 0, false
}

@(private = "file")
written_key :: proc(w: ^Written_Read, t: Token, want: string) -> bool {
	text, ok := token_text(w.view.readers, &w.view, t, context.allocator)
	return t.role == .Key && ok && text == want
}

@(private = "file")
written_as :: proc(w: ^Written_Read, t: Token, want: Value) -> bool {
	read := Document{view = w.view, nodes = []Node{t}}
	return reads_back_as(want, Node_Ref{&read, ROOT})
}
