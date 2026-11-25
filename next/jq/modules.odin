package jq

// jq 1.8.2's linker: `import PATH as NAME;` brings a module's definitions in as `NAME::f`, `include PATH;` brings them in
// as they are, and `import PATH as $NAME;` binds a JSON file's values, as an array, to `$NAME::NAME` and `$NAME`. A later
// import shadows an earlier one, and the program's own definitions shadow both. A module is only definitions. It sees
// what it imports, the builtins and the variables the program is compiled with, never its importer's definitions.
//
// A directive's dependency is found on its search path: the metadata's `search` (a string or an array), or "." and then
// `Modules.search`. In each directory PATH is tried as `PATH.jq`, `PATH/jq/main.jq` and `PATH/BASENAME.jq` (`.json` for
// data). A directory `~/` begins is under `Modules.home`, `$ORIGIN/` under `Modules.jq_origin`, `./` under the
// importer's directory, and any other relative one under it too, except "." itself, which is the working directory.
// With a `home` set, `$HOME/.jq` is included into every program when it is a file, as jq does.
//
// Dependencies load in reverse order, each module once, its own first. jq's messages and count of errors follow: a
// dependency that cannot be found, a malformed PATH or a cycle stops its importer's list with one error. A module that
// does not parse, or is not only definitions, or a data file that does not read, counts its errors and the list goes on.

import "base:runtime"
import "core:fmt"
import "core:path/slashpath"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/query"

// Where the files of modules and data come from. The package reads no file itself.
Loader :: struct {
	data:       rawptr,
	// The text of the file at `path`, allocated with `allocator`, or `ok` false when there is no such file.
	read:       proc(data: rawptr, path: string, allocator: runtime.Allocator) -> (text: string, ok: bool),
	// Parses JSON data files (`import "..." as $name`). Without it non-raw JSON data imports fail.
	parse_json: Json_Parser,
}

// What a program's modules and the builtins about them are given. Every path is the caller's spelling, joined and
// cleaned lexically: the caller gives absolute directories to get absolute paths in messages and `$__loc__`.
Modules :: struct {
	loader:    Loader,
	search:    []string, // `-L`'s directories: `get_search_list`, and where a directive without `search` looks after "."
	origin:    string, // jq's PROGRAM_ORIGIN, the directory of the program's file or the working directory
	jq_origin: string, // jq's JQ_ORIGIN, the directory of the executable, which `$ORIGIN/` stands for
	home:      string, // what `~/` stands for, "" for none
}

// A module or data file the program reaches, loaded.
@(private)
Lib :: struct {
	path:    string,
	src:     string,
	imports: []Import,
	defs:    ^Node, // its definitions, a chain of `Def` nodes
	entries: []^Scope, // the scope entry of each definition, made by binding
	data:    query.Value, // a data file's values
	is_data: bool,
}

// A dependency as its importer binds it: under `name::` (nothing for `include`), or a data file as `$name`. `lib` is
// nil for an optional one not found.
@(private)
Import :: struct {
	lib:  ^Lib,
	name: string,
}

// A directive's dependency, as `Parsed.deps` holds it.
@(private = "file")
Dep :: struct {
	name, relpath: string,
	search:        []string,
	has_search:    bool,
	is_data:       bool,
	raw:           bool,
	optional:      bool,
}

// Modules nest no deeper than this, as linking recurses once for each level.
@(private = "file")
MAX_IMPORT_DEPTH :: 256

@(private = "file")
Linker :: struct {
	m:         ^Modules,
	u:         ^Unit,
	libs:      [dynamic]^Lib,
	loading:   [dynamic]string, // the modules being loaded, outermost first
	errors:    ^[dynamic]Compile_Error,
	max_depth: int,
}

// What the program's directives import, and every module that takes, each after those it imports, or the errors
// appended to `errors`.
@(private)
link :: proc(m: ^Modules, u: ^Unit, deps: []query.Value, errors: ^[dynamic]Compile_Error, max_depth: int) -> (imports: []Import, libs: []^Lib) {
	list := make([dynamic]Dep, 0, len(deps) + 1)
	if m.home != "" {
		append(&list, Dep{optional = true, search = slice.clone([]string{m.home}), has_search = true})
	}
	for d in deps {
		append(&list, dep_of(d))
	}
	l := Linker{m = m, u = u, errors = errors, max_depth = max_depth}
	imports, _ = process(&l, list[:], m.origin)
	return imports, l.libs[:]
}

