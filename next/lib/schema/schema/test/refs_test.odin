// Tests for OS-free VFS `$ref` resolution: multi-document in-memory VFS (bytes & docs),
// circular `$ref` detection, missing `$ref`, custom `$vocabulary`, and embedded vendored meta-schemas.
package schema_test

import "base:runtime"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:lib/schema/schema"
import "stury:testkit"
import "stury:toml"

@(private = "file")
Mem_Vfs :: struct {
	files: map[string]string,
}

@(private = "file")
vfs_load_bytes :: proc(data: rawptr, uri: string, allocator: runtime.Allocator) -> (bytes: []u8, owned: bool, found: bool) {
	vfs := (^Mem_Vfs)(data)
	if text, ok := vfs.files[uri]; ok {
		return transmute([]u8)text, false, true
	}
	return nil, false, false
}

@(private = "file")
vfs_load_doc :: proc(data: rawptr, uri: string, allocator: runtime.Allocator) -> (doc: tape.Document, owned: bool, found: bool, err: schema.Error) {
	vfs := (^Mem_Vfs)(data)
	if text, ok := vfs.files[uri]; ok {
		built, berr := json.build(transmute([]u8)text, .Json, {}, allocator)
		if berr != nil {
			return {}, false, false, {kind = .Parse, keyword = "$ref"}
		}
		return built, true, true, {}
	}
	return {}, false, false, {}
}

@(test)
vfs_multi_document_bytes_and_doc_loaders :: proc(t: ^testing.T) {
	testkit.deadline(t)
	vfs := Mem_Vfs{files = make(map[string]string)}
	defer delete(vfs.files)
	vfs.files["vfs://schemas/address.json"] = `{
		"$id": "vfs://schemas/address.json",
		"type": "object",
		"$defs": {
			"zip": {"type": "string", "pattern": "^[0-9]{5}$"}
		},
		"properties": {
			"city": {"type": "string", "minLength": 1},
			"zip": {"$ref": "#/$defs/zip"}
		},
		"required": ["city", "zip"]
	}`
	vfs.files["vfs://schemas/common.json"] = `{
		"$id": "vfs://schemas/common.json",
		"$defs": {
			"nonEmpty": {"$anchor": "ne", "type": "string", "minLength": 1}
		}
	}`

	root_schema := `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"$id": "vfs://schemas/person.json",
		"type": "object",
		"properties": {
			"name": {"$ref": "common.json#ne"},
			"home": {"$ref": "address.json"}
		},
		"required": ["name", "home"]
	}`

	// 1. Via `load_bytes`
	c_bytes := compile_or_fail(t, root_schema, {
		base   = "vfs://schemas/person.json",
		loader = {load_bytes = vfs_load_bytes, data = &vfs},
	})
	defer schema.destroy(c_bytes)
	expect_json_valid(t, c_bytes, `{"name": "Ada", "home": {"city": "London", "zip": "12345"}}`, true)
	expect_json_valid(t, c_bytes, `{"name": "", "home": {"city": "London", "zip": "12345"}}`, false)
	expect_json_valid(t, c_bytes, `{"name": "Ada", "home": {"city": "London", "zip": "abc"}}`, false)

	// 2. Via `load_doc` (pre-parsed `tape.Document`)
	c_doc := compile_or_fail(t, root_schema, {
		base   = "vfs://schemas/person.json",
		loader = {load_doc = vfs_load_doc, data = &vfs},
	})
	defer schema.destroy(c_doc)
	expect_json_valid(t, c_doc, `{"name": "Grace", "home": {"city": "NYC", "zip": "10001"}}`, true)
	expect_json_valid(t, c_doc, `{"name": "Grace", "home": {"city": "", "zip": "10001"}}`, false)
}

@(test)
vfs_circular_and_missing_refs :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Direct in-place circular `$ref` is refused!
	_, err1 := schema.compile_json(transmute([]u8)string(`{"$defs":{"a":{"$ref":"#/$defs/b"},"b":{"$ref":"#/$defs/a"}},"$ref":"#/$defs/a"}`))
	testing.expect_value(t, err1.kind, schema.Error_Kind.Bad_Schema)
	schema.error_destroy(&err1)

	// Missing external `$ref` is refused cleanly!
	_, err2 := schema.compile_json(transmute([]u8)string(`{"$ref":"vfs://missing.json"}`))
	testing.expect_value(t, err2.kind, schema.Error_Kind.Bad_Schema)
	schema.error_destroy(&err2)

	// Recursive `$ref` through `properties` succeeds!
	c_rec := compile_or_fail(t, `{
		"$defs": {
			"node": {
				"type": "object",
				"properties": {
					"v": {"type": "integer"},
					"child": {"$ref": "#/$defs/node"}
				},
				"required": ["v"]
			}
		},
		"$ref": "#/$defs/node"
	}`)
	defer schema.destroy(c_rec)
	expect_json_valid(t, c_rec, `{"v": 1, "child": {"v": 2, "child": {"v": 3}}}`, true)
	expect_json_valid(t, c_rec, `{"v": 1, "child": {"v": "bad"}}`, false)
}

