ODIN ?= odin

# The oldest Odin release that passes `make lint`. It is checked once per make run, by the first make and not by the
# makes that tools/gate.py and the sanitizer targets start, which inherit ODIN_CHECKED.
MIN_ODIN := dev-2026-11
ifndef ODIN_CHECKED
ifeq ($(filter help,$(MAKECMDGOALS)),)
ODIN_PROBLEM := $(shell python3 tools/checks.py odin "$(ODIN)")
ifneq ($(ODIN_PROBLEM),)
$(error $(ODIN_PROBLEM))
endif
export ODIN_CHECKED := 1
endif
endif

# A plain `make` runs the gate.
.DEFAULT_GOAL := gate

# The library packages, and the test packages that read them.
LIB_PKGS  := core/spell core/regex core host core/kernel core/compose core/diff core/rules core/build core/typed core/write core/records core/schema core/model json dsv toml xml yaml cbor
TEST_PKGS := core/spell/test core/regex/test host/test core/kernel/test core/test core/write/test core/records/test json/test dsv/test toml/test xml/test yaml/test cbor/test
# The packages the tests share, checked by `lint` and built through their imports.
SUPPORT_PKGS := walktest bench/timing xml/test/oracle
# The benchmark programs, which `lint` and the gate compile.
BENCH_PKGS := bench bench/doc bench/editbench bench/paths bench/typed bench/write bench/records bench/schema bench/schema_csv bench/schema_json
# The test packages whose loops are compiled for the tier `-define:TIER` names.
TIER_PKGS := core/kernel/test
TEST_OPT  := -o:minimal
# A leak or a bad free fails the test that made it.
TEST_MEMORY := -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
# A text read on threads is cut at every byte in pieces of one byte, and at -o:speed chains run over several records.
TEST_PIECES := -define:RECORDS_SLICE=1 -define:RECORDS_FAN_AFTER=1 -define:RECORDS_SPARSE=1000000000
TEST_CHAINS := -define:RECORDS_SLICE=16 -define:RECORDS_FAN_AFTER=1 -define:RECORDS_SPARSE=1000000000
BUILD     := build
# The optimization of the command line, which a release build overrides for its target.
OPT       ?= -o:speed

# One target per compile, so `make -j` builds the tests in parallel and each compile writes its own binary.
TEST_MINIMAL  := $(foreach p,$(TEST_PKGS),$(BUILD)/test/minimal/$(p))
TEST_SPEED    := $(foreach p,$(TEST_PKGS),$(BUILD)/test/speed/$(p))
TEST_TARGETS  := $(TEST_MINIMAL) $(TEST_SPEED)
ASAN_TARGETS  := $(foreach p,$(TEST_PKGS),$(BUILD)/test/asan/$(p))
# The test packages that run threads, which only `host` does.
TSAN_PKGS     := host/test
TSAN_TARGETS  := $(foreach p,$(TSAN_PKGS),$(BUILD)/test/tsan/$(p))
X86_TARGETS   := $(foreach o,none speed,$(foreach t,0 1,$(foreach p,$(TEST_PKGS),$(BUILD)/test/x86/$(o)/$(t)/$(p))))

VET := -vet-unused-variables -vet-shadowing -vet-using-stmt -vet-cast -vet-semicolon -vet-tabs -vet-unused-imports -strict-style
LINT_FLAGS := $(VET) -warnings-as-errors -terse-errors -max-error-count:500

.PHONY: help check gate build-cli test test-examples test-lib test-one test-cli test-jq diff diff-suite diff-schema diff-schema-csv diff-schema-gen ecma-diff diff-xml test-x86 test-wide test-asan test-tsan test-f32 test-sweep lint lint-man lint-fixtures api-write bench bench-doc bench-paths bench-typed bench-records bench-schema bench-schema-peers bench-write bench-peers bench-cli fixtures surface \
	$(TEST_TARGETS) $(ASAN_TARGETS) $(TSAN_TARGETS) $(X86_TARGETS)

# The bench lanes' probes and peers, and the fixtures they read. BENCH_CC, BENCH_CXX and BENCH_CARGO name the compilers
# that build the peers. BENCH_FILES and RECORD_FILES name the fixtures of bench-doc and bench-records, LANES the lanes
# of bench-typed and bench-write. Each runner has its own default.
BENCH      := $(BUILD)/bench
BENCH_CC    ?= cc
BENCH_CXX   ?= c++
BENCH_CARGO ?= cargo
BENCH_FILES ?=
RECORD_FILES ?=
LANES ?=

