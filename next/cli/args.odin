package cli

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"
import "stury:engine"
import "stury:lib/core/tape"
import "stury:lib/ops/diff"
import "stury:lib/schema/schema"

VERSION_DEFINE :: #config(STURY_VERSION, "dev")
VERSION :: VERSION_DEFINE[1:len(VERSION_DEFINE) - 1] when len(VERSION_DEFINE) >= 2 && VERSION_DEFINE[0] == '"' else VERSION_DEFINE
BUILD_CONFIG :: "odin " + ODIN_VERSION + " -target:" + ODIN_OS_STRING + "_" + ODIN_ARCH_STRING + " " + OPT_MODE

@(private = "file")
OPT_MODE :: "-o:speed" when ODIN_OPTIMIZATION_MODE == .Speed else "-o:aggressive" when ODIN_OPTIMIZATION_MODE == .Aggressive else "-o:size" when ODIN_OPTIMIZATION_MODE == .Size else "-o:minimal" when ODIN_OPTIMIZATION_MODE == .Minimal else "-o:none"

Command :: enum u8 {
	Run,
	Check,
	Fmt,
	Edit,
	Schema,
	Diff,
}

Schema_Verb :: enum u8 {
	None,
	Infer,
	Sample,
	Odin,
	Check,
	Diff,
}

Compat :: enum u8 {
	None,
	Backward,
	Forward,
	Full,
}

Report_Kind :: enum u8 {
	Lines,
	Basic,
	Problem,
}

Color_Mode :: enum u8 {
	Auto,
	Always,
	Never,
}

Output_Render :: enum u8 {
	None,
	Table,
	Markdown,
}

Var_Kind :: enum u8 {
	Arg,
	Arg_Json,
	Raw_File,
	Slurp_File,
}

Rest_Mode :: enum u8 {
	Files,
	Args,
	Json_Args,
}

Var_Spec :: struct {
	name: string,
	raw:  string,
	kind: Var_Kind,
}

Pos_Spec :: struct {
	raw:     string,
	is_json: bool,
}

With_Spec :: struct {
	name:    string,
	path:    string,
	has_fmt: bool,
	spec:    engine.Spec,
	framing: engine.Framing,
}

Options :: struct {
	command:           Command,
	schema_verb:       Schema_Verb,
	jsonpath:          bool,
	compact:           bool,
	indent_set:        bool,
	tab:               bool,
	raw:               bool,
	join:              bool,
	raw0:              bool,
	ascii:             bool,
	sort_keys:         bool,
	unbuffered:        bool,
	null_input:        bool,
	slurp:             bool,
	raw_input:         bool,
	from_file:         bool,
	seq:               bool,
	stream:            bool,
	stream_errors:     bool,
	exit_status:       bool,
	where_mode:        bool,
	explain:           bool,
	in_place:          bool,
	check:             bool,
	reflow:            bool,
	diff_preview:      bool,
	each:              bool,
	no_filename:       bool,
	has_from:          bool,
	has_to:            bool,
	skip_bad:          bool,
	infer:             bool,
	grow_header:       bool,
	dsv_in_set:        bool,
	dsv_out_set:       bool,
	schema_flag_set:   bool,
	format_assert:     bool,
	ranges:            bool,
	invalid:           bool,
	comments:          bool,
	diff_patch:        bool,
	diff_json:         bool,
	diff_facts:        bool,
	diff_shape:        bool,
	show_help:         bool,
	show_version:      bool,
	show_build_config: bool,
	indent:            i8,
	color_mode:        Color_Mode,
	from_spec:         engine.Spec,
	to_spec:           engine.Spec,
	from_framing:      engine.Framing,
	to_framing:        engine.Framing,
	to_name:           string,
	to_render:         Output_Render,
	dups:              tape.Duplicates,
	budget:            tape.Budget,
	threads:           int,
	max_errors:        int,
	count:             int,
	seed:              u64,
	quarantine:        string,
	plan_out:          string,
	plan_file:         string,
	schema_file:       string,
	schema_ref:        string,
	schema_package:    string,
	old_schema:        string,
	new_schema:        string,
	schema_draft:      Maybe(schema.Draft),
	report:            Report_Kind,
	compat:            Compat,
	dsv_in:            tape.Dsv_Options,
	dsv_out:           tape.Dsv_Options,
	dsv_tolerate:      tape.Tolerances,
	xml_tolerate:      tape.Tolerances,
	xml_arrays:        tape.Xml_Arrays,
	xml_arrays_set:    bool,
	yaml_schema:       tape.Yaml_Dialect,
	yaml_schema_set:   bool,
	merge_keys:        bool,
	alias_limit_set:   bool,
	redact_paths:      [dynamic]string,
	diff_arrays:       diff.Arrays,
	diff_keys_raw:     [dynamic]string,
	diff_keys:         [dynamic]diff.Key_Rule,
	filter:            Maybe(string),
	files:             [dynamic]string,
	vars:              [dynamic]Var_Spec,
	with_sources:      [dynamic]With_Spec,
	positional:        [dynamic]Pos_Spec,
	lib_dirs:          [dynamic]string,
	allocator:         runtime.Allocator,
}

