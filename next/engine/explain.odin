package engine

import "base:runtime"
import "core:fmt"
import "core:strings"
import "stury:lib/query"

// Human-readable `--explain` formatting for `Decision` and its `query.Plan`.

@(private = "file", rodata)
FRAMING_NAMES := [Framing]string {
	.Single       = "single",
	.Lines        = "lines",
	.Seq          = "seq",
	.Elements     = "elements",
	.Members      = "members",
	.Concatenated = "concatenated",
}

@(private = "file", rodata)
ROUTE_NAMES := [Route_Kind]string {
	.Whole             = "whole",
	.Scan              = "scan",
	.Records_Serial    = "records_serial",
	.Records_Parallel  = "records_parallel",
	.Spine_Parallel    = "spine_parallel",
	.Projection_Direct = "projection_direct",
	.Conditional_Whole = "conditional_whole",
	.Files_Parallel    = "files_parallel",
}

@(private = "file", rodata)
HINT_NAMES := [Active_Hint]string {
	.None              = "none",
	.Spine_Split       = "spine_split",
	.Projection_Direct = "projection_direct",
	.Conditional_Whole = "conditional_whole",
}

@(private = "file", rodata)
WHY_TEXT := [Route_Why]string {
	.Edit_Needs_Layout     = "edit/fmt/in-place requires full document layout",
	.Format_No_Scan        = "input format does not support partial scan (built whole)",
	.All_Unbounded         = "all demand steps are unbounded wildcards (cheaper whole)",
	.Serial_Program        = "serial program property prevents parallel execution",
	.Eval_Ctx_Serial       = "unsynchronized evaluation context requires serial execution",
	.Dups_Need_Build       = "duplicate-key policy requires full container build",
	.Force_Whole           = "caller forced whole document build",
	.Facts_Need_Scan       = "output comments/facts keep facts along scanned paths",
	.Facts_Need_Whole      = "comments/facts requested on non-scannable format",
	.Slurp_Whole           = "slurp collects all inputs into a single array",
	.Raw_Lines             = "raw input reads each line as a string",
	.Demand_Whole          = "program demand requires the whole value",
	.Demand_None           = "program reads no fields from main input",
	.Where_Needs_Evaluator = "source provenance (--where) requires evaluator",
	.No_Runner             = "no multi-thread worker pool supplied",
	.Input_Too_Small       = "input below parallel size threshold",
	.Partial_Demand        = "partial demand scans only needed paths",
	.Projection_Direct_Hit = "Hint 2: direct projection emits leaf values without evaluator",
	.Conditional_Whole_Hit = "Hint 3: conditional whole scans predicate before building whole",
	.Spine_Split_Hit       = "Hint 1: per-element array split fans elements across worker pool",
	.Records_Framing       = "framed input iterates record by record",
	.Parallel_Worker_Pool  = "executes in parallel across worker pool",
	.Many_Files            = "multiple files dispatched across worker pool",
}

// Returns canonical string label for `Route_Kind`.
route_kind_name :: proc "contextless" (kind: Route_Kind) -> string {
	return ROUTE_NAMES[kind]
}

// Returns human-readable reason string for `Route_Why`.
route_why_text :: proc "contextless" (why: Route_Why) -> string {
	return WHY_TEXT[why]
}

// Formats a complete `--explain` report into `b` covering format, framing,
// contract demand/serial/hints (`query.format_plan`), chosen route, and reasons.
explain_to :: proc(b: ^strings.Builder, plan: ^query.Plan, decision: ^Decision) {
	if decision == nil {
		return
	}
	fmt.sbprintf(b, "format: %s (%s), framing: %s\n", decision.entry.title, decision.entry.name, FRAMING_NAMES[decision.framing])
	if plan != nil {
		query.format_plan(b, plan)
	}
	fmt.sbprintf(
		b,
		"route: %s (hint=%s, parallel=%s, facts=%s, origins=%s)\n",
		ROUTE_NAMES[decision.kind],
		HINT_NAMES[decision.active_hint],
		"yes" if decision.parallel else "no",
		"yes" if decision.keep_facts else "no",
		"yes" if decision.keep_origins else "no",
	)
	fmt.sbprintf(b, "why: %s\n", WHY_TEXT[decision.primary_why])
	for w in Route_Why {
		if w == decision.primary_why || w not_in decision.whys {
			continue
		}
		fmt.sbprintf(b, "because: %s\n", WHY_TEXT[w])
	}
}

