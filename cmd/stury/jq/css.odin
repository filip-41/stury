package jq

import core_pkg "../../../core"
import "../../../core/css"

// css(selector): the value of each element of the input that the selector matches, in document order, from the
// descendants of an element or of a whole xml or html input. A path through it steps along the grouped members a
// value reads, the index of an element whose name its parent repeats included.
gen_css :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink) -> Signal {
	text, is_str := string_of(args[0])
	if !is_str {
		return fail(ip, "%s (%s) cannot be a selector, as it is not a string", type_name(args[0]), brief(ip, args[0]))
	}
	r, is_ref := input.v.(Ref)
	if !is_ref || !core_pkg.is_markup(r.doc) {
		return fail(ip, "%s (%s) cannot be selected from, as it is not an element of an xml or html input", type_name(input.v), brief(ip, input.v))
	}
	sel, err := css.compile(text)
	if f, is_fault := err.(core_pkg.Fault); is_fault {
		return fail(ip, "%s (at offset %d) is not a valid selector: %s", brief(ip, args[0]), f.at, core_pkg.rule_of(f).message)
	} else if err != nil {
		return fail(ip, "css: out of memory")
	}
	defer css.destroy(&sel)
	found, no_memory := css.select(r.doc, &sel, r.node)
	if no_memory != nil {
		return fail(ip, "css: out of memory")
	}
	defer delete(found)
	for v in found {
		it := Item{v = Ref{r.doc, v}}
		if track {
			it.path = path_from(input, input.v) if pathless(input.path) else input.path
			it.path = element_path(it.path, r, v)
		}
		if sig := out.emit(out, it); sig != .Go {
			return sig
		}
	}
	return .Go
}

// `p` extended by the steps from object node `r` down to the element whose value is `v`: each element's name, then
// its index among the elements of that name when its parent has more than one.
@(private = "file")
element_path :: proc(p: ^Path_Step, r: Ref, v: core_pkg.Node_Index) -> ^Path_Step {
	p := p
	for at := r.node; at != v; {
		it := core_pkg.doc_pairs(r.doc, at)
		for k, child in core_pkg.doc_pair_next(&it) {
			if v < child || int(v) >= int(child) + core_pkg.subtree_size(r.doc, child) {
				continue
			}
			name := core_pkg.node_string(r.doc, k)
			p = extend(p, name)
			same := core_pkg.members_named(r.doc, at, name)
			index, count := 0, 0
			for node in core_pkg.member_next(&same) {
				index = count if node == child else index
				count += 1
			}
			if count > 1 {
				p = extend(p, num(f64(index)))
			}
			at = child
			break
		}
	}
	return p
}
