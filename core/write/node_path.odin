package write

import core "../"
import "../typed"

// Gives `refusal` the path from the root of `doc` to `node`, the innermost `MAX_ERROR_STEPS` steps of it: the names of
// the members and the indexes of the items it descends through, found by searching each container for the child that
// holds `node`. Names are copies in `context.temp_allocator`. It costs only a refusal.
@(cold)
node_path :: proc(refusal: ^core.Typed_Refusal, doc: ^core.Document, node: core.Node_Index) {
	steps := make([dynamic]core.Step, context.temp_allocator)
	at := core.ROOT
	descend: for at != node && int(at) < len(doc.nodes) {
		#partial switch doc.nodes[at].kind {
		case .Object:
			it := core.pairs(doc, at)
			for key, value in core.pair_next(&it) {
				if key == node || value <= node && int(node) < int(value) + core.subtree_size(doc, value) {
					name, _ := node_text(doc, key, nil, context.temp_allocator)
					append(&steps, core.Step(core.Name(name)))
					if key == node {
						break descend
					}
					at = value
					continue descend
				}
			}
		case .Array:
			it := core.children(doc, at)
			index := 0
			for child in core.child_next(&it) {
				if child <= node && int(node) < int(child) + core.subtree_size(doc, child) {
					append(&steps, core.Step(core.Index(index)))
					at = child
					continue descend
				}
				index += 1
			}
		}
		break
	}
	typed.path_keep(refusal, steps[:])
}