options_destroy :: proc(o: ^Options) {
	if o == nil || o.allocator.procedure == nil {
		return
	}
	a := o.allocator
	for kr in o.diff_keys {
		delete(kr.at, a)
	}
	delete(o.diff_keys)
	delete(o.diff_keys_raw)
	delete(o.redact_paths)
	delete(o.files)
	delete(o.vars)
	delete(o.with_sources)
	delete(o.positional)
	delete(o.lib_dirs)
	o^ = {}
}

parse_format :: proc(raw: string) -> (spec: engine.Spec, framing: engine.Framing, ok: bool) {
	e, fr, found := engine.format_and_framing_by_name(raw)
	return e.spec, fr, found
}

parse_output_render :: proc(raw: string) -> (Output_Render, bool) {
	if strings.equal_fold(raw, "table") {
		return .Table, true
	}
	if strings.equal_fold(raw, "markdown") || strings.equal_fold(raw, "md") {
		return .Markdown, true
	}
	return .None, false
}

@(private = "file")
choice_idx :: proc(val: string, choices: []string) -> (int, bool) {
	for c, i in choices {
		if val == c {
			return i, true
		}
	}
	return -1, false
}

@(private = "file")
parse_char_arg :: proc(s: string) -> (u8, bool) {
	switch s {
	case `\t`:
		return '\t', true
	case `\r`:
		return '\r', true
	case `\n`:
		return '\n', true
	}
	if len(s) == 1 && s[0] < 0x80 {
		return s[0], true
	}
	return 0, false
}

// As in jq: only `--...` or `-` followed by an ASCII letter is an option; negative numbers like `-1` are filters.
@(private = "file")
is_option :: proc(a: string) -> bool {
	return len(a) >= 2 && a[0] == '-' && (a[1] == '-' || ('a' <= a[1] && a[1] <= 'z') || ('A' <= a[1] && a[1] <= 'Z'))
}

@(private = "file")
opt_arity :: proc(flag: string, cmd := Command.Run) -> int {
	if cmd == .Diff && flag == "--schema" {
		return 0
	}
	switch flag {
	case "--indent", "--max-depth", "--max-memory", "--max-steps", "--max-nodes", "--expansion-limit", "--alias-limit", "--threads",
	     "--from", "--in", "--to", "--out", "--dups", "--quarantine", "--plan-out", "--plan-file", "-L", "--library-path",
	     "--schema", "--schema-ref", "--schema-draft", "--max-errors", "--report", "--package", "--redact",
	     "--seed", "--count", "--old-schema", "--new-schema", "--compat", "--key", "--with",
	     "--delimiter", "--comment", "--out-delimiter", "--out-comment", "--xml-arrays", "--yaml-schema":
		return 1
	case "--arg", "--argjson", "--rawfile", "--slurpfile":
		return 2
	}
	return 0
}

@(private = "file")
split_long_eq :: proc(a: string, cmd := Command.Run) -> (flag, val: string, has_eq: bool) {
	if strings.has_prefix(a, "--") {
		if eq := strings.index_byte(a, '='); eq > 2 && opt_arity(a[:eq], cmd) == 1 {
			return a[:eq], a[eq + 1:], true
		}
	}
	return a, "", false
}

@(private = "file")
short_has_from_file :: proc(a: string) -> bool {
	if !is_option(a) || a[1] == '-' {
		return false
	}
	for k := 1; k < len(a); k += 1 {
		if a[k] == 'L' {
			return false
		}
		if a[k] == 'f' {
			return true
		}
	}
	return false
}

@(private = "file")
detect_subcommand :: proc(args: []string) -> (Command, int) {
	seen_from_file := false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if a == "--" {
			return .Run, -1
		}
		if a == "--from-file" || short_has_from_file(a) {
			seen_from_file = true
		}
		if is_option(a) {
			if a[1] != '-' {
				// Account for standalone `-L dir` or `-Ldir`.
				for k := 1; k < len(a); k += 1 {
					if a[k] == 'L' {
						if k + 1 == len(a) {
							i += 1
						}
						break
					}
				}
				continue
			}
			f, _, has_eq := split_long_eq(a)
			if !has_eq {
				i += opt_arity(f)
			}
			continue
		}
		if seen_from_file {
			return .Run, -1
		}
		switch a {
		case "check", "validate":
			return .Check, i
		case "fmt":
			return .Fmt, i
		case "edit":
			return .Edit, i
		case "schema":
			return .Schema, i
		case "diff":
			return .Diff, i
		}
		return .Run, -1
	}
	return .Run, -1
}

