// The walk tests share this harness. It holds a hook that logs every token and hashes it, the rule that picks `Skip`
// and `Stop`, a mutation of a seeded text, the json5-tests suites, and the law of `records.each`.
package walktest

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import core "../core"
import host "../host"
import records "../core/records"

// The capacity of `Log.tokens` is the most tokens a test text may hold.
MAX_TOKENS :: 1 << 14

// A `Fence` is one mapping whose last page has no access, sized for the longest text copied into it. `fence_copy`
// copies a text to end at the mapping's last readable byte, so a read past the text faults in every build, with or
// without the address sanitizer. `unfence` releases the mapping.
Fence :: struct {
	base: rawptr,
	span: uint,
	size: uint,
}

// Returns a fence with no mapping. `fence_copy` maps it for the first text.
fence_init :: proc() -> Fence {
	return {}
}

@(private)
page_size :: #force_inline proc() -> uint {
	page := uint(posix.sysconf(._PAGESIZE))
	if page == 0 {
		page = 1 << 12
	}
	return page
}

// Maps the fence with room for `n` bytes when it holds less, and marks the page after that room as no access.
@(private)
fence_reserve :: proc(f: ^Fence, n: uint) {
	page := page_size()
	span := (n + page - 1) & ~(page - 1)
	if span == 0 {
		span = page
	}
	if f.base != nil && f.span >= span {
		return
	}
	unfence(f)
	size := span + page
	base := posix.mmap(nil, size, {.READ, .WRITE}, {.ANONYMOUS, .PRIVATE})
	if base == nil || base == posix.MAP_FAILED {
		panic("walktest.fence: mmap failed")
	}
	if posix.mprotect(rawptr(uintptr(base) + uintptr(span)), page, posix.PROT_NONE) != .OK {
		posix.munmap(base, size)
		panic("walktest.fence: mprotect failed")
	}
	f^ = {base = base, span = span, size = size}
}

// Copies `src` to the end of the fence's readable pages and returns the copy. A read past the copy faults.
fence_copy :: proc(f: ^Fence, src: []u8) -> []u8 {
	fence_reserve(f, uint(len(src)))
	lo := f.span - uint(len(src))
	dst := ([^]u8)(f.base)[lo:f.span]
	copy(dst, src)
	return dst
}

// Releases the mapping a fence made.
unfence :: proc(f: ^Fence) {
	if f.base != nil {
		posix.munmap(f.base, f.size)
	}
	f^ = {}
}

// `log_hook` logs every token into `tokens`, updates `hash`, and returns the action `ask` picks from `rule`.
Log :: struct {
	tokens: [MAX_TOKENS]core.Token,
	n:      int,
	hash:   u64,
	rule:   u64,
}

log_hook :: proc "contextless" (h: ^Log, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	a := ask(h.rule, u64(h.n), t)
	h.tokens[h.n] = t
	h.n += 1
	h.hash = mix(h.hash, t)
	return s, a
}

// `log_hook`, with its state in the walk's registers. `a` is the hash, `b` the token count, `c` the rule.
regs_hook :: proc "contextless" (h: ^struct {}, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return {mix(s.a, t), s.b + 1, s.c}, ask(s.c, s.b, t)
}

// The action a hook returns on the `i`th token it sees. It is `Stop` on the token the rule's low 32 bits name, `Skip`
// on a container or key picked by the high 32 bits, and `Next` otherwise. Rule 0 always returns `Next`.
ask :: proc "contextless" (rule, i: u64, t: core.Token) -> core.Action {
	if rule == 0 {
		return .Next
	}
	if i == rule & 0xffff_ffff {
		return .Stop
	}
	if (t.kind == .Array || t.kind == .Map || t.role == .Key) && ((i + rule >> 32) * 0x9e37_79b9_7f4a_7c15) >> 62 == 0 {
		return .Skip
	}
	return .Next
}

mix :: proc "contextless" (hash: u64, t: core.Token) -> u64 {
	x := hash ~ t.lo ~ u64(t.n) << 32 ~ u64(t.kind) << 48 ~ u64(t.role) << 56 ~ u64(t.spelling) << 60
	return x * 0x100_0000_01b3 + 1
}

