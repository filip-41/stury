package typed

import "base:intrinsics"
import "base:runtime"
import spell "../spell"
import core ".."
import build "../build"

// The typed read of a built document: the same hook as a read of a text, fed by `build.feed_nodes` from `doc.nodes`. The
// document gives each token the walk gave, so a read of a node is the read of that value's text, and it names no format
// but through `doc.readers`.
//
// A read borrows `doc.src` and nothing else of the document. With `borrow_strings` a string with nothing to decode is a
// slice of `doc.src`. Every other string, and everything a read allocates, is the read's `allocator`'s, so the target
// outlives `core.destroy(doc)` and needs `doc.src` only for what it borrowed.

// Reads the value at `node` of `doc` into `target`, with `plan`, or with a nil `plan` by one `plan_make` builds for
// the call from `doc.as` with `context.allocator` and frees. See `Read_Options` for the options. A plan built for
// another type, for another format than `doc`'s, or not by `dsv.plan_make` for a delimited document, is `.Plan_Mismatch`,
// and a nil target, a nil document, a node past
// the document, a key and `.Refuse` are `.Bad_Option`: a document that must hold no repeated key is built under
// `.Refuse`.
unmarshal :: proc {unmarshal_node, unmarshal_answer, unmarshal_value}

unmarshal_node :: proc(doc: ^core.Document, node: core.Node_Index, target: ^$T, plan: ^Plan, read := Read_Options{}, allocator := context.allocator) -> core.Error {
	return core.error_of(read_document(doc, node, typeid_of(T), target, plan, read, allocator))
}

// Reads the value a path found. An answer that is not `.Found` holds no value, and is `.Bad_Option`.
unmarshal_answer :: proc(doc: ^core.Document, answer: core.Answer, target: ^$T, plan: ^Plan, read := Read_Options{}, allocator := context.allocator) -> core.Error {
	if answer.outcome != .Found {
		return core.error_of(core.Typed_Error{kind = .Bad_Option})
	}
	return core.error_of(read_document(doc, answer.node, typeid_of(T), target, plan, read, allocator))
}

// Reads the value `v` into `target` with `plan`, as a text of the plan's format spelling it would be read: a double
// fills an integer field when it holds that integer exactly, and a `Number_Text` by its digits. A node is read from its
// document. A nil plan, and one whose format writes no built value, is `.Bad_Option`, and a plan with no text read
// `.Plan_Mismatch`.
unmarshal_value :: proc(v: core.Value, target: ^$T, plan: ^Plan, read := Read_Options{}, allocator := context.allocator) -> core.Error {
	if r, is_node := core.plain(v).(core.Node_Ref); is_node {
		return core.error_of(read_document(r.doc, r.node, typeid_of(T), target, plan, read, allocator))
	}
	if plan == nil || plan.value_text == nil {
		return core.error_of(core.Typed_Error{kind = .Bad_Option})
	}
	text, err := plan.value_text(plan, v, context.allocator)
	defer delete(text)
	if err.kind != .None {
		return core.error_of(err)
	}
	// The text lasts only the call, so no string borrows from it.
	read := read
	read.borrow_strings = false
	return unmarshal_text(text, target, typeid_of(T), plan, read, allocator)
}

// A read's state beside the hook's own: the document, and the node `build.feed_nodes` is giving the hook.
@(private)
Document_Read :: struct {
	reader: Reader,
	doc:    ^core.Document,
	at:     core.Node_Index,
	room:   int, // the frames the reader holds
}

@(private)
read_document :: proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator) -> core.Typed_Error {
	if doc == nil || doc.readers == nil || int(node) >= len(doc.nodes) || doc.nodes[node].role == .Key || read.dups == .Refuse {
		return {kind = .Bad_Option}
	}
	if plan == nil {
		made, refusal := plan_make(T, doc.as)
		err: core.Typed_Error
		if refused, is_typed := refusal.(core.Typed_Error); is_typed {
			err = refused
		} else if refusal != nil {
			err.kind = .No_Memory
		} else {
			err = read_document(doc, node, T, target, &made, read, allocator)
		}
		own_errors(&err, read.sink)
		plan_destroy(&made)
		return err
	}
	// A format that writes no key frame has tokens that do not type their values, so only its own plan maker's plan reads it.
	if plan != nil && core.same_format(plan.readers, doc.readers) && len(doc.readers.key_open) == 0 {
		if plan.node_read == nil {
			return {kind = .Plan_Mismatch}
		}
		return plan.node_read(doc, node, T, target, plan, read, allocator)
	}
	// The frames and the replay's two words a level grow as the value nests past them.
	frames: [core.MAX_DEPTH + 2]Frame = ---
	ends: [2 * core.MAX_DEPTH]u32 = ---
	d := Document_Read{doc = doc, room = len(frames)}
	regs, err := read_start(&d.reader, doc.src, plan, doc.as, T, target, read, frames[:], allocator)
	if err.kind != .None {
		return err
	}
	defer read_release(&d.reader, frames[:])
	d.reader.format = &d
	d.reader.find_tag = document_tag
	to := u32(node) + (doc.nodes[node].n if doc.nodes[node].kind > .Plain else 1)
	if !build.feed_nodes(doc, u32(node), to, &d, &regs, ends[:], document_step, document_keyed, document_deepen, true) {
		return {kind = .No_Memory}
	}
	return read_end(&d.reader, regs, nil)
}

