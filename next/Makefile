ODIN ?= odin

PKGS := $(sort $(patsubst ./%/,%,$(dir $(shell find . -name '*.odin' -not -path './build/*'))))
TEST_PKGS := $(filter %/test,$(PKGS))
WASM_PKG := tools/wasm
DEADSTRIP_PKG := tools/deadstrip
LIB_PKGS := $(filter-out $(TEST_PKGS) $(WASM_PKG) $(DEADSTRIP_PKG) cli,$(PKGS))

COLLECTION := -collection:stury=$(CURDIR)
VET := -vet-unused-variables -vet-shadowing -vet-using-stmt -vet-cast -vet-semicolon -vet-tabs -vet-unused-imports -strict-style
LINT_FLAGS := $(COLLECTION) $(VET) -warnings-as-errors -terse-errors -max-error-count:500
# `SEED` and `ROUNDS` of `testkit` change the random choices of a run and how many it makes:
# `make test TEST_DEFINES="-define:SEED=7 -define:ROUNDS=5"`. A test that has not returned after
# `TEST_TIMEOUT_SECONDS` fails, named, instead of holding the runner.
TEST_DEFINES ?=
# A build on a runner's threads reads texts of any length in parts, so the tests' short texts take that route too.
TEST_BASE_FLAGS := $(COLLECTION) -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:BUILD_PARALLEL_FROM=0 $(TEST_DEFINES)
TEST_FLAGS := $(TEST_BASE_FLAGS) -define:TEST_TIMEOUT_SECONDS=120


# Tests need an OS (`core:testing` imports `core:os`), so only the library is checked for wasm.
TEST_LINT_TARGETS := linux_amd64 windows_amd64 linux_riscv64
FREESTANDING_AMD64_PKGS := lib/base/kernel
# The walks' states end in `#must_tail` calls, which WebAssembly runs with its tail-call feature. `odin check` takes no
# target features, and only a program that calls the reads compiles their walks, so `WASM_PKG` exports a caller of each
# read and is built for every wasm target and feature set.
WASM_TARGETS := freestanding_wasm32 wasi_wasm32
WASM_FEATURE_SETS := tail-call tail-call,simd128
NM ?= $(shell command -v llvm-nm || echo /opt/homebrew/opt/llvm@22/bin/llvm-nm)
# Feature sets without `tail-call`, which a build must refuse, the message naming the feature.
WASM_NO_TAIL_FEATURE_SETS := none simd128

# Test packages whose kernels pick an x86-64 tier, run at each tier and `X86_OPTS` level, and once at each level with
# no tier named, so the CPU's own tier is detected and used. On an x86-64 machine these runs replace the plain one. An
# arm64 Mac runs them through Rosetta, and skips them with a note where Rosetta is not installed.
TIER_PKGS := lib/base/kernel/test lib/base/regex/test dsv/test cbor/test xml/test
# `json/test` checks `json::string_span_v3` tier isolation in `lint-tiers`; it stays out of `TIER_PKGS` because its
# single-module `-o:speed` x86-64 test binary inlines all five `read_nested` arms past `THREAD_START` before `probe_stack`.
LINT_TIER_PKGS := $(TIER_PKGS) json/test
# The tests of `dsv/test` that read texts of every shape through the delimited pass. The others do not reach the pass
# instances, and a run under Rosetta takes the whole package six times.
comma := ,
space := $(subst ,, )
DSV_TIER_TESTS := $(addprefix dsv_tests.,walk_tokens walked_tokens_span_what_their_kind_says builds_read_as_tables \
	finds_answer_cells_and_records scans_agree_with_builds scans_answer_paths_as_a_build_does pieces_agree_with_whole_reads \
	pieces_carry_each_state_across_a_window parts_build_what_one_thread_builds records_answer_as_their_own_text \
	validates_in_two_windows_as_the_whole_text validates_count_steps_as_builds_do \
	scans_take_the_columns_of_wide_records_as_builds_do scans_replay_records_as_they_read_them \
	records_with_an_unclosed_quote_do_not_fault_at_later_lines \
	records_with_an_unclosed_quote_judge_a_cut_sequence_by_their_own_bytes)
