package jq

import "core:strconv"
import "stury:lib/query"

// jq's messages for the engine's errors.

// The value `try ... catch` gives for the error in the heap, which it takes: a raised value itself, else jq's message.
@(private)
error_value :: proc(m: ^Machine) -> (res: query.Value, status: query.Status) {
	h := m.h
	e := query.take_error(h)
	if e.kind == .Raised {
		v := e.a
		e.a = query.ABSENT
		query.destroy_error(h, &e)
		return v, .Ok
	}
	defer query.destroy_error(h, &e)
	out := make([dynamic]u8, h.allocator)
	defer delete(out)
	write_error(h, &out, &e)
	return query.text_value(h, string(out[:]))
}

// The message jq prints for error `e` when nothing catches it, without its `jq: error (at ...)` head.
error_message :: proc(h: ^query.Heap, e: ^query.Error, allocator := context.allocator) -> string {
	out := make([dynamic]u8, allocator)
	if e.kind == .Raised && !query.is_text(e.a) {
		if query.write_json(h, &out, e.a, {double = jq_double, too_deep = TOO_DEEP}) != .Ok {
			query.clear_error(h)
		}
		append(&out, " (not a string)")
		return string(out[:])
	}
	write_error(h, &out, e)
	return string(out[:])
}

@(private)
append_all_str :: proc(out: ^[dynamic]u8, parts: ..string) {
	for p in parts {
		append(out, p)
	}
}

// Appends jq's words for error `e` to `out`.
@(private)
write_error :: proc(h: ^query.Heap, out: ^[dynamic]u8, e: ^query.Error) {
	pair :: proc(h: ^query.Heap, out: ^[dynamic]u8, e: ^query.Error, verb: string) {
		typed(h, out, e.a)
		append(out, " and ")
		typed(h, out, e.b)
		append(out, verb)
	}
	switch e.kind {
	case .None:
		append(out, "unknown error")
	case .Raised:
		if query.is_text(e.a) {
			append(out, query.text_of(e.a))
		} else {
			write_brief(h, out, e.a)
			append(out, " (not a string)")
		}
	case .Zero_Divisor:
		pair(h, out, e, " cannot be divided (remainder) because the divisor is zero" if e.op == .Remainder else " cannot be divided because the divisor is zero")
	case .Types:
		#partial switch e.op {
		case .Add:
			pair(h, out, e, " cannot be added")
		case .Subtract:
			pair(h, out, e, " cannot be subtracted")
		case .Multiply:
			pair(h, out, e, " cannot be multiplied")
		case .Divide:
			pair(h, out, e, " cannot be divided")
		case .Remainder:
			pair(h, out, e, " cannot be divided (remainder)")
		case .Contains:
			pair(h, out, e, " cannot have their containment checked")
		case .Set:
			pair(h, out, e, " cannot be combined as sets")
		case .Negate, .Aggregate, .Keys, .Search:
			typed(h, out, e.a)
			#partial switch e.op {
			case .Negate:
				append(out, " cannot be negated")
			case .Aggregate:
				append(out, " cannot be summarized")
			case .Keys:
				append(out, " has no keys")
			case .Search:
				append(out, " cannot be searched from")
			}
		case .Index:
			if e.detail == "object key" {
				append(out, "Object keys must be strings")
				return
			}
			append_all_str(out, "Cannot index ", type_name(e.a), " with ")
			typed(h, out, e.b)
		case .Slice:
			append(out, "Array/string slice indices must be integers")
		case .Iterate:
			append(out, "Cannot iterate over ")
			typed(h, out, e.a)
		case .Reshape:
			append(out, "melt and pivot take an array of keys and two strings")
		case .Number_Format:
			append(out, "numfmt format must be a string")
		case .Get_Path, .Set_Path, .Delete_Paths:
			switch e.detail {
			case "":
				append(out, "Path must be specified as an array" if e.op != .Delete_Paths else "Paths must be specified as an array")
			case "path":
				append_all_str(out, "Path must be specified as array, not ", type_name(e.a))
			case "element of array":
				append_all_str(out, "Cannot delete ", type_name(e.b), " element of array")
			case "fields from":
				append_all_str(out, "Cannot delete fields from ", type_name(e.a))
			case "field of object":
				append_all_str(out, "Cannot delete ", type_name(e.b), " field of object")
			case:
				append(out, e.detail)
			}
		case:
			if e.detail != "" {
				append(out, e.detail)
			} else {
				typed(h, out, e.a)
				append(out, " is not valid here")
			}
		}
	case .Range, .Parse, .Pattern:
		if e.op == .Aggregate {
			append(out, "quantile ")
			write_brief(h, out, e.a)
			append(out, " must be a number from 0 to 1")
			return
		}
		if write_text_fault(h, out, e) {
			return
		}
		if e.kind == .Pattern && e.op == .Match {
			append(out, "Regex failure: ")
		}
		append(out, e.detail)
	case .Memory:
		append(out, "Out of memory")
	case .Budget:
		append(out, "Budget exceeded")
	case .Depth:
		#partial switch e.op {
		case .Get_Path, .Set_Path, .Delete_Paths:
			append(out, "Path too deep")
		case .Merge:
			append(out, "Object merge too deep")
		case .Equal:
			append(out, "Equality check too deep")
		case .Compare, .Sort, .Group:
			append(out, "Comparison too deep")
		case .Contains:
			append(out, "Containment check too deep")
		case:
			append(out, e.detail if e.detail != "" else "Exceeds depth limit for parsing")
		}
	}
}

