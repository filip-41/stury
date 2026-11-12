#+private
package cbor

import "base:runtime"
import spell "../core/spell"
import core "../core"
import engine "../core/build"

// CBOR's document holds the walk's tokens over the caller's bytes. A document keeps no whitespace and no comment, so a
// tag is its only fact.

// CBOR's handle, which only `as` names: the readers of a built document with the services, which reach every pass. Every
// spec shares it, since a handle holds its spec. The tables hold pointers to the bound tables, so they are set at
// startup and never written after.
HANDLE := handle_readers(&SERVICES)

SERVICES := core.Services {
	build    = build_item,
	validate = validate_handle,
	scan     = scan_item,
	write    = document_write,
	edit     = &EDIT,
	plans    = rawptr(plan_as),
	reads    = &CHECKS,
	tokens   = &TOKENS,
	records  = &FRAMING,
	docs     = &RECORD_DOCS,
}

// The readers of the handle: `READERS` with the services.
handle_readers :: proc "contextless" (services: ^core.Services) -> core.Readers {
	r := READERS
	r.services = services
	return r
}

// CBOR's fault table, which names the format.
format_rules :: proc "contextless" () -> ^core.Rules {
	return &RULES
}

// The handle of an item of `spec` read or written with `opts` over `readers`.
as_of :: #force_inline proc "contextless" (readers: ^core.Readers, spec: Spec, opts: Options) -> core.As {
	return {readers = readers, spec = u8(spec), max_depth = opts.max_depth, tolerate = opts.tolerate, opts = {0 = u8(opts.structs)}}
}

// The options a handle `as_of` made holds.
options_of :: #force_inline proc "contextless" (as: core.As) -> Options {
	return {max_depth = as.max_depth, tolerate = as.tolerate, structs = Struct_Form(as.opts[0])}
}

// The spec and options of a handle that a walk reads.
handle_rules :: #force_inline proc "contextless" (as: core.As) -> Walk_Rules {
	return {as.max_depth, as.tolerate, Spec(as.spec)}
}

// `walk` of a spec chosen at run time, also telling whether the hook stopped it. A `cursor` that holds a stop resumes
// it, and a stop saves in a `cursor`, which the caller frees.
walk_stopped :: proc "contextless" (src: []u8, lo: u64, rules: Walk_Rules, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor = nil) -> (hi: u64, fault: Maybe(core.Fault), stopped: bool) {
	zero: core.Hook_Regs
	r := regs if regs != nil else &zero
	word: u64
	if rules.spec == .Cbor {
		word = run(src, lo, rules, h, r, on, false, cursor)
	} else {
		word = run(src, lo, rules, h, r, on, true, cursor)
	}
	return core.result_of(word, &RULES)
}

// `walk_stopped` without the stop.
walk_rules :: #force_inline proc "contextless" (src: []u8, lo: u64, rules: Walk_Rules, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	hi, fault, _ = walk_stopped(src, lo, rules, h, regs, on)
	return
}

// Judges `src` as one item of the spec and options handle `as` holds.
validate_handle :: proc "contextless" (src: []u8, as: core.As) -> Maybe(core.Fault) {
	return validate_text(src, handle_rules(as))
}

validate_text :: proc "contextless" (src: []u8, rules: Walk_Rules) -> Maybe(core.Fault) {
	h: core.No_Hooks
	regs: core.Hook_Regs
	hi, fault, _ := walk_stopped(src, 0, rules, &h, &regs, core.no_hook)
	if fault != nil {
		return fault
	}
	return tail_fault(src, hi)
}

// The fault of a text that is no item, or that holds bytes past the one item that ends at `hi`.
tail_fault :: proc "contextless" (src: []u8, hi: u64) -> Maybe(core.Fault) {
	if len(src) == 0 {
		return core.Fault{rules = &RULES, kind = .Truncated, detail = u8(Detail.No_Item)}
	}
	if hi < u64(len(src)) {
		return core.Fault{at = hi, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Trailing)}
	}
	return nil
}