// Copies `src` into `out` with one random edit. A byte is replaced, deleted or inserted, or the text is cut short.
// `sharp` holds the bytes a mutation may write.
mutate :: proc(out: ^[dynamic]u8, src: []u8, sharp: string) {
	clear(out)
	append(out, ..src)
	if len(src) == 0 {
		append(out, pick(sharp))
		return
	}
	i := rand.int_max(len(src))
	switch rand.int_max(4) {
	case 0:
		out[i] = pick(sharp)
	case 1:
		ordered_remove(out, i)
	case 2:
		inject_at(out, i, pick(sharp))
	case:
		resize(out, i)
	}
}

// Returns a random byte of `s`.
pick :: proc(s: string) -> u8 {
	return s[rand.int_max(len(s))]
}

// A `Node_Want` is a node a document test expects, with its span, its `n` (a byte length, a subtree size or a child
// count), kind and role.
Node_Want :: struct {
	lo, n: u64,
	kind:  core.Kind,
	role:  core.Role,
}

// Checks a document's nodes against `want`, and that no non-container spelling reaches bit 15.
expect_nodes :: proc(t: ^testing.T, doc: ^core.Document, want: []Node_Want) -> bool {
	if !testing.expectf(t, len(doc.nodes) == len(want), "%d nodes, want %d", len(doc.nodes), len(want)) {
		return false
	}
	for w, i in want {
		n := doc.nodes[i]
		if !testing.expectf(t, n.lo == w.lo && u64(n.n) == w.n && n.kind == w.kind && n.role == w.role, "node %d: %v, want %v", i, n, w) {
			return false
		}
		// A container's spelling is its 16-bit child count, every other node stays below bit 15.
		if n.kind != .Array && n.kind != .Map && !testing.expectf(t, n.spelling < 1 << 15, "node %d spelling %d", i, n.spelling) {
			return false
		}
	}
	return true
}

// Checks every container node's span and child count against the walk's tokens for the same text. The span ends where
// the container's `End` ends, and the count is its members' count. `tokens` skips facts, as the document does. A headed
// dsv document keeps a header row the walk makes no token for, and a record keeps no `Key` node, so the token-to-node
// mapping skips both.
check_containers :: proc(t: ^testing.T, doc: ^core.Document, tokens: []core.Token) -> bool {
	Frame :: struct {
		lo:    u64,
		node:  core.Node_Index,
		count: u32,
	}
	stack: [1100]Frame
	depth := 0
	node := core.Node_Index(0)
	headed := doc.shared_keys != 0
	for tok in tokens {
		if tok.role > .Key {
			continue
		}
		if tok.kind == .End {
			if !testing.expect(t, depth > 0) {
				return false
			}
			depth -= 1
			f := stack[depth]
			hi := tok.lo + u64(tok.n)
			s := core.span(doc, f.node)
			if !testing.expectf(t, f.lo + u64(len(s)) == hi, "container %d at %d: span ends at %d, walk at %d, missing %q after %q", f.node, f.lo, f.lo + u64(len(s)), hi, doc.src[min(f.lo + u64(len(s)), u64(len(doc.src))):min(hi, u64(len(doc.src)))], s[len(s) - min(len(s), 12):]) {
				return false
			}
			if doc.nodes[f.node].spelling != core.MAX_CHILDREN {
				if !testing.expectf(t, u32(core.length(doc, f.node)) == f.count, "container %d: %d members, walk %d", f.node, core.length(doc, f.node), f.count) {
					return false
				}
			}
			continue
		}
		if headed && tok.role == .Key {
			continue
		}
		if depth > 0 && tok.role == .Value {
			stack[depth - 1].count += 1
		}
		if tok.kind == .Array || tok.kind == .Map {
			if !testing.expect(t, depth < len(stack)) {
				return false
			}
			stack[depth] = {lo = tok.lo, node = node, count = 0}
			depth += 1
		}
		node += 1
		// The root is the first token, and a headed document's next nodes are the header row and its cells.
		if headed && node == 1 {
			node += core.Node_Index(doc.nodes[doc.shared_keys].n)
		}
	}
	return testing.expectf(t, depth == 0 && node == core.Node_Index(len(doc.nodes)), "depth %d, %d nodes, doc %d", depth, node, len(doc.nodes))
}

// Checks that the two trees give container `oi` the same child count.
count_agrees :: proc(t: ^testing.T, src: []u8, oi: core.Node_Index, ours, theirs: int) -> bool {
	return testing.expectf(t, ours == theirs, "%q node %d: %d children, current tree %d", src, oi, ours, theirs)
}