parse_args :: proc(args: []string, allocator := context.allocator) -> (o: Options, err: string) {
	o = {
		indent        = 2,
		from_spec     = engine.spec_of_id(.Json),
		to_spec       = engine.spec_of_id(.Json),
		from_framing  = .Single,
		to_framing    = .Single,
		to_name       = "json",
		files        = make([dynamic]string, allocator),
		vars         = make([dynamic]Var_Spec, allocator),
		with_sources = make([dynamic]With_Spec, allocator),
		positional   = make([dynamic]Pos_Spec, allocator),
		lib_dirs     = make([dynamic]string, allocator),
		diff_keys_raw = make([dynamic]string, allocator),
		diff_keys    = make([dynamic]diff.Key_Rule, allocator),
		redact_paths = make([dynamic]string, allocator),
		allocator    = allocator,
	}
	sub_cmd, sub_idx := detect_subcommand(args)
	o.command = sub_cmd
	rest_mode := Rest_Mode.Files
	args_done := false

	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if i == sub_idx {
			continue
		}
		if args_done || !is_option(a) {
			switch {
			case o.command == .Schema && o.schema_verb == .None && !args_done:
				if a == "gen" {
					o.schema_verb = .Odin
				} else if idx, ok := choice_idx(a, {"infer", "sample", "odin", "check", "diff"}); ok {
					o.schema_verb = Schema_Verb(idx + 1)
				} else {
					return o, fmt.aprintf("schema takes infer, sample, odin, check, or diff, not %s", a, allocator = allocator)
				}
			case (o.command == .Run || o.command == .Edit) && o.filter == nil:
				o.filter = a
			case rest_mode == .Args:
				append(&o.positional, Pos_Spec{raw = a})
			case rest_mode == .Json_Args:
				append(&o.positional, Pos_Spec{raw = a, is_json = true})
			case:
				append(&o.files, a)
			}
			continue
		}
		if a == "--" {
			args_done = true
			continue
		}
		if a[1] != '-' {
			if e := parse_short(&o, args, &i); e != "" {
				return o, e
			}
			continue
		}
		flag, val, has_eq := split_long_eq(a, o.command)
		arity := opt_arity(flag, o.command)
		if !has_eq && arity >= 1 {
			if i + arity >= len(args) {
				return o, fmt.aprintf("%s takes %d parameter%s", flag, arity, "" if arity == 1 else "s", allocator = allocator)
			}
			val = args[i + 1]
			i += arity
		}
		if e := apply_long_flag(&o, flag, val, args[i], &rest_mode); e != "" {
			return o, e
		}
	}
	if ke := compile_key_rules(&o); ke != "" {
		return o, ke
	}
	if o.show_help || o.show_version || o.show_build_config {
		return o, ""
	}
	return o, validate_options(&o)
}

