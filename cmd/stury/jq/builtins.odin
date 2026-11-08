package jq

// jq's builtin functions. Those that need their arguments as filters, or that generate, are natives (`natives.odin`).
// The rest take their arguments' values (every combination of them, the first argument varying slowest) and give one
// value. What jq itself defines in jq is defined so here too, in `PRELUDE`.
//
// Where builtin X lives, by the `Builtin` field the table below fills:
//	native     (`Native`)     takes its arguments as filters: natives.odin (select, path, limit, the type
//	                          selectors), regex_natives.odin (sub/gsub)
//	gen        (`Generator`)  takes values, may give several: natives.odin (getpath, range, halt_error),
//	                          regex_natives.odin (match, capture)
//	fn         (`Function`)   takes values, gives one: natives.odin (setpath), regex_natives.odin (test,
//	                          split/2), math_time.odin (time and number functions), functions.odin and
//	                          sort.odin (the rest)
//	math1/math2               libm functions of one or two numbers
//	PRELUDE                   everything jq writes in jq itself

import "base:runtime"
import "core:c/libc"
import "core:math"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import "../message"

Native :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal
Generator :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink) -> Signal
Function :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal)

Builtin :: struct {
	native: Native,
	gen:    Generator,
	fn:     Function,
	math1:  proc "c" (x: f64) -> f64, // of the input
	math2:  proc "c" (x, y: f64) -> f64, // of the two arguments
	// One jq 1.8.2 writes in jq, where its arguments are subfunctions, which `check` reads them as.
	in_jq:  bool,
}

MAX_ARITY :: 4

@(private = "file")
table_once: sync.Once

@(private = "file")
table: map[string][MAX_ARITY]Builtin

builtin :: proc(name: string, arity: int) -> (Builtin, bool) {
	sync.once_do(&table_once, fill_table)
	if arity >= MAX_ARITY {
		return {}, false
	}
	row, has := table[name]
	if !has {
		return {}, false
	}
	b := row[arity]
	return b, b != {}
}

// `b` under each of `names`, separated by spaces, at each of `arities`.
@(private = "file")
put :: proc(names: string, arities: bit_set[0 ..< MAX_ARITY], b: Builtin) {
	names := names
	for name in strings.fields_iterator(&names) {
		_, row, _, _ := map_entry(&table, name)
		for a in arities {
			row[a] = b
		}
	}
}

