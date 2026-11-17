// `engine` and `typed` are used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
package yaml

import "base:runtime"
import "core:io"
import kernel "../core/kernel"
import core "../core"
import compose "../core/compose"
import engine "../core/build"
import typed "../core/typed"
import cw "../core/write"

// A YAML text holds a stream of documents: a whole build refuses a second document, and a text with none.
CAPABILITIES :: core.Capabilities {
	writes = {.Pretty, .Indent, .Ascii, .Sort_Keys, .Respell_Strings},
	framings = {.Concatenated, .Entries},
	specs = Spec,
	follows = proc "contextless" (f: core.Fault) -> bool {return f.rules == &RULES && (f.detail == u8(Detail.Extra_Document) || f.detail == u8(Detail.No_Document))},
}

// The handle of a YAML text of `spec` read with `opts`.
as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return as_of(&HANDLES[spec] if spec <= max(Spec) else nil, spec, opts)
}

// Builds the document of `src`, a YAML text of one document, with `allocator`. `dups` is as for JSON, and `.Refuse`
// fails at a repeated key. It links the passes a build needs alone, and `core.build` with `as(spec, opts)` links every
// pass. The same holds for the other entry points below, and the forms that take a `Document` give it the services of
// the spec.
build :: proc(src: []u8, $S: Spec, opts := Options{}, dups := core.Duplicates.Default, allocator := context.allocator) -> (core.Document, core.Error) {
	doc, err := build_as(src, bound_as(S, opts), dups == .Refuse, allocator)
	return doc, core.error_of(err)
}

// The path reads of `core/build`. `scan`, `each_answer`, `find` and `set` take `spec` and `opts`. A read walks the text
// once, skipping what no path needs, and builds the document only when it reaches an alias. `read.dups` picks among a
// repeated key, and `.Refuse` builds the whole text.
scan :: proc {scan_one, scan_many}

@(private)
scan_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return scan_many(src, S, []core.Path{path}, opts, read, allocator)
}

@(private)
scan_many :: proc(src: []u8, $S: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return engine.scan_with(src, bound_as(S, opts), paths, read, allocator, build_as, scan_as)
}

each_answer :: proc {each_answer_one, each_answer_many}

@(private)
each_answer_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return each_answer_many(src, S, []core.Path{path}, state, on, opts, read, allocator)
}

@(private)
each_answer_many :: proc(src: []u8, $S: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return engine.each_answer_with(src, bound_as(S, opts), paths, state, on, read, allocator, build_as, scan_as)
}

// The answers `each_answer` gives, as an iterator that `next` takes them from: `for a in yaml.next(&it)`. A loop that
// ends before `next` returns false frees the read with `destroy(&it)`. `paths` is read at the first `next`.
answers :: proc {answers_one, answers_many}

@(private)
answers_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return engine.answers_of(src, bound_as(S, opts), nil, path, read, allocator, answers_fill)
}

@(private)
answers_many :: #force_inline proc(src: []u8, $S: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return engine.answers_of(src, bound_as(S, opts), paths, {}, read, allocator, answers_fill)
}

find :: proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error) {
	doc, err = scan_one(src, S, engine.first_path(path), opts, read, allocator)
	return doc, engine.first_answer(&doc), err
}

// Makes `v` the value at every answer of `path` over `src`, a text of one document, in one call, and returns the new
// text, which the caller frees with `allocator`, keeping every byte the edit does not reach. A `typed.Raw` is the text
// of a value, a struct, a slice or a map is built by `plan`, and any other value is spelled by the format. A `Name` the
// path ends in that its container lacks is inserted after the container's last member. `read.dups` picks among a
// repeated key as `query` does, and sets each repeat under `.All`.
set :: proc(src: []u8, $S: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	return cw.set_with(src, bound_as(S, opts), build_as, &EDIT, path, v, plan, read, allocator)
}

// Returns an edit list over `doc`. A document an entry point reads holds no edit services, so the list takes the
// spec's.
edit_list_init :: proc(doc: ^core.Document, $S: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = &EDIT
	return list
}

// Returns the source bytes `list`'s edits make, as `compose.commit` does, in the document's own spec or in `spec`. A
// program that names a spec links every spec's passes.
commit :: proc {commit_own, commit_as}

@(private)
commit_own :: proc(list: ^core.Edit_List, allocator := context.allocator) -> (out: []u8, dropped: int, err: core.Error) {
	return compose.commit(list, nil, allocator)
}

@(private)
commit_as :: proc(list: ^core.Edit_List, spec: Spec, allocator := context.allocator) -> (out: []u8, dropped: int, err: core.Error) {
	return compose.commit(list, as(spec), allocator)
}

