// The records of XML. An XML text is one document whose end the walk finds only at the input's end, past its trailing
// comments and processing instructions, so under `.Concatenated` the record is the whole text from the reader's
// position to the input's end, and an input of no bytes holds none. A stream's record is settled once its input has
// ended. A reader the entry points open holds no record reads: a caller that builds or scans a record sets
// `it.docs = record_docs(spec)`.
package xml

import "base:runtime"
import "core:io"
import core "../core"
import engine "../core/build"
import cw "../core/write"
import records "../core/records"

// The framing of XML texts, which a handle's `records` and the readers the entry points open reach.
@(private, rodata)
FRAMING := records.Framing_Services {
	next  = #partial {.Concatenated = next_text, .Entries = records.entries_walked},
	judge = records.no_judge,
	close = records.entries_walked_close,
	closed = #partial {.Entries = true},
	entry_step = step_entries,
	entry_build = build_entry,
}

// The cursor of `.Entries`, and a copy of what it held before its last step.
@(private)
Entry_Cursor :: struct {
	cursor: Cursor,
	back:   ^core.Held_Tokens,
}

@(private)
Entry_Paused :: Paused(core.Holding(records.Entry_Walk))

// The walk of `.Entries` from the reader's position, or its resume, and the cursor's part in following a stream's
// window. The walk past a member reads on to the next element's end, so a member is given once the window holds that
// end. The window keeps the bytes from the walk's pause and its held tokens on, and from the reader's first position
// when the DTD declares an entity or an attribute list, since their nodes span the DTD's bytes. The names of the open
// elements and the namespace declarations in scope that lie before that are copied out of the window.
@(private)
step_entries :: proc(it: ^records.Reader, w: ^records.Entry_Walk, op: records.Entry_Op) -> (hi: u64, fault: Maybe(core.Fault)) {
	e := (^Entry_Cursor)(w.cursor)
	switch op {
	case .Step:
		if e == nil {
			failed: runtime.Allocator_Error
			if e, failed = new(Entry_Cursor, it.allocator); failed != nil {
				return 0, core.Fault{kind = .No_Memory}
			}
			e.cursor.allocator = it.allocator
			first := !w.logging
			w.cursor, w.logging = e, true
			hi, fault = walk(it.src, it.pos, .Xml, options_of(it.as), w, nil, records.entry_hook, &e.cursor)
			if first && w.given && w.prolog == nil {
				if fault = read_prolog(it, w); fault != nil {
					w.given = false
					return
				}
			}
		} else {
			hi, fault = walk_resume(it.src, &e.cursor, .Xml, options_of(it.as), w, nil, records.entry_hook)
		}
		if w.given && it.input.procedure != nil && !it.last && !paused_within(e.cursor.held, u64(len(it.src))) {
			w.given = false
			return 0, core.Fault{at = u64(len(it.src)), kind = .Truncated}
		}
	case .Free:
		if e != nil {
			held_free(e.back, it.allocator)
			core.cursor_free(&e.cursor)
			free(e, it.allocator)
			w.cursor = nil
		}
	case .Save:
		if e == nil {
			return
		}
		if e.cursor.held == nil {
			held_free(e.back, it.allocator)
			e.back = nil
		} else if e.back == nil {
			ok: bool
			if e.back, ok = held_clone(e.cursor.held, it.allocator); !ok {
				return 0, core.Fault{kind = .No_Memory}
			}
		} else if !held_copy(e.back, e.cursor.held, it.allocator) {
			return 0, core.Fault{kind = .No_Memory}
		}
	case .Restore:
		core.cursor_free(&e.cursor)
		e.cursor.held, e.back = e.back, nil
	case .Rebase:
		old, old_n := e.cursor.src, e.cursor.n
		e.cursor.src, e.cursor.n = raw_data(it.src), u64(len(it.src))
		if held := e.cursor.held; held != nil {
			for &t in held.queue[held.next:] {
				if !t.close {
					t.token.lo = records.shifted(t.token.lo, w.delta, it.pin)
				}
			}
			held.hi = records.shifted(held.hi, w.delta, it.pin)
			if held.walk != nil {
				paused_rebase((^Entry_Paused)(held.walk), old, old_n, raw_data(it.src), u64(len(it.src)), w.delta, it.pin)
			}
		}
		// A pinned window keeps the DTD's offsets.
		if w.prolog != nil && it.pin == 0 {
			dtd_shift(dtd_view(w.prolog), w.delta)
		}
	case .Keep:
		hi = max(u64)
		held := e.cursor.held if e != nil else nil
		if held == nil {
			return
		}
		if held.walk != nil && it.pin == 0 {
			if d := (^Entry_Paused)(held.walk).walk.dtd; d != nil && (d.head.entities > 0 || d.head.attrs > 0) {
				it.pin = d.head.subset_hi
			}
		}
		for t in held.queue[held.next:] {
			if !t.close && t.token.lo >= it.pin {
				hi = min(hi, t.token.lo)
			}
		}
		if held.walk != nil {
			paused := (^Entry_Paused)(held.walk)
			hi = min(hi, paused.at)
			if !paused_keep(paused, raw_data(it.src), u64(len(it.src)), it.pin, hi) {
				return 0, core.Fault{kind = .No_Memory}
			}
		}
	case .Clone:
		if e != nil {
			c, failed := new(Entry_Cursor, it.allocator)
			if failed != nil {
				return 0, core.Fault{kind = .No_Memory}
			}
			c.cursor = e.cursor
			ok: bool
			if c.cursor.held, ok = held_clone(e.cursor.held, it.allocator); !ok {
				free(c, it.allocator)
				return 0, core.Fault{kind = .No_Memory}
			}
			w.cursor = c
		}
	}
	return
}