# `$(call odin_each,VERB,PACKAGES,FLAGS,LABEL)` runs `odin VERB` over each package and stops at the first failure.
define odin_each
@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && for p in $(2); do \
	echo "== $$p$(4)"; $(ODIN) $(1) $$p $(3) $(if $(filter test,$(1)),-out:$$d/test) || exit 1; \
done
endef

# The command line at $(OPT). STURY_VERSION names the version `-V` prints, the commit's short hash by default.
ifeq ($(shell uname -s),Darwin)
CLI_LINK := "-extra-linker-flags:-L$(shell xcrun --show-sdk-path)/usr/lib/system -lsystem_m -lsystem_c -lsystem_kernel -lsystem_pthread -lsystem_malloc"
else ifeq ($(shell uname -s),Linux)
CLI_LINK := -reloc-mode:static
endif
CLI_VERSION := $(or $(STURY_VERSION),$(shell git log -1 --format=%h 2>/dev/null),dev)
CLI_DEFINES := -define:STURY_VERSION='"$(CLI_VERSION)"'
build-cli:
	@mkdir -p $(BUILD)
	$(ODIN) build cmd/stury $(OPT) $(CLI_LINK) $(CLI_DEFINES) -out:$(BUILD)/stury

help:
	@echo "make check        the checks the files you changed can reach (seconds)"
	@echo "make gate         everything a branch passes before it lands (python3 tools/gate.py full adds the long runs)"
	@echo "make test         library suites, examples, CLI smoke cases, jq corpus"
	@echo "make test-lib     the library suites (-j runs the compiles at once)"
	@echo "make test-one P=<package> T=<test>   one test"
	@echo "make test-cli, test-jq, test-examples, diff   the CLI and examples"
	@echo "make ecma-diff    core/regex's ECMA patterns against Node's RegExp (needs node on PATH)"
	@echo "make lint         vet and surface checks on every target; lint-man, lint-fixtures the docs"
	@echo "make api-write    regenerate API.txt and API_SHARED.txt after a public change"
	@echo "make test-asan, test-tsan, test-x86, test-wide, test-f32   sanitizers, x86 tiers, binary32"
	@echo "make build-cli    build/stury (OPT=, STURY_VERSION=)"
	@echo "make diff-schema  the schema lane's peers against the Python jsonschema package (needs uv)"
	@echo "make diff-schema-csv  the check of CSV and TSV against a Python cell-rule converter and jsonschema (needs uv)"
	@echo "make diff-schema-gen  the check over generated schemas against jsonschema (needs uv)"
	@echo "make bench-doc, bench-paths, bench-typed, bench-records, bench-schema, bench-write, bench-cli   see bench/README.md"
	@echo "ODIN=<path> names the compiler, and needs release $(MIN_ODIN) or later."

# The checks a change can reach, in `tools/gate.py`: `check` while editing, `gate` before a branch lands. `gate` is the
# merge tier. `python3 tools/gate.py full` adds the long randomized runs.
check:
	@ODIN=$(ODIN) python3 tools/gate.py quick

gate:
	@ODIN=$(ODIN) python3 tools/gate.py merge

# The library suites, the examples, then the command line against its smoke cases and the jq corpus.
test: test-lib test-examples test-cli test-jq

