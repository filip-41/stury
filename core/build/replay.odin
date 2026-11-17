package build

import "base:runtime"
import core ".."

// Feeds a hook the tokens of nodes `from ..< to` of `doc` as the walk gave them: each close comes back from a stack of
// container ends, each key of a headed record from the table's header, and a `Skip` steps over the value's subtree. A
// `Stop` ends the replay at once, and `out` holds the registers either way. A container's token keeps its node's subtree
// size and child count, where the walk gives zeros, and an `End` carries its container's last node in `lo`.
//
// `step` gets a token and the node it came from. With `$OPEN` false an `End` carries `core.NO_NODE` and `ends` holds a frame
// per depth. With it true an `End` carries the container's node, and `ends` holds two words per depth. `keyed` says
// whether the value at node `i` of the container `open` has a key in the table's header and which, and is called only for
// a document that has them. `open` is `core.NO_NODE` unless `$OPEN`.
//
// After a step that does not skip, `cut` may name the node at which the open container ends sooner than it did: no later
// sibling is read, and the container closes there. It gets the depth of the open container, its end, and the node's index. It
// returns `max(u32)` for no cut. The hook's close must then know that its count is the container's, and `resume` gives,
// after the close of the container at 0-based depth `k`, the node the replay goes on at, or 0 when it was not cut.
//
// The hook's stacks hold at least the depths `ends` holds. A container that leaves `ends` room for no deeper level
// grows it, and `deepen` grows the hook's stacks by as many levels. Returns false when either cannot grow.
feed_nodes :: proc "contextless" (
	doc: ^core.Document,
	from, to: u32,
	h: ^$H,
	out: ^core.Hook_Regs,
	ends: []u32,
	$step: proc "contextless" (h: ^H, regs: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action),
	$keyed: proc "contextless" (h: ^H, regs: core.Hook_Regs, i, open: core.Node_Index) -> (core.Node_Index, bool),
	$deepen: proc "contextless" (h: ^H, extra: int) -> bool,
	$OPEN: bool,
	$cut: proc "contextless" (h: ^H, regs: core.Hook_Regs, depth: int, i: u32, t: core.Token, end: u32) -> u32,
	$resume: proc "contextless" (h: ^H, k: int) -> u32,
) -> bool {
	when OPEN {
		STRIDE :: 2
	} else {
		STRIDE :: 1
	}
	regs := out^
	defer out^ = regs
	ends := ends
	owned := false
	defer if owned {
		runtime.heap_free(raw_data(ends))
	}
	// No step writes the document, so its nodes and header row are read once.
	nodes := doc.nodes
	headed := core.header_of(doc) != 0
	depth := 0
	i := from
	action: core.Action
	for {
		for depth > 0 && i >= ends[(depth - 1) * STRIDE] {
			depth -= 1
			at := core.NO_NODE
			when OPEN {
				at = core.Node_Index(ends[depth * STRIDE + 1])
			}
			regs, action = step(h, regs, core.Token{kind = .End, lo = u64(ends[depth * STRIDE]) - 1}, at)
			if action == .Stop {
				return true
			}
			i = max(i, resume(h, depth))
		}
		if i >= to {
			return true
		}
		t := nodes[i]
		if headed {
			// The header row is the root's first child, and the walk gives its cells as each record's keys.
			if t.role == .Key && t.kind == .Array {
				i += t.n
				continue
			}
			if depth > 0 {
				open := core.NO_NODE
				when OPEN {
					open = core.Node_Index(ends[depth * STRIDE - 1])
				}
				if at, ok := keyed(h, regs, core.Node_Index(i), open); ok {
					regs, action = step(h, regs, nodes[at], at)
					if action == .Stop {
						return true
					}
					if action == .Skip {
						i += t.n if t.kind > .Plain else 1
						continue
					}
				}
			}
		}
		regs, action = step(h, regs, t, core.Node_Index(i))
		switch action {
		case .Stop:
			return true
		case .Skip:
			// A key passed over takes its value with it.
			if t.role == .Key {
				i += 1
				t = nodes[i]
			}
			i += t.n if t.kind > .Plain else 1
		case .Next, .Keep:
			if depth > 0 {
				if c := cut(h, regs, depth, i, t, ends[(depth - 1) * STRIDE]); c < ends[(depth - 1) * STRIDE] {
					ends[(depth - 1) * STRIDE] = c
				}
			}
			if t.kind > .Plain {
				if (depth + 2) * STRIDE > len(ends) {
					// The hook's stacks grow first, since a resize frees the old `ends` and the deferred free would free it again.
					n := max(2 * len(ends), 2 * STRIDE)
					if !deepen(h, (n - len(ends)) / STRIDE) {
						return false
					}
					wide, grown := grow_ends(ends, owned, n)
					if !grown {
						return false
					}
					ends, owned = wide, true
				}
				ends[depth * STRIDE] = i + t.n
				when OPEN {
					ends[depth * STRIDE + 1] = i
				}
				depth += 1
			}
			i += 1
		}
	}
}

// A copy of `ends` in `n` slots on the default heap, freeing `ends` when `owned`.
@(private, cold)
grow_ends :: proc "contextless" (ends: []u32, owned: bool, n: int) -> ([]u32, bool) {
	raw := runtime.heap_resize(raw_data(ends), n * size_of(u32)) if owned else runtime.heap_alloc(n * size_of(u32), false)
	if raw == nil {
		return ends, false
	}
	wide := ([^]u32)(raw)[:n]
	if !owned {
		copy(wide, ends)
	}
	return wide, true
}

// The `cut` of a hook that reads every sibling.
no_cut :: #force_inline proc "contextless" (_: ^$H, _: core.Hook_Regs, _: int, _: u32, _: core.Token, _: u32) -> u32 {
	return max(u32)
}

// The `resume` of a hook that cuts nothing.
no_resume :: #force_inline proc "contextless" (_: ^$H, _: int) -> u32 {
	return 0
}

// The `deepen` of a hook with no stack.
no_deepen :: proc "contextless" (_: ^$H, _: int) -> bool {
	return true
}
