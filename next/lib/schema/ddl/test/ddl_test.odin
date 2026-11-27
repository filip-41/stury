// Comprehensive tests for SQL DDL (`CREATE TABLE`) schema frontend (`stury:lib/schema/ddl`):
// lexing/parsing dialects, SQL types, CHECK expressions, multi-format validation (JSON, CSV, TOML, YAML),
// schema.compare DDL evolution, schema.sample, schema.write_schema, schema.write_odin, errors, and OOM sweep.
package ddl_test

import "base:runtime"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/ddl"
import "stury:lib/schema/rules"
import "stury:lib/schema/schema"
import "stury:testkit"
import "stury:toml"
import "stury:yaml"

@(private = "file")
must_compile :: proc(t: ^testing.T, sql: string, opts := ddl.Compile_Options{}, loc := #caller_location) -> ^ddl.Compiled {
	c, err := ddl.compile_ddl(transmute([]u8)sql, opts)
	if err.kind != .None {
		defer ddl.error_destroy(&err)
		testing.expectf(t, false, "compile_ddl failed: kind=%v line=%d col=%d msg=%q table=%q col=%q", err.kind, err.line, err.col, err.message, err.table, err.column, loc = loc)
		return nil
	}
	return c
}

@(private = "file")
expect_json :: proc(t: ^testing.T, c: ^ddl.Compiled, text: string, want: bool, loc := #caller_location) {
	if c == nil {
		return
	}
	doc, jerr := json.build(transmute([]u8)text)
	if jerr != nil {
		testing.expectf(t, false, "json.build failed on %q: %v", text, jerr, loc = loc)
		return
	}
	defer tape.destroy_document(&doc)
	got := ddl.valid_document(c, &doc)
	testing.expectf(t, got == want, "json %s: got valid=%v, want %v", text, got, want, loc = loc)
}

@(test)
ddl_lex_parse_dialects_and_multitable :: proc(t: ^testing.T) {
	testkit.deadline(t)

	sql := `
	-- Leading line comment & non-table statements safely skipped
	SET client_encoding = 'UTF8';
	DROP TABLE IF EXISTS legacy_users;
	CREATE TYPE account_status AS ENUM ('pending', 'active', 'suspended');

	/* Outer block comment
	   /* Nested block comment */
	   still inside comment */
	create temporary table if not exists public.users (
		"user_id" BIGSERIAL PRIMARY KEY,
		` + "`email`" + ` VARCHAR(120) NOT NULL UNIQUE,
		[Display Name] TEXT DEFAULT 'it''s anonymous',
		status account_status NOT NULL DEFAULT 'pending'::account_status,
		parent_id BIGINT REFERENCES public.users("user_id") ON DELETE SET NULL NOT NULL,
		CONSTRAINT uq_email_status UNIQUE ("email", status),
		KEY idx_status (status)
	) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

	CREATE UNIQUE INDEX idx_users_email ON public.users ("email");
	COMMENT ON TABLE public.users IS 'Primary user accounts';

	CREATE TABLE billing.orders (
		tenant_id INT NOT NULL,
		order_no INT NOT NULL,
		total NUMERIC(10, 2) NOT NULL DEFAULT 0.00,
		notes TEXT,
		PRIMARY KEY (tenant_id, order_no),
		FOREIGN KEY (tenant_id) REFERENCES public.users("user_id") ON DELETE CASCADE
	) WITHOUT ROWID, STRICT;
	`

	// Default selection picks first table (`public.users`)
	c_users := must_compile(t, sql)
	defer ddl.destroy(c_users)
	testing.expect_value(t, c_users.meta.schema_name, "public")
	testing.expect_value(t, c_users.meta.table_name, "users")
	testing.expect_value(t, len(c_users.meta.primary_key), 1)
	testing.expect_value(t, c_users.meta.primary_key[0], "user_id")
	testing.expect(t, len(c_users.meta.unique_columns) >= 3)
	testing.expect_value(t, len(c_users.meta.foreign_keys), 1)
	testing.expect_value(t, c_users.meta.foreign_keys[0].ref_table, "public.users")

	// Valid row: status omitted (has DEFAULT), Display Name omitted (nullable), parent_id required (NOT NULL after REFERENCES!)
	expect_json(t, c_users, `{"user_id": 1, "email": "alice@example.com", "parent_id": 0}`, true)
	expect_json(t, c_users, `{"user_id": 1, "email": "alice@example.com", "Display Name": null, "status": "active", "parent_id": 0}`, true)
	// Missing parent_id fails (`NOT NULL` after `REFERENCES` was preserved!)
	expect_json(t, c_users, `{"user_id": 1, "email": "alice@example.com"}`, false)
	// Invalid custom ENUM value fails
	expect_json(t, c_users, `{"user_id": 1, "email": "alice@example.com", "status": "deleted", "parent_id": 0}`, false)

	// Select second table by unqualified name (case-insensitive)
	c_orders := must_compile(t, sql, {table_name = "ORDERS"})
	defer ddl.destroy(c_orders)
	testing.expect_value(t, c_orders.meta.schema_name, "billing")
	testing.expect_value(t, c_orders.meta.table_name, "orders")
	testing.expect_value(t, len(c_orders.meta.primary_key), 2)
	testing.expect_value(t, c_orders.meta.primary_key[0], "tenant_id")
	testing.expect_value(t, c_orders.meta.primary_key[1], "order_no")
	testing.expect_value(t, len(c_orders.meta.foreign_keys), 1)

	// Composite PRIMARY KEY columns are required and non-null; `total` has DEFAULT so optional by default.
	expect_json(t, c_orders, `{"tenant_id": 1, "order_no": 42}`, true)
	expect_json(t, c_orders, `{"tenant_id": 1, "order_no": 42, "total": 19.99, "notes": null}`, true)
	expect_json(t, c_orders, `{"tenant_id": 1, "order_no": null}`, false)
	expect_json(t, c_orders, `{"tenant_id": 1, "order_no": 42, "total": 19.999}`, false)

	// Select by schema-qualified name
	c_qual := must_compile(t, sql, {table_name = "billing.orders"})
	defer ddl.destroy(c_qual)
	testing.expect_value(t, c_qual.meta.table_name, "orders")

	// Missing table returns `.No_Table`
	_, missing_err := ddl.compile_ddl(transmute([]u8)sql, {table_name = "nonexistent"})
	defer ddl.error_destroy(&missing_err)
	testing.expect_value(t, missing_err.kind, ddl.Error_Kind.No_Table)
}

