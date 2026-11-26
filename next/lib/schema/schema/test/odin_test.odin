// Tests for Odin source code generation (`write_odin`) from `rules.Description`:
// structs, optional/nullable fields, tags, enums, unions, recursive pointers, formats, fragments, and errors.
package schema_test

import "base:runtime"
import "core:strings"
import "core:testing"
import "stury:lib/schema/model"
import "stury:lib/schema/schema"
import "stury:testkit"

@(test)
odin_structs_tags_optional_and_recursive :: proc(t: ^testing.T) {
	testkit.deadline(t)
	s := `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"title": "User",
		"description": "A user record.",
		"type": "object",
		"properties": {
			"userName": {"type": "string", "minLength": 2, "maxLength": 32},
			"age": {"type": "integer", "minimum": 0, "maximum": 150},
			"email": {"type": "string", "format": "email"},
			"createdAt": {"type": "string", "format": "date-time"},
			"id": {"type": "string", "format": "uuid"},
			"parent": {"$ref": "#"},
			"nickname": {"type": ["string", "null"]}
		},
		"required": ["userName", "id"],
		"additionalProperties": false
	}`
	c := compile_or_fail(t, s, {format_assert = true})
	defer schema.destroy(c)

	src, err := schema.write_odin(c.description, "demo_types", true)
	defer schema.error_destroy(&err)
	testing.expectf(t, err.kind == .None, "write_odin failed: %v %q", err.kind, err.keyword)
	defer delete(src)

	testing.expect(t, strings.contains(src, "package demo_types"))
	testing.expect(t, strings.contains(src, `import "core:encoding/uuid"`))
	testing.expect(t, strings.contains(src, `import "core:time"`))
	testing.expect(t, strings.contains(src, `import model "stury:lib/schema/model"`))
	testing.expect(t, strings.contains(src, "User :: struct {"))
	testing.expect(t, strings.contains(src, `user_name: string`))
	testing.expect(t, strings.contains(src, `json:"userName"`))
	testing.expect(t, strings.contains(src, `len>=2,len<=32`))
	testing.expect(t, strings.contains(src, `age: Maybe(i64)`))
	testing.expect(t, strings.contains(src, `email: Maybe(model.Email)`))
	testing.expect(t, strings.contains(src, `created_at: Maybe(time.Time)`))
	testing.expect(t, strings.contains(src, `id: uuid.Identifier`))
	testing.expect(t, strings.contains(src, `parent: ^User`))
	testing.expect(t, strings.contains(src, `nickname: Maybe(string)`))
	testing.expect(t, strings.contains(src, `omitunset`))
	testing.expect(t, strings.contains(src, `set: model.Fields_Set`))
	testing.expect(t, strings.contains(src, `model.register_extra(reg, User, .Forbid)`))
}

@(test)
odin_enums_unions_fragments_and_errors :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// String enum + integer enum + anyOf union + judged `not` fragment + default
	s := `{
		"type": "object",
		"properties": {
			"status": {"enum": ["in-progress", "done"], "default": "done"},
			"code": {"enum": [200, 404, 500]},
			"payload": {"anyOf": [{"type": "string"}, {"type": "integer"}]},
			"nonzero": {"type": "integer", "not": {"const": 0}}
		},
		"required": ["code", "payload", "nonzero"]
	}`
	c := compile_or_fail(t, s)
	defer schema.destroy(c)

	src, err := schema.write_odin(c.description, "api_models")
	defer schema.error_destroy(&err)
	testing.expectf(t, err.kind == .None, "write_odin failed: %v %q", err.kind, err.keyword)
	defer delete(src)

	testing.expect(t, strings.contains(src, "In_Progress,"))
	testing.expect(t, strings.contains(src, `model.register_enum(reg, {`))
	testing.expect(t, strings.contains(src, "V200 = 200,"))
	testing.expect(t, strings.contains(src, "union #no_nil {string, i64}"))
	testing.expect(t, strings.contains(src, `model.register_default(reg, Root, "status",`))
	testing.expect(t, strings.contains(src, `register_fragment(reg,`))

	// Invalid package name refused as `.Bad_Option`
	_, berr := schema.write_odin(c.description, "struct")
	testing.expect_value(t, berr.kind, schema.Error_Kind.Bad_Option)
	schema.error_destroy(&berr)

	_, berr2 := schema.write_odin(c.description, "schema")
	testing.expect_value(t, berr2.kind, schema.Error_Kind.Bad_Option)
	schema.error_destroy(&berr2)

	// Unsupported keyword (`false` root) refused as `.Unsupported`
	cf := compile_or_fail(t, `false`)
	defer schema.destroy(cf)
	_, uerr := schema.write_odin(cf.description, "demo_types")
	testing.expect_value(t, uerr.kind, schema.Error_Kind.Unsupported)
	schema.error_destroy(&uerr)
}

