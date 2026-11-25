package query

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"

// The query contract shared by every query frontend (`jq`, `jsonpath`) and the execution engine:
// per-source demand (what parts of each input source a program reads), serial requirements, three optional
// execution hints (`Per_Element_Split`, `Projection_Template`, `Conditional_Whole`), and `--explain` formatting.

// Caps past which a demand degrades to `.Whole` so planning and scanning stay bounded.
MAX_DEMAND_PATHS :: 64
MAX_DEMAND_NODES :: 128

// Which input source a `Source_Demand` describes.
Source_Kind :: enum u8 {
	Main,   // `.` (the main input)
	Inputs, // `input` / `inputs` (e.g. under `-n`)
	Slurp,  // each record of a slurped input array (under `-s`)
	Raw,    // raw lines (under `-R`)
}

// How much of an input source a program needs.
Demand_Mode :: enum u8 {
	None,    // source is unused
	Partial, // `demand` holds the keep-set for a partial scan
	Whole,   // the whole document is needed
}

// Why a source demand settled on `.Whole` (for `--explain`).
Whole_Reason :: enum u8 {
	None,
	Identity,       // reads `.` whole
	Dynamic_Step,   // dynamic index/slice/path cannot be bounded
	Dynamic_Call,   // unknown/recursive/opaque operation
	Analysis_Cap,   // demand exceeded path/depth/memo budget
	All_Steps_Only, // demand has only unbounded `[]` steps; building whole is cheaper
	Too_Wide,       // demand exceeded path or trie node cap
	Stream_Mode,    // `--stream` / `tostream` reads whole
	Whole_Op,       // mutation or whole-value builtin
}

// One normalized demand path kept beside the compiled `tape.Demand` for explain output and cost decisions.
// String names in `Name` steps borrow the program's memory.
Demand_Path :: struct {
	steps: []tape.Step,
	grain: tape.Grain,
	limit: int, // 0 for all answers
}

// What a program reads of one input source.
Source_Demand :: struct {
	mode:      Demand_Mode,
	demand:    tape.Demand,
	paths:     []Demand_Path,
	facts:     bool,
	reason:    Whole_Reason,
	allocator: runtime.Allocator,
}

// Why a program must run on one thread with inputs in order.
Serial :: enum u8 {
	Inputs,   // calls `input` or `inputs`
	Position, // reads `input_filename` or `input_line_number`
	Messages, // writes `debug` or `stderr`
	Halts,    // calls `halt` or `halt_error`
	Recurses, // runs `recurse(f)` or a recursive function
}

Serial_Flags :: bit_set[Serial; u8]

// Hint 1: filter over the elements of an array reached by `prefix`.
Split_Kind :: enum u8 {
	None,
	Stream,  // `.prefix[] | each`
	Collect, // `[.prefix[] | each] | tail` or `.prefix | map(each) | tail`
	Length,  // `.prefix | length` or `[.prefix[] | each] | length`
	Reduce,  // `reduce .prefix[] as $x (init; update)`
}

Per_Element_Split :: struct {
	kind:        Split_Kind,
	prefix:      []tape.Step,
	each_demand: Source_Demand,
	has_each:    bool,
	has_tail:    bool,
}

// Hint 2: output built purely from static demanded leaves.
Projection_Shape :: enum u8 {
	None,
	Single, // `.p`
	Stream, // `.p1, .p2`
	Array,  // `[.p1, .p2]`
	Object, // `{k1: .p1, k2: .p2}`
}

Projection_Field :: struct {
	key:  string, // set for `.Object`
	path: []tape.Step,
}

Projection_Template :: struct {
	shape:  Projection_Shape,
	fields: []Projection_Field,
}

// Hint 3: `select(P)` — evaluate predicate on `pred_demand` first, keep whole only when selected.
Compare_Op :: enum u8 {
	None,
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
}

Simple_Compare :: struct {
	path:    []tape.Step,
	op:      Compare_Op,
	literal: Value, // borrowed constant from the program
}

