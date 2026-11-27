package jq

import "stury:lib/query"

// jq's builtins: the names a program calls, each bound to an engine operation. A value builtin takes its arguments'
// values, every combination of them with the first varying slowest, and gives one value. The others take their
// arguments as filters and run in the evaluator (`Builtin_Op`). What jq writes in jq itself is `PRELUDE`.

@(private)
Builtin_Kind :: enum u8 {
	Value, // one output for each combination of its arguments' values
	Single, // at most one output, whatever its arguments
	Single_Args, // single when its arguments are
	Breaks, // single unless the program has `?//`, which outputs again after the break it makes
	Generator, // any number of outputs
}

// The builtins the evaluator runs itself, as they take filters or generate.
@(private)
Builtin_Op :: enum u8 {
	None,
	Empty,
	Select,
	Kind_Filter, // values, nulls, booleans, ...: the input when its type is in `types`
	Error,
	Path,
	Getpath,
	Limit,
	Skip,
	First,
	Last,
	Isempty,
	Range,
	Input,
	Inputs,
	Debug,
	Stderr,
	Halt,
	Halt_Error,
	Css,
}

@(private)
Value_Fn :: #type proc(x: ^Machine, b: ^Builtin, input: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status)

@(private)
Builtin :: struct {
	name:        string,
	arity:       u8,
	kind:        Builtin_Kind,
	op:          Builtin_Op,
	native:      bool, // the native evaluator runs it: a value builtin, or a filter one it knows
	takes_input: bool, // consumes `input` by move (preserving `rc == 1` for in-place COW mutation)
	fn:          Value_Fn,
	types:       bit_set[query.Type], // a kind filter's
}

// The builtin `name/arity`, nil for none.
@(private)
find_builtin :: proc(name: string, arity: int) -> ^Builtin {
	for &b in BUILTINS {
		if int(b.arity) == arity && b.name == name {
			return &b
		}
	}
	return nil
}

@(private)
NOT_NULL :: bit_set[query.Type]{.False, .True, .Number, .String, .Array, .Object}

