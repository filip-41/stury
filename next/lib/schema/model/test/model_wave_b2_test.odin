// Wave B2 test suite:
// 1. Secret redaction (`secret` tag in `stury:`, `json:`, `model:`, `Dump_Opts.redact`, `redact_mask`,
//    `redact_paths` with wildcards, `json.dump` fast path + `model.dump` multi-format, and `Problem` error redaction).
// 2. Named validators (`Validator_Registry`, `Compile_Options`, `Load_Opts`, `validate=` / `validator=` tags,
//    compile-time & runtime missing-validator refusal, `x-stury-validators` JSON Schema export/import & doc validation,
//    `load` / `json.load` / `validate` / `patch` integration).
// 3. Versioned models & migrations (`Migration_Plan`, `Versioned_Model`, `edit.Overlay` + `tape.Document` +
//    typed struct chains `v1 -> v2 -> v3`, version extraction, `schema.compare` compat checking, runtime schema validation,
//    and clean error reporting on missing/unknown/downgrade/cyclic/duplicate versions).
package model_test

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:lib/ops/write"
import "stury:lib/schema/model"
import "stury:lib/schema/rules"
import "stury:testkit"
import "stury:toml"

// ============================================================================
// 1. Secret Redaction Tests
// ============================================================================

@(test)
redaction_secret_tags_dump_and_custom_mask :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Creds :: struct {
		user:       string,
		password:   string `stury:"secret"`,
		api_key:    string `json:"api_key,secret"`,
		pin:        int    `model:">=1000,secret"`,
		paired_tok: string `json:"tok" stury:"secret"`,
	}

	m, cerr := model.compile(nil, Creds)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)

	{
		c := Creds{
			user       = "ada",
			password   = "hunter2",
			api_key    = "sk-live-999",
			pin        = 4321,
			paired_tok = "bearer-xyz",
		}

		// Without `redact = true`, all values dump normally (both direct `json.dump` and generic `model.dump`).
		plain_fast, perr1 := json.dump(&m, &c, allocator = a)
		defer delete(plain_fast, a)
		testing.expect_value(t, perr1, nil)
		testing.expect(t, strings.contains(string(plain_fast), `"password":"hunter2"`))
		testing.expect(t, strings.contains(string(plain_fast), `"api_key":"sk-live-999"`))
		testing.expect(t, strings.contains(string(plain_fast), `"pin":4321`))
		testing.expect(t, strings.contains(string(plain_fast), `"tok":"bearer-xyz"`))

		// With `redact = true`, default mask `"[REDACTED]"` replaces every secret field (even non-string `pin`!).
		red_fast, rerr1 := json.dump(&m, &c, {redact = true}, allocator = a)
		defer delete(red_fast, a)
		testing.expect_value(t, rerr1, nil)
		rs := string(red_fast)
		testing.expect(t, strings.contains(rs, `"user":"ada"`))
		testing.expect(t, strings.contains(rs, `"password":"[REDACTED]"`))
		testing.expect(t, strings.contains(rs, `"api_key":"[REDACTED]"`))
		testing.expect(t, strings.contains(rs, `"pin":"[REDACTED]"`))
		testing.expect(t, strings.contains(rs, `"tok":"[REDACTED]"`))
		testing.expect(t, !strings.contains(rs, "hunter2"))
		testing.expect(t, !strings.contains(rs, "sk-live-999"))
		testing.expect(t, !strings.contains(rs, "4321"))
		testing.expect(t, !strings.contains(rs, "bearer-xyz"))

		// Custom `redact_mask` works on both `json.dump` (pretty) and generic `model.dump` (TOML).
		red_pretty, rerr2 := json.dump(&m, &c, {redact = true, redact_mask = "***"}, {indent = 2}, allocator = a)
		defer delete(red_pretty, a)
		testing.expect_value(t, rerr2, nil)
		testing.expect(t, strings.contains(string(red_pretty), `"password": "***"`))
		testing.expect(t, !strings.contains(string(red_pretty), "hunter2"))

		write_toml :: proc(doc: ^tape.Document, opts: write.Options, allocator: runtime.Allocator) -> ([]u8, tape.Facts, write.Error) {
			return toml.write(doc, .Toml_1_0, opts, allocator)
		}
		red_toml, terr := model.dump(&m, &c, write_toml, {redact = true, redact_mask = "<hidden>"}, allocator = a)
		defer delete(red_toml, a)
		testing.expect_value(t, terr, nil)
		testing.expect(t, strings.contains(string(red_toml), `password = "<hidden>"`))
		testing.expect(t, strings.contains(string(red_toml), `user = "ada"`))
		testing.expect(t, !strings.contains(string(red_toml), "hunter2"))
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
redaction_arbitrary_paths_and_wildcards :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Header :: struct {
		name:  string,
		value: string,
	}
	Nested :: struct {
		auth:    struct { token: string, region: string },
		headers: []Header,
		meta:    map[string]string,
	}

	m, cerr := model.compile(nil, Nested)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	meta := make(map[string]string)
	defer delete(meta)
	meta["public"] = "ok"
	meta["secret_note"] = "do-not-leak"

	v := Nested{
		auth    = {token = "tok-abc", region = "eu"},
		headers = {{name = "Authorization", value = "Bearer 123"}, {name = "Accept", value = "application/json"}},
		meta    = meta,
	}
	paths := []string{"/auth/token", "/headers/*/value", "/meta/secret_note"}

	// Test both direct `json.dump` and `model.dump` (`emit_node`) agree identically!
	out_fast, err1 := json.dump(&m, &v, {redact_paths = paths, redact_mask = "MASKED"})
	defer delete(out_fast)
	testing.expect_value(t, err1, nil)

	out_doc, err2 := model.dump(&m, &v, write_json_default, {redact_paths = paths, redact_mask = "MASKED"})
	defer delete(out_doc)
	testing.expect_value(t, err2, nil)

	testing.expect_value(t, string(out_fast), string(out_doc))
	s := string(out_fast)
	testing.expect(t, strings.contains(s, `"region":"eu"`))
	testing.expect(t, strings.contains(s, `"token":"MASKED"`))
	testing.expect(t, strings.contains(s, `"value":"MASKED"`))
	testing.expect(t, strings.contains(s, `"public":"ok"`))
	testing.expect(t, strings.contains(s, `"secret_note":"MASKED"`))
	testing.expect(t, !strings.contains(s, "tok-abc"))
	testing.expect(t, !strings.contains(s, "Bearer 123"))
	testing.expect(t, !strings.contains(s, "do-not-leak"))
}

