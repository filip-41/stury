package jq

// jq 1.8.2's language over the library's values. An interpreter runs on one thread at a time and shares nothing with
// another, and `clone` copies one for another thread.
//
//	ip: jq.Interp
//	jq.init(&ip, {})
//	defer jq.destroy(&ip)
//	prog, errors := jq.compile(&ip, ".[] | .name") // in context.allocator, for as long as it runs
//	values: virtual.Arena // what a run makes, emptied between inputs
//	defer virtual.arena_destroy(&values)
//	if errors == nil {
//		context.allocator = jq.run_allocator(&values)
//		print := jq.Sink{emit = proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {
//			fmt.println(jq.to_json(it.v))
//			return .Go
//		}}
//		jq.run(&ip, prog, input, &print) // .Done, or .Raised with ip.err, or .Halted with ip.halted
//	}

import "base:runtime"
import "core:mem/virtual"
import core_pkg "../core"

// What an interpreter is given before it compiles: its hooks, the module search list (nil for jq's default:
// `~/.jq`, `$ORIGIN/../lib/jq`, `$ORIGIN/../lib`), the filter file it came from ("" for none), which sets
// `get_prog_origin` and where relative module paths start, the path the program was run by, whose directory `$ORIGIN`
// names, the name its messages carry, how `fromjson` and data files read a text, and how `debug` prints.
Options :: struct {
	hooks:      Hooks,
	search:     []string,
	file:       string,
	executable: string,
	name:       string,
	reading:    core_pkg.As,
	debug:      Layout,
}

// A compiled filter: its checked body, the scope it starts in (the prelude, the modules and the variables), its text,
// the variables it was compiled with, and its `$ENV` once a run reads it.
Program :: struct {
	body:    ^Node,
	globals: ^Env,
	text:    string,
	vars:    []Var,
	env:     ^Program_Env,
}

// `$name`, bound to `value` in a program.
Var :: struct {
	name:  string,
	value: core_pkg.Value,
}

// Why a filter did not compile, as jq tells it:
//	Filter     the filter's own syntax or an undefined name, `msg` located in its text
//	Empty      a filter that only defines functions
//	Module     a module not found, or a cycle of imports
//	Data_File  a data file that does not read, at `path`
//	Library    a module that does not parse, or is not only definitions, `msg` located in its text
Compile_Fault :: enum u8 {
	Filter,
	Empty,
	Module,
	Data_File,
	Library,
}

// One of the errors of a filter that does not compile. jq counts every error but those it marks `uncounted`: the
// errors before a module not found, or a cycle of imports, in the same list of imports.
Error :: struct {
	fault:     Compile_Fault,
	path:      string,
	msg:       string,
	uncounted: bool,
}

// How a run ended: every output given (`Done`), an error raised (`Raised`: `Interp.err` holds it), or `halt` or
// `halt_error` (`Halted`: `Interp.halted` holds the exit code).
Outcome :: enum u8 {
	Done,
	Raised,
	Halted,
}

init :: proc(ip: ^Interp, opts: Options) {
	ip^ = {
		hooks        = opts.hooks,
		search_list  = opts.search,
		executable   = opts.executable,
		name         = opts.name if opts.name != "" else "jq",
		reading      = opts.reading,
		debug_layout = opts.debug,
	}
	if opts.file != "" {
		ip.prog_origin = real_path(ip, dir_name(opts.file))
	}
}

