/*
 * Native C99 / C11 / C++11 shared-library consumer test for libstury (next/capi/stury.h).
 *
 * Exercises every exported symbol in stury.h, ABI struct layout invariants,
 * multi-format validation/building/writing/transcoding (JSON, JSONC, JSON5, TOML, XML, CSV, CBOR),
 * lossless overlay editing with arena resets, JSON Schema 2020-12 streaming checks,
 * jq and RFC 9535 JSONPath callbacks (including early stop, halt, runtime error, and budgets),
 * and NULL-arena / NULL-pointer / SIZE_MAX overflow safety.
 */

#include "../stury.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                              \
    do {                                                                         \
        g_checks += 1;                                                           \
        if (!(cond)) {                                                           \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);      \
            g_failures += 1;                                                     \
        }                                                                        \
    } while (0)

#define CHECK_EQ_U64(got, want)                                                  \
    do {                                                                         \
        uint64_t _g = (uint64_t)(got);                                           \
        uint64_t _w = (uint64_t)(want);                                          \
        g_checks += 1;                                                           \
        if (_g != _w) {                                                          \
            fprintf(stderr, "FAIL %s:%d: %s == %llu, want %llu\n",               \
                    __FILE__, __LINE__, #got,                                    \
                    (unsigned long long)_g, (unsigned long long)_w);             \
            g_failures += 1;                                                     \
        }                                                                        \
    } while (0)

static const uint8_t *u8_ptr(const char *s) {
    return (const uint8_t *)s;
}

static bool bytes_eq(const uint8_t *buf, size_t len, const char *lit) {
    size_t want = strlen(lit);
    return buf != NULL && len == want && memcmp(buf, lit, want) == 0;
}

static bool bytes_contains(const uint8_t *buf, size_t len, const char *needle) {
    size_t nlen = strlen(needle);
    size_t i;
    if (buf == NULL || nlen == 0 || nlen > len) {
        return false;
    }
    for (i = 0; i + nlen <= len; i += 1) {
        if (memcmp(buf + i, needle, nlen) == 0) {
            return true;
        }
    }
    return false;
}

/* -------------------------------------------------------------------------
 * 1. ABI layout and sentinel invariants
 * ------------------------------------------------------------------------- */
static void test_abi_layout(void) {
    CHECK_EQ_U64(sizeof(stury_err_t), 24);
    CHECK_EQ_U64(offsetof(stury_err_t, code), 0);
    CHECK_EQ_U64(offsetof(stury_err_t, at), 8);
    CHECK_EQ_U64(offsetof(stury_err_t, message), 16);

    CHECK_EQ_U64(sizeof(stury_budget_t), 32);
    CHECK_EQ_U64(offsetof(stury_budget_t, depth), 0);
    CHECK_EQ_U64(offsetof(stury_budget_t, nodes), 4);
    CHECK_EQ_U64(offsetof(stury_budget_t, memory), 8);
    CHECK_EQ_U64(offsetof(stury_budget_t, steps), 16);
    CHECK_EQ_U64(offsetof(stury_budget_t, expansion), 24);

    CHECK_EQ_U64(sizeof(stury_format_t), 4);
    CHECK_EQ_U64(sizeof(stury_caps_t), 4);
    CHECK_EQ_U64(sizeof(stury_facts_t), 2);
    CHECK_EQ_U64(sizeof(stury_err_code_t), 4);

    CHECK_EQ_U64(STURY_NO_BYTE, UINT64_MAX);
    CHECK_EQ_U64(STURY_ROOT, 0);
    CHECK_EQ_U64(STURY_NO_NODE, UINT32_MAX);
}

/* -------------------------------------------------------------------------
 * 2. Arena lifecycle & format lookup / detection / capabilities / facts
 * ------------------------------------------------------------------------- */