@(test)
redaction_errors_and_problem_never_leak_secrets :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Login :: struct {
		username: string `model:"len>=3"`,
		password: string `model:"len>=8,secret"`,
		note:     string `model:"len>=4"`,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	// Deliberately echo the secret value inside a custom validator to prove redaction scrubs it before storage & reporting!
	_ = model.register_after(&reg, Login, "password", proc(pw: string, r: ^model.Report) {
		if pw == "secret12345" {
			model.fail(r, "rejected password value: secret12345")
		}
	})

	m, cerr := model.compile(&reg, Login)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// (A) Streaming `json.load` failure on secret field: neither `Sink`, `Model_Error`, nor `Problem` leaks the secret!
	{
		sink: model.Sink
		defer model.destroy(&sink)
		out: Login
		defer model.free_value(&out, type_info_of(Login), context.allocator)
		err := json.load(&m, transmute([]u8)string(`{"username":"ab","password":"secret12345","note":"hi"}`), &out, sink = &sink)
		testing.expect(t, err != nil)
		testing.expect_value(t, len(sink.entries), 3)

		// Find the `/password` entry and confirm it's flagged secret and scrubbed right in the sink.
		found_pw := false
		for e in sink.entries {
			if e.pointer == "/password" {
				found_pw = true
				testing.expect(t, e.secret)
				testing.expect(t, !strings.contains(e.want.text, "secret12345"))
				testing.expect(t, !strings.contains(e.operand, "secret12345"))
			}
		}
		testing.expect(t, found_pw)

		// `problem()` automatically masks secret fields AND masks extra `redact_paths` (`/note`).
		p, perr := model.problem(sink.entries[:], "Bad Login", 422, opts = {redact = true, redact_mask = "[HIDDEN]", redact_paths = {"/note"}})
		defer model.problem_destroy(p)
		testing.expect_value(t, perr, runtime.Allocator_Error.None)
		for pe in p.errors {
			testing.expect(t, !strings.contains(pe.message, "secret12345"))
			if pe.pointer == "/password" || pe.pointer == "/note" {
				testing.expect(t, strings.contains(pe.message, "[HIDDEN]"))
			} else if pe.pointer == "/username" {
				testing.expect(t, strings.contains(pe.message, "at least 3"))
			}
		}

		// `write_problem_tokens` also respects `Problem_Opts`.
		tt: write.Token_Tape
		testing.expect_value(t, write.token_tape_start(&tt, false, 0, context.allocator), runtime.Allocator_Error.None)
		defer write.token_tape_drop(&tt)
		testing.expect_value(t, model.write_problem_tokens(&tt, sink.entries[:], p, opts = {redact = true, redact_mask = "[HIDDEN]", redact_paths = {"/note"}}), nil)
		doc, derr := write.token_tape_document(&tt)
		testing.expect_value(t, derr, runtime.Allocator_Error.None)
		bytes, _, werr := json.write(&doc)
		defer delete(bytes)
		testing.expect_value(t, werr, nil)
		testing.expect(t, !strings.contains(string(bytes), "secret12345"))
		testing.expect(t, strings.contains(string(bytes), "[HIDDEN]"))
	}

	// (B) In-memory `model.validate` also marks secret errors and scrubs custom messages!
	{
		bad := Login{username = "ada", password = "secret12345", note = "okay"}
		sink: model.Sink
		defer model.destroy(&sink)
		verr := model.validate(&m, &bad, &sink)
		testing.expect(t, verr != nil)
		testing.expect_value(t, len(sink.entries), 1)
		testing.expect(t, sink.entries[0].secret)
		testing.expect(t, !strings.contains(sink.entries[0].want.text, "secret12345"))
	}
}

// ============================================================================
// 2. Named Validators (`Validator_Registry` + `x-stury-validators`) Tests
// ============================================================================

@(private = "file")
check_non_empty_trim :: proc(s: string, r: ^model.Report) {
	if len(strings.trim_space(s)) == 0 {
		model.fail(r, "must contain non-whitespace characters")
	}
}

@(private = "file")
check_corp_email :: proc(s: string, r: ^model.Report) {
	if !strings.has_suffix(s, "@corp.example") {
		model.fail(r, "email must belong to @corp.example")
	}
}

@(private = "file")
check_even_i64 :: proc(n: i64, r: ^model.Report) {
	if n % 2 != 0 {
		model.fail(r, "must be even")
	}
}

