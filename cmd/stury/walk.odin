package main

// The files a directory argument names: those under it in the byte order of their paths, so a directory's files come
// at its place among its siblings, as its name and a `/`. A walk reads a regular file whose extension names a format (the one
// --from names, when given) or that an including -g matches, unless an excluding -g matches it or a directory above
// it, or, inside a git work tree, an ignore rule as git reads them. It does not follow a symlink or enter a version
// control system's directory, and it judges a file by its name and its directory entry alone. A named file is read
// whatever these rules say.
//
// The walk publishes each path as it lists it (`walked`), on a thread of its own from the first directory on, so a
// run's tasks may read the first files while it lists the rest (`walk_path`).

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "message"

Entry_Kind :: enum u8 {
	Unknown, // the file system gives no kind, so one lstat tells it, or a named path names nothing
	File, // a regular file
	Long, // a regular file its stat found `FILES_LONG` or more, which the pieces read
	Dir,
	Other,
}

Dir_Entry :: struct {
	name: string,
	kind: Entry_Kind,
}

// A glob in gitignore's syntax: `*` and `?` within a name, `[...]` a class, `**` across directories. `!` before it
// negates it, a `/` after it matches only a directory, and a `/` before or inside it anchors it to the path below the
// walk's root, where one without matches a name at any depth.
Glob :: struct {
	pattern:                     string,
	negated, dir_only, anchored: bool,
}

@(rodata)
VCS_DIRS := []string{".git", ".hg", ".svn", ".jj"}

// The most paths a walk publishes: the regions below are reserved for them once, and filled as they come.
WALK_PATHS :: 1 << 26
@(private = "file")
WALK_COMMIT :: 1 << 16
// The paths published between wakes of the readers that wait, and at the end of each directory.
@(private = "file")
WALK_RUN :: 64

// The files a run reads: those named, and in a directory's place the files its walk finds, with the kind of each. A
// published path never moves, as the paths lie in a region reserved whole. `count` only grows, and `done` is set
// once every path is published.
Walked :: struct {
	paths:     [^]string,
	kinds:     [^]Entry_Kind,
	committed: int,
	count:     int,
	done:      bool,
	// Rung by a publish while a reader waits for one.
	bell:      sync.Futex,
	waiting:   i32,
	thread:    ^thread.Thread,
}

walked: Walked

// Whether a run may read the walk's files while it lists them, through `walk_path`. Until `walk_end` the list is not
// whole.
walk_streams: bool

// The directories a walk could not list and why, told by `open_file` at their place among the files. The walk's thread
// adds to it while a run reads it, under `unlisted_lock`, and `unlisted_count` spares a run with none the lock.
unlisted: map[string]os.Error
@(private = "file")
unlisted_lock: sync.Mutex
@(private = "file")
unlisted_count: int

// A rule of an ignore file, and the directory below the work tree's root whose files it is matched against: the
// directory of its .gitignore, or the root for the repository's and the user's excludes files.
@(private = "file")
Ignore :: struct {
	glob: Glob,
	base: string,
}

@(private = "file")
Walk :: struct {
	named:    []string,
	kinds:    []Entry_Kind, // the named paths'
	from_dir: int, // the first named directory, where the walk's thread starts
	globs:    []Glob,
	includes: bool, // some -g includes, so a file only such a -g matches is read
	from:     Maybe(Format),
	ignore:   bool,
	ignores:  [dynamic]Ignore, // the rules of the directories being walked, the deepest last
	above:    Maybe(string), // the walk's root below its work tree's root, nil outside one or under --no-ignore
}

@(private = "file")
the_walk: Walk

glob_of :: proc(text: string) -> (g: Glob) {
	p := text
	if strings.has_prefix(p, "!") {
		g.negated, p = true, p[1:]
	}
	if len(p) > 1 && strings.has_suffix(p, "/") {
		g.dir_only, p = true, p[:len(p) - 1]
	}
	g.anchored = strings.contains_rune(p, '/')
	g.pattern = strings.trim_prefix(p, "/")
	return
}

