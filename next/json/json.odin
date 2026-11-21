package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// JSON as RFC 8259, and the specs past it that `Spec` names.

// The grammar a JSON text follows.
Spec :: enum u8 {
	Json, // RFC 8259
	Jsonc, // JSON with comments and trailing commas
	Json5, // JSON5 1.0.0
}

// Options of a JSON read.
Options :: struct {
	budget: tape.Budget, // only `depth` and `nodes` apply to a JSON read
}

@(private, rodata)
RULES := tape.Rules{"json", {}}

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Json  = {name = "json", id = 1, bounds = quotes, decode = text_decoded, number = number_value},
	.Jsonc = {name = "jsonc", id = 2, facts = tape.COMMENTS, bounds = quotes, decode = text_decoded, number = number_value},
	.Json5 = {name = "json5", id = 3, facts = tape.COMMENTS, bounds = quotes, decode = text_decoded, number = number_value},
}

// The format handle of `spec`, to read nodes of a text of `spec` with `tape.node_text` and `tape.node_number`, and to
// pass a document's format to a call that takes one. Nil for a `spec` out of range.
as :: proc "contextless" (spec: Spec) -> ^tape.Format {
	return &FORMATS[spec] if spec <= max(Spec) else nil
}

// The quotes of a string token, one byte on each side, and none around another scalar.
@(private)
quotes :: proc "contextless" (src: []u8, t: tape.Token) -> (head, tail: u8) {
	q := u8(t.kind == .String && t.spelling & tape.SPELLING_QUOTED != 0)
	return q, q
}

// The error in `src`, nil when it is one text of `spec`. An optimized build with a constant `spec` links only that
// spec's walk.
@(require_results)
validate :: #force_inline proc "contextless" (src: []u8, spec := Spec.Json, opts := Options{}) -> tape.Error {
	switch spec {
	case .Json:
		return validate_as(src, .Json, opts)
	case .Jsonc:
		return validate_as(src, .Jsonc, opts)
	case .Json5:
		return validate_as(src, .Json5, opts)
	}
	runtime.panic_contextless("json: spec out of range")
}

// A document of every value in `src` read as `spec`, with keys and duplicates as written and comments as facts. Its
// nodes point into `src`.
@(require_results)
build :: #force_inline proc(src: []u8, spec := Spec.Json, opts := Options{}, allocator := context.allocator) -> (tape.Document, tape.Error) {
	switch spec {
	case .Json:
		return build_as(src, .Json, opts, allocator)
	case .Jsonc:
		return build_as(src, .Jsonc, opts, allocator)
	case .Json5:
		return build_as(src, .Json5, opts, allocator)
	}
	panic("json: spec out of range")
}

// The first value `path` reaches in `src`, a text of `spec`, read with no document, or why none was reached.
// Only a path longer than `build.FIND_ROOM` steps, or whose negative indexes reach further in sum, allocates.
// An optimized build with a constant `spec` links only that spec's walk.
@(require_results)
find :: #force_inline proc(src: []u8, path: []tape.Step, spec := Spec.Json, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Span_Answer, tape.Error) {
	switch spec {
	case .Json:
		return find_as(src, path, .Json, read, opts, allocator)
	case .Jsonc:
		return find_as(src, path, .Jsonc, read, opts, allocator)
	case .Json5:
		return find_as(src, path, .Json5, read, opts, allocator)
	}
	panic("json: spec out of range")
}

// The nodes of `src` that the paths of `demand` reach, read as `spec`, with each path's answers in text order. A
// value a path ends at is kept whole. Containers off the paths are judged and not stored. With `read.stop_early` the
// walk ends once no answer can come or go, and the text past it is not read. Its nodes point into `src`.
@(require_results)
scan :: #force_inline proc(src: []u8, demand: ^tape.Demand, spec := Spec.Json, read := tape.Read_Options{}, opts := Options{}, allocator := context.allocator) -> (tape.Partial_Result, tape.Error) {
	switch spec {
	case .Json:
		return scan_as(src, demand, .Json, read, opts, allocator)
	case .Jsonc:
		return scan_as(src, demand, .Jsonc, read, opts, allocator)
	case .Json5:
		return scan_as(src, demand, .Json5, read, opts, allocator)
	}
	panic("json: spec out of range")
}

@(private)
validate_as :: proc "contextless" (src: []u8, $S: Spec, opts: Options) -> tape.Error {
	h: tape.No_Hooks
	regs: tape.Hook_Regs
	_, err := walk_text(src, S, depth_limit(opts), &h, &regs, tape.no_hook)
	return err
}

@(private)
build_as :: proc(src: []u8, $S: Spec, opts: Options, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	limit := depth_limit(opts)
	depth := min(limit, u64(len(src)))
	most := node_most(node_bound(src, depth), opts)
	frames: [FRAME_DEPTH]u64 = ---
	b := build.builder_start(src, &FORMATS[S], len(src) / BUILD_BYTES_PER_NODE, most, frames[:min(depth, FRAME_DEPTH)], allocator)
	if b.err != nil {
		return {}, b.err
	}
	regs := build.builder_regs(&b)
	on :: build.builder_hook_facts when S != .Json else build.builder_hook
	root_close, err := walk_text(src, S, limit, &b, &regs, on)
	return build.builder_end(&b, regs, root_close, err)
}