@(private = "file")
fill_table :: proc() {
	// Room for 256 names at once, so the table never grows.
	table = make(map[string][MAX_ARITY]Builtin, 256, runtime.heap_allocator())
	put("empty", {0}, {native = native_empty})
	put("select", {1}, {native = native_select})
	put("values", {0}, {native = kept_by_kind(~{.Null})})
	put("nulls", {0}, {native = kept_by_kind({.Null})})
	put("booleans", {0}, {native = kept_by_kind({.False, .True})})
	put("numbers", {0}, {native = kept_by_kind({.Number})})
	put("strings", {0}, {native = kept_by_kind({.String})})
	put("arrays", {0}, {native = kept_by_kind({.Array})})
	put("objects", {0}, {native = kept_by_kind({.Object})})
	put("iterables", {0}, {native = kept_by_kind({.Array, .Object})})
	put("scalars", {0}, {native = kept_by_kind(~{.Array, .Object})})
	put("error", {0}, {native = native_error})
	put("error", {1}, {gen = proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink) -> Signal {
			ip.err = args[0]
			ip.raised += 1
			return .Fail
		}, in_jq = true})
	put("path", {1}, {native = native_path})
	put("getpath", {1}, {gen = gen_getpath})
	put("setpath", {2}, {fn = fn_setpath})
	put("delpaths", {1}, {fn = fn_delpaths})
	put("limit skip", {2}, {native = native_count})
	put("first", {1}, {native = native_first})
	put("last", {1}, {native = native_last})
	put("isempty", {1}, {native = native_isempty})
	put("range", {1, 2, 3}, {gen = gen_range, in_jq = true})
	put("recurse", {0}, {native = native_recurse})
	put("recurse", {1}, {native = native_recurse_f})
	put("input", {0}, {native = native_input})
	put("inputs", {0}, {native = native_inputs})
	put("debug", {0}, {native = native_debug})
	put("stderr", {0}, {native = native_stderr})
	put("halt", {0}, {native = native_halt})
	put("halt_error", {1}, {gen = gen_halt_error})
	put("sub gsub", {2, 3}, {native = native_sub})
	put("match", {1, 2}, {gen = each_match(false), in_jq = true})
	put("capture", {1, 2}, {gen = each_match(true), in_jq = true})
	put("test", {1, 2}, {fn = fn_test, in_jq = true})
	put("split", {2}, {fn = fn_split_regex, in_jq = true})

	put("input_filename input_line_number", {0}, {fn = fn_input_position})
	put("env", {0}, {fn = proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {return env_value(ip)}})
	put("builtins", {0}, {fn = fn_builtins})
	put("now", {0}, {fn = proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
			return num(f64(time.time_to_unix_nano(time.now())) / 1e9), .Go
		}})
	put("have_literal_numbers have_decnum", {0}, {fn = proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {return true, .Go}})
	put("get_search_list get_jq_origin get_prog_origin", {0}, {fn = fn_origin})
	put("modulemeta", {0}, {fn = fn_modulemeta})
	put("infinite", {0}, {fn = proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {return num(math.inf_f64(1)), .Go}})
	put("nan", {0}, {fn = proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {return num(math.nan_f64()), .Go}})
	put("not", {0}, {fn = proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {return !truthy(v), .Go}})
	put("type", {0}, {fn = proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {return type_name(v), .Go}})
	put("length", {0}, {fn = fn_length})
	put("utf8bytelength", {0}, {fn = fn_utf8bytelength})
	put("keys", {0}, {fn = fn_keys})
	put("keys_unsorted", {0}, {fn = fn_keys_unsorted})
	put("has", {1}, {fn = fn_has})
	put("contains", {1}, {fn = fn_contains})
	put("tostring", {0}, {fn = proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
			if kind(v) == .String {
				return v, .Go
			}
			return to_json(v), .Go
		}})
	put("tojson", {0}, {fn = proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {return to_json(v), .Go}})
	put("tonumber", {0}, {fn = fn_tonumber})
	put("fromjson", {0}, {fn = fn_fromjson})
	put("ascii_downcase ascii_upcase", {0}, {fn = fn_ascii_case})
	put("explode", {0}, {fn = fn_explode})
	put("implode", {0}, {fn = fn_implode})
	put("ltrimstr rtrimstr", {1}, {fn = fn_affix, in_jq = true})
	put("startswith endswith", {1}, {fn = fn_affix})
	put("trim ltrim rtrim", {0}, {fn = fn_trim})
	put("split", {1}, {fn = fn_split})
	put("join", {1}, {fn = fn_join, in_jq = true})
	put("sort unique", {0}, {fn = fn_sort})
	put("sort_by", {1}, {native = sort_by(.Sorted)})
	put("group_by", {1}, {native = sort_by(.Grouped)})
	put("unique_by", {1}, {native = sort_by(.Unique)})
	put("min_by", {1}, {native = extreme_by(false)})
	put("max_by", {1}, {native = extreme_by(true)})
	put("min max", {0}, {fn = fn_extreme})
	put("reverse", {0}, {fn = fn_reverse})
	put("flatten", {0, 1}, {fn = fn_flatten, in_jq = true})
	put("_strindices", {1}, {fn = fn_strindices})
	put("add", {0}, {fn = fn_add})
	put("to_entries", {0}, {fn = fn_to_entries})
	put("format", {1}, {fn = proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
			f, ok := string_of(args[0])
			if !ok {
				return nil, fail(ip, "%s (%s) is not a valid format", type_name(args[0]), brief(ip, args[0]))
			}
			return format(ip, f, v)
		}})
	put("bsearch", {1}, {fn = fn_bsearch})
	put("isinfinite isnan isnormal", {0}, {fn = fn_float_class})
	put("gmtime localtime", {0}, {fn = fn_gmtime})
	put("mktime", {0}, {fn = fn_mktime})
	put("strftime strflocaltime", {1}, {fn = fn_strftime})
	put("strptime", {1}, {fn = fn_strptime})
	put("frexp modf lgamma_r", {0}, {fn = fn_number_pair})

	// libm, as jq calls it, so results agree to the last digit.
	math1 := [?]struct {
		name: string,
		f:    proc "c" (x: f64) -> f64,
	} {
		{"floor", libc.floor}, {"ceil", libc.ceil}, {"round", libc.round}, {"trunc", libc.trunc}, {"rint", libc.rint},
		{"nearbyint", libc.nearbyint}, {"fabs", libc.fabs}, {"sqrt", libc.sqrt}, {"cbrt", libc.cbrt},
		{"exp", libc.exp}, {"exp2", libc.exp2}, {"expm1", libc.expm1}, {"log", libc.log}, {"log2", libc.log2},
		{"log10", libc.log10}, {"log1p", libc.log1p}, {"logb", libc.logb}, {"tgamma", libc.tgamma},
		{"sin", libc.sin}, {"cos", libc.cos}, {"tan", libc.tan}, {"asin", libc.asin}, {"acos", libc.acos}, {"atan", libc.atan},
		{"sinh", libc.sinh}, {"cosh", libc.cosh}, {"tanh", libc.tanh}, {"asinh", libc.asinh}, {"acosh", libc.acosh},
		{"atanh", libc.atanh}, {"erf", libc.erf}, {"erfc", libc.erfc},
		{"j0", bessel_j0}, {"j1", bessel_j1}, {"y0", bessel_y0}, {"y1", bessel_y1},
		// libm's `gamma` is log-gamma (glibc, jq on Linux).
		{"gamma", libc.lgamma}, {"lgamma", libc.lgamma},
		{"exp10", proc "c" (x: f64) -> f64 {return libc.pow(10, x)}},
		{"significand", proc "c" (x: f64) -> f64 {return libc.scalbn(x, -libc.ilogb(x)) if x != 0 && !math.is_inf(x) else x}},
	}
	for m in math1 {
		put(m.name, {0}, {math1 = m.f})
	}
	math2 := [?]struct {
		name: string,
		f:    proc "c" (x, y: f64) -> f64,
	} {
		{"pow", libc.pow}, {"atan2", libc.atan2}, {"fmod", libc.fmod}, {"fmin", libc.fmin}, {"fmax", libc.fmax},
		{"hypot", libc.hypot}, {"copysign", libc.copysign}, {"nextafter", libc.nextafter}, {"nexttoward", libc.nextafter},
		{"remainder", libc.remainder}, {"drem", libc.remainder}, {"fdim", libc.fdim},
		{"ldexp", proc "c" (x, y: f64) -> f64 {return libc.ldexp(x, i32(y))}},
		// As jq's libm scalb: the exponent is cut toward zero, so 2.5 scales by 4.
		{"scalb", proc "c" (x, y: f64) -> f64 {return y if math.is_nan(y) else libc.scalbln(x, scale_exponent(y))}},
		{"scalbln", proc "c" (x, y: f64) -> f64 {return libc.scalbln(x, scale_exponent(y))}},
		// The order is C's, converted as C converts a double to int.
		{"jn", proc "c" (x, y: f64) -> f64 {return bessel_jn(i32(x), y)}},
		{"yn", proc "c" (x, y: f64) -> f64 {return bessel_yn(i32(x), y)}},
	}
	for m in math2 {
		put(m.name, {2}, {math2 = m.f})
	}
	put("fma", {3}, {fn = proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
			xs: [3]f64
			for a, i in args {
				n, ok := number_of(a)
				if !ok {
					return nil, fail(ip, "%s (%s) number required", type_name(a), brief(ip, a))
				}
				xs[i] = n.f
			}
			return num(libc.fma(xs[0], xs[1], xs[2])), .Go
		}})
}

