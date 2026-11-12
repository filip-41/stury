// `engine` and `typed` are used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
package yaml

import "base:runtime"
import core "../core"
import engine "../core/build"
import typed "../core/typed"
import cw "../core/write"

// The handle of a YAML text of `spec` read with `opts`.
as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return as_of(&HANDLES[spec] if spec <= max(Spec) else nil, spec, opts)
}

// YAML's one duplicate policy is `.Refuse`, which the walk applies to every read: a repeated key is a fault of the
// text. The fault of a read asked for another policy, nil for `.Default` and `.Refuse`.
@(private)
policy_fault :: proc "contextless" (dups: core.Duplicates) -> Maybe(core.Fault) {
	if dups == .Default || dups == .Refuse {
		return nil
	}
	return core.Fault{rules = &RULES, kind = .Bad_Option}
}

// Builds the document of `src`, a YAML text of one document, with `allocator`. A repeated key is a fault, since
// `.Refuse` is YAML's only duplicate policy. A constant `spec` links the passes a build needs alone, and a `spec` chosen
// at run time is `core.build` with `as(spec, opts)`. The same holds for the other entry points below, and the forms that
// take a `Document` give it the services of the spec.
build :: proc {build_bound, build_chosen}

@(private)
build_bound :: proc(src: []u8, $S: Spec, opts := Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	doc, err := build_as(src, bound_as(S, opts), true, allocator)
	return doc, core.error_of(err)
}

@(private)
build_chosen :: #force_inline proc(src: []u8, spec: Spec, opts := Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return core.build(src, as(spec, opts), .Refuse, allocator)
}

// The path reads of `core/build`. `scan`, `each_answer`, `find` and `set` take `spec` and `opts`. A read walks the text
// once, skipping what no path needs, and builds the document only when it reaches an alias. `read.dups` is `.Default`
// or `.Refuse`, and any other policy is `.Bad_Option`.
scan :: proc {scan_bound_one, scan_bound_many, scan_chosen_one, scan_chosen_many}

@(private)
scan_bound_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return scan_bound_many(src, S, []core.Path{path}, opts, read, allocator)
}

@(private)
scan_bound_many :: proc(src: []u8, $S: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	doc, err := scan_as(src, bound_as(S, opts), paths, read, nil, nil, allocator)
	return doc, core.error_of(err)
}

@(private)
scan_chosen_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	return scan_chosen_many(src, spec, []core.Path{path}, opts, read, allocator)
}

@(private)
scan_chosen_many :: proc(src: []u8, spec: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (core.Document, core.Error) {
	if core.services_of(as(spec, opts)) == nil {
		return {}, core.error_of(core.Path_Error{kind = .Unsupported})
	}
	doc, err := core.services_of(as(spec, opts)).scan(src, as(spec, opts), paths, read, nil, nil, allocator)
	return doc, core.error_of(err)
}

each_answer :: proc {each_answer_bound_one, each_answer_bound_many, each_answer_chosen_one, each_answer_chosen_many}

@(private)
each_answer_bound_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return each_answer_bound_many(src, S, []core.Path{path}, state, on, opts, read, allocator)
}

@(private)
each_answer_bound_many :: proc(src: []u8, $S: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	doc, err := scan_as(src, bound_as(S, opts), paths, read, state, on, allocator)
	core.destroy(&doc)
	return core.error_of(err)
}

@(private)
each_answer_chosen_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	return each_answer_chosen_many(src, spec, []core.Path{path}, state, on, opts, read, allocator)
}