# Each program under examples/ is built and run from here, and its output is the `expected.txt` beside it. The JSON
# walks and dsv passes it links are the counts in `examples/links.txt`. On x86-64 each dsv pass is built once per vector
# tier, and the v2 copies are the count.
DSV_PASS := $(if $(filter x86_64 amd64,$(shell uname -m)),pass_v2,pass_base)
test-examples:
	@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && for e in examples/*/; do e=$${e%/}; echo "== $$e"; \
		$(ODIN) build $$e $(TEST_OPT) -collection:stury=. -out:$$d/x && $$d/x > $$d/out && diff $$d/out $$e/expected.txt || exit 1; \
		want=$$(awk -v n=$${e#examples/} '$$1 == n {print $$2, $$3}' examples/links.txt); \
		got="$$(nm $$d/x | grep -c 'json::st_value:') $$(nm $$d/x | grep -c 'dsv::$(DSV_PASS):')"; \
		[ "$$got" = "$$want" ] || { echo "$$e links $$got (walks passes), examples/links.txt says $$want" >&2; exit 1; }; \
	done

# The library suites at -o:minimal and at -o:speed, where the optimizer reasons about loads that the walk makes past an
# input's end. Each compile is its own target, so `make -j test-lib` runs them at once.
test-lib: $(TEST_TARGETS)

# `make test-one P=json/test T=test_name` runs one test of one test package. A failed suite names the test to pass as T.
test-one:
	@[ -n "$(P)" ] && [ -n "$(T)" ] || { echo "usage: make test-one P=<package dir> T=<test name>" >&2; exit 2; }
	$(ODIN) test $(P) $(TEST_OPT) $(TEST_MEMORY) $(TEST_PIECES) -define:ODIN_TEST_NAMES=$(T) -out:$(BUILD)/test-one

# The command line end to end on what jq has not, held to smoke.floor.
test-cli: build-cli
	@echo "== cmd/stury"
	python3 cmd/stury/test/smoke.py $(BUILD)/stury
	python3 cmd/stury/test/toml_suite.py $(BUILD)/stury
	python3 cmd/stury/test/yaml_suite.py $(BUILD)/stury

# jq 1.8.2's corpus and cli.tsv, every row passing.
test-jq: build-cli
	python3 cmd/stury/test/jq_suite.py $(BUILD)/stury

# The command line against jq 1.8.2: the suite in diff mode, and jq_diff with regex_diff over each seed, a target per
# seed so that `make -j` runs the seeds at once. Without jq 1.8.2 on PATH only the jq suite runs.
DIFF_SEEDS ?= 77 1016 5
DIFF_SEED_TARGETS := $(DIFF_SEEDS:%=diff-seed-%)
.PHONY: $(DIFF_SEED_TARGETS)
ifeq ($(shell jq --version 2>/dev/null),jq-1.8.2)
diff: diff-suite $(DIFF_SEED_TARGETS)
else
diff: test-jq
	@echo "== diff: no jq 1.8.2 on PATH, only the jq suite ran"
endif
diff-suite: build-cli
	STURY_TEST_TIMEOUT=60 python3 cmd/stury/test/jq_suite.py $(BUILD)/stury --diff
$(DIFF_SEED_TARGETS): diff-seed-%: build-cli
	python3 cmd/stury/test/jq_diff.py $(BUILD)/stury --seed=$*
	python3 cmd/stury/test/regex_diff.py $(BUILD)/stury --seed=$*

# core/regex's ECMA patterns against Node's RegExp. Without node on PATH it says so and compares nothing.
ecma-diff:
	python3 cmd/stury/test/ecma_diff.py --odin $(ODIN)

# The XML walk against expat (pyexpat) on seeded random and broken texts, with xmllint as the third opinion. XML_DIFF_SEEDS
# and XML_DIFF_CASES set the runs.
XML_DIFF_SEEDS ?= 1 2 3
XML_DIFF_CASES ?= 40000
diff-xml:
	@mkdir -p $(BUILD)
	$(ODIN) build xml/test/oracle $(TEST_OPT) -out:$(BUILD)/xml_oracle
	@for seed in $(XML_DIFF_SEEDS); do python3 cmd/stury/test/xml_diff.py $(BUILD)/xml_oracle --seed=$$seed --cases=$(XML_DIFF_CASES) || exit 1; done

# The XML conformance documents, fetched once, which the package's tests read.
XML_SUITE := xml/test/conformance/files
$(XML_SUITE):
	python3 xml/test/conformance/fetch.py
$(filter %/xml/test,$(TEST_TARGETS) $(ASAN_TARGETS) $(TSAN_TARGETS) $(X86_TARGETS)): | $(XML_SUITE)

$(TEST_MINIMAL): $(BUILD)/test/minimal/%:
	@mkdir -p $(@D)
	@echo "== $* (-o:minimal)"
	@$(ODIN) test $* $(TEST_OPT) $(TEST_MEMORY) $(TEST_PIECES) -out:$@ || { echo "== $* (-o:minimal) failed: make test-one P=$* T=<failed test's name>"; exit 1; }

$(TEST_SPEED): $(BUILD)/test/speed/%:
	@mkdir -p $(@D)
	@echo "== $* (-o:speed)"
	@$(ODIN) test $* -o:speed $(TEST_MEMORY) $(TEST_CHAINS) -out:$@ || { echo "== $* (-o:speed) failed: make test-one P=$* T=<failed test's name> runs it at -o:minimal"; exit 1; }

# The x86-64 tiers v2 and v3 in a build for Odin's default CPU, as a caller's build is, at -o:none, where no kernel
# is inlined into the tier's procedures, and at -o:speed. TIER picks the tier of the kernel tests' loops and of `tier()`.
# On Apple silicon they run under Rosetta. v4 runs only on a machine with AVX-512 (TIER=2), and `lint` compiles it.
# X86_THREADS sets each suite's test threads: on a host with as many cores as `make -j` runs suites, one thread each
# keeps a timed test from sharing its core.
test-x86: $(X86_TARGETS)

# `build/test/x86/OPT/TIER/PACKAGE` runs one package at one tier.
$(X86_TARGETS): $(BUILD)/test/x86/%:
	@mkdir -p $(@D)
	@o=$(word 1,$(subst /, ,$*)); t=$(word 2,$(subst /, ,$*)); p=$(patsubst $(word 1,$(subst /, ,$*))/$(word 2,$(subst /, ,$*))/%,%,$*); \
	echo "== $$p (x86 tier $$t -o:$$o)"; \
	$(ODIN) test $$p -o:$$o -target:darwin_amd64 -define:TIER=$$t $(if $(X86_THREADS),-define:ODIN_TEST_THREADS=$(X86_THREADS)) -out:$@ || \
		{ echo "== $$p (x86 tier $$t -o:$$o) failed"; exit 1; }

# Each x86 tier on a machine that lacks it: each package built for linux_amd64 with the tier forced, and run under
# Intel SDE (`SDE=sde64`) emulating a Nehalem for v2 (x86-64-v2, no PCLMULQDQ), a Haswell for v3 and a Sapphire Rapids
# for v4.
SDE ?= sde64
test-wide: | $(XML_SUITE)
	@mkdir -p $(BUILD)/wide
	@for spec in 0:nhm 1:hsw 2:spr; do t=$${spec%%:*}; cpu=$${spec##*:}; for p in $(TEST_PKGS); do \
		echo "== $$p (tier $$t on $$cpu)"; \
		$(ODIN) build $$p -build-mode:test -target:linux_amd64 -o:minimal $(TEST_MEMORY) $(TEST_PIECES) \
			-define:ODIN_TEST_FANCY=false -define:TIER=$$t -out:$(BUILD)/wide/test || exit 1; \
		$(SDE) -$$cpu -- $(BUILD)/wide/test || exit 1; \
	done; done

# The sweeps the edit loop narrows: the string writer at every length and offset up to 80, and a spine's records with
# 16 bytes at either end broken in turn. The gate's full tier runs them.
test-sweep:
	@mkdir -p $(BUILD)/test/sweep
	$(ODIN) test json/test -o:minimal $(TEST_MEMORY) $(TEST_PIECES) -define:FULL_SWEEP=true \
		-define:ODIN_TEST_NAMES=json_tests.every_byte_at_every_offset,json_tests.records_validate_a_spine \
		-out:$(BUILD)/test/sweep/json

# Every binary32 pattern read back and checked shortest, on F32_THREADS threads at -o:speed, which the gate's full tier runs.
F32_THREADS ?= 6
test-f32:
	@mkdir -p $(BUILD)/test/f32
	$(ODIN) test core/spell/test -o:speed -define:F32_STRIDE=1 -define:F32_THREADS=$(F32_THREADS) \
		-define:ODIN_TEST_NAMES=spell_tests.f32_exhaustive -out:$(BUILD)/test/f32/spell

# The command line under a sanitizer, with its smoke cases and jq corpus. TSan otherwise sleeps a second at every exit of
# a process that ran threads, which is most of smoke.py's wall time.
SAN_ENV := STURY_SANITIZED=1 STURY_TEST_TIMEOUT=300 ASAN_OPTIONS=use_sigaltstack=0:detect_leaks=0 TSAN_OPTIONS=atexit_sleep_ms=0
SAN_STACK := ulimit -s 65520 2>/dev/null || ulimit -s unlimited

# `$(call sanitized_cli,SANITIZER)` builds the command line with -sanitize:SANITIZER and runs both suites on it.
define sanitized_cli
@mkdir -p $(BUILD)
$(ODIN) build cmd/stury $(OPT) -debug -sanitize:$(1) $(CLI_LINK) $(CLI_DEFINES) -out:$(BUILD)/stury-$(1)
$(SAN_STACK); STURY_SANITIZER=$(1) $(SAN_ENV) python3 cmd/stury/test/smoke.py $(BUILD)/stury-$(1)
$(SAN_STACK); STURY_SANITIZER=$(1) $(SAN_ENV) python3 cmd/stury/test/jq_suite.py $(BUILD)/stury-$(1)
endef

.PHONY: test-asan-cli test-tsan-cli
test-asan-cli:
	$(call sanitized_cli,address)
test-tsan-cli:
	$(call sanitized_cli,thread)

test-asan: $(ASAN_TARGETS)
	@$(MAKE) --no-print-directory test-asan-cli

# Under the sanitizer a text read on threads is cut in pieces of 16 bytes: the -o:minimal suites take the pieces of one byte.
$(ASAN_TARGETS): $(BUILD)/test/asan/%:
	@mkdir -p $(@D)
	@echo "== $* (address)"
	@$(ODIN) test $* -o:minimal -sanitize:address -debug $(TEST_CHAINS) -out:$@ || { echo "== $* (address) failed"; exit 1; }

test-tsan: $(TSAN_TARGETS)
	@$(MAKE) --no-print-directory test-tsan-cli

$(TSAN_TARGETS): $(BUILD)/test/tsan/%:
	@mkdir -p $(@D)
	@echo "== $* (thread)"
	@TSAN_OPTIONS=atexit_sleep_ms=0 $(ODIN) test $* -o:speed -sanitize:thread -debug -out:$@ || { echo "== $* (thread) failed"; exit 1; }

# Host, then the other architectures' sources: x86-64 and a target with neither NEON nor x86 vectors.
lint:
	python3 tools/checks.py imports
	python3 tools/checks.py words
	python3 tools/checks.py globals
	python3 tools/checks.py api
	$(call odin_each,check,$(LIB_PKGS) $(TEST_PKGS) $(SUPPORT_PKGS),-no-entry-point $(LINT_FLAGS),)
	$(call odin_each,check,$(BENCH_PKGS),$(LINT_FLAGS),)
	$(ODIN) check cmd/stury $(LINT_FLAGS)
	$(ODIN) check cmd/stury $(LINT_FLAGS) -target:linux_amd64
	@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && echo "== cmd/stury (windows_amd64 objects)" && \
		$(ODIN) build cmd/stury -build-mode:obj -target:windows_amd64 -windows-sdk-root:$$d $(LINT_FLAGS) -out:$$d/stury.obj
	$(call odin_each,check,$(LIB_PKGS) $(TEST_PKGS) $(SUPPORT_PKGS),-no-entry-point $(LINT_FLAGS) -target:linux_amd64, (linux_amd64))
	@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && for p in $(TIER_PKGS); do for o in none speed; do \
		echo "== $$p (linux_amd64 v4 -o:$$o)"; \
		$(ODIN) test $$p -build-mode:obj -target:linux_amd64 -define:TIER=2 -o:$$o $(LINT_FLAGS) -out:$$d/t.o || exit 1; \
	done; done
	$(call odin_each,check,$(LIB_PKGS),-no-entry-point $(LINT_FLAGS) -target:linux_riscv64, (linux_riscv64))

# The public declarations of each library package, sorted. `api` compares their signatures with API.txt and
# API_SHARED.txt, and `python3 tools/checks.py api --write` regenerates both.
surface:
	python3 tools/checks.py surface

api-write:
	python3 tools/checks.py api --write

# The man page, and the generated fixtures against bench/manifest.toml's hashes, which hold for the CPython the
# generators were checked on. `lint-fixtures` fetches the corpus and generates the files in memory, writing nothing
# under bench/fixtures.
lint-man:
	mandoc -T lint -W warning docs/stury.1

lint-fixtures:
	python3 bench/fetch.py corpus
	python3 bench/gen.py --check > /dev/null

# Kernel timings at release optimization, of the tier at place TIER of `Tier`. ROUNDS, CASES and COUNT pass through
# to run.py.
TIER ?= 0
bench: ROUNDS ?= 5
bench:
	@mkdir -p $(BUILD)
	$(ODIN) build bench -o:speed -define:TIER=$(TIER) -out:$(BUILD)/kernelbench
	ROUNDS=$(ROUNDS) python3 -I bench/run.py $(BUILD)/kernelbench

# The bench fixtures: downloads the pinned corpus and the peers' sources (bench/fetch.py, checked by SHA-256), then
# writes the synthetic files and fails when one's hash is not bench/manifest.toml's (bench/gen.py).
fixtures:
	python3 bench/fetch.py
	python3 bench/gen.py

# The path lanes' probe at -o:speed, then paths.py over the peers `bench-doc` built. Its lanes are fixed. ROUNDS passes
# through.
bench-paths: ROUNDS ?= 5
bench-paths:
	@mkdir -p $(BENCH)
	$(ODIN) build bench/paths -o:speed -out:$(BENCH)/paths
	ROUNDS=$(ROUNDS) python3 bench/paths.py

# The typed read's probe at -o:speed, the peers, then typed.py. ROUNDS and LANES pass through.
bench-typed: ROUNDS ?= 5
bench-typed: bench-peers
	@mkdir -p $(BENCH)
	$(ODIN) build bench/typed -o:speed -out:$(BENCH)/typed
	ROUNDS=$(ROUNDS) python3 bench/typed.py $(LANES)

# The record lanes on the NDJSON and CSV fixtures, beside the peers' record readers. ROUNDS and RECORD_FILES pass
# through.
bench-records: ROUNDS ?= 5
bench-records: bench-peers
	$(ODIN) build bench/records -o:speed -out:$(BENCH)/records
	ROUNDS=$(ROUNDS) python3 bench/records.py $(RECORD_FILES)

# The schema lane's stury probe and the validators whose toolchains are present: Blaze through cmake, jsonschema-rs and
# boon through cargo. The first Rust build downloads the crates bench/peers/rust-schema/Cargo.lock names, and the Blaze build
# takes a few minutes.
bench-schema-peers:
	@mkdir -p $(BENCH)
	python3 bench/fetch.py corpus schema archive
	python3 bench/gen.py logs.json logs.ndjson schema/logs.schema.json schema/twitter.schema.json schema/citm.schema.json \
		schema/applicator.schema.json schema/applicator.ndjson schema/twitter.json schema/citm.json schema/logs.json >/dev/null
	$(ODIN) build bench/schema -o:speed -out:$(BENCH)/schema_probe
	@if command -v cmake >/dev/null && [ -d $(BENCH)/deps/blaze ]; then \
		cmake -S bench/peers/blaze -B $(BENCH)/blaze -DCMAKE_BUILD_TYPE=Release -DBLAZE_DIR=$(abspath $(BENCH)/deps/blaze) \
			-DBUILD_SHARED_LIBS=OFF >$(BENCH)/blaze-build.log 2>&1 \
		&& cmake --build $(BENCH)/blaze --target blaze_bench >>$(BENCH)/blaze-build.log 2>&1 && echo "blaze: built" \
		|| echo "blaze: build failed, see $(BENCH)/blaze-build.log"; \
	else echo "blaze: left out (cmake is not on PATH or the Blaze source is missing)"; fi
	@if command -v $(BENCH_CARGO) >/dev/null; then \
		CARGO_TARGET_DIR=$(abspath $(BENCH)/rust-schema) $(BENCH_CARGO) build --release --locked \
			--manifest-path bench/peers/rust-schema/Cargo.toml && echo "jsonschema, boon: built"; \
	else echo "jsonschema, boon: left out ($(BENCH_CARGO) is not on PATH)"; fi

# The schema lane, stury beside the peers, on the 19 fixtures. ROUNDS and the fixture names in SCHEMA_FIXTURES pass through.
SCHEMA_FIXTURES ?=
bench-schema: ROUNDS ?= 5
bench-schema: bench-schema-peers
	ROUNDS=$(ROUNDS) python3 bench/schema.py $(SCHEMA_FIXTURES)

# The peers' verdicts, instance by instance, against the Python `jsonschema` package (uv fetches the pinned version, or
# finds it offline). ORACLE_ARGS=--suite also holds the oracle to the vendored JSON-Schema-Test-Suite.
ORACLE_ARGS ?=
diff-schema: bench-schema-peers
	uv run --offline --no-project --with jsonschema==4.26.0 python3 bench/schema_oracle.py $(ORACLE_ARGS) $(SCHEMA_FIXTURES)

# The check of CSV and TSV against an independent converter of the cell rule and the same package, over generated tables.
CSV_ORACLE_ARGS ?=
diff-schema-csv:
	@mkdir -p $(BUILD)/oracle
	$(ODIN) build bench/schema_csv $(TEST_OPT) -collection:stury=. -out:$(BUILD)/oracle/schema_csv
	uv run --offline --no-project --with jsonschema==4.26.0 python3 -I bench/csv_oracle.py $(BUILD)/oracle/schema_csv $(CSV_ORACLE_ARGS)

# The check over generated schemas and instances against the same package.
GEN_ORACLE_ARGS ?=
diff-schema-gen:
	@mkdir -p $(BUILD)/oracle
	$(ODIN) build bench/schema_json $(TEST_OPT) -collection:stury=. -out:$(BUILD)/oracle/schema_json
	uv run --offline --no-project --with jsonschema==4.26.0 python3 -I bench/schema_gen_oracle.py $(BUILD)/oracle/schema_json $(GEN_ORACLE_ARGS)

# The peers whose toolchain and sources are present: yyjson, simdjson (threaded, as its document_stream runs stage 1 in a
# thread of its own), and the Rust binaries (sonic-rs, serde_json, simd-csv). The first Rust build downloads the crates
# bench/peers/rust/Cargo.lock names.
bench-peers:
	@mkdir -p $(BENCH)
	@if command -v $(BENCH_CC) >/dev/null && [ -f $(BENCH)/deps/yyjson/yyjson.c ]; then \
		$(BENCH_CC) -O3 -DNDEBUG -o $(BENCH)/yy_bench bench/peers/yy_bench.c \
			$(BENCH)/deps/yyjson/yyjson.c -I$(BENCH)/deps/yyjson && echo "yy: built"; \
	else echo "yy: left out ($(BENCH_CC) is not on PATH or the yyjson source is missing; run make fixtures)"; fi
	@if command -v $(BENCH_CXX) >/dev/null && [ -f $(BENCH)/deps/simdjson/simdjson.cpp ]; then \
		$(BENCH_CXX) -O3 -DNDEBUG -std=c++17 -pthread -o $(BENCH)/cpp_bench bench/peers/cpp_bench.cpp \
			$(BENCH)/deps/simdjson/simdjson.cpp -I$(BENCH)/deps/simdjson && echo "simd: built"; \
	else echo "simd: left out ($(BENCH_CXX) is not on PATH or the simdjson source is missing; run make fixtures)"; fi
	@if command -v $(BENCH_CARGO) >/dev/null; then \
		echo "cargo: building the Rust peers (the first build downloads crates)"; \
		CARGO_TARGET_DIR=$(abspath $(BENCH)/rust) $(BENCH_CARGO) build --release --locked \
			--manifest-path bench/peers/rust/Cargo.toml && echo "sonic, serde, simd-csv: built"; \
	else echo "sonic, serde, simd-csv: left out ($(BENCH_CARGO) is not on PATH)"; fi

# The command line against jq, jaq, gojq and yq on the fixtures and the corpus. Needs zsh, hyperfine and the tools
# installed (bench/README.md), and an idle machine for a quotable result. ROUNDS, RUNS and CASES (a regex of case names)
# pass through.
bench-cli: build-cli
	python3 bench/gen.py
	python3 bench/fetch.py corpus
	zsh bench/cli/jq_compare.sh

# The write lanes: stury's probe at -o:speed, the peers, then write.py. ROUNDS and LANES pass through.
bench-write: ROUNDS ?= 5
bench-write: bench-peers
	@mkdir -p $(BENCH)
	$(ODIN) build bench/write -o:speed -out:$(BENCH)/write
	ROUNDS=$(ROUNDS) python3 bench/write.py $(LANES)

# The document lanes' probe at -o:speed, the peers, then doc.py. ROUNDS and BENCH_FILES pass through.
bench-doc: ROUNDS ?= 5
bench-doc: bench-peers
	$(ODIN) build bench/doc -o:speed -out:$(BENCH)/doc
	ROUNDS=$(ROUNDS) python3 bench/doc.py $(BENCH_FILES)
