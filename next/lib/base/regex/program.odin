// Package regex is the engine behind jq's `test`, `match`, `sub` and the like, in Oniguruma's syntax, and behind a
// schema's `pattern`, in ECMA-262's (`Flags.ecma`). A pattern passes through these files in order:
// - parse.odin (`parse`): source to a tree of Nodes (tree.odin), with Oniguruma's error messages. It uses escape.odin,
//   class.odin, callout.odin and refs.odin.
// - call.odin (`check_calls`): checks \g<...> calls for endless recursion.
// - look_behind.odin: makes a look-behind a fixed length.
// - compile.odin (`compile`): the tree to a Regex holding a program of Insts (program.odin).
// - optimize.odin: Oniguruma's search optimizer and the literals a search can skip by.
// - dfa.odin, dfa_build.odin and dfa_alphabet.odin: automata that answer in one pass whether and where a program
//   matches.
// - match.odin (`search`): the backtracking matcher over the program, with visited.odin for the linear search. It
//   reads \X clusters through grapheme.odin. counting.odin answers whether an ECMA program with counted repeats
//   matches, where the automata do not.
// sample.odin draws a text a pattern matches. unicode.odin and fold.odin supply character classes and case folds,
// from the generated unicode_tables.odin.
//
// The package reaches no OS and keeps no state of its own: every allocation comes from an allocator the caller passes
// (`compile`, `refusal`, `sample`, `scratch_make`), and a failed allocation comes back as an `Error` of kind `.Memory`.
// A search takes the work it may do as `steps`, and keeps to the engine's own limits when the caller gives none. Its
// memory limits are fixed. The caller maps its own budget onto `steps`: it refuses a spent budget itself and passes
// what is left.
package regex

// The most memory, in bytes, that a program may take, and that a linear search's visited sets, backtrack stack and log
// take together. Short counted repeats are written out, so many of them would otherwise take unbounded memory.
// Oniguruma has no such limit.
@(private)
MAX_BYTES :: 1 << 28 when size_of(int) == 8 else 1 << 26

@(private)
MEMORY_ERROR :: "fail to memory allocation"

// The grammar of a pattern: Oniguruma's, as jq reads it, or ECMA-262's with the `u` flag, as a JSON Schema `pattern`.
Syntax :: enum u8 {
	Oniguruma,
	Ecma,
}

// The pattern's options under Oniguruma's syntax: jq's `i`, `x` and `s` flags. `longest` and `not_empty` change only
// the search: ONIG_OPTION_FIND_LONGEST takes the longest match of all, not the first, and ONIG_OPTION_FIND_NOT_EMPTY
// takes no empty match. ECMA-262's syntax takes none, and `compile` refuses them with it.
Flags :: struct {
	fold, extend, dotall, multiline, longest, not_empty: bool,
}

// What the parser reads: the flags in force and the syntax.
@(private)
Options :: struct {
	using flags: Flags,
	ecma:        bool,
}

// Why a compile or a search gave up. `Syntax` is a pattern Oniguruma refuses. `Steps` is the caller's step limit, or
// the engine's own limit on a search's work when the caller gave none. `Memory` is a failed allocation or a cap on what
// a compile or search may hold. `Callout` is an error that a pattern's callout ends the search with. `message` is
// Oniguruma's.
Error_Kind :: enum u8 {
	None,
	Syntax,
	Steps,
	Memory,
	Callout,
}

Error :: struct {
	kind:    Error_Kind,
	message: string,
}

// A search past the caller's `steps` or past a backtrack limit, the message Oniguruma gives for its retry limit.
@(private)
STEPS_OUT :: Error{.Steps, "retry-limit-in-match over"}
// A linear search past the engine's own limit on its work, which the caller gave no `steps` to replace.
@(private)
BUDGET_OUT :: Error{.Steps, "search work limit over"}
@(private)
MEMORY_OUT :: Error{.Memory, MEMORY_ERROR}

