package scan

import "walk"

// JSON's hooks, the table the walk's matchers call into. Every JSON scan's context points at it.
@(rodata)
FORMAT_HOOKS := walk.Format_Hooks{
	escaped_key_equals = name_equals,
	path_subwalk = path_subwalk_for_core,
	dom_unescape_into = dom_unescape_into,
}

@(private = "file")
path_subwalk_for_core :: proc(s: ^walk.Scanner, ctx: ^walk.Query_Ctx, max_depth: u64, halted: ^bool) -> Maybe(Error) {
	// Under a raised cap the re-entry reads at the level of the walk that reached it.
	if max_depth > MAX_DEPTH {
		if ctx.walk_judged {
			return walk_deep(s, ctx, max_depth, .Values, {.Path}, &Jsonc_Cursor{json = true}, true, halted)
		}
		return walk_deep(s, ctx, max_depth, .Locate, {.Path}, &Jsonc_Cursor{json = true}, true, halted)
	}
	// A checking walk may have skipped the answer (`.Lazy`), so the re-entry checks it, and only it: the
	// members it passes were checked by that walk, or skipped as a forward index skips them.
	if ctx.walk_judged {
		return walk_value_q(s, ctx, max_depth, .Values, {.Path}, &Byte_Cursor{}, true, true, halted)
	}
	return walk_value_q(s, ctx, max_depth, .Locate, {.Path}, &Byte_Cursor{}, false, true, halted)
}
