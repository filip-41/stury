#+build amd64
package dsv

import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

@(private, enable_target_feature = kernel.FEATURES[.V3])
pass_default_v3 :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT: bool) -> hook.Walk_Result {
	hs := regs^
	defer regs^ = hs
	return pass(w, src, lo, default_options(S), &hs, on, EMIT, false, .V3)
}

@(private, enable_target_feature = kernel.FEATURES[.V3])
pass_with_v3 :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, p: Pass_Options, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT, $COMMENTS: bool) -> hook.Walk_Result {
	hs := regs^
	defer regs^ = hs
	return pass(w, src, lo, p, &hs, on, EMIT, COMMENTS, .V3)
}

@(private, enable_target_feature = kernel.FEATURES[.V3])
line_end_v3 :: #force_no_inline proc "contextless" (src: []u8, start: int, $S: Spec, delim: u8) -> int {
	return line_end_in_blocks(src, start, S, delim, .V3)
}

@(private, enable_target_feature = kernel.FEATURES[.V3])
read_chunk_v3 :: #force_no_inline proc "contextless" (src: []u8, c: ^Chunk, $S: Spec, p: Pass_Options, both: bool) {
	read_chunk_in(src, c, S, p, both, .V3)
}