// Checks that `child_at` returns every member `child_next` walks, in order, and fails past the last.
child_at_agrees :: proc(t: ^testing.T, src: []u8, ours: ^core.Document, oi: core.Node_Index) -> bool {
	it := core.children(ours, oi)
	k := 0
	for {
		want, more := core.child_next(&it)
		if !more {
			break
		}
		got, ok := core.child_at(ours, oi, k)
		if !testing.expectf(t, ok && got == want, "%q node %d child %d: %v %v, walk gives %v", src, oi, k, got, ok, want) {
			return false
		}
		k += 1
	}
	_, ok := core.child_at(ours, oi, k)
	return testing.expectf(t, !ok, "%q node %d: child %d exists", src, oi, k)
}

// `JSON_TEST_SUITE` holds the JSONTestSuite parsing files and `JSON5_TESTS` the json5-tests suites, used by the walk's
// conformance tests and by tests outside this tree.
JSON_TEST_SUITE := #load_directory("../json/test/conformance/JSONTestSuite/test_parsing")

JSON5_TESTS := [?][]runtime.Load_Directory_File {
	#load_directory("../json/test/conformance/json5-tests/arrays"),
	#load_directory("../json/test/conformance/json5-tests/comments"),
	#load_directory("../json/test/conformance/json5-tests/misc"),
	#load_directory("../json/test/conformance/json5-tests/new-lines"),
	#load_directory("../json/test/conformance/json5-tests/numbers"),
	#load_directory("../json/test/conformance/json5-tests/objects"),
	#load_directory("../json/test/conformance/json5-tests/strings"),
	#load_directory("../json/test/conformance/json5-tests/todo"),
}

// A `Fact_Model` holds a fact's node, byte, span, role and body for a round's model.
Fact_Model :: struct {
	node: core.Node_Index,
	lo:   u64,
	n:    u64,
	role: core.Role,
	body: string,
}

FACT_ROLES := [?]core.Role{.Comment, .Comment_Inline, .Comment_Foot}

// The bodies a fact round sets are `c`, `two words`, empty, one with an LF, one with a CR, one that would close a block
// comment, one that closes it without a line end, a lone `*`, the comment byte, and U+2028, which only JSON5 reads as a
// line end.
FACT_BODIES := [?]string{"c", "two words", "", "one\ntwo", "a\rb", "x\n*/", "a*/b", "*", "#", "a\xE2\x80\xA8b"}

// Whether a set, insert or removal touches `node`. With `allow_remove` set a removal is skipped, so a round can name a
// fact on a node the same list removes and check the commit's refusal.
tree_touched :: proc(doc: ^core.Document, list: ^core.Edit_List, node: core.Node_Index, allow_remove: bool) -> bool {
	for e in list.edits {
		if e.op >= .Set_Fact {
			continue
		}
		if e.op == .Insert {
			if e.node == node {
				return true
			}
			continue
		}
		if e.op == .Remove && allow_remove {
			continue
		}
		if int(e.node) >= len(doc.nodes) {
			continue
		}
		n := doc.nodes[e.node]
		span := n.n if n.kind == .Array || n.kind == .Map else 1
		if e.node <= node && node < e.node + core.Node_Index(span) {
			return true
		}
	}
	return false
}

// Whether a tree edit writes over fact `f`'s bytes. A removal takes the removed subtree and the comments on it. A set
// takes the node's own span, so a head comment before that span and an inline comment after it stay, and a comment
// inside the span goes.
tree_written :: proc(doc: ^core.Document, list: ^core.Edit_List, f: Fact_Model) -> bool {
	for e in list.edits {
		if int(e.node) >= len(doc.nodes) {
			continue
		}
		switch e.op {
		case .Remove:
			n := doc.nodes[e.node]
			span := n.n if n.kind == .Array || n.kind == .Map else 1
			if e.node <= f.node && f.node < e.node + core.Node_Index(span) {
				return true
			}
		case .Set:
			lo := doc.nodes[e.node].lo
			hi := lo + u64(len(core.span(doc, e.node)))
			if f.lo >= lo && f.lo + f.n <= hi {
				return true
			}
		case .Insert, .Set_Fact, .Remove_Fact:
		}
	}
	return false
}