DSV_TIER_NAMES := -define:ODIN_TEST_NAMES=$(subst $(space),$(comma),$(DSV_TIER_TESTS))
X86_TIERS := 0 1
X86_OPTS ?= minimal speed
# The forced-tier runs and `dsv/test` build one LLVM module per package/file: at `-o:speed` one module of `dsv/test`
# takes minutes and gigabytes. The smaller packages' detected-tier runs keep the one module an optimized build makes by
# default so cross-file inlining is exercised at runtime.
X86_TIER_MODULES := -use-separate-modules
OBJDUMP ?= $(shell command -v llvm-objdump || echo /opt/homebrew/opt/llvm@22/bin/llvm-objdump)
PLAIN_PKGS := $(TEST_PKGS)
ifeq ($(shell uname -sm),Darwin arm64)
ifeq ($(shell arch -x86_64 /usr/bin/true >/dev/null 2>&1 && echo rosetta),rosetta)
X86_RUNS := 1
X86_FLAGS := -target:darwin_amd64
else
X86_SKIPPED := 1
endif
else ifeq ($(shell uname -m),x86_64)
X86_RUNS := 1
PLAIN_PKGS := $(filter-out $(TIER_PKGS),$(TEST_PKGS))
endif

# Test packages whose walks also build without member gaps, and then read as a format whose values cannot be walked
# again alone, which keeps nodes where a read would walk a value again
GAP_PKGS := json/test

# Sanitized tests link through LLVM's own clang, as Apple's lacks the runtime LLVM's instrumentation calls
# (`__asan_version_mismatch_check_v8`).
SAN_LLVM ?= /opt/homebrew/opt/llvm@22/bin
SAN_RUN := PATH="$(SAN_LLVM):$$PATH" ASAN_OPTIONS=detect_leaks=0 TSAN_OPTIONS=atexit_sleep_ms=0
# A sanitizer run holds shadow memory per test thread, so its runner keeps to a few threads. Its build makes one module
# per package on a few threads, as one instrumented module of the json tests takes LLVM past the 4 GiB memory cap.
SAN_FLAGS := $(TEST_BASE_FLAGS) -define:TEST_TIMEOUT_SECONDS=900 -define:ODIN_TEST_THREADS=4 -use-separate-modules -thread-count:4

# The test whose text nests 100,000 levels on a thread of one MiB, run at the optimization levels that change a frame.
DEEP_TEST := json_tests.reads_nest_100000_levels_in_one_mib
DEEP_CBOR_TEST := cbor_tests.reads_nest_100000_levels_in_one_mib
DEEP_TOML_TEST := toml_tests.reads_nest_100000_levels_in_one_mib
DEEP_XML_TEST := xml_tests.reads_nest_100000_levels_in_one_mib
DEEP_JQ_TEST := jq_tests.programs_nest_100000_levels_in_one_mib,jq_tests.runs_go_100000_levels_deep_in_one_mib
DEEP_OPTS := none speed

.PHONY: check check-all lint lint-check lint-wasm lint-tiers $(LINT_TIER_PKGS:%=lint-tiers/%) test test-deep test-asan test-tsan

check: lint test

# `check` and the sanitizer runs, which take longer and are not part of it.
check-all: check test-asan test-tsan

# The three parts share nothing, and the longest builds in them (a wasm object, the optimized `dsv/test` module) use one
# thread each, so they run side by side.
lint:
	@$(MAKE) -j4 --no-print-directory lint-check lint-wasm lint-tiers

lint-check:
	@echo "== layers"; python3 tools/layers.py || exit 1
	@for p in $(LIB_PKGS); do \
		echo "== $$p"; $(ODIN) check $$p -no-entry-point $(LINT_FLAGS) || exit 1; \
		for t in $(TEST_LINT_TARGETS); do \
			echo "== $$p ($$t)"; $(ODIN) check $$p -no-entry-point $(LINT_FLAGS) -target:$$t || exit 1; \
		done; \
	done
	@for p in $(FREESTANDING_AMD64_PKGS); do \
		echo "== $$p (freestanding_amd64_sysv)"; $(ODIN) check $$p -no-entry-point $(LINT_FLAGS) -target:freestanding_amd64_sysv || exit 1; \
	done
	@for p in $(TEST_PKGS); do \
		echo "== $$p"; $(ODIN) check $$p -no-entry-point $(LINT_FLAGS) || exit 1; \
		for t in $(TEST_LINT_TARGETS); do \
			echo "== $$p ($$t)"; $(ODIN) check $$p -no-entry-point $(LINT_FLAGS) -target:$$t || exit 1; \
		done; \
	done