// Publishes `files` in `walked`, each directory among those past the first `kept` but "-" replaced by the files under
// it, the ignore rules applied when `ignore`, and leaves `files` the list published. Returns whether one was a
// directory. When `streams`, the walk's thread lists on while the run reads, and `files` holds none until `walk_end`.
walk_files :: proc(files: ^[dynamic]string, kept: int, globs: []Glob, from: Maybe(Format), ignore, streams: bool) -> (dirs: bool) {
	w := &the_walk
	w^ = {named = files[:], kinds = make([]Entry_Kind, len(files)), from_dir = len(files), globs = globs, from = from, ignore = ignore}
	w.includes = slice.any_of_proc(globs, proc(g: Glob) -> bool {return !g.negated})
	for path, i in w.named {
		kind, named := path_stat(path)
		w.kinds[i] = .Other if path == "-" else kind if named else .Unknown
		if i >= kept && w.kinds[i] == .Dir {
			w.from_dir = min(w.from_dir, i)
		}
	}
	paths, perr := virtual.reserve(WALK_PATHS * size_of(string))
	kinds, kerr := virtual.reserve(WALK_PATHS)
	if perr != nil || kerr != nil {
		out_of_memory()
	}
	walked = {paths = ([^]string)(raw_data(paths)), kinds = ([^]Entry_Kind)(raw_data(kinds))}
	for path, i in w.named[:w.from_dir] {
		publish(path, w.kinds[i])
	}
	dirs = w.from_dir < len(w.named)
	walked.thread = thread.create(walk_rest) if dirs else nil
	if walked.thread != nil {
		thread.start(walked.thread)
	} else {
		walk_rest(nil)
	}
	walk_streams = streams && dirs
	files^ = nil
	if !walk_streams {
		all := walk_end()
		files^ = transmute([dynamic]string)runtime.Raw_Dynamic_Array{raw_data(all), len(all), len(all), runtime.nil_allocator()}
	}
	return
}

// The named paths from the first directory on, published from the walk's thread when it has one.
@(private = "file")
walk_rest :: proc(_: ^thread.Thread) {
	w := &the_walk
	for path, i in w.named[w.from_dir:] {
		if kind := w.kinds[w.from_dir + i]; kind == .Dir {
			if !w.ignore || !open_work_tree(w, path) {
				walk_dir(w, path, "")
			}
			clear(&w.ignores)
			w.above = nil
		} else {
			publish(path, kind)
		}
	}
	sync.atomic_store(&walked.done, true)
	ring_walk()
}

// Path `k` of the run's files and its kind, once the walk has listed it, or false past the last. While it waits it
// lists the directories queued ahead of the walk.
walk_path :: proc(k: int) -> (path: string, kind: Entry_Kind, ok: bool) {
	for {
		if k < sync.atomic_load(&walked.count) {
			return walked.paths[k], walked.kinds[k], true
		}
		if sync.atomic_load(&walked.done) && k >= sync.atomic_load(&walked.count) {
			return
		}
		if list_ahead() {
			continue
		}
		sync.atomic_add(&walked.waiting, 1)
		bell := sync.atomic_load(&walked.bell)
		if k >= sync.atomic_load(&walked.count) && !sync.atomic_load(&walked.done) {
			sync.futex_wait(&walked.bell, u32(bell))
		}
		sync.atomic_sub(&walked.waiting, 1)
	}
}

// Every path of the run's files, once the walk has listed them.
walk_end :: proc() -> []string {
	if t := walked.thread; t != nil {
		thread.join(t)
		thread.destroy(t)
		walked.thread = nil
	}
	walk_streams = false
	return walked.paths[:walked.count]
}

// `files`, or every file of a walk that streams once it has listed them.
whole_files :: proc(files: []string) -> []string {
	return walk_end() if walk_streams else files
}

// The kind the walk found file `k` of `files` to be, `.Unknown` for a list that is not the walk's.
walk_kind :: proc(files: []string, k: int) -> Entry_Kind {
	return walked.kinds[k] if walked.paths != nil && raw_data(files) == walked.paths else .Unknown
}