@(test)
odin_recursive_judged_wide_struct_anyof_default_and_number_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// 1. Recursive judged schema (object with `propertyNames` + self-reference)
	{
		c := compile_or_fail(t, `{
			"$defs": {
				"node": {
					"type": "object",
					"propertyNames": {"minLength": 1},
					"properties": {
						"v": {"type": "integer"},
						"next": {"$ref": "#/$defs/node"}
					},
					"required": ["v"]
				}
			},
			"$ref": "#/$defs/node"
		}`)
		defer schema.destroy(c)
		src, err := schema.write_odin(c.description, "rec_pkg")
		defer schema.error_destroy(&err)
		testing.expectf(t, err.kind == .None, "recursive judged write_odin failed: %v %q", err.kind, err.keyword)
		defer delete(src)
		testing.expect(t, strings.contains(src, "next: ^Node"))
		testing.expect(t, strings.contains(src, "register :: proc(reg: ^model.Registry) -> model.Error"))
	}

	// 2. Wide struct (>128 fields) emits `model.Fields_Set` cleanly without refusing
	{
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, `{"type":"object","properties":{`)
		for i in 0 ..< 140 {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, `"f`)
			strings.write_int(&b, i)
			strings.write_string(&b, `":{"type":["integer","null"]}`)
		}
		strings.write_string(&b, `}}`)
		c := compile_or_fail(t, strings.to_string(b))
		defer schema.destroy(c)
		src, err := schema.write_odin(c.description, "wide_pkg")
		defer schema.error_destroy(&err)
		testing.expectf(t, err.kind == .None, "wide struct write_odin failed: %v %q", err.kind, err.keyword)
		defer delete(src)
		testing.expect(t, strings.contains(src, "set: model.Fields_Set"))
	}

	// 3. `anyOf` scalar default + unbounded `number` uses `model.Number_Text`
	{
		c := compile_or_fail(t, `{
			"type": "object",
			"properties": {
				"choice": {"anyOf": [{"type": "string"}, {"type": "integer"}], "default": "hello"},
				"amount": {"type": "number"}
			}
		}`)
		defer schema.destroy(c)
		src, err := schema.write_odin(c.description, "def_pkg")
		defer schema.error_destroy(&err)
		testing.expectf(t, err.kind == .None, "anyOf default write_odin failed: %v %q", err.kind, err.keyword)
		defer delete(src)
		testing.expect(t, strings.contains(src, `model.register_default(reg, Root, "choice",`))
		testing.expect(t, strings.contains(src, "amount: Maybe(model.Number_Text)"))
		testing.expect(t, !strings.contains(src, "rules.Number_Text"))
		testing.expect(t, strings.contains(src, "register :: proc(reg: ^model.Registry) -> model.Error"))
	}
}

