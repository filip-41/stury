#+private
package jq

// jq 1.8.2's module system, as its linker behaves: `import PATH as NAME;` brings a module's definitions in as
// `NAME::f`, `include PATH;` brings them in as they are, and `import PATH as $NAME;` binds a JSON file's texts, as an
// array, to `$NAME::NAME` and `$NAME`. A later import shadows an earlier one, and the program's own definitions
// shadow both. A module is only definitions. It sees what it imports, the builtins and the variables the program is compiled with,
// never its importer's definitions, and each definition sees those before it.
//
// A directive's dependency is found on its search path: the metadata's `search` (a string or an array), or
// "." and then the library directories (`Options.search`, or `~/.jq`, `$ORIGIN/../lib/jq`, `$ORIGIN/../lib`). In each
// directory PATH is tried as `PATH.jq`, `PATH/jq/main.jq` and `PATH/BASENAME.jq` (`.json` for data). A
// directory `~/` begins is under $HOME, `$ORIGIN/` under the directory of argv[0], `./` under the
// importer's directory, and any other relative one under it too, except "." itself, which is the working
// directory. `~/.jq`, when it is not a directory, is included into every program, found as a module named ""
// on the search path [$HOME], so that `$HOME/jq/main.jq` serves as well.
//
// Dependencies load in reverse order, each module once (a failed one again), its own first. jq's messages and count
// of errors follow: a dependency that cannot be found, a malformed PATH or a cycle stops its importer's list with one
// error. A module that does not parse, or is not only definitions, or a data file that does not read, counts its
// errors and the list goes on.

import "core:fmt"
import "core:slice"
import "core:strings"
import core_pkg "../core"

// A module or data file the program reaches, loaded.
Library :: struct {
	path:    string, // its real path
	src:     string,
	imports: []Import,
	defs:    []Lib_Def, // its definitions, in order
	data:    core_pkg.Value, // a data file's texts, or its text with `raw`
	is_data: bool,
	// The oldest of its scopes at run time, whose parent is set to the program's globals before it runs.
	bottom:  ^Env,
}

// A dependency as its importer binds it: under `name::` (nothing for `include`), or a data file as `$name`.
// `lib` is nil for an optional one not found.
Import :: struct {
	lib:  ^Library,
	name: string,
}

// A definition of a module: its scope at run time, and the scope `check` resolves its body's names in.
Lib_Def :: struct {
	env:     ^Env,
	body:    ^Scope,
	reached: bool, // the program calls it, through any number of definitions
	lib:     ^Library,
}

// What linking the program found, or its errors.
Linked :: struct {
	imports: []Import, // the program's
	libs:    []^Library, // every module, each after those it imports
	errors:  []Error,
}

@(private = "file")
Linker :: struct {
	ip:      ^Interp,
	libs:    [dynamic]^Library,
	loading: [dynamic]string, // the modules being loaded, outermost first
	errors:  [dynamic]Error,
}

// Load what the program's directives `deps` import, from `origin`, the directory its relative paths start from, and
// `~/.jq` first.
link :: proc(ip: ^Interp, deps: []core_pkg.Value, origin: string) -> Linked {
	deps := deps
	if dep, found := home_dep(ip); found {
		all := make([]core_pkg.Value, len(deps) + 1)
		all[0] = dep
		copy(all[1:], deps)
		deps = all
	}
	l := Linker{ip = ip}
	imports, _ := process(&l, deps, origin)
	return {imports, l.libs[:], l.errors[:]}
}