@(private = "file")
publish :: proc(path: string, kind: Entry_Kind) {
	n := walked.count
	if n == walked.committed {
		if n == WALK_PATHS || virtual.commit(&walked.paths[n], WALK_COMMIT * size_of(string)) != nil || virtual.commit(&walked.kinds[n], WALK_COMMIT) != nil {
			out_of_memory()
		}
		walked.committed += WALK_COMMIT
	}
	walked.paths[n], walked.kinds[n] = path, kind
	sync.atomic_store(&walked.count, n + 1)
	// Readers that wait are woken for a run of paths, not each one: a wake costs more than a run of lists.
	if n % WALK_RUN == WALK_RUN - 1 {
		ring_walk()
	}
}

@(private = "file")
ring_walk :: proc() {
	if sync.atomic_load(&walked.waiting) > 0 {
		sync.atomic_add(&walked.bell, 1)
		sync.futex_broadcast(&walked.bell)
	}
}

// The error the walk could not list the directory `path` with, if it could not.
unlisted_error :: proc(path: string) -> (err: os.Error, unread: bool) {
	if sync.atomic_load(&unlisted_count) == 0 {
		return
	}
	sync.guard(&unlisted_lock)
	return unlisted[path]
}

@(private = "file")
walk_dir :: proc(w: ^Walk, dir, rel: string, ahead := -1) {
	entries, err := take_listing(dir, ahead)
	defer {
		for e in entries {
			delete(e.name)
		}
		delete(entries)
	}
	if err != nil {
		kept := strings.clone(dir)
		sync.lock(&unlisted_lock)
		unlisted[kept] = err
		sync.atomic_add(&unlisted_count, 1)
		sync.unlock(&unlisted_lock)
		publish(kept, .Other)
		return
	}
	slice.sort_by(entries[:], walk_before)
	// The names below the root as typed are joined with `/` on every system, so a path reads the same everywhere.
	sep := "" if os.is_path_separator(dir[len(dir) - 1]) else "/"
	pushed := len(w.ignores)
	defer resize(&w.ignores, pushed)
	for e in entries {
		if e.name == ".gitignore" && w.above != nil {
			read_ignores(w, strings.concatenate({dir, sep, e.name}, context.temp_allocator), under(w, rel))
		}
	}
	// What the walk does with each entry, settled before it enters any, so the directories it enters are queued to be
	// listed ahead of it: the slot of one queued, -1 for one not, -2 for a file it reads and -3 for an entry it passes.
	Step :: struct {
		path, sub: string,
		ahead:     int,
	}
	steps := make([]Step, len(entries), context.temp_allocator)
	for e, i in entries {
		path := strings.concatenate({dir, sep, e.name})
		sub := strings.concatenate({rel, "/", e.name}, context.temp_allocator) if rel != "" else e.name
		kind := e.kind
		if kind == .Unknown {
			info, lerr := os.lstat(path, context.temp_allocator)
			kind = .Other if lerr != nil else .File if info.type == .Regular else .Dir if info.type == .Directory else .Other
		}
		steps[i] = {path, sub, -3}
		switch {
		case kind == .Dir && !slice.contains(VCS_DIRS, e.name) && !ignored(w, under(w, sub), true) && !last_negated(w.globs, sub, true):
			steps[i].ahead = queue_listing(path)
		case kind == .File && !ignored(w, under(w, sub), false) && walk_reads(w, sub, e.name):
			steps[i].ahead = -2
		}
	}
	ring_walk()
	for s in steps {
		switch s.ahead {
		case -2:
			publish(s.path, .File)
			continue
		case -3:
		case:
			walk_dir(w, s.path, s.sub, s.ahead)
		}
		delete(s.path)
	}
	ring_walk()
}

// A directory the walk is to enter, listed ahead of it by a reader of its files that would otherwise wait for it.
@(private = "file")
Listing :: struct {
	path:    string,
	entries: [dynamic]Dir_Entry,
	err:     os.Error,
	state:   i32,
}

@(private = "file")
LISTING_FREE :: 0
@(private = "file")
LISTING_QUEUED :: 1
@(private = "file")
LISTING_TAKEN :: 2
@(private = "file")
LISTING_DONE :: 3

// The directories queued, the `queued`th in slot `queued % LISTINGS`, and the next a reader takes.
@(private = "file")
LISTINGS :: 4096
@(private = "file")
listings: [LISTINGS]Listing
@(private = "file")
queued, listed_next: int