Conditional_Whole :: struct {
	active:      bool,
	pred_demand: Source_Demand,
	cmp:         Simple_Compare,
}

Hints :: struct {
	split:       Per_Element_Split,
	projection:  Projection_Template,
	conditional: Conditional_Whole,
}

Plan :: struct {
	sources:   [Source_Kind]Source_Demand,
	serial:    Serial_Flags,
	hints:     Hints,
	allocator: runtime.Allocator,
}

// Returns the broader of grains `a` and `b` (`.Whole` > `.Keys` > `.Exists`).
broader_grain :: #force_inline proc "contextless" (a, b: tape.Grain) -> tape.Grain {
	return a if u8(a) < u8(b) else b
}

// Merges two path limits (0 = unlimited wins; otherwise the larger count).
merge_limit :: #force_inline proc "contextless" (a, b: int) -> int {
	if a == 0 || b == 0 {
		return 0
	}
	return max(a, b)
}

// A whole-document demand with `reason`.
whole_demand :: proc "contextless" (facts: bool, reason: Whole_Reason) -> Source_Demand {
	return {mode = .Whole, facts = facts, reason = reason}
}

// Normalizes `paths`, applies cost rules (root whole, all-`All` steps, width caps), and compiles the
// `tape.Demand` trie in `allocator`. Copies step slices into `allocator` so the result outlives `paths`.
finalize_source_demand :: proc(paths: []Demand_Path, facts: bool, allocator := context.allocator) -> Source_Demand {
	if len(paths) == 0 {
		return {mode = .None, facts = facts, allocator = allocator}
	}
	// Deduplicate identical paths and drop any path subsumed by an unlimited `.Whole` prefix.
	kept := make([dynamic]Demand_Path, 0, len(paths), allocator)
	defer delete(kept)
	for p in paths {
		if len(p.steps) == 0 && p.grain == .Whole && p.limit == 0 {
			return whole_demand(facts, .Identity)
		}
		merged := false
		for &k in kept {
			if steps_equal(k.steps, p.steps) {
				k.grain = broader_grain(k.grain, p.grain)
				k.limit = merge_limit(k.limit, p.limit)
				merged = true
				break
			}
		}
		if !merged {
			append(&kept, p)
		}
	}
	// Subsumption pass: drop paths whose strict prefix is already kept `.Whole` with no limit.
	n := 0
	outer: for i in 0 ..< len(kept) {
		cand := kept[i]
		for j in 0 ..< len(kept) {
			if i == j {
				continue
			}
			other := kept[j]
			if other.grain == .Whole && other.limit == 0 && len(other.steps) < len(cand.steps) && steps_prefix(other.steps, cand.steps) {
				continue outer
			}
		}
		kept[n] = cand
		n += 1
	}
	norm := kept[:n]
	if len(norm) == 0 {
		return {mode = .None, facts = facts, allocator = allocator}
	}
	if len(norm) > MAX_DEMAND_PATHS {
		return whole_demand(facts, .Too_Wide)
	}
	// Cost rule: if every path consists solely of unbounded `All` steps (e.g. `.[]`, `.[][]`), building whole is cheaper.
	if all_steps_unbounded_all(norm) {
		return whole_demand(facts, .All_Steps_Only)
	}
	out_paths := make([]Demand_Path, len(norm), allocator)
	raw_steps := make([][]tape.Step, len(norm), allocator)
	grains := make([]tape.Grain, len(norm), allocator)
	limits := make([]int, len(norm), allocator)
	defer {
		delete(raw_steps, allocator)
		delete(grains, allocator)
		delete(limits, allocator)
	}
	for p, i in norm {
		cloned := slice.clone(p.steps, allocator)
		out_paths[i] = {steps = cloned, grain = p.grain, limit = p.limit}
		raw_steps[i] = cloned
		grains[i] = p.grain
		limits[i] = p.limit
	}
	d, err := tape.demand_of(raw_steps, grains, limits, facts, allocator)
	if err != nil || len(d.nodes) > MAX_DEMAND_NODES {
		tape.destroy_demand(&d)
		for p in out_paths {
			delete(p.steps, allocator)
		}
		delete(out_paths, allocator)
		return whole_demand(facts, .Too_Wide)
	}
	return {
		mode      = .Partial,
		demand    = d,
		paths     = out_paths,
		facts     = facts,
		allocator = allocator,
	}
}

