package jq

import "core:strings"
import "stury:lib/query"

// Relational join helpers for jq:
// 1. Pure-jq join helper library (`JOIN_STDLIB` + `compile_with_joins`) adding `index_by(f)`,
//    `group_by_key(f)`, `lookup($idx; $key)`, `hash_join`, `left_join`, `semi_join`, and `anti_join`.
// 2. Native `query.Hash_Index` / key-object builders backed by compiled jq key filters (`Program`).

JOIN_STDLIB :: `def _join_canon:
  if type == "object" then . as $o | reduce (keys[]) as $k ({}; .[$k] = ($o[$k] | _join_canon))
  elif type == "array" then map(_join_canon) else . end;
def _join_key:
  if . == null then "u:null"
  elif type == "boolean" then "b:\(.)"
  elif type == "number" then
    if isnan then empty
    elif isinfinite then (if . > 0 then "n:inf" else "n:-inf" end)
    elif . == floor and . >= -9007199254740992 and . <= 9007199254740992 then "n:\(floor)"
    else "n:\(.)" end
  elif type == "string" then "s:\(.)"
  else "j:\(_join_canon | tojson)" end;
def _jk(f): first(f | _join_key) // null;
def _join_rows(f): if type == "array" then [.[] | f] else f end;
def _join_set(f): reduce .[] as $r ({}; ($r | _jk(f)) as $k | if $k == null then . else .[$k] = true end);
def index_by(f): reduce .[] as $row ({}; ($row | _jk(f)) as $k | if $k == null then . else .[$k] = $row end);
def group_by_key(f): reduce .[] as $row ({}; ($row | _jk(f)) as $k | if $k == null then . else .[$k] = ((.[$k] // []) + [$row]) end);
def lookup($idx; $key):
  if ($idx | type) == "object" then
    ($key | _jk(.)) as $k |
    if $k != null and ($idx | has($k)) then $idx[$k]
    elif ($key | type) == "string" and ($idx | has($key)) then $idx[$key]
    elif $key == null and ($idx | has("null")) then $idx["null"]
    elif ($key | type) == "number" then
      if ($key | isnan) then null
      elif ($key | isinfinite) then (if $key > 0 then "Infinity" else "-Infinity" end) as $ik | if ($idx | has($ik)) then $idx[$ik] else null end
      elif ($idx | has($key | tostring)) then $idx[$key | tostring] else null end
    elif ($key | type) == "boolean" and ($idx | has($key | tostring)) then $idx[$key | tostring]
    elif (($key | type) == "array" or ($key | type) == "object") then
      ($key | _join_canon | tojson) as $jk | if ($idx | has($jk)) then $idx[$jk] else null end
    else null end
  elif ($idx | type) == "array" and ($key | type) == "number" then $idx[$key]
  else null end;
def hash_join($right; left_key; right_key):
  ($right | group_by_key(right_key)) as $idx |
  _join_rows(. as $l | ($l | _jk(left_key)) as $k | if $k == null then empty else ($idx[$k] // [])[] | [$l, .] end);
def left_join($right; left_key; right_key):
  ($right | group_by_key(right_key)) as $idx |
  _join_rows(. as $l | (($l | _jk(left_key)) as $k | if $k == null then [] else ($idx[$k] // []) end) as $ms | if ($ms | length) == 0 then [$l, null] else ($ms[] | [$l, .]) end);
def semi_join($right; left_key; right_key):
  ($right | _join_set(right_key)) as $idx | _join_rows(select((_jk(left_key)) as $k | $k != null and ($idx[$k] // false)));
def anti_join($right; left_key; right_key):
  ($right | _join_set(right_key)) as $idx | _join_rows(select(((_jk(left_key)) as $k | $k != null and ($idx[$k] // false)) | not));
`

Join_Index_Mode :: enum u8 {
	First, // keep first row per key
	Last,  // keep last row per key
	Group, // keep all matching rows as an array per key
}

// Compiles jq source `src` with `JOIN_STDLIB` definitions in scope (placed after any leading
// `module`, `import`, or `include` directives so jq grammar rules remain intact).
compile_with_joins :: proc(src: string, opts: Compile_Options = {}, allocator := context.allocator) -> (prog: ^Program, errors: []Compile_Error) {
	split_at := find_preamble_end(src)
	combined := strings.concatenate({src[:split_at], JOIN_STDLIB, src[split_at:]}, allocator)
	defer delete(combined, allocator)
	return compile(combined, opts, allocator)
}

// Evaluates `prog` on borrowed `input`, returning its first emitted value (`found = false` if empty).
eval_first :: proc(prog: ^Program, h: ^query.Heap, input: query.Value, hooks: ^Hooks = nil, globals: []query.Value = nil, steps := 0) -> (val: query.Value, found: bool, status: query.Status) {
	if prog == nil || h == nil {
		return query.ABSENT, false, .Error
	}
	Capture :: struct {
		val:   query.Value,
		found: bool,
	}
	on_val :: proc(data: rawptr, v: query.Value, _: ^query.Heap) -> bool {
		cap := (^Capture)(data)
		cap.val, cap.found = v, true
		return false
	}
	run: Run
	run_init(&run, prog, h, globals, hooks, steps)
	defer run_destroy(&run)

	cap: Capture
	end := run_value(&run, query.retain(input), on_val, &cap)
	if h.tainted || end == .Tainted || end == .Failed {
		if cap.found {
			query.release(h, cap.val)
		}
		if end == .Tainted {
			h.tainted = true
		}
		return query.ABSENT, false, .Error
	}
	return cap.val if cap.found else query.ABSENT, cap.found, .Ok
}

