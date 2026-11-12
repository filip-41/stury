package html

import "base:runtime"
import core "../core"
import engine "../core/build"

// Reads `src`, an HTML text, into a document, allocating its nodes with `allocator`: the tree the standard's algorithm
// builds, in the shape an XML text with the same markup builds, see emit.odin. A build recovers from every parse error,
// as the standard does, and fails only for the faults `validate` names past them. `.Refuse` fails at a name an element
// repeats among its children. The document borrows `src`, which must outlive it, and `core.destroy` frees the document.
// A constant `spec` links the reads of that spec alone, and a `spec` chosen at run time is `core.build` with
// `as(spec, opts)`. The same holds for the other entry points.
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

// The build of spec `S`, as `Services.build` takes it.
@(private)
build_of :: proc "contextless" ($S: Spec) -> proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	return proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
		return build_spec(src, S, as, refuse_duplicates, allocator)
	}
}

// Reads `src` as spec `S` into a document that holds the handle `handle`: the tree is built on the default heap, its
// tokens are given once to size the document and again to write it, and the tree is freed.
@(private)
build_spec :: proc(src: []u8, $S: Spec, handle: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	t, fault := build_tree(src, S, options_of(handle), 0, runtime.default_allocator())
	if f, bad := fault.?; bad {
		return {}, document_error(f)
	}
	defer tree_destroy(&t)
	c: engine.Count
	counter := Emitter(engine.Count){t = &t, h = &c, spec = S}
	defer delete(counter.run)
	emit_tree(&counter, engine.builder_hook_count)
	if f, bad := counter.fault.?; bad {
		return {}, document_error(f)
	}
	b := engine.builder_start(src, handle, refuse_duplicates, allocator, c.nodes, c.deepest, c.facts)
	kept: Kept
	defer kept_destroy(&kept)
	writer := Emitter(engine.Builder){t = &t, h = &b, regs = engine.BUILDER_REGS, spec = S, keep = &kept}
	defer delete(writer.run)
	if b.err.kind == .None {
		emit_tree(&writer, engine.builder_hook)
	}
	b.root_close = u64(len(src))
	doc, err := engine.builder_end(&b, writer.regs, writer.fault)
	if err.kind == .None && !keep_state(&doc, &kept, allocator) {
		core.destroy(&doc)
		return {}, {kind = .No_Memory}
	}
	return doc, err
}

// The document error of fault `f`.
@(private)
document_error :: proc "contextless" (f: core.Fault) -> core.Document_Error {
	if f.kind == .No_Memory {
		return {kind = .No_Memory}
	}
	return {kind = .Walk, at = f.at, inner = f}
}

// Checks that `src` is an HTML text of `spec` with no parse error: returns the first the standard's algorithm finds,
// in the order it finds them, or a fault a build would return, or nil. A parse error of the input stream or the
// tokenizer is `Truncated` for one the standard names after the end of the text, and `Bad_Char` at its byte for any
// other, and one of the tree construction is `Bad_Char` at the token it reads.
validate :: proc {validate_bound, validate_chosen}

@(private)
validate_bound :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> core.Error {
	return core.error_of(validate_spec(src, S, read_of(opts)))
}

@(private)
validate_chosen :: #force_inline proc "contextless" (src: []u8, spec: Spec, opts := Options{}) -> core.Error {
	return core.validate(src, as(spec, opts))
}

// The verdict on `src` for spec `S`: the tree is built on the default heap and freed.
@(private)
validate_spec :: proc "contextless" (src: []u8, $S: Spec, opts: Read) -> Maybe(core.Fault) {
	context = runtime.default_context()
	t, fault := build_tree(src, S, opts, 0)
	if fault != nil {
		return fault
	}
	defer tree_destroy(&t)
	if len(t.errors) == 0 {
		return nil
	}
	first := t.errors[0]
	kind := core.Fault_Kind.Bad_Char
	#partial switch first.detail {
	case .Eof_Before_Tag_Name, .Eof_In_Cdata, .Eof_In_Comment, .Eof_In_Doctype, .Eof_In_Processing_Instruction, .Eof_In_Script_Html_Comment_Like_Text, .Eof_In_Tag:
		kind = .Truncated
	}
	return core.Fault{at = first.at, rules = &RULES, kind = kind, detail = u8(first.detail)}
}

// Reads `src` from byte `lo` as one text of spec `S`, building its tree and giving its tokens to the hook in preorder,
// as a build reads them (emit.odin). `lo` past 0 reads from there with no encoding sniffed. A hook that stops the
// walk ends it with no fault. Returns one past the span of the token the hook stopped on, or the text's length, and
// the fault, nil for every text but those a build refuses. `regs` is passed to the first token and holds what the hook
// returned last, and a nil `regs` starts from zero registers and keeps none. The tree lives on the default heap
// while the hook reads. With a `cursor`, a stop leaves the tokens past it in the cursor, which `walk_resume` gives.
walk :: proc(src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor = nil) -> (hi: u64, fault: Maybe(core.Fault)) {
	if cursor == nil {
		return walk_tree(src, lo, S, opts, h, regs, on)
	}
	holding :: proc "contextless" (s: ^core.Holding(H), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
		return core.holding_hook(s, regs, t, on)
	}
	zero: core.Hook_Regs
	r := regs if regs != nil else &zero
	s := core.Holding(H) {
		hooks = h,
	}
	hi, fault = walk_tree(src, lo, S, opts, &s, r, holding)
	return core.holding_end(src, cursor, &s, r, hi, fault, &RULES)
}

// A walk's cursor, `core.Token_Cursor`, as XML's is: at its first stop the walk reads on to the text's end and holds the
// tokens past the stop.
Cursor :: core.Token_Cursor

// Whether `cursor` holds a stop that `walk_resume` continues, false once the walk it fills ended.
can_resume :: #force_inline proc "contextless" (cursor: ^Cursor) -> bool {
	return cursor.held != nil
}

// Continues the walk `cursor` holds a stop of, over the same `src`, from the token after the one it stopped on, with
// the results of `walk`. `regs` is passed to the first token in place of the registers the stop saved, unless it is
// nil. A cursor that holds no stop, or that a walk of another text filled, is refused with `.Bad_Option`.
walk_resume :: proc "contextless" (src: []u8, cursor: ^Cursor, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	return core.cursor_resume(src, cursor, h, regs, on, &RULES)
}

// Frees what `cursor` holds, a stop no resume ended.
cursor_destroy :: core.cursor_free

@(private)
walk_tree :: proc(src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	t: Html_Tree
	t, fault = build_tree(src, S, read_of(opts), lo, runtime.default_allocator())
	if fault != nil {
		return
	}
	defer tree_destroy(&t)
	e := Emitter(H){t = &t, h = h, spec = S}
	defer delete(e.run)
	if regs != nil {
		e.regs = regs^
	}
	emit_tree(&e, on)
	if regs != nil {
		regs^ = e.regs
	}
	if e.stopped {
		return e.hi, e.fault
	}
	return u64(len(src)), nil
}
