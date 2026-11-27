package tape

// Readers over `Tabular_Ext` (CSV/TSV) tables and their header-named rows.

// The table whose row is the object at `at`, false for an object of no table.
@(private)
row_of :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> (Table, bool) {
	if doc.ext == nil {
		return {}, false
	}
	ext, tabular := &doc.ext.format.(Tabular_Ext)
	if !tabular {
		return {}, false
	}
	return table_around(ext, doc, at)
}

// How a table kept the cells of a header name that repeats: the first or the last of a name under `.First` and `.Last`,
// as an object built under them keeps one member of a key, and every one under the other policies.
@(private = "file")
table_kept :: #force_inline proc "contextless" (doc: ^Document) -> Duplicates {
	d := doc.ext.format.(Tabular_Ext).dups
	return d if d == .First || d == .Last else .All
}

// The policy a row of a table reads `dups` as. A table that kept one cell of a repeated name never reads another, so
// its policy is the table's, and the cells of a table that kept every one are read as an object's members are.
@(private)
row_policy :: #force_inline proc "contextless" (doc: ^Document, dups: Duplicates) -> Duplicates {
	if kept := table_kept(doc); kept != .All {
		return kept
	}
	return read_dups(doc.format, dups)
}

// Whether cell `j` of the `cells` of a row of a table whose keys are `keys` is one its build stored but drops, a cell of
// a repeated key the table's `Duplicates` policy does not keep.
column_dropped :: proc "contextless" (doc: ^Document, keys: []Node, j, cells: int) -> bool {
	kept := table_kept(doc)
	return kept != .All && cell_dropped(doc, keys, j, cells, kept)
}

// Whether cell `j` of the `cells` of a row is one a table that kept the `kept` cell of a name stored but dropped: a
// later cell of its key under `.Last`, an earlier under `.First`.
@(private = "file")
cell_dropped :: proc "contextless" (doc: ^Document, keys: []Node, j, cells: int, kept: Duplicates) -> bool #no_bounds_check {
	k := keys[j]
	lo, hi := 0, j
	if kept == .Last {
		lo, hi = j + 1, cells
	}
	for o in lo ..< hi {
		if doc_same_keys(doc, keys[o], k) {
			return true
		}
	}
	return false
}

// The table whose node is the array at `at`, false for an array that is no table.
@(private)
table_of :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> (Table, bool) {
	t, inside := row_of(doc, at)
	return t, inside && t.node == at
}

// The table whose node holds node `at`, false for none. Tables are sorted by node and do not nest.
@(private = "file")
table_around :: proc "contextless" (ext: ^Tabular_Ext, doc: ^Document, at: Node_Index) -> (Table, bool) #no_bounds_check {
	lo, hi := 0, len(ext.tables)
	for lo < hi {
		mid := (lo + hi) / 2
		if ext.tables[mid].node <= at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return {}, false
	}
	t := ext.tables[lo - 1]
	return t, at < t.node + Node_Index(doc.nodes[t.node].n)
}

// The keys of the table whose keys are `keys_n` from `keys_lo` of its `Tabular_Ext`.
@(private = "file")
table_keys_at :: #force_inline proc "contextless" (doc: ^Document, keys_lo, keys_n: u32) -> []Node #no_type_assert #no_bounds_check {
	return doc.ext.format.(Tabular_Ext).keys[keys_lo:][:keys_n]
}

// The keys of the table whose node is `at`, none for a table with no header, and whether `at` is a table.
table_keys :: proc "contextless" (doc: ^Document, at: Node_Index) -> (keys: []Node, table: bool) {
	t := table_of(doc, at) or_return
	return table_keys_at(doc, t.keys_lo, t.keys_n), true
}

// The cells of row `at` that a key names, of the `keys` keys of its table, which a row with more cells than keys has
// fewer of.
@(private = "file")
row_cells :: #force_inline proc "contextless" (doc: ^Document, keys: u32, at: Node_Index) -> int {
	return min(int(doc.nodes[at].n) - 1, int(keys))
}

