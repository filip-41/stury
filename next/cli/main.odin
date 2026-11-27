package cli

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "stury:engine"
import "stury:host"

@(private = "file")
check_stdout_write :: proc(ok: bool, w: io.Writer, stderr_w: io.Writer) -> int {
	if !ok {
		return report_stdout_error(stderr_w, .Short_Write)
	}
	if w.data != rawptr(os.stdout) && w.data != rawptr(os.stderr) {
		if f, has_f := io.to_flusher(w); has_f {
			if ferr := io.flush(f); ferr != .None {
				return report_stdout_error(stderr_w, ferr)
			}
		}
	}
	return EXIT_OK
}

@(private = "file")
should_init_verb_pool :: proc(opts: ^Options, alloc: runtime.Allocator) -> bool {
	if opts.threads == 1 {
		return false
	}
	if opts.threads > 1 || len(opts.files) > 1 {
		return true
	}
	if len(opts.files) == 1 && opts.files[0] != "-" {
		fi, err := os.stat(opts.files[0], alloc)
		if err != nil {
			return false
		}
		sz := fi.size
		is_reg := fi.type == .Regular
		os.file_info_delete(fi, alloc)
		return is_reg && sz >= 4 << 20
	}
	return false
}

@(private = "file")
run_with_options :: proc(
	opts: ^Options,
	stdin_override: Maybe([]u8),
	stdout_w, stderr_w: io.Writer,
	stdout_is_tty, stdin_is_tty: bool,
	alloc: runtime.Allocator,
) -> int {
	if opts.show_help {
		if opts.command == .Run && len(opts.files) == 0 && opts.filter == nil && stdout_w.data == rawptr(os.stdout) {
			_ = write_help(stdout_w, opts.command, false)
			return EXIT_OK
		}
		return check_stdout_write(write_help(stdout_w, opts.command, false), stdout_w, stderr_w)
	}
	if opts.show_version {
		return check_stdout_write(write_version(stdout_w), stdout_w, stderr_w)
	}
	if opts.show_build_config {
		buf: [256]u8
		s := fmt.bprintf(buf[:], "%s\n", BUILD_CONFIG)
		_, werr := io.write_string(stdout_w, s)
		return check_stdout_write(werr == .None, stdout_w, stderr_w)
	}
	if opts.command == .Run && opts.filter == nil && !opts.from_file && stdin_is_tty && stdout_is_tty {
		_ = write_help(stderr_w, .Run, true)
		return EXIT_USAGE
	}
	if opts.has_to {
		if te, ok := engine.entry_of_spec(opts.to_spec); ok && te.binary && stdout_is_tty && !opts.in_place && !opts.check && opts.command != .Check {
			label := "CBOR" if te.family == .Cbor else "MessagePack" if te.family == .Msgpack else te.name
			fmt.wprintf(stderr_w, "stury: binary %s output will not be written to a terminal; redirect stdout or pipe to another program\n", label)
			return EXIT_USAGE
		}
	}
	if opts.color_mode == .Auto && stdout_is_tty && !opts.raw {
		if nc, ok := os.lookup_env("NO_COLOR", alloc); ok {
			defer delete(nc, alloc)
			if nc == "" {
				opts.color_mode = .Always
			}
		} else {
			opts.color_mode = .Always
		}
	}

	pool: host.Pool
	pool_ready := false
	if opts.command != .Run && should_init_verb_pool(opts, alloc) {
		pool_ready = host.pool_init(&pool, opts.threads) == nil
	}
	defer if pool_ready {
		host.pool_destroy(&pool)
	}
	runner := &pool.runner if pool_ready else nil

	exe_dir, e1 := os.get_executable_directory(alloc)
	defer if e1 == nil {
		delete(exe_dir, alloc)
	}
	cwd, e2 := os.get_working_directory(alloc)
	defer if e2 == nil {
		delete(cwd, alloc)
	}
	home_dir, hok := os.lookup_env("HOME", alloc)
	if !hok {
		home_dir, hok = os.lookup_env("USERPROFILE", alloc)
	}
	defer if hok {
		delete(home_dir, alloc)
	}

	ed := exe_dir if e1 == nil else ""
	cd := cwd if e2 == nil else ""
	hd := home_dir if hok else ""

	switch opts.command {
	case .Check:
		return run_check(opts, stdin_override, stdout_w, stderr_w, runner, alloc)
	case .Fmt:
		return run_fmt(opts, stdin_override, stdout_w, stderr_w, runner, alloc)
	case .Edit:
		return run_edit(opts, stdin_override, stdout_w, stderr_w, runner, ed, cd, hd, alloc)
	case .Diff:
		return run_diff(opts, stdin_override, stdout_w, stderr_w, runner, alloc)
	case .Schema:
		return run_schema(opts, stdin_override, stdout_w, stderr_w, runner, alloc)
	case .Run:
		return run_query(opts, stdin_override, stdout_w, stderr_w, runner, ed, cd, hd, alloc)
	}
	return EXIT_USAGE
}

run_cli :: proc(
	args: []string,
	stdin_override: Maybe([]u8),
	stdout_w, stderr_w: io.Writer,
	stdout_is_tty := false,
	stdin_is_tty := false,
	alloc := context.allocator,
) -> int {
	opts, perr := parse_args(args, alloc)
	defer options_destroy(&opts)
	if perr != "" {
		fmt.wprintf(stderr_w, "stury: %s\n", perr)
		delete(perr, alloc)
		return EXIT_USAGE
	}
	return run_with_options(&opts, stdin_override, stdout_w, stderr_w, stdout_is_tty, stdin_is_tty, alloc)
}

@(private = "file")
run_process :: proc() -> int {
	cli_args := os.args[1:] if len(os.args) > 1 else nil
	alloc := runtime.heap_allocator()
	stdout_w := os.to_writer(os.stdout)
	stderr_w := os.to_writer(os.stderr)
	opts, perr := parse_args(cli_args, alloc)
	defer options_destroy(&opts)
	if perr != "" {
		fmt.wprintf(stderr_w, "stury: %s\n", perr)
		delete(perr, alloc)
		_ = os.flush(os.stderr)
		return EXIT_USAGE
	}
	check_closed := !(opts.show_help || (opts.command == .Check && opts.report == .Lines) || opts.in_place || opts.check) && !opts.show_build_config
	code := run_with_options(&opts, nil, stdout_w, stderr_w, os.is_tty(os.stdout), os.is_tty(os.stdin), alloc)
	if check_closed && code != EXIT_USAGE {
		if fi, serr := os.fstat(os.stdout, alloc); serr == nil {
			os.file_info_delete(fi, alloc)
		} else {
			code = report_stdout_os_error(stderr_w, serr)
		}
	}
	_ = os.flush(os.stderr)
	return code
}

main :: proc() {
	os.exit(run_process())
}