// Whether `node` and every touched node are outside each other's subtrees, so neither is the other's ancestor.
nodes_disjoint :: proc(doc: ^core.Document, touched: []core.Node_Index, node: core.Node_Index) -> bool {
	for t in touched {
		nt, nn := doc.nodes[t], doc.nodes[node]
		ts := nt.n if nt.kind == .Array || nt.kind == .Map else 1
		ns := nn.n if nn.kind == .Array || nn.kind == .Map else 1
		if t <= node && node < t + core.Node_Index(ts) {
			return false
		}
		if node <= t && t < node + core.Node_Index(ns) {
			return false
		}
	}
	return true
}

// Whether `body` holds a line end a JSON line comment ends at.
@(private)
body_line_end :: proc(body: string) -> bool {
	for i in 0 ..< len(body) {
		switch body[i] {
		case '\n', '\r':
			return true
		}
		if body[i] == 0xE2 && i + 2 < len(body) && body[i+1] == 0x80 && body[i+2] | 1 == 0xA9 {
			return true
		}
	}
	return false
}

// Whether the output `read` holds a fact of `role` on `node`: the role has a slot, the output has a comment marker,
// and the body has a spelling under it. A delimited text's root comment needs a record after it in `read`, since an
// output that removed every record reads the comment as a foot. A JSON line comment ends at U+2028 or U+2029 too, so
// such a body needs the block spelling, which holds no `*/`. An inline body with `*/` and no line end is either
// spelled or dropped, so `fact_agrees` judges it by what reads back.
fact_holdable :: proc(doc: ^core.Document, node: core.Node_Index, role: core.Role, body: string, spec: u8, read: ^core.Document) -> bool {
	edit := doc.spelling.edit
	if edit == nil || edit.comment == nil {
		return false
	}
	style, _ := edit.comment(doc, spec)
	if style == .None {
		return false
	}
	table := core.is_flat(doc)
	if !table {
		if role == .Comment_Foot {
			n := doc.nodes[node]
			if node != core.ROOT && n.kind != .Array && n.kind != .Map {
				return false
			}
		}
	} else {
		if role == .Comment_Foot {
			if node != core.ROOT {
				return false
			}
		} else if role == .Comment {
			if node == core.ROOT {
				if read.shared_keys == 0 || core.length(read, core.ROOT) == 0 {
					return false
				}
			} else {
				n := doc.nodes[node]
				if n.role != .Value || (n.kind != .Array && n.kind != .Map) {
					return false
				}
			}
		} else {
			return false
		}
	}
	switch style {
	case .None:
		return false
	case .Byte:
		return !strings.contains(body, "\n") && !strings.contains(body, "\r")
	case .Line:
		return !(strings.contains(body, "*/") && (body_line_end(body) || role == .Comment_Inline))
	}
	return false
}

// Whether a named fact's body holds `*/` and no line end under a `.Line` style, so core may spell it or drop it.
@(private)
fact_either :: proc(doc: ^core.Document, e: core.Edit, spec: u8) -> bool {
	body := string(e.text)
	if !strings.contains(body, "*/") || body_line_end(body) {
		return false
	}
	edit := doc.spelling.edit
	if edit == nil || edit.comment == nil {
		return false
	}
	style, _ := edit.comment(doc, spec)
	return style == .Line
}

// Whether a fact edit names one node and role: that fact is the edit's, not the invariant's.
fact_named :: proc(list: ^core.Edit_List, node: core.Node_Index, role: core.Role) -> bool {
	for e in list.edits {
		if e.op >= .Set_Fact && e.node == node && e.role == role {
			return true
		}
	}
	return false
}

// Appends the facts `doc` reads to `out`, in source order. The body is the bytes between the lead and tail counts in
// the fact's spelling, as core's reader slices it.
fact_model :: proc(doc: ^core.Document, out: ^[dynamic]Fact_Model) {
	for f in doc.facts {
		lead := u64(f.spelling & 0xFF)
		tail := u64(f.spelling >> 8)
		body := doc.src[f.lo + lead:f.lo + u64(f.n) - tail]
		append(out, Fact_Model{node = f.node, lo = f.lo, n = u64(f.n), role = f.role, body = string(body)})
	}
}

