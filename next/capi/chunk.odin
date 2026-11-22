package capi

import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The tokens a chunk hook hands its consumer at once. A foreign boundary that costs more than a token's copy is crossed
// once per chunk rather than once per token.
CHUNK :: 256

// A hook that hands a consumer the walk's tokens in chunks, for a consumer across a boundary whose every call is dear.
// `take` gets the tokens the walk gave since the last chunk, in text order, in the hook's own buffer, which the next
// chunk overwrites: a consumer copies what it keeps. Each token is a view into the text its `lo` and `n` place it in.
// `take` answers whether the walk goes on: `false` hands the chunk it found full and ends the walk at the next token,
// which is not given. The cursor rides in the walk's registers, so a token costs the walk a store and an add, and no
// call of a capability's; the registers hold the buffer's address, so the hook does not move between `chunk_regs` and
// the walk's end.
Chunk_Hook :: struct {
	take:     proc "c" (ctx: rawptr, tokens: [^]tape.Token, n: int) -> bool,
	ctx:      rawptr,
	buf:      [CHUNK]tape.Token,
	protocol: hook.Protocol(hook.Capabilities{}, hook.Unused, hook.Unused, hook.Unused),
}

// The registers a walk for the hook `h` starts with: `a` the buffer's next free token, `b` one past its last.
chunk_regs :: #force_inline proc "contextless" (h: ^Chunk_Hook) -> hook.Regs {
	start := uintptr(&h.buf[0])
	return hook.Regs{a = u64(start), b = u64(start) + CHUNK * size_of(tape.Token)}
}

// Gives the hook token `t`, handing the consumer the chunk first where the buffer is full.
chunk_hook :: #force_inline proc "contextless" (h: ^Chunk_Hook, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	s := s
	if s.a == s.b {
		s.a = u64(uintptr(&h.buf[0]))
		if !h.take(h.ctx, &h.buf[0], CHUNK) {
			return s, .Stop
		}
	}
	(^tape.Token)(uintptr(s.a))^ = t
	s.a += size_of(tape.Token)
	return s, .Next
}

// Hands the consumer the tokens past the last full chunk, after the walk ended however it did, its last registers
// `regs`, and answers `take`. A consumer that ended the walk with `false` is not called again.
chunk_flush :: proc "contextless" (h: ^Chunk_Hook, regs: hook.Regs) -> bool {
	held := int((uintptr(regs.a) - uintptr(&h.buf[0])) / size_of(tape.Token))
	if held == 0 {
		return true
	}
	return h.take(h.ctx, &h.buf[0], held)
}
