// v2 upgrades test suite:
// 1. Native `load_document` & `load_value` across JSON, TOML, XML, CBOR, DSV, and programmatic `rules.Value` (zero serialize-reparse!).
// 2. >128-field Odin struct (200 fields!): compile, schema, load, was_set, validate, dump, patch, zero memory leaks.
// 3. Deep `patch` inside `Maybe(struct)` (closing the v1 gap!): recursive partial patch preserving sibling fields,
//    `null` clearing `Maybe`, `nil` destination populated with defaults + patched fields, transactional rollback, zero leaks.
package model_test

import "base:runtime"
import "core:io"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/check"
import "stury:lib/schema/model"
import "stury:lib/schema/rules"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

// ============================================================================
// 1. Native `load_document` & `load_value` across ALL 5 formats (JSON, TOML, XML, CBOR, DSV)
// ============================================================================

@(test)
native_load_document_and_load_value_multi_format :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Config :: struct {
		name:    string `model:"len>=2"`,
		port:    u16 `model:">=1,<=65535"`,
		enabled: bool,
		tags:    []string `model:"optional"`,
		set:     model.Fields_Set,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, Config, "enabled", true)

	m, cerr := model.compile(&reg, Config)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// (A) JSON `tape.Document` -> `load_document`
	{
		doc, berr := json.build(transmute([]u8)string(`{"name":"api","port":8080,"tags":["v2","fast"]}`))
		defer tape.destroy(&doc)
		testing.expect_value(t, berr, nil)

		c: Config
		defer model.free_value(&c, type_info_of(Config), context.allocator)
		testing.expect_value(t, model.load_document(&m, &doc, &c), nil)
		testing.expect(t, c.name == "api" && c.port == 8080 && c.enabled && len(c.tags) == 2 && c.tags[1] == "fast")
		testing.expect(t, model.was_set(&m, Config, c.set, "name") && !model.was_set(&m, Config, c.set, "enabled"))
	}

	// (B) TOML `tape.Document` -> `load_document`
	{
		toml_src := "name = \"worker\"\nport = 9000\ntags = [\"toml\"]\n"
		doc, berr := toml.build(transmute([]u8)toml_src)
		defer tape.destroy(&doc)
		testing.expect_value(t, berr, nil)

		c: Config
		defer model.free_value(&c, type_info_of(Config), context.allocator)
		testing.expect_value(t, model.load_document(&m, &doc, &c), nil)
		testing.expect(t, c.name == "worker" && c.port == 9000 && c.enabled && len(c.tags) == 1 && c.tags[0] == "toml")
	}

	// (C) CBOR `tape.Document` -> `load_document` (encoded from a dumped document!)
	{
		orig := Config{name = "cbor-svc", port = 443, enabled = false, tags = {"bin"}}
		ddoc, derr := model.dump_document(&m, &orig)
		defer tape.destroy(&ddoc)
		testing.expect_value(t, derr, nil)

		cbor_bytes, _, werr := cbor.write(&ddoc)
		defer delete(cbor_bytes)
		testing.expect_value(t, werr, nil)

		cdoc, berr := cbor.build(cbor_bytes)
		defer tape.destroy(&cdoc)
		testing.expect_value(t, berr, nil)

		c: Config
		defer model.free_value(&c, type_info_of(Config), context.allocator)
		testing.expect_value(t, model.load_document(&m, &cdoc, &c), nil)
		testing.expect(t, c.name == "cbor-svc" && c.port == 443 && !c.enabled && len(c.tags) == 1 && c.tags[0] == "bin")
	}

	// (D) XML `tape.Document` -> `load_document` (with Xml_Options{infer = true}!)
	{
		Xml_Item :: struct {
			name: string `model:"len>=2"`,
			port: u16 `model:">=1"`,
		}
		Xml_Root :: struct {
			config: Xml_Item,
		}
		xm, xerr := model.compile(nil, Xml_Root)
		defer model.destroy(&xm)
		testing.expect_value(t, xerr, nil)

		xml_src := `<config><name>edge</name><port>8443</port></config>`
		xdoc, berr := xml.build(transmute([]u8)xml_src, .Xml, {format = tape.Xml_Options{infer = true}})
		defer tape.destroy(&xdoc)
		testing.expect_value(t, berr, nil)

		xr: Xml_Root
		defer model.free_value(&xr, type_info_of(Xml_Root), context.allocator)
		testing.expect_value(t, model.load_document(&xm, &xdoc, &xr), nil)
		testing.expect(t, xr.config.name == "edge" && xr.config.port == 8443)
	}

	// (E) DSV (CSV) `tape.Document` -> `load_document` (slice of structs!)
	{
		Row :: struct {
			name: string `model:"len>=2"`,
			age:  int `model:">=18"`,
		}
		rm, rerr := model.compile(nil, []Row)
		defer model.destroy(&rm)
		testing.expect_value(t, rerr, nil)

		csv_src := "name,age\nada,36\nbob,25\n"
		cdoc, berr := dsv.build(transmute([]u8)csv_src, .Csv, {format = tape.Dsv_Options{infer = true}})
		defer tape.destroy(&cdoc)
		testing.expect_value(t, berr, nil)

		rows: []Row
		defer model.free_value(&rows, type_info_of([]Row), context.allocator)
		testing.expect_value(t, model.load_document(&rm, &cdoc, &rows), nil)
		testing.expect_value(t, len(rows), 2)
		testing.expect(t, rows[0].name == "ada" && rows[0].age == 36 && rows[1].name == "bob" && rows[1].age == 25)

		// Invalid CSV row caught with accurate row/field pointer!
		bad_csv := "name,age\nada,10\n"
		bdoc, berr2 := dsv.build(transmute([]u8)bad_csv, .Csv, {format = tape.Dsv_Options{infer = true}})
		defer tape.destroy(&bdoc)
		testing.expect_value(t, berr2, nil)
		sink: model.Sink
		defer model.destroy(&sink)
		bad_rows: []Row
		defer model.free_value(&bad_rows, type_info_of([]Row), context.allocator)
		testing.expect(t, model.load_document(&rm, &bdoc, &bad_rows, &sink) != nil)
		testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Below_Minimum && sink.entries[0].pointer == "/0/age")
	}

	// (F) Programmatic in-memory `rules.Value` -> `load_value` (ZERO serialize-reparse!)
	{
		tags_val := []rules.Value{rules.Value("mem"), rules.Value("zero-copy")}
		val := rules.Value([]rules.Member_Value{
			{key = "name", value = "inmem"},
			{key = "port", value = i64(3000)},
			{key = "tags", value = tags_val},
		})
		c: Config
		defer model.free_value(&c, type_info_of(Config), context.allocator)
		testing.expect_value(t, model.load_value(&m, val, &c), nil)
		testing.expect(t, c.name == "inmem" && c.port == 3000 && c.enabled && len(c.tags) == 2 && c.tags[0] == "mem")
	}
}