destroy_source_demand :: proc(s: ^Source_Demand) {
	if s.demand.nodes != nil {
		tape.destroy_demand(&s.demand)
	}
	for p in s.paths {
		delete(p.steps, s.allocator)
	}
	delete(s.paths, s.allocator)
	s^ = {}
}

destroy_plan :: proc(p: ^Plan) {
	for &s in p.sources {
		destroy_source_demand(&s)
	}
	delete(p.hints.split.prefix, p.allocator)
	destroy_source_demand(&p.hints.split.each_demand)
	for f in p.hints.projection.fields {
		delete(f.path, p.allocator)
	}
	delete(p.hints.projection.fields, p.allocator)
	destroy_source_demand(&p.hints.conditional.pred_demand)
	delete(p.hints.conditional.cmp.path, p.allocator)
	p^ = {}
}

// Whether two step slices are identical.
steps_equal :: proc "contextless" (a, b: []tape.Step) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// Whether `prefix` is a prefix of `full`.
steps_prefix :: proc "contextless" (prefix, full: []tape.Step) -> bool {
	if len(prefix) > len(full) {
		return false
	}
	for i in 0 ..< len(prefix) {
		if prefix[i] != full[i] {
			return false
		}
	}
	return true
}

@(private = "file")
all_steps_unbounded_all :: proc "contextless" (paths: []Demand_Path) -> bool {
	for p in paths {
		if len(p.steps) == 0 || p.limit > 0 {
			return false
		}
		for s in p.steps {
			all, is_all := s.(tape.All)
			if !is_all || all.limit > 0 {
				return false
			}
		}
	}
	return true
}

// ---- `--explain` formatting

@(private = "file", rodata)
SOURCE_NAMES := [Source_Kind]string {
	.Main   = "main",
	.Inputs = "inputs",
	.Slurp  = "slurp",
	.Raw    = "raw",
}

@(private = "file", rodata)
GRAIN_NAMES := [tape.Grain]string {
	.Whole  = "whole",
	.Keys   = "keys",
	.Exists = "exists",
}

@(private = "file", rodata)
REASON_NAMES := [Whole_Reason]string {
	.None           = "",
	.Identity       = "reads whole input",
	.Dynamic_Step   = "dynamic path step",
	.Dynamic_Call   = "dynamic or recursive call",
	.Analysis_Cap   = "analysis cap reached",
	.All_Steps_Only = "all-element walk cheaper whole",
	.Too_Wide       = "demand too wide",
	.Stream_Mode    = "streaming mode",
	.Whole_Op       = "whole-value operation",
}

@(private = "file", rodata)
SERIAL_NAMES := [Serial]string {
	.Inputs   = "inputs",
	.Position = "position",
	.Messages = "messages",
	.Halts    = "halts",
	.Recurses = "recurses",
}

@(private = "file", rodata)
SPLIT_NAMES := [Split_Kind]string {
	.None    = "none",
	.Stream  = "stream",
	.Collect = "collect",
	.Length  = "length",
	.Reduce  = "reduce",
}

@(private = "file", rodata)
PROJ_NAMES := [Projection_Shape]string {
	.None   = "none",
	.Single = "single",
	.Stream = "stream",
	.Array  = "array",
	.Object = "object",
}

@(private = "file", rodata)
CMP_NAMES := [Compare_Op]string {
	.None = "",
	.Eq   = "==",
	.Ne   = "!=",
	.Lt   = "<",
	.Le   = "<=",
	.Gt   = ">",
	.Ge   = ">=",
}

