package jq

// jq 1.8.2's module system, as its linker behaves: `import PATH as NAME;` brings a module's definitions in as
// `NAME::f`, `include PATH;` brings them in as they are, and `import PATH as $NAME;` binds a JSON file's texts, as an
// array, to `$NAME::NAME` and `$NAME`. A later import shadows an earlier one, and the program's own definitions
// shadow both. A module is only definitions. It sees what it imports, the builtins and the command line's variables,
// never its importer's definitions, and each definition sees those before it.
//
// A directive's dependency is found on its search path: the metadata's `search` (a string or an array), or
// "." and then the library directories (-L's, or `~/.jq`, `$ORIGIN/../lib/jq`, `$ORIGIN/../lib`). In each
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
import "core:os"
import "core:strings"

// The program name jq's messages carry.
@(private = "file")
NAME :: "stury"

// A module or data file the program reaches, loaded.
Library :: struct {
	path:    string, // its real path
	src:     string,
	imports: []Import,
	defs:    []Lib_Def, // its definitions, in order
	data:    Value, // a data file's texts, or its text with `raw`
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

// What linking the program found, or its messages and jq's count of errors.
Linked :: struct {
	imports:  []Import, // the program's
	libs:     []^Library, // every module, each after those it imports
	messages: string,
	errors:   int,
}

@(private = "file")
Linker :: struct {
	ip:       ^Interp,
	libs:     [dynamic]^Library,
	loading:  [dynamic]string, // the modules being loaded, outermost first
	messages: strings.Builder,
}

// Load what the program's directives `deps` import, from `origin`, the directory its relative paths start from, and
// `~/.jq` first.
link :: proc(ip: ^Interp, deps: []Value, origin: string) -> Linked {
	deps := deps
	if dep, found := home_dep(); found {
		all := make([]Value, len(deps) + 1)
		all[0] = dep
		copy(all[1:], deps)
		deps = all
	}
	l := Linker{ip = ip}
	imports, errors := process(&l, deps, origin)
	return {imports, l.libs[:], strings.to_string(l.messages), errors}
}

// Whether `~/.jq` stands for a module every program includes: `$HOME/.jq` a file, or `$HOME/jq/main.jq`
// there when `$HOME/.jq` is not. Every run asks, so an absolute $HOME is two stats and no allocation.
home_module :: proc(ip: ^Interp) -> bool {
	home := string(home_dir())
	if len(home) == 0 || home[0] != '/' {
		// Unset, or relative to the program's directory: as the linker finds it.
		dep, found := home_dep()
		if !found {
			return false
		}
		search, _ := object_get(dep, "search")
		_, msg := find_module(ip, "", search, ".jq", program_origin(ip))
		return msg == ""
	}
	buf: [PATH_MAX + 16]u8
	if len(home) > PATH_MAX {
		return false
	}
	copy(buf[:], home)
	copy(buf[len(home):], "/.jq\x00")
	if kind := path_kind(cstring(&buf[0])); kind != .Missing {
		return kind == .File
	}
	copy(buf[len(home):], "//jq/main.jq\x00")
	kind := path_kind(cstring(&buf[0]))
	return kind == .File || kind == .Dir
}

// The include jq adds for `~/.jq` when $HOME is set and that is not a directory.
@(private = "file")
home_dep :: proc() -> (Value, bool) {
	home := home_dir()
	if home == nil {
		return nil, false
	}
	if path_kind(strings.clone_to_cstring(fmt.tprintf("%s/.jq", home), context.temp_allocator)) == .Dir {
		return nil, false
	}
	dep := new_object()
	object_put(dep, "optional", true)
	object_put(dep, "search", strings.clone_from_cstring(home))
	object_put(dep, "is_data", false)
	object_put(dep, "relpath", "")
	return dep, true
}

// Each of `deps`, last first: found, loaded unless it was, and bound. One that cannot be found ends the
// list as one error, as a cycle does.
@(private = "file")
process :: proc(l: ^Linker, deps: []Value, origin: string) -> (imports: []Import, errors: int) {
	imports = make([]Import, len(deps))
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
			fmt.sbprintf(&l.messages, "%s: error: %s\n\n", NAME, msg)
			return imports, 1
		}
		for p in l.loading {
			if p == path {
				fmt.sbprintf(&l.messages, "%s: error: circular import of %s\n\n", NAME, path)
				return imports, 1
			}
		}
		lib := cached(l, path) if !is_data else nil
		if lib == nil {
			n: int
			lib, n = load(l, path, is_data, raw)
			errors += n
		}
		imports[i] = {lib, name if has_name else ""}
	}
	return
}