// The handle's build: the one item of the text. Every node is an item of at least one byte, so the item makes at
// most `len(src)` nodes, the hook tests no capacity, and a tag's fact grows the facts. A refused reservation reads the
// item again to size every buffer exactly.
build_item :: proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	rules := handle_rules(as)
	doc, err := build_reserved(src, as, rules, refuse_duplicates, allocator, len(src) + 16, 0)
	if err.kind != .No_Memory {
		return doc, err
	}
	count: engine.Count
	counted: core.Hook_Regs
	walk_rules(src, 0, rules, &count, &counted, engine.builder_hook_count)
	return build_reserved(src, as, rules, refuse_duplicates, allocator, count.nodes, count.facts)
}

// Reads the item into a builder with room for `nodes` nodes, which must cover every node the walk reaches, and
// `facts` facts. The open containers' stack is this frame's, since no item nests past `core.MAX_DEPTH`.
build_reserved :: proc(src: []u8, as: core.As, rules: Walk_Rules, refuse_duplicates: bool, allocator: runtime.Allocator, nodes, facts: int) -> (core.Document, core.Document_Error) {
	frames: [core.MAX_DEPTH]u64 = ---
	b := engine.builder_start(src, as, refuse_duplicates, allocator, nodes, core.MAX_DEPTH, facts, frames[:])
	if len(b.doc.nodes) == 0 {
		return engine.builder_end(&b, engine.BUILDER_REGS, nil)
	}
	regs := engine.BUILDER_REGS
	hi, fault := walk_rules(src, 0, rules, &b, &regs, engine.builder_hook)
	if fault == nil {
		fault = tail_fault(src, hi)
	}
	b.root_close = hi
	return engine.builder_end(&b, regs, fault)
}

// A path read walks the item with the scan's hook, which skips what is off the paths. Every byte the walk passes is
// judged as `validate` judges it, unless `read.stop_early` ends the read at the last answer.
scan_item :: proc(src: []u8, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Path_Error) {
	rules := handle_rules(handle)
	// The scan's room as words, which an uninitialized declaration leaves unwritten where a struct's padding would not.
	room: [size_of(engine.Scan) / 8]u64 = ---
	h := (^engine.Scan)(rawptr(&room))
	frames: [core.MAX_DEPTH]u64 = ---
	if e := engine.scan_start(h, src, handle, paths, read, false, allocator, min(core.reserve_depth(rules.max_depth, len(src)), core.MAX_DEPTH), frames[:], on != nil, state, on); e.kind != .None {
		return {}, e
	}
	regs := engine.BUILDER_REGS
	hi: u64
	fault: Maybe(core.Fault)
	stopped: bool
	h.opts = &rules
	defer h.opts = nil
	if on != nil {
		h.rewalk = rewalk(engine.scan_hook_stream)
		hi, fault, stopped = walk_stopped(src, 0, rules, h, &regs, engine.scan_hook_stream)
	} else if h.many == nil {
		hi, fault, stopped = walk_stopped(src, 0, rules, h, &regs, engine.scan_hook)
	} else {
		h.rewalk = rewalk(engine.scan_hook_many)
		hi, fault, stopped = walk_stopped(src, 0, rules, h, &regs, engine.scan_hook_many)
	}
	if fault == nil && !stopped {
		fault = tail_fault(src, hi)
	}
	err = engine.scan_end(h, regs, hi, fault, &doc)
	return
}

// An iterator over the answers of `paths`, or of `one` when `paths` is nil, in an item read with handle `handle`.
answers_of :: proc(src: []u8, handle: core.As, paths: []core.Path, one: core.Path, read: core.Path_Options, allocator: runtime.Allocator) -> engine.Answer_Iter {
	return {src = src, as = handle, paths = paths, one = one, read = read, allocator = allocator, fill = answers_fill, max_batch = engine.ANSWER_BATCH}
}