// Builds a native `query.Hash_Index` over `right_collection` using compiled jq key filter `key_prog`.
@(require_results)
join_index_build :: proc(h: ^query.Heap, right_collection: query.Value, key_prog: ^Program, hooks: ^Hooks = nil, globals: []query.Value = nil, steps := 0) -> (idx: query.Hash_Index, status: query.Status) {
	if h == nil || key_prog == nil {
		return {}, .Error
	}
	Exec_Ctx :: struct {
		prog:    ^Program,
		hooks:   ^Hooks,
		globals: []query.Value,
		steps:   int,
	}
	extract :: proc(raw_ctx: rawptr, hp: ^query.Heap, row: query.Value) -> (query.Value, bool, query.Status) {
		ec := (^Exec_Ctx)(raw_ctx)
		return eval_first(ec.prog, hp, row, ec.hooks, ec.globals, ec.steps)
	}
	ec := Exec_Ctx{prog = key_prog, hooks = hooks, globals = globals, steps = steps}
	return query.hash_index_build(h, right_collection, extract, &ec)
}

// Builds a key-indexed `query.Value` lookup object `{key_text: row}` (or `{key_text: [rows]}` under `.Group`).
@(require_results)
join_lookup_object :: proc(h: ^query.Heap, right_collection: query.Value, key_prog: ^Program, mode := Join_Index_Mode.Last, hooks: ^Hooks = nil, globals: []query.Value = nil, steps := 0) -> (res: query.Value, status: query.Status) {
	if h == nil || key_prog == nil {
		return query.NULL, .Error
	}
	if ct := query.type_of(right_collection); ct != .Array && ct != .Object {
		return query.NULL, query.fail(h, .Types, .Iterate, right_collection)
	}
	Group_Bucket :: struct {
		key, arr: query.Value,
	}
	n := query.length_of(h, right_collection)
	obj := query.make_object(h, n) or_return
	buckets: [dynamic]Group_Bucket
	buckets.allocator = query.heap_allocator(h)
	defer {
		if status != .Ok || mode == .Group {
			query.release(h, obj)
		}
		for &bk in buckets {
			query.release(h, bk.key)
			query.release(h, bk.arr)
		}
		delete(buckets)
	}
	if mode == .Group && n > 0 && reserve(&buckets, min(n, 64)) != nil {
		return query.NULL, query.fail(h, .Memory, .None)
	}
	cur := query.cursor_open(h, right_collection) or_return
	defer query.cursor_close(&cur)

	for {
		mk, row, more := query.cursor_next(h, &cur) or_return
		query.release(h, mk)
		if !more {
			break
		}
		raw_key, found, ks := eval_first(key_prog, h, row, hooks, globals, steps)
		if ks != .Ok || !found || raw_key.kind == .Absent {
			query.release(h, row)
			query.release(h, raw_key)
			if ks != .Ok {
				return query.NULL, ks
			}
			continue
		}
		kstr, cs := query.canonical_index_key(h, raw_key)
		query.release(h, raw_key)
		if cs != .Ok || kstr.kind == .Absent {
			query.release(h, row)
			if cs != .Ok {
				return query.NULL, cs
			}
			continue
		}
		if mode != .Group {
			if mode == .First && query.has_member(h, obj, query.text_of(kstr)) {
				query.release(h, kstr)
				query.release(h, row)
				continue
			}
			query.object_put(h, &obj, kstr, row) or_return
			continue
		}
		existing, es := query.member(h, obj, query.text_of(kstr))
		if es != .Ok {
			query.release(h, kstr)
			query.release(h, row)
			return query.NULL, es
		}
		if existing.kind == .Absent {
			bucket, bs := query.make_array(h, 1)
			if bs != .Ok {
				query.release(h, kstr)
				query.release(h, row)
				return query.NULL, bs
			}
			if ps := query.append_owned(h, &bucket, row); ps != .Ok {
				query.release(h, bucket)
				query.release(h, kstr)
				return query.NULL, ps
			}
			if _, aerr := append(&buckets, Group_Bucket{key = kstr, arr = bucket}); aerr != nil {
				query.release(h, bucket)
				query.release(h, kstr)
				return query.NULL, query.fail(h, .Memory, .None)
			}
			query.object_put(h, &obj, query.retain(kstr), query.int_value(i64(len(buckets) - 1))) or_return
		} else {
			query.release(h, kstr)
			query.append_owned(h, &buckets[int(existing.i)].arr, row) or_return
		}
	}
	if mode != .Group {
		return obj, .Ok
	}
	query.release(h, obj)
	obj = query.ABSENT
	out := query.make_object(h, len(buckets)) or_return
	defer if status != .Ok {
		query.release(h, out)
	}
	for &bk in buckets {
		bk_key, bk_arr := bk.key, bk.arr
		bk = {}
		query.object_put(h, &out, bk_key, bk_arr) or_return
	}
	return out, .Ok
}