// Renders `--explain` output as a newly allocated string owned by the caller.
@(require_results)
explain :: proc(plan: ^query.Plan, decision: ^Decision, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	explain_to(&b, plan, decision)
	return strings.to_string(b)
}

@(private = "file", rodata)
DEMAND_KIND_NAMES := [query.Demand_Mode]string {
	.None    = "none",
	.Partial = "partial",
	.Whole   = "whole",
}

// Canonical, deterministic machine-readable plan pin for `--plan-out` and `--plan-file`.
Plan_Pin :: struct {
	route:       string,
	framing:     string,
	parallel:    bool,
	hint:        string,
	demand_kind: string,
	format:      string,
}

// Returns canonical string label for `query.Demand_Mode`.
demand_mode_name :: proc "contextless" (mode: query.Demand_Mode) -> string {
	return DEMAND_KIND_NAMES[mode]
}

// Extracts the canonical `Plan_Pin` from `decision` (zero allocations; borrows static rodata strings).
@(require_results)
plan_pin_of :: proc "contextless" (decision: ^Decision) -> Plan_Pin {
	if decision == nil {
		return {}
	}
	return {
		route       = ROUTE_NAMES[decision.kind],
		framing     = FRAMING_NAMES[decision.framing],
		parallel    = decision.parallel,
		hint        = HINT_NAMES[decision.active_hint],
		demand_kind = DEMAND_KIND_NAMES[decision.demand_mode],
		format      = decision.entry.name,
	}
}

// Releases heap-owned string fields produced by `parse_plan_pin_json`.
destroy_plan_pin :: proc(pin: ^Plan_Pin, allocator := context.allocator) {
	if pin == nil {
		return
	}
	delete(pin.route, allocator)
	delete(pin.framing, allocator)
	delete(pin.hint, allocator)
	delete(pin.demand_kind, allocator)
	delete(pin.format, allocator)
	pin^ = {}
}

// Writes the canonical deterministic JSON representation of `pin` into `b` (WASM-clean, no `core:os`).
explain_pin_json_to :: proc(b: ^strings.Builder, decision: ^Decision) {
	pin := plan_pin_of(decision)
	strings.write_string(b, `{"route":`)
	write_pin_json_str(b, pin.route)
	strings.write_string(b, `,"framing":`)
	write_pin_json_str(b, pin.framing)
	strings.write_string(b, `,"parallel":`)
	strings.write_string(b, "true" if pin.parallel else "false")
	strings.write_string(b, `,"hint":`)
	write_pin_json_str(b, pin.hint)
	strings.write_string(b, `,"demand_kind":`)
	write_pin_json_str(b, pin.demand_kind)
	strings.write_string(b, `,"format":`)
	write_pin_json_str(b, pin.format)
	strings.write_string(b, "}\n")
}

// Renders the canonical deterministic JSON plan pin as a newly allocated string owned by the caller.
@(require_results)
explain_pin_json :: proc(decision: ^Decision, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	explain_pin_json_to(&b, decision)
	return strings.to_string(b)
}

