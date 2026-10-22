# Changelog

## Unreleased

- `Request` and `Prepared` name their type parameter `$KINDS` (was `$Q`), as the generic procedures that take
  them do. Callers that write `Request({.Path})` are unaffected.
- `marshal` writes an empty `json.Digits` as `null`, as it writes an empty `json.Raw`, instead of failing with
  `.Bad_Raw`.
- `render_error` of an `Unmarshal_Error` ends with its path (`1:11: Wrong_Kind at .a.b`), with `…` when the path
  was truncated.
- `unmarshal`'s `.Unsupported` for a `,string` field, or for two fields writing one key, names that field in the
  error path.
- CLI: `halt_error/1` with a non-number argument names its input as jq does (`number (1) halt_error/1: number
  required`).
- CLI: `select(PATH OP literal)` on a large single document reads only its path, and prints the text only when it
  keeps it, instead of building the whole document.

## 0.0.1 (2026-10-22)

The first release. It builds with Odin `dev-2026-10` and targets 64-bit little-endian systems (darwin and
linux, on amd64 and arm64).

### Library (`stury:json`, `stury:host`)

- Validation: check a text against RFC 8259 without allocating, with the line and column of the first fault.
- Path queries: read the values at one or more paths without parsing the rest of the text (`find` for one
  path's first answer, a `Request` for more).
- Parsed documents: build a document once and query it, numbers are checked when it is built and decoded when
  read, so the input must outlive the document.
- Typed `unmarshal` and `marshal`: read JSON into Odin structs, slices, maps, unions and `any`, and write Odin
  values back as JSON.
- Byte-preserving edits: `set`, `insert`, `remove` and `splice` change only the bytes they target.
- NDJSON and RFC 7464 records: iterate the values of a line-delimited or record-separated stream.
- JSONC: read comments and trailing commas, and write the comments back.
- Parallel validation and per-record work take threads from `stury:host` (`Batch_Pool`), and the library starts no
  thread of its own.
- One error convention and fixed limits throughout. Each public name's doc comment describes it. A
  procedure whose result is its only output carries `@(require_results)`, so a dropped result is a compile
  error.
- On amd64 the floor is x86-64-v2, long strings are scanned 64 bytes at a time where the processor has
  AVX-512BW.

### Command line (`stury`)

- jq 1.8.2's language, answers and exit codes. Its messages start with `stury:` and are worded its own way;
  where stury answers differently, [docs/cli.md](docs/cli.md) lists it. Modules (`import`, `include`, `-L`,
  `~/.jq`), every jq option except `--run-tests` (a test-file runner stury does not have), `--seq`,
  `--stream`, colours, and regular expressions in Oniguruma syntax (with their own engine, so there is no
  dependency on the Oniguruma library).
- New options: `--ndjson`, `--jsonc`, `--max-depth N` (allow nesting past 1024 for every input, `fromjson` and
  option JSON, where jq caps at 10000) and the `stury check` subcommand (`--strict-limits` holds the library's
  digit and scale limits).
- `--jsonc` output keeps the comments of values taken unchanged from the input and drops them on values the
  filter made. Use `.@comment`, `.@comment_inline` and `.@comment_foot` to read them as a list of texts or
  null.
- Large inputs are read and printed on several threads (see `host.Batch_Pool` in `stury:host`).
- Filters that recurse in tail position use constant memory, and recursion can go about a million levels deep.
