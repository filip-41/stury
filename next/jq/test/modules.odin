#+feature dynamic-literals
package jq_tests

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "stury:jq"
import "stury:lib/query"
import "stury:testkit"

// Where the corpus's own modules are, as jq's run-tests passes it with `-L`.
MODULES_DIR :: "jq/test/cases/modules"

read_file :: proc(data: rawptr, path: string, allocator: runtime.Allocator) -> (string, bool) {
	text, err := os.read_entire_file_from_path(path, allocator)
	return string(text), err == nil
}

MODULES_SEARCH := [?]string{MODULES_DIR}

corpus_modules :: proc() -> jq.Modules {
	return {loader = {read = read_file, parse_json = parse_json_hook}, search = MODULES_SEARCH[:]}
}

// The files of a loader that reads none from disk, by path.
Memory_Files :: map[string]string

read_memory :: proc(data: rawptr, path: string, allocator: runtime.Allocator) -> (string, bool) {
	files := (^Memory_Files)(data)
	text, found := files[path]
	return strings.clone(text, allocator), found
}

// Compiles `src` with `modules` and runs it on null with `globals`: its outputs as JSON, joined by a space, then
// `error: ` and the message if the run failed, or jq's first line for the compile error.
eval :: proc(t: ^testing.T, src: string, modules: jq.Modules, variables: []string = nil, globals: []string = nil) -> string {
	prog, errors := jq.compile(src, {modules = modules, variables = variables})
	defer jq.destroy_program(prog)
	if len(errors) > 0 {
		return last_message(errors)
	}
	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)
	values := make([]query.Value, len(globals))
	for text, i in globals {
		values[i], _ = read_value(&h, text)
	}
	run: jq.Run
	jq.run_init(&run, prog, &h, values)
	outs := Outputs{h = &h}
	end := jq.run_value(&run, query.NULL, collect, &outs)
	shown := make([dynamic]string)
	for v in outs.vals {
		append(&shown, show(&h, v))
		query.release(&h, v)
	}
	if end == .Failed {
		e := query.take_error(&h)
		append(&shown, strings.concatenate({"error: ", jq.error_message(&h, &e)}))
		query.destroy_error(&h, &e)
	}
	jq.run_destroy(&run)
	for v in values {
		query.release(&h, v)
	}
	testing.expect_value(t, query.heap_live(&h), u64(0))
	return strings.join(shown[:], " ")
}

@(test)
modules_bind_their_names :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	files := Memory_Files {
		"/m/a.jq"      = "def f: 1; def g: f + 1;",
		"/m/b.jq"      = `import "a" as a; def h: a::g * 10;`,
		"/m/loc.jq"    = "def where: $__loc__;",
		"/m/bad.jq"    = "def broken: nosuch;",
		"/m/main.jq"   = "def f: 1; .",
		"/m/data.json" = `{"k": [1, 2]}`,
		"/m/raw.json"  = "hi",
		"/m/empty.json" = " ",
		"/m/in/x.jq"   = `import "sib" as s {search: "./"}; def x: s::y;`,
		"/m/in/sib.jq" = "def y: 7;",
	}
	mods := jq.Modules {
		loader = {data = &files, read = read_memory, parse_json = parse_json_hook},
		search = {"/m"},
	}
	testing.expect_value(t, eval(t, `import "b" as b; b::h`, mods), "20")
	testing.expect_value(t, eval(t, `import "b" as b; a::f`, mods), "jq: error: a::f/0 is not defined at <top-level>, line 1, column 18:")
	testing.expect_value(t, eval(t, `import "loc" as l; l::where`, mods), `{"file":"/m/loc.jq","line":1}`)
	testing.expect_value(t, eval(t, `import "data" as $d; $d, $d::d`, mods), `[{"k":[1,2]}] [{"k":[1,2]}]`)
	testing.expect_value(t, eval(t, `import "empty" as $d; $d`, mods), "[]")
	testing.expect_value(t, eval(t, `import "raw" as $d {raw: true}; $d`, mods), `"hi"`)
	testing.expect_value(t, eval(t, `import "in/x" as x; x::x`, mods), "7")
	testing.expect_value(t, eval(t, `import "nope" as n; .`, mods), "jq: error: module not found: nope")
	testing.expect_value(t, eval(t, `import "nope" as n {optional: true}; 1`, mods), "1")
	testing.expect_value(t, eval(t, `import "bad" as b; 1`, mods), "jq: error: nosuch/0 is not defined at /m/bad.jq, line 1, column 13:")
	testing.expect_value(t, eval(t, `import "main" as m; 1`, mods), "jq: error: library should only have function definitions, not a main expression")
	testing.expect_value(t, eval(t, `import "../a" as m; 1`, mods), "jq: error: Relative paths to modules may not traverse to parent directories (../a)")
	testing.expect_value(t, eval(t, `import "a/a" as m; 1`, mods), "jq: error: module names must not have equal consecutive components: a/a")
	testing.expect_value(t, eval(t, `import "a\\b" as m; 1`, mods), "jq: error: Modules must be named by relative paths using '/', not '\\' (a\\b)")
	no_loader := jq.Modules{search = {"/m"}}
	testing.expect_value(t, eval(t, `import "a" as a; 1`, no_loader), "jq: error: module not found: a")
}