static void test_arena_and_formats(void) {
    stury_arena_t *a = stury_arena_new();
    CHECK(a != NULL);
    stury_arena_reset(a);
    stury_arena_free(a);

    /* Format by name */
    CHECK_EQ_U64(stury_format_by_name("json", 4), STURY_FORMAT_JSON);
    CHECK_EQ_U64(stury_format_by_name("jsonc", 5), STURY_FORMAT_JSONC);
    CHECK_EQ_U64(stury_format_by_name("json5", 5), STURY_FORMAT_JSON5);
    CHECK_EQ_U64(stury_format_by_name("TOML", 4), STURY_FORMAT_TOML_1_0);
    CHECK_EQ_U64(stury_format_by_name("xml", 3), STURY_FORMAT_XML);
    CHECK_EQ_U64(stury_format_by_name("csv", 3), STURY_FORMAT_CSV);
    CHECK_EQ_U64(stury_format_by_name("tsv", 3), STURY_FORMAT_TSV);
    CHECK_EQ_U64(stury_format_by_name("cbor", 4), STURY_FORMAT_CBOR);
    CHECK_EQ_U64(stury_format_by_name("unknown_fmt", 11), STURY_FORMAT_UNKNOWN);
    CHECK_EQ_U64(stury_format_by_name("", 0), STURY_FORMAT_UNKNOWN);
    CHECK_EQ_U64(stury_format_by_name(NULL, 4), STURY_FORMAT_UNKNOWN);
    CHECK_EQ_U64(stury_format_by_name("json", SIZE_MAX), STURY_FORMAT_UNKNOWN);

    /* Format of path */
    CHECK_EQ_U64(stury_format_of_path("dir/config.json.gz", 18), STURY_FORMAT_JSON);
    CHECK_EQ_U64(stury_format_of_path("settings.toml", 13), STURY_FORMAT_TOML_1_0);
    CHECK_EQ_U64(stury_format_of_path("doc.xml", 7), STURY_FORMAT_XML);
    CHECK_EQ_U64(stury_format_of_path("rows.csv", 8), STURY_FORMAT_CSV);
    CHECK_EQ_U64(stury_format_of_path("blob.cbor", 9), STURY_FORMAT_CBOR);
    CHECK_EQ_U64(stury_format_of_path("noext", 5), STURY_FORMAT_UNKNOWN);
    CHECK_EQ_U64(stury_format_of_path(NULL, 5), STURY_FORMAT_UNKNOWN);

    /* Format content detection */
    {
        const char *j = "{\"hello\":1}";
        const char *x = "<root><a/></root>";
        const uint8_t cbor_bytes[4] = {0xA1, 0x61, 'k', 0x05};
        CHECK_EQ_U64(stury_format_detect(u8_ptr(j), strlen(j)), STURY_FORMAT_JSON);
        CHECK_EQ_U64(stury_format_detect(u8_ptr(x), strlen(x)), STURY_FORMAT_XML);
        CHECK_EQ_U64(stury_format_detect(cbor_bytes, sizeof(cbor_bytes)), STURY_FORMAT_CBOR);
        CHECK_EQ_U64(stury_format_detect(NULL, 4), STURY_FORMAT_UNKNOWN);
        CHECK_EQ_U64(stury_format_detect(u8_ptr(j), 0), STURY_FORMAT_UNKNOWN);
    }

    /* Capabilities & facts bitmasks */
    {
        stury_caps_t cbor_caps = stury_format_caps(STURY_FORMAT_CBOR);
        stury_facts_t xml_facts = stury_format_facts(STURY_FORMAT_XML);
        stury_facts_t jsonc_facts = stury_format_facts(STURY_FORMAT_JSONC);
        stury_facts_t json_facts = stury_format_facts(STURY_FORMAT_JSON);

        CHECK((cbor_caps & STURY_CAP_BINARY) != 0);
        CHECK((xml_facts & STURY_FACT_ATTRIBUTE) != 0);
        CHECK((xml_facts & STURY_FACT_COMMENT) != 0);
        CHECK((jsonc_facts & STURY_FACTS_COMMENTS) != 0);
        CHECK_EQ_U64(json_facts, 0);
        CHECK_EQ_U64(stury_format_caps(STURY_FORMAT_UNKNOWN), 0);
        CHECK_EQ_U64(stury_format_facts(STURY_FORMAT_UNKNOWN), 0);
    }
}

/* -------------------------------------------------------------------------
 * 3. Validate, build, inspect, write, and cross-format conversion
 * ------------------------------------------------------------------------- */