@(test)
vfs_custom_meta_vocabulary_and_embedded_meta_ref :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Custom meta-schema loaded via VFS that disables validation vocabulary
	vfs := Mem_Vfs{files = make(map[string]string)}
	defer delete(vfs.files)
	vfs.files["vfs://meta/no-validation.json"] = `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"$id": "vfs://meta/no-validation.json",
		"$vocabulary": {
			"https://json-schema.org/draft/2020-12/vocab/core": true,
			"https://json-schema.org/draft/2020-12/vocab/applicator": true
		}
	}`
	c := compile_or_fail(t, `{
		"$schema": "vfs://meta/no-validation.json",
		"type": "integer",
		"minimum": 100
	}`, {loader = {load_bytes = vfs_load_bytes, data = &vfs}})
	defer schema.destroy(c)
	// Because validation vocabulary is not enabled, `type` and `minimum` are ignored!
	expect_json_valid(t, c, `"not an integer"`, true)

	// Embedded vendored Draft 2020-12 meta-schema via `$ref` (zero OS, zero VFS needed!)
	c_meta := compile_or_fail(t, `{"$ref": "https://json-schema.org/draft/2020-12/schema"}`)
	defer schema.destroy(c_meta)
	expect_json_valid(t, c_meta, `{"type": "string", "minLength": 3}`, true)
	expect_json_valid(t, c_meta, `{"minLength": -5}`, false)
}

@(test)
read_without_resolver_vendored_meta_no_uaf :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Calling `schema.read(..., res = nil)` when `$ref` loads vendored `META` must detach `Node_Ref`s
	// so `d` has ZERO dangling pointers after `read`'s local resolver is destroyed!
	src := `{"$ref": "https://json-schema.org/draft/2020-12/schema"}`
	doc, berr := json.build(transmute([]u8)src, .Json)
	testing.expect(t, berr == nil)
	defer tape.destroy_document(&doc)

	desc, rerr := schema.read(&doc, tape.ROOT, "", nil)
	defer schema.error_destroy(&rerr)
	testing.expect_value(t, rerr.kind, schema.Error_Kind.None)
	defer rules.description_destroy(&desc)

	plan, cerr := check.compile(&desc)
	testing.expect_value(t, cerr.kind, check.Error_Kind.None)
	defer check.plan_destroy(&plan)

	ok_res := json.check(transmute([]u8)string(`{"type": "integer", "minimum": 0}`), &plan, .Json)
	defer check.result_destroy(&ok_res)
	testing.expect(t, ok_res.valid)

	bad_res := json.check(transmute([]u8)string(`{"type": "not-a-type"}`), &plan, .Json)
	defer check.result_destroy(&bad_res)
	testing.expect(t, !bad_res.valid)

	// Also serialize `desc` with `write_schema` to exercise every materialized `default`/`enum` value under ASan!
	written, werr := schema.write_schema(&desc)
	defer schema.error_destroy(&werr)
	testing.expect_value(t, werr.kind, schema.Error_Kind.None)
	defer delete(written)
}

@(private = "file")
parse_toml_schema :: proc(_: rawptr, src: []u8, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	return toml.build(src, .Toml_1_0, {}, allocator)
}

@(test)
vfs_boolean_schema_cross_draft_and_non_json_parse :: proc(t: ^testing.T) {
	testkit.deadline(t)
	vfs := Mem_Vfs{files = make(map[string]string)}
	defer delete(vfs.files)
	vfs.files["vfs://schemas/always_true.json"] = `true`
	vfs.files["vfs://schemas/always_false.json"] = `false`

	// 1. External `$ref` to boolean schemas `true` and `false`
	c_true := compile_or_fail(t, `{"$ref": "vfs://schemas/always_true.json"}`, {loader = {load_bytes = vfs_load_bytes, data = &vfs}})
	defer schema.destroy(c_true)
	expect_json_valid(t, c_true, `{"anything": 1}`, true)

	c_false := compile_or_fail(t, `{"$ref": "vfs://schemas/always_false.json"}`, {loader = {load_bytes = vfs_load_bytes, data = &vfs}})
	defer schema.destroy(c_false)
	expect_json_valid(t, c_false, `1`, false)

	// 2. Cross-draft JSON Pointer `$ref` from outer Draft 2020-12 into embedded Draft 4 resource using `"id"`
	c_cross := compile_or_fail(t, `{
		"$schema": "https://json-schema.org/draft/2020-12/schema",
		"$defs": {
			"legacy": {
				"$schema": "http://json-schema.org/draft-04/schema#",
				"id": "https://example.com/legacy.json",
				"definitions": {
					"pos": {"type": "integer", "minimum": 0, "exclusiveMinimum": true}
				}
			}
		},
		"$ref": "#/$defs/legacy/definitions/pos"
	}`)
	defer schema.destroy(c_cross)
	expect_json_valid(t, c_cross, `1`, true)
	expect_json_valid(t, c_cross, `0`, false)

	// 3. Non-JSON caller `opts.parse` (TOML) still loads vendored JSON `META` schemas cleanly!
	toml_root := `
"$ref" = "https://json-schema.org/draft/2020-12/schema"
`
	c_toml_meta, err := schema.compile_json(transmute([]u8)toml_root, {parse = parse_toml_schema})
	defer schema.error_destroy(&err)
	testing.expect_value(t, err.kind, schema.Error_Kind.None)
	defer schema.destroy(c_toml_meta)
	expect_json_valid(t, c_toml_meta, `{"type": "string"}`, true)
	expect_json_valid(t, c_toml_meta, `{"type": 123}`, false)
}
