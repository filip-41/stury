ODIN ?= odin

MIN_ODIN := dev-2026-11
ifndef ODIN_CHECKED
ifeq ($(filter help,$(MAKECMDGOALS)),)
ODIN_RELEASE := $(shell $(ODIN) version 2>/dev/null | grep -o 'dev-[0-9]*-[0-9]*[a-z]*')
ifeq ($(ODIN_RELEASE),)
$(error ODIN=$(ODIN) does not run or names no release: pass ODIN=<path to odin>, release $(MIN_ODIN) or later)
endif
ifneq ($(firstword $(sort $(MIN_ODIN) $(ODIN_RELEASE))),$(MIN_ODIN))
$(error $(ODIN) is $(ODIN_RELEASE): stury needs Odin $(MIN_ODIN) or later)
endif
export ODIN_CHECKED := 1
endif
endif

# A plain `make` runs the gate.
.DEFAULT_GOAL := gate

# The library packages
LIB_PKGS  := core/spell core/regex core host core/kernel core/compose core/diff core/rules core/css core/build core/typed core/write core/records core/schema core/model json dsv toml xml yaml cbor html jq
TEST_PKGS := core/spell/test core/regex/test host/test core/kernel/test core/test core/diff/test core/model/test core/schema/test core/css/test core/write/test core/records/test json/test dsv/test toml/test xml/test yaml/test cbor/test html/test jq/test
# The packages the tests share, checked by `lint`
SUPPORT_PKGS := testkit bench/timing bench/formats tools/tests/oracles/xml tools/tests/oracles/model tools/tests/oracles/regex tools/tests/oracles/schema/csv tools/tests/oracles/schema/gen
BENCH_PKGS := $(wildcard bench/lanes/*/stury)
HTML_INTERNALS := -define:STURY_HTML_INTERNALS=true
TIER_PKGS := core/kernel/test
TEST_OPT  := -o:minimal
TEST_MEMORY := -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
# A text read on threads is cut at every byte in pieces of one byte, and at -o:speed chains run over several records.
TEST_PIECES := -define:RECORDS_SLICE=1 -define:RECORDS_FAN_AFTER=1 -define:RECORDS_SPARSE=1000000000
TEST_CHAINS := -define:RECORDS_SLICE=16 -define:RECORDS_FAN_AFTER=1 -define:RECORDS_SPARSE=1000000000
BUILD     := build
# The optimization of the command line
OPT       ?= -o:speed

# Compile targets
TEST_MINIMAL  := $(foreach p,$(TEST_PKGS),$(BUILD)/test/minimal/$(p))
TEST_SPEED    := $(foreach p,$(TEST_PKGS),$(BUILD)/test/speed/$(p))
TEST_TARGETS  := $(TEST_MINIMAL) $(TEST_SPEED)
ASAN_TARGETS  := $(foreach p,$(TEST_PKGS),$(BUILD)/test/asan/$(p))
# The test packages that run threads
TSAN_PKGS     := host/test
TSAN_TARGETS  := $(foreach p,$(TSAN_PKGS),$(BUILD)/test/tsan/$(p))
# X86_OPTS and WIDE_TIERS narrow test-x86 and test-wide
X86_OPTS      ?= none speed
X86_TARGETS   := $(foreach o,$(X86_OPTS),$(foreach t,0 1,$(foreach p,$(TEST_PKGS),$(BUILD)/test/x86/$(o)/$(t)/$(p))))

VET := -vet-unused-variables -vet-shadowing -vet-using-stmt -vet-cast -vet-semicolon -vet-tabs -vet-unused-imports -strict-style
LINT_FLAGS := $(VET) -warnings-as-errors -terse-errors -max-error-count:500

.PHONY: help check gate build-cli build-cli-minimal test test-examples test-lib test-one test-py test-cli test-jq diff diff-suite diff-schema diff-schema-csv diff-schema-gen diff-model ecma-diff diff-xml test-x86 test-wide test-asan test-asan-lib test-tsan test-f32 test-sweep lint lint-man lint-fixtures names-write bench bench-doc bench-paths bench-typed bench-records bench-schema bench-schema-peers bench-write bench-edit bench-model bench-peers bench-cli bench-files fixtures \
	$(TEST_TARGETS) $(ASAN_TARGETS) $(TSAN_TARGETS) $(X86_TARGETS)

# The bench lanes: ROUNDS, ARMS, CASES, COUNT and TIER reach the runner as environment variables, ROWS names rows
BENCH_RUN := uv run --project bench bench
ROWS ?=

# `$(call odin_check,PACKAGES,FLAGS,LABEL)` runs `odin check` over each package and stops at the first failure.
define odin_check
@for p in $(1); do echo "== $$p$(3)"; $(ODIN) check $$p $(2) || exit 1; done
endef

# The command line at $(OPT). STURY_VERSION names the version `-V` prints, the commit's short hash by default.
ifeq ($(shell uname -s),Darwin)
CLI_LINK := "-extra-linker-flags:-L$(shell xcrun --show-sdk-path)/usr/lib/system -lsystem_m -lsystem_c -lsystem_kernel -lsystem_pthread -lsystem_malloc -Wl,-dead_strip_dylibs"
else ifeq ($(shell uname -s),Linux)
CLI_LINK := -reloc-mode:static
endif
CLI_VERSION := $(or $(STURY_VERSION),$(shell git log -1 --format=%h 2>/dev/null),dev)
CLI_DEFINES := -define:STURY_VERSION='"$(CLI_VERSION)"'
build-cli:
	@mkdir -p $(BUILD)
	$(ODIN) build cmd/stury $(OPT) $(CLI_LINK) $(CLI_DEFINES) -out:$(BUILD)/stury

# The command line at -o:minimal, for trying what a change answers: it compiles in seconds, where -o:speed takes minutes.
build-cli-minimal:
	@mkdir -p $(BUILD)
	$(ODIN) build cmd/stury $(TEST_OPT) $(CLI_LINK) $(CLI_DEFINES) -out:$(BUILD)/stury-minimal

help:
	@echo "make check        the checks the files you changed can reach (seconds)"
	@echo "make gate         everything a branch passes before it lands (python3 tools/gate.py full adds the long runs)"
	@echo "make test         library suites, examples, CLI smoke cases, jq corpus"
	@echo "make test-lib     the library suites (-j runs the compiles at once)"
	@echo "make test-one P=<package> T=<test>   one test"
	@echo "make test-cli, test-jq, test-examples, diff   the CLI and examples"
	@echo "make test-py      every test of tools/tests, the oracles included"
	@echo "make ecma-diff    core/regex's ECMA patterns against Node's RegExp (needs node on PATH)"
	@echo "make lint         vet, import and entry checks on every target; lint-man, lint-fixtures the docs"
	@echo "make names-write  regenerate each format's names.odin from tools/names.txt"
	@echo "make test-asan, test-tsan, test-x86, test-wide, test-f32   sanitizers, x86 tiers, binary32"
	@echo "make build-cli    build/stury (OPT=, STURY_VERSION=)"
	@echo "make build-cli-minimal   build/stury-minimal, built in seconds for trying a change (not for timing)"
	@echo "make diff-schema  the check on the schema lane's fixtures against the Python jsonschema package (needs uv)"
	@echo "make diff-schema-csv  the check of CSV and TSV against a Python cell-rule converter and jsonschema (needs uv)"
	@echo "make diff-schema-gen  the check over generated schemas against jsonschema (needs uv)"
	@echo "make diff-model       the errors of model.load against pydantic (needs uv)"
	@echo "make bench-doc, bench-paths, bench-typed, bench-records, bench-schema, bench-write, bench-edit, bench-model, bench-cli, bench-files   see bench/README.md"
	@echo "ODIN=<path> names the compiler, and needs release $(MIN_ODIN) or later."

check:
	@ODIN=$(ODIN) python3 tools/gate.py quick

gate:
	@ODIN=$(ODIN) python3 tools/gate.py merge

# The library suites, the examples, then the command line against its smoke cases and the jq corpus.
test: test-lib test-examples test-cli test-jq

# Each program under examples/ against its expected.txt
DSV_PASS := $(if $(filter x86_64 amd64,$(shell uname -m)),pass_v2,pass_base)
test-examples:
	@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && for e in examples/*/; do e=$${e%/}; echo "== $$e"; \
		$(ODIN) build $$e $(TEST_OPT) -collection:stury=. -out:$$d/x && $$d/x > $$d/out && diff $$d/out $$e/expected.txt || exit 1; \
		want=$$(awk -v n=$${e#examples/} '$$1 == n {print $$2, $$3}' examples/links.txt); \
		got="$$(nm $$d/x | grep -c 'json::st_value:') $$(nm $$d/x | grep -c 'dsv::$(DSV_PASS):')"; \
		[ "$$got" = "$$want" ] || { echo "$$e links $$got (walks passes), examples/links.txt says $$want" >&2; exit 1; }; \
	done

# The library suites at -o:minimal and at -o:speed
test-lib: $(TEST_TARGETS)

test-one:
	@[ -n "$(P)" ] && [ -n "$(T)" ] || { echo "usage: make test-one P=<package dir> T=<test name>" >&2; exit 2; }
	$(ODIN) test $(P) $(TEST_OPT) $(TEST_MEMORY) $(TEST_PIECES) -define:ODIN_TEST_NAMES=$(T) -out:$(BUILD)/test-one

# The pytest project of the tests: uv installs its pinned packages, N is the worker count
PYTEST = uv run --frozen --directory tools/tests pytest -n $(N)
N ?= auto
STURY_ABS = $(abspath $(BUILD))/stury

# Every test of the project, the oracles included, on a fresh build
test-py: build-cli
	$(PYTEST) --stury=$(STURY_ABS) --odin=$(ODIN)

test-cli: build-cli
	@echo "== cmd/stury"
	$(PYTEST) --stury=$(STURY_ABS) cli/test_smoke.py cli/test_conformance.py

# jq 1.8.2's corpus and cli.tsv
test-jq: build-cli
	$(PYTEST) --stury=$(STURY_ABS) cli/test_jq.py

# The command line against jq
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
	STURY_TEST_TIMEOUT=60 $(PYTEST) --stury=$(STURY_ABS) --diff cli/test_jq.py
$(DIFF_SEED_TARGETS): diff-seed-%: build-cli
	$(PYTEST) --stury=$(STURY_ABS) --seed=$* cli/test_jq_diff.py cli/test_regex_diff.py

# core/regex's ECMA patterns against Node's RegExp
ecma-diff:
	$(PYTEST) --odin=$(ODIN) oracles/regex

# The XML walk against expat (pyexpat) on seeded random and broken texts
diff-xml:
	$(PYTEST) --odin=$(ODIN) oracles/xml

# The XML conformance documents
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

test-x86: $(X86_TARGETS)

# `build/test/x86/OPT/TIER/PACKAGE` runs one package at one tier.
$(X86_TARGETS): $(BUILD)/test/x86/%:
	@mkdir -p $(@D)
	@o=$(word 1,$(subst /, ,$*)); t=$(word 2,$(subst /, ,$*)); p=$(patsubst $(word 1,$(subst /, ,$*))/$(word 2,$(subst /, ,$*))/%,%,$*); \
	echo "== $$p (x86 tier $$t -o:$$o)"; \
	$(ODIN) test $$p -o:$$o -target:darwin_amd64 -define:TIER=$$t $(if $(X86_THREADS),-define:ODIN_TEST_THREADS=$(X86_THREADS)) -out:$@ || \
		{ echo "== $$p (x86 tier $$t -o:$$o) failed"; exit 1; }

# Each x86 tier on a machine that lacks it
SDE ?= sde64
WIDE_TIERS ?= 0:nhm 1:hsw 2:spr
test-wide: | $(XML_SUITE)
	@mkdir -p $(BUILD)/wide
	@for spec in $(WIDE_TIERS); do t=$${spec%%:*}; cpu=$${spec##*:}; for p in $(TEST_PKGS); do \
		echo "== $$p (tier $$t on $$cpu)"; \
		$(ODIN) build $$p -build-mode:test -target:linux_amd64 -o:minimal $(TEST_MEMORY) $(TEST_PIECES) \
			-define:ODIN_TEST_FANCY=false -define:TIER=$$t -out:$(BUILD)/wide/test || exit 1; \
		$(SDE) -$$cpu -- $(BUILD)/wide/test || exit 1; \
	done; done

test-sweep:
	@mkdir -p $(BUILD)/test/sweep
	$(ODIN) test json/test -o:minimal $(TEST_MEMORY) $(TEST_PIECES) -define:FULL_SWEEP=true \
		-define:ODIN_TEST_NAMES=json_tests.every_byte_at_every_offset,json_tests.records_validate_a_spine \
		-out:$(BUILD)/test/sweep/json

F32_THREADS ?= 6
test-f32:
	@mkdir -p $(BUILD)/test/f32
	$(ODIN) test core/spell/test -o:speed -define:F32_STRIDE=1 -define:F32_THREADS=$(F32_THREADS) \
		-define:ODIN_TEST_NAMES=spell_tests.f32_exhaustive -out:$(BUILD)/test/f32/spell

SAN_ENV := STURY_SANITIZED=1 STURY_TEST_TIMEOUT=300 ASAN_OPTIONS=use_sigaltstack=0:detect_leaks=0 TSAN_OPTIONS=atexit_sleep_ms=0
SAN_STACK := ulimit -s 65520 2>/dev/null || ulimit -s unlimited

# `$(call sanitized_cli,SANITIZER)` builds the command line with -sanitize:SANITIZER and runs both suites on it.
define sanitized_cli
@mkdir -p $(BUILD)
$(ODIN) build cmd/stury $(OPT) -debug -sanitize:$(1) $(CLI_LINK) $(CLI_DEFINES) -out:$(BUILD)/stury-$(1)
$(SAN_STACK); STURY_SANITIZER=$(1) $(SAN_ENV) $(PYTEST) --stury=$(abspath $(BUILD))/stury-$(1) cli/test_smoke.py cli/test_jq.py
endef

.PHONY: test-asan-cli test-tsan-cli
test-asan-cli:
	$(call sanitized_cli,address)
test-tsan-cli:
	$(call sanitized_cli,thread)

test-asan: test-asan-lib
	@$(MAKE) --no-print-directory test-asan-cli
test-asan-lib: $(ASAN_TARGETS)

# Under the sanitizer a text read on threads is cut in pieces of 16 bytes
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

lint:
	python3 tools/checks.py imports
	python3 tools/checks.py entries
	python3 tools/checks.py names
	$(call odin_check,$(LIB_PKGS) $(filter-out html/test,$(TEST_PKGS)) $(SUPPORT_PKGS),-no-entry-point $(LINT_FLAGS),)
	$(ODIN) check html/test -no-entry-point $(LINT_FLAGS) $(HTML_INTERNALS)
	$(call odin_check,$(BENCH_PKGS),$(LINT_FLAGS),)
	$(ODIN) check cmd/stury $(LINT_FLAGS)
	$(ODIN) check cmd/stury $(LINT_FLAGS) -target:linux_amd64
	@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && echo "== cmd/stury (windows_amd64 objects)" && \
		$(ODIN) build cmd/stury -build-mode:obj -target:windows_amd64 -windows-sdk-root:$$d $(LINT_FLAGS) -out:$$d/stury.obj
	$(call odin_check,$(LIB_PKGS) $(filter-out html/test,$(TEST_PKGS)) $(SUPPORT_PKGS),-no-entry-point $(LINT_FLAGS) -target:linux_amd64, (linux_amd64))
	$(ODIN) check html/test -no-entry-point $(LINT_FLAGS) $(HTML_INTERNALS) -target:linux_amd64
	@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && for p in $(TIER_PKGS); do for o in none speed; do \
		echo "== $$p (linux_amd64 v4 -o:$$o)"; \
		$(ODIN) test $$p -build-mode:obj -target:linux_amd64 -define:TIER=2 -o:$$o $(LINT_FLAGS) -out:$$d/t.o || exit 1; \
	done; done
	$(call odin_check,$(LIB_PKGS),-no-entry-point $(LINT_FLAGS) -target:linux_riscv64, (linux_riscv64))

names-write:
	python3 tools/checks.py names --write

# The man page
lint-man:
	mandoc -T lint -W warning docs/stury.1

lint-fixtures:
	uv run --project bench bench fixtures --check > /dev/null

# The bench lanes
TIER ?= 0
bench:
	TIER=$(TIER) $(BENCH_RUN) kernel

# The bench fixtures
fixtures:
	uv run --project bench bench fixtures

bench-doc bench-paths bench-typed bench-records bench-write bench-schema bench-edit bench-model:
	$(BENCH_RUN) $(@:bench-%=%) $(ROWS)

bench-peers:
	$(BENCH_RUN) build

bench-schema-peers:
	$(BENCH_RUN) build schema

# The command line against jq, jaq, gojq and yq on the fixtures and the corpus
bench-cli: build-cli fixtures
	$(BENCH_RUN) cli

# Many files: a tree of about 34,000 against jq, jaq and gojq over find and xargs, and ripgrep
bench-files: build-cli fixtures
	$(BENCH_RUN) files

diff-schema: build-cli
	$(PYTEST) --stury=$(STURY_ABS) oracles/schema/test_schema_fixtures.py

diff-schema-csv:
	$(PYTEST) --odin=$(ODIN) oracles/schema/test_schema_csv.py

# The check over generated schemas and instances against the same package.
diff-schema-gen:
	$(PYTEST) --odin=$(ODIN) oracles/schema/test_schema_gen.py

# The errors of model.load on generated bodies against pydantic 2 in strict mode
diff-model:
	$(PYTEST) --odin=$(ODIN) oracles/model