// The filter `text` compiled with the variables `vars` and `$ARGS` bound to `args` (nil for
// `{"positional": [], "named": {}}`), or its errors. The program lives in `context.allocator`, as does the `$ENV` a
// run of it makes, and the errors in it or in `context.temp_allocator`: the program must outlive each of its runs,
// and the outputs that hold its literals or `$ENV`.
compile :: proc(ip: ^Interp, text: string, vars: []Var = nil, args: core_pkg.Value = nil) -> (prog: Program, errors: []Error) {
	parsed, faults := parse(text)
	if len(faults) > 0 {
		return {}, filter_errors(text, faults)
	}
	if parsed.body == nil {
		errors = make([]Error, 1)
		errors[0] = {.Empty, "", `Top-level program not given (try ".")`, false}
		return {}, errors
	}
	linked: Linked
	if len(parsed.deps) > 0 || home_module(ip) {
		linked = link(ip, parsed.deps, program_origin(ip))
		if len(linked.errors) > 0 {
			return {}, linked.errors
		}
	}
	ip.builtins = builtin_table()
	body, check_errors, prelude := check(ip.builtins, parsed.body, vars, linked)
	if len(check_errors) > 0 {
		return {}, filter_errors(text, check_errors)
	}
	globals := prelude
	for v in vars {
		globals = bind_var(ip, globals, v.name, v.value)
	}
	args := args
	if args == nil {
		o := core_pkg.new_object()
		core_pkg.object_put(o, "positional", core_pkg.new_array())
		core_pkg.object_put(o, "named", core_pkg.new_object())
		args = o
	}
	globals = bind_var(ip, globals, "ARGS", args)
	// A module sees the variables, never its importer's.
	for lib in linked.libs {
		if lib.bottom != nil {
			lib.bottom.parent = globals
		}
	}
	globals = bind_data(globals, linked.imports)
	return {body, globals, text, vars, new_clone(Program_Env{memory = context.allocator})}, nil
}

// `prog` on `input`, each output given to `out`. With `transient`, `out` keeps no output once its `emit` returns, so
// what made one is emptied then. The values a run makes are in `context.allocator`, which the caller empties between
// inputs: a `run_allocator`, for the run to give back what it no longer needs as it goes. The messages of the errors
// it raises are in the interpreter's own arenas. The `debug`, `stderr` and
// `halt_error` text goes to the messages hook as it is written: a caller that wants it held buffers it there.
run :: proc(ip: ^Interp, prog: Program, input: core_pkg.Value, out: ^Sink, transient := false) -> Outcome {
	ip.halted, ip.brk = nil, NO_LABEL
	ip.free_envs = nil // the last input's, emptied with its memory
	ip.printer = out if transient else nil
	ip.env = prog.env
	sig := eval(ip, prog.body, {v = input}, prog.globals, false, out)
	ip.printer = nil
	switch {
	case ip.halted != nil:
		return .Halted
	case sig == .Fail:
		return .Raised
	}
	return .Done
}

// The outputs of `prog` on each member of `of`, appended to `into` in order, as `[.[] | prog]` collects them. What
// a member's run makes that no output keeps is given back as that run ends.
collect :: proc(ip: ^Interp, prog: Program, of: core_pkg.Value, into: ^[dynamic]core_pkg.Value) -> Outcome {
	ip.halted, ip.brk = nil, NO_LABEL
	ip.free_envs = nil
	ip.env = prog.env
	x := region_collect(ip, prog.body, prog.globals, into)
	defer free_regions(ip)
	sig := Signal.Go
	it := iterate(of)
	for _, v in next_member(&it) {
		if sig = x.emit(&x, {v = v}); sig != .Go {
			break
		}
	}
	sig = end_region_collect(&x, sig)
	switch {
	case ip.halted != nil:
		return .Halted
	case sig != .Go:
		return .Raised
	}
	return .Done
}

// Readies what `prog` reads on every run, its variables and the modules' data files, for copies of `ip` that run at
// once (`clone`), so that their reads write nothing. Called once, before the copies start.
share :: proc(ip: ^Interp, prog: Program) {
	for e := prog.globals; e != nil; e = e.parent {
		if e.kind == .Var {
			index_shared(e.value)
		}
	}
	for v in ip.data {
		index_shared(v)
	}
	if ip.env = prog.env; ip.env != nil {
		env_value(ip) // the copies read the one $ENV, which a failure leaves each to make
	}
}

// Makes `into` a copy of `ip` that another thread runs while `ip` and its other copies run: it reads what `ip`
// compiled and keeps its own memory. `into` is zero, or a copy made before, whose compiled regexes it keeps and
// whose runs' memory it gives back. `destroy` gives back all a copy holds.
clone :: proc(ip: ^Interp, into: ^Interp) {
	regexes, scratch := into.regexes, into.slice_scratch
	into.regexes, into.slice_scratch = {}, {}
	free_detached(into)
	into^ = ip^
	detach_memory(into)
	into.regexes, into.slice_scratch = regexes, scratch
}

// Ends a run from its sink with the error `err`: `return jq.raise(ip, err)`.
raise :: proc(ip: ^Interp, err: core_pkg.Value) -> Signal {
	ip.err = err
	return .Fail
}

