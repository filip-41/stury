package json_tests

import "core:strings"
import "core:testing"
import core "../../core"
import schema "../../core/schema"
import json ".."

// `schema.write_odin`: the types written for a description, and the keyword a refusal names.

// The source `write_odin` writes for `text` in package `p`, or its error.
@(private = "file")
odin_of :: proc(t: ^testing.T, text: string, p := "p", format_assert := false) -> (source: string, err: core.Error) {
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
	return schema.write_odin(c.description, p, format_assert, context.temp_allocator)
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
		"Person :: struct {\n",
		"\tfull_name: string `json:\"full name\" model:\"len>=1\"`,\n",
		"\tage: i64 `model:\"optional,>=0,<=150\"`,\n",
		"\ttags: []Person_Tags_Item `model:\"optional\"`,\n",
		"\tboss: ^Person `model:\"optional,not_null\"`,\n",
		"\t// format: date-time\n\tborn: string `model:\"optional\"`,\n",
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
		"$defs": {"Point": {"type": "object", "properties": {"x": {"type": "number"}}}}}`, format_assert = true)
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
		"proc": {"type": "string"}, "1st": {"type": "string"}, "-": {"type": "string"}}}`)
	testing.expectf(t, err == nil, "%v", err)
	for want in ([]string{
		"\ta_b: string `json:\"a-b\" model:\"optional\"`,\n",
		"\ta_b_2: string `json:\"a_b\" model:\"optional\"`,\n",
		"\tproc_: string `json:\"proc\" model:\"optional\"`,\n",
		"\t_1st: string `json:\"1st\" model:\"optional\"`,\n",
		"\tmember: string `json:\"\\-\" model:\"optional\"`,\n",
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
		{`{"allOf": [{"type": "integer"}, {"type": "string"}]}`, "false", 0},
		{`{"type": "object", "properties": {"a": {"type": "array", "items": {"type": ["string", "null"], "if": {"minLength": 2}}}}}`, "if", 2},
		{`{"oneOf": [{"type": ["integer", "null"]}, {"type": "null"}]}`, "oneOf", 0},
		{`{"type": ["integer", "null"], "not": {"minimum": 3}}`, "not", 0},
		{`{"type": "object", "patternProperties": {"^x": {}}, "additionalProperties": {"type": "string"}}`, "patternProperties", 0},
		{`{"type": "array", "items": {"type": "null"}}`, "type", 1},
		{`{"enum": [9007199254740993]}`, "enum", 0},
		{`{"type": "array", "prefixItems": [{"type": "integer"}]}`, "prefixItems", 0},
		{`{"type": "object", "properties": {"": {}}}`, "properties", 0},
		{`{"type": "object", "required": ["z"], "additionalProperties": false}`, "required", 0},
		{`{"type": "object", "properties": {"a": {}}, "additionalProperties": {"type": "string"}, "allOf": [{"properties": {"b": {}}}]}`, "additionalProperties", 0},
		{`{"$defs": {"a": {"type": "object", "properties": {"x": {"type": ["number", "null"], "not": {"minimum": 1}}}}}, "type": "object", "properties": {"p": {"$ref": "#/$defs/a"}}}`, "not", 2},
		{`{"$defs": {"t": {"type": "array", "items": {"$ref": "#/$defs/t"}}}, "$ref": "#/$defs/t"}`, "$ref", 1},
	}) {
		keyword, steps := refused_keyword(t, c.text)
		testing.expectf(t, keyword == c.keyword && len(steps) == c.steps, "%s: refused %q at %d steps, not %q at %d", c.text, keyword, len(steps), c.keyword, c.steps)
	}
}

@(test)
odin_package_name :: proc(t: ^testing.T) {
	for p in ([]string{"", "_", "9lives", "a-b", "proc", "model", "time"}) {
		_, err := odin_of(t, `{"type": "string"}`, p)
		e, typed := err.(core.Typed_Error)
		testing.expectf(t, typed && e.kind == .Bad_Option, "%q: %v", p, err)
	}
	for p in ([]string{"my_types", "Pkg", "a__b"}) {
		source, err := odin_of(t, `{"type": "string"}`, p)
		testing.expectf(t, err == nil, "%q: %v", p, err)
		testing.expectf(t, strings.contains(source, strings.concatenate({"package ", p, "\n"}, context.temp_allocator)) && strings.contains(source, "Root :: string\n"), "%s", source)
	}
}