// Writes node `node` of `doc` as YAML, as `core.write` does with `as(spec)`.
write :: proc(doc: ^core.Document, $S: Spec, write := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	return core.write(doc, write, as(S), node, allocator)
}

// Reads `src` as spec `S` and writes it back as `write` says, as `core.format` does with `as(spec, opts)`.
format :: proc(src: []u8, $S: Spec, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	return core.format(src, as(S, opts), write, allocator)
}

// Writes node `node` of `doc` as spec `S` to `w`, as `core.write_stream` does with `as(spec)`.
write_stream :: proc(w: io.Stream, doc: ^core.Document, $S: Spec, write := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (dropped: int, err: core.Error) {
	return core.write_stream(w, doc, write, as(S), node, allocator)
}

// The handle's build: the first document of the text, whose scalars are `Plain` nodes that `resolve` types. A second
// document is `Extra_Document`, and a text with no document is `No_Document`. A key that repeats one of its mapping's,
// of the same type and value, is `.Duplicate_Key` under `refuse_duplicates`, and two keys of one text and two types
// are two members, the second marked in `Document.clash`.
@(private)
build_as :: proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	doc, err, typed := build_once(src, as, refuse_duplicates, allocator)
	if typed && err.kind == .Duplicate_Key {
		// The builder judges a repeat by its text, which does not settle a key that resolves to no string.
		doc, err, _ = build_once(src, as, false, allocator)
	}
	if typed && err.kind == .None {
		err = judge_keys(&doc, refuse_duplicates)
	}
	return doc, err
}

// `build_as`, with a repeat judged by the builder, which also says whether a key of the text resolves to no string.
@(private)
build_once :: proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Document_Error, typed: bool) {
	opts := options_of(as)
	// An alias reads its node's tokens again and an empty node takes no byte, so no bound on the text's length covers
	// the nodes or the depth. The reservation is JSON's bound, and the hook grows past it.
	depth := min(core.reserve_depth(opts.max_depth, len(src)), core.MAX_DEPTH)
	frames: [core.MAX_DEPTH]u64 = ---
	b := engine.builder_start(src, as, refuse_duplicates, allocator, (len(src) + depth) / 2 + 16, depth, 0, frames[:])
	if len(b.doc.nodes) > 0 {
		regs := engine.BUILDER_REGS
		f := Filter{build = &b, src = src}
		replayed: bool
		hi, fault := walk_noting(src, 0, opts, &f, &regs, filter_hook, nil, &typed, &replayed)
		if b.err.kind == .None {
			fault = document_fault(src, hi, opts, &f, fault, regs.a)
		}
		doc, err = engine.builder_end(&b, regs, fault)
		doc.in_order = !replayed && !opts.merge_keys
		if err.kind != .No_Memory {
			return
		}
	} else {
		engine.builder_end(&b, engine.BUILDER_REGS, nil)
	}
	// The allocator refused the estimate or a growth. A count of the text sizes every buffer exactly, so only a
	// document that does not fit the allocator fails.
	count: engine.Count
	counted: core.Hook_Regs
	cf := Filter{count = &count}
	hi, fault := walk(src, 0, .Yaml_1_2, opts, &cf, &counted, filter_hook)
	fault = document_fault(src, hi, opts, &cf, fault, u64(count.nodes))
	if f, bad := fault.?; bad {
		return {}, core.fault_error(f), false
	}
	b = engine.builder_start(src, as, refuse_duplicates, allocator, count.nodes, count.deepest, count.facts)
	if len(b.doc.nodes) == 0 {
		doc, err = engine.builder_end(&b, engine.BUILDER_REGS, nil)
		return
	}
	regs := engine.BUILDER_REGS
	bf := Filter{build = &b, src = src}
	replayed: bool
	_, fault = walk_noting(src, 0, opts, &bf, &regs, filter_hook, nil, &typed, &replayed)
	doc, err = engine.builder_end(&b, regs, fault)
	doc.in_order = !replayed && !opts.merge_keys
	return
}

// Judges the keys of `doc`, a key of whose text resolves to no string: under `refuse` a repeat is `.Duplicate_Key` at
// its byte, and the first clash is marked in `Document.clash`.
@(private)
judge_keys :: proc(doc: ^core.Document, refuse: bool) -> core.Document_Error {
	k: Key_Table
	defer keys_destroy(&k)
	ends := make([dynamic]int)
	defer delete(ends)
	for n, i in doc.nodes {
		for len(ends) > 0 && i == ends[len(ends) - 1] {
			pop(&ends)
			keys_close(&k)
		}
		if n.kind == .Array || n.kind == .Object {
			keys_open(&k, n.kind == .Object)
			append(&ends, i + int(n.n))
		} else if n.role == .Key {
			judged := key_enter(&k, n, doc.src)
			if refuse && .Repeat in judged {
				core.destroy(doc)
				doc^ = {}
				return {kind = .Duplicate_Key, at = core.node_start(n)}
			}
			if .Clash in judged && doc.clash == 0 {
				doc.clash = core.node_start(n)
			}
		}
	}
	return {}
}