static void test_validate_build_write_convert(void) {
    stury_arena_t *a = stury_arena_new();
    CHECK(a != NULL);

    /* Validate JSONC, build, inspect facts & node count, write to JSON */
    {
        const char *jc = "// header\n{\"a\":1,\"b\":[2,3]}\n";
        stury_err_t verr = stury_validate(a, u8_ptr(jc), strlen(jc), STURY_FORMAT_JSONC, NULL);
        CHECK_EQ_U64(verr.code, STURY_OK);
        CHECK(verr.message == NULL);

        stury_doc_t *doc = NULL;
        stury_err_t berr = stury_build(a, u8_ptr(jc), strlen(jc), STURY_FORMAT_JSONC, NULL, &doc);
        CHECK_EQ_U64(berr.code, STURY_OK);
        CHECK(doc != NULL);
        CHECK(stury_doc_node_count(doc) >= 5);
        CHECK((stury_doc_facts(doc) & STURY_FACT_COMMENT) != 0);

        uint8_t *out = NULL;
        size_t out_len = 0;
        stury_facts_t dropped = 0;
        stury_err_t werr = stury_write(a, doc, STURY_FORMAT_JSON, &out, &out_len, &dropped);
        CHECK_EQ_U64(werr.code, STURY_OK);
        CHECK(bytes_eq(out, out_len, "{\"a\":1,\"b\":[2,3]}"));
        CHECK((dropped & STURY_FACT_COMMENT) != 0);

        /* Also write JSON5 and TOML from the same built document */
        uint8_t *toml_out = NULL;
        size_t toml_len = 0;
        stury_err_t werr2 = stury_write(a, doc, STURY_FORMAT_TOML_1_0, &toml_out, &toml_len, NULL);
        CHECK_EQ_U64(werr2.code, STURY_OK);
        CHECK(toml_out != NULL && toml_len > 0);
        CHECK_EQ_U64(stury_validate(a, toml_out, toml_len, STURY_FORMAT_TOML_1_0, NULL).code, STURY_OK);

        stury_doc_free(doc);
    }

    stury_arena_reset(a);

    /* Convert across TOML -> JSON -> CBOR -> JSON */
    {
        const char *toml_src = "# top comment\na = 10\nb = \"hi\"\n";
        uint8_t *json_out = NULL;
        size_t json_len = 0;
        stury_facts_t dropped = 0;
        stury_err_t e1 = stury_convert(
            a, u8_ptr(toml_src), strlen(toml_src),
            STURY_FORMAT_TOML_1_0, STURY_FORMAT_JSON,
            NULL, &json_out, &json_len, &dropped);
        CHECK_EQ_U64(e1.code, STURY_OK);
        CHECK(bytes_eq(json_out, json_len, "{\"a\":10,\"b\":\"hi\"}"));
        CHECK((dropped & STURY_FACT_COMMENT) != 0);

        uint8_t *cbor_out = NULL;
        size_t cbor_len = 0;
        stury_err_t e2 = stury_convert(
            a, json_out, json_len,
            STURY_FORMAT_JSON, STURY_FORMAT_CBOR_DETERMINISTIC,
            NULL, &cbor_out, &cbor_len, NULL);
        CHECK_EQ_U64(e2.code, STURY_OK);
        CHECK(cbor_out != NULL && cbor_len > 0);
        CHECK_EQ_U64(stury_validate(a, cbor_out, cbor_len, STURY_FORMAT_CBOR, NULL).code, STURY_OK);

        uint8_t *back_out = NULL;
        size_t back_len = 0;
        stury_err_t e3 = stury_convert(
            a, cbor_out, cbor_len,
            STURY_FORMAT_CBOR, STURY_FORMAT_JSON,
            NULL, &back_out, &back_len, NULL);
        CHECK_EQ_U64(e3.code, STURY_OK);
        CHECK(bytes_eq(back_out, back_len, "{\"a\":10,\"b\":\"hi\"}"));
    }

    /* Convert XML -> JSON and JSON -> XML */
    {
        const char *xml_src = "<root id=\"7\"><name>ada</name></root>";
        uint8_t *json_out = NULL;
        size_t json_len = 0;
        stury_facts_t dropped = 0;
        stury_err_t ex1 = stury_convert(
            a, u8_ptr(xml_src), strlen(xml_src),
            STURY_FORMAT_XML, STURY_FORMAT_JSON,
            NULL, &json_out, &json_len, &dropped);
        CHECK_EQ_U64(ex1.code, STURY_OK);
        CHECK(bytes_contains(json_out, json_len, "\"ada\""));
        CHECK((dropped & STURY_FACT_ATTRIBUTE) != 0);

        const char *j_obj = "{\"root\":{\"name\":\"ada\"}}";
        uint8_t *xml_out = NULL;
        size_t xml_len = 0;
        stury_err_t ex2 = stury_convert(
            a, u8_ptr(j_obj), strlen(j_obj),
            STURY_FORMAT_JSON, STURY_FORMAT_XML,
            NULL, &xml_out, &xml_len, NULL);
        CHECK_EQ_U64(ex2.code, STURY_OK);
        CHECK(bytes_contains(xml_out, xml_len, "<name>ada</name>"));
        CHECK_EQ_U64(stury_validate(a, xml_out, xml_len, STURY_FORMAT_XML, NULL).code, STURY_OK);
    }

    /* Convert CSV -> JSON -> CSV */
    {
        const char *csv_src = "name,age\nada,36\nbob,42\n";
        uint8_t *json_out = NULL;
        size_t json_len = 0;
        stury_err_t ec1 = stury_convert(
            a, u8_ptr(csv_src), strlen(csv_src),
            STURY_FORMAT_CSV, STURY_FORMAT_JSON,
            NULL, &json_out, &json_len, NULL);
        CHECK_EQ_U64(ec1.code, STURY_OK);
        CHECK(bytes_contains(json_out, json_len, "\"ada\""));
        CHECK(bytes_contains(json_out, json_len, "\"bob\""));

        uint8_t *csv_out = NULL;
        size_t csv_len = 0;
        stury_err_t ec2 = stury_convert(
            a, json_out, json_len,
            STURY_FORMAT_JSON, STURY_FORMAT_CSV,
            NULL, &csv_out, &csv_len, NULL);
        CHECK_EQ_U64(ec2.code, STURY_OK);
        CHECK(bytes_contains(csv_out, csv_len, "name,age"));
        CHECK(bytes_contains(csv_out, csv_len, "ada,36"));

        /* Unspellable target: TOML has no null spelling */
        const char *has_null = "{\"a\":null}";
        uint8_t *bad_out = NULL;
        size_t bad_len = 0;
        stury_err_t ec3 = stury_convert(
            a, u8_ptr(has_null), strlen(has_null),
            STURY_FORMAT_JSON, STURY_FORMAT_TOML_1_0,
            NULL, &bad_out, &bad_len, NULL);
        CHECK_EQ_U64(ec3.code, STURY_ERR_UNSPELLABLE);
        CHECK(ec3.message != NULL && ec3.message[0] != '\0');
    }

    /* Syntax error diagnostics with arena AND with NULL arena */
    {
        const char *bad = "{\"a\": }";
        stury_err_t e_arena = stury_validate(a, u8_ptr(bad), strlen(bad), STURY_FORMAT_JSON, NULL);
        CHECK_EQ_U64(e_arena.code, STURY_ERR_SYNTAX);
        CHECK(e_arena.at != STURY_NO_BYTE);
        CHECK(e_arena.message != NULL && e_arena.message[0] != '\0');

        stury_err_t e_null = stury_validate(NULL, u8_ptr(bad), strlen(bad), STURY_FORMAT_JSON, NULL);
        CHECK_EQ_U64(e_null.code, STURY_ERR_SYNTAX);
        CHECK(e_null.at != STURY_NO_BYTE);
        CHECK(e_null.message != NULL && e_null.message[0] != '\0');
    }

    stury_arena_free(a);
}

/* -------------------------------------------------------------------------
 * 4. Lossless overlay editing + arena reset survival
 * ------------------------------------------------------------------------- */