// Whether `got` holds one fact of node, role and body, taking it from `used`.
fact_find :: proc(got: []Fact_Model, used: []bool, node: core.Node_Index, role: core.Role, body: string) -> bool {
	for g, i in got {
		if !used[i] && g.node == node && g.role == role && g.body == body {
			used[i] = true
			return true
		}
	}
	return false
}

// Whether `got` holds one fact of a body and role, taking it from `used`. A fact of the same bytes is taken first, then
// one of the same role, then one of any role.
body_find :: proc(got: []Fact_Model, used: []bool, read: ^core.Document, role: core.Role, body, full: string) -> bool {
	role_found, any_found := -1, -1
	for g, i in got {
		if used[i] || g.body != body {
			continue
		}
		if string(read.src[g.lo:g.lo + g.n]) == full {
			used[i] = true
			return true
		}
		if g.role == role && role_found < 0 {
			role_found = i
		}
		if any_found < 0 {
			any_found = i
		}
	}
	if role_found >= 0 {
		used[role_found] = true
		return true
	}
	if any_found >= 0 {
		used[any_found] = true
		return true
	}
	return false
}

// Checks the fact rule of a round's commit, over the round's own edit list. A named fact the output holds reads back on
// the node the commit maps it to, in its role, with its body. A named fact the output cannot hold is not required, and
// every such fact is one of the commit's drops. Every source fact not named and not written over reads back by its
// body, unless the output cannot hold it, which is the other kind of drop. `kept` is how many facts the round
// compared.
fact_agrees :: proc(t: ^testing.T, round: int, before: []Fact_Model, doc: ^core.Document, list: ^core.Edit_List, node_at: []core.Node_Index, read: ^core.Document, dropped: int, spec: u8) -> (ok: bool, kept: int) {
	got: [dynamic]Fact_Model
	defer delete(got)
	fact_model(read, &got)
	used := make([]bool, len(got), context.temp_allocator)
	kept = 0
	missing := 0
	expected := 0
	either_missing := 0
	for e in list.edits {
		if e.op < .Set_Fact {
			continue
		}
		node := core.NO_NODE
		if int(e.node) < len(node_at) {
			node = node_at[e.node]
		}
		if e.op == .Remove_Fact {
			continue
		}
		kept += 1
		slot := node != core.NO_NODE && fact_holdable(doc, e.node, e.role, "", spec, read)
		if slot && fact_either(doc, e, spec) {
			if !fact_find(got[:], used, node, e.role, string(e.text)) {
				either_missing += 1
			}
			continue
		}
		holdable := slot && fact_holdable(doc, e.node, e.role, string(e.text), spec, read)
		if !holdable {
			expected += 1
			continue
		}
		if node == core.NO_NODE || !fact_find(got[:], used, node, e.role, string(e.text)) {
			missing += 1
			fmt.printfln("    round %d: set fact node %d -> %d role %v body %q is not there", round, e.node, node, e.role, e.text)
		}
	}
	for f in before {
		if fact_named(list, f.node, f.role) || tree_written(doc, list, f) {
			continue
		}
		// A source root comment above a header reads as the root's foot when the commit leaves no record, which the
		// output holds.
		foot := f.role == .Comment && f.node == core.ROOT && doc.shared_keys != 0 && core.length(read, core.ROOT) == 0
		// A source fact in the document's own spec already reads under it, so only a missing slot drops it. Under
		// another spec the output must hold the whole fact, body included.
		if spec != doc.as.spec && !foot && !fact_holdable(doc, f.node, f.role, f.body, spec, read) {
			expected += 1
			continue
		}
		if spec == doc.as.spec && !foot && !fact_holdable(doc, f.node, f.role, "", spec, read) {
			expected += 1
			continue
		}
		kept += 1
		if !body_find(got[:], used, read, f.role, f.body, string(doc.src[f.lo:f.lo + f.n])) {
			missing += 1
			fmt.printfln("    round %d: source fact node %d role %v body %q went", round, f.node, f.role, f.body)
		}
	}
	// A fact an edit's text writes is new, so its read is not a source fact's.
	for g, i in got {
		if used[i] {
			continue
		}
		full := read.src[g.lo:g.lo + g.n]
		for e in list.edits {
			if (e.op == .Set || e.op == .Insert) && strings.contains(string(e.text), string(full)) {
				used[i] = true
				break
			}
		}
	}
	// A fact of a node a tree edit removes goes with the node and must not read back on any node. A fact the same
	// list names is the edit's, and a read already attributed to another fact or to an edit's text is that one's.
	for b in before {
		if !tree_written(doc, list, b) || fact_named(list, b.node, b.role) {
			continue
		}
		for g, i in got {
			if !used[i] && g.body == b.body {
				return testing.expectf(t, false, "round %d: fact of removed node %d role %v body %q reads on node %d", round, b.node, b.role, b.body, g.node), kept
			}
		}
	}
	// A removed fact must not read back on the node the commit maps it to. A read already attributed to another source
	// fact that a tree edit left in the text, or to an edit's text, is not the removed fact's. Every other read of the
	// body is.
	for e in list.edits {
		if e.op != .Remove_Fact {
			continue
		}
		node := core.NO_NODE
		if int(e.node) < len(node_at) {
			node = node_at[e.node]
		}
		for b in before {
			if b.node != e.node || b.role != e.role {
				continue
			}
			for g, i in got {
				if !used[i] && g.node == node && g.role == e.role && g.body == b.body {
					return testing.expectf(t, false, "round %d: removed fact node %d role %v body %q still reads", round, node, e.role, b.body), kept
				}
			}
		}
	}
	extra := 0
	for u in used {
		if !u {
			extra += 1
		}
	}
	if missing > 0 || extra > 0 || dropped != expected + either_missing {
		for g, i in got {
			if !used[i] {
				fmt.printfln("    unused node %d role %v body %q bytes %q", g.node, g.role, g.body, read.src[g.lo:g.lo + g.n])
			}
		}
		for g in got {
			fmt.printfln("    reads node %d role %v body %q", g.node, g.role, g.body)
		}
		for b in before {
			fmt.printfln("    source node %d role %v body %q", b.node, b.role, b.body)
		}
		return testing.expectf(t, false, "round %d: %d facts went of %d, %d extra, dropped %d, expected %d + %d either", round, missing, kept, extra, dropped, expected, either_missing), kept
	}
	return true, kept
}