// The cell of row `at` of table `t` whose key is `name` under `dups`, through the table's key slots when they settle
// it.
@(private)
row_member :: proc "contextless" (doc: ^Document, t: Table, at: Node_Index, name: string, dups: Duplicates) -> (Node_Index, Presence) #no_bounds_check {
	cells := row_cells(doc, t.keys_n, at)
	keys := table_keys_at(doc, t.keys_lo, t.keys_n)
	f := doc.format
	// The slots hold each key's first column, which is its only one in a table whose keys are unique.
	if t.slots_len != 0 && (t.unique_keys || dups != .Last) {
		slots := doc.ext.format.(Tabular_Ext).slots[t.slots_lo:][:t.slots_len]
		mask := t.slots_len - 1
		for i := f.key_hash(transmute([]u8)name, {n = u32(len(name)), kind = .String}) & mask; slots[i] != 0; i = (i + 1) & mask {
			col := Node_Index(slots[i]) - 1
			if doc_names(doc, keys[col], name) {
				if int(col) < cells {
					return at + 1 + col, .Found
				}
				break
			}
		}
		return NO_NODE, .Missing
	}
	found := NO_NODE
	for j in 0 ..< cells {
		if doc_names(doc, keys[j], name) {
			found = at + 1 + Node_Index(j)
			if dups != .Last || t.unique_keys {
				break
			}
		}
	}
	return found, .Found if found != NO_NODE else .Missing
}

// The distinct keys of row `at` of table `t`.
@(private)
row_length :: proc "contextless" (doc: ^Document, t: Table, at: Node_Index) -> int #no_bounds_check {
	cells := row_cells(doc, t.keys_n, at)
	if t.unique_keys {
		return cells
	}
	c := Children{container = at, next = at + 1, keys_lo = t.keys_lo, keys_n = t.keys_n}
	for {
		if _, p := next_cell(doc, &c, row_policy(doc, .Default)); p != .Found {
			return int(c.place)
		}
	}
}

// `next_child` over a table's row: each cell as written under `.Group`, for a walk from `named` and for a table of
// unique keys, else each distinct key with the cell `dups` takes. A cell's key is no node, but `cell_key`'s.
@(private)
next_cell :: proc "contextless" (doc: ^Document, c: ^Children, dups: Duplicates) -> (value: Node_Index, p: Presence) #no_bounds_check {
	keys := table_keys_at(doc, c.keys_lo, c.keys_n)
	cells := Node_Index(row_cells(doc, c.keys_n, c.container))
	kept := table_kept(doc)
	next: for c.next < c.container + 1 + cells {
		j := c.next - c.container - 1
		value = c.next
		k := keys[j]
		c.next += 1
		if c.named {
			if !doc_names(doc, k, c.name) || !c.once && kept != .All && cell_dropped(doc, keys, int(j), int(cells), kept) {
				continue
			}
		} else if !c.once && kept == .Last {
			if cell_dropped(doc, keys, int(j), int(cells), kept) {
				continue
			}
		} else if !c.once && dups != .Group {
			for o in 0 ..< j {
				if doc_same_keys(doc, keys[o], k) {
					continue next
				}
			}
			if dups != .First {
				for o in j + 1 ..< cells {
					if doc_same_keys(doc, keys[o], k) {
						value = c.container + 1 + o
					}
				}
			}
		}
		c.place += 1
		return value, .Found
	}
	return NO_NODE, .Missing
}

// The key of the cell `next_child` last gave from `c`, a cursor over a table's row, which `next_child` gives `NO_NODE`
// for as the key has no node: the cursor's `keys_n` is not 0.
@(require_results)
cell_key :: proc "contextless" (r: Reader, c: Children) -> Token #no_bounds_check {
	return table_keys_at(r.doc, c.keys_lo, c.keys_n)[c.next - c.container - 2]
}
