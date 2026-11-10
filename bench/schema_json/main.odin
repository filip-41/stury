// `schema_json CASES`: the oracle's stury arm for schemas over JSON. CASES holds one JSON object a line: `schema` (the
// schema's text) and `instances` (texts). Each case prints a line: `V` or `I` for each instance, space separated, or `E`
// and the error for a schema that does not read, and `U` and the error for one the check does not bind.
package schema_json

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import core "../../core"
import schema "../../core/schema"
import json "../../json"

Case :: struct {
	schema:    string,
	instances: []string,
}

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: schema_json CASES")
		os.exit(2)
	}
	cases, err := os.read_entire_file(os.args[1], runtime.default_allocator())
	if err != nil {
		fmt.eprintln(os.args[1], err)
		os.exit(1)
	}
	rest := string(cases)
	for line in strings.split_lines_iterator(&rest) {
		if line != "" {
			fmt.println(judge(line))
			free_all(context.temp_allocator)
		}
	}
}

judge :: proc(line: string) -> string {
	c: Case
	if e := json.unmarshal(transmute([]u8)line, .Json, &c); e != nil {
		return fmt.tprint("E", e)
	}
	doc, _ := json.build(transmute([]u8)c.schema, .Json)
	defer core.destroy(&doc)
	compiled, cerr := schema.compile(&doc, core.ROOT, {resolver = {as = json.as(.Json)}})
	defer schema.destroy(&compiled)
	if cerr != nil {
		return fmt.tprint("E", cerr)
	}
	bound, berr := schema.bind(&compiled, json.as(.Json))
	defer schema.unbind(&bound)
	if berr != nil {
		return fmt.tprint("U", berr)
	}
	out := strings.builder_make(context.temp_allocator)
	for text, i in c.instances {
		if i > 0 {
			strings.write_byte(&out, ' ')
		}
		strings.write_byte(&out, 'V' if schema.valid(&bound, transmute([]u8)text) else 'I')
	}
	return strings.to_string(out)
}