@(private)
each_answer_chosen_many :: proc(src: []u8, spec: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Error {
	if core.services_of(as(spec, opts)) == nil {
		return core.error_of(core.Path_Error{kind = .Unsupported})
	}
	doc, err := core.services_of(as(spec, opts)).scan(src, as(spec, opts), paths, read, state, on, allocator)
	core.destroy(&doc)
	return core.error_of(err)
}

// The answers `each_answer` gives, as an iterator that `next` takes them from: `for a in yaml.next(&it)`. A loop that
// ends before `next` returns false frees the read with `destroy(&it)`. `paths` is read at the first `next`.
answers :: proc {answers_bound_one, answers_bound_many, answers_chosen_one, answers_chosen_many}

@(private)
answers_bound_one :: #force_inline proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, bound_as(S, opts), nil, path, read, allocator)
}

@(private)
answers_bound_many :: #force_inline proc(src: []u8, $S: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, bound_as(S, opts), paths, {}, read, allocator)
}

@(private)
answers_chosen_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, as(spec, opts), nil, path, read, allocator)
}

@(private)
answers_chosen_many :: #force_inline proc(src: []u8, spec: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> engine.Answer_Iter {
	return answers_of(src, as(spec, opts), paths, {}, read, allocator)
}

find :: proc {find_bound, find_chosen}

@(private)
find_bound :: proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error) {
	one := path
	one.limit = min(path.limit.? or_else 1, 1)
	doc, err = scan_bound_one(src, S, one, opts, read, allocator)
	answer = doc.answers[0] if len(doc.answers) > 0 else {core.NO_NODE, core.NO_NODE, 0, .Missing}
	return
}

@(private)
find_chosen :: proc(src: []u8, spec: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: core.Answer, err: core.Error) {
	one := path
	one.limit = min(path.limit.? or_else 1, 1)
	doc, err = scan_chosen_one(src, spec, one, opts, read, allocator)
	answer = doc.answers[0] if len(doc.answers) > 0 else {core.NO_NODE, core.NO_NODE, 0, .Missing}
	return
}

// Makes `v` the value at every answer of `path` over `src`, a text of one document, in one call, and returns the new
// text, which the caller frees with `allocator`, keeping every byte the edit does not reach. A `typed.Raw` is the text
// of a value, a struct, a slice or a map is built by `plan`, and any other value is spelled by the format. A `Name` the
// path ends in that its container lacks is inserted after the container's last member. `read.dups` is `.Default` or
// `.Refuse`, and any other policy is `.Bad_Option`.
set :: proc {set_bound, set_chosen}

@(private)
set_bound :: proc(src: []u8, $S: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	core.error_of(policy_fault(read.dups)) or_return
	scratch: cw.Scratch
	defer cw.scratch_destroy(&scratch)
	in_ := cw.edit_input(v, plan, &scratch) or_return
	doc, berr := build_bound(src, S, opts, allocator)
	defer core.destroy(&doc)
	if berr != nil {
		return nil, berr
	}
	list := edit_list_init_bound(&doc, S, allocator)
	defer core.edit_list_destroy(&list)
	return engine.set_answers(&list, path, in_, {}, allocator)
}

@(private)
set_chosen :: proc(src: []u8, spec: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	core.error_of(policy_fault(read.dups)) or_return
	scratch: cw.Scratch
	defer cw.scratch_destroy(&scratch)
	in_ := cw.edit_input(v, plan, &scratch) or_return
	return engine.set(src, as(spec, opts), path, in_, {}, allocator)
}

// Answers `path` or `paths` over a document built whole, as `core.query` does. A document read as a constant spec holds
// no services, so `core.query` does not answer for it. `read.dups` is `.Default` or `.Refuse`.
query :: proc {query_one, query_many}

@(private)
query_one :: proc(doc: ^core.Document, path: core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Error) {
	return query_many(doc, []core.Path{path}, read, allocator)
}

@(private)
query_many :: proc(doc: ^core.Document, paths: []core.Path, read := core.Query_Options{}, allocator := context.allocator) -> (answers: []core.Answer, err: core.Error) {
	if doc == nil || doc.readers == nil {
		return nil, core.error_of(core.Path_Error{kind = .Unsupported})
	}
	core.error_of(policy_fault(read.dups)) or_return
	found, refusal := engine.query(doc, paths, {}, allocator)
	return found, core.error_of(refusal)
}

