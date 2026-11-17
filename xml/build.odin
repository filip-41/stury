package xml

import "base:runtime"
import core "../core"
import engine "../core/build"

// Reads `src`, an XML text, into a document, allocating its nodes with `allocator`. The document is an `Object` of one
// member, the root element, and `.Refuse` fails at a name an element repeats among its children. The document borrows
// `src`, which must outlive it, and `core.destroy` frees the document. It links the walk alone, and `core.build` with
// `as(spec, opts)` links every pass.
build :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Last, allocator := context.allocator) -> (core.Document, core.Error) {
	doc, err := build_spec(src, S, bound_as(S, opts), dups == .Refuse, allocator)
	return doc, core.error_of(err)
}

// What a build's walk writes through: the builder, and whether the text declares a namespace, in which case a key is
// compared through `key_is`, which resolves an expanded name.
@(private)
Reading :: struct {
	build:      engine.Builder,
	namespaced: bool,
}

@(private)
reading_hook :: proc "contextless" (r: ^Reading, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	if t.role == .Attribute && declares_ns(raw_data(r.build.doc.src[t.lo:]), name_length(r.build.doc.src, t.lo)) {
		r.namespaced = true
	}
	return engine.builder_hook_growing(&r.build, s, t)
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

// The build of a handle's spec, as `Services.build` takes it.
@(private)
build_handle :: proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	return build_spec(src, Spec(as.spec), as, refuse_duplicates, allocator)
}

// Reads `src` as `spec` into a document that holds the handle `handle`. The nodes are reserved at JSON's bound and the
// hook grows past it, since a text of short elements, or a reference to an entity, makes more nodes than half its bytes.
@(private)
build_spec :: proc(src: []u8, spec: Spec, handle: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	opts := options_of(handle)
	depth := min(core.reserve_depth(opts.max_depth, len(src)), core.MAX_DEPTH)
	frames: [core.MAX_DEPTH]u64 = ---
	r := Reading {
		build = engine.builder_start(src, handle, refuse_duplicates, allocator, (len(src) + depth) / 2 + 16, depth, 0, frames[:]),
	}
	if len(r.build.doc.nodes) == 0 {
		return engine.builder_end(&r.build, engine.BUILDER_REGS, nil)
	}
	regs := engine.BUILDER_REGS
	root_close, fault, state := walk_keeping(src, 0, opts, &r, &regs, reading_hook)
	r.build.root_close = root_close
	doc, err := engine.builder_end(&r.build, regs, fault)
	if !keep_state(&doc, state, err.kind == .None, allocator) {
		core.destroy(&doc)
		return {}, {kind = .No_Memory}
	}
	if err.kind == .None && r.namespaced {
		for &n in doc.nodes {
			if n.role == .Key {
				n.spelling |= core.SPELLING_DECODE
			}
		}
	}
	return doc, err
}
