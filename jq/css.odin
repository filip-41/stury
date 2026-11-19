#+private
package jq

import core_pkg "../core"
import "../core/css"

// css(selector): the value of each element of the input that the selector matches, in document order, from the
// descendants of an element or of a whole xml or html input, as the filter has it: an update keeps the nodes it leaves
// alone, and the elements are read through what it changed. A path through it steps along the grouped members a value
// reads, the index of an element whose name its parent repeats included.
gen_css :: proc(ip: ^Interp, input: Item, args: []core_pkg.Value, track: bool, out: ^Sink) -> Signal {
	text, is_str := string_of(args[0])
	if !is_str {
		return fail(ip, "%s (%s) cannot be a selector, as it is not a string", type_name(args[0]), brief(ip, args[0]))
	}
	_, is_node := core_pkg.plain(input.v).(core_pkg.Node_Ref)
	doc := markup_document(input.v)
	if doc == nil || !is_node && kind(input.v) != .Object {
		return fail(ip, "%s (%s) cannot be selected from, as it is not an element of an xml or html input", type_name(input.v), brief(ip, input.v))
	}
	sel, err := css.compile(text)
	if f, is_fault := err.(core_pkg.Fault); is_fault {
		return fail(ip, "%s (at offset %d) is not a valid selector: %s", brief(ip, args[0]), f.at, core_pkg.rule_of(f).message)
	} else if err != nil {
		return fail(ip, "css: out of memory")
	}
	defer css.destroy(&sel)
	found, no_memory := css.select_value(input.v, &sel, doc.readers.fold_names, track)
	if no_memory != nil {
		return fail(ip, "css: out of memory")
	}
	for match in found {
		it := Item{v = match.value}
		if track {
			it.path = path_from(input, input.v) if pathless(input.path) else input.path
			for step in match.path {
				it.path = extend(it.path, step)
			}
		}
		if sig := out.emit(out, it); sig != .Go {
			return sig
		}
	}
	return .Go
}

// The markup document `v` is a node of or was put in place of one of, or that the first node an update of one kept is
// in. Nil for a value of no markup document.
@(private = "file")
markup_document :: proc(v: core_pkg.Value, depth := 0) -> ^core_pkg.Document {
	if depth > core_pkg.MAX_DEPTH {
		return nil
	}
	if r, is_node := core_pkg.facts_node(v); is_node {
		return r.doc if core_pkg.is_markup(r.doc) else nil
	}
	members: []core_pkg.Value
	#partial switch x in core_pkg.plain(v) {
	case ^core_pkg.Object: members = core_pkg.object_vals(x)[:]
	case ^core_pkg.Array:  members = x.items[:]
	}
	for m in members {
		if doc := markup_document(m, depth + 1); doc != nil {
			return doc
		}
	}
	return nil
}