@(test)
cyclic_imports_are_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	files := Memory_Files {
		"/m/p.jq" = `import "q" as q; def a: 1;`,
		"/m/q.jq" = `import "p" as p; def b: 1;`,
	}
	mods := jq.Modules {
		loader = {data = &files, read = read_memory, parse_json = parse_json_hook},
		search = {"/m"},
	}
	testing.expect_value(t, eval(t, `import "p" as p; 1`, mods), "jq: error: circular import of /m/p.jq")
}

@(test)
search_paths_are_expanded_as_jq_expands_them :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	files := Memory_Files {
		"/h/lib/x.jq"  = "def x: 1;",
		"/lib/y.jq"    = "def y: 2;",
		"/h/.jq"       = "def hm: 3;",
		"/w/z/z.jq"    = "def z: 4;",
		"/lib/jq/w.jq" = "def w: 5;",
	}
	mods := jq.Modules {
		loader = {data = &files, read = read_memory},
		search = {"/lib/jq"},
		origin = "/w",
		jq_origin = "/o",
		home = "/h",
	}
	testing.expect_value(t, eval(t, `import "x" as x {search: "~/lib"}; x::x`, mods), "1")
	testing.expect_value(t, eval(t, `import "y" as y {search: "$ORIGIN/../lib"}; y::y`, mods), "2")
	testing.expect_value(t, eval(t, `import "z" as z {search: "./"}; z::z`, mods), "4")
	testing.expect_value(t, eval(t, `import "w" as w; w::w`, mods), "5")
	testing.expect_value(t, eval(t, `hm`, mods), "3")
	testing.expect_value(t, eval(t, `import "x" as x {search: "~/lib"}; 1`, jq.Modules{loader = mods.loader}), "jq: error: module not found: x (Could not expand ~/lib. (Could not find home directory.))")
	testing.expect_value(t, eval(t, `[get_search_list, get_jq_origin, get_prog_origin]`, mods), `[["/lib/jq"],"/o","/w"]`)
	testing.expect_value(t, eval(t, `"w" | modulemeta`, mods), `{"deps":[],"defs":["w/0"]}`)
	testing.expect_value(t, eval(t, `"nope" | modulemeta`, mods), "error: module not found: nope")
	testing.expect_value(t, eval(t, `1 | modulemeta`, mods), "error: modulemeta input module name must be a string")
}

@(test)
callers_name_variables_programs_and_modules_see :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	files := Memory_Files {
		"/m/v.jq" = "def v: $x + $__prog_args[0] + $ENV.A;",
	}
	mods := jq.Modules {
		loader = {data = &files, read = read_memory, parse_json = parse_json_hook},
		search = {"/m"},
	}
	globals := []string{`{"A":100}`, "[10]", "1"}
	testing.expect_value(t, eval(t, `$x`, mods, {"x"}, globals), "1")
	testing.expect_value(t, eval(t, `import "v" as m; m::v, env.A`, mods, {"x"}, globals), "111 100")
	testing.expect_value(t, eval(t, `$y`, mods, {"x"}, globals), "jq: error: $y is not defined at <top-level>, line 1, column 1:")
}
