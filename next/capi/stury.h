/*
 * stury.h — C99/C11 ABI for the stury v2 multi-format data engine.
 *
 * Ownership and threading contract:
 * - Zero global mutable state. Every operation is thread-safe when operating on
 *   distinct arenas/overlays.
 * - `stury_arena_t` is caller-owned. Output byte buffers (`stury_write`,
 *   `stury_convert`, `stury_overlay_commit`) and formatted error messages
 *   (`stury_err_t.message`) allocated in an arena remain valid until
 *   `stury_arena_reset` or `stury_arena_free`.
 * - Independent handles (`stury_doc_t`, `stury_overlay_t`, `stury_schema_t`,
 *   `stury_jq_t`, `stury_jsonpath_t`) own their internal storage on the library
 *   allocator and are freed independently via their matching `*_free` functions,
 *   so resetting or freeing a `stury_arena_t` never invalidates them.
 * - `stury_doc_t` borrows its input byte slice `src`; the caller must keep `src`
 *   alive for the lifetime of the document, and must keep `doc` alive for the
 *   lifetime of any `stury_overlay_t` created over it.
 * - Compiled schemas, jq programs, JSONPath programs, and built documents are
 *   immutable and safe to share concurrently across threads.
 * - Wherever `stury_arena_t *a` is used only for error messages (i.e. all calls
 *   except `stury_write`, `stury_convert`, and `stury_overlay_commit`, which
 *   allocate output buffers in `a`), passing `a == NULL` is allowed and falls
 *   back to static NUL-terminated error strings.
 * - Callback slices (`bytes`, `norm_path`) delivered to `stury_emit_fn` and
 *   `stury_jsonpath_emit_fn` are borrowed only for the duration of the callback
 *   invocation and are NOT guaranteed to be NUL-terminated; callers that keep
 *   them must copy `len` bytes.
 */

#ifndef STURY_H
#define STURY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Sentinel values matching stury's tape constants. */
#define STURY_NO_BYTE UINT64_MAX
#define STURY_ROOT    ((uint32_t)0)
#define STURY_NO_NODE UINT32_MAX

/* Opaque handles. */
typedef struct stury_arena    stury_arena_t;    /* Caller-owned dynamic arena */
typedef struct stury_doc      stury_doc_t;      /* Concrete tape.Document (freed by stury_doc_free) */
typedef struct stury_overlay  stury_overlay_t;  /* Sparse format-preserving edit overlay */
typedef struct stury_schema   stury_schema_t;   /* Compiled JSON Schema 2020-12 plan */
typedef struct stury_jq       stury_jq_t;       /* Compiled jq program */
typedef struct stury_jsonpath stury_jsonpath_t; /* Compiled RFC 9535 JSONPath program */

/* Format + specification identifier (exact match to engine.Format_Id). */
typedef uint32_t stury_format_t;
enum {
    STURY_FORMAT_JSON               = 0,
    STURY_FORMAT_JSONC              = 1,
    STURY_FORMAT_JSON5              = 2,
    STURY_FORMAT_TOML_1_0           = 3,
    STURY_FORMAT_TOML_1_1           = 4,
    STURY_FORMAT_XML                = 5,
    STURY_FORMAT_CSV                = 6,
    STURY_FORMAT_TSV                = 7,
    STURY_FORMAT_PLAIN              = 8,
    STURY_FORMAT_CBOR               = 9,
    STURY_FORMAT_CBOR_PREFERRED     = 10,
    STURY_FORMAT_CBOR_DETERMINISTIC = 11,
    STURY_FORMAT_CBOR_LENGTH_FIRST  = 12,
    STURY_FORMAT_UNKNOWN            = 255
};

/* Format capability bitmask (exact layout of tape.Caps / bit_set[tape.Cap; u32]). */
typedef uint32_t stury_caps_t;
enum {
    STURY_CAP_REWALK      = 1u << 0,
    STURY_CAP_NAMES_AHEAD = 1u << 1,
    STURY_CAP_BINARY      = 1u << 2
};

/* Document/format fact bitmask (bits 0..15 of tape.Fact_Kind). */
typedef uint16_t stury_facts_t;
enum {
    STURY_FACT_COMMENT          = 1u << 0,
    STURY_FACT_COMMENT_INLINE   = 1u << 1,
    STURY_FACT_COMMENT_FOOT     = 1u << 2,
    STURY_FACT_TAG              = 1u << 3,
    STURY_FACT_ANCHOR           = 1u << 4,
    STURY_FACT_ALIAS            = 1u << 5,
    STURY_FACT_INSTRUCTION      = 1u << 6,
    STURY_FACT_INSTRUCTION_FOOT = 1u << 7,
    STURY_FACT_DOCTYPE          = 1u << 8,
    STURY_FACT_DIRECTIVE        = 1u << 9,
    STURY_FACT_ATTRIBUTE        = 1u << 10,
    STURY_FACT_STYLE            = 1u << 11,
    STURY_FACT_NAME             = 1u << 12,
    STURY_FACT_NAMESPACE        = 1u << 13,
    STURY_FACT_CONTENT          = 1u << 14,
    STURY_FACT_ABSENT           = 1u << 15,
    STURY_FACTS_COMMENTS        = STURY_FACT_COMMENT | STURY_FACT_COMMENT_INLINE | STURY_FACT_COMMENT_FOOT
};

