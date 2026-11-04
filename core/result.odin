package core

// The `u64` result word every format's walk carries while it runs. It is one word, so a state or pass passes it in a
// register, and the walk's end turns it into `(hi, fault)`.

// Builds a result word: `pos` in bits 16 and up, `detail` in bits 8 to 15, and `kind` in bits 0 to 7, 0 for none.
// With no fault, `pos` is where the walk ended and `detail` is `STOPPED` when a hook stopped it. `detail` holds the
// format's `Detail` narrowed to a byte.
fault_at :: #force_inline proc "contextless" (pos: u64, kind: Fault_Kind, detail: u8 = 0) -> u64 {
	return pos << 16 | u64(detail) << 8 | u64(kind)
}

// The detail field of a result when a hook returned `.Stop`: no fault, and `hi` is one past the token it stopped on.
// The walk read no further, so `hi` is not a document boundary.
STOPPED :: 1

// Returns the `Fault` in `r` with `rules` set, or nil when `r`'s kind is 0.
fault_of :: #force_inline proc "contextless" (r: u64, rules: ^Rules) -> Maybe(Fault) {
	if r & 0xff == 0 {
		return nil
	}
	return Fault{at = r >> 16, rules = rules, kind = Fault_Kind(r & 0xff), detail = u8(r >> 8)}
}

// An empty hook type. `validate` passes it, and the hook compiles to no code.
No_Hooks :: struct {}

no_hook :: #force_inline proc "contextless" (h: ^No_Hooks, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	return s, .Next
}