@(test)
odin_pointer_defaults_names_node_number_text_f64_and_fragment_errors :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Optional `^T` recursive field with scalar `default`: emits `model.register_factory` + `import "base:runtime"`, NOT broken `register_default`!
	{
		c := compile_or_fail(t, `{
			"$defs": {
				"item": {
					"anyOf": [
						{"type": "string"},
						{
							"type": "object",
							"properties": {
								"next": {"$ref": "#/$defs/item", "default": "leaf"}
							}
						}
					]
				}
			},
			"$ref": "#/$defs/item"
		}`)
		defer schema.destroy(c)
		src, err := schema.write_odin(c.description, "ptr_def_pkg")
		defer schema.error_destroy(&err)
		testing.expectf(t, err.kind == .None, "ptr default write_odin failed: %v %q", err.kind, err.keyword)
		defer delete(src)
		testing.expect(t, strings.contains(src, `import "base:runtime"`))
		testing.expect(t, strings.contains(src, `next: ^Item`))
		testing.expect(t, strings.contains(src, `model.register_factory(reg,`))
		testing.expect(t, strings.contains(src, `new_clone(`))
		testing.expect(t, !strings.contains(src, `model.register_default(reg,`))
	}

	// 2. `names_node`: `required`-only key alongside `patternProperties` + `additionalProperties: false` must NOT be added to `^(?:...)$`!
	{
		c := compile_or_fail(t, `{
			"type": "object",
			"properties": {"id": {"type": "integer"}},
			"required": ["id", "x_req"],
			"patternProperties": {"^x_": {"type": "string"}},
			"additionalProperties": false
		}`)
		defer schema.destroy(c)
		src, err := schema.write_odin(c.description, "names_pkg")
		defer schema.error_destroy(&err)
		testing.expectf(t, err.kind == .None, "names_node write_odin failed: %v %q", err.kind, err.keyword)
		defer delete(src)
		testing.expect(t, strings.contains(src, `^(?:id)$`))
		testing.expect(t, !strings.contains(src, `^(?:id|x_req)$`))
	}

	// 3. `f64_holds` checks `multipleOf` binary64 exactness (`0.1` -> `model.Number_Text`, `0.25` -> `f64`)
	//    AND `Number_Text` default populates both `.text` and `.value`!
	{
		c := compile_or_fail(t, `{
			"type": "object",
			"properties": {
				"price": {"type": "number", "minimum": 0, "maximum": 100, "multipleOf": 0.1, "default": 1.5},
				"quarter": {"type": "number", "minimum": 0, "maximum": 100, "multipleOf": 0.25, "default": 0.5}
			}
		}`)
		defer schema.destroy(c)
		src, err := schema.write_odin(c.description, "num_pkg")
		defer schema.error_destroy(&err)
		testing.expectf(t, err.kind == .None, "f64_holds write_odin failed: %v %q", err.kind, err.keyword)
		defer delete(src)
		testing.expect(t, strings.contains(src, `price: Maybe(model.Number_Text)`))
		testing.expect(t, strings.contains(src, `model.Number_Text{text = "1.5", value = 1.5}`))
		testing.expect(t, strings.contains(src, `quarter: Maybe(f64)`))
	}

	// 4. `REGISTER_FRAGMENT` preserves `model.Model_Error` detail (does NOT coerce all failures to `Invalid_Argument`).
	{
		c := compile_or_fail(t, `{"type": "integer", "not": {"const": 0}}`)
		defer schema.destroy(c)
		src, err := schema.write_odin(c.description, "frag_pkg")
		defer schema.error_destroy(&err)
		testing.expectf(t, err.kind == .None, "fragment write_odin failed: %v %q", err.kind, err.keyword)
		defer delete(src)
		testing.expect(t, strings.contains(src, `import "core:strings"`))
		testing.expect(t, strings.contains(src, `model.Model_Error{`))
		testing.expect(t, !strings.contains(src, `Invalid_Argument`))
	}

	// 5. Real `model.compile` verification of emitted `register_factory` on `^T` and `model.Number_Text{text, value}`!
	{
		Node_Item :: union #no_nil {
			string,
			Node_Obj,
		}
		Node_Obj :: struct {
			next:  ^Node_Item               `json:",omitempty" model:"optional,not_null"`,
			price: Maybe(model.Number_Text) `json:",omitempty" model:"optional,not_null,>=0,<=100,multiple_of=0.1"`,
			set:   model.Fields_Set,
		}
		reg: model.Registry
		defer model.registry_destroy(&reg)
		ferr := model.register_factory(&reg, Node_Obj, "next", proc(a: runtime.Allocator) -> ^Node_Item {
			p, _ := new_clone(Node_Item(string("leaf")), a)
			return p
		})
		testing.expect_value(t, ferr, runtime.Allocator_Error.None)
		derr := model.register_default(&reg, Node_Obj, "price", model.Number_Text{text = "1.5", value = 1.5})
		testing.expect_value(t, derr, nil)
		m, cerr := model.compile(&reg, Node_Obj)
		testing.expect_value(t, cerr, nil)
		defer model.destroy(&m)
	}
}
