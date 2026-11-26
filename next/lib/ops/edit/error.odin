package edit

import "base:runtime"
import "stury:lib/core/tape"

// Errors, refusal groups, commit options, and splice descriptors for `lib/ops/edit`.
//
// Refusals are classified into three explicit groups (matching `analysis.md` §1):
// 1. `Format_Impossible`: impossible in the target format — always refused, even under `Options.reflow = true`.
// 2. `Layout_Conflict`: layout the local splicer cannot preserve byte-locally — accepted by default wherever the
//    v2 format-family composers can express it (multi-range members, TOML sections before top-level lines, comments
//    in multi-item flow lines, neighbour style inheritance); any remaining case is refused unless `Options.reflow`
//    is enabled, in which case the smallest enclosing container is rewritten and reported in `Commit_Result.rewritten`.
// 3. `Alias_Unshare`: edits through aliases/merge keys (reserved for YAML in Phase 2C); runs only under `Options.reflow`.

Refusal_Group :: enum u8 {
	Format_Impossible,
	Layout_Conflict,
	Alias_Unshare,
}

Refusal_Kind :: enum u8 {
	None,
	// Group 1: Format_Impossible (never bypassed by `Options.reflow`).
	No_Document,
	Partial_Document,
	Bad_Handle,
	Bad_Path,
	Wrong_Container,
	Bad_Position,
	Bad_Order,
	Bad_Xml_Comment,
	Bad_Name,
	Void_Content,
	Root_Shape,
	Empty_Markup_Array,
	Nested_Markup_Array,
	Text_Markup,
	Fact_No_Place,
	Unspellable_Value,
	Invalid_Result,
	// Group 2: Layout_Conflict (accepted under `Options.reflow = true`).
	Layout_Reflow_Needed,
	// Group 3: Alias_Unshare (accepted under `Options.reflow = true`).
	Alias_Edit_Requires_Reflow,
}

// Structured edit refusal with its group, optional source byte offset, optional base node, and detail message.
Refusal :: struct {
	kind:   Refusal_Kind,
	group:  Refusal_Group,
	at:     u64,
	node:   tape.Node_Index,
	detail: string,
}

// The error of any overlay mutation or commit call.
Error :: union {
	Refusal,
	tape.Fault,
	tape.Exceeded,
	tape.Bad_Option,
	runtime.Allocator_Error,
}

// Returns the refusal group of `kind`.
refusal_group :: proc "contextless" (kind: Refusal_Kind) -> Refusal_Group {
	#partial switch kind {
	case .Layout_Reflow_Needed:
		return .Layout_Conflict
	case .Alias_Edit_Requires_Reflow:
		return .Alias_Unshare
	}
	return .Format_Impossible
}

// Constructs a `Refusal` error with its canonical group.
refuse :: proc "contextless" (kind: Refusal_Kind, detail := "", node := tape.NO_NODE, at := tape.NO_BYTE) -> Error {
	return Refusal {
		kind   = kind,
		group  = refusal_group(kind),
		at     = at,
		node   = node,
		detail = detail,
	}
}

// A half-open byte range `[lo, hi)` in source or output bytes.
Byte_Range :: struct {
	lo, hi: u64,
}

// Options controlling how an overlay is committed to bytes or a spliced `tape.Document`.
Options :: struct {
	// Opt-in flag (`--reflow`): when a layout cannot be expressed byte-locally, rewrite only the smallest enclosing
	// value in the target format's normal layout while keeping every byte outside byte-exact, and report the rewritten
	// output ranges in `Commit_Result.rewritten`. Group 1 refusals remain refused even when `reflow` is true.
	reflow: bool,
	// Target format handle when committing to a sibling spec (e.g., JSON -> JSONC or JSON5). Nil uses `base.format`.
	target: ^tape.Format,
	// Default indentation width for reflowed or newly inserted multiline values when no neighbour shows one (0 => 2).
	indent: u8,
	// Use tabs instead of spaces when no neighbour shows indentation.
	tab:    bool,
	// When true, `commit_document` marks the returned document `.Owns_Src` and takes ownership of `Commit_Result.bytes`
	// so `tape.destroy_document` frees it (and `Commit_Result.bytes` borrows `doc.src`).
	own_src: bool,
	// Resource budget applied to spliced fragment parsing and full rebuilds in `commit_document` / `splice_document`.
	budget:  tape.Budget,
}

