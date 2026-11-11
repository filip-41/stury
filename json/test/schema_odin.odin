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
	c, cerr := schema.compile(core.span(&doc, core.ROOT), json.as(.Json), {})
	if !testing.expectf(t, cerr == nil, "%s: %v", text, cerr) {
		return "", cerr
	}
	defer schema.destroy(c)
	return schema.write_odin(c.description, p, json.as(.Json), format_assert, context.temp_allocator)
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
		"\tage: Maybe(i64) `json:\",omitempty\" model:\"optional,not_null,>=0,<=150\"`,\n",
		"\ttags: Maybe([]Person_Tags_Item) `json:\",omitempty\" model:\"optional,not_null\"`,\n",
		"\tboss: ^Person `json:\",omitempty\" model:\"optional,not_null\"`,\n",
		"\t// format: date-time\n\tborn: Maybe(string) `json:\",omitempty\" model:\"optional,not_null\"`,\n",
		"\tnote: Maybe(string) `json:\",omitunset\" model:\"optional\"`,\n",
		"\tset: model.Fields_Set,\n",
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
		"Point :: struct {\n\tx: Maybe(core.Number_Text) `json:\",omitempty\" model:\"optional,not_null\"`,\n}\n",
		"\tat: Maybe(Point) `json:\",omitempty\" model:\"optional,not_null\"`,\n",
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
		"\ta_b: Maybe(string) `json:\"a-b,omitempty\" model:\"optional,not_null\"`,\n",
		"\ta_b_2: Maybe(string) `json:\"a_b,omitempty\" model:\"optional,not_null\"`,\n",
		"\tproc_: Maybe(string) `json:\"proc,omitempty\" model:\"optional,not_null\"`,\n",
		"\t_1st: Maybe(string) `json:\"1st,omitempty\" model:\"optional,not_null\"`,\n",
		"\tmember: Maybe(string) `json:\"\\-,omitempty\" model:\"optional,not_null\"`,\n",
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
		{`{"type": "object", "properties": {"a": {"type": "array", "items": {"anyOf": [{"type": "string"}, {"type": "null"}], "if": {"type": "null"}, "then": {"type": "string"}}}}}`, "if", 2},
		{`{"oneOf": [{"type": ["integer", "null"]}, {"type": "null"}]}`, "oneOf", 0},
		{`{"oneOf": [{"type": "integer"}, {"type": "integer"}, {"type": "string"}]}`, "oneOf", 0},
		{`{"oneOf": [{"type": "integer"}, {"type": "integer"}]}`, "oneOf", 0},
		{`{"oneOf": [{"type": "integer"}, {"type": "null"}], "not": {"const": null}}`, "not", 0},
		{`{"type": "object", "patternProperties": {"^x": {}}, "additionalProperties": {"type": "string"}}`, "patternProperties", 0},
		{`{"type": "array", "items": {"type": "null"}}`, "type", 1},
		{`{"enum": [9007199254740993]}`, "enum", 0},
		{`{"type": "array", "prefixItems": [{"type": "integer"}]}`, "prefixItems", 0},
		{`{"type": "object", "properties": {"": {}}}`, "properties", 1},
		{`{"type": "object", "required": ["z"], "additionalProperties": false}`, "required", 0},
		{`{"type": "object", "properties": {"a": {}}, "additionalProperties": {"type": "string"}, "allOf": [{"properties": {"b": {}}}]}`, "additionalProperties", 0},
		{`{"$defs": {"a": {"type": "object", "properties": {"x": {"anyOf": [{"type": "number"}, {"type": "null"}], "not": {"const": null}}}}}, "type": "object", "properties": {"p": {"$ref": "#/$defs/a"}}}`, "not", 2},
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
		"\textra: Maybe(i64) `json:\",omitempty\" model:\"optional,not_null\"`,\n",
		"\tn: Null `json:\",omitunset\" model:\"optional\"`,\n",
		"\tpair: Maybe([2]core.Number_Text) `json:\",omitempty\" model:\"optional,not_null\"`,\n",
		"\te: Root_E `json:\",omitunset\" model:\"optional\"`,\n",
		"\tb: string,\n",
		"\textra_2: map[string]string `json:\",unknown\"`,\n",
		"Null :: union {}\n",
		"Root_E :: union {Root_E_String, Root_E_Integer}\n",
	}) {
		testing.expectf(t, strings.contains(source, want), "no %q in\n%s", want, source)
	}
	source, err = odin_of(t, `{"type": "object", "properties": {"a": {"type": "integer"}}, "allOf": [{"properties": {"b": {"type": "boolean"}}, "required": ["b"]}]}`)
	testing.expectf(t, err == nil, "%v", err)
	testing.expectf(t, strings.contains(source, "\ta: Maybe(i64) `json:\",omitempty\" model:\"optional,not_null\"`,\n\tb: bool,\n"), "%s", source)
	source, err = odin_of(t, `{"$defs": {"Root": {"type": "object", "properties": {"x": {"type": "integer"}}}}, "type": ["array", "null"],
		"items": {"$ref": "#/$defs/Root"}}`)
	testing.expectf(t, err == nil, "%v", err)
	testing.expectf(t, strings.contains(source, "Root_2 :: Maybe([]Root)\n") && strings.contains(source, "Root :: struct {\n"), "%s", source)
}