@(test)
ddl_sql_types_options_and_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)

	sql := `
	CREATE TABLE records (
		id UUID PRIMARY KEY,
		tiny TINYINT NOT NULL,
		utiny TINYINT UNSIGNED NOT NULL,
		small SMALLINT NOT NULL,
		whole INTEGER NOT NULL,
		big BIGINT NOT NULL,
		ratio DOUBLE PRECISION,
		price DECIMAL(6, 2) NOT NULL,
		active BOOLEAN NOT NULL DEFAULT TRUE,
		country CHAR(2) NOT NULL,
		nick VARCHAR(8),
		created_date DATE NOT NULL,
		alarm_time TIME,
		updated_at TIMESTAMPTZ NOT NULL,
		payload JSONB,
		raw BYTEA,
		role ENUM('admin', 'editor', 'viewer') NOT NULL,
		opt_role ENUM('a', 'b'),
		tags TEXT[]
	);
	`
	c := must_compile(t, sql)
	defer ddl.destroy(c)

	good := `{
		"id": "550e8400-e29b-41d4-a716-446655440000",
		"tiny": -128,
		"utiny": 255,
		"small": 32767,
		"whole": 100000,
		"big": 9007199254740991,
		"ratio": 3.14159,
		"price": 9999.99,
		"country": "US",
		"nick": "filip",
		"created_date": "2026-11-26",
		"alarm_time": "08:30:00Z",
		"updated_at": "2026-11-26T18:00:00Z",
		"payload": {"nested": [1, true, "x"]},
		"raw": "aGVsbG8=",
		"role": "admin",
		"opt_role": null,
		"tags": ["sql", "ddl"]
	}`
	expect_json(t, c, good, true)

	// Integer bounds checks
	expect_json(t, c, `{"id":"550e8400-e29b-41d4-a716-446655440000","tiny":128,"utiny":0,"small":0,"whole":0,"big":0,"price":1.00,"country":"US","created_date":"2026-11-26","updated_at":"2026-11-26T18:00:00Z","role":"admin"}`, false)
	expect_json(t, c, `{"id":"550e8400-e29b-41d4-a716-446655440000","tiny":127,"utiny":-1,"small":0,"whole":0,"big":0,"price":1.00,"country":"US","created_date":"2026-11-26","updated_at":"2026-11-26T18:00:00Z","role":"admin"}`, false)
	expect_json(t, c, `{"id":"550e8400-e29b-41d4-a716-446655440000","tiny":0,"utiny":0,"small":40000,"whole":0,"big":0,"price":1.00,"country":"US","created_date":"2026-11-26","updated_at":"2026-11-26T18:00:00Z","role":"admin"}`, false)
	// CHAR(2) enforces exact length 2
	expect_json(t, c, `{"id":"550e8400-e29b-41d4-a716-446655440000","tiny":0,"utiny":0,"small":0,"whole":0,"big":0,"price":1.00,"country":"U","created_date":"2026-11-26","updated_at":"2026-11-26T18:00:00Z","role":"admin"}`, false)
	expect_json(t, c, `{"id":"550e8400-e29b-41d4-a716-446655440000","tiny":0,"utiny":0,"small":0,"whole":0,"big":0,"price":1.00,"country":"USA","created_date":"2026-11-26","updated_at":"2026-11-26T18:00:00Z","role":"admin"}`, false)
	// VARCHAR(8) enforces maxLength 8
	expect_json(t, c, `{"id":"550e8400-e29b-41d4-a716-446655440000","tiny":0,"utiny":0,"small":0,"whole":0,"big":0,"price":1.00,"country":"US","nick":"123456789","created_date":"2026-11-26","updated_at":"2026-11-26T18:00:00Z","role":"admin"}`, false)
	// Format assertions (UUID, DATE, TIME, TIMESTAMPTZ)
	expect_json(t, c, `{"id":"not-a-uuid","tiny":0,"utiny":0,"small":0,"whole":0,"big":0,"price":1.00,"country":"US","created_date":"2026-11-26","updated_at":"2026-11-26T18:00:00Z","role":"admin"}`, false)
	expect_json(t, c, `{"id":"550e8400-e29b-41d4-a716-446655440000","tiny":0,"utiny":0,"small":0,"whole":0,"big":0,"price":1.00,"country":"US","created_date":"2026-99-99","updated_at":"2026-11-26T18:00:00Z","role":"admin"}`, false)
	expect_json(t, c, `{"id":"550e8400-e29b-41d4-a716-446655440000","tiny":0,"utiny":0,"small":0,"whole":0,"big":0,"price":1.00,"country":"US","created_date":"2026-11-26","updated_at":"not-a-timestamp","role":"admin"}`, false)
	// Strict columns rejects extra fields by default
	expect_json(t, c, `{"id":"550e8400-e29b-41d4-a716-446655440000","tiny":0,"utiny":0,"small":0,"whole":0,"big":0,"price":1.00,"country":"US","created_date":"2026-11-26","updated_at":"2026-11-26T18:00:00Z","role":"admin","extra":1}`, false)

	// `strict_columns = false` and `default_optional = false`
	c_opts := must_compile(t, sql, {strict_columns = false, default_optional = false})
	defer ddl.destroy(c_opts)
	// Missing `active` (has DEFAULT TRUE) now fails because `default_optional = false`!
	expect_json(t, c_opts, `{"id":"550e8400-e29b-41d4-a716-446655440000","tiny":0,"utiny":0,"small":0,"whole":0,"big":0,"price":1.00,"country":"US","created_date":"2026-11-26","updated_at":"2026-11-26T18:00:00Z","role":"admin"}`, false)
	// With `active` present AND extra field -> passes because `strict_columns = false`!
	expect_json(t, c_opts, `{"id":"550e8400-e29b-41d4-a716-446655440000","tiny":0,"utiny":0,"small":0,"whole":0,"big":0,"price":1.00,"country":"US","active":false,"created_date":"2026-11-26","updated_at":"2026-11-26T18:00:00Z","role":"admin","extra":123}`, true)
}

