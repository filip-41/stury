package jsonpath

import "base:runtime"
import "core:mem"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/query"

// Package jsonpath implements RFC 9535 JSONPath over `stury:lib/query`:
// - `ast.odin`: immutable compiled `Program`, AST nodes, error types, and arena ownership.
// - `parse.odin`: strict RFC 9535 lexer, explicit-stack parser, and §2.4 well-typedness checker.
// - `iregexp.odin`: strict RFC 9485 I-Regexp validator and translator over `stury:lib/base/regex`.
// - `plan.odin`: `query.Plan` demand analysis and Hint 1/2/3 extraction.
// - `norm_path.odin`: RFC 9535 §2.7 normalized path formatting.
// - `eval.odin`: zero-recursion explicit-stack evaluator with uncatchable taint guard and step/depth budgets.

// Compile-time options.
Compile_Options :: struct {
	// Maximum nesting depth for parser/planner frames: 0 defaults to `tape.DEFAULT_DEPTH` (10,000).
	max_depth: int,
}

Error_Kind :: enum u8 {
	None,
	Syntax,
	Type,
	Depth,
	Memory,
}

// Structured compile error with byte offset into the source query and static message.
Compile_Error :: struct {
	kind:    Error_Kind,
	offset:  int,
	message: string,
}

// RFC 9535 §2.4 expression types.
Expr_Type :: enum u8 {
	Value,
	Logical,
	Nodes,
}

// Segment kinds (child vs descendant).
Segment_Kind :: enum u8 {
	Child,
	Descendant,
}

Segment :: struct {
	kind:              Segment_Kind,
	selectors:         []Selector,
	// True when parsed as a bracketed segment with whitespace inside `[ ... ]`, which disqualifies
	// it from RFC 9535 §2.3.5.1 `singular-query` (`name-segment` / `index-segment` forbid inner S).
	has_bracket_space: bool,
	// True when parsed as `.member-name-shorthand` (always singular-eligible if `kind == .Child`).
	shorthand:         bool,
}

Selector_Kind :: enum u8 {
	Name,
	Wildcard,
	Index,
	Slice,
	Filter,
}

Selector :: struct {
	kind:      Selector_Kind,
	name:      string, // `.Name`
	index:     i64,    // `.Index`
	start:     i64,    // `.Slice`
	end:       i64,    // `.Slice`
	step:      i64,    // `.Slice` (default 1)
	has_start: bool,
	has_end:   bool,
	has_step:  bool,
	filter:    ^Expr,  // `.Filter`
}

// A query (either root `$` or relative `@` inside a filter expression).
Query_Kind :: enum u8 {
	Root,
	Relative,
}

Query :: struct {
	kind:        Query_Kind,
	segments:    []Segment,
	is_singular: bool,
}

Compare_Op :: enum u8 {
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
}

Func_Kind :: enum u8 {
	Length,
	Count,
	Match,
	Search,
	Value,
}

Expr_Kind :: enum u8 {
	Literal,
	Query,
	Or,
	And,
	Not,
	Paren,
	Compare,
	Func,
}

// Precompiled literal I-Regexp state for `match(s, "lit")` and `search(s, "lit")`.
Compiled_Pattern_State :: enum u8 {
	Dynamic, // pattern argument is not a string literal
	Valid,   // statically compiled into `compiled_re`
	Invalid, // literal is invalid I-Regexp (RFC 9535: evaluates to LogicalFalse)
}

Expr :: struct {
	kind:        Expr_Kind,
	type:        Expr_Type,
	op:          Compare_Op,             // `.Compare`
	func:        Func_Kind,              // `.Func`
	literal:     query.Value,            // `.Literal` (frozen constant, unheld or arena-backed)
	query:       Query,                  // `.Query`
	a, b:        ^Expr,                  // `.Or`, `.And`, `.Not` (`a`), `.Paren` (`a`), `.Compare` (`a`, `b`)
	args:        []^Expr,                // `.Func`
	pat_state:   Compiled_Pattern_State, // `.Func` (`.Match` / `.Search`)
	compiled_re: ^regex.Regex,           // `.Func` when `pat_state == .Valid`
}

// Immutable compiled JSONPath program. Safe to share across concurrent runs.
Program :: struct {
	arena:     mem.Dynamic_Arena,
	allocator: runtime.Allocator, // arena allocator
	backing:   runtime.Allocator, // caller allocator for freeing `Program` and `plan`
	root:      Query,
	plan:      query.Plan,
	// Heap used solely to hold any frozen big-int literal constants inside the program.
	const_heap: query.Heap,
	has_heap:   bool,
}

// Frees `prog` and all memory owned by it (AST, precompiled regexes, plan, constant literals).
destroy_program :: proc(prog: ^Program) {
	if prog == nil {
		return
	}
	backing := prog.backing
	query.destroy_plan(&prog.plan)
	if prog.has_heap {
		query.heap_destroy(&prog.const_heap)
	}
	mem.dynamic_arena_destroy(&prog.arena)
	free(prog, backing)
}

// RFC 9535 §2.3.3.1 maximum safe integer magnitude: (2^53) - 1.
MAX_SAFE_INT :: i64(9007199254740991)

// Returns the effective max depth for compilation.
@(private)
compile_depth_limit :: #force_inline proc "contextless" (opts: Compile_Options) -> int {
	return opts.max_depth if opts.max_depth > 0 else tape.DEFAULT_DEPTH
}
