package capi

import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The tokens a chunk hook gives its consumer per call. A foreign call costs more than copying a token, so the boundary
// is crossed once per chunk instead of once per token.
CHUNK :: 256

// A hook that gives a consumer the walk's tokens in chunks, for a consumer across a boundary where every call is
// expensive. `take` receives the tokens the walk gave since the last chunk, in text order, in the hook's own buffer,
// which the next chunk overwrites, so a consumer copies what it keeps. Each token is a view into the text, placed by
// its `lo` and `n`. `take` returns whether the walk continues: `false` ends the walk at the next token, which is not
// given. The cursor is in the walk's registers, so giving a token costs the walk a store and an add and no capability
// call. The registers hold the buffer's address, so the hook must not move between `chunk_regs` and the walk's end.
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

// Gives token `t` to the hook, first passing the chunk to the consumer when the buffer is full.
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

// Gives the consumer the tokens after the last full chunk, once the walk has ended for any reason. `regs` are the
// walk's last registers. Returns what `take` returns. A consumer that ended the walk with `false` is not called
// again.
chunk_flush :: proc "contextless" (h: ^Chunk_Hook, regs: hook.Regs) -> bool {
	held := int((uintptr(regs.a) - uintptr(&h.buf[0])) / size_of(tape.Token))
	if held == 0 {
		return true
	}
	return h.take(h.ctx, &h.buf[0], held)
}
