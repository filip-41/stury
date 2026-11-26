package jq

import "core:strings"
import "stury:lib/query"

// Relational join helpers for jq:
// 1. Pure-jq join helper library (`JOIN_STDLIB` + `compile_with_joins`) adding `index_by(f)`,
//    `group_by_key(f)`, `lookup($idx; $key)`, `hash_join($right; left_key; right_key)`,
//    `left_join($right; left_key; right_key)`, `semi_join($right; left_key; right_key)`, and
//    `anti_join($right; left_key; right_key)`.
// 2. Native `query.Hash_Index` / key-object builders backed by compiled jq key filters (`Program`)
//    so streaming joins avoid O(N*M) nested loops and honor exact jq numeric/scalar equality (`1 == 1.0`).

// Canonical scalar key encoding (`"u:null"`, `"b:true"`, `"n:1"`, `"s:foo"`, etc.) ensures numeric
// equivalence (`1` == `1.0`) without conflating integers with strings (`1` vs `"1"`), distinguishes
// `+Inf`/`-Inf` from `null`, canonicalizes compound objects with sorted keys, and omits NaN.
JOIN_STDLIB :: `def _join_canon:
  if type == "object" then
    . as $o | reduce (keys[]) as $k ({}; .[$k] = ($o[$k] | _join_canon))
  elif type == "array" then
    map(_join_canon)
  else . end;
def _join_key:
  if . == null then "u:null"
  elif type == "boolean" then "b:\(.)"
  elif type == "number" then
    if isnan then empty
    elif isinfinite then (if . > 0 then "n:inf" else "n:-inf" end)
    elif . == floor and . >= -9007199254740992 and . <= 9007199254740992 then "n:\(floor)"
    else "n:\(.)"
    end
  elif type == "string" then "s:\(.)"
  else "j:\(_join_canon | tojson)"
  end;
def index_by(f):
  reduce .[] as $row ({}; (first($row | f | _join_key) // null) as $k | if $k == null then . else .[$k] = $row end);
def group_by_key(f):
  reduce .[] as $row ({}; (first($row | f | _join_key) // null) as $k | if $k == null then . else .[$k] = ((.[$k] // []) + [$row]) end);
def lookup($idx; $key):
  if ($idx | type) == "object" then
    (first($key | _join_key) // null) as $k |
    if $k != null and ($idx | has($k)) then $idx[$k]
    elif ($key | type) == "string" and ($idx | has($key)) then $idx[$key]
    elif $key == null and ($idx | has("null")) then $idx["null"]
    elif ($key | type) == "number" then
      if ($key | isnan) then null
      elif ($key | isinfinite) then (if $key > 0 then "Infinity" else "-Infinity" end) as $ik | if ($idx | has($ik)) then $idx[$ik] else null end
      elif ($idx | has($key | tostring)) then $idx[$key | tostring]
      else null
      end
    elif ($key | type) == "boolean" and ($idx | has($key | tostring)) then $idx[$key | tostring]
    elif (($key | type) == "array" or ($key | type) == "object") then
      (($key | _join_canon | tojson)) as $jk |
      if ($idx | has($jk)) then $idx[$jk] else null end
    else null
    end
  elif ($idx | type) == "array" and ($key | type) == "number" then
    $idx[$key]
  else
    null
  end;
def hash_join($right; left_key; right_key):
  ($right | group_by_key(right_key)) as $idx |
  if type == "array" then
    [.[] | . as $l | (first($l | left_key | _join_key) // null) as $k | if $k == null then empty else ($idx[$k] // [])[] | [$l, .] end]
  else
    . as $l | (first($l | left_key | _join_key) // null) as $k | if $k == null then empty else ($idx[$k] // [])[] | [$l, .] end
  end;
def left_join($right; left_key; right_key):
  ($right | group_by_key(right_key)) as $idx |
  if type == "array" then
    [.[] | . as $l | ((first($l | left_key | _join_key) // null) as $k | if $k == null then [] else ($idx[$k] // []) end) as $ms | if ($ms | length) == 0 then [$l, null] else ($ms[] | [$l, .]) end]
  else
    . as $l | ((first($l | left_key | _join_key) // null) as $k | if $k == null then [] else ($idx[$k] // []) end) as $ms | if ($ms | length) == 0 then [$l, null] else ($ms[] | [$l, .]) end
  end;
def semi_join($right; left_key; right_key):
  ($right | reduce .[] as $r ({}; (first($r | right_key | _join_key) // null) as $k | if $k == null then . else .[$k] = true end)) as $idx |
  if type == "array" then
    [.[] | select(((first(left_key | _join_key) // null) as $k | $k != null and ($idx[$k] // false)))]
  else
    select(((first(left_key | _join_key) // null) as $k | $k != null and ($idx[$k] // false)))
  end;
def anti_join($right; left_key; right_key):
  ($right | reduce .[] as $r ({}; (first($r | right_key | _join_key) // null) as $k | if $k == null then . else .[$k] = true end)) as $idx |
  if type == "array" then
    [.[] | select(((first(left_key | _join_key) // null) as $k | $k != null and ($idx[$k] // false)) | not)]
  else
    select(((first(left_key | _join_key) // null) as $k | $k != null and ($idx[$k] // false)) | not)
  end;
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
eval_first :: proc(
	prog: ^Program,
	h: ^query.Heap,
	input: query.Value,
	hooks: ^Hooks = nil,
	globals: []query.Value = nil,
	steps := 0,
) -> (
	val: query.Value,
	found: bool,
	status: query.Status,
) {
	if prog == nil || h == nil {
		return query.ABSENT, false, .Error
	}
	Capture :: struct {
		val:   query.Value,
		found: bool,
	}
	on_val :: proc(data: rawptr, v: query.Value, _: ^query.Heap) -> bool {
		cap := (^Capture)(data)
		cap.val = v
		cap.found = true
		return false
	}
	run: Run
	run_init(&run, prog, h, globals, hooks, steps)
	defer run_destroy(&run)

	cap: Capture
	end := run_value(&run, query.retain(input), on_val, &cap)
	if h.tainted || end == .Tainted {
		if cap.found {
			query.release(h, cap.val)
		}
		h.tainted = true
		return query.ABSENT, false, .Error
	}
	if end == .Failed {
		if cap.found {
			query.release(h, cap.val)
		}
		return query.ABSENT, false, .Error
	}
	if !cap.found {
		return query.ABSENT, false, .Ok
	}
	return cap.val, true, .Ok
}

// Builds a native `query.Hash_Index` over `right_collection` using compiled jq key filter `key_prog`.
// Always release the returned index via `query.hash_index_destroy(&idx)`.
@(require_results)
join_index_build :: proc(
	h: ^query.Heap,
	right_collection: query.Value,
	key_prog: ^Program,
	hooks: ^Hooks = nil,
	globals: []query.Value = nil,
	steps := 0,
) -> (
	idx: query.Hash_Index,
	status: query.Status,
) {
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

// Builds a key-indexed `query.Value` lookup object `{key_text: row}` (or `{key_text: [rows]}` under
// `.Group`) from `right_collection` using compiled jq key filter `key_prog` in a single O(M) pass.
@(require_results)
join_lookup_object :: proc(
	h: ^query.Heap,
	right_collection: query.Value,
	key_prog: ^Program,
	mode := Join_Index_Mode.Last,
	hooks: ^Hooks = nil,
	globals: []query.Value = nil,
	steps := 0,
) -> (
	query.Value,
	query.Status,
) {
	if h == nil || key_prog == nil {
		return query.NULL, .Error
	}
	ct := query.type_of(right_collection)
	if ct != .Array && ct != .Object {
		return query.NULL, query.fail(h, .Types, .Iterate, right_collection)
	}
	n := query.length_of(h, right_collection)

	if mode != .Group {
		obj, obj_status := query.make_object(h, n)
		if obj_status != .Ok {
			return query.NULL, obj_status
		}
		ok := false
		defer if !ok {
			query.release(h, obj)
		}
		cur, cur_status := query.cursor_open(h, right_collection)
		if cur_status != .Ok {
			return query.NULL, cur_status
		}
		defer query.cursor_close(&cur)

		for {
			mk, row, more, ns := query.cursor_next(h, &cur)
			query.release(h, mk)
			if ns != .Ok {
				return query.NULL, ns
			}
			if !more {
				break
			}
			raw_key, found, ks := eval_first(key_prog, h, row, hooks, globals, steps)
			if ks != .Ok {
				query.release(h, row)
				query.release(h, raw_key)
				return query.NULL, ks
			}
			if !found || raw_key.kind == .Absent {
				query.release(h, row)
				query.release(h, raw_key)
				continue
			}
			kstr, cs := query.canonical_index_key(h, raw_key)
			query.release(h, raw_key)
			if cs != .Ok {
				query.release(h, row)
				return query.NULL, cs
			}
			if kstr.kind == .Absent {
				query.release(h, row)
				continue
			}
			if mode == .First && query.has_member(h, obj, query.text_of(kstr)) {
				query.release(h, kstr)
				query.release(h, row)
				continue
			}
			if os := query.object_put(h, &obj, kstr, row); os != .Ok {
				return query.NULL, os
			}
		}
		ok = true
		return obj, .Ok
	}

	Group_Bucket :: struct {
		key: query.Value,
		arr: query.Value,
	}
	alloc := query.heap_allocator(h)
	idx_obj, idx_status := query.make_object(h, n)
	if idx_status != .Ok {
		return query.NULL, idx_status
	}
	buckets: [dynamic]Group_Bucket
	buckets.allocator = alloc
	if n > 0 {
		if reserve(&buckets, min(n, 64)) != nil {
			query.release(h, idx_obj)
			return query.NULL, query.fail(h, .Memory, .None)
		}
	}
	defer {
		query.release(h, idx_obj)
		for &bk in buckets {
			query.release(h, bk.key)
			query.release(h, bk.arr)
		}
		delete(buckets)
	}

	cur, cur_status := query.cursor_open(h, right_collection)
	if cur_status != .Ok {
		return query.NULL, cur_status
	}
	defer query.cursor_close(&cur)

	for {
		mk, row, more, ns := query.cursor_next(h, &cur)
		query.release(h, mk)
		if ns != .Ok {
			return query.NULL, ns
		}
		if !more {
			break
		}
		raw_key, found, ks := eval_first(key_prog, h, row, hooks, globals, steps)
		if ks != .Ok {
			query.release(h, row)
			query.release(h, raw_key)
			return query.NULL, ks
		}
		if !found || raw_key.kind == .Absent {
			query.release(h, row)
			query.release(h, raw_key)
			continue
		}
		kstr, cs := query.canonical_index_key(h, raw_key)
		query.release(h, raw_key)
		if cs != .Ok {
			query.release(h, row)
			return query.NULL, cs
		}
		if kstr.kind == .Absent {
			query.release(h, row)
			continue
		}
		existing, es := query.member(h, idx_obj, query.text_of(kstr))
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
			gi := i64(len(buckets))
			if _, aerr := append(&buckets, Group_Bucket{key = kstr, arr = bucket}); aerr != nil {
				query.release(h, bucket)
				query.release(h, kstr)
				return query.NULL, query.fail(h, .Memory, .None)
			}
			if os := query.object_put(h, &idx_obj, query.retain(kstr), query.int_value(gi)); os != .Ok {
				return query.NULL, os
			}
		} else {
			gi := int(existing.i)
			query.release(h, kstr)
			// `buckets[gi].arr` stays uniquely held (`rc == 1`) so append is amortized O(1).
			if ps := query.append_owned(h, &buckets[gi].arr, row); ps != .Ok {
				return query.NULL, ps
			}
		}
	}

	query.release(h, idx_obj)
	idx_obj = query.ABSENT

	out, out_status := query.make_object(h, len(buckets))
	if out_status != .Ok {
		return query.NULL, out_status
	}
	ok := false
	defer if !ok {
		query.release(h, out)
	}
	for &bk in buckets {
		bk_key, bk_arr := bk.key, bk.arr
		bk = {}
		if put_status := query.object_put(h, &out, bk_key, bk_arr); put_status != .Ok {
			return query.NULL, put_status
		}
	}
	ok = true
	return out, .Ok
}

// Performs an O(1)-per-row hash join probe over `left_collection` using pre-built `right_idx` and
// left key expression `left_key_prog`.
@(require_results)
join_hash_eval :: proc(
	h: ^query.Heap,
	left_collection: query.Value,
	right_idx: ^query.Hash_Index,
	left_key_prog: ^Program,
	kind := query.Join_Kind.Inner,
	combine := query.Join_Combine.Pair,
	hooks: ^Hooks = nil,
	globals: []query.Value = nil,
	steps := 0,
) -> (
	res: query.Value,
	status: query.Status,
) {
	if h == nil || right_idx == nil || left_key_prog == nil {
		return query.NULL, .Error
	}
	lt := query.type_of(left_collection)
	if lt != .Array && lt != .Object {
		return query.NULL, query.fail(h, .Types, .Iterate, left_collection)
	}
	out := query.make_array(h, query.length_of(h, left_collection)) or_return
	defer if status != .Ok {
		query.release(h, out)
	}
	cur := query.cursor_open(h, left_collection) or_return
	defer query.cursor_close(&cur)

	for {
		mk, lrow, more, ns := query.cursor_next(h, &cur)
		query.release(h, mk)
		if ns != .Ok {
			return query.NULL, ns
		}
		if !more {
			break
		}
		lkey, found, ks := eval_first(left_key_prog, h, lrow, hooks, globals, steps)
		if ks != .Ok {
			query.release(h, lrow)
			query.release(h, lkey)
			return query.NULL, ks
		}
		matches: []query.Value
		if found && lkey.kind != .Absent {
			ls: query.Status
			matches, ls = query.hash_index_lookup(right_idx, lkey)
			if ls != .Ok {
				query.release(h, lrow)
				query.release(h, lkey)
				return query.NULL, ls
			}
		}
		query.release(h, lkey)

		switch kind {
		case .Inner:
			for rrow in matches {
				joined, js := query.join_combine_rows(h, lrow, rrow, true, combine)
				if js != .Ok {
					query.release(h, lrow)
					return query.NULL, js
				}
				if as := query.append_owned(h, &out, joined); as != .Ok {
					query.release(h, lrow)
					return query.NULL, as
				}
			}
		case .Left:
			if len(matches) == 0 {
				joined, js := query.join_combine_rows(h, lrow, query.ABSENT, false, combine)
				if js != .Ok {
					query.release(h, lrow)
					return query.NULL, js
				}
				if as := query.append_owned(h, &out, joined); as != .Ok {
					query.release(h, lrow)
					return query.NULL, as
				}
			} else {
				for rrow in matches {
					joined, js := query.join_combine_rows(h, lrow, rrow, true, combine)
					if js != .Ok {
						query.release(h, lrow)
						return query.NULL, js
					}
					if as := query.append_owned(h, &out, joined); as != .Ok {
						query.release(h, lrow)
						return query.NULL, as
					}
				}
			}
		case .Semi:
			if len(matches) > 0 {
				if as := query.append_owned(h, &out, query.retain(lrow)); as != .Ok {
					query.release(h, lrow)
					return query.NULL, as
				}
			}
		}
		query.release(h, lrow)
	}
	return out, .Ok
}

// Finds byte offset right after any leading `module ...;`, `import ...;`, `include ...;` headers.
@(private = "file")
find_preamble_end :: proc "contextless" (src: string) -> int #no_bounds_check {
	i := 0
	n := len(src)
	for {
		j := skip_ws_and_comments(src, i)
		if j >= n || !is_preamble_ident_start(src[j]) {
			return i
		}
		kw_start := j
		for j < n && is_preamble_ident_byte(src[j]) {
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
is_preamble_ident_start :: #force_inline proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

@(private = "file")
is_preamble_ident_byte :: #force_inline proc "contextless" (c: u8) -> bool {
	return is_preamble_ident_start(c) || (c >= '0' && c <= '9')
}

// Skips a `#` comment starting at `start` (`src[start] == '#'`), honoring jq `\\`, `\\\n`, `\\\r\n` continuations.
@(private = "file")
skip_jq_comment :: proc "contextless" (src: string, start: int) -> int #no_bounds_check {
	i := start + 1
	n := len(src)
	for i < n {
		c := src[i]
		if c == '\n' {
			return i + 1
		}
		if c == '\r' && i + 1 < n && src[i + 1] == '\n' {
			return i + 2
		}
		if c == '\\' && i + 1 < n {
			next := src[i + 1]
			if next == '\\' || next == '\n' {
				i += 2
				continue
			}
			if next == '\r' && i + 2 < n && src[i + 2] == '\n' {
				i += 3
				continue
			}
		}
		i += 1
	}
	return n
}

@(private = "file")
skip_ws_and_comments :: proc "contextless" (s: string, start: int) -> int #no_bounds_check {
	i := start
	n := len(s)
	for i < n {
		c := s[i]
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			i += 1
			continue
		}
		if c == '#' {
			i = skip_jq_comment(s, i)
			continue
		}
		break
	}
	return i
}

@(private = "file")
skip_stmt_to_semicolon :: proc "contextless" (s: string, start: int) -> int #no_bounds_check {
	i := start
	n := len(s)
	depth := 0
	in_str := false
	for i < n {
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
			if depth > 0 {
				depth -= 1
			}
		case ';':
			if depth == 0 {
				return i
			}
		}
		i += 1
	}
	return -1
}