// ============================================================================
// 2. >128-field struct test (200 fields!): compile, describe, load, was_set, validate, dump, patch
// ============================================================================

@(private = "file")
Wide_200 :: struct {
	f000, f001, f002, f003, f004, f005, f006, f007, f008, f009: int `model:">=0,optional"`,
	f010, f011, f012, f013, f014, f015, f016, f017, f018, f019: int `model:">=0,optional"`,
	f020, f021, f022, f023, f024, f025, f026, f027, f028, f029: int `model:">=0,optional"`,
	f030, f031, f032, f033, f034, f035, f036, f037, f038, f039: int `model:">=0,optional"`,
	f040, f041, f042, f043, f044, f045, f046, f047, f048, f049: int `model:">=0,optional"`,
	f050, f051, f052, f053, f054, f055, f056, f057, f058, f059: int `model:">=0,optional"`,
	f060, f061, f062, f063, f064, f065, f066, f067, f068, f069: int `model:">=0,optional"`,
	f070, f071, f072, f073, f074, f075, f076, f077, f078, f079: int `model:">=0,optional"`,
	f080, f081, f082, f083, f084, f085, f086, f087, f088, f089: int `model:">=0,optional"`,
	f090, f091, f092, f093, f094, f095, f096, f097, f098, f099: int `model:">=0,optional"`,
	f100, f101, f102, f103, f104, f105, f106, f107, f108, f109: int `model:">=0,optional"`,
	f110, f111, f112, f113, f114, f115, f116, f117, f118, f119: int `model:">=0,optional"`,
	f120, f121, f122, f123, f124, f125, f126, f127, f128, f129: int `model:">=0,optional"`,
	f130, f131, f132, f133, f134, f135, f136, f137, f138, f139: int `model:">=0,optional"`,
	f140, f141, f142, f143, f144, f145, f146, f147, f148, f149: int `model:">=0,optional"`,
	f150, f151, f152, f153, f154, f155, f156, f157, f158, f159: int `model:">=0,optional"`,
	f160, f161, f162, f163, f164, f165, f166, f167, f168, f169: int `model:">=0,optional"`,
	f170, f171, f172, f173, f174, f175, f176, f177, f178, f179: int `model:">=0,optional"`,
	f180, f181, f182, f183, f184, f185, f186, f187, f188, f189: int `model:">=0,optional"`,
	f190, f191, f192, f193, f194, f195, f196, f197, f198:       int `model:">=0,optional"`,
	f199:                                                       string `model:"len>=2"`,
	set:                                                        model.Fields_Set,
}