@(private)
Op :: enum u32 {
	Match,
	Str, // the literal bytes[a:][:b]
	Char_Fold, // a rune whose fold is a
	Any, // any rune but "\n"
	Any_All,
	Class, // classes[a]
	Split, // go on at a, on failure at b
	// a greedy loop: go on at pc+1 with b to fall back to when the byte at the position is a, otherwise at b
	Split_Head,
	Jmp, // to a
	Save, // slot a = the position (captures, loop marks, and \K as slot 0). b: a group's start, which unsets its end
	Set, // slot a = the position, kept as the match backs past it: a group's bound Oniguruma writes in place
	Assert, // Assert_Kind(a). A callout's data at callouts[b]
	Backref, // the text of one of refs[a]'s groups. b: folded, or under ECMA read leftwards
	Look, // a look-around or atomic group, Look_Kind(a), ending at the Look_End at b
	Look_End,
	Back, // a runes back, for a look-behind
	Check, // a loop's body matched empty when slot a is the position: leave the loop, for b, or fail for b -1
	Unset, // slots a up to b = -1: the groups of an ECMA loop's body, at each iteration
	Cond, // group a matched: go on, otherwise go to b
	Linebreak, // \R
	Grapheme, // \X
	Rep, // the one-rune instruction after this, a to b times (b -1: no bound), as many as can, then pc+2
	Rep_Lazy, // the same, as few as can
	Count_Reset, // slot a, a counted loop's iterations, = 0
	// a counted loop at slot a: its body at pc+2 runs while slot a is short of insts[pc+1].a, may run while short of
	// insts[pc+1].b, as many times as can, then on to b
	Count,
	Count_Lazy, // the same, as few times as can
	Count_Next, // slot a += 1, then to the loop's Count at b
	Count_Check, // as Check under ECMA, failing only once the loop whose Count is at b has run its least count
	// Call and the ops after it are a call's or an absent operator's, which `Regex.calls_or_limits` tells of.
	Call, // the group at a, which returns to pc+1. b: its number
	Return,
	Mem_Start, // group a's start, in a group that calls itself, whose end finds the start of its own call
	Mem_End,
	Limit_Save, // slot a = the text's end as matched against (an absent's limit), restored when the match backs past
	Limit_Cut, // the limit = slot a, kept as the match backs within the absent
	Limit_Restore, // the limit = slot a
	Limit_Clear, // the limit = the text's end
}

@(private)
Inst :: struct {
	op:   Op,
	a, b: i32,
}
#assert(size_of(Inst) == 12)

// A compiled pattern, which `search` runs.
Regex :: struct {
	dfa:             ^Dfa, // the automaton that answers a search that reads no bounds, or nil (dfa.odin)
	// under ECMA, the counted repeats a search that reads no bounds follows in one pass, or nil (counting.odin)
	counting:        ^Counting,
	// what Oniguruma's optimizer would have the search skip by, kept apart since a Regex is copied
	opt:             ^Search_Opt,
	// What every match starts with, at distance 0: the literal it begins with, or one of the bytes it can begin with.
	head:            ^Search_Opt,
	visited:         ^Visited, // under `linear`, what the visited set needs of the program
	insts:           []Inst,
	ecma:            bool, // compiled under `Syntax.Ecma`, whose search refuses a text too long for the visited set
	// A program with choices whose outcome at an instruction and a position does not depend on the way there: the
	// search keeps the pairs it has been to, so no pair runs twice. The ECMA programs `linear_ops` allows, and the jq
	// ones.
	linear:          bool,
	narrowed:        bool, // `opt` bounds the starts the search tries
	longest:         bool, // Flags.longest
	not_empty:       bool, // Flags.not_empty
	calls_or_limits: bool, // holds a subexpression call or an absent operator, whose tracking the match then runs
	bytes:           string,
	classes:         []^Class,
	refs:            [][]int,
	callouts:        []^Callout, // those that keep data, each at its index
	names:           []string, // group n's name at n, "" for none. Index 0 is the whole match
	slots:           int, // two per group with the whole match, then a mark per loop that can match empty
}

// Each group's name at its number, "" for a group with none. The whole match is group 0.
group_names :: proc "contextless" (re: ^Regex) -> []string {
	return re.names
}