/* Structured error code. */
typedef uint32_t stury_err_code_t;
enum {
    STURY_OK                 = 0,
    STURY_ERR_INVALID_ARG    = 1,  /* NULL pointer, unknown format, or length overflow */
    STURY_ERR_SYNTAX         = 2,  /* Input syntax fault or query/schema compile fault */
    STURY_ERR_BUDGET         = 3,  /* Depth, node, memory, step, or expansion budget exceeded */
    STURY_ERR_NO_MEMORY      = 4,  /* Out of memory */
    STURY_ERR_UNSPELLABLE    = 5,  /* Target format cannot spell a value */
    STURY_ERR_SCHEMA_INVALID = 6,  /* Document/text failed schema validation */
    STURY_ERR_EDIT_REFUSED   = 7,  /* Overlay edit or commit refused */
    STURY_ERR_QUERY_RUNTIME  = 8,  /* Runtime error during jq or JSONPath evaluation */
    STURY_ERR_STOPPED        = 9,  /* Callback requested early stop */
    STURY_ERR_UNSUPPORTED    = 10, /* Unsupported operation */
    STURY_ERR_HALTED         = 11  /* Query program halted explicitly (jq halt / halt_error) */
};

/* Structured error returned by all fallible C ABI calls. */
typedef struct stury_err {
    stury_err_code_t code;    /* STURY_OK (0) on success */
    uint64_t         at;      /* Byte offset in input, or STURY_NO_BYTE */
    const char      *message; /* NUL-terminated message (in arena or static); NULL on STURY_OK */
} stury_err_t;

/* Resource limits for one read, check, or query run (0 = default/unlimited). */
typedef struct stury_budget {
    uint32_t depth;     /* Max nesting depth (0 = default 10,000) */
    uint32_t nodes;     /* Max nodes kept in a build (0 = unlimited) */
    uint64_t memory;    /* Max memory in bytes (0 = unlimited) */
    uint64_t steps;     /* Max walk/eval steps (0 = unlimited) */
    uint64_t expansion; /* Max entity/alias expansion bytes (0 = default) */
} stury_budget_t;

/*
 * Callback receiving each compact JSON output from stury_jq_eval.
 * `bytes` is borrowed only during the callback and is NOT NUL-terminated.
 * Return false to stop early (yields STURY_ERR_STOPPED).
 */
typedef bool (*stury_emit_fn)(void *ctx, const uint8_t *bytes, size_t len);

/*
 * Callback receiving each compact JSON value and optional RFC 9535 normalized path
 * from stury_jsonpath_eval. `bytes` and `norm_path` are borrowed only during the
 * callback and are NOT NUL-terminated. `norm_path` is NULL (len 0) when
 * `want_paths` is false. Return false to stop early (yields STURY_ERR_STOPPED).
 */
typedef bool (*stury_jsonpath_emit_fn)(
    void          *ctx,
    const uint8_t *bytes,
    size_t         len,
    const char    *norm_path,
    size_t         norm_path_len
);

/* -------------------------------------------------------------------------
 * Arena lifecycle
 * ------------------------------------------------------------------------- */

stury_arena_t *stury_arena_new(void);
void           stury_arena_reset(stury_arena_t *a);
void           stury_arena_free(stury_arena_t *a);

/* -------------------------------------------------------------------------
 * Format lookup, detection, and capabilities
 * ------------------------------------------------------------------------- */

stury_format_t stury_format_by_name(const char *name, size_t len);
stury_format_t stury_format_of_path(const char *path, size_t len);
stury_format_t stury_format_detect(const uint8_t *src, size_t len);
stury_caps_t   stury_format_caps(stury_format_t fmt);
stury_facts_t  stury_format_facts(stury_format_t fmt);

/* -------------------------------------------------------------------------
 * Validation, document building, inspection, writing, and conversion
 * ------------------------------------------------------------------------- */

/* `a` is optional (used only for formatted error messages); `budget` is optional. */
stury_err_t stury_validate(
    stury_arena_t        *a,
    const uint8_t        *src,
    size_t                len,
    stury_format_t        fmt,
    const stury_budget_t *budget
);

/*
 * Builds an independent `stury_doc_t` (freed by `stury_doc_free`) borrowing `src`.
 * `a` is optional (used only for formatted error messages); `budget` is optional.
 */
stury_err_t stury_build(
    stury_arena_t        *a,
    const uint8_t        *src,
    size_t                len,
    stury_format_t        fmt,
    const stury_budget_t *budget,
    stury_doc_t         **out
);