@(test)
named_validators_compile_load_validate_patch_and_missing_refusal :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Member :: struct {
		name:  string `model:"validate=non_empty_trim"`,
		email: string `model:"format=email,validator=corp_email"`,
		quota: i64    `model:">=0,validate=even_number"`,
		set:   model.Fields_Set,
	}

	// (A) Missing named validator refused cleanly at compile time when `!defer_validators`!
	{
		vr_partial: model.Validator_Registry
		defer model.destroy(&vr_partial)
		_ = model.register_named_validator(&vr_partial, "non_empty_trim", string, check_non_empty_trim)

		_, cerr := model.compile_with_opts(nil, Member, {validators = &vr_partial})
		me, is_me := cerr.(model.Model_Error)
		testing.expect(t, is_me)
		testing.expect_value(t, me.kind, model.Error_Kind.Missing_Validator)
		testing.expect_value(t, me.want.text, "corp_email")
	}

	// (B) Full registry compiles and runs on `json.load` (streaming!), `model.load`, `model.validate`, and `model.patch`!
	{
		vr: model.Validator_Registry
		defer model.destroy(&vr)
		testing.expect_value(t, model.register_named_validator(&vr, "non_empty_trim", string, check_non_empty_trim), runtime.Allocator_Error.None)
		testing.expect_value(t, model.register_named_validator(&vr, "corp_email", string, check_corp_email), runtime.Allocator_Error.None)
		testing.expect_value(t, model.register_named_validator(&vr, "even_number", i64, check_even_i64), runtime.Allocator_Error.None)

		m, cerr := model.compile_with_opts(nil, Member, {validators = &vr})
		defer model.destroy(&m)
		testing.expect_value(t, cerr, nil)

		// Valid load (streaming path!)
		ok_m: Member
		defer model.free_value(&ok_m, type_info_of(Member), context.allocator)
		testing.expect_value(t, json.load(&m, transmute([]u8)string(`{"name":"Ada","email":"ada@corp.example","quota":10}`), &ok_m), nil)
		testing.expect(t, ok_m.name == "Ada" && ok_m.email == "ada@corp.example" && ok_m.quota == 10)

		// Invalid values caught with structured Problem errors!
		sink: model.Sink
		defer model.destroy(&sink)
		bad_m: Member
		defer model.free_value(&bad_m, type_info_of(Member), context.allocator)
		lerr := json.load(&m, transmute([]u8)string(`{"name":"   ","email":"ada@other.org","quota":7}`), &bad_m, sink = &sink)
		testing.expect(t, lerr != nil)
		testing.expect_value(t, len(sink.entries), 3)

		prob, perr := model.problem(sink.entries[:], "Validation Failed", 422)
		defer model.problem_destroy(prob)
		testing.expect_value(t, perr, runtime.Allocator_Error.None)
		testing.expect_value(t, prob.errors[0].pointer, "/name")
		testing.expect_value(t, prob.errors[0].code, "custom")
		testing.expect_value(t, prob.errors[0].message, "must contain non-whitespace characters")
		testing.expect_value(t, prob.errors[1].pointer, "/email")
		testing.expect_value(t, prob.errors[1].message, "email must belong to @corp.example")
		testing.expect_value(t, prob.errors[2].pointer, "/quota")
		testing.expect_value(t, prob.errors[2].message, "must be even")

		// `model.patch` runs named validators on patched fields and rolls back on failure!
		patch_err := model.patch(&m, &ok_m, transmute([]u8)string(`{"email":"bob@gmail.com"}`), json.as(.Json), json.reads(.Json))
		defer model.error_destroy(patch_err)
		testing.expect(t, patch_err != nil)
		testing.expect_value(t, ok_m.email, "ada@corp.example") // untouched!

		testing.expect_value(t, model.patch(&m, &ok_m, transmute([]u8)string(`{"email":"grace@corp.example","quota":12}`), json.as(.Json), json.reads(.Json)), nil)
		testing.expect(t, ok_m.email == "grace@corp.example" && ok_m.quota == 12)
	}

	// (C) Deferred validators (`defer_validators = true`): supplied at runtime via `Load_Opts.validators`,
	//     and cleanly refused with `.Missing_Validator` when omitted!
	{
		m, cerr := model.compile_with_opts(nil, Member, {defer_validators = true})
		defer model.destroy(&m)
		testing.expect_value(t, cerr, nil)

		// Missing at runtime -> `.Missing_Validator`
		out1: Member
		defer model.free_value(&out1, type_info_of(Member), context.allocator)
		err_miss := json.load(&m, transmute([]u8)string(`{"name":"Ada","email":"ada@corp.example","quota":4}`), &out1)
		defer model.error_destroy(err_miss)
		me, is_me := err_miss.(model.Model_Error)
		testing.expect(t, is_me && me.kind == .Missing_Validator)

		// Provided at runtime via `Load_Opts.validators` -> passes!
		vr: model.Validator_Registry
		defer model.destroy(&vr)
		_ = model.register_named_validator(&vr, "non_empty_trim", string, check_non_empty_trim)
		_ = model.register_named_validator(&vr, "corp_email", string, check_corp_email)
		_ = model.register_named_validator(&vr, "even_number", i64, check_even_i64)

		testing.expect_value(t, json.load(&m, transmute([]u8)string(`{"name":"Ada","email":"ada@corp.example","quota":4}`), &out1, opts = {validators = &vr}), nil)
		testing.expect_value(t, model.validate(&m, &out1, opts = {validators = &vr}), nil)

		// Validate without registry also returns `.Missing_Validator`!
		verr := model.validate(&m, &out1)
		defer model.error_destroy(verr)
		vme, is_vme := verr.(model.Model_Error)
		testing.expect(t, is_vme && vme.kind == .Missing_Validator)
	}
}

