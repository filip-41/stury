package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import core "stury:core"
import csv "stury:csv"
import json "stury:json"

SPEC :: #config(SPEC, 0)
BORROW :: #config(BORROW, true)

Raw_T :: json.Raw
Digits_T :: json.Digits
Decoded_T :: json.Decoded

hex_read :: proc(v: core.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Unmarshal_Error_Kind) {
	if len(v.decoded) == 0 {
		return .Out_Of_Range
	}
	// JSON5's text differs by arm: the old one writes the value out again as JSON.
	(^Hex)(dest).n = i64(len(v.text)) * 1000 + i64(v.text[0]) if SPEC == 0 else 1
	return nil
}

// The old `Decoded` holds a float as a `Number`, next's as an `f64`.
arm_canon :: proc(b: ^strings.Builder, v: any) -> bool {
	// The old read writes a JSON5 value out again as JSON, and next keeps its span.
	if _, is_raw := v.(Raw_T); is_raw && SPEC == 2 {
		return true
	}
	if n, ok := v.(core.Number); ok {
		fmt.sbprintf(b, "%x", transmute(u64)n.value)
		return true
	}
	return false
}

rd :: proc(src: []u8, d: ^$T, a: runtime.Allocator) -> bool {
	@(static) plan: json.Type_Plan
	@(static) made: bool
	@(static) opts: json.Unmarshal_Opts
	if !made {
		po: json.Plan_Opts
		when T == Holder {
			po = {union_tag = "type", tag_names = {{Tag_B, "b"}}}
		}
		when T == Hooked {
			po = {hooks = {{type = Hex, read = hex_read}}}
		}
		plan = json.type_plan_init(T, po)
		opts = {strictness = .Strict, borrow_strings = BORROW, dialect = json.Dialect(SPEC)}
		switch os.get_env("ORACLE_DUPS", context.temp_allocator) {
		case "first": opts.duplicates = .First
		case "refuse": opts.duplicates = .Refuse
		}
		if os.get_env("ORACLE_UNKNOWN", context.temp_allocator) != "" {
			opts.unknown_fields = .Refuse
		}
		made = true
	}
	err := json.unmarshal(src, d, opts, &plan, a)
	if err != nil && len(os.args) > 4 {
		fmt.eprintln(err)
	}
	return err == nil
}

rd_cells :: proc(src: []u8, d: ^$T, a: runtime.Allocator) -> bool {
	env :: proc(name: string) -> string {
		return os.get_env(name, context.temp_allocator)
	}
	@(static) plan: csv.Type_Plan
	@(static) made: bool
	@(static) opts: csv.Unmarshal_Opts
	if !made {
		po := csv.Plan_Opts{hooks = {{type = Hex, read = hex_read}}}
		if env("ORACLE_ENUMS") != "" {
			po.enums = .Int
		}
		plan = csv.type_plan_init(T, po)
		opts.borrow_strings = BORROW
		switch env("ORACLE_SPEC") {
		case "tsv": opts.dialect = csv.TSV
		case "plain": opts.dialect.quoting = .None
		}
		opts.dialect.comment = '#' if env("ORACLE_COMMENT") != "" else 0
		opts.dialect.ragged = env("ORACLE_RAGGED") != ""
		opts.no_header = env("ORACLE_NO_HEADER") != ""
		switch env("ORACLE_DUPS") {
		case "first": opts.duplicates = .First
		case "refuse": opts.duplicates = .Refuse
		}
		if env("ORACLE_UNKNOWN") != "" {
			opts.unknown_fields = .Refuse
		}
		made = true
	}
	e, refused := csv.unmarshal(src, d, opts, &plan, a).?
	if refused {
		b := strings.builder_make(context.temp_allocator)
		// The two trees spell a walk's fault by different kinds, and `Width` is a record of the wrong field count.
		width := e.kind == .Syntax && e.syntax == .Bad_Structure && e.detail == u8(csv.Fault.Field_Count)
		fmt.sbprintf(&b, "R %v %d ", "Width" if width else "Walk" if e.kind == .Syntax else fmt.tprint(e.kind), e.offset)
		for step in e.steps[:e.n_steps] {
			switch v in step {
			case core.Name: fmt.sbprintf(&b, ".%s", string(v))
			case core.Index: fmt.sbprintf(&b, "[%d]", i64(v))
			case core.Any: fmt.sbprint(&b, "[*]")
			}
		}
		why_refused = strings.clone(strings.to_string(b), context.temp_allocator)
	}
	return !refused
}