@(test)
ddl_check_expressions_and_3vl :: proc(t: ^testing.T) {
	testkit.deadline(t)

	sql := `
	CREATE TABLE products (
		sku VARCHAR(32) NOT NULL CHECK (LENGTH(sku) >= 3 AND LENGTH(sku) <= 16 AND sku <> '' AND sku LIKE 'PRD_%'),
		name TEXT NOT NULL CHECK (name != '' AND CHAR_LENGTH(name) >= 2),
		tier TEXT NOT NULL CHECK (tier IN ('free', 'pro', 'enterprise')),
		region CHAR(2) NOT NULL CHECK (region = 'EU'),
		rating INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
		discount INT CHECK (discount > 0 AND 100 >= discount),
		band INT CHECK (band < 0 OR band > 10),
		code INT NOT NULL CHECK (NOT (code BETWEEN 10 AND 20) AND code <> 0),
		opt_tag TEXT CHECK (opt_tag IN ('alpha', 'beta')),
		kind TEXT NOT NULL,
		url TEXT,
		start_day INT NOT NULL,
		end_day INT NOT NULL,
		CHECK (kind = 'local' OR url IS NOT NULL),
		CHECK (end_day >= start_day)
	);
	`

	c := must_compile(t, sql)
	defer ddl.destroy(c)
	// Cross-column `CHECK (end_day >= start_day)` is recorded in `uncompiled_checks`.
	testing.expect_value(t, c.meta.uncompiled_checks, 1)

	// Valid row (including SQL 3VL: nullable `discount`, `band`, `opt_tag` all accept null!)
	expect_json(t, c, `{
		"sku": "PRD_100",
		"name": "Widget",
		"tier": "pro",
		"region": "EU",
		"rating": 5,
		"discount": null,
		"band": null,
		"code": 25,
		"opt_tag": null,
		"kind": "local",
		"start_day": 1,
		"end_day": 2
	}`, true)

	// Valid row with non-null optional constrained fields and remote + url
	expect_json(t, c, `{
		"sku": "PRD_99",
		"name": "Gadget",
		"tier": "free",
		"region": "EU",
		"rating": 1,
		"discount": 50,
		"band": -5,
		"code": 5,
		"opt_tag": "alpha",
		"kind": "remote",
		"url": "https://example.com",
		"start_day": 1,
		"end_day": 5
	}`, true)

	// Fails LIKE 'PRD_%'
	expect_json(t, c, `{"sku":"ABC_100","name":"Widget","tier":"pro","region":"EU","rating":3,"code":1,"kind":"local","start_day":1,"end_day":2}`, false)
	// Fails LENGTH(name) >= 2 / name != ''
	expect_json(t, c, `{"sku":"PRD_100","name":"","tier":"pro","region":"EU","rating":3,"code":1,"kind":"local","start_day":1,"end_day":2}`, false)
	expect_json(t, c, `{"sku":"PRD_100","name":"A","tier":"pro","region":"EU","rating":3,"code":1,"kind":"local","start_day":1,"end_day":2}`, false)
	// Fails IN ('free','pro','enterprise')
	expect_json(t, c, `{"sku":"PRD_100","name":"Widget","tier":"vip","region":"EU","rating":3,"code":1,"kind":"local","start_day":1,"end_day":2}`, false)
	// Fails const `region = 'EU'`
	expect_json(t, c, `{"sku":"PRD_100","name":"Widget","tier":"pro","region":"US","rating":3,"code":1,"kind":"local","start_day":1,"end_day":2}`, false)
	// Fails BETWEEN 1 AND 5
	expect_json(t, c, `{"sku":"PRD_100","name":"Widget","tier":"pro","region":"EU","rating":6,"code":1,"kind":"local","start_day":1,"end_day":2}`, false)
	// Fails `discount > 0` (exclusive!) and `100 >= discount`
	expect_json(t, c, `{"sku":"PRD_100","name":"Widget","tier":"pro","region":"EU","rating":3,"discount":0,"code":1,"kind":"local","start_day":1,"end_day":2}`, false)
	expect_json(t, c, `{"sku":"PRD_100","name":"Widget","tier":"pro","region":"EU","rating":3,"discount":101,"code":1,"kind":"local","start_day":1,"end_day":2}`, false)
	// Fails `band < 0 OR band > 10`
	expect_json(t, c, `{"sku":"PRD_100","name":"Widget","tier":"pro","region":"EU","rating":3,"band":5,"code":1,"kind":"local","start_day":1,"end_day":2}`, false)
	// Fails `NOT (code BETWEEN 10 AND 20)` and `code <> 0`
	expect_json(t, c, `{"sku":"PRD_100","name":"Widget","tier":"pro","region":"EU","rating":3,"code":15,"kind":"local","start_day":1,"end_day":2}`, false)
	expect_json(t, c, `{"sku":"PRD_100","name":"Widget","tier":"pro","region":"EU","rating":3,"code":0,"kind":"local","start_day":1,"end_day":2}`, false)
	// Fails table-level multi-column `CHECK (kind = 'local' OR url IS NOT NULL)`
	expect_json(t, c, `{"sku":"PRD_100","name":"Widget","tier":"pro","region":"EU","rating":3,"code":1,"kind":"remote","start_day":1,"end_day":2}`, false)
	expect_json(t, c, `{"sku":"PRD_100","name":"Widget","tier":"pro","region":"EU","rating":3,"code":1,"kind":"remote","url":null,"start_day":1,"end_day":2}`, false)

	// With `strict_checks = true`, cross-column `CHECK (end_day >= start_day)` returns `.Bad_Check`
	_, berr := ddl.compile_ddl(transmute([]u8)sql, {strict_checks = true})
	defer ddl.error_destroy(&berr)
	testing.expect_value(t, berr.kind, ddl.Error_Kind.Bad_Check)
}