static void test_overlay_and_arena_reset(void) {
    stury_arena_t *a = stury_arena_new();
    CHECK(a != NULL);

    const char *src =
        "{\n"
        "  // keep comment\n"
        "  \"user\": {\"name\": \"old\", \"count\": 1},\n"
        "  \"items\": [10, 20, 30],\n"
        "  \"drop\": true,\n"
        "  \"a/b\": \"orig\",\n"
        "  \"x~y\": \"tilde\"\n"
        "}\n";

    stury_doc_t *doc = NULL;
    CHECK_EQ_U64(stury_build(a, u8_ptr(src), strlen(src), STURY_FORMAT_JSONC, NULL, &doc).code, STURY_OK);
    CHECK(doc != NULL);

    /* Reset arena immediately after build — doc must survive intact! */
    stury_arena_reset(a);
    CHECK(stury_doc_node_count(doc) > 0);
    CHECK((stury_doc_facts(doc) & STURY_FACT_COMMENT) != 0);

    stury_overlay_t *ov = NULL;
    CHECK_EQ_U64(stury_overlay_new(a, doc, &ov).code, STURY_OK);
    CHECK(ov != NULL);

    CHECK_EQ_U64(stury_overlay_set_string(a, ov, "/user/name", 10, "ada", 3).code, STURY_OK);
    CHECK_EQ_U64(stury_overlay_set_int(a, ov, "/user/count", 11, 99).code, STURY_OK);
    CHECK_EQ_U64(stury_overlay_set_raw(a, ov, "/items/1", 8, u8_ptr("[1,2]"), 5).code, STURY_OK);
    CHECK_EQ_U64(stury_overlay_set_string(a, ov, "/a~1b", 5, "slash", 5).code, STURY_OK);
    CHECK_EQ_U64(stury_overlay_set_string(a, ov, "/x~0y", 5, "tilded", 6).code, STURY_OK);
    CHECK_EQ_U64(stury_overlay_del_path(a, ov, "/drop", 5).code, STURY_OK);

    /* Reset arena again before committing! */
    stury_arena_reset(a);

    uint8_t *out1 = NULL;
    size_t len1 = 0;
    stury_facts_t dropped1 = 0;
    CHECK_EQ_U64(
        stury_overlay_commit(a, ov, STURY_FORMAT_UNKNOWN, false, &out1, &len1, &dropped1).code,
        STURY_OK);
    CHECK(bytes_contains(out1, len1, "// keep comment"));
    CHECK(bytes_contains(out1, len1, "\"ada\""));
    CHECK(bytes_contains(out1, len1, "99"));
    CHECK(bytes_contains(out1, len1, "[1,2]"));
    CHECK(bytes_contains(out1, len1, "\"slash\""));
    CHECK(bytes_contains(out1, len1, "\"tilded\""));
    CHECK(!bytes_contains(out1, len1, "\"drop\""));
    CHECK_EQ_U64(dropped1, 0);

    /* Mutate again, reset arena again, commit to strict JSON (drops comments) with reflow=true */
    CHECK_EQ_U64(stury_overlay_set_int(NULL, ov, "/user/count", 11, 100).code, STURY_OK);
    stury_arena_reset(a);

    uint8_t *out2 = NULL;
    size_t len2 = 0;
    stury_facts_t dropped2 = 0;
    CHECK_EQ_U64(
        stury_overlay_commit(a, ov, STURY_FORMAT_JSON, true, &out2, &len2, &dropped2).code,
        STURY_OK);
    CHECK(!bytes_contains(out2, len2, "// keep comment"));
    CHECK(bytes_contains(out2, len2, "100"));
    CHECK((dropped2 & STURY_FACT_COMMENT) != 0);
    CHECK_EQ_U64(stury_validate(a, out2, len2, STURY_FORMAT_JSON, NULL).code, STURY_OK);

    /* Invalid JSON Pointer (missing leading '/') returns STURY_ERR_INVALID_ARG */
    CHECK_EQ_U64(
        stury_overlay_set_int(a, ov, "user/count", 10, 5).code,
        STURY_ERR_INVALID_ARG);
    /* Deleting root or bad tilde escape */
    CHECK_EQ_U64(
        stury_overlay_set_int(a, ov, "/bad~2esc", 9, 5).code,
        STURY_ERR_INVALID_ARG);

    stury_overlay_free(ov);
    stury_arena_reset(a);
    stury_doc_free(doc);
    stury_arena_free(a);
}

/* -------------------------------------------------------------------------
 * 5. JSON Schema 2020-12 compile & streaming multi-format check
 * ------------------------------------------------------------------------- */
static void test_schema(void) {
    stury_arena_t *a = stury_arena_new();
    CHECK(a != NULL);

    const char *schema_src =
        "{\"type\":\"object\",\"required\":[\"name\",\"age\"],"
        "\"properties\":{\"name\":{\"type\":\"string\",\"minLength\":1},"
        "\"age\":{\"type\":\"integer\",\"minimum\":0}}}";

    stury_schema_t *sc = NULL;
    CHECK_EQ_U64(stury_schema_compile(a, u8_ptr(schema_src), strlen(schema_src), &sc).code, STURY_OK);
    CHECK(sc != NULL);

    bool valid = false;
    const char *ok_json = "{\"name\":\"ada\",\"age\":36}";
    CHECK_EQ_U64(
        stury_schema_check(a, sc, u8_ptr(ok_json), strlen(ok_json), STURY_FORMAT_JSON, NULL, &valid).code,
        STURY_OK);
    CHECK(valid);

    /* Check TOML with NULL arena and NULL out_valid */
    const char *ok_toml = "name = \"ada\"\nage = 36\n";
    CHECK_EQ_U64(
        stury_schema_check(NULL, sc, u8_ptr(ok_toml), strlen(ok_toml), STURY_FORMAT_TOML_1_0, NULL, NULL).code,
        STURY_OK);

    /* Check CBOR */
    {
        const uint8_t ok_cbor[16] = {
            0xA2, 0x64, 'n', 'a', 'm', 'e', 0x63, 'a', 'd', 'a',
            0x63, 'a', 'g', 'e', 0x18, 36
        };
        valid = false;
        CHECK_EQ_U64(
            stury_schema_check(a, sc, ok_cbor, sizeof(ok_cbor), STURY_FORMAT_CBOR, NULL, &valid).code,
            STURY_OK);
        CHECK(valid);
    }

    /* Schema violation -> STURY_ERR_SCHEMA_INVALID */
    {
        const char *bad_age = "{\"name\":\"ada\",\"age\":-5}";
        valid = true;
        stury_err_t e = stury_schema_check(a, sc, u8_ptr(bad_age), strlen(bad_age), STURY_FORMAT_JSON, NULL, &valid);
        CHECK_EQ_U64(e.code, STURY_ERR_SCHEMA_INVALID);
        CHECK(!valid);
        CHECK(e.message != NULL && e.message[0] != '\0');
    }

    /* Budget exhaustion -> STURY_ERR_BUDGET */
    {
        stury_schema_t *arr_sc = NULL;
        const char *arr_schema = "{\"type\":\"array\"}";
        const char *nested_arr = "[[[1]]]";
        stury_budget_t b;
        memset(&b, 0, sizeof(b));
        b.steps = 1;
        CHECK_EQ_U64(
            stury_schema_compile(a, u8_ptr(arr_schema), strlen(arr_schema), &arr_sc).code,
            STURY_OK);
        valid = true;
        stury_err_t e = stury_schema_check(
            a, arr_sc, u8_ptr(nested_arr), strlen(nested_arr), STURY_FORMAT_JSON, &b, &valid);
        CHECK_EQ_U64(e.code, STURY_ERR_BUDGET);
        CHECK(!valid);
        stury_schema_free(arr_sc);
    }

    /* Malformed schema -> STURY_ERR_SYNTAX */
    {
        stury_schema_t *bad_sc = (stury_schema_t *)(uintptr_t)0x1;
        const char *malformed = "{not valid json";
        stury_err_t e = stury_schema_compile(NULL, u8_ptr(malformed), strlen(malformed), &bad_sc);
        CHECK_EQ_U64(e.code, STURY_ERR_SYNTAX);
        CHECK(bad_sc == NULL);
        CHECK(e.message != NULL && e.message[0] != '\0');
    }

    stury_schema_free(sc);
    stury_arena_free(a);
}