// Settles `.Default` duplicates to the format's own policy, the last.
@(private)
json_dups :: proc "contextless" (read: ^tape.Read_Options) {
	if read.dups == .Default {
		read.dups = .Last
	}
}

@(private)
scan_as :: proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, allocator: runtime.Allocator) -> (tape.Partial_Result, tape.Error) {
	read := read
	json_dups(&read)
	limit := depth_limit(opts)
	depth := min(limit, u64(len(src)))
	most := node_most(node_bound(src, depth), opts)
	frames: [FRAME_DEPTH]u64 = ---
	// The value at `lo` walked again, which the first walk judged within the depth limit.
	rewalk :: proc "contextless" (h: ^build.Scanner, regs: ^tape.Hook_Regs, lo: u64) -> tape.Walk_Result {
		src := h.b.doc.src
		return walk_value(src, raw_data(src)[lo:], S, u64(max(u32)), h, regs, build.scanner_hook)
	}
	room: build.Scan_Room = ---
	h, err := build.scanner_start(src, &FORMATS[S], demand, read, key_is, rewalk, SCAN_NODES, most, frames[:min(depth, FRAME_DEPTH)], &room, allocator)
	if err != nil {
		return {}, err
	}
	regs := build.builder_regs(&h.b)
	root_close, werr := walk_text(src, S, limit, &h, &regs, build.scanner_hook)
	return build.scanner_end(&h, regs, root_close, werr)
}

// Open levels a build or scan keeps in its own frame before its builder's stack grows.
@(private)
FRAME_DEPTH :: 1024

// The room a build starts with, a node per this many bytes.
@(private)
BUILD_BYTES_PER_NODE :: 16

// The room a scan starts with, which holds the answers of a few paths with no growth.
@(private)
SCAN_NODES :: 1024

// The most nodes a text of `src` can make, at most `(len(src) + 1 + depth) / 2`. Each node spends two bytes (a
// container its brackets, a key its colon, a scalar the comma or close after it), except a container left open and
// the token before a fault, which may spend one.
@(private)
node_bound :: #force_inline proc "contextless" (src: []u8, depth: u64) -> u64 {
	return (u64(len(src)) + depth) / 2 + 16
}

// The most nodes a read may make, `bound` within `Budget.nodes`, a 32-bit node index and an `int` of bytes.
@(private)
node_most :: #force_inline proc "contextless" (bound: u64, opts: Options) -> int {
	budget := u64(opts.budget.nodes) if opts.budget.nodes != 0 else max(u64)
	return int(min(bound, budget, u64(tape.NO_NODE) - 1, u64(max(int) / size_of(tape.Node))))
}

@(private)
find_as :: proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, allocator: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	read := read
	json_dups(&read)
	// The value at `lo` walked again, which the first walk judged within the depth limit.
	rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> tape.Walk_Result {
		regs: tape.Hook_Regs
		return walk_value(h.src, raw_data(h.src)[lo:], S, u64(max(u32)), h, &regs, build.finder_hook)
	}
	room: build.Find_Room = ---
	f, err := build.finder_start(src, &FORMATS[S], path, read, key_is, respell, rewalk, &room, allocator)
	if err != nil {
		return {}, err
	}
	defer build.finder_end(&f)
	regs: tape.Hook_Regs
	if _, err := walk_text(src, S, depth_limit(opts), &f, &regs, build.finder_hook); err != nil {
		return {}, err
	}
	if f.refused {
		return {}, runtime.Allocator_Error.Out_Of_Memory
	}
	return build.finder_answer(&f), nil
}

@(private)
depth_limit :: #force_inline proc "contextless" (opts: Options) -> u64 {
	return u64(opts.budget.depth) if opts.budget.depth != 0 else tape.DEFAULT_DEPTH
}

// The end of the root value of `src`, or the error in `src`. Only white space may follow the value.
@(private)
walk_text :: #force_inline proc "contextless" (src: []u8, $S: Spec, limit: u64, h: ^$H, regs: ^tape.Hook_Regs, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> (root_close: u64, err: tape.Error) {
	p := raw_data(src)
	end := p[len(src):]
	p = kernel.skip_ws(p[bom_length(src):], end)
	at, e, stopped := tape.walk_error(walk_value(src, p, S, limit, h, regs, on), &RULES)
	if e != nil || stopped {
		return at, e
	}
	if q := kernel.skip_ws(raw_data(src)[at:], end); q != end {
		when S != .Json {
			return at, root_tail(src, at, q, S, h, regs, on)
		}
		return at, tape.Fault{at = u64(intrinsics.ptr_sub(q, raw_data(src))), rules = &RULES, kind = .Bad_Char}
	}
	return at, nil
}

// The length of the UTF-8 byte order mark that starts `src`, 0 for none.
@(private)
bom_length :: #force_inline proc "contextless" (src: []u8) -> int {
	return 3 if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF else 0
}