// The fill of an iterator: the stream's walk with a cursor in the iterator's `cursor`, which stops once the buffer
// holds a batch. It judges what the walk leaves and ends the read as `scan_item` does.
answers_fill :: proc(it: ^engine.Answer_Iter) {
	#assert(size_of(Cursor) <= size_of(it.cursor))
	cursor := (^Cursor)(&it.cursor)
	h := &it.scan
	src := it.src
	rules := handle_rules(it.as)
	if it.state == .Fresh {
		if it.read.dups == .Refuse {
			built, e := build_item(src, it.as, true, it.allocator)
			core.destroy(&built)
			if e.kind != .None {
				engine.answers_fail(it, core.error_of(e))
				return
			}
		}
		if !engine.answers_start(it, false, min(core.reserve_depth(rules.max_depth, len(src)), core.MAX_DEPTH)) {
			return
		}
		cursor^ = {src = raw_data(src), n = u64(len(src))}
		it.release = answers_release
		it.regs = engine.BUILDER_REGS
		h.rewalk = rewalk(engine.scan_hook_stream)
		h.pause_on_flush = true
	}
	h.opts = &rules
	hi, fault, stopped := walk_stopped(src, 0, rules, h, &it.regs, engine.scan_hook_stream, cursor)
	h.opts = nil
	if stopped && !h.stopped {
		return
	}
	if fault == nil && !h.stopped {
		fault = tail_fault(src, hi)
	}
	engine.answers_end(it, hi, fault)
}

// The iterator's `release`: frees what its walk's cursor holds.
answers_release :: proc(it: ^engine.Answer_Iter) {
	cursor_destroy((^Cursor)(&it.cursor))
}

// The scan's `rewalk` with the hook `on`: a walk from `lo` of the item the scan reads.
rewalk :: proc "contextless" ($on: proc "contextless" (h: ^engine.Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> proc "contextless" (h: ^engine.Scan, s: ^core.Hook_Regs, lo: u64, at: core.Node_Index) {
	return proc "contextless" (h: ^engine.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
		walk_rules(h.b.doc.src, lo, (^Walk_Rules)(h.opts)^, h, s, on)
	}
}

// The byte just past node `i`. A container ends where a walk of its item ends, since the nodes keep no end.
@(cold)
close_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	n := doc.nodes[i]
	if i == core.ROOT && doc.root_close != 0 {
		return doc.root_close
	}
	if n.kind <= .Plain {
		_, hi := core.scalar_ends(n)
		return hi
	}
	h: core.No_Hooks
	regs: core.Hook_Regs
	hi, _ := walk(doc.src, n.lo, .Cbor, {max_depth = doc.as.max_depth, tolerate = {.Invalid_Utf8}}, &h, &regs, core.no_hook)
	return hi
}

decode :: proc "contextless" (src: []u8, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	if t.kind > .Plain || t.kind == .Number {
		return "", false
	}
	span := src[t.lo:t.lo + u64(t.n)]
	if t.spelling & INT_KEY != 0 {
		// `core.text_room` sizes the buffer from the key's span, which holds its digits but may be under 21 bytes.
		digits: [24]u8
		spelled, _ := integer_text(span, digits[:])
		if len(spelled) > len(buf) {
			return "", false
		}
		return string(buf[:copy(buf, spelled)]), true
	}
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(span), true
	}
	lax := t.kind == .String && t.spelling & core.SPELLING_LAX != 0
	it := chunks_run(span) if t.spelling & STR_INDEF != 0 else Chunks{src = span}
	w := 0
	for chunk in chunk_next(&it) {
		if !lax {
			if w + len(chunk) > len(buf) {
				return "", false
			}
			w += copy(buf[w:], chunk)
			continue
		}
		p := raw_data(chunk)
		end := p[len(chunk):]
		for q := p; q < end; {
			if q[0] < 0x80 {
				if w == len(buf) {
					return "", false
				}
				buf[w] = q[0]
				w += 1
				q = q[1:]
				continue
			}
			spelled, size, next := spell.utf8_lax_char(q, end)
			if w + size > len(buf) {
				return "", false
			}
			copy(buf[w:], spelled[:size])
			w += size
			q = next
		}
	}
	return string(buf[:w]), true
}

// Whether the decoded text of key `t` is `name`. A key longer than the stack buffer decodes on the heap.
spelling_key_equals :: proc "contextless" (v: ^core.Token_View, t: core.Token, name: string) -> bool {
	stack: [256]u8
	buf := stack[:]
	heap: []u8
	room := 3 * int(t.n) + 4
	if room > len(stack) {
		context = runtime.default_context()
		heap = make([]u8, room)
		if heap == nil {
			return false
		}
		buf = heap
	}
	s, ok := decode(v.src, t, buf)
	equal := ok && s == name
	if heap != nil {
		context = runtime.default_context()
		delete(heap)
	}
	return equal
}