@(private = "file")
apply_long_flag :: proc(o: ^Options, flag, val, val2: string, rest_mode: ^Rest_Mode) -> string {
	a := o.allocator
	switch flag[2:] {
	case "help":
		o.show_help = true
	case "version":
		o.show_version = true
	case "build-configuration":
		o.show_build_config = true
	case "jsonpath", "path":
		o.jsonpath = true
	case "compact-output":
		o.compact = true
	case "tab":
		o.compact, o.tab, o.indent, o.indent_set = false, true, -1, true
	case "raw-output":
		o.raw = true
	case "join-output":
		o.raw, o.join = true, true
	case "raw-output0":
		o.raw, o.join, o.raw0 = true, true, true
	case "ascii-output":
		o.ascii = true
	case "sort-keys":
		o.sort_keys = true
	case "color-output":
		o.color_mode = .Always
	case "monochrome-output":
		o.color_mode = .Never
	case "unbuffered":
		o.unbuffered = true
	case "binary":
	case "null-input":
		o.null_input = true
	case "slurp":
		o.slurp = true
	case "raw-input":
		o.raw_input = true
	case "from-file":
		o.from_file = true
	case "seq":
		o.seq = true
	case "stream":
		o.stream = true
	case "stream-errors":
		o.stream, o.stream_errors = true, true
	case "exit-status":
		o.exit_status = true
	case "where":
		o.where_mode = true
	case "explain":
		o.explain = true
	case "plan-out":
		if val == "" {
			return strings.clone("--plan-out takes a file path", a)
		}
		o.plan_out = val
	case "plan-file":
		if val == "" {
			return strings.clone("--plan-file takes a file path", a)
		}
		o.plan_file = val
	case "in-place":
		o.in_place = true
	case "check":
		o.check = true
	case "reflow":
		o.reflow = true
	case "diff":
		o.diff_preview = true
	case "each":
		o.each = true
	case "no-filename":
		o.no_filename = true
	case "skip-bad":
		o.skip_bad = true
	case "quarantine":
		o.quarantine, o.skip_bad = val, true
	case "library-path":
		append(&o.lib_dirs, val)
	case "args":
		rest_mode^ = .Args
	case "jsonargs":
		rest_mode^ = .Json_Args
	case "no-header":
		o.dsv_in.no_header, o.dsv_in_set = true, true
	case "infer":
		o.infer = true
		o.dsv_in.infer = true
	case "ragged":
		o.dsv_tolerate += {.Ragged}
		o.dsv_in_set = true
	case "lazy-quotes":
		o.dsv_tolerate += {.Bare_Quote}
		o.dsv_in_set = true
	case "unread-entities":
		o.xml_tolerate += {.Unread_Entity}
	case "xml-arrays":
		if idx, ok := choice_idx(val, {"auto", "always", "schema"}); ok {
			o.xml_arrays = tape.Xml_Arrays(idx)
			o.xml_arrays_set = true
		} else {
			return fmt.aprintf("invalid --xml-arrays %s (expected auto, always, or schema)", val, allocator = a)
		}
	case "yaml-schema":
		if idx, ok := choice_idx(val, {"core", "json", "failsafe"}); ok {
			o.yaml_schema = tape.Yaml_Dialect(idx)
			o.yaml_schema_set = true
		} else {
			return fmt.aprintf("invalid --yaml-schema %s (expected core, json, or failsafe)", val, allocator = a)
		}
	case "merge-keys":
		o.merge_keys = true
	case "redact":
		if val == "" || val[0] != '/' {
			return strings.clone("--redact takes an RFC 6901 JSON Pointer starting with /", a)
		}
		for idx := 1; idx < len(val); idx += 1 {
			if val[idx] == '~' {
				if idx + 1 >= len(val) || (val[idx + 1] != '0' && val[idx + 1] != '1') {
					return fmt.aprintf("invalid --redact pointer %q: malformed RFC 6901 ~ escape", val, allocator = a)
				}
				idx += 1
			}
		}
		append(&o.redact_paths, val)
	case "out-no-header":
		o.dsv_out.no_header, o.dsv_out_set = true, true
	case "crlf":
		o.dsv_out.crlf, o.dsv_out_set = true, true
	case "grow-header":
		o.grow_header = true
	case "schema":
		o.schema_file, o.schema_flag_set = val, true
	case "schema-ref":
		o.schema_ref, o.schema_flag_set = val, true
	case "format-assert":
		o.format_assert = true
	case "package":
		o.schema_package = val
	case "ranges":
		o.ranges = true
	case "invalid":
		o.invalid = true
	case "comments":
		o.comments = true
	case "patch":
		o.diff_patch = true
	case "json":
		o.diff_json = true
	case "facts":
		o.diff_facts = true
	case "shape":
		o.diff_shape = true
	case "old-schema":
		o.old_schema = val
	case "new-schema":
		o.new_schema = val
	case "key":
		append(&o.diff_keys_raw, val)
	case "with":
		ws, werr := parse_with_spec(val, a)
		if werr != "" {
			return werr
		}
		if has_with_source(o.with_sources[:], ws.name) {
			return fmt.aprintf("duplicate --with source %q", ws.name, allocator = a)
		}
		append(&o.with_sources, ws)
	case "arg", "argjson", "rawfile", "slurpfile":
		k, _ := choice_idx(flag, {"--arg", "--argjson", "--rawfile", "--slurpfile"})
		// jq's first-wins variable binding rule: ignore later bindings of the same name.
		if !has_var_spec(o.vars[:], val) {
			append(&o.vars, Var_Spec{name = val, raw = val2, kind = Var_Kind(k)})
		}
	case "indent":
		n, ok := strconv.parse_int(val, 10)
		if !ok || n < -1 || n > 7 {
			return strings.clone("--indent takes -1..7", a)
		}
		o.compact, o.indent, o.indent_set, o.tab = false, i8(n), true, n < 0
	case "from", "in", "to", "out":
		if flag == "--to" || flag == "--out" {
			if r, is_r := parse_output_render(val); is_r {
				o.has_to = true
				o.to_spec = nil
				o.to_framing = .Single
				o.to_name = "table" if r == .Table else "markdown"
				o.to_render = r
				return ""
			}
		} else {
			if _, is_r := parse_output_render(val); is_r {
				return fmt.aprintf("--from %s is not supported (%s is output-only)", val, val, allocator = a)
			}
		}
		sp, fr, ok := parse_format(val)
		if !ok {
			return fmt.aprintf("unknown format %q", val, allocator = a)
		}
		if flag == "--from" || flag == "--in" {
			o.has_from, o.from_spec, o.from_framing = true, sp, fr
		} else {
			o.has_to, o.to_spec, o.to_framing, o.to_name, o.to_render = true, sp, fr, val, .None
		}
	case "dups":
		if idx, ok := choice_idx(val, {"default", "last", "first", "all", "refuse"}); ok {
			o.dups = tape.Duplicates(idx)
		} else {
			return fmt.aprintf("invalid --dups %s", val, allocator = a)
		}
	case "threads":
		n, ok := strconv.parse_int(val, 10)
		if !ok || n < 1 {
			return strings.clone("--threads takes a positive integer", a)
		}
		o.threads = n
	case "max-depth", "max-memory", "max-steps", "max-nodes", "expansion-limit", "alias-limit":
		n, ok := strconv.parse_u64_of_base(val, 10)
		if !ok || n == 0 || ((flag == "--max-depth" || flag == "--max-nodes") && n > u64(max(u32))) {
			return fmt.aprintf("%s takes a positive integer", flag, allocator = a)
		}
		switch flag {
		case "--max-depth":
			o.budget.depth = u32(n)
		case "--max-memory":
			o.budget.memory = n
		case "--max-steps":
			o.budget.steps = n
		case "--max-nodes":
			o.budget.nodes = u32(n)
		case "--expansion-limit":
			o.budget.expansion = n
		case "--alias-limit":
			o.budget.expansion = n
			o.alias_limit_set = true
		}
	case "delimiter", "comment", "out-delimiter", "out-comment":
		b, ok := parse_char_arg(val)
		if !ok {
			return fmt.aprintf("%s takes a single ASCII byte", flag, allocator = a)
		}
		switch flag {
		case "--delimiter":
			o.dsv_in.delimiter, o.dsv_in_set = b, true
		case "--comment":
			o.dsv_in.comment, o.dsv_in_set = b, true
		case "--out-delimiter":
			o.dsv_out.delimiter, o.dsv_out_set = b, true
		case "--out-comment":
			o.dsv_out.comment, o.dsv_out_set = b, true
		}
	case "schema-draft":
		if idx, ok := choice_idx(val, {"4", "6", "7", "2019-09", "2020-12"}); ok {
			o.schema_draft = schema.Draft(idx)
			o.schema_flag_set = true
		} else {
			return fmt.aprintf("invalid --schema-draft %s", val, allocator = a)
		}
	case "max-errors", "count":
		n, ok := strconv.parse_int(val, 10)
		if !ok || n < 1 {
			return fmt.aprintf("%s takes a positive integer", flag, allocator = a)
		}
		if flag == "--max-errors" {
			o.max_errors = n
		} else {
			o.count = n
		}
	case "seed":
		n, ok := strconv.parse_u64_of_base(val, 10)
		if !ok {
			return strings.clone("--seed takes a non-negative integer", a)
		}
		o.seed = n
	case "report":
		if idx, ok := choice_idx(val, {"lines", "basic", "problem"}); ok {
			o.report = Report_Kind(idx)
		} else {
			return fmt.aprintf("invalid --report %s", val, allocator = a)
		}
	case "set", "position":
		want := diff.Arrays.Set if flag == "--set" else .Position
		if o.diff_arrays != .Sequence && o.diff_arrays != want {
			return strings.clone("--set and --position are mutually exclusive", a)
		}
		o.diff_arrays = want
	case "compat":
		if idx, ok := choice_idx(val, {"backward", "forward", "full"}); ok {
			o.compat = Compat(idx + 1)
		} else {
			return fmt.aprintf("invalid --compat %s", val, allocator = a)
		}
	case:
		return fmt.aprintf("Unknown option %s", flag, allocator = a)
	}
	return ""
}

