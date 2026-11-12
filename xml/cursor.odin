package xml

import core "../core"

// A walk's cursor, `core.Token_Cursor`: at its first stop the walk reads on to the text's end and holds the tokens
// past the stop, which `walk_resume` gives.
Cursor :: core.Token_Cursor

// Whether `cursor` holds a stop that `walk_resume` continues, false once the walk it fills ended.
can_resume :: #force_inline proc "contextless" (cursor: ^Cursor) -> bool {
	return cursor.held != nil
}

// Continues the walk `cursor` holds a stop of, over the same `src`, from the token after the one it stopped on.
// `regs` is passed to the first token in place of the registers the stop saved, unless it is nil. The results are
// `walk`'s. A cursor that holds no stop, or that a walk of another text filled, is refused with `.Bad_Option`.
walk_resume :: proc "contextless" (src: []u8, cursor: ^Cursor, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	return core.cursor_resume(src, cursor, h, regs, on, &RULES)
}

// Frees what `cursor` holds, a stop no resume ended.
cursor_destroy :: core.cursor_free

// `walk` with a cursor: the walk of the whole text through `core.Holding`, which hands its held tokens to `cursor` when
// the hook stopped.
@(private)
walk_holding :: proc "contextless" (src: []u8, lo: u64, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor) -> (hi: u64, fault: Maybe(core.Fault)) {
	holding :: proc "contextless" (s: ^core.Holding(H), regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
		return core.holding_hook(s, regs, t, on)
	}
	zero: core.Hook_Regs
	r := regs if regs != nil else &zero
	s := core.Holding(H) {
		hooks = h,
	}
	hi, fault, _ = core.result_of(walk_document(src, lo, opts, &s, r, holding, nil), &RULES)
	return core.holding_end(src, cursor, &s, r, hi, fault, &RULES)
}