@(test)
ddl_multi_format_json_csv_toml_yaml :: proc(t: ^testing.T) {
	testkit.deadline(t)

	sql := `
	CREATE TABLE employees (
		id INT PRIMARY KEY,
		name VARCHAR(32) NOT NULL CHECK (name <> ''),
		age SMALLINT NOT NULL CHECK (age >= 18 AND age <= 120),
		active BOOLEAN NOT NULL
	);
	`

	// 1. Single-row TOML & YAML
	c_row := must_compile(t, sql)
	defer ddl.destroy(c_row)

	toml_ok := "id = 1\nname = \"Ada\"\nage = 36\nactive = true\n"
	tdoc, terr := toml.build(transmute([]u8)toml_ok)
	testing.expect(t, terr == nil)
	defer tape.destroy_document(&tdoc)
	testing.expect(t, ddl.valid_document(c_row, &tdoc))

	toml_bad := "id = 1\nname = \"Ada\"\nage = 12\nactive = true\n"
	tdoc_bad, terr2 := toml.build(transmute([]u8)toml_bad)
	testing.expect(t, terr2 == nil)
	defer tape.destroy_document(&tdoc_bad)
	testing.expect(t, !ddl.valid_document(c_row, &tdoc_bad))

	yaml_ok := "id: 2\nname: Grace\nage: 45\nactive: false\n"
	ydoc, yerr := yaml.build(transmute([]u8)yaml_ok)
	testing.expect(t, yerr == nil)
	defer tape.destroy_document(&ydoc)
	testing.expect(t, ddl.valid_document(c_row, &ydoc))

	yaml_bad := "id: 2\nname: \"\"\nage: 45\nactive: false\n"
	ydoc_bad, yerr2 := yaml.build(transmute([]u8)yaml_bad)
	testing.expect(t, yerr2 == nil)
	defer tape.destroy_document(&ydoc_bad)
	testing.expect(t, !ddl.valid_document(c_row, &ydoc_bad))

	// 2. Table-rows array (`as_array = true`): JSON array + CSV (inferred)
	c_arr := must_compile(t, sql, {as_array = true})
	defer ddl.destroy(c_arr)

	// JSON array of distinct rows passes; duplicate rows fail `uniqueItems` (from PRIMARY KEY)
	expect_json(t, c_arr, `[{"id":1,"name":"Ada","age":36,"active":true},{"id":2,"name":"Bob","age":29,"active":false}]`, true)
	expect_json(t, c_arr, `[{"id":1,"name":"Ada","age":36,"active":true},{"id":1,"name":"Ada","age":36,"active":true}]`, false)

	// CSV with `infer = true`
	csv_opts := dsv.Options{format = tape.Dsv_Options{infer = true}}
	csv_ok := "id,name,age,active\n1,Ada,36,true\n2,Grace,45,false\n"
	cdoc, cerr := dsv.build(transmute([]u8)csv_ok, .Csv, csv_opts)
	testing.expect(t, cerr == nil)
	defer tape.destroy_document(&cdoc)
	testing.expect(t, ddl.valid_document(c_arr, &cdoc))

	// CSV with underage row (`age = 15`) fails `CHECK (age >= 18)`
	csv_bad := "id,name,age,active\n1,Ada,36,true\n2,Kid,15,true\n"
	cdoc_bad, cerr2 := dsv.build(transmute([]u8)csv_bad, .Csv, csv_opts)
	testing.expect(t, cerr2 == nil)
	defer tape.destroy_document(&cdoc_bad)
	res := ddl.check_document(c_arr, &cdoc_bad)
	defer check.result_destroy(&res)
	testing.expect(t, !res.valid)
	testing.expect_value(t, res.err.kind, rules.Error_Kind.Below_Minimum)
}