@(private = "file")
has_var_spec :: proc(vars: []Var_Spec, name: string) -> bool {
	for vs in vars {
		if vs.name == name {
			return true
		}
	}
	return false
}

@(private = "file")
has_with_source :: proc(sources: []With_Spec, name: string) -> bool {
	for ws in sources {
		if ws.name == name {
			return true
		}
	}
	return false
}

@(private = "file")
is_jq_ident :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	c0 := s[0]
	if !((c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z') || c0 == '_') {
		return false
	}
	for i := 1; i < len(s); i += 1 {
		c := s[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_') {
			return false
		}
	}
	return true
}

@(private = "file")
parse_with_spec :: proc(raw: string, a: runtime.Allocator) -> (ws: With_Spec, err: string) {
	eq := strings.index_byte(raw, '=')
	if eq <= 0 || eq + 1 >= len(raw) {
		return {}, fmt.aprintf("invalid --with %q (expected NAME=[FORMAT:]PATH)", raw, allocator = a)
	}
	name := raw[:eq]
	rhs := raw[eq + 1:]
	if !is_jq_ident(name) {
		return {}, fmt.aprintf("invalid --with variable name %q (must be a valid jq identifier)", name, allocator = a)
	}
	if name == "ARGS" || name == "ENV" || name == "JQ_BUILD_CONFIGURATION" || name == "__prog_args" {
		return {}, fmt.aprintf("--with variable name %q conflicts with built-in jq variable", name, allocator = a)
	}

	// Detect optional `format:path` prefix (while keeping Windows drive paths like `C:\...` or `C:/...` intact).
	colon1 := strings.index_byte(rhs, ':')
	is_win_drive := colon1 == 1 && len(rhs) >= 2 && ((rhs[0] >= 'a' && rhs[0] <= 'z') || (rhs[0] >= 'A' && rhs[0] <= 'Z'))
	has_sep_before_colon := false
	if colon1 > 0 {
		for k in 0 ..< colon1 {
			if rhs[k] == '/' || rhs[k] == '\\' {
				has_sep_before_colon = true
				break
			}
		}
	}
	if colon1 == 0 {
		if os.exists(rhs) {
			return {name = name, path = rhs}, ""
		}
		return {}, fmt.aprintf("invalid --with %q: empty format prefix", raw, allocator = a)
	}
	if colon1 > 0 && !is_win_drive && !has_sep_before_colon {
		// Check multi-colon format specifiers first (e.g. `yaml:merge:file.yaml`, `cbor:preferred:file.cbor`).
		after1 := rhs[colon1 + 1:]
		if colon2_rel := strings.index_byte(after1, ':'); colon2_rel > 0 {
			colon2 := colon1 + 1 + colon2_rel
			sep_between := false
			for k in colon1 + 1 ..< colon2 {
				if rhs[k] == '/' || rhs[k] == '\\' {
					sep_between = true
					break
				}
			}
			if !sep_between {
				fmt2 := rhs[:colon2]
				if sp2, fr2, ok2 := parse_format(fmt2); ok2 {
					p2 := rhs[colon2 + 1:]
					if p2 == "" {
						return {}, fmt.aprintf("invalid --with %q: missing file path", raw, allocator = a)
					}
					return {name = name, path = p2, has_fmt = true, spec = sp2, framing = fr2}, ""
				}
			}
		}
		fmt1 := rhs[:colon1]
		p1 := rhs[colon1 + 1:]
		if p1 == "" {
			if os.exists(rhs) {
				return {name = name, path = rhs}, ""
			}
			return {}, fmt.aprintf("invalid --with %q: missing file path", raw, allocator = a)
		}
		sp1, fr1, ok1 := parse_format(fmt1)
		if !ok1 {
			if os.exists(rhs) {
				return {name = name, path = rhs}, ""
			}
			return {}, fmt.aprintf("invalid --with %q: unknown format %q", raw, fmt1, allocator = a)
		}
		return {name = name, path = p1, has_fmt = true, spec = sp1, framing = fr1}, ""
	}
	return {name = name, path = rhs}, ""
}