lint-wasm:
	@mkdir -p build; for t in $(WASM_TARGETS); do for f in $(WASM_FEATURE_SETS); do \
		echo "== $(WASM_PKG) ($$t, $$f)"; \
		$(ODIN) build $(WASM_PKG) -build-mode:obj -no-entry-point $(LINT_FLAGS) -o:speed -target:$$t -target-features:$$f -out:build/wasm.o || exit 1; \
		python3 tools/wasm_check.py $(NM) $(OBJDUMP) build/wasm.o $(WASM_PKG)/exports.odin || exit 1; \
	done; \
	for f in $(WASM_NO_TAIL_FEATURE_SETS); do \
		echo "== $(WASM_PKG) ($$t, $$f, refused)"; \
		if [ $$f = none ]; then features=; else features=-target-features:$$f; fi; \
		if out=$$($(ODIN) build $(WASM_PKG) -build-mode:obj -no-entry-point $(COLLECTION) -o:speed -target:$$t $$features -out:build/wasm-refused.o 2>&1); then \
			echo "a build without tail-call compiled"; exit 1; \
		fi; \
		echo "$$out" | grep -q "tail-call" || { echo "a build without tail-call failed otherwise:"; echo "$$out"; exit 1; }; \
	done; done
	@echo "== $(DEADSTRIP_PKG)"
	@$(ODIN) build $(DEADSTRIP_PKG) -build-mode:obj -no-entry-point $(LINT_FLAGS) -o:speed -out:build/deadstrip.o || exit 1
	@python3 tools/deadstrip_check.py $(NM) build/deadstrip.o || exit 1

lint-tiers: $(LINT_TIER_PKGS:%=lint-tiers/%)

$(LINT_TIER_PKGS:%=lint-tiers/%): lint-tiers/%:
	@mkdir -p build; p=$*; o=build/tiers-$$(echo $$p | tr / -); \
		echo "== $$p (linux_amd64 tiers)"; \
		case $$p in dsv/test) req="--require dsv::pass_default_v3:";; lib/base/regex/test) req="--require ::set_v3";; json/test) req="--require json::string_span_v3:";; xml/test) req="--require xml::span_v3:";; *) req=;; esac; \
		rm -rf $$o-none && mkdir -p $$o-none && \
		$(ODIN) test $$p -build-mode:obj -use-separate-modules -target:linux_amd64 -o:none $(LINT_FLAGS) -out:$$o-none/m.o || exit 1; \
		python3 tools/tier_check.py $(OBJDUMP) $$o-none $$req || exit 1; \
		if [ "$$p" != "dsv/test" ]; then \
			$(ODIN) test $$p -build-mode:obj -use-single-module -target:linux_amd64 -o:speed $(LINT_FLAGS) -out:$$o-speed.o || exit 1; \
			python3 tools/tier_check.py $(OBJDUMP) $$o-speed.o --inlined $$req || exit 1; \
		else \
			rm -rf $$o-speed && mkdir -p $$o-speed && \
			$(ODIN) test $$p -build-mode:obj -use-separate-modules -target:linux_amd64 -o:speed $(LINT_FLAGS) -out:$$o-speed/m.o || exit 1; \
			python3 tools/tier_check.py $(OBJDUMP) $$o-speed --inlined \
				--inlined-skip 'dsv::line_end_v3:proc"contextless"(src:[]u8,start:int,S:$$$$1,' \
				--inlined-skip 'dsv::line_end_v3:proc"contextless"(src:[]u8,start:int,S:$$$$2,' \
				$$req || exit 1; \
		fi