// Renders `p` in human-readable form for `--explain`.
format_plan :: proc(b: ^strings.Builder, p: ^Plan) {
	for kind in Source_Kind {
		s := &p.sources[kind]
		if s.mode == .None && kind != .Main {
			continue
		}
		fmt.sbprintf(b, "source %s: ", SOURCE_NAMES[kind])
		format_source_demand(b, s)
		strings.write_byte(b, '\n')
	}
	if p.serial != {} {
		strings.write_string(b, "serial:")
		first := true
		for flag in Serial {
			if flag not_in p.serial {
				continue
			}
			strings.write_string(b, " " if first else ", ")
			strings.write_string(b, SERIAL_NAMES[flag])
			first = false
		}
		strings.write_byte(b, '\n')
	}
	if p.hints.split.kind != .None {
		sp := &p.hints.split
		fmt.sbprintf(b, "hint split (%s): ", SPLIT_NAMES[sp.kind])
		format_steps(b, sp.prefix)
		if sp.kind != .Length {
			strings.write_string(b, "[]")
		}
		if sp.each_demand.mode != .None {
			strings.write_string(b, " each=")
			format_source_demand(b, &sp.each_demand)
		}
		strings.write_byte(b, '\n')
	}
	if p.hints.projection.shape != .None {
		pr := &p.hints.projection
		fmt.sbprintf(b, "hint projection (%s):", PROJ_NAMES[pr.shape])
		for f, i in pr.fields {
			strings.write_string(b, " " if i == 0 else ", ")
			if pr.shape == .Object {
				fmt.sbprintf(b, "%s=", f.key)
			}
			format_steps(b, f.path)
		}
		strings.write_byte(b, '\n')
	}
	if p.hints.conditional.active {
		cw := &p.hints.conditional
		strings.write_string(b, "hint conditional_whole: pred=")
		format_source_demand(b, &cw.pred_demand)
		if cw.cmp.op != .None {
			strings.write_string(b, " cmp=")
			format_steps(b, cw.cmp.path)
			fmt.sbprintf(b, " %s ...", CMP_NAMES[cw.cmp.op])
		}
		strings.write_byte(b, '\n')
	}
}

format_source_demand :: proc(b: ^strings.Builder, s: ^Source_Demand) {
	switch s.mode {
	case .None:
		strings.write_string(b, "none")
	case .Whole:
		strings.write_string(b, "whole")
		if s.facts {
			strings.write_string(b, "+facts")
		}
		if s.reason != .None {
			fmt.sbprintf(b, " (%s)", REASON_NAMES[s.reason])
		}
	case .Partial:
		strings.write_string(b, "partial")
		if s.facts {
			strings.write_string(b, "+facts")
		}
		strings.write_string(b, " [")
		for path, i in s.paths {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			format_steps(b, path.steps)
			if path.grain != .Whole {
				fmt.sbprintf(b, ":%s", GRAIN_NAMES[path.grain])
			}
			if path.limit > 0 {
				fmt.sbprintf(b, "(limit=%d)", path.limit)
			}
		}
		strings.write_byte(b, ']')
	}
}

format_steps :: proc(b: ^strings.Builder, steps: []tape.Step) {
	if len(steps) == 0 {
		strings.write_byte(b, '.')
		return
	}
	for s in steps {
		switch step in s {
		case tape.Name:
			strings.write_byte(b, '.')
			strings.write_string(b, string(step))
		case tape.Index:
			fmt.sbprintf(b, "[%d]", int(step))
		case tape.All:
			if step.limit > 0 {
				fmt.sbprintf(b, "[:%d][]", step.limit)
			} else {
				strings.write_string(b, "[]")
			}
		case tape.Slice:
			if hi, has_hi := step.hi.?; has_hi {
				fmt.sbprintf(b, "[%d:%d]", step.lo, hi)
			} else {
				fmt.sbprintf(b, "[%d:]", step.lo)
			}
		case tape.Descend:
			strings.write_string(b, "..")
		}
	}
}