@(private = "file")
cached :: proc(l: ^Linker, path: string) -> ^Library {
	for lib in l.libs {
		if !lib.is_data && lib.path == path {
			return lib
		}
	}
	return nil
}

// The module or data file at `path`, and its errors. It is nil if it has any.
@(private = "file")
load :: proc(l: ^Linker, path: string, is_data, raw: bool) -> (^Library, int) {
	v, msg := l.ip.load_file(path, raw || !is_data)
	if msg != "" {
		fmt.sbprintf(&l.messages, "%s: error loading data file %s: %s\n\n", NAME, path, msg)
		return nil, 1
	}
	if is_data {
		return new_clone(Library{path = path, data = v, is_data = true}), 0
	}
	src, _ := string_of(v)
	prog, errors := parse_library(src, path, &l.messages.buf)
	if errors > 0 {
		return nil, errors
	}
	append(&l.loading, path)
	imports, n := process(l, prog.deps, dir_name(path))
	pop(&l.loading)
	if n > 0 {
		return nil, n
	}
	lib := new_clone(Library{path = path, src = src, imports = imports})
	count := 0
	for d := prog.defs; d != nil; d = d.a {
		count += 1
	}
	lib.defs = make([]Lib_Def, count)
	i := 0
	for d := prog.defs; d != nil; d = d.a {
		e := new(Env)
		e^ = {kind = .Func, name = d.fn.name, arity = len(d.fn.params), fn = d.fn}
		lib.defs[i] = {env = e, lib = lib}
		i += 1
	}
	append(&l.libs, lib)
	return lib, 0
}

// `src` parsed as a library, its errors printed to `messages`, a main expression among them, how many.
@(private = "file")
parse_library :: proc(src, path: string, messages: ^[dynamic]byte) -> (Program, int) {
	prog, errors := parse(src, path)
	for e in errors {
		append(messages, ..transmute([]byte)fmt.tprintf("%s: error: %s\n", NAME, locate(src, e)))
	}
	if len(errors) > 0 || prog.body == nil {
		return prog, len(errors)
	}
	// jq's message, which carries jq's name in its text.
	append(messages, ..transmute([]byte)fmt.tprintf("%s: error: jq: error: library should only have function definitions, not a main expression\n", NAME))
	return prog, 1
}

// ---- Finding a module

// The search path a directive without `search` has: ".", then the library directories.
@(private = "file")
default_search :: proc(ip: ^Interp) -> Value {
	a := new_array()
	append(&a.items, ".")
	dirs := lib_dirs(ip)
	append(&a.items, ..dirs.(^Array).items[:])
	return a
}

// -L's directories, or jq's default list.
lib_dirs :: proc(ip: ^Interp) -> Value {
	if ip.search_list == nil {
		a := new_array(3)
		append(&a.items, "~/.jq", "$ORIGIN/../lib/jq", "$ORIGIN/../lib")
		return a
	}
	a := new_array(len(ip.search_list))
	for dir in ip.search_list {
		append(&a.items, dir)
	}
	return a
}

