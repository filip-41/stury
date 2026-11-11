package json_tests

import "core:strings"
import "core:testing"
import core "../../core"
import schema "../../core/schema"
import json ".."

// `schema.write_odin`: the types written for a description, and the keyword a refusal names.

// The source `write_odin` writes for `text` in package `p`, or its error.
@(private = "file")
odin_of :: proc(t: ^testing.T, text: string, p := "p") -> (source: string, err: core.Error) {
	doc, berr := core.build(transmute([]u8)text, json.as(.Json))
	if !testing.expectf(t, berr == nil, "%s: %v", text, berr) {
		return "", berr
	}
	defer core.destroy(&doc)
	c, cerr := schema.compile(&doc, core.ROOT, {resolver = {as = json.as(.Json)}})
	if !testing.expectf(t, cerr == nil, "%s: %v", text, cerr) {
		return "", cerr
	}
	defer schema.destroy(&c)
	return schema.write_odin(c.description, p, context.temp_allocator)
}

// The keyword `write_odin`'s refusal of `text` names, and the path it stands at.
@(private = "file")
refused_keyword :: proc(t: ^testing.T, text: string) -> (keyword: string, steps: []core.Step) {
	_, err := odin_of(t, text)
	e, typed := err.(core.Typed_Error)
	if !testing.expectf(t, typed && e.kind == .Unsupported, "%s: %v", text, err) {
		return "", nil
	}
	return e.want.text, e.steps
}

@(test)
odin_struct_members :: proc(t: ^testing.T) {
	source, err := odin_of(t, `{"title": "Person", "type": "object", "required": ["full name"], "additionalProperties": false,
		"properties": {"full name": {"type": "string", "minLength": 1}, "age": {"type": "integer", "minimum": 0, "maximum": 150},
		"tags": {"type": "array", "items": {"type": "string", "maxLength": 8}}, "boss": {"$ref": "#"},
		"born": {"type": "string", "format": "date-time"}, "note": {"type": ["string", "null"]}}}`, "people")
	testing.expectf(t, err == nil, "%v", err)
	for want in ([]string{
		"package people\n",
		"import \"core:time\"\n",
		"Person :: struct {\n",
		"\tfull_name: string `json:\"full name\" model:\"len>=1\"`,\n",
		"\tage: i64 `model:\"optional,>=0,<=150\"`,\n",
		"\ttags: []Person_Tags_Item `model:\"optional\"`,\n",
		"\tboss: ^Person `model:\"optional\"`,\n",
		"\tborn: time.Time `model:\"optional\"`,\n",
		"\tnote: Maybe(string) `model:\"optional\"`,\n",
		"Person_Tags_Item :: distinct string\n",
		"\tmodel.register_type(reg, {Person_Tags_Item, \"len<=8\"}) or_return\n",
		"\tmodel.register_extra(reg, Person, .Forbid) or_return\n",
	}) {
		testing.expectf(t, strings.contains(source, want), "no %q in\n%s", want, source)
	}
}

@(test)
odin_enums_unions_and_defs :: proc(t: ^testing.T) {
	source, err := odin_of(t, `{"type": "object", "properties": {"kind": {"enum": ["read-only", "admin", ""]}, "level": {"enum": [1, -2]},
		"id": {"anyOf": [{"type": "string", "format": "uuid"}, {"type": "integer"}]}, "at": {"$ref": "#/$defs/Point"}},
		"$defs": {"Point": {"type": "object", "properties": {"x": {"type": "number"}}}}}`)
	testing.expectf(t, err == nil, "%v", err)
	for want in ([]string{
		"Root :: struct {\n",
		"Root_Kind :: enum {\n\tRead_Only,\n\tAdmin,\n\tEmpty,\n}\n",
		"Root_Level :: enum i64 {\n\tV1 = 1,\n\tVM2 = -2,\n}\n",
		"Root_Id :: union #no_nil {uuid.Identifier, i64}\n",
		"Point :: struct {\n\tx: f64 `model:\"optional\"`,\n}\n",
		"\tat: Point `model:\"optional\"`,\n",
		"[]model.Enum_Rename{{\"Read_Only\", \"read-only\"}, {\"Admin\", \"admin\"}, {\"Empty\", \"\"}}",
		"model.register_enum(reg, {Root_Level, true, nil})",
	}) {
		testing.expectf(t, strings.contains(source, want), "no %q in\n%s", want, source)
	}
}

@(test)
odin_names_are_unique_identifiers :: proc(t: ^testing.T) {
	source, err := odin_of(t, `{"type": "object", "properties": {"a-b": {"type": "string"}, "a_b": {"type": "string"},
		"proc": {"type": "string"}, "1st": {"type": "string"}, "": {"type": "string"}}}`)
	testing.expectf(t, err == nil, "%v", err)
	for want in ([]string{
		"\ta_b: string `json:\"a-b\" model:\"optional\"`,\n",
		"\ta_b_2: string `json:\"a_b\" model:\"optional\"`,\n",
		"\tproc_: string `json:\"proc\" model:\"optional\"`,\n",
		"\t_1st: string `json:\"1st\" model:\"optional\"`,\n",
		"\tmember: string `json:\"\" model:\"optional\"`,\n",
	}) {
		testing.expectf(t, strings.contains(source, want), "no %q in\n%s", want, source)
	}
}

@(test)
odin_refusals_name_the_keyword :: proc(t: ^testing.T) {
	Case :: struct {
		text, keyword: string,
		steps:         int,
	}
	for c in ([]Case{
		{`{"allOf": [{"type": "integer"}]}`, "allOf", 0},
		{`{"type": "object", "properties": {"a": {"type": "array", "items": {"if": {"type": "string"}}}}}`, "if", 2},
		{`{"oneOf": [{"type": "integer"}, {"minimum": 2}]}`, "oneOf", 0},
		{`{"type": "array", "uniqueItems": true}`, "uniqueItems", 0},
		{`{"type": "object", "patternProperties": {"^x": {}}}`, "patternProperties", 0},
		{`{"type": "null"}`, "type", 0},
		{`{"enum": [1, "a"]}`, "enum", 0},
		{`{"$defs": {"t": {"type": "array", "items": {"$ref": "#/$defs/t"}}}, "$ref": "#/$defs/t"}`, "$ref", 1},
	}) {
		keyword, steps := refused_keyword(t, c.text)
		testing.expectf(t, keyword == c.keyword && len(steps) == c.steps, "%s: refused %q at %d steps, not %q at %d", c.text, keyword, len(steps), c.keyword, c.steps)
	}
}

@(test)
odin_package_name :: proc(t: ^testing.T) {
	for p in ([]string{"", "9lives", "Pkg", "a-b", "proc"}) {
		_, err := odin_of(t, `{"type": "string"}`, p)
		e, typed := err.(core.Typed_Error)
		testing.expectf(t, typed && e.kind == .Bad_Option, "%q: %v", p, err)
	}
	source, err := odin_of(t, `{"type": "string"}`, "my_types")
	testing.expectf(t, err == nil, "%v", err)
	testing.expectf(t, strings.contains(source, "package my_types\n") && strings.contains(source, "Root :: string\n"), "%s", source)
}