@(test)
ddl_compare_sample_write_schema_and_write_odin :: proc(t: ^testing.T) {
	testkit.deadline(t)

	v1_sql := `
	CREATE TABLE accounts (
		id UUID PRIMARY KEY,
		username VARCHAR(50) NOT NULL CHECK (LENGTH(username) >= 3),
		tier SMALLINT NOT NULL CHECK (tier >= 0),
		balance NUMERIC(10, 2) NOT NULL,
		status ENUM('open', 'closed') NOT NULL DEFAULT 'open',
		created_at TIMESTAMP NOT NULL
	);
	`
	// Compatible widening migration: VARCHAR(50)->VARCHAR(100), SMALLINT->INT, NUMERIC(10,2)->NUMERIC(12,4),
	// new enum value, and new nullable column.
	v2_compat_sql := `
	CREATE TABLE accounts (
		id UUID PRIMARY KEY,
		username VARCHAR(100) NOT NULL CHECK (LENGTH(username) >= 3),
		tier INT NOT NULL CHECK (tier >= 0),
		balance NUMERIC(12, 4) NOT NULL,
		status ENUM('open', 'closed', 'frozen') NOT NULL DEFAULT 'open',
		created_at TIMESTAMP NOT NULL,
		bio TEXT
	);
	`
	// Breaking migration: adding NOT NULL column without default + narrowing VARCHAR(50)->VARCHAR(20)
	v2_break_sql := `
	CREATE TABLE accounts (
		id UUID PRIMARY KEY,
		username VARCHAR(20) NOT NULL CHECK (LENGTH(username) >= 3),
		tier SMALLINT NOT NULL CHECK (tier >= 10),
		balance NUMERIC(10, 2) NOT NULL,
		status ENUM('open', 'closed') NOT NULL DEFAULT 'open',
		created_at TIMESTAMP NOT NULL,
		org_id INT NOT NULL
	);
	`

	d1, e1 := ddl.compile_description(transmute([]u8)v1_sql)
	defer ddl.error_destroy(&e1)
	testing.expect_value(t, e1.kind, ddl.Error_Kind.None)
	defer rules.description_destroy(&d1)

	d2_compat, e2 := ddl.compile_description(transmute([]u8)v2_compat_sql)
	defer ddl.error_destroy(&e2)
	testing.expect_value(t, e2.kind, ddl.Error_Kind.None)
	defer rules.description_destroy(&d2_compat)

	d2_break, e3 := ddl.compile_description(transmute([]u8)v2_break_sql)
	defer ddl.error_destroy(&e3)
	testing.expect_value(t, e3.kind, ddl.Error_Kind.None)
	defer rules.description_destroy(&d2_break)

	// 1. `schema.compare`: v1 -> v2_compat is backward-compatible (`old_in_new == .Yes`, `new_in_old == .No`).
	// Note: `d1` and `d2_compat` already carry `assert_format = true` on UUID/TIMESTAMP nodes directly.
	cmp_ok, _ := schema.compare(&d1, &d2_compat)
	defer schema.comparison_destroy(&cmp_ok)
	testing.expectf(t, cmp_ok.old_in_new.verdict == .Yes, "expected compatible migration, got %v (witness=%q reason=%q)", cmp_ok.old_in_new.verdict, cmp_ok.old_in_new.witness, cmp_ok.old_in_new.reason)
	testing.expect_value(t, cmp_ok.new_in_old.verdict, schema.Verdict.No)

	// 2. `schema.compare`: v1 -> v2_break is BREAKING (`old_in_new == .No` with counterexample witness!)
	cmp_brk, _ := schema.compare(&d1, &d2_break)
	defer schema.comparison_destroy(&cmp_brk)
	testing.expect_value(t, cmp_brk.old_in_new.verdict, schema.Verdict.No)
	testing.expect(t, cmp_brk.old_in_new.witness != "")

	// Verify counterexample witness passes v1 and fails v2_break!
	c1 := must_compile(t, v1_sql)
	defer ddl.destroy(c1)
	c2_break := must_compile(t, v2_break_sql)
	defer ddl.destroy(c2_break)
	expect_json(t, c1, cmp_brk.old_in_new.witness, true)
	expect_json(t, c2_break, cmp_brk.old_in_new.witness, false)

	// 3. `schema.sample`: generate 5 valid samples from DDL description and validate every one!
	samples, serr := schema.sample(&d1, {seed = 42, count = 5})
	defer schema.error_destroy(&serr)
	testing.expectf(t, serr.kind == .None, "schema.sample failed: %v %q", serr.kind, serr.message)
	defer {
		for s in samples {
			delete(s)
		}
		delete(samples)
	}
	testing.expect_value(t, len(samples), 5)
	for s in samples {
		expect_json(t, c1, string(s), true)
	}

	// 4. `schema.write_schema`: round-trip DDL -> Draft 2020-12 JSON Schema -> `schema.compile_json`
	js_bytes, werr := schema.write_schema(&d1, {indent = 2})
	defer schema.error_destroy(&werr)
	testing.expect_value(t, werr.kind, schema.Error_Kind.None)
	defer delete(js_bytes)
	js_compiled, jcerr := schema.compile_json(js_bytes, {format_assert = true})
	defer schema.error_destroy(&jcerr)
	testing.expect_value(t, jcerr.kind, schema.Error_Kind.None)
	defer schema.destroy(js_compiled)
	// Every generated sample from DDL passes the round-tripped JSON Schema!
	for s in samples {
		sdoc, sjerr := json.build(s)
		testing.expect(t, sjerr == nil)
		testing.expect(t, schema.valid_document(js_compiled, &sdoc))
		tape.destroy_document(&sdoc)
	}
	// Round-trip structural equivalence on a schema without `FORMAT_PATTERNS` regex expansion:
	plain_sql := "CREATE TABLE items (id INT PRIMARY KEY, name VARCHAR(32) NOT NULL, price NUMERIC(8, 2) NOT NULL);"
	d_plain, e_plain := ddl.compile_description(transmute([]u8)plain_sql)
	defer ddl.error_destroy(&e_plain)
	testing.expect_value(t, e_plain.kind, ddl.Error_Kind.None)
	defer rules.description_destroy(&d_plain)
	js_plain, wp_err := schema.write_schema(&d_plain)
	defer schema.error_destroy(&wp_err)
	testing.expect_value(t, wp_err.kind, schema.Error_Kind.None)
	defer delete(js_plain)
	js_plain_c, jp_err := schema.compile_json(js_plain)
	defer schema.error_destroy(&jp_err)
	testing.expect_value(t, jp_err.kind, schema.Error_Kind.None)
	defer schema.destroy(js_plain_c)
	cmp_rt, _ := schema.compare(&d_plain, js_plain_c.description)
	defer schema.comparison_destroy(&cmp_rt)
	testing.expect_value(t, cmp_rt.old_in_new.verdict, schema.Verdict.Yes)
	testing.expect_value(t, cmp_rt.new_in_old.verdict, schema.Verdict.Yes)

	// 5. `schema.write_odin`: generate Odin types from DDL `rules.Description`
	odin_src, oerr := schema.write_odin(&d1, "db_models", true)
	defer schema.error_destroy(&oerr)
	testing.expectf(t, oerr.kind == .None, "schema.write_odin failed: %v %q %q", oerr.kind, oerr.keyword, oerr.message)
	defer delete(odin_src)
	testing.expect(t, strings.contains(odin_src, "package db_models"))
	testing.expect(t, strings.contains(odin_src, "Accounts :: struct {"))
	testing.expect(t, strings.contains(odin_src, "id: uuid.Identifier"))
	testing.expect(t, strings.contains(odin_src, "created_at: time.Time"))
	testing.expect(t, strings.contains(odin_src, `model.register_extra(reg, Accounts, .Forbid)`))
	testing.expect(t, strings.contains(odin_src, `model.register_default(reg, Accounts, "status",`))
}