@(private, rodata)
BUILTINS := [?]Builtin {
	{name = "empty", kind = .Single, op = .Empty, native = true},
	{name = "select", arity = 1, kind = .Single_Args, op = .Select, native = true},
	{name = "values", kind = .Single, op = .Kind_Filter, native = true, types = NOT_NULL},
	{name = "nulls", kind = .Single, op = .Kind_Filter, native = true, types = {.Null, .Absent}},
	{name = "booleans", kind = .Single, op = .Kind_Filter, native = true, types = {.False, .True}},
	{name = "numbers", kind = .Single, op = .Kind_Filter, native = true, types = {.Number}},
	{name = "strings", kind = .Single, op = .Kind_Filter, native = true, types = {.String}},
	{name = "arrays", kind = .Single, op = .Kind_Filter, native = true, types = {.Array}},
	{name = "objects", kind = .Single, op = .Kind_Filter, native = true, types = {.Object}},
	{name = "iterables", kind = .Single, op = .Kind_Filter, native = true, types = {.Array, .Object}},
	{name = "scalars", kind = .Single, op = .Kind_Filter, native = true, types = {.Absent, .Null, .False, .True, .Number, .String}},
	{name = "error", kind = .Single, op = .Error, native = true},
	{name = "error", arity = 1, kind = .Single, op = .Error, native = true},
	{name = "path", arity = 1, kind = .Single_Args, op = .Path},
	{name = "getpath", arity = 1, kind = .Single_Args, op = .Getpath},
	{name = "limit", arity = 2, kind = .Generator, op = .Limit},
	{name = "skip", arity = 2, kind = .Generator, op = .Skip},
	{name = "first", arity = 1, kind = .Breaks, op = .First},
	{name = "last", arity = 1, kind = .Single, op = .Last},
	{name = "isempty", arity = 1, kind = .Breaks, op = .Isempty},
	{name = "range", arity = 1, kind = .Generator, op = .Range},
	{name = "range", arity = 2, kind = .Generator, op = .Range},
	{name = "range", arity = 3, kind = .Generator, op = .Range},
	{name = "input", kind = .Single, op = .Input},
	{name = "inputs", kind = .Generator, op = .Inputs},
	{name = "debug", kind = .Single, op = .Debug},
	{name = "stderr", kind = .Single, op = .Stderr},
	{name = "halt", kind = .Single, op = .Halt},
	{name = "halt_error", arity = 1, kind = .Single, op = .Halt_Error},
	{name = "not", arity = 0, kind = .Value, native = true, fn = v_not},
	{name = "type", arity = 0, kind = .Value, native = true, fn = v_type},
	{name = "add", arity = 0, kind = .Value, native = true, fn = v_add},
	{name = "length", arity = 0, kind = .Value, native = true, fn = v_length},
	{name = "utf8bytelength", arity = 0, kind = .Value, native = true, fn = v_utf8bytelength},
	{name = "graphemes", arity = 0, kind = .Value, native = true, fn = v_grapheme},
	{name = "grapheme_length", arity = 0, kind = .Value, native = true, fn = v_grapheme},
	{name = "grapheme_slice", arity = 1, kind = .Value, native = true, fn = v_grapheme},
	{name = "grapheme_slice", arity = 2, kind = .Value, native = true, fn = v_grapheme},
	{name = "keys", arity = 0, kind = .Value, native = true, fn = v_keys},
	{name = "keys_unsorted", arity = 0, kind = .Value, native = true, fn = v_keys},
	{name = "tostring", arity = 0, kind = .Value, native = true, fn = v_tostring},
	{name = "tojson", arity = 0, kind = .Value, native = true, fn = v_tojson},
	{name = "tonumber", arity = 0, kind = .Value, native = true, fn = v_tonumber},
	{name = "fromjson", arity = 0, kind = .Value, native = true, fn = v_fromjson},
	{name = "ascii_downcase", arity = 0, kind = .Value, native = true, fn = v_ascii_case},
	{name = "ascii_upcase", arity = 0, kind = .Value, native = true, fn = v_ascii_case},
	{name = "explode", arity = 0, kind = .Value, native = true, fn = v_explode},
	{name = "implode", arity = 0, kind = .Value, native = true, fn = v_implode},
	{name = "trim", arity = 0, kind = .Value, native = true, fn = v_trim},
	{name = "ltrim", arity = 0, kind = .Value, native = true, fn = v_trim},
	{name = "rtrim", arity = 0, kind = .Value, native = true, fn = v_trim},
	{name = "sort", arity = 0, kind = .Value, native = true, takes_input = true, fn = v_sort},
	{name = "unique", arity = 0, kind = .Value, native = true, takes_input = true, fn = v_by},
	{name = "min", arity = 0, kind = .Value, native = true, fn = v_by},
	{name = "max", arity = 0, kind = .Value, native = true, fn = v_by},
	{name = "isinfinite", arity = 0, kind = .Value, native = true, fn = v_number_class},
	{name = "isnan", arity = 0, kind = .Value, native = true, fn = v_number_class},
	{name = "isnormal", arity = 0, kind = .Value, native = true, fn = v_number_class},
	{name = "gmtime", arity = 0, kind = .Value, native = true, fn = v_time},
	{name = "localtime", arity = 0, kind = .Value, native = true, fn = v_time},
	{name = "mktime", arity = 0, kind = .Value, native = true, fn = v_time},
	{name = "frexp", arity = 0, kind = .Value, native = true, fn = v_frexp},
	{name = "modf", arity = 0, kind = .Value, native = true, fn = v_frexp},
	{name = "lgamma_r", arity = 0, kind = .Value, native = true, fn = v_frexp},
	{name = "input_filename", arity = 0, kind = .Value, native = true, fn = v_constant},
	{name = "input_line_number", arity = 0, kind = .Value, native = true, fn = v_constant},
	{name = "where", arity = 0, kind = .Value, native = true, fn = v_where},
	{name = "builtins", arity = 0, kind = .Value, native = true, fn = v_builtins},
	{name = "now", arity = 0, kind = .Value, native = true, fn = v_constant},
	{name = "have_literal_numbers", arity = 0, kind = .Value, native = true, fn = v_constant},
	{name = "have_decnum", arity = 0, kind = .Value, native = true, fn = v_constant},
	{name = "get_search_list", arity = 0, kind = .Value, native = true, fn = v_module_info},
	{name = "get_jq_origin", arity = 0, kind = .Value, native = true, fn = v_module_info},
	{name = "get_prog_origin", arity = 0, kind = .Value, native = true, fn = v_module_info},
	{name = "modulemeta", arity = 0, kind = .Value, native = true, fn = v_modulemeta},
	{name = "infinite", arity = 0, kind = .Value, native = true, fn = v_constant},
	{name = "nan", arity = 0, kind = .Value, native = true, fn = v_constant},
	{name = "floor", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "ceil", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "round", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "trunc", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "rint", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "nearbyint", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "fabs", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "sqrt", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "cbrt", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "exp", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "exp2", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "exp10", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "expm1", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "log", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "log2", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "log10", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "log1p", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "logb", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "tgamma", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "lgamma", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "gamma", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "sin", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "cos", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "tan", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "asin", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "acos", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "atan", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "sinh", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "cosh", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "tanh", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "asinh", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "acosh", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "atanh", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "erf", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "erfc", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "j0", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "j1", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "y0", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "y1", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "significand", arity = 0, kind = .Value, native = true, fn = v_math},
	{name = "has", arity = 1, kind = .Value, native = true, fn = v_has},
	{name = "contains", arity = 1, kind = .Value, native = true, fn = v_contains},
	{name = "startswith", arity = 1, kind = .Value, native = true, fn = v_affix},
	{name = "endswith", arity = 1, kind = .Value, native = true, fn = v_affix},
	{name = "split", arity = 1, kind = .Value, native = true, fn = v_split},
	{name = "_strindices", arity = 1, kind = .Value, native = true, fn = v_strindices},
	{name = "format", arity = 1, kind = .Value, native = true, fn = v_format},
	{name = "bsearch", arity = 1, kind = .Value, native = true, fn = v_bsearch},
	{name = "strftime", arity = 1, kind = .Value, native = true, fn = v_time},
	{name = "strflocaltime", arity = 1, kind = .Value, native = true, fn = v_time},
	{name = "strptime", arity = 1, kind = .Value, native = true, fn = v_time},
	{name = "delpaths", arity = 1, kind = .Value, native = true, takes_input = true, fn = v_delpaths},
	{name = "setpath", arity = 2, kind = .Value, native = true, takes_input = true, fn = v_setpath},
	{name = "pow", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "atan2", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "fmod", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "fmin", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "fmax", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "hypot", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "copysign", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "nextafter", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "nexttoward", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "remainder", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "drem", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "fdim", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "ldexp", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "scalb", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "scalbln", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "jn", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "yn", arity = 2, kind = .Value, native = true, fn = v_math},
	{name = "fma", arity = 3, kind = .Value, native = true, fn = v_math},
	{name = "fromrfc3339", kind = .Value, native = true, fn = v_time},
	{name = "torfc3339", kind = .Value, native = true, fn = v_time},
	{name = "_sort_by_impl", arity = 1, kind = .Value, native = true, takes_input = true, fn = v_by},
	{name = "_group_by_impl", arity = 1, kind = .Value, native = true, takes_input = true, fn = v_by},
	{name = "_unique_by_impl", arity = 1, kind = .Value, native = true, takes_input = true, fn = v_by},
	{name = "_min_by_impl", arity = 1, kind = .Value, native = true, fn = v_by},
	{name = "_max_by_impl", arity = 1, kind = .Value, native = true, fn = v_by},
	{name = "_flatten", arity = 1, kind = .Value, native = true, fn = v_flatten},
	{name = "_match_impl", arity = 3, kind = .Value, native = true, fn = v_match_impl},
	{name = "avg", kind = .Value, native = true, fn = v_statistic},
	{name = "variance", kind = .Value, native = true, fn = v_statistic},
	{name = "stddev", kind = .Value, native = true, fn = v_statistic},
	{name = "median", kind = .Value, native = true, fn = v_statistic},
	{name = "quantile", arity = 1, kind = .Value, native = true, fn = v_statistic},
	{name = "frequency", kind = .Value, native = true, fn = v_statistic},
	{name = "union", arity = 1, kind = .Value, native = true, fn = v_set},
	{name = "intersect", arity = 1, kind = .Value, native = true, fn = v_set},
	{name = "except", arity = 1, kind = .Value, native = true, fn = v_set},
	{name = "fill_forward", kind = .Value, native = true, fn = v_reshape},
	{name = "melt", arity = 1, kind = .Value, native = true, fn = v_reshape},
	{name = "melt", arity = 3, kind = .Value, native = true, fn = v_reshape},
	{name = "pivot", arity = 3, kind = .Value, native = true, fn = v_reshape},
	{name = "sha1", kind = .Value, native = true, fn = v_digest},
	{name = "sha256", kind = .Value, native = true, fn = v_digest},
	{name = "sha512", kind = .Value, native = true, fn = v_digest},
	{name = "md5", kind = .Value, native = true, fn = v_digest},
	{name = "crc32", kind = .Value, native = true, fn = v_digest},
	{name = "hmac_sha256", arity = 1, kind = .Value, native = true, fn = v_hmac},
	{name = "hmac_sha512", arity = 1, kind = .Value, native = true, fn = v_hmac},
	{name = "hex_encode", kind = .Value, native = true, fn = v_text_code},
	{name = "hex_decode", kind = .Value, native = true, fn = v_text_code},
	{name = "base64url_encode", kind = .Value, native = true, fn = v_text_code},
	{name = "base64url_decode", kind = .Value, native = true, fn = v_text_code},
	{name = "uuid_v4", kind = .Value, native = true, fn = v_uuid},
	{name = "uuid_v7", kind = .Value, native = true, fn = v_uuid},
	{name = "parse_url", kind = .Value, native = true, fn = v_parse_text},
	{name = "parse_query_string", kind = .Value, native = true, fn = v_parse_text},
	{name = "parse_logfmt", kind = .Value, native = true, fn = v_parse_text},
	{name = "numfmt", arity = 1, kind = .Value, native = true, fn = v_numfmt},
	{name = "ip_valid", kind = .Value, native = true, fn = v_address},
	{name = "ip_class", kind = .Value, native = true, fn = v_address},
	{name = "ip_canonical", kind = .Value, native = true, fn = v_address},
	{name = "ip_in_cidr", arity = 1, kind = .Value, native = true, fn = v_address},
	{name = "_pointer_tokens", arity = 1, kind = .Value, native = true, fn = v_pointer},
	{name = "_pointer_index", kind = .Value, native = true, fn = v_pointer},
	{name = "_fact_step", arity = 1, kind = .Value, native = true, fn = v_fact_step},
	{name = "_attribute_step", arity = 1, kind = .Value, native = true, fn = v_attribute_step},
	{name = "css", arity = 1, kind = .Generator, op = .Css},
}