@(test)
named_validators_x_stury_validators_schema_roundtrip :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Contact :: struct {
		label: string `model:"validate=non_empty_trim"`,
		email: string `model:"validator=corp_email"`,
	}
	Team :: struct {
		lead:    Contact,
		members: []Contact,
	}

	vr: model.Validator_Registry
	defer model.destroy(&vr)
	_ = model.register_named_validator(&vr, "non_empty_trim", string, check_non_empty_trim)
	_ = model.register_named_validator(&vr, "corp_email", string, check_corp_email)

	m, cerr := model.compile_with_opts(nil, Team, {validators = &vr})
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// 1. Export JSON Schema with `"x-stury-validators"` metadata (including inside `$defs` because `Contact` is shared!).
	schema_bytes, serr := model.schema_json(&m, .Load, {indent = 2})
	defer delete(schema_bytes)
	testing.expect_value(t, serr, nil)
	schema_str := string(schema_bytes)
	testing.expect(t, strings.contains(schema_str, `"x-stury-validators"`))
	testing.expect(t, strings.contains(schema_str, `"non_empty_trim"`))
	testing.expect(t, strings.contains(schema_str, `"corp_email"`))

	// 2. Import `"x-stury-validators"` back from the emitted JSON Schema `tape.Document`!
	sdoc, berr := json.build(schema_bytes)
	defer tape.destroy(&sdoc)
	testing.expect_value(t, berr, nil)

	sv, eerr := model.extract_schema_validators(&sdoc)
	defer model.destroy(&sv)
	testing.expect_value(t, eerr, nil)
	testing.expect(t, len(sv.bindings) >= 4) // `/lead/label`, `/lead/email`, `/members/*/label`, `/members/*/email`

	// 3. Validate a raw `tape.Document` directly against the imported `Schema_Validators`!
	bad_json := `{"lead":{"label":"Boss","email":"boss@corp.example"},"members":[{"label":"   ","email":"x@external.io"}]}`
	doc, derr := json.build(transmute([]u8)bad_json)
	defer tape.destroy(&doc)
	testing.expect_value(t, derr, nil)

	sink: model.Sink
	defer model.destroy(&sink)
	verr := model.validate_schema_validators(&doc, &sv, &vr, &sink)
	testing.expect(t, verr != nil)
	testing.expect_value(t, len(sink.entries), 2)
	testing.expect_value(t, sink.entries[0].pointer, "/members/0/label")
	testing.expect_value(t, sink.entries[1].pointer, "/members/0/email")

	// 4. Import `"x-stury-validators"` from a JSON Schema onto an UNTAGGED Odin struct via `register_schema_validators`!
	Plain_User :: struct {
		name:  string,
		email: string,
	}
	ext_schema_src := `{
		"type": "object",
		"properties": {
			"name":  {"type": "string", "x-stury-validators": ["non_empty_trim"]},
			"email": {"type": "string", "x-stury-validators": ["corp_email"]}
		}
	}`
	ext_sdoc, xberr := json.build(transmute([]u8)ext_schema_src)
	defer tape.destroy(&ext_sdoc)
	testing.expect_value(t, xberr, nil)

	reg: model.Registry
	defer model.destroy(&reg)
	testing.expect_value(t, model.register_schema_validators(&reg, Plain_User, &ext_sdoc), nil)

	pm, pcerr := model.compile_with_opts(&reg, Plain_User, {validators = &vr})
	defer model.destroy(&pm)
	testing.expect_value(t, pcerr, nil)

	u: Plain_User
	defer model.free_value(&u, type_info_of(Plain_User), context.allocator)
	bad_lerr := json.load(&pm, transmute([]u8)string(`{"name":"Ada","email":"ada@nope.com"}`), &u)
	defer model.error_destroy(bad_lerr)
	testing.expect(t, bad_lerr != nil)
	testing.expect_value(t, json.load(&pm, transmute([]u8)string(`{"name":"Ada","email":"ada@corp.example"}`), &u), nil)

	// 5. Malformed `"x-stury-validators"` in external schema is refused cleanly with `.Bad_Tag` and zero leaks!
	for bad_schema in ([]string{
		`{"type":"object","properties":{"x":{"type":"string","x-stury-validators":"not_an_array"}}}`,
		`{"type":"object","properties":{"x":{"type":"string","x-stury-validators":[123]}}}`,
		`{"type":"object","properties":{"x":{"type":"string","x-stury-validators":["bad name!"]}}}`,
	}) {
		bsdoc, bberr := json.build(transmute([]u8)bad_schema)
		defer tape.destroy(&bsdoc)
		testing.expect_value(t, bberr, nil)
		_, bverr := model.extract_schema_validators(&bsdoc)
		defer model.error_destroy(bverr)
		bme, is_bme := bverr.(model.Model_Error)
		testing.expect(t, is_bme && bme.kind == .Bad_Tag)
	}

	// 6. Type-level named validator (`register_type`) runs on distinct types and exports to JSON Schema!
	Sku :: distinct string
	Order :: struct {
		sku: Sku,
	}
	check_sku :: proc(s: string, r: ^model.Report) {
		if !strings.has_prefix(s, "SKU-") { model.fail(r, "must start with SKU-") }
	}
	reg_sku: model.Registry
	defer model.destroy(&reg_sku)
	_ = model.register_named_validator(&reg_sku, "sku_prefix", string, check_sku)
	_ = model.register(&reg_sku, model.Type_Rule{Sku, "validate=sku_prefix"})

	om, ocerr := model.compile(&reg_sku, Order)
	defer model.destroy(&om)
	testing.expect_value(t, ocerr, nil)

	ord: Order
	defer model.free_value(&ord, type_info_of(Order), context.allocator)
	bad_oerr := json.load(&om, transmute([]u8)string(`{"sku":"BAD-1"}`), &ord)
	defer model.error_destroy(bad_oerr)
	testing.expect(t, bad_oerr != nil)
	testing.expect_value(t, json.load(&om, transmute([]u8)string(`{"sku":"SKU-42"}`), &ord), nil)
	testing.expect_value(t, string(ord.sku), "SKU-42")
}