// The slot `path` is queued in to be listed ahead, or -1 when every slot is full.
@(private = "file")
queue_listing :: proc(path: string) -> int {
	k := queued % LISTINGS
	l := &listings[k]
	if sync.atomic_load(&l.state) != LISTING_FREE {
		return -1
	}
	l.path = path
	sync.atomic_store(&l.state, LISTING_QUEUED)
	sync.atomic_store(&queued, queued + 1)
	return k
}


// The entries of directory `dir`, listed ahead in slot `ahead` or else now, and the slot freed.
@(private = "file")
take_listing :: proc(dir: string, ahead: int) -> (entries: [dynamic]Dir_Entry, err: os.Error) {
	if ahead < 0 {
		return list_dir(dir)
	}
	l := &listings[ahead]
	if _, took := sync.atomic_compare_exchange_strong(&l.state, LISTING_QUEUED, LISTING_TAKEN); took {
		entries, err = list_dir(dir)
	} else {
		for sync.atomic_load(&l.state) != LISTING_DONE {
			thread.yield()
		}
		entries, err = l.entries, l.err
	}
	l^ = {}
	sync.atomic_store(&l.state, LISTING_FREE)
	return
}

// Lists a directory queued ahead of the walk when the paths it has listed past path `k` run short: a directory's open
// costs as much as a file's, so a walk that lists alone falls behind the readers.
help_walk :: proc(k: int) {
	if sync.atomic_load(&walked.count) - k < WALK_BACKLOG && !sync.atomic_load(&walked.done) {
		list_ahead()
	}
}

@(private = "file")
WALK_BACKLOG :: 1024

// Lists the next directory queued ahead of the walk. False when none is queued.
@(private = "file")
list_ahead :: proc() -> bool {
	for {
		k := sync.atomic_load(&listed_next)
		if k >= sync.atomic_load(&queued) {
			return false
		}
		if _, took := sync.atomic_compare_exchange_strong(&listed_next, k, k + 1); !took {
			continue
		}
		l := &listings[k % LISTINGS]
		if _, took := sync.atomic_compare_exchange_strong(&l.state, LISTING_QUEUED, LISTING_TAKEN); took {
			context.allocator = runtime.heap_allocator()
			l.entries, l.err = list_dir(l.path)
			sync.atomic_store(&l.state, LISTING_DONE)
			return true
		}
	}
}

// Adds the files the list file `list` names, its lines or the names between NULs when it holds one. A list on stdin
// leaves no stdin to read an input from.
list_files :: proc(files: ^[dynamic]string, list: string) {
	text: []byte
	err: os.Error
	if list == "-" {
		text, err = os.read_entire_file(os.stdin, context.allocator)
	} else {
		text, err = os.read_entire_file(list, context.allocator)
	}
	if err != nil {
		message.write_stderr("stury: error: Could not open file %s: %s\n", list, strerror(err))
		os.exit(EXIT_USAGE)
	}
	s := string(text)
	nul := strings.index_byte(s, 0) >= 0
	for line in strings.split_iterator(&s, "\x00" if nul else "\n") {
		if name := line if nul else strings.trim_suffix(line, "\r"); name != "" {
			append(files, name)
		}
	}
	if list == "-" && slice.contains(files[:], "-") {
		usage_error("--files-from - reads the list of files from standard input, which then holds no input")
	}
}