@(private = "file")
parse_short :: proc(o: ^Options, args: []string, idx: ^int) -> string {
	a := args[idx^]
	for k := 1; k < len(a); k += 1 {
		switch a[k] {
		case 'h':
			o.show_help = true
		case 'V':
			o.show_version = true
		case 'r':
			o.raw = true
		case 'j':
			o.raw, o.join = true, true
		case '0':
			o.raw, o.join, o.raw0 = true, true, true
		case 'c':
			o.compact = true
		case 'S':
			o.sort_keys = true
		case 'a':
			o.ascii = true
		case 'n':
			o.null_input = true
		case 's':
			o.slurp = true
		case 'R':
			o.raw_input = true
		case 'e':
			o.exit_status = true
		case 'f':
			o.from_file = true
		case 'C':
			o.color_mode = .Always
		case 'M':
			o.color_mode = .Never
		case 'b':
		case 'i':
			o.in_place = true
		case 'L':
			if k + 1 < len(a) {
				append(&o.lib_dirs, a[k + 1:])
				return ""
			}
			if idx^ + 1 >= len(args) {
				return strings.clone("-L takes a directory", o.allocator)
			}
			idx^ += 1
			append(&o.lib_dirs, args[idx^])
			return ""
		case:
			return fmt.aprintf("Unknown option -%c", a[k], allocator = o.allocator)
		}
	}
	return ""
}

@(private = "file")
compile_key_rules :: proc(o: ^Options) -> string {
	for spec in o.diff_keys_raw {
		at, member := "", spec
		if eq := strings.index_byte(spec, '='); eq >= 0 {
			at, member = spec[:eq], spec[eq + 1:]
		}
		if member == "" {
			return fmt.aprintf("--key %s names no member", spec, allocator = o.allocator)
		}
		rule := diff.Key_Rule{member = member}
		if at != "" {
			steps, ok := parse_key_path(at, o.allocator)
			if !ok {
				return fmt.aprintf("--key %s: invalid path %s", spec, at, allocator = o.allocator)
			}
			rule.at = steps
		}
		append(&o.diff_keys, rule)
	}
	return ""
}

@(private = "file")
parse_key_path :: proc(at: string, alloc: runtime.Allocator) -> ([]tape.Step, bool) {
	steps := make([dynamic]tape.Step, alloc)
	s := at[1:] if len(at) > 0 && at[0] == '$' else at
	for len(s) > 0 {
		if s[0] == '[' {
			c := strings.index_byte(s, ']')
			if c < 0 {
				delete(steps)
				return nil, false
			}
			in_s := s[1:c]
			if in_s == "" {
				append(&steps, tape.Step(tape.All{}))
			} else if n, ok := strconv.parse_int(in_s, 10); ok {
				append(&steps, tape.Step(tape.Index(n)))
			} else {
				append(&steps, tape.Step(tape.Name(strings.trim(in_s, `"'`))))
			}
			s = s[c + 1:]
		} else {
			if s[0] == '.' {
				s = s[1:]
			}
			if len(s) == 0 {
				delete(steps)
				return nil, false
			}
			e := 0
			for e < len(s) && s[e] != '.' && s[e] != '[' {
				e += 1
			}
			append(&steps, tape.Step(tape.Name(s[:e])))
			s = s[e:]
		}
	}
	return steps[:], true
}