// One spliced region produced by a composer, mapping a replaced base node/range to its new byte range in `bytes`.
// Used by `commit_document` (`walk_fragment` incremental tape splice) to re-walk only the modified bytes.
Splice_Record :: struct {
	base_node:     tape.Node_Index, // base node replaced (or container whose child was inserted/deleted)
	src_lo:        u64,             // start byte in `base.src`
	src_hi:        u64,             // end byte in `base.src`
	dst_lo:        u64,             // start byte in `Commit_Result.bytes`
	dst_hi:        u64,             // end byte in `Commit_Result.bytes`
	// True when the edit replaces the single subtree `base_node` in place with a single value (including same-node
	// fact edits that stay within its value range). False when structural container edits (insert/delete/reorder)
	// changed the parent container, in which case `base_node` is that enclosing container to re-walk.
	subtree_only:  bool,
	// True when the splice can be re-walked incrementally in context; false forces full rebuild for safety
	// (e.g., XML DTD/xmlns mutation or TOML cross-section structural move).
	full_rewalk:   bool,
}

// Output of `commit`: the edited bytes, dropped fact kinds, any reflow-rewritten output ranges, and splice records
// for incremental tape splicing.
Commit_Result :: struct {
	bytes:     []u8,
	dropped:   tape.Facts,
	rewritten: []Byte_Range,
	splices:   []Splice_Record,
	allocator: runtime.Allocator,
}

// Frees all buffers owned by `res` and zeroes it.
destroy_commit_result :: proc(res: ^Commit_Result) {
	if res.bytes != nil {
		delete(res.bytes, res.allocator)
	}
	if res.rewritten != nil {
		delete(res.rewritten, res.allocator)
	}
	if res.splices != nil {
		delete(res.splices, res.allocator)
	}
	res^ = {}
}

// Context passed to a format's `walk_fragment` callback so it can re-walk a single spliced byte range in place.
Fragment_Context :: struct {
	base:       ^tape.Document, // original immutable document (for DTD, scopes, header keys, format options)
	base_node:  tape.Node_Index, // node being replaced (or enclosing container)
	base_depth: u32,             // open container depth strictly above `base_node`
	budget:     tape.Budget,     // effective budget propagated from `Options.budget`
}

// The mini-tape produced by a format's `walk_fragment` callback for one edited byte range.
// Node offsets (`Node.lo`, `Fact.lo`) are already absolute byte offsets into the new `src` buffer.
// `Fact.node` and `Child_Count.node` are relative to `nodes[0]` (0-based within this fragment).
Fragment_Tape :: struct {
	nodes:      []tape.Node,
	facts:      []tape.Fact,
	counts:     []tape.Child_Count,
	present:    tape.Facts,
	root_close: u64,
	// Optional full replacement document when a format cannot splice incrementally (e.g., XML DTD/xmlns change).
	full_doc:   Maybe(tape.Document),
	allocator:  runtime.Allocator,
}

destroy_fragment_tape :: proc(ft: ^Fragment_Tape) {
	if ft.nodes != nil {
		delete(ft.nodes, ft.allocator)
	}
	if ft.facts != nil {
		delete(ft.facts, ft.allocator)
	}
	if ft.counts != nil {
		delete(ft.counts, ft.allocator)
	}
	if doc, ok := &ft.full_doc.?; ok {
		tape.destroy_document(doc)
	}
	ft^ = {}
}

// Format-supplied callback that walks ONLY `src[range.lo:range.hi]` in `ctx` and produces a `Fragment_Tape`.
Fragment_Walker :: #type proc(
	data: rawptr,
	src: []u8,
	range: Byte_Range,
	ctx: Fragment_Context,
	allocator: runtime.Allocator,
) -> (Fragment_Tape, tape.Error)

// Format-supplied fallback full builder used when a splice has `full_rewalk = true` or changes the root.
Full_Builder :: #type proc(
	data: rawptr,
	src: []u8,
	allocator: runtime.Allocator,
) -> (tape.Document, tape.Error)