// Whether `~/.jq` stands for a module every program includes: `$HOME/.jq` a file, or `$HOME/jq/main.jq`
// there when `$HOME/.jq` is not. Every run asks, so an absolute $HOME is two stats.
home_module :: proc(ip: ^Interp) -> bool {
	home, _ := home_dir(ip)
	if len(home) == 0 || home[0] != '/' {
		// Unset, or relative to the program's directory: as the linker finds it.
		dep, found := home_dep(ip)
		if !found {
			return false
		}
		search, _ := object_get(dep, "search")
		_, msg := find_module(ip, "", search, ".jq", program_origin(ip))
		return msg == ""
	}
	if kind := path_kind(ip, strings.concatenate({home, "/.jq"}, context.temp_allocator)); kind != .Missing {
		return kind == .File
	}
	kind := path_kind(ip, strings.concatenate({home, "//jq/main.jq"}, context.temp_allocator))
	return kind == .File || kind == .Dir
}

// The include jq adds for `~/.jq` when $HOME is set and that is not a directory.
@(private = "file")
home_dep :: proc(ip: ^Interp) -> (core_pkg.Value, bool) {
	home, has_home := home_dir(ip)
	if !has_home {
		return nil, false
	}
	if path_kind(ip, fmt.tprintf("%s/.jq", home)) == .Dir {
		return nil, false
	}
	dep := core_pkg.new_object()
	core_pkg.object_put(dep, "optional", true)
	core_pkg.object_put(dep, "search", strings.clone(home))
	core_pkg.object_put(dep, "is_data", false)
	core_pkg.object_put(dep, "relpath", string(""))
	return dep, true
}

// Each of `deps`, last first: found, loaded unless it was, and bound. One that cannot be found ends the
// list as one error, as a cycle does.
@(private = "file")
process :: proc(l: ^Linker, deps: []core_pkg.Value, origin: string) -> (imports: []Import, count: int) {
	imports = make([]Import, len(deps))
	listed := len(l.errors)
	#reverse for dep, i in deps {
		name, has_name := member_string(dep, "as")
		relpath, _ := member_string(dep, "relpath")
		is_data, raw, optional := member_true(dep, "is_data"), member_true(dep, "raw"), member_true(dep, "optional")
		search, has_search := object_get(dep, "search")
		if !has_search {
			search = default_search(l.ip)
		}
		path, msg := find_module(l.ip, relpath, search, ".json" if is_data else ".jq", origin)
		if msg != "" {
			if optional {
				continue
			}
			return imports, stop_list(l, listed, {.Module, "", msg, false})
		}
		if slice.contains(l.loading[:], path) {
			return imports, stop_list(l, listed, {.Module, path, fmt.aprintf("circular import of %s", path), false})
		}
		lib: ^Library
		for x in l.libs {
			if !is_data && !x.is_data && x.path == path {
				lib = x
			}
		}
		if lib == nil {
			n: int
			lib, n = load(l, path, is_data, raw)
			count += n
		}
		imports[i] = {lib, name if has_name else ""}
	}
	return
}

// Ends an import list with `err`, which jq counts as the list's one error.
@(private = "file")
stop_list :: proc(l: ^Linker, listed: int, err: Error) -> int {
	for &e in l.errors[listed:] {
		e.uncounted = true
	}
	append(&l.errors, err)
	return 1
}

// The module or data file at `path`, and jq's count of its errors. It is nil if it has any.
@(private = "file")
load :: proc(l: ^Linker, path: string, is_data, raw: bool) -> (^Library, int) {
	v, msg := load_file(l.ip, path, raw || !is_data)
	if msg != "" {
		append(&l.errors, Error{.Data_File, path, msg, false})
		return nil, 1
	}
	if is_data {
		append(&l.ip.data, v)
		return new_clone(Library{path = path, data = v, is_data = true}), 0
	}
	src, _ := string_of(v)
	errors := len(l.errors)
	prog := parse_library(src, path, &l.errors)
	if len(l.errors) > errors {
		return nil, len(l.errors) - errors
	}
	append(&l.loading, path)
	imports, n := process(l, prog.deps, dir_name(path))
	pop(&l.loading)
	if n > 0 {
		return nil, n
	}
	lib := new_clone(Library{path = path, src = src, imports = imports})
	defs: [dynamic]Lib_Def
	for d := prog.defs; d != nil; d = d.a {
		append(&defs, Lib_Def{env = new_clone(Env{kind = .Func, name = d.fn.name, arity = len(d.fn.params), fn = d.fn}), lib = lib})
	}
	lib.defs = defs[:]
	append(&l.libs, lib)
	return lib, 0
}