@(private = "file")
dep_of :: proc(v: query.Value) -> (d: Dep) {
	for e in query.entries_of(v) {
		switch query.text_of(e.key) {
		case "as":
			d.name = query.text_of(e.value) if query.is_text(e.value) else ""
		case "relpath":
			d.relpath = query.text_of(e.value) if query.is_text(e.value) else ""
		case "is_data":
			d.is_data = e.value.kind == .True
		case "raw":
			d.raw = e.value.kind == .True
		case "optional":
			d.optional = e.value.kind == .True
		case "search":
			d.has_search, d.search = true, search_entries(e.value)
		}
	}
	return
}

// The directories a `search` value names: its string, or the strings of its array.
@(private = "file")
search_entries :: proc(v: query.Value) -> []string {
	if query.is_text(v) {
		return slice.clone([]string{query.text_of(v)})
	}
	if v.kind != .Array {
		return nil
	}
	out := make([dynamic]string)
	for x in query.items_of(v) {
		if query.is_text(x) {
			append(&out, query.text_of(x))
		}
	}
	return out[:]
}

// Each of `deps`, last first: found, loaded unless it was, and bound. One that cannot be found ends the list as one
// error, as a cycle does.
@(private = "file")
process :: proc(l: ^Linker, deps: []Dep, origin: string) -> (imports: []Import, count: int) {
	imports = make([]Import, len(deps))
	listed := len(l.errors^)
	#reverse for dep, i in deps {
		search, from := dep.search, origin
		if !dep.has_search {
			// The library directories are the caller's, not relative to the importer.
			search, from = default_search(l.m), ""
		}
		path, text, msg := find_module(l.m, dep.relpath, search, ".json" if dep.is_data else ".jq", from)
		if msg != "" {
			if dep.optional {
				continue
			}
			return imports, stop_list(l, listed, msg)
		}
		if slice.contains(l.loading[:], path) {
			return imports, stop_list(l, listed, fmt.aprintf("circular import of %s", path))
		}
		lib: ^Lib
		for x in l.libs {
			if !dep.is_data && x.path == path {
				lib = x
			}
		}
		if lib == nil {
			n: int
			lib, n = load(l, path, text, dep.is_data, dep.raw)
			count += n
		}
		imports[i] = {lib, dep.name}
	}
	return
}

// Ends an import list with `msg`, which jq counts as the list's one error.
@(private = "file")
stop_list :: proc(l: ^Linker, listed: int, msg: string) -> int {
	for &e in l.errors[listed:] {
		e.uncounted = true
	}
	append(l.errors, Compile_Error{msg = msg, kind = .Unlocated})
	return 1
}

// The module or data file at `path`, whose text is `text`, and jq's count of its errors. It is nil if it has any.
@(private = "file")
load :: proc(l: ^Linker, path, text: string, is_data, raw: bool) -> (^Lib, int) {
	if is_data {
		v, msg := data_values(l.u, l.m.loader, text, raw)
		if msg != "" {
			append(l.errors, Compile_Error{msg = fmt.aprintf("jq: error loading data file %s: %s", path, msg), kind = .Raw})
			return nil, 1
		}
		return new_clone(Lib{path = path, data = v, is_data = true}), 0
	}
	errors := len(l.errors^)
	prog := parse_library(l.u, text, path, l.errors, l.max_depth)
	if len(l.errors^) > errors {
		return nil, len(l.errors^) - errors
	}
	if len(l.loading) >= MAX_IMPORT_DEPTH {
		append(l.errors, Compile_Error{msg = fmt.aprintf("modules are imported more than %d deep at %s", MAX_IMPORT_DEPTH, path), kind = .Unlocated})
		return nil, 1
	}
	append(&l.loading, path)
	deps := make([]Dep, len(prog.deps))
	for d, i in prog.deps {
		deps[i] = dep_of(d)
	}
	imports, n := process(l, deps, slashpath.dir(path))
	pop(&l.loading)
	if n > 0 {
		return nil, n
	}
	lib := new_clone(Lib{path = path, src = text, imports = imports, defs = prog.defs})
	append(&l.libs, lib)
	return lib, 0
}

// `src` parsed as the module at `path`, its errors put in `errors`, a main expression among them.
@(private)
parse_library :: proc(u: ^Unit, src, path: string, errors: ^[dynamic]Compile_Error, max_depth: int) -> Parsed {
	before := len(errors^)
	prog := parse(u, src, errors, max_depth, path)
	if len(errors^) == before && prog.body != nil {
		append(errors, Compile_Error{msg = "library should only have function definitions, not a main expression", kind = .Unlocated})
	}
	return prog
}