@(private)
write_text_fault :: proc(h: ^query.Heap, out: ^[dynamic]u8, e: ^query.Error) -> bool {
	#partial switch e.op {
	case .Url, .Address:
		typed(h, out, e.a)
		append_all_str(out, " ", e.detail)
	case .Logfmt:
		line := query.text_of(e.a)
		at := int(query.as_f64(e.b))
		append(out, "logfmt: ")
		if e.detail == "unexpected" {
			numeral: [20]u8
			append_all_str(out, "unexpected ", line[at:at + 1], " at byte ", strconv.write_int(numeral[:], i64(at), 10))
			return true
		}
		end := at
		for end < len(line) && line[end] != '=' {
			end += 1
		}
		append_all_str(out, "unknown escape in the value of " if e.detail == "unknown escape" else "the quoted value of ", line[at:end])
		if e.detail == "unclosed" {
			append(out, " is not closed")
		}
	case .Pointer:
		if e.detail != "" {
			append(out, e.detail)
			return true
		}
		append(out, "json_pointer: ")
		write_brief(h, out, e.a)
		append(out, " is not a JSON Pointer")
	case .Number_Format:
		if e.kind == .Range {
			append(out, "numfmt requires a finite number")
		} else {
			append_all_str(out, `numfmt: invalid format "`, query.text_of(e.a), `"`)
		}
	case:
		return false
	}
	return true
}

@(private)
typed :: proc(h: ^query.Heap, out: ^[dynamic]u8, v: query.Value) {
	append_all_str(out, type_name(v), " (")
	write_brief(h, out, v)
	append(out, ")")
}

// jq's message for the time error `e` of builtin `name`.
@(private)
write_time_error :: proc(out: ^[dynamic]u8, name: string, e: ^query.Error) {
	arity1 := name == "strftime" || name == "strflocaltime" || name == "strptime"
	switch e.detail {
	case query.TIME_NUMBER:
		append_all_str(out, name, "() requires numeric inputs")
	case query.TIME_ARRAY:
		append(out, "mktime requires array inputs")
	case query.TIME_DATETIME:
		append_all_str(out, name, "/1 requires parsed datetime inputs" if arity1 else " requires parsed datetime inputs")
	case query.TIME_FORMAT:
		append_all_str(out, name, "/1 requires a string format")
	case query.TIME_STRINGS:
		if name == "strptime" {
			append(out, "strptime/1 requires string inputs and arguments")
		} else {
			append_all_str(out, name, " requires string inputs")
		}
	case query.TIME_RANGE:
		append(out, "error converting number of seconds since epoch to datetime")
	case query.TIME_REPRESENTATION:
		append(out, "invalid gmtime representation")
	case query.TIME_UNSUPPORTED:
		append(out, "mktime not supported on this platform")
	case query.TIME_MISMATCH:
		append_all_str(out, "date \"", query.text_of(e.a), "\" does not match format \"", query.text_of(e.b), "\"")
	case query.TIME_FAILURE:
		append_all_str(out, name, "/1: unknown system failure")
	case query.TIME_RFC3339:
		append_all_str(out, "date \"", query.text_of(e.a), "\" is not an RFC 3339 date-time")
	case query.TIME_YEARS:
		append(out, "torfc3339() input is outside the years 0000 to 9999")
	}
}