@(test)
odin_applicators_are_registered_as_fragments_on_a_named_type :: proc(t: ^testing.T) {
	source, err := odin_of(t, `{"type": "object", "properties": {"tags": {"type": "array", "items": {"type": "string"}, "uniqueItems": true,
		"contains": {"const": "a"}, "maxContains": 2}, "n": {"oneOf": [{"type": "integer"}, {"type": "number", "minimum": 2}]}},
		"patternProperties": {"^x-": {"type": "integer"}}, "propertyNames": {"maxLength": 4}, "dependentRequired": {"a": ["b"]},
		"if": {"required": ["a"]}, "then": {"required": ["c"]}}`)
	testing.expectf(t, err == nil, "%v", err)
	for want in ([]string{
		"Root :: struct {\n",
		"\ttags: Maybe(Root_Tags) `json:\",omitempty\" model:\"optional,not_null,unique\"`,\n",
		"\textra: map[string]core.Value `json:\",unknown\"`,\n",
		"Root_Tags :: distinct []string\n",
		"register :: proc(reg: ^model.Registry) -> core.Error {\n",
		"\tregister_fragment(reg, Root_Tags, `{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"contains\":{\"const\":\"a\"},\"maxContains\":2}`) or_return\n",
		"model.register_union(reg, {Root_N, .One_Match, \"\"}) or_return",
		`"if":{"required":["a"]},"then":{"required":["c"]},"patternProperties":{"^x-":{"type":"integer"}},"propertyNames":{"maxLength":4},"dependentRequired":{"a":["b"]}`,
		"register_fragment :: proc(reg: ^model.Registry, T: typeid, text: string) -> core.Error {\n",
		"\tmodel.register_schema(reg, T, s.description) or_return\n",
	}) {
		testing.expectf(t, strings.contains(source, want), "no %q in\n%s", want, source)
	}
}

@(test)
odin_spells_a_judged_value_as_it_reads :: proc(t: ^testing.T) {
	Case :: struct {
		text:  string,
		wants: []string,
	}
	for c in ([]Case{
		{`{"type": "array", "uniqueItems": true, "items": {"type": "object", "properties": {"a": {"type": "integer"}}}}`,
			{"\ta: Maybe(i64) `json:\",omitempty\" model:\"optional,not_null\"`,\n", "\textra: map[string]core.Value `json:\",unknown\"`,\n"}},
		{`{"type": "object", "properties": {"a": {"type": "integer"}}, "patternProperties": {"^a": {"minimum": 5}}}`,
			{"\ta: Maybe(i64) `json:\",omitempty\" model:\"optional,not_null\"`,\n", `"patternProperties":{"^a":{"minimum":5}}`}},
		{`{"type": ["integer", "null"], "not": {"const": 3}}`, {"Root :: Maybe(Root_Value)\n", "Root_Value :: distinct i64\n", `register_fragment(reg, Root_Value, `}},
		{`{"type": ["integer", "null"], "not": {"enum": [3, null]}}`, {"Root :: distinct i64\n"}},
		{`{"type": "object", "properties": {"a.b": {"type": "string"}}, "patternProperties": {"^x-": {"type": "integer"}}, "additionalProperties": false}`,
			{"\textra: map[string]i64 `json:\",unknown\"`,\n", `"propertyNames":{"type":"string","pattern":"^(?:a\\.b)$|(?:^x-)"}`}},
		{`{"anyOf": [{"type": "integer"}, {"type": "integer"}]}`, {"Root :: i64\n"}},
	}) {
		source, err := odin_of(t, c.text)
		testing.expectf(t, err == nil, "%s: %v", c.text, err)
		for want in c.wants {
			testing.expectf(t, strings.contains(source, want), "no %q in\n%s", want, source)
		}
	}
}