// What jq 1.8.2 writes in jq itself (src/builtin.jq), each definition reached only when a program calls it.
@(private)
PRELUDE :: `
def map(f): [.[] | f];
def recurse(f): def r: ., (f | r); r;
def recurse: recurse(.[]?);
def env: $ENV;
def sort_by(f): _sort_by_impl(map([f]));
def group_by(f): _group_by_impl(map([f]));
def unique_by(f): _unique_by_impl(map([f]));
def max_by(f): _max_by_impl(map([f]));
def min_by(f): _min_by_impl(map([f]));
def to_entries: [keys_unsorted[] as $k | {key: $k, value: .[$k]}];
def reverse: [.[range(length-1;-1;-1)]];
def join($x): reduce .[] as $i (null;
            (if .==null then "" else .+$x end) |
            . + ($i | if type=="boolean" or type=="number" then tostring end)
        ) // "";
def _flatten_any($x): reduce .[] as $i ([]; if $i | type == "array" and $x != 0 then . + ($i | _flatten_any($x - 1)) else . + [$i] end);
def flatten($x): if $x < 0 then error("flatten depth must not be negative") elif ($x | type) == "number" then _flatten($x) else _flatten_any($x) end;
def flatten: _flatten(-1);
def ltrimstr($left): if startswith($left) then .[$left | length:] end;
def rtrimstr($right): if endswith($right) then .[:length - ($right | length)] end;
def match(re; mode): _match_impl(re; mode; false)|.[];
def match($val): ($val|type) as $vt | if $vt == "string" then match($val; null)
   elif $vt == "array" and ($val | length) > 1 then match($val[0]; $val[1])
   elif $vt == "array" and ($val | length) > 0 then match($val[0]; null)
   else error( $vt + " not a string or array") end;
def test(re; mode): _match_impl(re; mode; true);
def test($val): ($val|type) as $vt | if $vt == "string" then test($val; null)
   elif $vt == "array" and ($val | length) > 1 then test($val[0]; $val[1])
   elif $vt == "array" and ($val | length) > 0 then test($val[0]; null)
   else error( $vt + " not a string or array") end;
def capture(re; mods): match(re; mods) | reduce ( .captures | .[] | select(.name != null) | { (.name) : .string } ) as $pair ({}; . + $pair);
def capture($val): ($val|type) as $vt | if $vt == "string" then capture($val; null)
   elif $vt == "array" and ($val | length) > 1 then capture($val[0]; $val[1])
   elif $vt == "array" and ($val | length) > 0 then capture($val[0]; null)
   else error( $vt + " not a string or array") end;
def scan($re; $flags):
  match($re; "g" + $flags)
    | if (.captures|length > 0)
      then [ .captures | .[] | .string ]
      else .string
      end;
def scan($re): scan($re; null);
def splits($re; $flags):
  .[foreach (match($re; $flags+"g"), null) as {$offset, $length}
      (null; {start: .next, end: $offset, next: ($offset+$length)})];
def splits($re): splits($re; null);
def split($re; $flags): [ splits($re; $flags) ];
def sub($re; s; $flags):
   . as $in
   | (reduce match($re; $flags) as $edit
        ({result: [], previous: 0};
            $in[ .previous: ($edit | .offset) ] as $gap
            | [reduce ( $edit | .captures | .[] | select(.name != null) | { (.name) : .string } ) as $pair
                 ({}; . + $pair) | s ] as $inserts
            | reduce range(0; $inserts|length) as $ix (.; .result[$ix] += $gap + $inserts[$ix])
            | .previous = ($edit | .offset + .length ) )
          | .result[] + $in[.previous:] )
      // $in;
def sub($re; s): sub($re; s; "");
def gsub($re; s; flags): sub($re; s; flags + "g");
def gsub($re; s): sub($re; s; "g");
def tostream:
  path(def r: (.[]?|r), .; r) as $p |
  getpath($p) |
  reduce path(.[]?) as $q ([$p, .]; [$p+$q]);
def map_values(f): .[] |= f;
def recurse(f; cond): def r: ., (f | select(cond) | r); r;
def finites: select(type == "number" and (isinfinite | not));
def normals: select(isnormal);
def add(f): reduce f as $x (null; . + $x);

def del(f): delpaths([path(f)]);
def paths: path(recurse) | select(length > 0);
def paths(node_filter): path(recurse | select(node_filter)) | select(length > 0);
def pick(pathexps): . as $top | reduce path(pathexps) as $p (null; setpath($p; $top | getpath($p)));
def from_entries: add(.[] | { ((.key // .Key // .name // .Name) | if type == "string" then . else error("Cannot use \(type) (\(tojson)) as object key") end):
  if has("value") then .value else .Value end }) // {};
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
def fromstream(f): { x: null, e: false } as $init
  | foreach f as $i ($init;
      if .e then $init else . end
      | if $i | length == 2
        then setpath(["e"]; $i[0] | length == 0) | setpath(["x"] + $i[0]; $i[1])
        else setpath(["e"]; $i[0] | length == 1) end;
      if .e then .x else empty end);
def truncate_stream(stream): . as $n | null | stream | . as $input
  | if (.[0] | length) > $n then setpath([0]; .[0][$n:]) else empty end;
def leaf_paths: paths(scalars);
def avg(f): map(f) | avg;
def variance(f): map(f) | variance;
def stddev(f): map(f) | stddev;
def median(f): map(f) | median;
def quantile($p; f): map(f) | quantile($p);
def frequency(f): map(f) | frequency;
def _pointer_walk($t; $i): if $i == ($t | length) then . else (if type == "array" then ($t[$i] | _pointer_index) as $k | if $k == null then null else .[$k] end else .[$t[$i]] end | _pointer_walk($t; $i + 1)) end;
def json_pointer($p): _pointer_walk(_pointer_tokens($p); 0);
`