// The inputs `input` and `inputs` read, which a caller may replace between runs (`set_inputs`).
inputs :: proc(ip: ^Interp) -> Input_Source {
	return ip.hooks.inputs
}

set_inputs :: proc(ip: ^Interp, inputs: Input_Source) {
	ip.hooks.inputs = inputs
}

// What the interpreter keeps from one run to the next: its arenas, compiled regexes and buffers.
destroy :: proc(ip: ^Interp) {
	free_detached(ip)
}

@(private = "file")
filter_errors :: proc(text: string, faults: []Compile_Error) -> []Error {
	errors := make([]Error, len(faults))
	for f, i in faults {
		errors[i] = {.Filter, "", locate(text, f), false}
	}
	return errors
}

// What a sink tells the run after an output: `.Go` for the next, `.Break` to end the run with no error, `.Fail` to end
// it with the error `raise` sets.
Signal :: enum u8 {
	Go,
	Break,
	Fail,
}

// An output: a value, and under `track` where it was read from the root (`nil` is the root itself).
Item :: struct {
	v:    core_pkg.Value,
	path: ^core_pkg.Trail_Step,
}

// Where a run's outputs go: `emit` takes one. A sink that needs data of its own embeds a `Sink` with `using` and casts.
Sink :: struct {
	emit: proc(s: ^Sink, it: Item) -> Signal,
}

// An interpreter. After a run, `err` holds the error it raised (`.Raised`) and `halted` the exit code `halt` or
// `halt_error` gave (`.Halted`).
Interp :: struct {
	err:           core_pkg.Value,
	halted:        Maybe(int),
	// The rest is the interpreter's own, which a caller neither reads nor writes. A private struct embedded with
	// `using` would hold them, but the compiler's escape check then warns that a run keeps the interpreter.
	raised:        int, // errors raised so far: tells one raise of `err` from another of the same value
	brk:           int, // the label id a `.Break` unwinds to, -1 for `halt`, NO_LABEL for a sink's
	labels:        int, // label ids handed out so far (`fresh_label`)
	literals:      u32, // the marks `tonumber` gave its literals, which tell one from another of the same text
	builtins:      ^Builtins, // the table the program was checked with
	hooks:         Hooks,
	reading:       core_pkg.As, // how `fromjson` reads a text (`Options.reading`)
	env:           ^Program_Env, // the running program's
	debug_layout:  Layout, // how `debug` prints its message: jq's output options, compact
	search_list:   []string, // the module directories, nil for jq's default list
	prog_origin:   string, // the real path of the directory the program's text came from, or empty
	executable:    string, // the path the program was run by, whose directory `$ORIGIN` names
	name:          string, // the program name the messages `modulemeta` writes carry, as jq's carry "jq"
	data:          [dynamic]core_pkg.Value, // the modules' data files, which every thread of a run reads (`index_shared`)
	// Scopes no evaluation reads any more, linked by `parent`, for `new_env` to hand out again. They live
	// in the input's memory, so the caller empties the list with it.
	free_envs:     ^Env,
	// The sink a caller prints outputs with, keeping none of them once it returns, or nil: what a pipe or
	// a binding feeding it makes for an output is emptied once that output is printed (`Output_Scope`).
	printer:       ^Sink,
	scope:         Output_Scope,
	owned:         ^Owned, // the innermost reduce or foreach whose update changes its state in place, or nil
	text:          Text_Count, // the code-point count a state that grows by `+` resumes from (`length`)
	recycler:      Input_Recycler,
	faults:        Arena_Pair, // `fail`'s messages and their details (`message_allocator`)
	regions:       ^Region, // regions given back (`collect_regioned`)
	too_deep:      bool, // a comparison since it was cleared met values nested deeper than MAX_DEPTH
	regexes:       Regex_Cache,
	slice_scratch: [dynamic]byte, // the buffer a slice of a string that needs decoding decodes it into
}

// The allocator over the arena `a` that a run's values go in (`run`), and an input's document is built in. Emptying it
// keeps its first block and writes no zeros over it, and a shrink gives the last allocation's tail back without zeroing
// it, so a build's unused node room is never written: only `.Alloc` and `.Resize` promise zeros, and they write them
// over what they give. An output scope's arena, which takes many small allocations, keeps the virtual arena's own
// zeroing (`scope_allocator`).
run_allocator :: proc(a: ^virtual.Arena) -> runtime.Allocator {
	return {arena_proc, a}
}
