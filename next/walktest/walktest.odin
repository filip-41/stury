// The harness the walk tests share, a hook that logs every token and hashes it, the rule that picks Skip and Stop, a
// mutation of a seeded text, and the json5-tests suites.
package walktest

import "base:runtime"
import "core:math/rand"
import "core:testing"
import core "../core"

// The capacity of `Log.tokens`, the most tokens a test text may hold.
MAX_TOKENS :: 1 << 14

// A hook that logs every token into `tokens`, updates `hash`, and returns the action `ask` picks from `rule`.
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

// `log_hook` with its state in the walk's registers. `a` is the hash, `b` the token count, `c` the rule.
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

// A random byte of `s`.
pick :: proc(s: string) -> u8 {
	return s[rand.int_max(len(s))]
}

// A node a document test expects, with its span, its `n` (a byte length, a subtree size or a child count), kind and
// role.
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
		node:  u32,
		count: u32,
	}
	stack: [1100]Frame
	depth := 0
	node := u32(0)
	headed := doc.header != 0
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
			if doc.nodes[f.node].spelling != core.CHILDREN_MAX {
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
			node += u32(doc.nodes[doc.header].n)
		}
	}
	return testing.expectf(t, depth == 0 && node == u32(len(doc.nodes)), "depth %d, %d nodes, doc %d", depth, node, len(doc.nodes))
}

// Checks that the two trees give container `oi` the same child count.
count_agrees :: proc(t: ^testing.T, src: []u8, oi: u32, ours, theirs: int) -> bool {
	return testing.expectf(t, ours == theirs, "%q node %d: %d children, current tree %d", src, oi, ours, theirs)
}

// Checks that `child_at` returns every member `child_next` walks, in order, and fails past the last.
child_at_agrees :: proc(t: ^testing.T, src: []u8, ours: ^core.Document, oi: u32) -> bool {
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

// The json5-tests suites, used by the walk's conformance test and by its oracle.
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

// A fact a round's model holds, with its node, its byte, its role and its body.
Fact_Model :: struct {
	node: u32,
	lo:   u64,
	role: core.Role,
	body: string,
}

FACT_ROLES := [?]core.Role{.Comment, .Comment_Inline, .Comment_Foot}

// The bodies a fact round sets are `c`, `two words`, empty, one with an LF, one with a CR, one that would close a block
// comment, a lone `*`, the comment byte, and U+2028, which only JSON5 reads as a line end.
FACT_BODIES := [?]string{"c", "two words", "", "one\ntwo", "a\rb", "x\n*/", "*", "#", "a\xE2\x80\xA8b"}

// Whether a node edit writes over `node`. A set or a removal replaces the whole subtree, and an insert names the
// container it joins. A fact on that node is replaced with the bytes the edit writes and is no part of the invariant.
tree_touched :: proc(doc: ^core.Document, list: ^core.Edit_List, node: u32) -> bool {
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
		if int(e.node) >= len(doc.nodes) {
			continue
		}
		n := doc.nodes[e.node]
		span := n.n if n.kind == .Array || n.kind == .Map else 1
		if e.node <= node && node < e.node + span {
			return true
		}
	}
	return false
}

// The first byte of the line holding `pos`, and one past its last byte before the CR or LF.
line_span :: proc(src: []u8, pos: u64) -> (lo, hi: u64) {
	lo, hi = pos, pos
	for lo > 0 && src[lo-1] != '\n' && src[lo-1] != '\r' {
		lo -= 1
	}
	for hi < u64(len(src)) && src[hi] != '\n' && src[hi] != '\r' {
		hi += 1
	}
	return
}

// Whether an edit writes over a fact or a comment on its line. A comment's role depends on the line it is on, so a
// fact edit beside another comment on that line can change that comment's role, and the round does not hold such a
// fact.
fact_touched :: proc(doc: ^core.Document, list: ^core.Edit_List, node: u32, lo: u64) -> bool {
	if tree_touched(doc, list, node) {
		return true
	}
	from, to := line_span(doc.src, lo)
	for e in list.edits {
		if e.op < .Set_Fact {
			continue
		}
		for f in doc.facts {
			if f.node != e.node || f.role != e.role {
				continue
			}
			// A block comment can start on an earlier line and span the target's line.
			if f.lo <= to && from <= f.lo + u64(f.n) {
				return true
			}
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
		append(out, Fact_Model{node = f.node, lo = f.lo, role = f.role, body = string(body)})
	}
}

// Removes every entry of `out` with `node` and `role`. A set replaces those facts and a removal drops them.
fact_model_take :: proc(out: ^[dynamic]Fact_Model, node: u32, role: core.Role) {
	for i := len(out) - 1; i >= 0; i -= 1 {
		if out[i].node == node && out[i].role == role {
			copy(out[i:], out[i+1:])
			pop(out)
		}
	}
}

// Records a set of `body` on `node` and `role` in the model. Removes the entries it replaces, then appends one. A body
// holding a line end is written as one block spelling.
fact_model_set :: proc(out: ^[dynamic]Fact_Model, node: u32, role: core.Role, body: string) {
	fact_model_take(out, node, role)
	append(out, Fact_Model{node = node, role = role, body = body})
}

// Checks that the facts the committed text reads match the model as a multiset of node, role and body.
fact_model_agrees :: proc(t: ^testing.T, round: int, model: []Fact_Model, doc: ^core.Document) -> bool {
	got: [dynamic]Fact_Model
	defer delete(got)
	fact_model(doc, &got)
	if len(model) != len(got) {
		testing.expectf(t, false, "round %d: %d facts, want %d", round, len(got), len(model))
		return false
	}
	used := make([]bool, len(got), context.temp_allocator)
	for m in model {
		found := false
		for g, i in got {
			if !used[i] && g.node == m.node && g.role == m.role && g.body == m.body {
				used[i] = true
				found = true
				break
			}
		}
		if !found {
			return testing.expectf(t, false, "round %d: fact node %d role %v body %q is missing", round, m.node, m.role, m.body)
		}
	}
	return true
}