// `src` parsed as a library, its errors put in `errors`, a main expression among them.
@(private = "file")
parse_library :: proc(src, path: string, errors: ^[dynamic]Error) -> Parsed {
	prog, faults := parse(src, path)
	for e in faults {
		append(errors, Error{.Library, path, locate(src, e), false})
	}
	if len(faults) == 0 && prog.body != nil {
		// jq's message, which carries jq's name in its text.
		append(errors, Error{.Library, path, "jq: error: library should only have function definitions, not a main expression", false})
	}
	return prog
}

// ---- Finding a module

// The search path a directive without `search` has: ".", then the library directories.
@(private = "file")
default_search :: proc(ip: ^Interp) -> core_pkg.Value {
	a := core_pkg.new_array()
	append(&a.items, string("."))
	dirs := lib_dirs(ip)
	append(&a.items, ..dirs.(^core_pkg.Array).items[:])
	return a
}

// The module directories `Options.search` gives, or jq's default list.
lib_dirs :: proc(ip: ^Interp) -> core_pkg.Value {
	if ip.search_list == nil {
		a := core_pkg.new_array(3)
		append(&a.items, string("~/.jq"), string("$ORIGIN/../lib/jq"), string("$ORIGIN/../lib"))
		return a
	}
	a := core_pkg.new_array(len(ip.search_list))
	for dir in ip.search_list {
		append(&a.items, dir)
	}
	return a
}

// The real path of the module `relpath` names, on the search path `search` (an array, or one entry), with `suffix`.
// Relative entries start from the directory `origin` (none if nil). When there is no such module, `msg` is
// jq's message.
find_module :: proc(ip: ^Interp, relpath: string, search: core_pkg.Value, suffix: string, origin: Maybe(string)) -> (path: string, msg: string) {
	if msg = check_relpath(relpath); msg != "" {
		return
	}
	dirs, expand_error := search_dirs(ip, search, origin)
	base := relpath[strings.last_index_byte(relpath, '/') + 1:]
	for dir in dirs {
		if dir == "" {
			continue
		}
		tries := [?]string {
			fmt.tprintf("%s/%s%s", dir, relpath, suffix),
			fmt.tprintf("%s/%s/jq/main%s", dir, relpath, suffix),
			fmt.tprintf("%s/%s/%s%s", dir, relpath, base, suffix),
		}
		for try in tries {
			kind := path_kind(ip, try)
			if kind == .File || kind == .Dir {
				return real_path(ip, try), ""
			}
			if kind == .Unreadable {
				break
			}
		}
	}
	if expand_error != "" {
		return "", fmt.aprintf("module not found: %s (%s)", relpath, expand_error)
	}
	return "", fmt.aprintf("module not found: %s", relpath)
}

// jq's checks on a module's path: no NUL, no `\`, no `..` component, no component twice in a row.
@(private = "file")
check_relpath :: proc(relpath: string) -> string {
	if strings.index_byte(relpath, 0) >= 0 {
		return "Module path contains a NUL byte"
	}
	if strings.index_byte(relpath, '\\') >= 0 {
		return fmt.aprintf("Modules must be named by relative paths using '/', not '\\' (%s)", relpath)
	}
	prev: Maybe(string)
	rest := relpath
	for {
		end := strings.index_byte(rest, '/')
		part := rest if end < 0 else rest[:end]
		if part == ".." {
			return fmt.aprintf("Relative paths to modules may not traverse to parent directories (%s)", relpath)
		}
		if p, has := prev.?; has && p == part {
			return fmt.aprintf("module names must not have equal consecutive components: %s", relpath)
		}
		if end < 0 {
			return ""
		}
		prev, rest = part, rest[end + 1:]
	}
}

