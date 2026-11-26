package yaml

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Reads YAML texts arriving in piece windows (`Options.pieces`). Because YAML documents can reference earlier anchors,
// span root multi-line plain scalars across lines, apply `.Last` duplicates or `<<` merges at container close, and
// must check for trailing documents, intermediate windows buffer cleanly until the final window and then run the exact
// single-pass YAML walk so results, faults, and partial trees agree identically with whole-text reads.

@(private)
Piece :: struct {
	using state: hook.Piece_State,
}

@(private)
piece_free :: proc(p: ^tape.Pieces) {
	hook.piece_release(p)
}

@(private)
piece_read :: proc(
	src: []u8,
	$S: Spec,
	opts: Options,
	h: ^$H,
	regs: ^hook.Regs,
	allocator: runtime.Allocator,
	ctx: ^runtime.Context,
	$on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action),
	allow_empty := false,
	check_tail := true,
	allow_complex := false,
) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	context = ctx^
	p := opts.pieces
	s, text, to, e := hook.piece_begin(p, Piece, piece_free, src)
	if e != nil {
		return 0, e, false
	}
	_ = s
	if !p.last {
		p.more, p.at, p.keep, p.open = true, to, 0, nil
		return 0, nil, false
	}
	p.more, p.at, p.open = false, to, nil
	when H == hook.No_Hooks {
		if allow_empty {
			return validate_stream(text, S, true, opts, h, regs, allocator, ctx)
		}
	}
	return walk_text(text, S, true, opts, h, regs, allocator, ctx, on, 0, allow_empty, check_tail, allow_complex)
}

@(private)
validate_pieces :: proc(src: []u8, $S: Spec, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	walk :: proc(src: []u8, opts: Options, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, hook.no_hook, allow_empty = true, check_tail = false, allow_complex = true)
	}
	return build.read_validate_pieces(src, &FORMATS[S], opts, allocator, Piece, walk)
}

@(private)
build_pieces :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, build.builder_hook_facts)
	}
	return build.read_build_pieces(src, &FORMATS[S], &RULES, opts, caller, Piece, walk, build.builder_finish_dups)
}

@(private)
find_pieces :: proc(src: []u8, path: []tape.Step, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		return piece_read(src, S, opts, h, regs, a, ctx, build.finder_key_skip_hook)
	}
	return build.read_find_pieces(src, path, &FORMATS[S], read, opts, caller, respell_number, Piece, walk)
}

@(private)
scan_pieces :: proc(src: []u8, demand: ^tape.Demand, $S: Spec, read: tape.Read_Options, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	walk :: proc(src: []u8, opts: Options, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		h.scattered = true
		return piece_read(src, S, opts, h, regs, a, ctx, build.scanner_key_skip_hook)
	}
	return build.read_scan_pieces(src, demand, &FORMATS[S], read, opts, caller, Piece, walk)
}