/* -------------------------------------------------------------------------
 * 6. jq and RFC 9535 JSONPath callbacks, early stop, halt, runtime & budgets
 * ------------------------------------------------------------------------- */
typedef struct emit_collector {
    char   values[16][64];
    char   paths[16][64];
    size_t count;
    size_t path_count;
    size_t stop_after; /* 0 = unlimited */
    bool   saw_non_null_path;
} emit_collector_t;

static bool jq_collect_cb(void *ctx, const uint8_t *bytes, size_t len) {
    emit_collector_t *c = (emit_collector_t *)ctx;
    if (c->count < 16) {
        size_t copy_n = len < 63 ? len : 63;
        if (bytes != NULL && copy_n > 0) {
            memcpy(c->values[c->count], bytes, copy_n);
        }
        c->values[c->count][copy_n] = '\0';
        c->count += 1;
    }
    return c->stop_after == 0 || c->count < c->stop_after;
}

static bool jp_collect_cb(
    void *ctx,
    const uint8_t *bytes,
    size_t len,
    const char *norm_path,
    size_t norm_path_len
) {
    emit_collector_t *c = (emit_collector_t *)ctx;
    if (c->count < 16) {
        size_t copy_n = len < 63 ? len : 63;
        if (bytes != NULL && copy_n > 0) {
            memcpy(c->values[c->count], bytes, copy_n);
        }
        c->values[c->count][copy_n] = '\0';
        c->count += 1;
    }
    if (norm_path != NULL || norm_path_len > 0) {
        c->saw_non_null_path = true;
        if (c->path_count < 16) {
            size_t copy_p = norm_path_len < 63 ? norm_path_len : 63;
            if (norm_path != NULL && copy_p > 0) {
                memcpy(c->paths[c->path_count], norm_path, copy_p);
            }
            c->paths[c->path_count][copy_p] = '\0';
            c->path_count += 1;
        }
    }
    return c->stop_after == 0 || c->count < c->stop_after;
}

