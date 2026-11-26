// Structured error reporting for SQL DDL lexing, parsing, and schema compilation.
// Zero `core:os`, zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package ddl

import "base:runtime"
import "core:strings"
import "stury:lib/schema/check"

// Why a DDL parse or compile operation failed.
Error_Kind :: enum u8 {
	None,
	Syntax,
	No_Table,
	Duplicate_Column,
	Bad_Check,
	Depth_Limit,
	Compile,
	No_Memory,
}

// Structured error with byte offset and 1-based line:col location.
// Call `error_destroy` when finished (safe on zero/non-owned errors).
Error :: struct {
	kind:        Error_Kind,
	offset:      u64,
	line:        u32,
	col:         u32,
	message:     string,
	table:       string,
	column:      string,
	compile_err: check.Compile_Error,
	owned:       bool,
	allocator:   runtime.Allocator,
}

// Frees any heap-allocated strings owned by `e` and resets `e` to zero.
error_destroy :: proc(e: ^Error) {
	if e == nil {
		return
	}
	if e.owned {
		a := e.allocator
		delete(e.message, a)
		delete(e.table, a)
		delete(e.column, a)
	}
	e^ = {}
}

@(private)
make_error :: proc(
	kind: Error_Kind,
	message: string,
	offset: u64 = 0,
	line: u32 = 0,
	col: u32 = 0,
	table := "",
	column := "",
	allocator := context.allocator,
) -> Error {
	if kind == .None {
		return {}
	}
	if allocator.procedure == nil || (table == "" && column == "" && kind == .No_Memory) {
		return {kind = kind, offset = offset, line = line, col = col, message = message}
	}
	msg, e1 := strings.clone(message, allocator)
	if e1 != nil {
		return {kind = .No_Memory, offset = offset, line = line, col = col, message = "out of memory"}
	}
	tbl: string
	if table != "" {
		t, e2 := strings.clone(table, allocator)
		if e2 != nil {
			delete(msg, allocator)
			return {kind = .No_Memory, offset = offset, line = line, col = col, message = "out of memory"}
		}
		tbl = t
	}
	cstr: string
	if column != "" {
		c, e3 := strings.clone(column, allocator)
		if e3 != nil {
			delete(msg, allocator)
			delete(tbl, allocator)
			return {kind = .No_Memory, offset = offset, line = line, col = col, message = "out of memory"}
		}
		cstr = c
	}
	return {
		kind      = kind,
		offset    = offset,
		line      = line,
		col       = col,
		message   = msg,
		table     = tbl,
		column    = cstr,
		owned     = true,
		allocator = allocator,
	}
}