// The real path of the module `relpath` names, on the search path `search` (an array, or one entry), with `suffix`.
// Relative entries start from the directory `origin` (none if nil). When there is no such module, `msg` is
// jq's message.
find_module :: proc(ip: ^Interp, relpath: string, search: Value, suffix: string, origin: Maybe(string)) -> (path: string, msg: string) {
	if msg = check_relpath(relpath); msg != "" {
		return
	}
	dirs, expand_error := search_dirs(ip, search, origin)
	base := relpath[strings.last_index_byte(relpath, '/') + 1:]
	for dir in dirs {
		if dir == "" {
			continue
		}
		for alt in 0 ..< 3 {
			try: string
			switch alt {
			case 0:
				try = fmt.tprintf("%s/%s%s", dir, relpath, suffix)
			case 1:
				try = fmt.tprintf("%s/%s/jq/main%s", dir, relpath, suffix)
			case:
				try = fmt.tprintf("%s/%s/%s%s", dir, relpath, base, suffix)
			}
			kind := path_kind(strings.clone_to_cstring(try, context.temp_allocator))
			if kind == .File || kind == .Dir {
				return real_path(try), ""
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
search_dirs :: proc(ip: ^Interp, search: Value, origin: Maybe(string)) -> (dirs: [dynamic]string, expand_error: string) {
	entries := []Value{search}
	if a, is_array := search.(^Array); is_array {
		entries = a.items[:]
	}
	for entry in entries {
		dir, is_string := entry.(string)
		if !is_string {
			continue
		}
		if len(dir) > 1 && dir[0] == '~' && dir[1] == '/' {
			home := home_dir()
			if home == nil {
				expand_error = fmt.aprintf("Could not expand %s. (Could not find home directory.)", dir)
				continue
			}
			dir = strings.concatenate({string(home), dir[1:]})
		}
		o, has_origin := origin.?
		switch {
		case dir == ".":
		case strings.has_prefix(dir, "./"):
			dir = fmt.aprintf("%s/%s", o, dir[2:])
		case strings.has_prefix(dir, "$ORIGIN/"):
			dir = fmt.aprintf("%s/%s", jq_origin(), dir[len("$ORIGIN/"):])
		case has_origin && !os.is_absolute_path(dir):
			dir = fmt.aprintf("%s/%s", o, dir)
		}
		append(&dirs, dir)
	}
	return
}

// jq's JQ_ORIGIN: the directory of argv[0], as dirname gives it. Worked out by `set_origin` before any thread
// but one runs, since dirname may answer in a buffer all its callers share.
jq_origin :: proc() -> string {
	return origin
}

set_origin :: proc() {
	origin = dir_name(os.args[0])
}

@(private = "file")
origin: string

// jq's PROGRAM_ORIGIN: the real path of the -f file's directory, or else of the working directory.
program_origin :: proc(ip: ^Interp) -> string {
	if ip.prog_origin != "" {
		return ip.prog_origin
	}
	return real_path(".")
}

// What stat tells of a path: a missing one is ENOENT, and an unreadable one any other failure.
Path_Kind :: enum {
	File,
	Dir,
	Missing,
	Unreadable,
}

@(private = "file")
member_string :: proc(o: Value, k: string) -> (string, bool) {
	v, _ := object_get(o, k)
	return string_of(v)
}

@(private = "file")
member_true :: proc(o: Value, k: string) -> bool {
	v, _ := object_get(o, k)
	b, is_bool := v.(bool)
	return is_bool && b
}

// ---- modulemeta

// The module the input names, found on the library directories alone: its `module` metadata, with its
// directives as `deps` and the names of its definitions as `defs`. A module that does not parse gives null,
// its errors printed.
fn_modulemeta :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	relpath, is_string := string_of(v)
	if !is_string {
		return nil, fail(ip, "modulemeta input module name must be a string")
	}
	path, msg := find_module(ip, relpath, lib_dirs(ip), ".jq", nil)
	if msg != "" {
		return nil, fail(ip, "%s", msg)
	}
	text, err := ip.load_file(path, true)
	if err != "" {
		return nil, fail(ip, "%s", err)
	}
	src, _ := string_of(text)
	prog, errors := parse_library(src, path, &ip.messages)
	if errors > 0 {
		return nil, .Go
	}
	meta := own(prog.meta).(^Object) if prog.meta != nil else new_object()
	deps := new_array(len(prog.deps))
	append(&deps.items, ..prog.deps)
	defs := new_array()
	outer: for d := prog.defs; d != nil; d = d.a {
		sig := fmt.aprintf("%s/%d", d.fn.name, len(d.fn.params))
		for s in defs.items {
			if s.(string) == sig {
				continue outer
			}
		}
		append(&defs.items, sig)
	}
	object_put(meta, "deps", deps)
	object_put(meta, "defs", defs)
	return meta, .Go
}
