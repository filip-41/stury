package jq

// The regular-expression builtins (`test`, `match`, `capture`, `split/2`, `sub`, `gsub`). Compiling a pattern and
// finding its matches is regex.odin's.

@(private = "file")
regex_input :: proc(ip: ^Interp, v: Value) -> (string, Signal) {
	s, ok := string_of(v)
	if !ok {
		return "", fail(ip, "%s (%s) cannot be matched, as it is not a string", type_name(v), brief(v))
	}
	return s, .Go
}

// The regex `re` with `flags` and its matches in `s`: every one or the first as `global` says, else as the
// flags say.
@(private = "file")
regex_run :: proc(ip: ^Interp, re, flags: Value, s: string, global: Maybe(bool)) -> (r: Regex, ms: []Match, sig: Signal) {
	pattern, ok := string_of(re)
	if !ok {
		return {}, nil, fail(ip, "%s (%s) is not a string", type_name(re), brief(re))
	}
	if r, sig = compile_regex(ip, pattern, flags); sig != .Go {
		return
	}
	if g, set := global.?; set {
		r.global = g
	}
	ms, sig = matches(ip, &r, s)
	return
}

// The regex of `args`, the string it runs on and its matches there (regex_run), failing where jq does
// first: a 1-argument call's wrapper on its argument's type (`re` or `[re]` or `[re, flags]`), then
// `_match_impl` on the input, then on the regex.
@(private = "file")
regex_on :: proc(ip: ^Interp, v: Value, args: []Value, global: Maybe(bool) = nil) -> (r: Regex, s: string, ms: []Match, sig: Signal) {
	re, flags := args[0], args[1] if len(args) > 1 else nil
	if len(args) == 1 {
		switch kind(re) {
		case .String:
		case .Array:
			n := length_of(re)
			if n == 0 {
				return {}, "", nil, fail(ip, "array not a string or array")
			}
			re, flags = array_at(re, 0), array_at(re, 1) if n > 1 else nil
		case .Null, .False, .True, .Number, .Object:
			return {}, "", nil, fail(ip, "%s not a string or array", type_name(re))
		}
	}
	if s, sig = regex_input(ip, v); sig != .Go {
		return
	}
	r, ms, sig = regex_run(ip, re, flags, s, global)
	return
}

fn_test :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	_, _, ms, sig := regex_on(ip, v, args, false)
	return len(ms) > 0, sig
}

gen_match :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink) -> Signal {
	return each_match(ip, input, args, track, out, false)
}

gen_capture :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink) -> Signal {
	return each_match(ip, input, args, track, out, true)
}

// Every match as `match` gives it, or under `capture` as its named groups.
@(private = "file")
each_match :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink, capture: bool) -> Signal {
	r, s, ms, sig := regex_on(ip, input.v, args)
	if sig != .Go {
		return sig
	}
	if track {
		return match_path_error(ip, &r, s, ms)
	}
	walk: Char_Walk
	for m in ms {
		v: Value = capture_object(&r, s, m) if capture else match_object(&r, s, m, &walk)
		if sig = emit_made(out, input, v, track); sig != .Go {
			return sig
		}
	}
	return .Go
}

// jq's `match` is `_match_impl(...) | .[]`: under `path(...)` that `.[]` meets an array no path leads to.
@(private = "file")
match_path_error :: proc(ip: ^Interp, r: ^Regex, s: string, ms: []Match) -> Signal {
	a := new_array(len(ms))
	walk: Char_Walk
	for m in ms {
		append(&a.items, match_object(r, s, m, &walk))
	}
	return fail(ip, "Invalid path expression near attempt to iterate through %s", brief(a))
}

// `split/2` as jq defines it, cutting at its matches' character offsets. jq's `match($re; flags + "g")`
// adds the flags first, so a non-string fails as that addition before the input is validated.
fn_split_regex :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	flags, sig := add(ip, args[1], "g")
	if sig != .Go {
		return nil, sig
	}
	_, s, ms, rsig := regex_on(ip, v, {args[0], flags})
	if sig = rsig; sig != .Go {
		return nil, sig
	}
	a := new_array()
	cuts := Cuts{bytes = on_boundaries(s, ms)}
	for m in ms {
		append(&a.items, cut_before(&cuts, s, m))
	}
	append(&a.items, cut_rest(&cuts, s))
	return a, .Go
}

// `sub` and `gsub` as jq defines them: the replacement's k-th output on each match's captures goes into the k-th
// result, so the results run in lockstep and one past a match's outputs misses that match's text, with no result, the
// input.
native_sub :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	// jq binds `$re` and `$flags` before it reads the input.
	res, sig := collect(ip, n.args[0], input, env)
	if sig != .Go {
		return sig
	}
	flags := []Value{nil}
	if len(n.args) > 2 {
		if flags, sig = collect(ip, n.args[2], input, env); sig != .Go {
			return sig
		}
	}
	s: string
	if s, sig = regex_input(ip, input.v); sig != .Go {
		return sig
	}
	for re in res {
		for fl in flags {
			r, ms, rsig := regex_run(ip, re, fl, s, true if n.name == "gsub" else nil)
			if rsig != .Go {
				return rsig
			}
			if track {
				return match_path_error(ip, &r, s, ms)
			}
			results := make([dynamic]Value)
			owned: Owned // each result grows in place, as no other value holds it
			cuts := Cuts{bytes = on_boundaries(s, ms)}
			for m in ms {
				gap := cut_before(&cuts, s, m)
				inserts: []Value
				if inserts, sig = collect(ip, n.args[1], {v = capture_object(&r, s, m)}, env); sig != .Go {
					return sig
				}
				for ins, k in inserts {
					piece: Value
					if piece, sig = binary_op(ip, .Add, gap, ins); sig != .Go {
						return sig
					}
					if k == len(results) {
						append(&results, nil)
					}
					if results[k], sig = add(ip, results[k], piece, &owned); sig != .Go {
						return sig
					}
				}
			}
			tail := cut_rest(&cuts, s)
			if len(results) == 0 {
				append(&results, "")
				tail = s
			}
			for v in results {
				whole: Value
				if whole, sig = binary_op(ip, .Add, v, tail); sig != .Go {
					return sig
				}
				if sig = emit_made(out, input, whole, track); sig != .Go {
					return sig
				}
			}
		}
	}
	return .Go
}