// ============================================================================
// 3. Versioned Models & Migrations (`migrate.odin`) Tests
// ============================================================================

@(test)
migrations_sequential_chain_overlay_and_typed_and_compat :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Config_V1 :: struct {
		schema_version: int,
		host:           string,
	}
	Config_V2 :: struct {
		schema_version: int,
		endpoint:       string,
		tls:            bool,
	}
	Config_V3 :: struct {
		schema_version: int,
		endpoint:       string,
		tls:            bool,
		retries:        int `model:">=0,<=10"`,
	}

	m1, e1 := model.compile(nil, Config_V1)
	defer model.destroy(&m1)
	m2, e2 := model.compile(nil, Config_V2)
	defer model.destroy(&m2)
	m3, e3 := model.compile(nil, Config_V3)
	defer model.destroy(&m3)
	testing.expect(t, e1 == nil && e2 == nil && e3 == nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)

	{
		plan: model.Migration_Plan
		model.migration_plan_init(&plan, current_version = 3, allocator = a)
		defer model.destroy(&plan)

		testing.expect_value(t, model.register_version_model(&plan, 1, &m1), nil)
		testing.expect_value(t, model.register_version_model(&plan, 2, &m2), nil)
		testing.expect_value(t, model.register_version_model(&plan, 3, &m3), nil)

		// Before registering steps, `verify_migration_plan_compat` detects breaking `v1 -> v2` change!
		compat12, cerr12 := model.check_version_compat(&plan, 1, 2, allocator = a)
		defer model.destroy(&compat12)
		testing.expect_value(t, cerr12, nil)
		testing.expect(t, !compat12.backward_compatible)
		testing.expect(t, compat12.requires_migration)

		ver_before := model.verify_migration_plan_compat(&plan, allocator = a)
		vme, is_vme := ver_before.(model.Model_Error)
		testing.expect(t, is_vme && vme.kind == .Incompatible_Schema)

		// Step 1 (`v1 -> v2`): in-place `edit.Overlay` rename + add fields!
		step_1_to_2 :: proc(ov: ^edit.Overlay, data: rawptr, allocator: runtime.Allocator) -> model.Error {
			_ = data; _ = allocator
			root, rerr := edit.ensure_root(ov)
			if rerr != nil { return model.Model_Error{kind = .Migration_Failed} }
			if err := edit.rename_member(ov, root, "host", "endpoint"); err != nil {
				return model.Model_Error{kind = .Migration_Failed}
			}
			if _, err := edit.set_member(ov, root, "tls", edit.val_bool(true)); err != nil {
				return model.Model_Error{kind = .Migration_Failed}
			}
			if _, err := edit.set_member(ov, root, "schema_version", edit.val_int(2)); err != nil {
				return model.Model_Error{kind = .Migration_Failed}
			}
			return nil
		}
		testing.expect_value(t, model.register_migration(&plan, 1, 2, step_1_to_2), nil)

		// Step 2 (`v2 -> v3`): typed struct-to-struct migration `Config_V2 -> Config_V3`!
		step_2_to_3 :: proc(src: ^Config_V2, dst: ^Config_V3, allocator: runtime.Allocator) -> model.Error {
			ep, aerr := strings.clone(src.endpoint, allocator)
			if aerr != nil { return aerr }
			dst^ = Config_V3{
				schema_version = 3,
				endpoint       = ep,
				tls            = src.tls,
				retries        = 3,
			}
			return nil
		}
		testing.expect_value(t, model.register_migration(&plan, 2, 3, &m2, &m3, step_2_to_3), nil)

		// Now `verify_migration_plan_compat` passes because every breaking step has a migration path!
		testing.expect_value(t, model.verify_migration_plan_compat(&plan, allocator = a), nil)

		// Execute full chain `v1 -> v3` via `Versioned_Model(Config_V3)`!
		vm := model.Versioned_Model(Config_V3){target = &m3, plan = plan}
		// Avoid double-destroying `plan` (owned by outer defer).
		v1_doc, berr := json.build(transmute([]u8)string(`{"schema_version":1,"host":"api.internal"}`), allocator = a)
		defer tape.destroy(&v1_doc)
		testing.expect_value(t, berr, nil)

		cfg: Config_V3
		defer model.free_value(&cfg, type_info_of(Config_V3), a)
		res, lerr := model.versioned_load_document(&vm, &v1_doc, &cfg, migrate_opts = {validate_steps = true}, allocator = a)
		testing.expect_value(t, lerr, nil)
		testing.expect(t, res.migrated && res.from_version == 1 && res.to_version == 3 && res.steps_run == 2)
		testing.expect(t, cfg.schema_version == 3 && cfg.endpoint == "api.internal" && cfg.tls && cfg.retries == 3)

		// Already-current `v3` document takes the fast zero-migration path!
		v3_doc, berr3 := json.build(transmute([]u8)string(`{"schema_version":3,"endpoint":"edge","tls":false,"retries":5}`), allocator = a)
		defer tape.destroy(&v3_doc)
		testing.expect_value(t, berr3, nil)

		cfg3: Config_V3
		defer model.free_value(&cfg3, type_info_of(Config_V3), a)
		res3, lerr3 := model.versioned_load_document(&vm, &v3_doc, &cfg3, allocator = a)
		testing.expect_value(t, lerr3, nil)
		testing.expect(t, !res3.migrated && res3.steps_run == 0 && cfg3.endpoint == "edge" && !cfg3.tls && cfg3.retries == 5)

		// Non-breaking evolution (`v3 -> v4` on closed schemas adding an optional field & widening `retries`)
		// reports `backward_compatible == true`!
		Config_V4 :: struct {
			schema_version: int,
			endpoint:       string,
			tls:            bool,
			retries:        int    `model:">=0,<=20"`,
			region:         string `model:"optional"`,
		}
		reg_closed: model.Registry
		defer model.destroy(&reg_closed)
		_ = model.register_extra(&reg_closed, Config_V3, .Forbid)
		_ = model.register_extra(&reg_closed, Config_V4, .Forbid)
		m3c, e3c := model.compile(&reg_closed, Config_V3, allocator = a)
		defer model.destroy(&m3c)
		m4c, e4c := model.compile(&reg_closed, Config_V4, allocator = a)
		defer model.destroy(&m4c)
		testing.expect(t, e3c == nil && e4c == nil)
		d3, d3err := model.schema(&m3c, .Load, a); defer rules.description_destroy(&d3)
		d4, d4err := model.schema(&m4c, .Load, a); defer rules.description_destroy(&d4)
		testing.expect(t, d3err == nil && d4err == nil)
		compat34, c34err := model.check_schema_compat(&d3, &d4, 3, 4, allocator = a)
		defer model.destroy(&compat34)
		testing.expect_value(t, c34err, runtime.Allocator_Error.None)
		testing.expect(t, compat34.backward_compatible && !compat34.requires_migration)

		// Invalid source v1 document (missing `host`) is rejected by source schema validation before running migration!
		bad_v1, bv1_err := json.build(transmute([]u8)string(`{"schema_version":1}`), allocator = a)
		defer tape.destroy(&bad_v1)
		testing.expect_value(t, bv1_err, nil)
		bad_sink: model.Sink
		model.sink_init(&bad_sink, a)
		defer model.destroy(&bad_sink)
		_, _, src_fail := model.migrate_document(&plan, &bad_v1, sink = &bad_sink, allocator = a)
		testing.expect(t, src_fail != nil && len(bad_sink.entries) >= 1)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
migrations_error_handling_unknown_downgrade_cyclic_and_custom_extractor :: proc(t: ^testing.T) {
	testkit.deadline(t)
	noop :: proc(ov: ^edit.Overlay, data: rawptr, allocator: runtime.Allocator) -> model.Error {
		_ = ov; _ = data; _ = allocator
		return nil
	}

	// (A) Self-loop & duplicate registration rejected immediately!
	{
		p: model.Migration_Plan
		model.migration_plan_init(&p, 3)
		defer model.destroy(&p)

		err_self := model.register_migration(&p, 1, 1, noop)
		me1, ok1 := err_self.(model.Model_Error)
		testing.expect(t, ok1 && me1.kind == .Cyclic_Migration)

		testing.expect_value(t, model.register_migration(&p, 1, 2, noop), nil)
		err_dup := model.register_migration(&p, 1, 2, noop)
		me2, ok2 := err_dup.(model.Model_Error)
		testing.expect(t, ok2 && me2.kind == .Duplicate_Migration)
	}

	// (B) Multi-hop cycle (`1 -> 2 -> 3 -> 1`) detected by `migration_plan_validate` & `migrate_document`!
	{
		p: model.Migration_Plan
		model.migration_plan_init(&p, 3)
		defer model.destroy(&p)
		testing.expect_value(t, model.register_migration(&p, 1, 2, noop), nil)
		testing.expect_value(t, model.register_migration(&p, 2, 3, noop), nil)
		testing.expect_value(t, model.register_migration(&p, 3, 1, noop), nil)

		verr := model.migration_plan_validate(&p)
		me, ok := verr.(model.Model_Error)
		testing.expect(t, ok && me.kind == .Cyclic_Migration)

		doc, _ := json.build(transmute([]u8)string(`{"version":1}`))
		defer tape.destroy(&doc)
		_, _, merr := model.migrate_document(&p, &doc)
		mme, mok := merr.(model.Model_Error)
		testing.expect(t, mok && mme.kind == .Cyclic_Migration)
	}

	// (C) Downgrade (`v3 -> v2`), unknown version (`v99`), missing version, string `"v1"`, and custom callback extractor!
	{
		p: model.Migration_Plan
		model.migration_plan_init(&p, 2)
		defer model.destroy(&p)
		testing.expect_value(t, model.register_migration(&p, 1, 2, noop), nil)

		// Downgrade refused (`src = 3 > target = 2`).
		d3, _ := json.build(transmute([]u8)string(`{"version":3}`))
		defer tape.destroy(&d3)
		_, _, err_down := model.migrate_document(&p, &d3)
		me_down, ok_down := err_down.(model.Model_Error)
		testing.expect(t, ok_down && me_down.kind == .Downgrade_Not_Allowed)

		// Unknown version (`src = 0`, no path `0 -> 2`).
		d0, _ := json.build(transmute([]u8)string(`{"version":0}`))
		defer tape.destroy(&d0)
		_, _, err_unk := model.migrate_document(&p, &d0)
		me_unk, ok_unk := err_unk.(model.Model_Error)
		testing.expect(t, ok_unk && me_unk.kind == .Unknown_Version)

		// Missing version field.
		dmiss, _ := json.build(transmute([]u8)string(`{"name":"no-ver"}`))
		defer tape.destroy(&dmiss)
		_, _, err_miss := model.migrate_document(&p, &dmiss)
		me_miss, ok_miss := err_miss.(model.Model_Error)
		testing.expect(t, ok_miss && me_miss.kind == .Missing_Version)

		// String version `"v1"` works out of the box!
		dv1, _ := json.build(transmute([]u8)string(`{"version":"v1","x":1}`))
		defer tape.destroy(&dv1)
		out_v2, res_v2, err_v2 := model.migrate_document(&p, &dv1)
		defer tape.destroy(&out_v2)
		testing.expect_value(t, err_v2, nil)
		testing.expect(t, res_v2.migrated && res_v2.from_version == 1 && res_v2.to_version == 2 && res_v2.steps_run == 1)

		// Custom version extractor callback!
		custom_extract :: proc(doc: ^tape.Document, data: rawptr) -> (int, bool) {
			_ = doc
			return (^int)(data)^, true
		}
		forced := 1
		model.set_version_extractor(&p, custom_extract, &forced)
		out_c, res_c, err_c := model.migrate_document(&p, &dmiss)
		defer tape.destroy(&out_c)
		testing.expect_value(t, err_c, nil)
		testing.expect(t, res_c.migrated && res_c.from_version == 1 && res_c.to_version == 2)
	}
}

// ============================================================================
// 4. Audit Regression Tests (Judged secret, merged x-stury-validators,
//    deep iterative schema extraction, stury:"secret,omitempty", strict versions)
// ============================================================================

@(test)
audit_secret_judged_unique_one_match_and_schema_and_stury_flags :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// (A) `secret` field with `unique` + `register_schema` + `.One_Match` union marks `secret = true` on judged failures!
	Arm_A :: struct { a: int }
	Arm_B :: struct { a: int }
	Ambig :: union { Arm_A, Arm_B }
	Vault :: struct {
		codes: []string `model:"unique,secret"`,
		token: string   `stury:"secret,omitempty"`,
		choice: Ambig   `model:"secret,optional"`,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register_union(&reg, model.Union_Rule{type = Ambig, mode = .One_Match})

	// Attach a custom schema fragment on `Vault` (`minProperties: 1` via `rules.Description`) to verify `register_schema` path too!
	// Also test struct validator calling `fail_at` using wire name on a `secret` field.
	_ = model.register_validator(&reg, Vault, proc(v: Vault, r: ^model.Report) {
		if v.token == "leaked-val" {
			model.fail_at(r, "token", "bad token leaked-val")
		}
	})

	m, cerr := model.compile(&reg, Vault)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// 1. `stury:"secret,omitempty"` both omits empty AND redacts non-empty!
	v_empty := Vault{codes = {"a", "b"}, token = ""}
	d_empty, derr1 := json.dump(&m, &v_empty, {redact = true})
	defer delete(d_empty)
	testing.expect_value(t, derr1, nil)
	testing.expect(t, !strings.contains(string(d_empty), `"token"`))
	testing.expect(t, strings.contains(string(d_empty), `"codes":"[REDACTED]"`))

	v_full := Vault{codes = {"a", "b"}, token = "supersecret"}
	d_full, derr2 := json.dump(&m, &v_full, {redact = true})
	defer delete(d_full)
	testing.expect_value(t, derr2, nil)
	testing.expect(t, strings.contains(string(d_full), `"token":"[REDACTED]"`))
	testing.expect(t, !strings.contains(string(d_full), "supersecret"))

	// 2. `unique` (judged!) failure inside `secret` field during BOTH `load` and `validate` sets `entry.secret == true`!
	{
		sink: model.Sink
		defer model.destroy(&sink)
		out: Vault
		defer model.free_value(&out, type_info_of(Vault), context.allocator)
		err := model.load(&m, transmute([]u8)string(`{"codes":["dup","dup"]}`), json.as(.Json), json.reads(.Json), &out, &sink)
		testing.expect(t, err != nil)
		testing.expect(t, len(sink.entries) >= 1 && sink.entries[0].kind == .Not_Unique && sink.entries[0].secret)

		p, perr := model.problem(sink.entries[:], "Invalid", 422)
		defer model.problem_destroy(p)
		testing.expect_value(t, perr, runtime.Allocator_Error.None)
		testing.expect(t, strings.contains(p.errors[0].message, "[REDACTED]"))
	}
	{
		bad_v := Vault{codes = {"dup", "dup"}}
		sink: model.Sink
		defer model.destroy(&sink)
		verr := model.validate(&m, &bad_v, &sink)
		testing.expect(t, verr != nil)
		testing.expect(t, len(sink.entries) >= 1 && sink.entries[0].kind == .Not_Unique && sink.entries[0].secret)
	}

	// 3. `.One_Match` union failure inside `secret` field sets `entry.secret == true`!
	{
		sink: model.Sink
		defer model.destroy(&sink)
		out: Vault
		defer model.free_value(&out, type_info_of(Vault), context.allocator)
		err := model.load(&m, transmute([]u8)string(`{"codes":["ok"],"choice":{"a":1}}`), json.as(.Json), json.reads(.Json), &out, &sink)
		testing.expect(t, err != nil)
		found_choice := false
		for e in sink.entries {
			if e.pointer == "/choice" {
				found_choice = true
				testing.expect(t, e.secret)
			}
		}
		testing.expect(t, found_choice)
	}

	// 4. `fail_at` by wire name on a `secret` field scrubs the custom message!
	{
		bad_v := Vault{codes = {"x"}, token = "leaked-val"}
		sink: model.Sink
		defer model.destroy(&sink)
		verr := model.validate(&m, &bad_v, &sink)
		testing.expect(t, verr != nil)
		testing.expect(t, len(sink.entries) == 1 && sink.entries[0].secret)
		testing.expect(t, !strings.contains(sink.entries[0].want.text, "leaked-val"))
	}

	// 5. `register_schema` fragment failure inside a `secret`-tagged nested struct marks `entry.secret == true`!
	{
		Secret_Box :: struct {
			a: int `model:"optional"`,
			b: int `model:"optional"`,
		}
		Holder :: struct {
			box: Secret_Box `stury:"secret"`,
		}
		// Fragment: `minProperties: 1` on `Secret_Box`.
		frag: rules.Description
		frag.allocator = context.allocator
		frag.nodes.allocator = context.allocator
		frag.objects.allocator = context.allocator
		frag.root = 0
		append(&frag.nodes, rules.Node{kinds = {.Object}, rules = {min_members = 1}, array = -1, object = -1})
		defer rules.description_destroy(&frag)

		reg2: model.Registry
		defer model.destroy(&reg2)
		testing.expect_value(t, model.register_schema(&reg2, Secret_Box, &frag), runtime.Allocator_Error.None)

		hm, hcerr := model.compile(&reg2, Holder)
		defer model.destroy(&hm)
		testing.expect_value(t, hcerr, nil)

		sink: model.Sink
		defer model.destroy(&sink)
		out: Holder
		defer model.free_value(&out, type_info_of(Holder), context.allocator)
		herr := model.load(&hm, transmute([]u8)string(`{"box":{}}`), json.as(.Json), json.reads(.Json), &out, &sink)
		testing.expect(t, herr != nil)
		testing.expect(t, len(sink.entries) >= 1 && sink.entries[0].kind == .Too_Few && sink.entries[0].secret)
	}
}

@(test)
audit_merged_field_and_type_x_stury_validators_and_deep_schema :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// (A) Field-level + type-level named validators on the SAME inline field compose cleanly (no overwrite!).
	Corp_Code :: distinct string
	Record :: struct {
		code: Corp_Code `model:"validate=non_empty_trim"`,
	}

	vr: model.Validator_Registry
	defer model.destroy(&vr)
	_ = model.register_named_validator(&vr, "non_empty_trim", string, check_non_empty_trim)
	_ = model.register_named_validator(&vr, "corp_email", string, check_corp_email)

	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, model.Type_Rule{Corp_Code, "validate=corp_email"})

	m, cerr := model.compile_with_opts(&reg, Record, {validators = &vr})
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	sbytes, serr := model.schema_json(&m, .Load)
	defer delete(sbytes)
	testing.expect_value(t, serr, nil)
	sstr := string(sbytes)
	testing.expect(t, strings.contains(sstr, `"non_empty_trim"`))
	testing.expect(t, strings.contains(sstr, `"corp_email"`))

	sdoc, berr := json.build(sbytes)
	defer tape.destroy(&sdoc)
	testing.expect_value(t, berr, nil)
	sv, eerr := model.extract_schema_validators(&sdoc)
	defer model.destroy(&sv)
	testing.expect_value(t, eerr, nil)
	testing.expect_value(t, len(sv.bindings), 1)
	testing.expect_value(t, sv.bindings[0].pointer, "/code")
	testing.expect_value(t, len(sv.bindings[0].validators), 2)

	// (B) Deep nested schema (256 levels) extracts iteratively without stack overflow and zero leaks!
	DEPTH :: 256
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for _ in 0 ..< DEPTH { strings.write_string(&b, `{"type":"object","properties":{"n":`) }
	strings.write_string(&b, `{"type":"string","x-stury-validators":["non_empty_trim"]}`)
	for _ in 0 ..< DEPTH { strings.write_string(&b, `}}`) }

	deep_doc, dberr := json.build(transmute([]u8)strings.to_string(b), opts = {budget = {depth = 1024}})
	defer tape.destroy(&deep_doc)
	testing.expect_value(t, dberr, nil)

	deep_sv, deerr := model.extract_schema_validators(&deep_doc)
	defer model.destroy(&deep_sv)
	testing.expect_value(t, deerr, nil)
	testing.expect_value(t, len(deep_sv.bindings), 1)
	testing.expect_value(t, len(deep_sv.bindings[0].validators), 1)
	testing.expect_value(t, deep_sv.bindings[0].validators[0], "non_empty_trim")
}

