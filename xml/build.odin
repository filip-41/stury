package xml

import "base:runtime"
import core "../core"
import engine "../core/build"

// Reads `src`, an XML text, into a document, allocating its nodes with `allocator`. The document is an `Object` of one
// member, the root element, and `.Refuse` fails at a name an element repeats among its children. The document borrows
// `src`, which must outlive it, and `core.destroy` frees the document. A constant `spec` links the walk of that spec
// alone, and a `spec` chosen at run time is `core.build` with `as(spec, opts)`.
build :: proc {build_bound, build_chosen}

@(private)
build_bound :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error) {
	doc, err := build_spec(src, S, bound_as(S, opts), dups == .Refuse, allocator)
	return doc, core.error_of(err)
}

@(private)
build_chosen :: #force_inline proc(src: []u8, spec: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error) {
	return core.build(src, as(spec, opts), dups, allocator)
}

// What the first walk of a build counts, and whether the text declares a namespace, in which case a key is compared
// through `key_is`, which resolves an expanded name.
@(private)
Counter :: struct {
	count:      engine.Count,
	src:        []u8,
	namespaced: bool,
}

@(private)
count_hook :: proc "contextless" (c: ^Counter, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if t.role == .Attribute && declares_ns(raw_data(c.src[t.lo:]), name_length(c.src, t.lo)) {
		c.namespaced = true
	}
	return engine.builder_hook_count(&c.count, s, t)
}

// Moves the sealed DTD `state` from the default heap into `doc`'s allocator when `keep`, or frees it. Returns false when
// memory runs out.
@(private)
keep_state :: proc(doc: ^core.Document, state: []u8, keep: bool, allocator: runtime.Allocator) -> bool {
	if len(state) == 0 {
		return true
	}
	defer runtime.heap_free(raw_data(state))
	if !keep {
		return true
	}
	// The block's tables hold words of up to 8 bytes.
	kept, err := runtime.mem_alloc_bytes(len(state), 16, allocator)
	if err != nil {
		return false
	}
	copy(kept, state)
	doc.state = kept
	return true
}

// Reads `src` as spec `S` into a document that holds the handle `handle`: the text is walked to size the document and
// walked again to write it.
@(private)
build_spec :: proc(src: []u8, $S: Spec, handle: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	opts := options_of(handle)
	c := Counter {
		src = src,
	}
	counted: core.Hook_Regs
	_, fault := walk(src, 0, S, opts, &c, &counted, count_hook)
	if f, bad := fault.?; bad {
		if f.kind == .No_Memory {
			return {}, {kind = .No_Memory}
		}
		return {}, {kind = .Walk, at = f.at, inner = f}
	}
	b := engine.builder_start(src, handle, refuse_duplicates, allocator, c.count.nodes, c.count.deepest, c.count.facts)
	if len(b.doc.nodes) == 0 {
		return engine.builder_end(&b, engine.BUILDER_REGS, nil)
	}
	regs := engine.BUILDER_REGS
	state: []u8
	b.root_close, fault, state = walk_keeping(src, opts, &b, &regs, engine.builder_hook)
	doc, err := engine.builder_end(&b, regs, fault)
	if !keep_state(&doc, state, err.kind == .None, allocator) {
		core.destroy(&doc)
		return {}, {kind = .No_Memory}
	}
	if err.kind == .None && c.namespaced {
		for &n in doc.nodes {
			if n.role == .Key {
				n.spelling |= core.SPELLING_DECODE
			}
		}
	}
	return doc, err
}