void          stury_doc_free(stury_doc_t *doc);
stury_facts_t stury_doc_facts(const stury_doc_t *doc);
size_t        stury_doc_node_count(const stury_doc_t *doc);

/* Requires non-NULL `a` (output buffer is allocated in `a`); `dropped` is optional. */
stury_err_t stury_write(
    stury_arena_t     *a,
    const stury_doc_t *doc,
    stury_format_t     to,
    uint8_t          **out,
    size_t            *out_len,
    stury_facts_t     *dropped
);

/* Requires non-NULL `a` (output buffer is allocated in `a`); `budget` and `dropped` are optional. */
stury_err_t stury_convert(
    stury_arena_t        *a,
    const uint8_t        *src,
    size_t                len,
    stury_format_t        from,
    stury_format_t        to,
    const stury_budget_t *budget,
    uint8_t             **out,
    size_t               *out_len,
    stury_facts_t        *dropped
);

/* -------------------------------------------------------------------------
 * JSON Schema 2020-12 compile and multi-format streaming validation
 * ------------------------------------------------------------------------- */

/* `a` is optional (used only for formatted error messages). */
stury_err_t stury_schema_compile(
    stury_arena_t   *a,
    const uint8_t   *schema_src,
    size_t           schema_len,
    stury_schema_t **out
);

void stury_schema_free(stury_schema_t *schema);

/* `a`, `budget`, and `out_valid` are optional. */
stury_err_t stury_schema_check(
    stury_arena_t        *a,
    const stury_schema_t *schema,
    const uint8_t        *src,
    size_t                len,
    stury_format_t        fmt,
    const stury_budget_t *budget,
    bool                 *out_valid
);

/* -------------------------------------------------------------------------
 * Format-preserving overlay editing (RFC 6901 JSON Pointer paths)
 * ------------------------------------------------------------------------- */

/* `doc` must outlive the returned overlay; `a` is optional (error messages only). */
stury_err_t stury_overlay_new(
    stury_arena_t     *a,
    const stury_doc_t *doc,
    stury_overlay_t  **out
);

void stury_overlay_free(stury_overlay_t *ov);

stury_err_t stury_overlay_set_raw(
    stury_arena_t   *a,
    stury_overlay_t *ov,
    const char      *pointer,
    size_t           pointer_len,
    const uint8_t   *raw,
    size_t           raw_len
);

stury_err_t stury_overlay_set_string(
    stury_arena_t   *a,
    stury_overlay_t *ov,
    const char      *pointer,
    size_t           pointer_len,
    const char      *val,
    size_t           val_len
);

stury_err_t stury_overlay_set_int(
    stury_arena_t   *a,
    stury_overlay_t *ov,
    const char      *pointer,
    size_t           pointer_len,
    int64_t          val
);

stury_err_t stury_overlay_del_path(
    stury_arena_t   *a,
    stury_overlay_t *ov,
    const char      *pointer,
    size_t           pointer_len
);

/*
 * Commits edits in `ov` to bytes allocated in `a` (requires non-NULL `a`).
 * Pass `target == STURY_FORMAT_UNKNOWN` to commit in the base document's own format.
 * `dropped` is optional.
 */
stury_err_t stury_overlay_commit(
    stury_arena_t   *a,
    stury_overlay_t *ov,
    stury_format_t   target,
    bool             reflow,
    uint8_t        **out,
    size_t          *out_len,
    stury_facts_t   *dropped
);

/* -------------------------------------------------------------------------
 * jq query compilation and callback-based evaluation
 * ------------------------------------------------------------------------- */

/* `a` is optional (used only for formatted error messages). */
stury_err_t stury_jq_compile(
    stury_arena_t *a,
    const char    *src,
    size_t         len,
    stury_jq_t   **out
);

void stury_jq_free(stury_jq_t *prog);

/* `a`, `budget`, and `emit` are optional. */
stury_err_t stury_jq_eval(
    stury_arena_t        *a,
    const stury_jq_t     *prog,
    const uint8_t        *src,
    size_t                len,
    stury_format_t        fmt,
    const stury_budget_t *budget,
    stury_emit_fn         emit,
    void                 *emit_ctx
);

/* -------------------------------------------------------------------------
 * RFC 9535 JSONPath compilation and callback-based evaluation
 * ------------------------------------------------------------------------- */

/* `a` is optional (used only for formatted error messages). */
stury_err_t stury_jsonpath_compile(
    stury_arena_t     *a,
    const char        *src,
    size_t             len,
    stury_jsonpath_t **out
);

void stury_jsonpath_free(stury_jsonpath_t *prog);

/* `a`, `budget`, and `emit` are optional. */
stury_err_t stury_jsonpath_eval(
    stury_arena_t          *a,
    const stury_jsonpath_t *prog,
    const uint8_t          *src,
    size_t                  len,
    stury_format_t          fmt,
    const stury_budget_t   *budget,
    bool                    want_paths,
    stury_jsonpath_emit_fn  emit,
    void                   *emit_ctx
);

#ifdef __cplusplus
}
#endif

#endif /* STURY_H */