when ODIN_OS == .Darwin {
	foreign import libm "system:System"
} else when ODIN_OS == .Windows {
	foreign import libm "system:libucrt.lib"
} else {
	foreign import libm "system:m"
}

// The UCRT names them with a leading underscore.
@(private = "file")
BESSEL :: "_" when ODIN_OS == .Windows else ""

// libm's Bessel functions (POSIX, not C), which core:c/libc does not bind.
@(private = "file", default_calling_convention = "c")
foreign libm {
	@(link_name = BESSEL + "j0")
	bessel_j0 :: proc(x: f64) -> f64 ---
	@(link_name = BESSEL + "j1")
	bessel_j1 :: proc(x: f64) -> f64 ---
	@(link_name = BESSEL + "jn")
	bessel_jn :: proc(n: i32, x: f64) -> f64 ---
	@(link_name = BESSEL + "y0")
	bessel_y0 :: proc(x: f64) -> f64 ---
	@(link_name = BESSEL + "y1")
	bessel_y1 :: proc(x: f64) -> f64 ---
	@(link_name = BESSEL + "yn")
	bessel_yn :: proc(n: i32, x: f64) -> f64 ---
}

// scalb's exponent as a long, held inside ±2^20 first: past it every finite result is already 0 or an
// infinity, and an out-of-range double converts to LONG_MIN on x86-64 where arm64 saturates.
@(private = "file")
scale_exponent :: proc "contextless" (y: f64) -> libc.long {
	return libc.long(clamp(y, -1 << 20, 1 << 20))
}