test:
	@for p in $(TEST_PKGS); do \
		awk 'state == 2 && $$0 !~ /testkit\.deadline\(t\)/ {print FILENAME ": " name " does not start with testkit.deadline(t)"; bad = 1} \
			state == 1 {name = $$1; state = 2; next} state == 2 {state = 0} /^@\(test/ {state = 1} END {exit bad}' $$p/*.odin || exit 1; \
	done
	@mkdir -p build; for p in $(PLAIN_PKGS); do \
		echo "== $$p"; $(ODIN) test $$p -o:minimal $(TEST_FLAGS) -out:build/test-$$(echo $$p | tr / -) || exit 1; \
	done
	@for p in $(GAP_PKGS); do \
		echo "== $$p (no gaps, no rewalk)"; $(ODIN) test $$p -o:minimal $(TEST_FLAGS) -define:JSON_GAPS=false -define:JSON_REWALK=false -out:build/test-$$(echo $$p | tr / -)-nogaps || exit 1; \
	done
	@for pkg in json cbor toml xml jq; do \
		case $$pkg in json) names="$(DEEP_TEST)";; cbor) names="$(DEEP_CBOR_TEST)";; toml) names="$(DEEP_TOML_TEST)";; xml) names="$(DEEP_XML_TEST)";; *) names="$(DEEP_JQ_TEST)";; esac; \
		for o in $(DEEP_OPTS); do \
			echo "== $$pkg/test (100,000 levels in one MiB, -o:$$o)"; \
			$(ODIN) test $$pkg/test -o:$$o $(TEST_FLAGS) -define:ODIN_TEST_NAMES=$$names -out:build/test-deep-$$pkg-$$o || exit 1; \
		done; \
	done
ifdef X86_RUNS
	@for p in $(TIER_PKGS); do for o in $(X86_OPTS); do \
		case $$p in dsv/test) names="$(DSV_TIER_NAMES)"; det_mods="$(X86_TIER_MODULES)";; *) names=; det_mods=;; esac; \
		for t in $(X86_TIERS); do \
			echo "== $$p (x86-64 tier $$t, -o:$$o)"; \
			$(ODIN) test $$p -o:$$o $(TEST_FLAGS) $(X86_FLAGS) $(X86_TIER_MODULES) $$names -define:TIER=$$t -out:build/test-tier$$t-$$o || exit 1; \
		done; \
		echo "== $$p (x86-64 detected tier, -o:$$o)"; \
		$(ODIN) test $$p -o:$$o $(TEST_FLAGS) $(X86_FLAGS) $$det_mods $$names -out:build/test-detected-$$o || exit 1; \
	done; done
endif
ifdef X86_SKIPPED
	@echo "== x86-64 tier runs skipped: Rosetta is not installed"
endif

# The sweeps that `test` samples, read in full: every cut, every window size, every budget around the least.
DEEP_ROUNDS ?= 16
DEEP_PKGS := cbor/test dsv/test json/test toml/test xml/test
test-deep:
	@mkdir -p build; for p in $(DEEP_PKGS); do \
		echo "== $$p (-define:ROUNDS=$(DEEP_ROUNDS))"; \
		$(ODIN) test $$p -o:minimal $(TEST_BASE_FLAGS) -define:ROUNDS=$(DEEP_ROUNDS) -define:TEST_TIMEOUT_SECONDS=3600 -out:build/test-deep-$$(echo $$p | tr / -) || exit 1; \
	done

test-asan:
	@mkdir -p build; for p in $(TEST_PKGS); do \
		echo "== $$p (address)"; \
		$(SAN_RUN) $(ODIN) test $$p -o:minimal -debug -sanitize:address $(SAN_FLAGS) -out:build/asan-$$(echo $$p | tr / -) || exit 1; \
	done
	@for p in $(GAP_PKGS); do \
		echo "== $$p (address, no gaps, no rewalk)"; \
		$(SAN_RUN) $(ODIN) test $$p -o:minimal -debug -sanitize:address $(SAN_FLAGS) -define:JSON_GAPS=false -define:JSON_REWALK=false -out:build/asan-$$(echo $$p | tr / -)-nogaps || exit 1; \
	done

test-tsan:
	@mkdir -p build; for p in $(TEST_PKGS); do \
		echo "== $$p (thread)"; \
		$(SAN_RUN) $(ODIN) test $$p -o:speed -debug -sanitize:thread $(SAN_FLAGS) -out:build/tsan-$$(echo $$p | tr / -) || exit 1; \
	done
	@for p in $(GAP_PKGS); do \
		echo "== $$p (thread, no gaps)"; \
		$(SAN_RUN) $(ODIN) test $$p -o:speed -debug -sanitize:thread $(SAN_FLAGS) -define:JSON_GAPS=false -out:build/tsan-$$(echo $$p | tr / -)-nogaps || exit 1; \
	done