// The fault of a walk over the text's first document that ended at `hi` with `fault` after `nodes` nodes: a key that
// is a collection, the walk's fault, a later document, or no document at all.
@(private)
document_fault :: proc(src: []u8, hi: u64, opts: Options, f: ^Filter, fault: Maybe(core.Fault), nodes: u64) -> Maybe(core.Fault) {
	if f.found {
		return complex_key(f.complex)
	}
	if fault != nil {
		return fault
	}
	if tail := tail_fault(src, hi, opts); tail != nil {
		return tail
	}
	if nodes == 0 {
		at := u64(len(src))
		return core.Fault{at = at, rules = &RULES, kind = .Truncated, detail = u8(Detail.No_Document)}
	}
	return nil
}

@(private)
complex_key :: proc "contextless" (at: u64) -> core.Fault {
	return {at = at, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Complex_Key)}
}

// Holds the properties before a node, since the builder gives the facts before a key to the key's value. A key's own
// properties are dropped, and a value's go on with it. A quoted or block scalar under a core tag other than `!!str`
// is built `Plain`, so `resolve` gives it the tag's type. A read keeps no tags, so there a plain scalar under `!!str`
// or a tag of no core type is a `String`. The tokens go to the count, the builder or the path read
// `scan`, whose stream's hook takes them when `stream` is set. A read stops at an alias it does not skip, since the
// tokens of the node an alias names are not in text order.
@(private)
Filter :: struct {
	count:  ^engine.Count,
	build:  ^engine.Builder,
	scan:   ^engine.Scan,
	stream: bool,
	src:    []u8,
	// The `%TAG` directives the tags resolve by, as `directives_keep` writes them, nil for those at the start of `src`.
	directives: []u8,
	held:  [4]core.Token,
	n:     int,
	// The first byte of a key that is a collection, which the filter stops at.
	complex: u64,
	found:   bool,
	aliased: bool,
}

@(private)
filter_hook :: #force_inline proc "contextless" (f: ^Filter, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return filter_token(f, s, t, false)
}

// The filter of a path read. It is a hook apart from a build's, since a branch to the read's hooks in the build's hook
// costs the build.
@(private)
read_filter_hook :: proc "contextless" (f: ^Filter, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return filter_token(f, s, t, true)
}

@(private)
filter_token :: #force_inline proc "contextless" (f: ^Filter, s: core.Hook_Regs, t: core.Token, $READ: bool) -> (core.Hook_Regs, core.Action) {
	if t.role == .Tag || t.role == .Anchor || t.role == .Alias {
		when READ {
			if t.role == .Alias {
				f.aliased = true
				return s, .Stop
			}
		}
		if f.n < len(f.held) {
			f.held[f.n] = t
			f.n += 1
		}
		return s, .Next
	}
	if t.role == .Key && (t.kind == .Array || t.kind == .Object) {
		f.complex, f.found = t.lo, true
		return s, .Stop
	}
	regs := s
	t := t
	if t.role != .Key {
		for held in f.held[:f.n] {
			if held.role == .Tag && f.count == nil && (t.kind == .String || READ && t.kind == .Plain) {
				ct := doc_core_type(f.directives if f.directives != nil else f.src, string(f.src[held.lo:held.lo + u64(held.n)]))
				t.kind = .String if ct == .None || ct == .Str else .Plain
			}
			regs, _ = forward_action(f, regs, held, READ)
		}
	}
	f.n = 0
	when READ {
		// An iterator's read by name that keeps the last of a repeat answers from a build, which marks a clash.
		if t.role == .Key && f.stream && t.spelling & KEY_TAGS > u16(Key_Tag.Text) << KEY_TAG_SHIFT && f.scan.last {
			f.aliased = true
			return regs, .Stop
		}
	}
	return forward_action(f, regs, t, READ)
}

@(private)
forward_action :: #force_inline proc "contextless" (f: ^Filter, s: core.Hook_Regs, t: core.Token, $READ: bool) -> (core.Hook_Regs, core.Action) {
	when READ {
		if f.stream {
			return engine.scan_hook_stream(f.scan, s, t)
		}
		if f.scan.many != nil {
			return engine.scan_hook_many(f.scan, s, t)
		}
		return engine.scan_hook(f.scan, s, t)
	} else {
		if f.count != nil {
			return engine.builder_hook_count(f.count, s, t)
		}
		return engine.builder_hook_growing(f.build, s, t)
	}
}

