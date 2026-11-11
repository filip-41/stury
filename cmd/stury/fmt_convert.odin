package main

// `stury fmt --schema S` judges each file against S as `check --schema` does, then formats a file that passes as plain
// fmt does. An output of cells is judged again as it reads back, since a cell holds less than a JSON value.

import "base:runtime"
import "core:strings"
import core "../../core"
import "../../core/typed"
import "../../core/schema"
import dsv "../../dsv"
import "jq"
import "message"

// fmt --schema's schema, bound to the inputs' format and, for an output of cells, to the cells as they read back.
Conversion :: struct {
	check:   ^Schema_Check,
	options: Schema_Options,
	cells:   schema.Bound,
	cells_as: core.As,
	// The open file is one table, as a delimited text or a JSON text whose root is an array of rows, so its output of
	// cells is judged as the one table it is, else row by row.
	table:   bool,
}

conversion_open :: proc(run: ^Run, options: Schema_Options, src: Source) -> ^Conversion {
	o := &run.opts
	c := new(Conversion, runtime.heap_allocator())
	c.check, c.options = schema_open(options, src), options
	if !writes_cells(o) {
		return c
	}
	// A JSON value keeps its kind in a cell only when the table reads back with --infer, which quotes a string that
	// spells a number or a boolean.
	o.cells_out.infer ||= !reads_cells(o)
	c.cells_as = cells_written_as(o)
	err: core.Error
	if c.cells, err = schema.bind(c.check.compiled, {dsv.checks_for(c.cells_as), c.cells_as}); err != nil {
		usage_error("--schema %s: %s", options.file, edit_error_text(c.check.text, err))
	}
	return c
}

// Judges the open file against the schema and tells its failures. A fault is left for fmt to tell.
conversion_judge :: proc(run: ^Run, ins: ^Inputs) -> Verdict {
	runner: ^core.Runner
	if len(ins.data) >= POOLED_BYTES {
		runner = run_pool(run)
	}
	verdict, _ := schema_judge(run.convert.check, run.convert.options, ins.name, ins.data, ins.source, runner)
	return verdict
}

// Whether `text`, the open file written as cells, passes the schema as it reads back: as one table, or each row as a
// record. Its failures are told against `NAME (output)`.
conversion_cells_pass :: proc(c: ^Conversion, ins: ^Inputs, text: []u8) -> bool {
	sink := typed.Sink {
		max_errors = c.options.max_errors if c.options.max_errors != 0 else 100,
		entries    = make([dynamic]core.Error_Entry, runtime.heap_allocator()),
	}
	defer typed.sink_destroy(&sink)
	err: core.Error
	if c.table {
		err = schema.check(&c.cells, text, &sink)
	} else if doc, fault := jq.build_text(text, c.cells_as, context.temp_allocator); fault == nil {
		it := core.value_children(core.Node_Ref{&doc, core.ROOT})
		for row in core.value_child_next(&it) {
			if failed := schema.check_node(&c.cells, &doc, row.(core.Node_Ref).node, &sink); err == nil {
				err = failed
			}
		}
	} else {
		err = fault.?
	}
	if err == nil {
		return true
	}
	name := strings.concatenate({ins.name, " (output)"}, context.temp_allocator)
	told(name, text, sink.entries[:])
	if len(sink.entries) == 0 {
		message.write_stderr("stury: error: %s: %s\n", name, edit_error_text(text, err))
	}
	return false
}