@(test)
audit_strict_version_token_rejections_and_nil_compat :: proc(t: ^testing.T) {
	testkit.deadline(t)

	p: model.Migration_Plan
	model.migration_plan_init(&p, 2)
	defer model.destroy(&p)

	// Strictly reject malformed / signed / float / hex / underscore / overflow version tokens!
	for bad_json in ([]string{
		`{"version":"v-1"}`,
		`{"version":"v+1"}`,
		`{"version":"v0x10"}`,
		`{"version":"v_1"}`,
		`{"version":"1_0"}`,
		`{"version":"v"}`,
		`{"version":""}`,
		`{"version":-1}`,
		`{"version":1.0}`,
		`{"version":1e2}`,
		`{"version":99999999999999999999999999}`,
	}) {
		doc, berr := json.build(transmute([]u8)bad_json)
		defer tape.destroy(&doc)
		testing.expect_value(t, berr, nil)
		_, verr := model.extract_document_version(&p, &doc)
		me, ok := verr.(model.Model_Error)
		testing.expectf(t, ok && me.kind == .Missing_Version, "expected Missing_Version for %s, got %v", bad_json, verr)
	}

	// `check_schema_compat` safely refuses nil descriptions instead of panicking.
	_, cerr := model.check_schema_compat(nil, nil)
	testing.expect_value(t, cerr, runtime.Allocator_Error.Invalid_Argument)
}