@(test)
odin_null_tuples_merges_and_other_members :: proc(t: ^testing.T) {
	source, err := odin_of(t, `{"type": "object", "properties": {"extra": {"type": "integer"}, "n": {"type": "null"},
		"pair": {"type": "array", "prefixItems": [{"type": "number"}, {"type": "number"}], "minItems": 2, "maxItems": 2},
		"e": {"enum": [1, "a", null]}, "when": {"type": "string", "format": "date-time"}}, "additionalProperties": {"type": "string"},
		"required": ["b"]}`)
	testing.expectf(t, err == nil, "%v", err)
	for want in ([]string{
		"\textra: i64 `model:\"optional\"`,\n",
		"\tn: Null `model:\"optional\"`,\n",
		"\tpair: [2]f64 `model:\"optional\"`,\n",
		"\te: Root_E `model:\"optional\"`,\n",
		"\tb: string,\n",
		"\textra_2: map[string]string `model:\"extra\"`,\n",
		"Null :: union {}\n",
		"Root_E :: union {Root_E_String, Root_E_Integer}\n",
	}) {
		testing.expectf(t, strings.contains(source, want), "no %q in\n%s", want, source)
	}
	source, err = odin_of(t, `{"type": "object", "properties": {"a": {"type": "integer"}}, "allOf": [{"properties": {"b": {"type": "boolean"}}, "required": ["b"]}]}`)
	testing.expectf(t, err == nil, "%v", err)
	testing.expectf(t, strings.contains(source, "\ta: i64 `model:\"optional\"`,\n\tb: bool,\n"), "%s", source)
	source, err = odin_of(t, `{"$defs": {"Root": {"type": "object", "properties": {"x": {"type": "integer"}}}}, "type": ["array", "null"],
		"items": {"$ref": "#/$defs/Root"}}`)
	testing.expectf(t, err == nil, "%v", err)
	testing.expectf(t, strings.contains(source, "Root_2 :: Maybe([]Root)\n") && strings.contains(source, "Root :: struct {\n"), "%s", source)
}

@(test)
odin_applicators_are_registered_on_a_named_type :: proc(t: ^testing.T) {
	source, err := odin_of(t, `{"type": "object", "properties": {"tags": {"type": "array", "items": {"type": "string"}, "uniqueItems": true,
		"contains": {"const": "a"}, "maxContains": 2}, "n": {"oneOf": [{"type": "integer"}, {"type": "number", "minimum": 2}]}},
		"patternProperties": {"^x-": {"type": "integer"}}, "propertyNames": {"maxLength": 4}, "dependentRequired": {"a": ["b"]},
		"if": {"required": ["a"]}, "then": {"required": ["c"]}}`)
	testing.expectf(t, err == nil, "%v", err)
	for want in ([]string{
		"Root :: struct {\n",
		"\ttags: Root_Tags `model:\"optional,unique\"`,\n",
		"Root_Tags :: distinct []string\n",
		"model.register_applies(reg, {Root_Tags, model.Contains{of = typeid_of(Root_Tags_Contains), max = 2}}) or_return",
		"model.register_union(reg, {Root_N, .One_Match, \"\"}) or_return",
		"model.register_applies(reg, {Root, model.Conditional{test = typeid_of(Root_If), then = typeid_of(Root_Then), other = nil}}) or_return",
		"model.register_applies(reg, {Root, model.Names{of = typeid_of(Root_Name)}}) or_return",
		"model.register_applies(reg, {Root, model.Pattern{\"^x-\", typeid_of(i64)}}) or_return",
		"model.register_applies(reg, {Root, model.Dependent{name = \"a\", requires = {\"b\"}}}) or_return",
	}) {
		testing.expectf(t, strings.contains(source, want), "no %q in\n%s", want, source)
	}
}
