// `schema_csv CASES`: the CSV oracle's stury arm. CASES holds one JSON object a line: `schema` (the schema's text), `text`,
// `spec` ("csv" or "tsv"), `dups` ("last", "first" or "refuse"), `ragged` and `no_header`. Each case prints a line, `V` for a
// text the schema accepts and `I` and the rows that fail it, comma separated, for one it refuses. A failure that names no
// row, a refused header or a fault of the text, is `-`. A schema the check does not bind prints `U` and the keyword.
package schema_csv

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import core "../../core"
import typed "../../core/typed"
import schema "../../core/schema"
import dsv "../../dsv"
import json "../../json"

Case :: struct {
	schema, text, spec, dups: string,
	ragged, no_header:        bool,
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: schema_csv CASES")
		os.exit(2)
	}
	cases, err := os.read_entire_file(os.args[1], runtime.default_allocator())
	if err != nil {
		fmt.eprintln(os.args[1], err)
		os.exit(1)
	}
	rest := string(cases)
	for line in strings.split_lines_iterator(&rest) {
		if line == "" {
			continue
		}
		fmt.println(judge(line))
		free_all(context.temp_allocator)
	}
}

judge :: proc(line: string) -> string {
	c: Case
	if e := json.unmarshal(transmute([]u8)line, .Json, &c); e != nil {
		return fmt.tprint("E", e)
	}
	compiled, cerr := schema.compile(transmute([]u8)c.schema, json.as(.Json))
	defer schema.destroy(compiled)
	if cerr != nil {
		return fmt.tprint("E", cerr)
	}
	spec := dsv.Spec.Tsv if c.spec == "tsv" else .Csv
	reads := dsv.checks(.Tsv).reads if spec == .Tsv else dsv.checks(.Csv).reads
	opts := dsv.Options{no_header = c.no_header}
	if c.ragged {
		opts.tolerate = {.Ragged}
	}
	bound, berr := schema.bind(compiled, {reads, dsv.as(spec, opts)})
	defer schema.unbind(&bound)
	if berr != nil {
		return fmt.tprint("U", berr)
	}
	read := typed.Read_Options{}
	switch c.dups {
	case "first":  read.dups = .First
	case "refuse": read.dups = .Refuse
	case:          read.dups = .Last
	}
	sink: typed.Sink
	defer typed.sink_destroy(&sink)
	read.sink = &sink
	target: u8
	if typed.check_text(transmute([]u8)c.text, &target, nil, &bound.plan, read) == nil {
		return "V"
	}
	rows: [dynamic]int
	for e in sink.entries {
		if len(e.path) > 0 {
			if i, is_row := e.path[0].(core.Index); is_row {
				if !slice.contains(rows[:], int(i)) {
					append(&rows, int(i))
				}
				continue
			}
		}
		if !slice.contains(rows[:], -1) {
			append(&rows, -1)
		}
	}
	slice.sort(rows[:])
	out := strings.builder_make(context.temp_allocator)
	strings.write_string(&out, "I ")
	for r, i in rows {
		if i > 0 {
			strings.write_byte(&out, ',')
		}
		strings.write_string(&out, "-" if r < 0 else fmt.tprint(r))
	}
	if len(rows) == 0 {
		strings.write_byte(&out, '-')
	}
	return strings.to_string(out)
}