// Returns an edit list over `doc`. A document read as a constant spec holds no edit services, so the list takes the
// spec's.
edit_list_init :: proc {edit_list_init_bound, edit_list_init_chosen}

@(private)
edit_list_init_bound :: proc(doc: ^core.Document, $S: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = edit_of(S)
	return list
}

@(private)
edit_list_init_chosen :: proc(doc: ^core.Document, spec: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = core.services_of(as(spec)).edit
	return list
}

// Writes node `node` of `doc` as YAML, as `core.write` does with `as(spec)`.
write :: proc {write_bound, write_chosen}

@(private)
write_bound :: proc(doc: ^core.Document, $S: Spec, opts := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	if int(node) >= len(doc.nodes) || doc.nodes[node].role == .Key {
		return nil, 0, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	out, cut, refusal := document_write(doc, opts, bound_as(S), node, {}, allocator)
	return out, cut, core.error_of(refusal)
}

@(private)
write_chosen :: #force_inline proc(doc: ^core.Document, spec: Spec, opts := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	return core.write(doc, opts, as(spec), node, allocator)
}

// The handle's build: the first document of the text, whose scalars are `Plain` nodes that `resolve` types. A second
// document is `Extra_Document`, and a text with no document is `No_Document`. The walk refuses a repeated key under
// every policy, so the builder tests none.
build_as :: proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	opts := options_of(as)
	// An alias reads its node's tokens again and an empty node takes no byte, so no bound on the text's length covers
	// the nodes or the depth. The reservation is JSON's bound, and the hook grows past it.
	depth := min(core.reserve_depth(opts.max_depth, len(src)), core.MAX_DEPTH)
	frames: [core.MAX_DEPTH]u64 = ---
	b := engine.builder_start(src, as, false, allocator, (len(src) + depth) / 2 + 16, depth, 0, frames[:])
	if len(b.doc.nodes) > 0 {
		regs := engine.BUILDER_REGS
		f := Filter{build = &b, src = src}
		hi, fault := walk(src, 0, .Yaml_1_2, opts, &f, &regs, filter_hook)
		if b.err.kind == .None {
			fault = document_fault(src, hi, opts, &f, fault, regs.a)
		}
		doc, err := engine.builder_end(&b, regs, fault)
		if err.kind != .No_Memory {
			return doc, err
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
		if f.kind == .No_Memory {
			return {}, {kind = .No_Memory}
		}
		return {}, {kind = .Walk, at = f.at, inner = f}
	}
	b = engine.builder_start(src, as, false, allocator, count.nodes, count.deepest, count.facts)
	if len(b.doc.nodes) == 0 {
		return engine.builder_end(&b, engine.BUILDER_REGS, nil)
	}
	regs := engine.BUILDER_REGS
	bf := Filter{build = &b, src = src}
	_, fault = walk(src, 0, .Yaml_1_2, opts, &bf, &regs, filter_hook)
	return engine.builder_end(&b, regs, fault)
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
	held:  [4]core.Token,
	n:     int,
	// The first byte of a key that is a collection, which the filter stops at.
	complex: u64,
	found:   bool,
	aliased: bool,
}

@(private)
filter_hook :: proc "contextless" (f: ^Filter, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
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
				ct := doc_core_type(f.src, string(f.src[held.lo:held.lo + u64(held.n)]))
				t.kind = .String if ct == .None || ct == .Str else .Plain
			}
			regs, _ = forward_action(f, regs, held, READ)
		}
	}
	f.n = 0
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
// after another from the innermost, so the native stack does not grow with the node's depth.
@(private)
close_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	flows := 0
	at: u64
	j := i
	for {
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
		last := j + 1
		for k := last; k < j + core.Node_Index(n.n); {
			last = k
			m := doc.nodes[k]
			k += core.Node_Index(m.n) if m.kind == .Array || m.kind == .Object else 1
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