// Parses a canonical plan pin JSON document produced by `explain_pin_json` (in any key order/whitespace).
// All 6 canonical fields (`route`, `framing`, `parallel`, `hint`, `demand_kind`, `format`) are required.
// Free the returned `Plan_Pin` with `destroy_plan_pin(pin, allocator)` when `ok` is true.
@(require_results)
parse_plan_pin_json :: proc(src: string, allocator := context.allocator) -> (pin: Plan_Pin, ok: bool) {
	p := Pin_Json_Parser{src = src}
	pin_skip_ws(&p)
	if !pin_take(&p, '{') {
		return {}, false
	}
	Field_Bit :: enum u8 {
		Route,
		Framing,
		Parallel,
		Hint,
		Demand_Kind,
		Format,
	}
	res: Plan_Pin
	seen: bit_set[Field_Bit; u8]
	ok_parse := false
	defer if !ok_parse {
		destroy_plan_pin(&res, allocator)
	}

	pin_skip_ws(&p)
	if pin_take(&p, '}') {
		return {}, false
	}
	for {
		key, kok := pin_read_string(&p, allocator)
		if !kok {
			return {}, false
		}
		defer delete(key, allocator)
		pin_skip_ws(&p)
		if !pin_take(&p, ':') {
			return {}, false
		}
		pin_skip_ws(&p)

		switch key {
		case "route":
			if .Route in seen {
				return {}, false
			}
			v, vok := pin_read_string(&p, allocator)
			if !vok {
				return {}, false
			}
			res.route = v
			seen += {.Route}
		case "framing":
			if .Framing in seen {
				return {}, false
			}
			v, vok := pin_read_string(&p, allocator)
			if !vok {
				return {}, false
			}
			res.framing = v
			seen += {.Framing}
		case "parallel":
			if .Parallel in seen {
				return {}, false
			}
			bval, bok := pin_read_bool(&p)
			if !bok {
				return {}, false
			}
			res.parallel = bval
			seen += {.Parallel}
		case "hint":
			if .Hint in seen {
				return {}, false
			}
			v, vok := pin_read_string(&p, allocator)
			if !vok {
				return {}, false
			}
			res.hint = v
			seen += {.Hint}
		case "demand_kind":
			if .Demand_Kind in seen {
				return {}, false
			}
			v, vok := pin_read_string(&p, allocator)
			if !vok {
				return {}, false
			}
			res.demand_kind = v
			seen += {.Demand_Kind}
		case "format":
			if .Format in seen {
				return {}, false
			}
			v, vok := pin_read_string(&p, allocator)
			if !vok {
				return {}, false
			}
			res.format = v
			seen += {.Format}
		case:
			return {}, false
		}

		pin_skip_ws(&p)
		if pin_take(&p, ',') {
			pin_skip_ws(&p)
			continue
		}
		if pin_take(&p, '}') {
			break
		}
		return {}, false
	}

	pin_skip_ws(&p)
	if p.pos != len(p.src) || seen != {.Route, .Framing, .Parallel, .Hint, .Demand_Kind, .Format} {
		return {}, false
	}
	ok_parse = true
	return res, true
}

// Compares `expected` against `actual`. Returns `true` when every pinned field matches; otherwise writes a
// concise human-readable diff (`expected route ..., got ...`) into `diff_out` (when non-nil) and returns `false`.
@(require_results)
compare_plan_pin :: proc(expected, actual: Plan_Pin, diff_out: ^strings.Builder = nil) -> bool {
	matched := true
	check_str :: proc(b: ^strings.Builder, matched: ^bool, field, exp, got: string) {
		if exp == got {
			return
		}
		if b != nil {
			if !matched^ {
				strings.write_string(b, "; ")
			}
			fmt.sbprintf(b, "expected %s %s, got %s", field, exp, got)
		}
		matched^ = false
	}
	check_bool :: proc(b: ^strings.Builder, matched: ^bool, field: string, exp, got: bool) {
		if exp == got {
			return
		}
		if b != nil {
			if !matched^ {
				strings.write_string(b, "; ")
			}
			fmt.sbprintf(b, "expected %s %s, got %s", field, "true" if exp else "false", "true" if got else "false")
		}
		matched^ = false
	}
	check_str(diff_out, &matched, "route", expected.route, actual.route)
	check_str(diff_out, &matched, "framing", expected.framing, actual.framing)
	check_bool(diff_out, &matched, "parallel", expected.parallel, actual.parallel)
	check_str(diff_out, &matched, "hint", expected.hint, actual.hint)
	check_str(diff_out, &matched, "demand_kind", expected.demand_kind, actual.demand_kind)
	check_str(diff_out, &matched, "format", expected.format, actual.format)
	return matched
}

@(private = "file")
write_pin_json_str :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", c)
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

@(private = "file")
Pin_Json_Parser :: struct {
	src: string,
	pos: int,
}

@(private = "file")
pin_skip_ws :: proc "contextless" (p: ^Pin_Json_Parser) {
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case ' ', '\t', '\r', '\n':
			p.pos += 1
		case:
			return
		}
	}
}

@(private = "file")
pin_take :: proc "contextless" (p: ^Pin_Json_Parser, ch: u8) -> bool {
	if p.pos < len(p.src) && p.src[p.pos] == ch {
		p.pos += 1
		return true
	}
	return false
}