// jq's attributes for its module paths (modules.odin): the library directories, the directory of argv[0],
// and where the program came from.
@(private = "file")
fn_origin :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	switch name {
	case "get_search_list":
		return lib_dirs(ip), .Go
	case "get_jq_origin":
		return jq_origin(), .Go
	}
	return program_origin(ip), .Go
}

// jq's own definitions of the builtins it writes in jq. A definition sees only those before it, and each
// starts a line of its own, where `prelude_defs` cuts them apart.
PRELUDE :: `
def map(f): [.[] | f];
def map_values(f): .[] |= f;
def recurse(f; cond): def r: ., (f | select(cond) | r); r;
def finites: select(type == "number" and (isinfinite | not));
def normals: select(isnormal);
def add(f): reduce f as $x (null; . + $x);
def del(f): delpaths([path(f)]);
def paths: path(..) | select(length > 0);
def paths(node_filter): path(..|select(node_filter)) | select(length > 0);
def pick(pathexps): . as $top | reduce path(pathexps) as $p (null; setpath($p; $top | getpath($p)));
def from_entries: map({ (.key // .Key // .name // .Name):
  if has("value") then .value else .Value end }) | add // {};
def with_entries(f): to_entries | map(f) | from_entries;
def walk(f): def w: if type == "object" then map_values(w) elif type == "array" then map(w) else . end | f; w;
def any(generator; condition): isempty(generator | condition or empty) | not;
def all(generator; condition): isempty(generator | condition and empty);
def any(condition): any(.[]; condition);
def all(condition): all(.[]; condition);
def any: any(.);
def all: all(.);
def in(xs): . as $x | xs | has($x);
def inside(xs): . as $x | xs | contains($x);
def first: .[0];
def last: .[-1];
def nth($n): .[$n];
def nth($n; f): if $n < 0 then error("nth doesn't support negative indices") else first(skip($n; f)) end;
def until(cond; update): def _until: if cond then . else (update | _until) end; _until;
def while(cond; update): def _while: if cond then ., (update | _while) else empty end; _while;
def repeat(f): def _repeat: f, _repeat; _repeat;
def IN(s): any(s == .; .);
def IN(src; s): any(src == s; .);
def combinations: if length == 0 then [] else .[0][] as $x | (.[1:] | combinations) as $w | [$x] + $w end;
def combinations(n): . as $dot | [range(n) | $dot] | combinations;
def transpose: [range(0; map(length) | max // 0) as $i | [.[][$i]]];
def indices($i): if type == "array" and ($i | type) == "array" then .[$i] elif type == "array" then .[[$i]]
    elif type == "string" and ($i | type) == "string" then _strindices($i) else .[$i] end;
def index($i): indices($i) | .[0];
def rindex($i): indices($i) | .[-1:][0];
def debug(msg): (msg | debug | empty), .;
def scan($re; $flags): match($re; "g" + $flags) | if (.captures | length > 0) then [.captures | .[] | .string] else .string end;
def scan($re): scan($re; null);
def splits($re; flags): .[foreach (match($re; flags + "g"), null) as {$offset, $length}
    (null; {start: .next, end: $offset, next: ($offset + $length)})];
def splits($re): splits($re; null);
def halt_error: halt_error(5);
def todateiso8601: strftime("%Y-%m-%dT%H:%M:%SZ");
def todate: todateiso8601;
def fromdateiso8601: strptime("%Y-%m-%dT%H:%M:%SZ") | mktime;
def fromdate: fromdateiso8601;
def abs: if . < 0 then - . else . end;
def isfinite: type == "number" and (isinfinite | not);
def trimstr($x): ltrimstr($x) | rtrimstr($x);
def toboolean: if type == "boolean" then . elif . == "true" then true elif . == "false" then false
    else error("\(type) (\(tojson)) cannot be parsed as a boolean") end;
def INDEX(stream; idx_expr): reduce stream as $row ({}; .[$row | idx_expr | tostring] = $row);
def INDEX(idx_expr): INDEX(.[]; idx_expr);
def JOIN($idx; idx_expr): [.[] | [., $idx[idx_expr]]];
def JOIN($idx; stream; idx_expr): stream | [., $idx[idx_expr]];
def JOIN($idx; stream; idx_expr; join_expr): stream | [., $idx[idx_expr]] | join_expr;
def tostream: path(def r: (.[]? | r), .; r) as $p | getpath($p) | reduce path(.[]?) as $q ([$p, .]; [$p + $q]);
def fromstream(f): { x: null, e: false } as $init
  | foreach f as $i ($init;
      if .e then $init else . end
      | if $i | length == 2
        then setpath(["e"]; $i[0] | length == 0) | setpath(["x"] + $i[0]; $i[1])
        else setpath(["e"]; $i[0] | length == 1) end;
      if .e then .x else empty end);
def truncate_stream(stream): . as $n | null | stream | . as $input
  | if (.[0] | length) > $n then setpath([0]; .[0][$n:]) else empty end;
`