static void test_jq_and_jsonpath(void) {
    stury_arena_t *a = stury_arena_new();
    CHECK(a != NULL);

    /* jq: compile, eval, callback emit, early stop, halt, runtime error, step & memory budgets */
    {
        stury_jq_t *prog = NULL;
        CHECK_EQ_U64(stury_jq_compile(a, ".items[]", 8, &prog).code, STURY_OK);
        CHECK(prog != NULL);

        const char *in_json = "{\"items\":[10,20,30]}";
        emit_collector_t col;
        memset(&col, 0, sizeof(col));
        CHECK_EQ_U64(
            stury_jq_eval(a, prog, u8_ptr(in_json), strlen(in_json), STURY_FORMAT_JSON, NULL, jq_collect_cb, &col).code,
            STURY_OK);
        CHECK_EQ_U64(col.count, 3);
        CHECK(strcmp(col.values[0], "10") == 0);
        CHECK(strcmp(col.values[1], "20") == 0);
        CHECK(strcmp(col.values[2], "30") == 0);

        /* Early stop -> STURY_ERR_STOPPED */
        memset(&col, 0, sizeof(col));
        col.stop_after = 1;
        CHECK_EQ_U64(
            stury_jq_eval(a, prog, u8_ptr(in_json), strlen(in_json), STURY_FORMAT_JSON, NULL, jq_collect_cb, &col).code,
            STURY_ERR_STOPPED);
        CHECK_EQ_U64(col.count, 1);

        /* Sinkless eval (emit == NULL) with NULL arena */
        CHECK_EQ_U64(
            stury_jq_eval(NULL, prog, u8_ptr(in_json), strlen(in_json), STURY_FORMAT_JSON, NULL, NULL, NULL).code,
            STURY_OK);

        stury_jq_free(prog);

        /* Explicit halt -> STURY_ERR_HALTED */
        stury_jq_t *halt_prog = NULL;
        CHECK_EQ_U64(stury_jq_compile(NULL, "halt", 4, &halt_prog).code, STURY_OK);
        CHECK_EQ_U64(
            stury_jq_eval(a, halt_prog, u8_ptr("null"), 4, STURY_FORMAT_JSON, NULL, NULL, NULL).code,
            STURY_ERR_HALTED);
        stury_jq_free(halt_prog);

        /* Runtime error -> STURY_ERR_QUERY_RUNTIME */
        stury_jq_t *err_prog = NULL;
        CHECK_EQ_U64(stury_jq_compile(a, "error(\"boom\")", 13, &err_prog).code, STURY_OK);
        stury_err_t rerr = stury_jq_eval(a, err_prog, u8_ptr("null"), 4, STURY_FORMAT_JSON, NULL, NULL, NULL);
        CHECK_EQ_U64(rerr.code, STURY_ERR_QUERY_RUNTIME);
        CHECK(rerr.message != NULL && rerr.message[0] != '\0');
        stury_jq_free(err_prog);

        /* Step budget exhaustion -> STURY_ERR_BUDGET */
        stury_jq_t *loop_prog = NULL;
        CHECK_EQ_U64(stury_jq_compile(a, "range(10000)", 12, &loop_prog).code, STURY_OK);
        stury_budget_t sb;
        memset(&sb, 0, sizeof(sb));
        sb.steps = 5;
        CHECK_EQ_U64(
            stury_jq_eval(a, loop_prog, u8_ptr("null"), 4, STURY_FORMAT_JSON, &sb, NULL, NULL).code,
            STURY_ERR_BUDGET);
        stury_jq_free(loop_prog);

        /* Memory budget exhaustion -> STURY_ERR_BUDGET */
        stury_jq_t *mem_prog = NULL;
        CHECK_EQ_U64(stury_jq_compile(a, "[range(500)]", 12, &mem_prog).code, STURY_OK);
        stury_budget_t mb;
        memset(&mb, 0, sizeof(mb));
        mb.memory = 512;
        CHECK_EQ_U64(
            stury_jq_eval(a, mem_prog, u8_ptr("null"), 4, STURY_FORMAT_JSON, &mb, NULL, NULL).code,
            STURY_ERR_BUDGET);
        stury_jq_free(mem_prog);

        /* Syntax error -> STURY_ERR_SYNTAX */
        stury_jq_t *bad_prog = (stury_jq_t *)(uintptr_t)0x1;
        stury_err_t cerr = stury_jq_compile(a, ".a +", 4, &bad_prog);
        CHECK_EQ_U64(cerr.code, STURY_ERR_SYNTAX);
        CHECK(bad_prog == NULL);
        CHECK(cerr.message != NULL && cerr.message[0] != '\0');
    }

    /* RFC 9535 JSONPath: compile, eval with & without paths, early stop, budget, syntax error */
    {
        stury_jsonpath_t *jp = NULL;
        CHECK_EQ_U64(stury_jsonpath_compile(a, "$.items[*]", 10, &jp).code, STURY_OK);
        CHECK(jp != NULL);

        const char *in_toml = "items = [10, 20, 30]\n";
        emit_collector_t col;
        memset(&col, 0, sizeof(col));
        CHECK_EQ_U64(
            stury_jsonpath_eval(
                a, jp, u8_ptr(in_toml), strlen(in_toml),
                STURY_FORMAT_TOML_1_0, NULL, true, jp_collect_cb, &col).code,
            STURY_OK);
        CHECK_EQ_U64(col.count, 3);
        CHECK(strcmp(col.values[0], "10") == 0);
        CHECK(strcmp(col.values[1], "20") == 0);
        CHECK(strcmp(col.values[2], "30") == 0);
        CHECK_EQ_U64(col.path_count, 3);
        CHECK(strcmp(col.paths[0], "$['items'][0]") == 0);
        CHECK(strcmp(col.paths[1], "$['items'][1]") == 0);
        CHECK(strcmp(col.paths[2], "$['items'][2]") == 0);

        /* want_paths = false + early stop after 2 */
        memset(&col, 0, sizeof(col));
        col.stop_after = 2;
        CHECK_EQ_U64(
            stury_jsonpath_eval(
                NULL, jp, u8_ptr(in_toml), strlen(in_toml),
                STURY_FORMAT_TOML_1_0, NULL, false, jp_collect_cb, &col).code,
            STURY_ERR_STOPPED);
        CHECK_EQ_U64(col.count, 2);
        CHECK(!col.saw_non_null_path);

        /* Memory budget exhaustion -> STURY_ERR_BUDGET */
        {
            stury_budget_t tiny;
            memset(&tiny, 0, sizeof(tiny));
            tiny.memory = 16;
            CHECK_EQ_U64(
                stury_jsonpath_eval(
                    a, jp, u8_ptr(in_toml), strlen(in_toml),
                    STURY_FORMAT_TOML_1_0, &tiny, false, NULL, NULL).code,
                STURY_ERR_BUDGET);
        }

        stury_jsonpath_free(jp);

        /* Syntax error -> STURY_ERR_SYNTAX */
        stury_jsonpath_t *bad_jp = (stury_jsonpath_t *)(uintptr_t)0x1;
        stury_err_t jcerr = stury_jsonpath_compile(NULL, "missing_dollar", 14, &bad_jp);
        CHECK_EQ_U64(jcerr.code, STURY_ERR_SYNTAX);
        CHECK(bad_jp == NULL);
        CHECK(jcerr.message != NULL && jcerr.message[0] != '\0');
    }

    stury_arena_free(a);
}

/* -------------------------------------------------------------------------
 * 7. NULL arena, NULL pointers, overflow lengths, and budget guards
 * ------------------------------------------------------------------------- */