// Whether the walk `held` holds paused within the window of `n` bytes, or ended on a fault there that no later byte
// changes, so the member before it stands.
@(private)
paused_within :: proc(held: ^core.Held_Tokens, n: u64) -> bool {
	if held == nil {
		return false
	}
	if held.walk != nil {
		return true
	}
	f, faulted := held.fault.?
	return faulted && f.kind != .Truncated && f.at + core.FAULT_REACH <= n
}

// A copy of what a cursor holds, which shares none of its memory: nil for nil, false when memory runs out.
@(private)
held_clone :: proc(from: ^core.Held_Tokens, allocator: runtime.Allocator) -> (to: ^core.Held_Tokens, ok: bool) {
	if from == nil {
		return nil, true
	}
	context = core.cursor_context(allocator)
	if to = new(core.Held_Tokens); to == nil {
		return nil, false
	}
	if !held_copy(to, from, allocator) {
		held_free(to, allocator)
		return nil, false
	}
	return to, true
}

// Makes `to` a copy of what `from` holds, which shares none of its memory, in the memory `to` holds where it is large
// enough. False when memory runs out, with `to` what `held_free` frees.
@(private)
held_copy :: proc(to, from: ^core.Held_Tokens, allocator: runtime.Allocator) -> bool {
	context = core.cursor_context(allocator)
	queue, walk, release := to.queue, to.walk, to.release
	to^ = from^
	to.queue, to.next, to.walk, to.release = queue, 0, walk, release
	clear(&to.queue)
	if _, failed := append(&to.queue, ..from.queue[from.next:]); failed != nil {
		return false
	}
	if from.walk == nil {
		if to.walk != nil {
			to.release(to.walk)
			to.walk = nil
		}
		return true
	}
	to.release = from.release
	if to.walk == nil {
		// The pause frees itself in its own allocator.
		context = core.cursor_context((^Entry_Paused)(from.walk).allocator)
		if to.walk = new(Entry_Paused); to.walk == nil {
			return false
		}
	}
	return paused_copy((^Entry_Paused)(to.walk), (^Entry_Paused)(from.walk))
}

@(private)
held_free :: proc(held: ^core.Held_Tokens, allocator: runtime.Allocator) {
	c := Cursor{held = held, allocator = allocator}
	core.cursor_free(&c)
}

// The hooks of the prolog's walk, which stops at the root's key. `core.No_Hooks` would not stop it, since the walk
// calls no hook of that type.
@(private)
Prolog_Hooks :: struct {}

// Reads the DTD's sealed tables into `w.prolog` by one walk of the prolog from the reader's first position, which stops
// at the root's key, for the documents of the members.
@(private)
read_prolog :: proc(it: ^records.Reader, w: ^records.Entry_Walk) -> Maybe(core.Fault) {
	h: Prolog_Hooks
	regs: core.Hook_Regs
	_, _, state := walk_keeping(it.src, w.start - it.base, options_of(it.as), &h, &regs, proc "contextless" (_: ^Prolog_Hooks, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
		return s, .Stop if t.role == .Key else .Next
	})
	defer runtime.heap_free(raw_data(state))
	if len(state) == 0 {
		return nil
	}
	failed: runtime.Allocator_Error
	if w.prolog, failed = runtime.make_aligned([]u8, len(state), 16, it.allocator); failed != nil {
		return core.Fault{kind = .No_Memory}
	}
	copy(w.prolog, state)
	// The walk sets `.In_Place` as it walks a reference over its literal, past the prolog, so a member's nodes may lie
	// in the subset whenever a replacement text holds markup or a reference.
	v := dtd_view(w.prolog)
	for &e in v.entities {
		for b in entity_text(&v, it.src, &e) {
			if b == '<' || b == '&' {
				v.head.flags += {.In_Place}
				return nil
			}
		}
	}
	return nil
}

