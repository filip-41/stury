package core

// What every format's walk returns while it runs. A result is one word, so a state or a pass passes it in a register,
// and only the walk's end turns it into `(hi, fault)`.

// A walk's result in one word: a position in bits 16 and up, a detail in bits 8 to 15, and the fault's kind in bits 0
// to 7, 0 for none. With no fault the position is where the walk ended and the detail is `STOPPED` when a hook
// stopped it. `detail` is the format's `Detail` narrowed to a byte.
fault_at :: #force_inline proc "contextless" (pos: u64, kind: Fault_Kind, detail: u8 = 0) -> u64 {
	return pos << 16 | u64(detail) << 8 | u64(kind)
}

// Set in the result's detail field when a hook asked the walk to stop: no fault, and `hi` is one past the token it
// stopped on.
STOPPED :: 1

// The fault a result word holds, through the format's `rules`, or nil when its kind is 0.
fault_of :: #force_inline proc "contextless" (r: u64, rules: ^Rules) -> Maybe(Fault) {
	if r & 0xff == 0 {
		return nil
	}
	return Fault{at = r >> 16, rules = rules, kind = Fault_Kind(r & 0xff), detail = u8(r >> 8)}
}

// A hook that asks for nothing: what `validate` passes for its tokens, which folds away to no code.
No_Hooks :: struct {}

no_hook :: #force_inline proc "contextless" (h: ^No_Hooks, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	return s, .Next
}