// Checks that `doc` holds one fact of `role` on `node` with body `want`.
body :: proc(t: ^testing.T, doc: ^core.Document, node: core.Node_Index, role: core.Role, want: string) -> bool {
	it := core.facts_of(doc, node, role)
	got, ok := core.fact_next(&it)
	if !testing.expectf(t, ok && string(got) == want, "node %d role %v: %q, want %q", node, role, got, want) {
		return false
	}
	if _, more := core.fact_next(&it); !testing.expectf(t, !more, "node %d role %v holds more than one fact", node, role) {
		return false
	}
	return true
}

// `Failing_Alloc` counts allocations and forwards each call to `inner`. It returns `.Out_Of_Memory` on the
// allocation numbered `fail_at`, counting from 0, on every later one while `fail_on` is set, and on every allocation
// while `fail_all` is set. A `fail_at` of -1 fails none.
Failing_Alloc :: struct {
	inner:    runtime.Allocator,
	n:        int,
	fail_at:  int,
	fail_all: bool,
	fail_on:  bool,
}

@(private)
failing_alloc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	f := (^Failing_Alloc)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if f.fail_all || f.n == f.fail_at || (f.fail_on && f.fail_at >= 0 && f.n > f.fail_at) {
			f.n += 1
			return nil, .Out_Of_Memory
		}
		f.n += 1
	case .Free, .Free_All, .Query_Features, .Query_Info:
	}
	return f.inner.procedure(f.inner.data, mode, size, alignment, old_memory, old_size, loc)
}

// Returns the allocator `f` describes.
failing_allocator :: proc(f: ^Failing_Alloc) -> runtime.Allocator {
	return {procedure = failing_alloc, data = f}
}

// A write `sweep_write` runs: the text under `allocator`, or why it has none.
Write_Try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind)

