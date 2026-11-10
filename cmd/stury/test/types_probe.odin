// types_law.py's typing of a filter for an input format that reads byte strings, which no format of the command line
// reads yet: `types_probe SCHEMA FILTER` writes the schema the filter's outputs pass, and each refusal on stderr.
package main

import "core:fmt"
import "core:os"
import core "../../../core"
import "../../../core/schema"
import json "../../../json"
import "../jq"

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: types_probe SCHEMA FILTER")
		os.exit(2)
	}
	text, read_err := os.read_entire_file(os.args[1], context.allocator)
	if read_err != nil {
		fmt.eprintln("types_probe: cannot read", os.args[1])
		os.exit(2)
	}
	doc, err := core.build(text, json.as(.Json))
	compiled: schema.Compiled
	if err == nil {
		compiled, err = schema.compile(&doc, core.ROOT, {})
	}
	parsed, errors := jq.parse(os.args[2])
	if err != nil || len(errors) > 0 {
		fmt.eprintln("types_probe: the schema or the filter does not compile")
		os.exit(2)
	}
	prog, check_errors, _ := jq.check(parsed.body, nil)
	if len(check_errors) > 0 {
		fmt.eprintln("types_probe: the filter does not compile")
		os.exit(2)
	}
	typing := jq.type_filter(prog, compiled.description, {bytes = true})
	for e in typing.refusals {
		fmt.eprintln(jq.locate(os.args[2], e))
	}
	out, werr := schema.write(&typing.d, json.as(.Json), {})
	if werr != nil {
		fmt.eprintln("types_probe: the output schema cannot be written")
		os.exit(2)
	}
	fmt.println(string(out))
	os.exit(1 if len(typing.refusals) > 0 else 0)
}