@(test)
ddl_errors_and_depth_bound :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// No CREATE TABLE
	empty_sql := "-- only comments\nCREATE INDEX i ON t(a);"
	_, e_empty := ddl.compile_ddl(transmute([]u8)empty_sql)
	defer ddl.error_destroy(&e_empty)
	testing.expect_value(t, e_empty.kind, ddl.Error_Kind.No_Table)

	// Duplicate column
	dup_sql := "CREATE TABLE t (id INT, ID BIGINT);"
	_, e_dup := ddl.compile_ddl(transmute([]u8)dup_sql)
	defer ddl.error_destroy(&e_dup)
	testing.expect_value(t, e_dup.kind, ddl.Error_Kind.Duplicate_Column)
	testing.expect_value(t, e_dup.column, "ID")

	// Unterminated string literal with accurate line:col
	str_sql := "CREATE TABLE t (\n  a TEXT DEFAULT 'unterminated\n);"
	_, e_str := ddl.compile_ddl(transmute([]u8)str_sql)
	defer ddl.error_destroy(&e_str)
	testing.expect_value(t, e_str.kind, ddl.Error_Kind.Syntax)
	testing.expect_value(t, e_str.line, u32(2))
	testing.expect_value(t, e_str.col, u32(18))

	// Unterminated block comment
	cmt_sql := "/* never closed\nCREATE TABLE t (a INT);"
	_, e_cmt := ddl.compile_ddl(transmute([]u8)cmt_sql)
	defer ddl.error_destroy(&e_cmt)
	testing.expect_value(t, e_cmt.kind, ddl.Error_Kind.Syntax)
	testing.expect_value(t, e_cmt.line, u32(1))

	// Trailing comma syntax error
	comma_sql := "CREATE TABLE t (a INT,);"
	_, e_comma := ddl.compile_ddl(transmute([]u8)comma_sql)
	defer ddl.error_destroy(&e_comma)
	testing.expect_value(t, e_comma.kind, ddl.Error_Kind.Syntax)

	// Deeply nested CHECK exceeds `MAX_EXPR_DEPTH` cleanly without overflowing stack
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "CREATE TABLE deep (x INT CHECK (")
	for _ in 0 ..< ddl.MAX_EXPR_DEPTH + 10 {
		strings.write_byte(&b, '(')
	}
	strings.write_string(&b, "x >= 0")
	for _ in 0 ..< ddl.MAX_EXPR_DEPTH + 10 {
		strings.write_byte(&b, ')')
	}
	strings.write_string(&b, "));")
	_, e_depth := ddl.compile_ddl(transmute([]u8)strings.to_string(b))
	defer ddl.error_destroy(&e_depth)
	testing.expect_value(t, e_depth.kind, ddl.Error_Kind.Depth_Limit)
}

@(test)
ddl_oom_sweep_and_guarded :: proc(t: ^testing.T) {
	testkit.deadline(t)

	sql := `
	CREATE TYPE state_t AS ENUM ('new', 'done');
	CREATE TABLE tasks (
		id UUID PRIMARY KEY,
		title VARCHAR(64) NOT NULL CHECK (LENGTH(title) >= 1 AND title <> ''),
		priority SMALLINT NOT NULL DEFAULT 1 CHECK (priority BETWEEN 1 AND 5),
		score NUMERIC(8, 2) CHECK (score < 0 OR score > 10),
		code INT NOT NULL CHECK (NOT (code IN (0, -1))),
		tag TEXT CHECK (tag LIKE 't_%'),
		state state_t NOT NULL DEFAULT 'new',
		owner TEXT,
		CHECK (state = 'done' OR owner IS NOT NULL),
		FOREIGN KEY (owner) REFERENCES users(name)
	);
	`
	// Guarded allocator check (detects any OOB heap writes)
	g: testkit.Guarded
	testkit.guarded_init(&g, context.allocator)
	defer testkit.guarded_destroy(&g)
	ga := testkit.guarded_allocator(&g)
	c, err := ddl.compile_ddl(transmute([]u8)sql, {as_array = true}, ga)
	testing.expect_value(t, err.kind, ddl.Error_Kind.None)
	ddl.error_destroy(&err)
	ddl.destroy(c)
	testing.expect(t, testkit.guarded_check(&g))

	// OOM failure sweep across every single allocation point in `compile_ddl`!
	Ctx :: struct {
		src: []u8,
	}
	ctx := Ctx{src = transmute([]u8)sql}
	sweep := testkit.sweep_failures(proc(data: rawptr, a: runtime.Allocator) {
		p := (^Ctx)(data)
		compiled, cerr := ddl.compile_ddl(p.src, {as_array = true}, a)
		if cerr.kind != .None {
			ddl.error_destroy(&cerr)
			return
		}
		ddl.destroy(compiled)
	}, &ctx, limit = 5000)
	testing.expectf(t, sweep.bad == 0, "OOM sweep found %d leaky/bad-free runs (first_bad=%d, runs=%d, refused=%d)", sweep.bad, sweep.first_bad, sweep.runs, sweep.refused)
	testing.expect(t, sweep.runs > 10)
}