// Finds the git work tree `root` is in, a directory holding a `.git` at or above it, and takes the rules that apply
// above `root`: the user's excludes file, the repository's `info/exclude`, and the .gitignore files from the work
// tree's root down to `root`'s parent. True when they skip `root` or a directory above it, as git skips what is in an
// ignored directory.
@(private = "file")
open_work_tree :: proc(w: ^Walk, root: string) -> (skipped: bool) {
	temp := context.temp_allocator
	abs, err := os.get_absolute_path(root, temp)
	top := abs
	for err == nil && !os.exists(strings.concatenate({top, "/.git"}, temp)) {
		parent := os.dir(top)
		if parent == top {
			return
		}
		top = parent
	}
	if err != nil {
		return
	}
	above, _ := strings.replace_all(strings.trim_left(abs[len(top):], "/\\"), "\\", "/", temp)
	w.above = above
	read_ignores(w, global_excludes(), "")
	git := strings.concatenate({top, "/.git"}, temp)
	// A linked work tree's `.git` is a file naming its git directory, whose `commondir` names the repository's.
	if text, ferr := os.read_entire_file(git, temp); ferr == nil {
		named := strings.trim_space(strings.trim_prefix(string(text), "gitdir:"))
		git = named if os.is_absolute_path(named) else strings.concatenate({top, "/", named}, temp)
		if common, cerr := os.read_entire_file(strings.concatenate({git, "/commondir"}, temp), temp); cerr == nil {
			git = strings.concatenate({git, "/", strings.trim_space(string(common))}, temp)
		}
	}
	read_ignores(w, strings.concatenate({git, "/info/exclude"}, temp), "")
	if above != "" {
		read_ignores(w, strings.concatenate({top, "/.gitignore"}, temp), "")
	}
	for c, i in above {
		if c == '/' {
			skipped ||= ignored(w, above[:i], true)
			read_ignores(w, strings.concatenate({top, "/", above[:i], "/.gitignore"}, temp), above[:i])
		}
	}
	return skipped || above != "" && ignored(w, above, true)
}

// Whether entry `a`'s path sorts before `b`'s, a directory's read on with its `/`.
@(private = "file")
walk_before :: proc(a, b: Dir_Entry) -> bool {
	n := min(len(a.name), len(b.name))
	if a.name[:n] != b.name[:n] {
		return a.name[:n] < b.name[:n]
	}
	after :: proc(e: Dir_Entry, n: int) -> int {
		return int(e.name[n]) if n < len(e.name) else '/' if e.kind == .Dir else -1
	}
	return after(a, n) < after(b, n)
}

// Whether the walk reads the file `name` at `rel` below its root.
@(private = "file")
walk_reads :: proc(w: ^Walk, rel, name: string) -> bool {
	#reverse for g in w.globs {
		if glob_matches(g, rel, false) {
			return !g.negated
		}
	}
	f, named := format_of_file(name)
	return !w.includes && named && (w.from == nil || f == w.from.?)
}

// Whether the last of `globs` that matches `rel` negates it.
@(private = "file")
last_negated :: proc(globs: []Glob, rel: string, dir: bool) -> bool {
	#reverse for g in globs {
		if glob_matches(g, rel, dir) {
			return g.negated
		}
	}
	return false
}

glob_matches :: proc(g: Glob, rel: string, dir: bool) -> bool {
	if g.dir_only && !dir {
		return false
	}
	return glob_match(g.pattern, rel if g.anchored else rel[strings.last_index_byte(rel, '/') + 1:])
}

// Whether the glob `p` matches all of `s`.
glob_match :: proc(p, s: string) -> bool {
	p, s := p, s
	for len(p) > 0 {
		switch {
		case strings.has_prefix(p, "**/"):
			// No directory or any number of them.
			for rest := s; !glob_match(p[3:], rest); {
				slash := strings.index_byte(rest, '/')
				if slash < 0 {
					return false
				}
				rest = rest[slash + 1:]
			}
			return true
		case p == "**":
			return true
		case p[0] == '*':
			for i in 0 ..= len(s) {
				if glob_match(p[1:], s[i:]) {
					return true
				}
				if i < len(s) && s[i] == '/' {
					break
				}
			}
			return false
		case len(s) == 0:
			return false
		case p[0] == '?':
			if s[0] == '/' {
				return false
			}
			p = p[1:]
		case p[0] == '[' && class_end(p) > 0:
			if s[0] == '/' || !class_match(p, s[0]) {
				return false
			}
			p = p[class_end(p):]
		case:
			if p[0] == '\\' && len(p) > 1 {
				p = p[1:]
			}
			if fold(p[0]) != fold(s[0]) {
				return false
			}
			p = p[1:]
		}
		s = s[1:]
	}
	return len(s) == 0
}

