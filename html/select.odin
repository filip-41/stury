package html

// The steps of the `option` and `select` elements the parser runs: when the parser pops an option its select has
// selected, the select's `selectedcontent` element takes a copy of the option's children. Selectedness is the
// standard's for a select without `multiple`: the last option with a `selected` attribute, else the first one not
// disabled.

// Copies option `n`'s children into its select's enabled `selectedcontent` when `n` is the option its select selects.
@(private, cold)
show_selected_option :: proc(t: ^Html_Tree, n: u32) {
	if t.nodes[n].ns != .Html {
		return
	}
	sel := nearest_select(t, n)
	if sel == 0 || node_has_attr(t, sel, "multiple") || selected_option(t, sel) != n {
		return
	}
	content := enabled_selectedcontent(t, sel)
	if content == 0 {
		return
	}
	for c := t.nodes[content].first; c != 0; c = t.nodes[content].first {
		unlink(t, c)
	}
	for c := t.nodes[n].first; c != 0 && !t.oom; c = t.nodes[c].next {
		copy_tree(t, c, content)
	}
}

// The select an option belongs to: its nearest ancestor `select`, unless a `datalist`, `hr`, `option` or a second
// `optgroup` comes first.
@(private)
nearest_select :: proc(t: ^Html_Tree, n: u32) -> u32 {
	optgroup := false
	for a := t.nodes[n].parent; a != 0; a = t.nodes[a].parent {
		node := &t.nodes[a]
		if node.ns != .Html {
			continue
		}
		#partial switch node.tag {
		case .Datalist, .Hr, .Option:
			return 0
		case .Optgroup:
			if optgroup {
				return 0
			}
			optgroup = true
		case .Select:
			return a
		}
	}
	return 0
}

// The option select `sel` selects among the options in it so far.
@(private)
selected_option :: proc(t: ^Html_Tree, sel: u32) -> u32 {
	first, chosen := u32(0), u32(0)
	for m := next_in(t, sel, sel); m != 0; m = next_in(t, sel, m) {
		node := &t.nodes[m]
		if !is_html(node, .Option) || nearest_select(t, m) != sel {
			continue
		}
		if node_has_attr(t, m, "selected") {
			chosen = m
		}
		parent := node.parent
		if first == 0 && !node_has_attr(t, m, "disabled") && !(is_html(&t.nodes[parent], .Optgroup) && node_has_attr(t, parent, "disabled")) {
			first = m
		}
	}
	return chosen if chosen != 0 else first
}

// The first `selectedcontent` in select `sel`, in tree order, unless a nested select holds it.
@(private)
enabled_selectedcontent :: proc(t: ^Html_Tree, sel: u32) -> u32 {
	for m := next_in(t, sel, sel); m != 0; m = next_in(t, sel, m) {
		if !is_html(&t.nodes[m], .Selectedcontent) {
			continue
		}
		for a := t.nodes[m].parent; a != 0; a = t.nodes[a].parent {
			if is_html(&t.nodes[a], .Select) {
				return m if a == sel else 0
			}
		}
	}
	return 0
}

// The node after `m` in tree order within `root`, 0 past its last.
@(private)
next_in :: proc(t: ^Html_Tree, root, m: u32) -> u32 {
	if f := t.nodes[m].first; f != 0 {
		return f
	}
	for n := m; n != root; n = t.nodes[n].parent {
		if next := t.nodes[n].next; next != 0 {
			return next
		}
	}
	return 0
}

@(private)
node_has_attr :: proc(t: ^Html_Tree, n: u32, name: string) -> bool {
	node := &t.nodes[n]
	found, _ := attr_value_is(t, t.attrs[node.a:][:node.b], name, "")
	return found
}

// Appends a copy of node `n` and its descendants to `parent`.
@(private)
copy_tree :: proc(t: ^Html_Tree, n, parent: u32) {
	c := t.nodes[n]
	c.parent, c.first, c.last, c.prev, c.next = 0, 0, 0, 0, 0
	c.flags = c.flags - {.Open, .Moved} + {.Cloned}
	if c.kind == .Text {
		// A text's pieces are its own, since a text it extends grows its last piece.
		first := add_piece(t, t.pieces[c.a].span)
		last := first
		for p := c.a; p != c.b && !t.oom; {
			p = t.pieces[p].next
			q := add_piece(t, t.pieces[p].span)
			t.pieces[last].next = q
			last = q
		}
		c.a, c.b = first, last
	}
	m := new_node(t, c)
	if t.oom {
		return
	}
	link(t, parent, m, 0)
	for k := t.nodes[n].first; k != 0 && !t.oom; k = t.nodes[k].next {
		copy_tree(t, k, m)
	}
}
