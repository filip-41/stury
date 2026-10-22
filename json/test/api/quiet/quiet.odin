package quiet

// What the quickstart snippets print, kept out of `make test`'s output: the snippets call
// `fmt.println`, `fmt.eprintln` and `fmt.eprintf`, and
// json/test/api/quickstart_test.odin imports this package as `fmt`.
// The tests check what the snippets read and write themselves.

println :: proc(args: ..any) {}

eprintln :: proc(args: ..any) {}

eprintf :: proc(format: string, args: ..any) {}