// The values of data file `text` as the array `$name` is bound to, or its text under `raw`, made in the unit's heap and
// frozen. The file holds a sequence of zero or more JSON values.
@(private = "file")
data_values :: proc(u: ^Unit, loader: Loader, text: string, raw: bool) -> (v: query.Value, msg: string) {
	if raw {
		return query.text_borrowed(text), ""
	}
	h := &u.heap
	out, _ := query.make_array(h, 1)
	rem := transmute([]u8)strings.trim_space(text)
	if len(rem) > 0 && loader.parse_json == nil {
		query.release(h, out)
		return query.NULL, "JSON parser is not configured"
	}
	for len(rem) > 0 {
		doc, err := loader.parse_json(loader.data, rem, {}, u.allocator)
		adv := len(rem)
		if err != nil {
			f, is_fault := err.(tape.Fault)
			if is_fault && f.kind == .Bad_Char && f.at > 0 && f.at < u64(len(rem)) {
				tape.destroy(&doc)
				doc, err = loader.parse_json(loader.data, rem[:f.at], {}, u.allocator)
				adv = int(f.at)
			}
			if err != nil {
				tape.destroy(&doc)
				query.release(h, out)
				buf: [256]u8
				return query.NULL, strings.clone(tape.error_message(buf[:], err, rem))
			}
		}
		x, _ := query.document_value(h, doc, true)
		built, _ := query.built_deep(h, x)
		query.release(h, x)
		_ = query.append_owned(h, &out, built)
		rem = transmute([]u8)strings.trim_space(string(rem[adv:]))
	}
	return query.freeze(out), ""
}

// ---- Finding a module

// The search path a directive without `search` has: ".", then the library directories.
@(private = "file")
default_search :: proc(m: ^Modules) -> []string {
	all := make([]string, 1 + len(m.search))
	all[0] = "."
	copy(all[1:], m.search)
	return all
}

// The module `relpath` names on the search path `search`, with `suffix`: its path and text. Relative entries start from
// the directory `origin` (none if empty). When there is no such module, `msg` is jq's message.
@(private)
find_module :: proc(m: ^Modules, relpath: string, search: []string, suffix: string, origin: string) -> (path, text, msg: string) {
	if msg = check_relpath(relpath); msg != "" {
		return
	}
	dirs, expand_error := search_dirs(m, search, origin)
	base := relpath[strings.last_index_byte(relpath, '/') + 1:]
	for dir in dirs {
		if dir == "" || m.loader.read == nil {
			continue
		}
		tries := [3]string {
			fmt.aprintf("%s/%s%s", dir, relpath, suffix),
			fmt.aprintf("%s/%s/jq/main%s", dir, relpath, suffix),
			fmt.aprintf("%s/%s/%s%s", dir, relpath, base, suffix),
		}
		for try in tries {
			found := slashpath.clean(try)
			if body, ok := m.loader.read(m.loader.data, found, context.allocator); ok {
				return found, body, ""
			}
		}
	}
	if expand_error != "" {
		return "", "", fmt.aprintf("module not found: %s (%s)", relpath, expand_error)
	}
	return "", "", fmt.aprintf("module not found: %s", relpath)
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
search_dirs :: proc(m: ^Modules, search: []string, origin: string) -> (dirs: [dynamic]string, expand_error: string) {
	for entry in search {
		dir := entry
		if len(dir) > 1 && dir[0] == '~' && dir[1] == '/' {
			if m.home == "" {
				expand_error = fmt.aprintf("Could not expand %s. (Could not find home directory.)", dir)
				continue
			}
			dir = strings.concatenate({m.home, dir[1:]})
		}
		switch {
		case dir == ".":
		case strings.has_prefix(dir, "./"):
			if origin != "" {
				dir = fmt.aprintf("%s/%s", origin, dir[2:])
			}
		case strings.has_prefix(dir, "$ORIGIN/"):
			dir = fmt.aprintf("%s/%s", m.jq_origin, dir[len("$ORIGIN/"):])
		case origin != "" && !is_absolute(dir):
			dir = fmt.aprintf("%s/%s", origin, dir)
		}
		append(&dirs, dir)
	}
	return
}

@(private = "file")
is_absolute :: proc(dir: string) -> bool {
	return strings.has_prefix(dir, "/") || (len(dir) > 1 && dir[1] == ':')
}