// Make the prelude's definitions that `calls` reach, by name, through the definitions they call in turn:
// newest first in `scope`, and as `check` resolves names in them in `names`.
load_prelude :: proc(calls: []string) -> (scope: ^Env, names: ^Scope) {
	defs := prelude_defs()
	wanted := make(map[string]bool, context.temp_allocator)
	for c in calls {
		wanted[c] = true
	}
	// A definition calls only those before it, so one pass from the newest finds them all. Every word of a
	// wanted definition is taken as a call, which may only make a few more. `b` stays in `context.allocator`,
	// as `parse` borrows slices of its text into the prelude's AST.
	b := strings.builder_make()
	keep := make([]bool, len(defs), context.temp_allocator)
	for i := len(defs) - 1; i >= 0; i -= 1 {
		d := defs[i]
		name, _ := def_signature(d)
		if !wanted[name] {
			continue
		}
		keep[i] = true
		for w := 0; w < len(d); {
			if !ident_byte(d[w]) {
				w += 1
				continue
			}
			start := w
			for w < len(d) && ident_byte(d[w]) {
				w += 1
			}
			wanted[d[start:w]] = true
		}
	}
	for d, i in defs {
		if keep[i] {
			strings.write_string(&b, d)
		}
	}
	strings.write_byte(&b, '.')
	prog, errors := parse(strings.to_string(b))
	if len(errors) > 0 {
		panic(errors[0].msg)
	}
	for n := prog.body; n.kind == .Def; n = n.a {
		e := new(Env)
		e^ = {parent = scope, kind = .Func, name = n.fn.name, arity = len(n.fn.params), fn = n.fn, in_prelude = true}
		scope = e
		names = bind_prelude_def(e, names)
	}
	return scope, names
}

// Each definition of the prelude, oldest first, as its own text from its `def` to the next one's.
@(private = "file")
prelude_defs :: proc() -> []string {
	defs := make([dynamic]string, context.temp_allocator)
	rest := PRELUDE[1:]
	for len(rest) > 0 {
		end := strings.index(rest[1:], "\ndef ")
		end = len(rest) if end < 0 else end + 2
		append(&defs, rest[:end])
		rest = rest[end:]
	}
	return defs[:]
}

// The name and arity a prelude definition `def` defines.
@(private = "file")
def_signature :: proc(def: string) -> (name: string, arity: int) {
	s := def[len("def "):]
	end := strings.index_any(s, "(:")
	if s[end] == '(' {
		arity = strings.count(s[:strings.index_byte(s, ')')], ";") + 1
	}
	return s[:end], arity
}

@(private = "file")
fn_builtins :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	names: [dynamic]string
	for fname, row in table {
		if fname[0] == '_' {
			continue
		}
		for b, arity in row {
			if b != {} {
				append(&names, message.build("%s/%d", fname, arity))
			}
		}
	}
	for d in prelude_defs() {
		def_name, arity := def_signature(d)
		append(&names, message.build("%s/%d", def_name, arity))
	}
	slice.sort(names[:]) // the table is a map: sorted, every run lists the same order
	a := new_array(len(names))
	for n in names {
		append(&a.items, n)
	}
	return a, .Go
}