@(private)
document_deepen :: proc "contextless" (d: ^Document_Read, extra: int) -> bool {
	room, grown := grow_frames(&d.reader, d.room, d.room + extra)
	d.room = room
	return grown
}

// A token as the walk would have given it: a container a path left partial is a value, an `End` has its bracket's byte,
// and a number's digits are folded for the hook.
@(private)
document_step :: proc "contextless" (d: ^Document_Read, regs: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	h := &d.reader
	d.at = at
	t := t
	if t.role == .Partial {
		t.role = .Value
	} else if t.kind == .End {
		// Only the closes that report a byte or end a value read whole ask for it, since a format's `close_end` may walk.
		f := &h.frames[h.sp - 1]
		if needs_close(f) {
			context = h.ctx
			t.lo = d.doc.readers.close_end(d.doc, at) - 1
			t.n = 1
		}
	} else if t.kind == .Number && t.spelling & core.NUMBER_KIND_MASK == 0 {
		h.mant = fold_digits(h.src, t)
	}
	return on_token_spelled(h, regs, t)
}

// Whether the close of the container `f` holds reads the bracket's byte: a fixed array's length, a `required` member, or
// the end of a value read whole.
@(private)
needs_close :: #force_inline proc "contextless" (f: ^Frame) -> bool {
	#partial switch frame_owner(f).kind {
	case .Array, .Required:
		return true
	case .Raw, .Hook:
		return f.seen == 0
	}
	return false
}

// The integer a plain number's integer and fraction digits spell, which wraps past 19 digits.
@(private)
fold_digits :: #force_inline proc "contextless" (src: []u8, t: core.Token) -> (mant: u64) #no_bounds_check {
	p := raw_data(src)[t.lo:]
	end := p[t.n:]
	if p[0] == '-' {
		p = p[1:]
	}
	q := spell.digit_end(p, end, &mant, true)
	if intrinsics.ptr_sub(end, q) > 0 && q[0] == '.' {
		spell.digit_end(q[1:], end, &mant, true)
	}
	return
}

// The key of the value at node `i` of the record `open`, whose cells are its scalar children in column order.
@(private)
document_keyed :: proc "contextless" (d: ^Document_Read, _: core.Hook_Regs, i, open: core.Node_Index) -> (core.Node_Index, bool) {
	return d.doc.shared_keys + 1 + (i - open - 1), d.doc.nodes[open].kind == .Object
}

// Finds the tag member of the object at the node the replay is giving, by replaying that object alone.
@(private)
document_tag :: proc(h: ^Reader, _: u64) -> Tag_Scan {
	d := (^Document_Read)(h.format)
	s := Tag_Scan{view = {src = h.src, as = h.plan.as}, name = h.plan.union_tag}
	regs: core.Hook_Regs
	// The replay opens the object alone, so it needs no more than two levels of ends.
	ends: [2]u32
	build.feed_nodes(d.doc, u32(d.at), u32(d.at) + d.doc.nodes[d.at].n, &s, &regs, ends[:], tag_step, tag_keyed, build.no_deepen, false)
	return s
}

// The tag scan's step, which passes over the containers inside the object.
@(private)
tag_step :: proc "contextless" (s: ^Tag_Scan, regs: core.Hook_Regs, t: core.Token, _: core.Node_Index) -> (core.Hook_Regs, core.Action) {
	next, action := on_tag_token(s, regs, t)
	if action == .Next && (t.kind == .Array || t.kind == .Object) && s.depth > 1 {
		s.depth -= 1
		return next, .Skip
	}
	return next, action
}

@(private)
tag_keyed :: proc "contextless" (_: ^Tag_Scan, _: core.Hook_Regs, _, _: core.Node_Index) -> (core.Node_Index, bool) {
	return core.NO_NODE, false
}