// A glob matches case-blind where file systems most often are, as git's core.ignorecase is there by default.
@(private = "file")
fold :: #force_inline proc(c: byte) -> byte {
	return c + 32 if (ODIN_OS == .Darwin || ODIN_OS == .Windows) && 'A' <= c && c <= 'Z' else c
}

// The length of the class `p` opens with, `!` or `^` after `[` negating it and a `]` first a member, or 0 when no `]`
// closes it.
@(private = "file")
class_end :: proc(p: string) -> int {
	i := 1
	i += int(i < len(p) && (p[i] == '!' || p[i] == '^'))
	close := strings.index_byte(p[min(i + 1, len(p)):], ']')
	return 0 if close < 0 else i + 1 + close + 1
}

// Whether byte `c` is in the class `p` opens with.
@(private = "file")
class_match :: proc(p: string, c: byte) -> bool {
	end := class_end(p) - 1
	negated := p[1] == '!' || p[1] == '^'
	in_class := false
	for i := 1 + int(negated); i < end; i += 1 {
		lo, hi := p[i], p[i]
		if i + 2 < end && p[i + 1] == '-' {
			hi = p[i + 2]
			i += 2
		}
		in_class ||= lo <= c && c <= hi || fold(lo) <= fold(c) && fold(c) <= fold(hi)
	}
	return in_class != negated
}

// The user's git excludes file: `core.excludesFile` of ~/.gitconfig, else `$XDG_CONFIG_HOME/git/ignore`, else
// ~/.config/git/ignore.
@(private = "file")
global_excludes :: proc() -> string {
	temp := context.temp_allocator
	home, _ := home_dir(nil)
	if text, err := os.read_entire_file(strings.concatenate({home, "/.gitconfig"}, temp), temp); err == nil {
		s, section := string(text), ""
		for raw in strings.split_lines_iterator(&s) {
			line := strings.trim_space(raw)
			key, eq, value := strings.partition(line, "=")
			if strings.has_prefix(line, "[") {
				section = line
			} else if eq != "" && strings.equal_fold(section, "[core]") && strings.equal_fold(strings.trim_space(key), "excludesfile") {
				path := strings.trim(strings.trim_space(value), "\"")
				return strings.concatenate({home, path[1:]}, temp) if strings.has_prefix(path, "~/") else path
			}
		}
	}
	if config := os.get_env("XDG_CONFIG_HOME", temp); config != "" {
		return strings.concatenate({config, "/git/ignore"}, temp)
	}
	return strings.concatenate({home, "/.config/git/ignore"}, temp)
}

// Adds the rules of the ignore file `path`, if there is one, for the files below `base`. A line is a glob, or a
// comment after `#`, with its trailing spaces cut unless a backslash keeps the last, and its CR before a LF.
@(private = "file")
read_ignores :: proc(w: ^Walk, path, base: string) {
	text, err := os.read_entire_file(long_path(path), context.allocator)
	if err != nil {
		return
	}
	s := string(text)
	for raw in strings.split_lines_iterator(&s) {
		line := raw
		for strings.has_suffix(line, " ") && !strings.has_suffix(line, "\\ ") {
			line = line[:len(line) - 1]
		}
		if line != "" && line[0] != '#' {
			append(&w.ignores, Ignore{glob_of(line), strings.clone(base)})
		}
	}
}

// The path `rel` below the walk's root as a path below its work tree's root.
@(private = "file")
under :: proc(w: ^Walk, rel: string) -> string {
	above := w.above.? or_else ""
	return rel if above == "" else above if rel == "" else strings.concatenate({above, "/", rel}, context.temp_allocator)
}

// Whether the ignore rules skip the file or directory `path` below the work tree's root: the last rule that matches
// it decides.
@(private = "file")
ignored :: proc(w: ^Walk, path: string, dir: bool) -> bool {
	if len(w.ignores) == 0 {
		return false
	}
	#reverse for r in w.ignores {
		p := path
		if r.base != "" {
			if len(path) <= len(r.base) || path[len(r.base)] != '/' || !strings.has_prefix(path, r.base) {
				continue
			}
			p = path[len(r.base) + 1:]
		}
		if glob_matches(r.glob, p, dir) {
			return !r.glob.negated
		}
	}
	return false
}