// ---- Calling

call_builtin :: proc(ip: ^Interp, b: Builtin, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if b.native != nil {
		return b.native(ip, n, input, env, track, out)
	}
	b := b
	return eval_args(ip, n, &b, input, env, track, out)
}

// The builtin `x.b` on one combination of its arguments' values.
apply_builtin :: #force_no_inline proc(x: ^Args_Sink) -> Signal {
	b := x.b^
	switch {
	case b.gen != nil:
		return b.gen(x.ip, x.input, x.vals, x.track, x.out)
	case b.math1 != nil:
		n, ok := number_of(x.input.v)
		if !ok {
			return fail(x.ip, "%s (%s) number required", type_name(x.input.v), brief(x.ip, x.input.v))
		}
		return emit_made(x.out, x.input, num(b.math1(n.f)), x.track)
	case b.math2 != nil:
		a, aok := number_of(x.vals[0])
		c, cok := number_of(x.vals[1])
		if !aok || !cok {
			bad := x.vals[0] if !aok else x.vals[1]
			return fail(x.ip, "%s (%s) number required", type_name(bad), brief(x.ip, bad))
		}
		return emit_made(x.out, x.input, num(b.math2(a.f, c.f)), x.track)
	}
	if x.track {
		if sig, done := defined_path(x); done {
			return sig
		}
	}
	// A function computes a new value from its input's and arguments' data: it carries no comments.
	for &a in x.vals {
		if c, is_commented := a.(^Commented); is_commented {
			a = c.v
		}
	}
	v, sig := b.fn(x.ip, x.n.name, plain(x.input.v), x.vals)
	if sig != .Go {
		return sig
	}
	return emit_made(x.out, x.input, v, x.track)
}

// Natives jq defines in jq, as a path expression steps through them: a trimmed ltrimstr or rtrimstr is a slice,
// ascii_downcase maps an array explode made, and `add`, `join` and `flatten` iterate their input and `reverse`
// indexes it, which fails on a value no path leads to.
@(private = "file")
defined_path :: proc(x: ^Args_Sink) -> (sig: Signal, done: bool) {
	t := x.input
	switch {
	case x.b.fn == fn_ascii_case:
		codes, esig := fn_explode(x.ip, "explode", t.v, nil)
		if esig != .Go {
			return esig, true
		}
		return fail(x.ip, "Invalid path expression near attempt to iterate through %s", brief(x.ip, codes)), true
	case x.n.name == "ltrimstr" || x.n.name == "rtrimstr":
		s, sok := string_of(t.v)
		cut, cok := string_of(x.vals[0])
		left := x.n.name == "ltrimstr"
		if !sok || !cok || !(strings.has_prefix(s, cut) if left else strings.has_suffix(s, cut)) {
			return .Go, false
		}
		key := new_object()
		kept := num(f64(utf8.rune_count(s) - utf8.rune_count(cut)))
		object_put(key, "start", num(f64(utf8.rune_count(cut))) if left else nil)
		object_put(key, "end", nil if left else kept)
		return index_and_emit(x.ip, t, key, true, x.out), true
	case !pathless(t.path):
	case x.b.fn == fn_add, x.b.fn == fn_join, x.b.fn == fn_flatten && (len(x.vals) == 0 || compare(x.vals[0], num(0)) >= 0):
		return fail(x.ip, "Invalid path expression near attempt to iterate through %s", brief(x.ip, t.v)), true
	case x.b.fn == fn_reverse:
		n, lsig := fn_length(x.ip, "reverse", t.v, nil)
		if lsig != .Go {
			return lsig, true
		}
		if l, _ := number_of(n); l.f > 0 {
			return index_and_emit(x.ip, t, num(l.f - 1), true, x.out), true
		}
	}
	return .Go, false
}

elements :: proc(value: Value) -> []Value {
	v := plain(value)
	if a, is_arr := v.(^Array); is_arr {
		return a.items[:]
	}
	if p, is_path := v.(Path); is_path {
		return path_array((^Path_Step)(p)).items[:]
	}
	out := make([dynamic]Value, 0, length_of(v))
	it := iterate(v)
	for _, m in next_member(&it) {
		append(&out, m)
	}
	return out[:]
}