@(test)
wide_200_field_struct_load_validate_dump_schema_and_patch :: proc(t: ^testing.T) {
	testkit.deadline(t)
	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, Wide_200, "f150", 777)

	m, cerr := model.compile(&reg, Wide_200)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	// Schema description & compiled check plan work on 200 fields!
	desc, serr := model.schema(&m, .Load)
	defer rules.description_destroy(&desc)
	testing.expect_value(t, serr, nil)
	cp, cperr := check.compile(&desc)
	defer check.plan_destroy(&cp)
	testing.expect_value(t, cperr.kind, rules.Error_Kind.None)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)

	{
		w: Wide_200
		defer model.free_value(&w, type_info_of(Wide_200), a)

		body := `{"f000":1,"f063":63,"f064":64,"f127":127,"f128":128,"f130":130,"f199":"hello"}`
		res := json.check(transmute([]u8)body, &cp)
		defer check.result_destroy(&res)
		testing.expect(t, res.valid)

		testing.expect_value(t, model.load(&m, transmute([]u8)body, json.as(.Json), json.reads(.Json), &w, allocator = a), nil)
		testing.expect(t, w.f000 == 1 && w.f063 == 63 && w.f064 == 64 && w.f127 == 127 && w.f128 == 128 && w.f130 == 130 && w.f150 == 777 && w.f199 == "hello")

		// `was_set` works seamlessly across the 64-bit and 128-bit boundaries up to field 199!
		testing.expect(t, model.was_set(&m, Wide_200, w.set, "f000"))
		testing.expect(t, model.was_set(&m, Wide_200, w.set, "f063"))
		testing.expect(t, model.was_set(&m, Wide_200, w.set, "f064"))
		testing.expect(t, model.was_set(&m, Wide_200, w.set, "f127"))
		testing.expect(t, model.was_set(&m, Wide_200, w.set, "f128"))
		testing.expect(t, model.was_set(&m, Wide_200, w.set, "f130"))
		testing.expect(t, !model.was_set(&m, Wide_200, w.set, "f150"))
		testing.expect(t, model.was_set(&m, Wide_200, w.set, "f199"))

		// Dump with `exclude_unset` writes ONLY the explicitly set fields (including >128)!
		dumped, derr := model.dump(&m, &w, write_json_default, {exclude_unset = true, check = true}, allocator = a)
		defer delete(dumped, a)
		testing.expect_value(t, derr, nil)
		testing.expect_value(t, string(dumped), body)

		// Patch field 198 & 199 while preserving f000, f128, f130, f150!
		testing.expect_value(t, model.patch(&m, &w, transmute([]u8)string(`{"f198":999,"f199":"world"}`), json.as(.Json), json.reads(.Json), allocator = a), nil)
		testing.expect(t, w.f000 == 1 && w.f128 == 128 && w.f130 == 130 && w.f150 == 777 && w.f198 == 999 && w.f199 == "world")
		testing.expect(t, model.was_set(&m, Wide_200, w.set, "f198") && model.was_set(&m, Wide_200, w.set, "f128"))

		// Failing patch on field 199 rolls back cleanly without leaking!
		perr := model.patch(&m, &w, transmute([]u8)string(`{"f198":111,"f199":"x"}`), json.as(.Json), json.reads(.Json), allocator = a)
		testing.expect(t, perr != nil)
		model.error_destroy(perr, a)
		testing.expect(t, w.f198 == 999 && w.f199 == "world")

		// Validate catches negative value on field 198.
		w.f198 = -5
		sink: model.Sink
		defer model.destroy(&sink)
		testing.expect(t, model.validate(&m, &w, &sink) != nil)
		testing.expect(t, len(sink.entries) == 1 && sink.entries[0].kind == .Below_Minimum && sink.entries[0].pointer == "/f198")
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// ============================================================================
// 3. Deep `patch` inside `Maybe(struct)` test (closing v1 gap!)
// ============================================================================

@(test)
patch_inside_maybe_struct_recursive_null_and_nil_init :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Geo :: struct {
		lat: f64 `model:"-90..=90"`,
		lon: f64 `model:"-180..=180"`,
	}
	Address :: struct {
		city:    string `model:"len>=2"`,
		zip:     int `model:">=0"`,
		country: string,
		geo:     Maybe(Geo) `model:"optional"`,
		set:     model.Fields_Set,
	}
	Profile :: struct {
		name:  string `model:"len>=2"`,
		addr:  Maybe(Address) `model:"optional"`,
		extra: map[string]string `json:",unknown"`,
		set:   model.Fields_Set,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, Address, "country", "US")
	_ = model.register(&reg, Address, "zip", 10001)

	m, cerr := model.compile(&reg, Profile)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)

	{
		p: Profile
		defer model.free_value(&p, type_info_of(Profile), a)

		// Initial load with populated `Maybe(Address)` and nested `Maybe(Geo)`.
		init_body := `{"name":"ada","addr":{"city":"Paris","zip":75001,"country":"FR","geo":{"lat":48.85,"lon":2.35}},"role":"admin"}`
		testing.expect_value(t, model.load(&m, transmute([]u8)init_body, json.as(.Json), json.reads(.Json), &p, allocator = a), nil)
		testing.expect(t, p.addr != nil && p.addr.?.city == "Paris" && p.addr.?.zip == 75001 && p.addr.?.country == "FR")
		testing.expect(t, p.addr.?.geo != nil && p.addr.?.geo.?.lat == 48.85 && p.addr.?.geo.?.lon == 2.35)

		// (1) Partial patch inside `Maybe(Address)` updates ONLY `zip` and nested `geo.lon`,
		// preserving `city = "Paris"`, `country = "FR"`, and `geo.lat = 48.85`!
		patch1 := `{"addr":{"zip":75002,"geo":{"lon":2.40}},"team":"core"}`
		testing.expect_value(t, model.patch(&m, &p, transmute([]u8)patch1, json.as(.Json), json.reads(.Json), allocator = a), nil)
		testing.expect(t, p.name == "ada")
		testing.expect(t, p.addr != nil)
		testing.expect_value(t, p.addr.?.city, "Paris")
		testing.expect_value(t, p.addr.?.zip, 75002)
		testing.expect_value(t, p.addr.?.country, "FR")
		testing.expect(t, p.addr.?.geo != nil)
		testing.expect_value(t, p.addr.?.geo.?.lat, f64(48.85))
		testing.expect_value(t, p.addr.?.geo.?.lon, f64(2.40))
		testing.expect(t, p.extra["role"] == "admin" && p.extra["team"] == "core")
		testing.expect(t, model.was_set(&m, Address, p.addr.?.set, "city") && model.was_set(&m, Address, p.addr.?.set, "zip"))

		// (2) Failing patch inside `Maybe(Address)` rolls back cleanly without touching `p` or leaking memory!
		live_before := len(track.allocation_map)
		bad_patch := `{"addr":{"city":"X","geo":{"lat":999}}}`
		sink: model.Sink
		model.sink_init(&sink, context.allocator)
		defer model.destroy(&sink)
		testing.expect(t, model.patch(&m, &p, transmute([]u8)bad_patch, json.as(.Json), json.reads(.Json), &sink, allocator = a) != nil)
		testing.expect_value(t, len(track.allocation_map), live_before)
		testing.expect_value(t, p.addr.?.city, "Paris")
		testing.expect_value(t, p.addr.?.geo.?.lat, f64(48.85))

		// (3) Patch nested `geo` to `null` clears inner `Maybe(Geo)` while preserving `Address`!
		testing.expect_value(t, model.patch(&m, &p, transmute([]u8)string(`{"addr":{"geo":null}}`), json.as(.Json), json.reads(.Json), allocator = a), nil)
		testing.expect(t, p.addr != nil && p.addr.?.city == "Paris" && p.addr.?.geo == nil)

		// (4) Patch `addr` to `null` clears `Maybe(Address)` to `nil` and frees its old strings!
		testing.expect_value(t, model.patch(&m, &p, transmute([]u8)string(`{"addr":null}`), json.as(.Json), json.reads(.Json), allocator = a), nil)
		testing.expect(t, p.addr == nil)

		// (5) Destination `addr` is `nil`: patching without required `city` is refused and leaves `addr == nil`!
		live_nil := len(track.allocation_map)
		nerr := model.patch(&m, &p, transmute([]u8)string(`{"addr":{"zip":90210}}`), json.as(.Json), json.reads(.Json), allocator = a)
		testing.expect(t, nerr != nil)
		model.error_destroy(nerr, a)
		testing.expect(t, p.addr == nil)
		testing.expect_value(t, len(track.allocation_map), live_nil)

		// (6) Destination `addr` is `nil`: patching with `city` populates `Address` with defaults (`zip=10001`, `country="US"`) + patched `city`!
		testing.expect_value(t, model.patch(&m, &p, transmute([]u8)string(`{"addr":{"city":"NYC"}}`), json.as(.Json), json.reads(.Json), allocator = a), nil)
		testing.expect(t, p.addr != nil && p.addr.?.city == "NYC" && p.addr.?.zip == 10001 && p.addr.?.country == "US")
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
dump_options_and_stream_round_trip :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Note :: struct {
		id:    i64 `model:"read_only"`,
		title: string `model:"len>=2"`,
		body:  Maybe(string) `model:"optional"`,
		level: int,
		pass:  string `model:"write_only,optional"`,
		set:   model.Fields_Set,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, Note, "level", 5)

	m, cerr := model.compile(&reg, Note)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	n: Note
	defer model.free_value(&n, type_info_of(Note), context.allocator)
	testing.expect_value(t, model.load(&m, transmute([]u8)string(`{"title":"hi","pass":"secret"}`), json.as(.Json), json.reads(.Json), &n), nil)
	n.id = 7

	d_all, e1 := model.dump(&m, &n, write_json_default)
	defer delete(d_all)
	testing.expect_value(t, e1, nil)
	testing.expect_value(t, string(d_all), `{"id":7,"title":"hi","body":null,"level":5}`)

	d_none, e2 := model.dump(&m, &n, write_json_default, {exclude_none = true})
	defer delete(d_none)
	testing.expect_value(t, e2, nil)
	testing.expect_value(t, string(d_none), `{"id":7,"title":"hi","level":5}`)

	d_def, e3 := model.dump(&m, &n, write_json_default, {exclude_defaults = true})
	defer delete(d_def)
	testing.expect_value(t, e3, nil)
	testing.expect_value(t, string(d_def), `{"id":7,"title":"hi"}`)

	// Streaming dump via `dump_stream`.
	b2 := strings.builder_make()
	defer strings.builder_destroy(&b2)
	write_json_to :: proc(w: io.Writer, doc: ^tape.Document, opts: write.Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
		return json.write_to(w, doc, .Json, opts, allocator)
	}
	serr2 := model.dump_stream(strings.to_writer(&b2), &m, &n, write_json_to, {exclude_none = true})
	testing.expect_value(t, serr2, nil)
	testing.expect_value(t, strings.to_string(b2), string(d_none))

	// `dump` with `check = true` refuses an invalid value as `.Check_Failed` and writes nothing.
	bad := Note{title = "a"}
	sink: model.Sink
	defer model.destroy(&sink)
	d_bad, bad_err := model.dump(&m, &bad, write_json_default, {check = true}, sink = &sink)
	testing.expect(t, d_bad == nil)
	me, ok := bad_err.(model.Model_Error)
	testing.expect(t, ok && me.kind == .Check_Failed && me.want.text == "too_short")
	testing.expect_value(t, len(sink.entries), 1)
}

