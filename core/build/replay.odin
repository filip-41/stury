package build

import core ".."

// Feeds a hook the tokens of nodes `from ..< to` of `doc` as the walk gave them: each close comes back from a stack of
// container ends, each key of a headed record from `doc.shared_keys`, and a `Skip` steps over the value's subtree. A
// `Stop` ends the replay at once, and `out` holds the registers either way. A container's token keeps its node's subtree
// size and child count, where the walk gives zeros, and an `End` carries its container's last node in `lo`.
//
// `step` gets a token and the node it came from. With `$OPEN` false an `End` carries `core.NO_NODE` and `ends` holds a frame
// per depth. With it true an `End` carries the container's node, and `ends` holds two words per depth. `keyed` says
// whether the value at node `i` of the container `open` has a key in `doc.shared_keys` and which, and is called only for
// a document that has them. `open` is `core.NO_NODE` unless `$OPEN`.
feed_nodes :: proc "contextless" (
	doc: ^core.Document,
	from, to: u32,
	h: ^$H,
	out: ^core.Hook_Regs,
	ends: []u32,
	$step: proc "contextless" (h: ^H, regs: core.Hook_Regs, t: core.Token, at: core.Node_Index) -> (core.Hook_Regs, core.Action),
	$keyed: proc "contextless" (h: ^H, regs: core.Hook_Regs, i, open: core.Node_Index) -> (core.Node_Index, bool),
	$OPEN: bool,
) {
	when OPEN {
		STRIDE :: 2
	} else {
		STRIDE :: 1
	}
	regs := out^
	defer out^ = regs
	// No step writes the document, so its nodes and header row are read once.
	nodes := doc.nodes
	headed := doc.shared_keys != 0
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
				return
			}
		}
		if i >= to {
			return
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
						return
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
			return
		case .Skip:
			// A key passed over takes its value with it.
			if t.role == .Key {
				i += 1
				t = nodes[i]
			}
			i += t.n if t.kind > .Plain else 1
		case .Next, .Keep:
			if t.kind > .Plain {
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