// Fails each allocation of a write in turn, then that one and every later one, on the output's allocator and on
// `context.allocator`. A write gives `want` or `.Out_Of_Memory`, whatever fails, and the test's tracker sees a leak.
sweep_write :: proc(t: ^testing.T, try: Write_Try, data: rawptr, want: string, loc := #caller_location) {
	for on_context in ([?]bool{false, true}) {
		for hold in ([?]bool{false, true}) {
			for at := 0;; at += 1 {
				f := Failing_Alloc{inner = context.allocator, fail_at = at, fail_on = hold}
				text: []u8
				kind: core.Typed_Error_Kind
				if on_context {
					inner := context.allocator
					context.allocator = failing_allocator(&f)
					text, kind = try(data, inner)
				} else {
					text, kind = try(data, failing_allocator(&f))
				}
				fine := kind == .Out_Of_Memory && len(text) == 0 || kind == .None && string(text) == want
				testing.expectf(t, fine, "allocation %d, later ones too %v, on the context %v: %v %q", at, hold, on_context, kind, text, loc = loc)
				delete(text)
				if f.n <= at {
					break
				}
			}
		}
	}
}

// Reads `src` as a built document under the spec a caller passes as `spec`.
Build :: proc(src: []u8, spec: any) -> (core.Document, core.Document_Error)

// Commits `list`, checks the output against `want`, then builds the output with `build` and `spec`.
expect_commit :: proc(t: ^testing.T, list: ^core.Edit_List, want: string, build: Build, spec: any) -> bool {
	out, _, err := core.commit(list)
	defer if len(out) > 0 {
		delete(out)
	}
	if !testing.expectf(t, err.kind == .None, "commit: %v", err) {
		return false
	}
	if !testing.expectf(t, string(out) == want, "committed %q, want %q", string(out), want) {
		return false
	}
	doc, derr := build(out, spec)
	defer core.destroy(&doc)
	return testing.expectf(t, derr.kind == .None, "committed text does not read: %v", derr)
}

// Builds `src` with `build` and `spec`, records `edit` on a list over it, and checks the committed text against `want`.
check :: proc(t: ^testing.T, src, want: string, build: Build, spec: any, edit: proc(list: ^core.Edit_List) -> core.Document_Error) -> bool {
	doc, err := build(transmute([]u8)src, spec)
	defer core.destroy(&doc)
	if !testing.expectf(t, err.kind == .None, "%q: %v", src, err) {
		return false
	}
	list := core.edit_list_init(&doc)
	defer core.edit_list_destroy(&list)
	if e := edit(&list); !testing.expectf(t, e.kind == .None, "%q: record %v", src, e) {
		return false
	}
	return expect_commit(t, &list, want, build, spec)
}

// `each` on each pool gives the records `next` gives, each once and in piece order, up to and with the piece the first
// fault ends, and that fault.
expect_each_law :: proc(t: ^testing.T, pools: []host.Pool, src: []u8, as: core.As, framing: core.Framing, at: u64 = 0) -> bool {
	it := records.open(src, as, framing, at, context.temp_allocator)
	want := make([dynamic][2]u64, context.temp_allocator)
	for rec in records.next(&it) {
		append(&want, [2]u64{rec.at, u64(len(rec.text))})
	}
	fault := it.fault
	records.close(&it)
	Piece :: struct {
		k:      int,
		ended:  bool,
		recs:   [dynamic][2]u64,
	}
	Got :: struct {
		lock:   sync.Mutex,
		pieces: [dynamic]Piece,
	}
	collect :: proc(g: ^Got, piece: ^records.Reader, k: int) -> bool {
		p := Piece{k = k, recs = make([dynamic][2]u64, runtime.heap_allocator())}
		for rec in records.next(piece) {
			append(&p.recs, [2]u64{rec.at, u64(len(rec.text))})
		}
		p.ended = piece.fault != nil
		sync.guard(&g.lock)
		append(&g.pieces, p)
		return true
	}
	for &pool in pools {
		g := Got{pieces = make([dynamic]Piece, runtime.heap_allocator())}
		f := records.each(src, as, framing, collect, &g, &pool.runner, at)
		slice.sort_by(g.pieces[:], proc(a, b: Piece) -> bool { return a.k < b.k })
		got := make([dynamic][2]u64, context.temp_allocator)
		ended, unique := false, true
		for p, i in g.pieces {
			unique &&= i == 0 || p.k != g.pieces[i - 1].k
			if !ended {
				append(&got, ..p.recs[:])
				ended = p.ended
			}
			delete(p.recs)
		}
		delete(g.pieces)
		if !testing.expectf(t, unique && f == fault && slice.equal(got[:], want[:]), "%v %q at width %d: each %v %v, want %v %v", framing, src, pool.runner.threads + 1, got, f, want, fault) {
			return false
		}
	}
	return true
}