@(test)
enum_rules_bit_sets_and_extra_collision :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Color :: enum u8 {
		Red,
		Dark_Green,
		Blue,
	}
	Status :: enum i16 {
		Ok  = 200,
		Bad = 400,
	}
	Flags :: bit_set[Color]
	Item :: struct {
		color:  Color,
		status: Status,
		flags:  Flags `model:"len>=1,optional"`,
		extra:  map[string]int `json:",unknown"`,
	}

	reg: model.Registry
	defer model.destroy(&reg)
	_ = model.register(&reg, model.Naming{enum_members = .Kebab})
	_ = model.register(&reg, model.Enum_Rule{type = Color, renames = {{member = "Red", name = "crimson"}}})
	_ = model.register(&reg, model.Enum_Rule{type = Status, by_number = true})

	m, cerr := model.compile(&reg, Item)
	defer model.destroy(&m)
	testing.expect_value(t, cerr, nil)

	v: Item
	defer model.free_value(&v, type_info_of(Item), context.allocator)
	src := `{"color":"crimson","status":200,"flags":["dark-green","blue"],"bonus":9}`
	testing.expect_value(t, model.load(&m, transmute([]u8)src, json.as(.Json), json.reads(.Json), &v), nil)
	testing.expect(t, v.color == .Red && v.status == .Ok && v.flags == {.Dark_Green, .Blue} && v.extra["bonus"] == 9)

	dumped, derr := model.dump(&m, &v, write_json_default, {check = true})
	defer delete(dumped)
	testing.expect_value(t, derr, nil)
	testing.expect_value(t, string(dumped), src)

	// Colliding extra key is refused on both `validate` and `dump`.
	v.extra["color"] = 1
	defer delete_key(&v.extra, "color")
	verr := model.validate(&m, &v)
	defer model.error_destroy(verr)
	testing.expect(t, verr != nil)
	d2, derr2 := model.dump(&m, &v, write_json_default)
	defer delete(d2)
	defer model.error_destroy(derr2)
	testing.expect(t, derr2 != nil)
}