@(test)
ddl_audit_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Repeated leading `UNSIGNED` must fail with `.Syntax` (no recursive stack overflow),
	//    while single leading `UNSIGNED INT` succeeds with [0, 4294967295].
	{
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, "CREATE TABLE t (x ")
		for _ in 0 ..< 256 {
			strings.write_string(&b, "UNSIGNED ")
		}
		strings.write_string(&b, "INT);")
		_, err := ddl.compile_ddl(transmute([]u8)strings.to_string(b))
		defer ddl.error_destroy(&err)
		testing.expect_value(t, err.kind, ddl.Error_Kind.Syntax)

		valid_u := "CREATE TABLE t (x UNSIGNED INT NOT NULL);"
		c := must_compile(t, valid_u)
		defer ddl.destroy(c)
		expect_json(t, c, `{"x": 0}`, true)
		expect_json(t, c, `{"x": 4294967295}`, true)
		expect_json(t, c, `{"x": -1}`, false)
	}

	// 2. Huge `u64` scale in `DECIMAL(38, 18446744073709551516)` must NOT overflow stack buffer,
	//    and negative / fractional / overflowing type parameters must fail with `.Syntax`.
	{
		huge_scale := "CREATE TABLE t (v DECIMAL(38, 18446744073709551516) NOT NULL);"
		c := must_compile(t, huge_scale)
		defer ddl.destroy(c)
		expect_json(t, c, `{"v": 12.34}`, true)

		bad_params := [?]string{
			"CREATE TABLE t (v DECIMAL(10, -2));",
			"CREATE TABLE t (v DECIMAL(10, 99999999999999999999));",
			"CREATE TABLE t (v VARCHAR(10.5));",
			"CREATE TABLE t (v VARCHAR(99999999999999999999));",
			"CREATE TABLE t (v BIT(99999999999999999999));",
		}
		for sql in bad_params {
			_, err := ddl.compile_ddl(transmute([]u8)sql)
			defer ddl.error_destroy(&err)
			testing.expectf(t, err.kind == .Syntax, "expected .Syntax for %q, got %v", sql, err.kind)
		}
	}

	// 3. Nullable `OR` growing `c.d.nodes` across multiple reallocations (ASan + Guarded UAF/double-free regression).
	{
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, "CREATE TABLE wide (\n")
		for i in 0 ..< 40 {
			if i > 0 {
				strings.write_string(&b, ",\n")
			}
			strings.write_string(&b, "  c")
			strings.write_int(&b, i)
			strings.write_string(&b, " INT CHECK (c")
			strings.write_int(&b, i)
			strings.write_string(&b, " < 0 OR c")
			strings.write_int(&b, i)
			strings.write_string(&b, " > 10)")
		}
		strings.write_string(&b, "\n);")
		g: testkit.Guarded
		testkit.guarded_init(&g, context.allocator)
		defer testkit.guarded_destroy(&g)
		c, err := ddl.compile_ddl(transmute([]u8)strings.to_string(b), {}, testkit.guarded_allocator(&g))
		testing.expect_value(t, err.kind, ddl.Error_Kind.None)
		ddl.error_destroy(&err)
		expect_json(t, c, `{"c0": null, "c39": 20}`, true)
		expect_json(t, c, `{"c0": 5}`, false)
		ddl.destroy(c)
		testing.expect(t, testkit.guarded_check(&g))
	}

	// 4. Unsound partial `AND` under `NOT (...)`: must NOT drop unsupported conjunct and over-reject!
	{
		sql := `
		CREATE TABLE t (
			a INT NOT NULL CHECK (NOT (a > 10 AND a + 1 < 20)),
			b INT NOT NULL,
			CHECK (NOT (a = 1 AND a < b))
		);
		`
		c := must_compile(t, sql)
		defer ddl.destroy(c)
		testing.expect_value(t, c.meta.uncompiled_checks, 2)
		// `a = 50` satisfies `NOT (50 > 10 AND 51 < 20)` = `NOT (FALSE)` = TRUE; must NOT be rejected!
		expect_json(t, c, `{"a": 50, "b": 100}`, true)
		// `a = 1, b = 0` satisfies `NOT (1 = 1 AND 1 < 0)` = TRUE; must NOT be rejected!
		expect_json(t, c, `{"a": 1, "b": 0}`, true)
	}

	// 5. SQL 3-valued logic on nullable columns:
	//    5a: multi-column `CHECK (a = 1 OR b > 0)` and `CHECK (NOT (a = 1 AND b > 0))` with nullable `b`
	//    5b: single-column `CHECK (x IS NOT NULL OR x > 0)` accepts `null` (`FALSE OR UNKNOWN = UNKNOWN`)
	//    5c: `CHECK (y IS NOT NULL AND y IN (1, 2))` rejects `null` and leaves no `Null` in `enum_of`
	{
		sql := `
		CREATE TABLE three_vl (
			a INT NOT NULL,
			b INT,
			x INT CHECK (x IS NOT NULL OR x > 0),
			y INT CHECK (y IS NOT NULL AND y IN (1, 2)),
			CHECK (a = 1 OR b > 0)
		);
		`
		c := must_compile(t, sql)
		defer ddl.destroy(c)

		// 5a: `{"a": 2, "b": null}` and `{"a": 2}` satisfy `a = 1 OR b > 0` (`FALSE OR UNKNOWN = UNKNOWN`)
		expect_json(t, c, `{"a": 2, "b": null, "x": null, "y": 1}`, true)
		expect_json(t, c, `{"a": 2, "x": -5, "y": 2}`, true)
		expect_json(t, c, `{"a": 1, "b": -5, "y": 1}`, true)
		expect_json(t, c, `{"a": 2, "b": 5, "y": 1}`, true)
		// `FALSE OR FALSE = FALSE` fails
		expect_json(t, c, `{"a": 2, "b": -5, "y": 1}`, false)

		// 5c: `y` rejects `null` and `3`, and its `enum_of` has no `rules.Null`
		expect_json(t, c, `{"a": 1, "y": null}`, false)
		expect_json(t, c, `{"a": 1, "y": 3}`, false)
		row_obj := &c.description.objects[c.description.nodes[c.description.root].object]
		y_node := &c.description.nodes[row_obj.members[3].node]
		testing.expect_value(t, len(y_node.enum_of), 2)

		// 5a negative polarity: `CHECK (NOT (a = 1 AND b > 0))`
		neg_sql := "CREATE TABLE t_neg (a INT NOT NULL, b INT, CHECK (NOT (a = 1 AND b > 0)));"
		cn := must_compile(t, neg_sql)
		defer ddl.destroy(cn)
		expect_json(t, cn, `{"a": 1, "b": null}`, true)
		expect_json(t, cn, `{"a": 1}`, true)
		expect_json(t, cn, `{"a": 1, "b": -5}`, true)
		expect_json(t, cn, `{"a": 2, "b": 5}`, true)
		expect_json(t, cn, `{"a": 1, "b": 5}`, false)

		// 5a negative polarity with negated atoms (`NOT IN`, `<>`) on nullable column:
		// `{"a": 1, "b": null}` -> `NOT (TRUE AND UNKNOWN) = UNKNOWN` (valid in SQL!).
		neg_in_sql := "CREATE TABLE t_neg_in (a INT NOT NULL, b INT, CHECK (NOT (a = 1 AND b NOT IN (1, 2))));"
		cni := must_compile(t, neg_in_sql)
		defer ddl.destroy(cni)
		expect_json(t, cni, `{"a": 1, "b": null}`, true)
		expect_json(t, cni, `{"a": 1, "b": 1}`, true)
		expect_json(t, cni, `{"a": 1, "b": 3}`, false)

		neg_ne_sql := "CREATE TABLE t_neg_ne (a INT NOT NULL, b TEXT, CHECK (NOT (a = 1 AND b <> 'admin')));"
		cnn := must_compile(t, neg_ne_sql)
		defer ddl.destroy(cnn)
		expect_json(t, cnn, `{"a": 1, "b": null}`, true)
		expect_json(t, cnn, `{"a": 1, "b": "admin"}`, true)
		expect_json(t, cnn, `{"a": 1, "b": "guest"}`, false)
	}

	// 6. `LIKE` matches newlines (`[\s\S]`) and escapes regex metacharacters,
	//    and PostgreSQL `E'...'` decodes `\'`, `\\`, `\n`, `\r`, `\t`.
	{
		sql := `
		CREATE TABLE text_rules (
			bio TEXT NOT NULL CHECK (bio LIKE 'a.b%c_d'),
			quote TEXT NOT NULL CHECK (quote = E'it\'s\nline\\2\tend')
		);
		`
		c := must_compile(t, sql)
		defer ddl.destroy(c)
		expect_json(t, c, `{"bio": "a.b\nmulti\nline\nc\nd", "quote": "it's\nline\\2\tend"}`, true)
		// `.` in LIKE pattern must match literal `.` only, not arbitrary char `X`
		expect_json(t, c, `{"bio": "aXb\nc\nd", "quote": "it's\nline\\2\tend"}`, false)
		expect_json(t, c, `{"bio": "a.bcXd", "quote": "wrong"}`, false)
	}

	// 7. `BIGINT UNSIGNED DEFAULT 18446744073709551615` keeps `default_of`,
	//    and table qualifier verification accepts `t.val >= 0` while rejecting foreign `other.val >= 0`.
	{
		sql := `
		CREATE TABLE edge_t (
			big BIGINT UNSIGNED NOT NULL DEFAULT 18446744073709551615,
			val INT NOT NULL CHECK (edge_t.val >= 0),
			CHECK (other.val >= 100)
		);
		`
		c := must_compile(t, sql)
		defer ddl.destroy(c)
		testing.expect_value(t, c.meta.uncompiled_checks, 1)
		row_obj := &c.description.objects[c.description.nodes[c.description.root].object]
		big_node := &c.description.nodes[row_obj.members[0].node]
		testing.expect(t, big_node.default_of != nil)
		// `edge_t.val >= 0` enforced; foreign `other.val >= 100` skipped (not applied to `val`!)
		expect_json(t, c, `{"val": 5}`, true)
		expect_json(t, c, `{"val": -1}`, false)
	}
}
