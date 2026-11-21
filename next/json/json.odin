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
	budget: tape.Budget, // only `depth` applies to a JSON read
}

@(private, rodata)
RULES := tape.Rules{"json", {}}

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Json  = {name = "json", id = 1},
	.Jsonc = {name = "jsonc", id = 2, facts = tape.COMMENTS},
	.Json5 = {name = "json5", id = 3, facts = tape.COMMENTS},
}

// The error in `src`, nil when it is one text of `spec`. An optimized build with a constant `spec` links only that
// spec's walk.
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
	// A text makes at most `(len(src) + 1 + depth) / 2` nodes, so the hook checks no capacity. Each node spends two
	// bytes (a container its brackets, a key its colon, a scalar the comma or close after it), except a container left
	// open and the token before a fault, which may spend one.
	frames: [FRAME_DEPTH]u64 = ---
	b := build.builder_start(src, &FORMATS[S], (len(src) + int(depth)) / 2 + 16, frames[:min(depth, FRAME_DEPTH)], allocator)
	if b.err != nil {
		return {}, b.err
	}
	regs := build.builder_regs(&b)
	on :: build.builder_hook_facts when S != .Json else build.builder_hook
	root_close, err := walk_text(src, S, limit, &b, &regs, on)
	return build.builder_end(&b, regs, root_close, err)
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