// A pattern with a double quote cannot stand in a struct tag, and one with a comma may hold text a tag reads as another
// item, so `register` holds it as the member's rule.
@(test)
odin_pattern_with_a_quote_or_a_comma_is_registered :: proc(t: ^testing.T) {
	source, err := odin_of(t, `{"type": "object", "required": ["q"], "properties": {"q": {"type": "string", "pattern": "^\"a\"$"}}}`)
	testing.expectf(t, err == nil, "%v", err)
	want := "\tmodel.register_field(reg, {Root, \"q\", \"pattern=^\\\"a\\\"$\"}) or_return\n"
	testing.expectf(t, strings.contains(source, want), "no %q in\n%s", want, source)
	source, err = odin_of(t, `{"type": "object", "required": ["q"], "properties": {"q": {"type": "string", "maxLength": 3, "pattern": "^a+$,len<=3"}}}`)
	testing.expectf(t, err == nil, "%v", err)
	want = "\tmodel.register_field(reg, {Root, \"q\", \"pattern=^a+$,len<=3\"}) or_return\n"
	testing.expectf(t, strings.contains(source, want) && strings.contains(source, "model:\"len<=3\""), "no %q in\n%s", want, source)
}

// A number whose bounds a double holds is an `f64`, and any other keeps its text, so no number its schema takes is
// refused: a member's text refuses null by its tag, and a list's element by being held.
@(test)
odin_keeps_the_text_of_a_number_a_double_may_not_hold :: proc(t: ^testing.T) {
	source, err := odin_of(t, `{"type": "object", "required": ["a", "b", "l"], "properties": {"a": {"type": "number"},
		"b": {"type": "number", "minimum": 0, "maximum": 1}, "l": {"type": "array", "items": {"type": "number"}}}}`)
	testing.expectf(t, err == nil, "%v", err)
	for want in ([]string{"\ta: core.Number_Text `model:\"not_null\"`,\n", "\tb: f64 `model:\">=0,<=1\"`,\n", "\tl: []core.Number_Text,\n"}) {
		testing.expectf(t, strings.contains(source, want), "no %q in\n%s", want, source)
	}
}

@(test)
odin_registers_a_members_default :: proc(t: ^testing.T) {
	source, err := odin_of(t, `{"type": "object", "properties": {"name": {"type": "string", "default": "a\"b"},
		"n": {"type": "integer", "default": 3}, "x": {"type": "number", "default": 1.5E2}, "on": {"type": "boolean", "default": true},
		"z": {"type": ["string", "null"], "default": null}}}`)
	testing.expectf(t, err == nil, "%v", err)
	for want in ([]string{
		"register :: proc(reg: ^model.Registry) -> core.Error {\n",
		"\tmodel.register_default(reg, Root, \"name\", string(`a\"b`)) or_return\n",
		"\tmodel.register_default(reg, Root, \"n\", i64(3)) or_return\n",
		"\tmodel.register_default(reg, Root, \"x\", core.Number_Text{\"1.5e2\", core.text_f64(\"1.5e2\")}) or_return\n",
		"\tmodel.register_default(reg, Root, \"on\", bool(true)) or_return\n",
	}) {
		testing.expectf(t, strings.contains(source, want), "no %q in\n%s", want, source)
	}
	testing.expectf(t, !strings.contains(source, `"z"`), "%s", source)
}

@(test)
odin_refuses_a_default_or_a_range_no_member_type_holds :: proc(t: ^testing.T) {
	for c in ([][2]string{
		{`{"type": "object", "properties": {"a": {"type": "array", "default": [1]}}}`, "default"},
		{`{"type": "object", "properties": {"n": {"type": "integer", "default": 1.5}}}`, "default"},
		{`{"type": "object", "properties": {"n": {"type": "integer", "minimum": -1, "maximum": 18446744073709551615}}}`, "maximum"},
		{`{"type": "object", "properties": {"n": {"type": "integer", "minimum": -9223372036854775809, "maximum": 0}}}`, "minimum"},
	}) {
		keyword, _ := refused_keyword(t, c[0])
		testing.expectf(t, keyword == c[1], "%s: refused %q", c[0], keyword)
	}
	source, err := odin_of(t, `{"type": "object", "properties": {"n": {"type": "integer", "minimum": 0, "maximum": 18446744073709551615}}}`)
	testing.expectf(t, err == nil && strings.contains(source, "Maybe(u64)"), "%v\n%s", err, source)
}