@(private = "file")
validate_options :: proc(o: ^Options) -> string {
	a := o.allocator
	if o.jsonpath && o.command != .Run {
		return strings.clone("--jsonpath can only be used with query execution", a)
	}
	if len(o.with_sources) > 0 {
		if o.command != .Run {
			return strings.clone("--with can only be used with query execution", a)
		}
		if o.jsonpath {
			return strings.clone("--with cannot be combined with --jsonpath", a)
		}
		if o.stream || o.stream_errors {
			return strings.clone("--with cannot be combined with --stream", a)
		}
		for ws in o.with_sources {
			if has_var_spec(o.vars[:], ws.name) {
				return fmt.aprintf("--with variable %q conflicts with --arg/--argjson/--rawfile/--slurpfile", ws.name, allocator = a)
			}
		}
	}
	if (o.plan_out != "" || o.plan_file != "") && o.command != .Run {
		return strings.clone("--plan-out/--plan-file can only be used with query execution", a)
	}
	if (o.command == .Edit || o.command == .Fmt) && o.in_place && o.check {
		return strings.clone("--in-place rewrites each file; --check only reads it", a)
	}
	if o.in_place && len(o.files) == 0 {
		return strings.clone("--in-place requires at least one file", a)
	}
	for p in o.files {
		if o.in_place && p == "-" {
			return strings.clone("--in-place cannot rewrite stdin (-)", a)
		}
	}
	if o.command == .Edit && o.filter == nil && !o.from_file {
		return strings.clone("edit needs a filter", a)
	}
	if o.no_filename && !o.each {
		return strings.clone("--no-filename has no use without --each", a)
	}
	if o.each && !o.no_filename && o.has_to {
		if te, ok := engine.entry_of_spec(o.to_spec); ok && te.binary {
			return strings.clone("--each labels the lines of its output, and binary output writes none: add --no-filename", a)
		}
	}
	if o.seq && o.has_from {
		if fe, ok := engine.entry_of_spec(o.from_spec); ok && fe.family != .Json {
			return fmt.aprintf("--seq applies to JSON text sequences, not --from %s", fe.name, allocator = a)
		}
	}
	if o.xml_arrays_set {
		#partial switch o.command {
		case .Diff, .Edit, .Schema:
			return strings.clone("--xml-arrays cannot be used with diff, edit, or schema", a)
		}
		if o.xml_arrays == .Schema && o.schema_file == "" {
			return strings.clone("--xml-arrays=schema requires --schema <file>", a)
		}
		if o.has_from {
			if fe, ok := engine.entry_of_spec(o.from_spec); ok && fe.family != .Xml {
				return fmt.aprintf("--xml-arrays applies to XML input, not --from %s", fe.name, allocator = a)
			}
		} else if len(o.files) == 0 {
			if !o.null_input {
				return strings.clone("--xml-arrays applies to XML input; pass --from xml for stdin", a)
			}
		} else {
			for p in o.files {
				sp, _ := detect_file_spec(o, p)
				if fe, ok := engine.entry_of_spec(sp); ok && fe.family != .Xml {
					return fmt.aprintf("--xml-arrays applies to XML input, not %s (%s)", p, fe.name, allocator = a)
				}
			}
		}
	}
	if o.yaml_schema_set || o.merge_keys || o.alias_limit_set {
		yflag := "--yaml-schema" if o.yaml_schema_set else "--merge-keys" if o.merge_keys else "--alias-limit"
		if o.null_input {
			return fmt.aprintf("%s cannot be used with --null-input", yflag, allocator = a)
		}
		if o.has_from {
			if fe, ok := engine.entry_of_spec(o.from_spec); ok && fe.family != .Yaml {
				return fmt.aprintf("%s applies to YAML input, not --from %s", yflag, fe.name, allocator = a)
			}
			if o.merge_keys && o.from_spec == engine.spec_of_id(.Yaml) {
				o.from_spec = engine.spec_of_id(.Yaml_Merge)
			}
		} else if len(o.files) == 0 {
			return fmt.aprintf("%s applies to YAML input; pass --from yaml for stdin", yflag, allocator = a)
		} else {
			for p in o.files {
				sp, _ := detect_file_spec(o, p)
				if fe, ok := engine.entry_of_spec(sp); ok && fe.family != .Yaml {
					return fmt.aprintf("%s applies to YAML input, not %s (%s)", yflag, p, fe.name, allocator = a)
				}
			}
		}
	}
	if o.comments {
		if o.command != .Schema || o.schema_verb != .Sample {
			return strings.clone("--comments only applies to schema sample", a)
		}
		if o.to_render != .None {
			return fmt.aprintf("--comments writes a description as a comment, and %s holds no comment", o.to_name, allocator = a)
		}
		if te, tok := engine.entry_of_spec(o.to_spec); tok {
			holds_comment := (.Comment in te.format.facts) if !te.tabular else (o.dsv_out.comment != 0)
			if !holds_comment {
				return fmt.aprintf("--comments writes a description as a comment, and %s holds no comment", o.to_name, allocator = a)
			}
		}
	}
	if o.quarantine != "" && o.stream_errors {
		return strings.clone("--stream-errors tells a bad record as an event, so --quarantine cannot go with it", a)
	}
	if o.skip_bad && o.stream_errors {
		return strings.clone("--stream-errors tells a bad record as an event, so --skip-bad cannot go with it", a)
	}
	if o.command == .Edit {
		if o.has_to {
			return strings.clone("edit rewrites each file in its own format, so --to cannot be used", a)
		}
		if o.raw || o.join || o.raw0 || o.color_mode == .Always || o.null_input || o.stream || o.stream_errors {
			return strings.clone("invalid option combination with edit", a)
		}
	}
	if o.has_to {
		if o.to_render != .None {
			if o.raw0 {
				return fmt.aprintf("--raw-output0 cannot be combined with --to %s", o.to_name, allocator = a)
			}
		} else if te, tok := engine.entry_of_spec(o.to_spec); tok {
			if o.raw0 && te.family != .Json {
				return fmt.aprintf("--raw-output0 cannot be combined with --to %s", o.to_name, allocator = a)
			}
			if te.tabular {
				bad := "-r" if (o.raw && !o.join && !o.raw0) else "-j" if (o.join && !o.raw0) else "--raw-output0" if o.raw0 else "-a" if o.ascii else "-C" if o.color_mode == .Always else "--tab" if o.tab else "--indent" if o.indent_set else "-c" if o.compact else "--seq" if o.seq else ""
				if bad != "" {
					return fmt.aprintf("%s cannot be combined with --to %s", bad, o.to_name, allocator = a)
				}
			} else if te.binary {
				if o.raw || o.join || o.raw0 || o.ascii || o.color_mode == .Always || o.tab || o.indent_set || o.compact || o.seq {
					return fmt.aprintf("text formatting options cannot be combined with --to %s", o.to_name, allocator = a)
				}
			} else if te.id == .Json && o.to_framing == .Lines && (o.tab || (o.indent_set && o.indent > 0)) {
				return fmt.aprintf("--tab/--indent cannot be combined with --to %s", o.to_name, allocator = a)
			}
		}
	}
	return ""
}