@(private = "file")
pin_read_bool :: proc "contextless" (p: ^Pin_Json_Parser) -> (val: bool, ok: bool) {
	rest := p.src[p.pos:]
	if len(rest) >= 4 && rest[:4] == "true" {
		p.pos += 4
		return true, true
	}
	if len(rest) >= 5 && rest[:5] == "false" {
		p.pos += 5
		return false, true
	}
	return false, false
}

@(private = "file")
pin_read_hex4 :: proc "contextless" (p: ^Pin_Json_Parser) -> (val: u16, ok: bool) {
	if p.pos + 4 > len(p.src) {
		return 0, false
	}
	v: u16
	for k in 0 ..< 4 {
		c := p.src[p.pos + k]
		d: u16
		switch c {
		case '0' ..= '9':
			d = u16(c - '0')
		case 'a' ..= 'f':
			d = u16(c - 'a' + 10)
		case 'A' ..= 'F':
			d = u16(c - 'A' + 10)
		case:
			return 0, false
		}
		v = (v << 4) | d
	}
	p.pos += 4
	return v, true
}

@(private = "file")
pin_encode_rune :: proc "contextless" (r: rune) -> (enc: [4]u8, n: int) {
	u := u32(r)
	switch {
	case u < 0x80:
		enc[0] = u8(u)
		return enc, 1
	case u < 0x800:
		enc[0] = 0xC0 | u8(u >> 6)
		enc[1] = 0x80 | u8(u & 0x3F)
		return enc, 2
	case u < 0x10000:
		enc[0] = 0xE0 | u8(u >> 12)
		enc[1] = 0x80 | u8((u >> 6) & 0x3F)
		enc[2] = 0x80 | u8(u & 0x3F)
		return enc, 3
	case:
		enc[0] = 0xF0 | u8(u >> 18)
		enc[1] = 0x80 | u8((u >> 12) & 0x3F)
		enc[2] = 0x80 | u8((u >> 6) & 0x3F)
		enc[3] = 0x80 | u8(u & 0x3F)
		return enc, 4
	}
}

@(private = "file")
pin_read_string :: proc(p: ^Pin_Json_Parser, allocator: runtime.Allocator) -> (s: string, ok: bool) {
	if !pin_take(p, '"') {
		return "", false
	}
	buf, berr := make([dynamic]u8, 0, 32, allocator)
	if berr != nil {
		return "", false
	}
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		p.pos += 1
		if c == '"' {
			return string(buf[:]), true
		}
		if c < 0x20 {
			delete(buf)
			return "", false
		}
		if c != '\\' {
			if _, aerr := append(&buf, c); aerr != nil {
				delete(buf)
				return "", false
			}
			continue
		}
		if p.pos >= len(p.src) {
			delete(buf)
			return "", false
		}
		esc := p.src[p.pos]
		p.pos += 1
		werr: runtime.Allocator_Error
		switch esc {
		case '"', '\\', '/':
			_, werr = append(&buf, esc)
		case 'b':
			_, werr = append(&buf, '\b')
		case 'f':
			_, werr = append(&buf, '\f')
		case 'n':
			_, werr = append(&buf, '\n')
		case 'r':
			_, werr = append(&buf, '\r')
		case 't':
			_, werr = append(&buf, '\t')
		case 'u':
			hi, ok_hi := pin_read_hex4(p)
			if !ok_hi || (0xDC00 <= hi && hi <= 0xDFFF) {
				delete(buf)
				return "", false
			}
			r := rune(hi)
			if 0xD800 <= hi && hi <= 0xDBFF {
				if p.pos + 2 > len(p.src) || p.src[p.pos] != '\\' || p.src[p.pos + 1] != 'u' {
					delete(buf)
					return "", false
				}
				p.pos += 2
				lo, ok_lo := pin_read_hex4(p)
				if !ok_lo || lo < 0xDC00 || lo > 0xDFFF {
					delete(buf)
					return "", false
				}
				r = rune(0x10000 + ((u32(hi - 0xD800) << 10) | u32(lo - 0xDC00)))
			}
			enc, n := pin_encode_rune(r)
			_, werr = append(&buf, ..enc[:n])
		case:
			delete(buf)
			return "", false
		}
		if werr != nil {
			delete(buf)
			return "", false
		}
	}
	delete(buf)
	return "", false
}