// The document of an `.Entries` member, built from the tokens the walk read of it in its place, with the DTD's
// entities and attribute defaults.
@(private)
build_entry :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	w := (^records.Entry_Walk)(it.format)
	return records.entry_document(it, rec, w.prolog if w != nil else nil, false, allocator, proc(b: ^engine.Builder, regs: core.Hook_Regs, tokens: []core.Token) -> core.Hook_Regs {
		regs := regs
		for t in tokens {
			regs, _ = engine.builder_hook(b, regs, t)
		}
		return regs
	})
}

// Frames the text at the reader's position, the rest of the input, judged by the walk from there.
@(private)
next_text :: proc(it: ^records.Reader) -> (rec: records.Record, ok: bool) {
	lo := it.pos
	if lo >= u64(len(it.src)) || it.to != 0 && lo >= it.to {
		return
	}
	h: core.No_Hooks
	if _, fault := walk(it.src, lo, .Xml, options_of(it.as), &h, nil, core.no_hook); fault != nil {
		it.fault = fault
		return
	}
	it.pos = u64(len(it.src))
	return {text = it.src[lo:], at = lo}, true
}

// The reads of a record's value: its build, which every spec shares. A scan of a record builds it.
record_docs :: proc "contextless" ($S: Spec) -> ^records.Record_Docs {
	return &RECORD_DOCS
}

@(private, rodata)
RECORD_DOCS := records.Record_Docs {
	build = build_record,
}

@(private)
build_record :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	doc, err := build_spec(rec.text, .Xml, it.as, false, allocator)
	core.move_document_error(&err, rec.at)
	return doc, err
}

// Opens `src` for its records, as `records.open` does with `as(spec, opts)`, and under `.Entries` the
// members of the container `entries` names, from the root through members.
records_open :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, at: u64 = 0, allocator := context.allocator, entries: []string = nil) -> records.Reader {
	return records.open_with(src, bound_as(S, opts), &FRAMING, nil, framing, at, allocator, entries)
}

// Opens the text `input` gives, as `records.open_stream` does with `as(spec, opts)`.
records_open_stream :: proc(input: io.Reader, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, stream := records.Stream_Options{}, at: u64 = 0, allocator := context.allocator) -> records.Reader {
	return records.open_stream_with(input, bound_as(S, opts), &FRAMING, nil, framing, stream, at, allocator)
}

// Returns the fault of a refused text of `src`, as `records.validate` does with `as(spec, opts)`.
records_validate :: proc(src: []u8, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> ([]core.Fault, runtime.Allocator_Error) {
	return records.validate(src, bound_as(S, opts), framing, allocator, runner, at, &FRAMING)
}

// Hands the text of `src` to `task` as one piece, as `records.each` does with `as(spec, opts)`.
records_each :: #force_inline proc(src: []u8, $S: Spec, framing: core.Framing, task: proc(data: ^$D, piece: ^records.Reader, k: int) -> bool, data: ^D, runner: ^core.Runner = nil, at: u64 = 0, opts := Options{}) -> core.Error {
	return records.each(src, bound_as(S, opts), framing, task, data, runner, at, &FRAMING)
}

// Starts a token write, as `write.tokens_init` does with `as(spec, opts)`.
tokens_init :: proc(t: ^cw.Tokens, $S: Spec, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}) -> core.Typed_Error_Kind {
	return cw.tokens_init(t, bound_as(S, opts), write, allocator, stream, &TOKENS)
}

// Starts a writer of records, as `records.writer_init` does with `as(spec, opts)`.
writer_init :: proc(wr: ^records.Writer, w: io.Stream, $S: Spec, opts := Options{}, framing := core.Framing.Concatenated, write := core.Write_Options{}, allocator := context.allocator) -> core.Typed_Error_Kind {
	return records.writer_init(wr, w, bound_as(S, opts), framing, write, allocator, &TOKENS)
}