write_version :: proc(w: io.Writer) -> bool {
	buf: [128]u8
	msg := fmt.bprintf(buf[:], "stury-%s\n", VERSION)
	_, err := io.write_string(w, msg)
	return err == .None
}

write_help :: proc(w: io.Writer, cmd: Command, short := false) -> bool {
	err: io.Error
	buf: [1024]u8
	if short {
		msg := fmt.bprintf(buf[:], "stury - v2 processor [%s]\nUsage: stury [options] <jq filter> [file...]\nUse stury --help.\n", VERSION)
		_, err = io.write_string(w, msg)
		return err == .None
	}
	switch cmd {
	case .Check:
		_, err = io.write_string(w, "Usage: stury check [--from fmt|--seq] [--xml-arrays auto|always|schema] [--schema file] [--schema-ref dir] [--schema-draft d] [--format-assert] [--max-errors n] [--report lines|basic|problem] [--dups policy] [--skip-bad] [--quarantine file] [file...]\n")
	case .Fmt:
		_, err = io.write_string(w, "Usage: stury fmt [--from fmt] [--to fmt] [--xml-arrays auto|always|schema] [--indent n|--tab|-c|-S|-a] [-i|--in-place|--check] [--schema file] [file...]\n")
	case .Edit:
		_, err = io.write_string(w, "Usage: stury edit [--from fmt|--seq|-R] [--reflow] [-i|--in-place|--check|--diff] <jq filter> [file...]\n")
	case .Diff:
		_, err = io.write_string(w, "Usage: stury diff [--patch] [--json] [--facts] [--set|--position|--key K] [--from fmt] <old> <new>\n       stury diff --schema [--compat backward|forward|full] <old> <new> | --old-schema s --new-schema s\n")
	case .Schema:
		_, err = io.write_string(w, "Usage: stury schema <infer|sample|odin|check|diff> [options] ...\n")
	case .Run:
		msg := fmt.bprintf(buf[:], HELP_MAIN, VERSION)
		_, err = io.write_string(w, msg)
	}
	return err == .None
}

@(private = "file")
HELP_MAIN :: `stury - JSON, JSONC, JSON5, TOML, XML, CSV/TSV, CBOR, YAML, HTML and MessagePack processor [version %s]
Usage:  stury [options] <jq filter> [file...] | stury --jsonpath [options] <jsonpath> [file...]
        stury check|fmt|edit|diff|schema [options] ...
Options: -n -R -s -c -r -j --raw-output0 -a -S -C -M --tab --indent N -e -f -L dir
         --arg k v --argjson k v --rawfile k f --slurpfile k f --with k=[fmt:]f
         --args --jsonargs --jsonpath/--path --seq --stream --stream-errors
         --from fmt --to fmt --xml-arrays auto|always|schema
         --yaml-schema core|json|failsafe --merge-keys --alias-limit N
         --schema file --redact /ptr --explain --plan-out f --plan-file f
         --where --threads N --dups policy --skip-bad --quarantine f -V -h --
`