// The byte just past node `i`. A block collection has no bytes of its own, so it ends where its last child does. A
// flow collection ends at its bracket, which follows the last descendant, any commas and comments. The descent goes
// down the last children in a loop and counts the flow collections on the way, whose brackets are then read past one
// after another from the innermost, so the native stack does not grow with the node's depth. The children an alias
// replayed hold the bytes of the node it names, and those a merge key adds the bytes of their source, so a flow
// collection that holds such children ends at its bracket found in its text, and a block collection whose last
// children an alias replayed ends past their `*` names, read on from the end of the last child that is none. A
// document built `in_order` holds none of them.
@(private)
close_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	flows := 0
	at: u64
	j := i
	merging, ordered := options_of(doc.as).merge_keys, doc.in_order
	descent: for {
		n := doc.nodes[j]
		if n.kind <= .Plain {
			_, at = core.scalar_ends(n)
			break
		}
		flow := is_flow(doc, n)
		if flow {
			flows += 1
		}
		if n.n <= 1 {
			at = n.lo + 1 if flow else n.lo
			break
		}
		last, authored, aliases := j + 1, core.NO_NODE, 0
		if ordered {
			for k := last; k < j + core.Node_Index(n.n); k += core.Node_Index(core.subtree_size(doc, k)) {
				last = k
			}
			j = last
			continue
		}
		floor := n.lo
		for k := last; k < j + core.Node_Index(n.n); {
			last = k
			if lo := doc.nodes[k].lo; replayed(lo, floor, doc.nodes[k - 1].lo, k - 1 == j) {
				aliases += 1
			} else {
				authored, aliases, floor = k, 0, lo
			}
			k += core.Node_Index(core.subtree_size(doc, k))
		}
		if flow && (aliases > 0 || merging) {
			at = flow_end(doc.src, n.lo)
			flows -= 1
			break descent
		}
		if aliases > 0 {
			at = close_end(doc, authored) if authored != core.NO_NODE else n.lo
			at = past_aliases(doc.src, at, aliases)
			break descent
		}
		j = last
	}
	src := doc.src
	for _ in 0 ..< flows {
		bracket: for at < u64(len(src)) {
			switch src[at] {
			case ' ', '\t', '\r', '\n', ',':
				at += 1
			case '#':
				for at < u64(len(src)) && src[at] != '\n' && src[at] != '\r' {
					at += 1
				}
			case:
				at += 1
				break bracket
			}
		}
	}
	return at
}

// Whether a child starting at `lo` is a node an alias replayed or a merge key added, whose bytes lie before it. An
// authored child starts past the last authored child before it, at `floor`, and past the node just before it, at
// `before`, or at both when that node is its parent.
@(private)
replayed :: #force_inline proc "contextless" (lo, floor, before: u64, first: bool) -> bool {
	return lo < floor || lo < before || !first && (lo == floor || lo == before)
}

// The byte past the `count`th alias name from `from` in a block collection, over the white space, comments, indicators
// and a merge key's `<<` and brackets between them. A merge key's members have no name, so it stops past the last
// name when the next byte that is none of those starts no alias.
@(private)
past_aliases :: proc "contextless" (src: []u8, from: u64, count: int) -> u64 {
	end := from
	for _ in 0 ..< count {
		at := end
		for at < u64(len(src)) {
			switch src[at] {
			case ' ', '\t', '\r', '\n', ',', ':', '?', '-', '<', '[', ']':
				at += 1
				continue
			case '#':
				for at < u64(len(src)) && src[at] != '\n' && src[at] != '\r' {
					at += 1
				}
				continue
			}
			break
		}
		if at >= u64(len(src)) || src[at] != '*' {
			return end
		}
		at += 1
		for at < u64(len(src)) && !(src[at] == ' ' || src[at] == '\t' || src[at] == '\r' || src[at] == '\n' || is_flow_indicator(src[at])) {
			at += 1
		}
		end = at
		for end < u64(len(src)) && (src[end] == ' ' || src[end] == ',') {
			end += 1
		}
		if end < u64(len(src)) && src[end] == ']' {
			end += 1
		} else {
			end = at
		}
	}
	return end
}

// The byte past the bracket that closes the flow collection opening at `lo`, read over its quoted scalars and
// comments.
@(private)
flow_end :: proc "contextless" (src: []u8, lo: u64) -> u64 {
	depth := 0
	at := lo
	for at < u64(len(src)) {
		c := src[at]
		at += 1
		switch c {
		case '[', '{':
			depth += 1
		case ']', '}':
			depth -= 1
			if depth == 0 {
				return at
			}
		case '"', '\'':
			at = u64(quoted_end(string(src), int(at) - 1))
		case '#':
			if kernel.is_ws(src[at - 2]) {
				for at < u64(len(src)) && src[at] != '\n' && src[at] != '\r' {
					at += 1
				}
			}
		}
	}
	return min(at, u64(len(src)))
}