// Performs an O(1)-per-row hash join probe over `left_collection` using pre-built `right_idx`.
@(require_results)
join_hash_eval :: proc(h: ^query.Heap, left_collection: query.Value, right_idx: ^query.Hash_Index, left_key_prog: ^Program, kind := query.Join_Kind.Inner, combine := query.Join_Combine.Pair, hooks: ^Hooks = nil, globals: []query.Value = nil, steps := 0) -> (res: query.Value, status: query.Status) {
	if h == nil || right_idx == nil || left_key_prog == nil {
		return query.NULL, .Error
	}
	if lt := query.type_of(left_collection); lt != .Array && lt != .Object {
		return query.NULL, query.fail(h, .Types, .Iterate, left_collection)
	}
	out := query.make_array(h, query.length_of(h, left_collection)) or_return
	defer if status != .Ok {
		query.release(h, out)
	}
	cur := query.cursor_open(h, left_collection) or_return
	defer query.cursor_close(&cur)

	emit_row :: proc(h: ^query.Heap, out: ^query.Value, lrow, rrow: query.Value, matched: bool, combine: query.Join_Combine) -> query.Status {
		joined := query.join_combine_rows(h, lrow, rrow, matched, combine) or_return
		return query.append_owned(h, out, joined)
	}

	for {
		mk, lrow, more := query.cursor_next(h, &cur) or_return
		query.release(h, mk)
		if !more {
			break
		}
		defer query.release(h, lrow)
		lkey, found, ks := eval_first(left_key_prog, h, lrow, hooks, globals, steps)
		defer query.release(h, lkey)
		if ks != .Ok {
			return query.NULL, ks
		}
		matches: []query.Value
		if found && lkey.kind != .Absent {
			matches = query.hash_index_lookup(right_idx, lkey) or_return
		}
		if kind == .Semi {
			if len(matches) > 0 {
				query.append_owned(h, &out, query.retain(lrow)) or_return
			}
			continue
		}
		if len(matches) == 0 {
			if kind == .Left {
				emit_row(h, &out, lrow, query.ABSENT, false, combine) or_return
			}
			continue
		}
		for rrow in matches {
			emit_row(h, &out, lrow, rrow, true, combine) or_return
		}
	}
	return out, .Ok
}

// Finds byte offset right after any leading `module ...;`, `import ...;`, `include ...;` headers.
@(private = "file")
find_preamble_end :: proc(src: string) -> int #no_bounds_check {
	i, n := 0, len(src)
	for {
		j := skip_ws_and_comments(src, i)
		if j >= n || !(src[j] == '_' || (src[j] >= 'a' && src[j] <= 'z') || (src[j] >= 'A' && src[j] <= 'Z')) {
			return i
		}
		kw_start := j
		for j < n && ident_byte(src[j]) {
			j += 1
		}
		kw := src[kw_start:j]
		if kw != "module" && kw != "import" && kw != "include" {
			return i
		}
		semi := skip_stmt_to_semicolon(src, j)
		if semi < 0 {
			return i
		}
		i = semi + 1
	}
}

@(private = "file")
skip_jq_comment :: proc "contextless" (src: string, start: int) -> int #no_bounds_check {
	for i, n := start + 1, len(src); i < n; {
		c := src[i]
		if c == '\n' {
			return i + 1
		}
		if c == '\r' && i + 1 < n && src[i + 1] == '\n' {
			return i + 2
		}
		if c == '\\' && i + 1 < n {
			if src[i + 1] == '\\' || src[i + 1] == '\n' {
				i += 2
				continue
			}
			if src[i + 1] == '\r' && i + 2 < n && src[i + 2] == '\n' {
				i += 3
				continue
			}
		}
		i += 1
	}
	return len(src)
}

@(private = "file")
skip_ws_and_comments :: proc "contextless" (s: string, start: int) -> int #no_bounds_check {
	i := start
	for i < len(s) {
		switch s[i] {
		case ' ', '\t', '\r', '\n':
			i += 1
		case '#':
			i = skip_jq_comment(s, i)
		case:
			return i
		}
	}
	return i
}

@(private = "file")
skip_stmt_to_semicolon :: proc "contextless" (s: string, start: int) -> int #no_bounds_check {
	depth := 0
	in_str := false
	for i, n := start, len(s); i < n; {
		c := s[i]
		if in_str {
			if c == '\\' && i + 1 < n {
				i += 2
				continue
			}
			if c == '"' {
				in_str = false
			}
			i += 1
			continue
		}
		switch c {
		case '"':
			in_str = true
		case '#':
			i = skip_jq_comment(s, i)
			continue
		case '{', '(':
			depth += 1
		case '}', ')':
			depth = max(depth - 1, 0)
		case ';':
			if depth == 0 {
				return i
			}
		}
		i += 1
	}
	return -1
}