// The directories of a search path, as jq expands them, and the last entry it could not expand.
@(private = "file")
search_dirs :: proc(ip: ^Interp, search: core_pkg.Value, origin: Maybe(string)) -> (dirs: [dynamic]string, expand_error: string) {
	entries := []core_pkg.Value{search}
	if a, is_array := search.(^core_pkg.Array); is_array {
		entries = a.items[:]
	}
	for entry in entries {
		dir, is_string := entry.(string)
		if !is_string {
			continue
		}
		if len(dir) > 1 && dir[0] == '~' && dir[1] == '/' {
			home, has_home := home_dir(ip)
			if !has_home {
				expand_error = fmt.aprintf("Could not expand %s. (Could not find home directory.)", dir)
				continue
			}
			dir = strings.concatenate({home, dir[1:]})
		}
		o, has_origin := origin.?
		switch {
		case dir == ".":
		case strings.has_prefix(dir, "./"):
			dir = fmt.aprintf("%s/%s", o, dir[2:])
		case strings.has_prefix(dir, "$ORIGIN/"):
			dir = fmt.aprintf("%s/%s", jq_origin(ip), dir[len("$ORIGIN/"):])
		case has_origin && !is_absolute_path(dir):
			dir = fmt.aprintf("%s/%s", o, dir)
		}
		append(&dirs, dir)
	}
	return
}

// jq's JQ_ORIGIN: the directory of argv[0], as dirname gives it.
jq_origin :: proc(ip: ^Interp) -> string {
	return dir_name(ip.executable)
}

// jq's PROGRAM_ORIGIN: the real path of the directory of the filter's file (`Options.file`), or else of the working
// directory.
program_origin :: proc(ip: ^Interp) -> string {
	if ip.prog_origin != "" {
		return ip.prog_origin
	}
	return real_path(ip, ".")
}

@(private = "file")
member_string :: proc(o: core_pkg.Value, k: string) -> (string, bool) {
	v, _ := object_get(o, k)
	return string_of(v)
}

@(private = "file")
member_true :: proc(o: core_pkg.Value, k: string) -> bool {
	v, _ := object_get(o, k)
	b, is_bool := v.(bool)
	return is_bool && b
}

// ---- modulemeta

// The module the input names, found on the library directories alone: its `module` metadata, with its
// directives as `deps` and the names of its definitions as `defs`. A module that does not parse gives null,
// its errors printed.
fn_modulemeta :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (core_pkg.Value, Signal) {
	relpath, is_string := string_of(v)
	if !is_string {
		return nil, fail(ip, "modulemeta input module name must be a string")
	}
	path, msg := find_module(ip, relpath, lib_dirs(ip), ".jq", nil)
	if msg != "" {
		return nil, fail(ip, "%s", msg)
	}
	text, err := load_file(ip, path, true)
	if err != "" {
		return nil, fail(ip, "%s", err)
	}
	src, _ := string_of(text)
	errors := make([dynamic]Error, context.temp_allocator)
	prog := parse_library(src, path, &errors)
	if len(errors) > 0 {
		for e in errors {
			say(ip, fmt.tprintf("%s: error: %s\n", ip.name, e.msg))
		}
		return nil, .Go
	}
	meta := own(prog.meta).(^core_pkg.Object) if prog.meta != nil else core_pkg.new_object()
	deps := core_pkg.new_array(len(prog.deps))
	append(&deps.items, ..prog.deps)
	defs := core_pkg.new_array()
	outer: for d := prog.defs; d != nil; d = d.a {
		sig := fmt.aprintf("%s/%d", d.fn.name, len(d.fn.params))
		for s in defs.items {
			if s.(string) == sig {
				continue outer
			}
		}
		append(&defs.items, sig)
	}
	core_pkg.object_put(meta, "deps", deps)
	core_pkg.object_put(meta, "defs", defs)
	return meta, .Go
}
