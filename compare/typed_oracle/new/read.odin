package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import core "next:core"
import typed "next:core/typed"
import dsv "next:dsv"
import json "next:json"

SPEC :: #config(SPEC, 0)
BORROW :: #config(BORROW, true)

Raw_T :: typed.Raw
Digits_T :: typed.Number_Text
Decoded_T :: typed.Scalar

hex_read :: proc(v: typed.Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind) {
	if len(v.decoded) == 0 {
		return .Out_Of_Range
	}
	// JSON5's text differs by arm: the old one writes the value out again as JSON.
	(^Hex)(dest).n = i64(len(v.text)) * 1000 + i64(v.text[0]) if SPEC == 0 else 1
	return nil
}

arm_canon :: proc(b: ^strings.Builder, v: any) -> bool {
	// The old read writes a JSON5 value out again as JSON, and next keeps its span.
	if _, is_raw := v.(Raw_T); is_raw && SPEC == 2 {
		return true
	}
	return false
}

read_options :: proc() -> (r: typed.Read_Options) {
	r.borrow_strings = BORROW
	switch os.get_env("ORACLE_DUPS", context.temp_allocator) {
	case "first": r.dups = core.Duplicates.First
	case "refuse": r.refuse_duplicates = true
	}
	r.unknown = .Refuse if os.get_env("ORACLE_UNKNOWN", context.temp_allocator) != "" else .Ignore
	return
}

rd :: proc(src: []u8, d: ^$T, a: runtime.Allocator) -> bool {
	@(static) plan: typed.Plan
	@(static) made: bool
	@(static) read: typed.Read_Options
	if !made {
		opts: typed.Plan_Options
		when T == Holder {
			opts = {union_tag = "type", tag_names = {{Tag_B, "b"}}}
		}
		when T == Hooked {
			opts = {hooks = {{type = Hex, read = hex_read}}}
		}
		err: core.Typed_Error
		plan, err = json.plan_make(T, opts)
		if err.kind != .None {
			fmt.println("PLAN", err.kind)
			os.exit(2)
		}
		read = read_options()
		made = true
	}
	err := json.unmarshal(src, json.Spec(SPEC), d, &plan, read, {}, a)
	if err.kind != .None && len(os.args) > 4 {
		fmt.eprintln(err.kind, err.at)
	}
	return err.kind == .None
}

rd_cells :: proc(src: []u8, d: ^$T, a: runtime.Allocator) -> bool {
	env :: proc(name: string) -> string {
		return os.get_env(name, context.temp_allocator)
	}
	@(static) plan: typed.Plan
	@(static) made: bool
	@(static) read: typed.Read_Options
	@(static) opts: dsv.Options
	if !made {
		po := typed.Plan_Options{hooks = {{type = Hex, read = hex_read}}}
		if env("ORACLE_ENUMS") != "" {
			po.enums = .Int
		}
		err: core.Typed_Error
		plan, err = dsv.plan_make(T, .Csv, opts = po)
		if err.kind != .None {
			fmt.println("PLAN", err.kind)
			os.exit(2)
		}
		read = read_options()
		opts.comment = '#' if env("ORACLE_COMMENT") != "" else 0
		if env("ORACLE_RAGGED") != "" {
			opts.tolerate = {.Ragged}
		}
		opts.no_header = env("ORACLE_NO_HEADER") != ""
		made = true
	}
	e: core.Typed_Error
	switch env("ORACLE_SPEC") {
	case "tsv": e = dsv.unmarshal(src, .Tsv, d, &plan, read, opts, a)
	case "plain": e = dsv.unmarshal(src, .Plain, d, &plan, read, opts, a)
	case: e = dsv.unmarshal(src, .Csv, d, &plan, read, opts, a)
	}
	if e.kind != .None {
		b := strings.builder_make(context.temp_allocator)
		width := e.kind == .Walk && e.inner.kind == .Bad_Char && e.inner.detail == u8(dsv.Detail.Field_Count)
		fmt.sbprintf(&b, "R %v %d ", "Width" if width else fmt.tprint(e.kind), e.at)
		for step in e.steps[:e.n_steps] {
			#partial switch v in step {
			case core.Name: fmt.sbprintf(&b, ".%s", string(v))
			case core.Index: fmt.sbprintf(&b, "[%d]", i64(v))
			case: fmt.sbprint(&b, "[*]")
			}
		}
		why_refused = strings.clone(strings.to_string(b), context.temp_allocator)
	}
	return e.kind == .None
}
