package html

// Parser steps for `<option>` and `<select>`: copies a selected option's children into its select's enabled
// `<selectedcontent>`. Uses an iterative heap work stack so deeply nested `<option>` DOM never recurses on the native stack.

@(private, cold)
show_selected_option :: proc(t: ^Html_Tree, n: u32) {
	if tree_node(t, n).ns != .Html {
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
	for c := tree_node(t, content).first; c != 0; c = tree_node(t, content).first {
		unlink(t, c)
	}
	for c := tree_node(t, n).first; c != 0 && !t.oom; c = tree_node(t, c).next {
		copy_tree(t, c, content)
	}
}

@(private)
nearest_select :: proc(t: ^Html_Tree, n: u32) -> u32 {
	optgroup := false
	for a := tree_node(t, n).parent; a != 0; a = tree_node(t, a).parent {
		node := tree_node(t, a)
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

@(private)
selected_option :: proc(t: ^Html_Tree, sel: u32) -> u32 {
	first, chosen := u32(0), u32(0)
	for m := next_in(t, sel, sel); m != 0; m = next_in(t, sel, m) {
		node := tree_node(t, m)
		if !is_html(node, .Option) || nearest_select(t, m) != sel {
			continue
		}
		if node_has_attr(t, m, "selected") {
			chosen = m
		}
		parent := node.parent
		if first == 0 && !node_has_attr(t, m, "disabled") && !(is_html(tree_node(t, parent), .Optgroup) && node_has_attr(t, parent, "disabled")) {
			first = m
		}
	}
	return chosen if chosen != 0 else first
}

@(private)
enabled_selectedcontent :: proc(t: ^Html_Tree, sel: u32) -> u32 {
	for m := next_in(t, sel, sel); m != 0; m = next_in(t, sel, m) {
		if !is_html(tree_node(t, m), .Selectedcontent) {
			continue
		}
		for a := tree_node(t, m).parent; a != 0; a = tree_node(t, a).parent {
			if is_html(tree_node(t, a), .Select) {
				return m if a == sel else 0
			}
		}
	}
	return 0
}

@(private)
next_in :: proc(t: ^Html_Tree, root, m: u32) -> u32 {
	if f := tree_node(t, m).first; f != 0 {
		return f
	}
	for n := m; n != root; n = tree_node(t, n).parent {
		if next := tree_node(t, n).next; next != 0 {
			return next
		}
	}
	return 0
}

@(private)
node_has_attr :: proc(t: ^Html_Tree, n: u32, name: string) -> bool {
	node := tree_node(t, n)
	found, _ := attr_value_is(t, t.attrs[node.a:][:node.b], name, "")
	return found
}

// Appends a copy of node `n` and its descendants to `parent` iteratively using `t.ctx.allocator`.
@(private)
copy_tree :: proc(t: ^Html_Tree, n, parent: u32) {
	Copy_Item :: struct {
		src:    u32,
		parent: u32,
	}
	stack := make([dynamic]Copy_Item, 0, 16, t.ctx.allocator)
	defer delete(stack)
	if _, err := append(&stack, Copy_Item{src = n, parent = parent}); err != nil {
		t.oom = true
		return
	}
	for len(stack) > 0 && !t.oom {
		item := pop(&stack)
		c := tree_node(t, item.src)^
		c.parent, c.first, c.last, c.prev, c.next = 0, 0, 0, 0, 0
		c.flags = c.flags - {.Open, .Moved} + {.Cloned}
		if c.kind == .Text {
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
		link(t, item.parent, m, 0)
		for k := tree_node(t, item.src).last; k != 0; k = tree_node(t, k).prev {
			if _, err := append(&stack, Copy_Item{src = k, parent = m}); err != nil {
				t.oom = true
				return
			}
		}
	}
}