static void test_null_and_overflow_safety(void) {
    stury_arena_t *a = stury_arena_new();
    CHECK(a != NULL);

    /* Free/reset on NULL must be no-ops */
    stury_arena_reset(NULL);
    stury_arena_free(NULL);
    stury_doc_free(NULL);
    stury_schema_free(NULL);
    stury_overlay_free(NULL);
    stury_jq_free(NULL);
    stury_jsonpath_free(NULL);

    CHECK_EQ_U64(stury_doc_facts(NULL), 0);
    CHECK_EQ_U64(stury_doc_node_count(NULL), 0);

    {
        const char *j = "{\"a\":1}";
        stury_doc_t *doc = NULL;
        uint8_t *out = NULL;
        size_t out_len = 0;

        /* NULL arena allowed on stury_build */
        CHECK_EQ_U64(stury_build(NULL, u8_ptr(j), strlen(j), STURY_FORMAT_JSON, NULL, &doc).code, STURY_OK);
        CHECK(doc != NULL);

        /* NULL arena refused on output-allocating calls */
        CHECK_EQ_U64(stury_write(NULL, doc, STURY_FORMAT_JSON, &out, &out_len, NULL).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(
            stury_convert(NULL, u8_ptr(j), strlen(j), STURY_FORMAT_JSON, STURY_FORMAT_TOML_1_0, NULL, &out, &out_len, NULL).code,
            STURY_ERR_INVALID_ARG);

        stury_overlay_t *ov = NULL;
        CHECK_EQ_U64(stury_overlay_new(NULL, doc, &ov).code, STURY_OK);
        CHECK_EQ_U64(
            stury_overlay_commit(NULL, ov, STURY_FORMAT_UNKNOWN, false, &out, &out_len, NULL).code,
            STURY_ERR_INVALID_ARG);
        stury_overlay_free(ov);
        stury_doc_free(doc);
        doc = NULL;

        /* Invalid arguments & SIZE_MAX overflow */
        CHECK_EQ_U64(stury_build(a, u8_ptr(j), strlen(j), STURY_FORMAT_JSON, NULL, NULL).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_build(a, NULL, 5, STURY_FORMAT_JSON, NULL, &doc).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_build(a, u8_ptr(j), SIZE_MAX, STURY_FORMAT_JSON, NULL, &doc).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_build(a, u8_ptr(j), strlen(j), STURY_FORMAT_UNKNOWN, NULL, &doc).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_write(a, NULL, STURY_FORMAT_JSON, &out, &out_len, NULL).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_schema_compile(a, u8_ptr(j), strlen(j), NULL).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_schema_check(a, NULL, u8_ptr(j), strlen(j), STURY_FORMAT_JSON, NULL, NULL).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_overlay_new(a, NULL, NULL).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_overlay_set_raw(a, NULL, NULL, 0, NULL, 0).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_overlay_set_string(a, NULL, NULL, 0, NULL, 0).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_overlay_set_int(a, NULL, NULL, 0, 1).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_overlay_del_path(a, NULL, NULL, 0).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_overlay_commit(a, NULL, STURY_FORMAT_UNKNOWN, false, &out, &out_len, NULL).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_jq_compile(a, j, strlen(j), NULL).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_jq_eval(a, NULL, u8_ptr(j), strlen(j), STURY_FORMAT_JSON, NULL, NULL, NULL).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_jsonpath_compile(a, j, strlen(j), NULL).code, STURY_ERR_INVALID_ARG);
        CHECK_EQ_U64(stury_jsonpath_eval(a, NULL, u8_ptr(j), strlen(j), STURY_FORMAT_JSON, NULL, false, NULL, NULL).code, STURY_ERR_INVALID_ARG);

        /* Depth & node budgets */
        {
            const char *nested = "[[[[1]]]]";
            stury_budget_t db;
            memset(&db, 0, sizeof(db));
            db.depth = 2;
            CHECK_EQ_U64(stury_validate(a, u8_ptr(nested), strlen(nested), STURY_FORMAT_JSON, &db).code, STURY_ERR_BUDGET);

            stury_budget_t nb;
            memset(&nb, 0, sizeof(nb));
            nb.nodes = 2;
            CHECK_EQ_U64(stury_build(a, u8_ptr(nested), strlen(nested), STURY_FORMAT_JSON, &nb, &doc).code, STURY_ERR_BUDGET);
            CHECK(doc == NULL);
        }
    }

    stury_arena_free(a);
}

/* -------------------------------------------------------------------------
 * 8. YAML, HTML, and MessagePack through libstury
 * ------------------------------------------------------------------------- */
static void test_yaml_html_msgpack(void) {
    stury_arena_t *a = stury_arena_new();
    CHECK(a != NULL);

    /* Name, path, detection, caps, and facts */
    CHECK_EQ_U64(stury_format_by_name("yaml", 4), STURY_FORMAT_YAML);
    CHECK_EQ_U64(stury_format_by_name("yaml:merge", 10), STURY_FORMAT_YAML_MERGE);
    CHECK_EQ_U64(stury_format_by_name("html", 4), STURY_FORMAT_HTML);
    CHECK_EQ_U64(stury_format_by_name("html:fragment", 13), STURY_FORMAT_HTML_FRAGMENT);
    CHECK_EQ_U64(stury_format_by_name("msgpack", 7), STURY_FORMAT_MSGPACK);
    CHECK_EQ_U64(stury_format_by_name("msgpack:compact", 15), STURY_FORMAT_MSGPACK_COMPACT);

    CHECK_EQ_U64(stury_format_of_path("app.yaml", 8), STURY_FORMAT_YAML);
    CHECK_EQ_U64(stury_format_of_path("page.html", 9), STURY_FORMAT_HTML);
    CHECK_EQ_U64(stury_format_of_path("blob.mpk", 8), STURY_FORMAT_MSGPACK);

    {
        const char *y = "---\nname: ada\n";
        const char *h = "<!DOCTYPE html><html><body><p>ada</p></body></html>";
        const uint8_t m[4] = {0x81, 0xA1, 'k', 0x05};
        CHECK_EQ_U64(stury_format_detect(u8_ptr(y), strlen(y)), STURY_FORMAT_YAML);
        CHECK_EQ_U64(stury_format_detect(u8_ptr(h), strlen(h)), STURY_FORMAT_HTML);
        CHECK_EQ_U64(stury_format_detect(m, sizeof(m)), STURY_FORMAT_MSGPACK);
        CHECK((stury_format_caps(STURY_FORMAT_MSGPACK) & STURY_CAP_BINARY) != 0);
        CHECK((stury_format_facts(STURY_FORMAT_HTML) & STURY_FACT_ATTRIBUTE) != 0);
        CHECK((stury_format_facts(STURY_FORMAT_YAML) & STURY_FACT_COMMENT) != 0);
    }

    /* YAML -> JSON -> MessagePack -> JSON + schema check + jq query */
    {
        const char *yml = "# cfg\nname: ada\nage: 36\n";
        uint8_t *j_out = NULL;
        size_t j_len = 0;
        stury_facts_t dropped = 0;
        CHECK_EQ_U64(stury_validate(a, u8_ptr(yml), strlen(yml), STURY_FORMAT_YAML, NULL).code, STURY_OK);
        CHECK_EQ_U64(
            stury_convert(a, u8_ptr(yml), strlen(yml), STURY_FORMAT_YAML, STURY_FORMAT_JSON, NULL, &j_out, &j_len, &dropped).code,
            STURY_OK);
        CHECK(bytes_eq(j_out, j_len, "{\"name\":\"ada\",\"age\":36}"));
        CHECK((dropped & STURY_FACT_COMMENT) != 0);

        uint8_t *mp_out = NULL;
        size_t mp_len = 0;
        CHECK_EQ_U64(
            stury_convert(a, j_out, j_len, STURY_FORMAT_JSON, STURY_FORMAT_MSGPACK_COMPACT, NULL, &mp_out, &mp_len, NULL).code,
            STURY_OK);
        CHECK(mp_out != NULL && mp_len > 0);
        CHECK_EQ_U64(stury_validate(a, mp_out, mp_len, STURY_FORMAT_MSGPACK_COMPACT, NULL).code, STURY_OK);

        uint8_t *back = NULL;
        size_t back_len = 0;
        CHECK_EQ_U64(
            stury_convert(a, mp_out, mp_len, STURY_FORMAT_MSGPACK, STURY_FORMAT_JSON, NULL, &back, &back_len, NULL).code,
            STURY_OK);
        CHECK(bytes_eq(back, back_len, "{\"name\":\"ada\",\"age\":36}"));

        /* Schema check over YAML and MessagePack */
        const char *sc_src = "{\"type\":\"object\",\"required\":[\"name\",\"age\"],\"properties\":{\"name\":{\"type\":\"string\"},\"age\":{\"type\":\"integer\"}}}";
        stury_schema_t *sc = NULL;
        bool valid = false;
        CHECK_EQ_U64(stury_schema_compile(a, u8_ptr(sc_src), strlen(sc_src), &sc).code, STURY_OK);
        CHECK_EQ_U64(stury_schema_check(a, sc, u8_ptr(yml), strlen(yml), STURY_FORMAT_YAML, NULL, &valid).code, STURY_OK);
        CHECK(valid);
        valid = false;
        CHECK_EQ_U64(stury_schema_check(a, sc, mp_out, mp_len, STURY_FORMAT_MSGPACK, NULL, &valid).code, STURY_OK);
        CHECK(valid);
        stury_schema_free(sc);

        /* jq eval over YAML and MessagePack */
        stury_jq_t *jqp = NULL;
        CHECK_EQ_U64(stury_jq_compile(a, ".name", 5, &jqp).code, STURY_OK);
        emit_collector_t col;
        memset(&col, 0, sizeof(col));
        CHECK_EQ_U64(stury_jq_eval(a, jqp, u8_ptr(yml), strlen(yml), STURY_FORMAT_YAML, NULL, jq_collect_cb, &col).code, STURY_OK);
        CHECK_EQ_U64(col.count, 1);
        CHECK(strcmp(col.values[0], "\"ada\"") == 0);
        memset(&col, 0, sizeof(col));
        CHECK_EQ_U64(stury_jq_eval(a, jqp, mp_out, mp_len, STURY_FORMAT_MSGPACK, NULL, jq_collect_cb, &col).code, STURY_OK);
        CHECK_EQ_U64(col.count, 1);
        CHECK(strcmp(col.values[0], "\"ada\"") == 0);
        stury_jq_free(jqp);
    }

    /* HTML validate, build, write to JSON, and jq query */
    {
        const char *h = "<!DOCTYPE html><html><body><p>hello</p></body></html>";
        stury_doc_t *doc = NULL;
        CHECK_EQ_U64(stury_validate(a, u8_ptr(h), strlen(h), STURY_FORMAT_HTML, NULL).code, STURY_OK);
        CHECK_EQ_U64(stury_build(a, u8_ptr(h), strlen(h), STURY_FORMAT_HTML, NULL, &doc).code, STURY_OK);
        CHECK(doc != NULL && stury_doc_node_count(doc) > 0);
        uint8_t *out = NULL;
        size_t out_len = 0;
        CHECK_EQ_U64(stury_write(a, doc, STURY_FORMAT_JSON, &out, &out_len, NULL).code, STURY_OK);
        CHECK(bytes_contains(out, out_len, "\"hello\""));
        stury_doc_free(doc);

        stury_jq_t *jqp = NULL;
        CHECK_EQ_U64(stury_jq_compile(a, ".html.body.p", 12, &jqp).code, STURY_OK);
        emit_collector_t col;
        memset(&col, 0, sizeof(col));
        CHECK_EQ_U64(stury_jq_eval(a, jqp, u8_ptr(h), strlen(h), STURY_FORMAT_HTML, NULL, jq_collect_cb, &col).code, STURY_OK);
        CHECK_EQ_U64(col.count, 1);
        CHECK(strcmp(col.values[0], "\"hello\"") == 0);
        stury_jq_free(jqp);
    }

    stury_arena_free(a);
}

int main(void) {
    test_abi_layout();
    test_arena_and_formats();
    test_validate_build_write_convert();
    test_overlay_and_arena_reset();
    test_schema();
    test_jq_and_jsonpath();
    test_null_and_overflow_safety();
    test_yaml_html_msgpack();

    if (g_failures > 0) {
        fprintf(stderr, "c_consumer_test: %d/%d checks FAILED\n", g_failures, g_checks);
        return 1;
    }
    printf("c_consumer_test: all %d checks passed\n", g_checks);
    return 0;
}
