ODIN ?= odin
OPT  ?= -o:speed

# Library packages and test packages. Library packages have
# no entry point, and the test packages pull in the libraries they exercise.
LIB_PKGS  := host core core/bits core/path core/spell csv json json/encode json/scan json/scan/walk json/scan/lex json/scan/number json/scan/index json/test/stock
TEST_PKGS := core/test csv/test json/test/api
# `make test` builds the suites at -o:minimal because the build is most of their run time.
TEST_OPT := -o:minimal
# The CLI's size cap; raise it deliberately when a feature earns the bytes.
CLI_MAX_BYTES := 3014656

VET := -vet-unused-variables -vet-shadowing -vet-using-stmt -vet-cast -vet-semicolon -vet-tabs -strict-style
LINT_FLAGS := $(VET) -warnings-as-errors -terse-errors -max-error-count:500

.PHONY: build-cli test test-x86 test-modes diff test-asan test-tsan lint bench-compare bench-cli

# `$(call odin_each,VERB,PACKAGES,FLAGS,LABEL)` runs `odin VERB` over each package and stops at the first failure.
define odin_each
@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && for p in $(2); do \
	echo "== $$p$(4)"; $(ODIN) $(1) $$p $(3) $(if $(filter test,$(1)),-out:$$d/test) || exit 1; \
done
endef

# `$(call odin_build,ARGS,OUT)` runs `odin build ARGS` for OUT in a directory of the call's own under build/
define odin_build
@mkdir -p build
d=$$(mktemp -d build/.out.XXXXXX) && trap 'rm -rf $$d' EXIT && \
$(ODIN) build $(1) -out:$$d/$(notdir $(2)) && \
if [ -d $$d/$(notdir $(2)).dSYM ]; then rm -rf $(2).dSYM && mv $$d/$(notdir $(2)).dSYM $(2).dSYM; fi && \
mv $$d/$(notdir $(2)) $(2)
endef

# The private targets requiring internal, not published, machinery.
PRIVATE_TARGETS := all probe fixtures bench selftest test-diff test-private lint-gate
ifndef GATE
.PHONY: $(PRIVATE_TARGETS)
$(PRIVATE_TARGETS):
	@if [ -f Makefile.gate ]; then exec $(MAKE) -f Makefile.gate $@; fi; \
	echo "make $@ is the private gate: it needs Makefile.gate and the private checkout, which are not published." >&2; \
	echo "This file's targets are: lint test test-modes test-x86 test-asan test-tsan diff build-cli bench-compare bench-cli." >&2; \
	exit 1
endif

# `make` with no target is the release gate where Makefile.gate is present, and `test` elsewhere.
.DEFAULT_GOAL := $(if $(wildcard Makefile.gate),all,test)

ifeq ($(shell uname -s),Darwin)
CLI_LINK := "-extra-linker-flags:-L$(shell xcrun --show-sdk-path)/usr/lib/system -lsystem_m -lsystem_c -lsystem_kernel -lsystem_pthread -lsystem_malloc"
else ifeq ($(shell uname -s),Linux)
# Not position-independent, as test-x86's linux_amd64 link is: a PIE's relocations put the binary over
# CLI_MAX_BYTES. Build PIE if a distribution asks for it.
CLI_LINK := -reloc-mode:static
endif


CLI_VERSION := $(or $(STURY_VERSION),$(shell p=$$(git rev-parse --show-prefix 2>/dev/null) && [ -z "$$p" ] && git log -1 --format=%h 2>/dev/null),dev)
# The CLI never asks for `Duplicates.Refuse` (jq keeps a repeated key's last value), so it is built without that
# key-checking copy of every scan walk.
CLI_DEFINES := -define:STURY_VERSION='"$(CLI_VERSION)"' -define:REFUSE_DUPLICATES=false
build-cli:
	$(call odin_build,cmd/stury $(OPT) $(CLI_LINK) $(CLI_DEFINES),build/stury)

test: build-cli
	$(call odin_each,test,$(TEST_PKGS),$(TEST_OPT),)
	@echo "== cmd/stury"
	sh cmd/stury/test/smoke.sh build/stury
	@if [ -n "$(JQ_SUITE_IN_DIFF)" ] && [ "$$(jq --version 2>/dev/null)" = jq-1.8.2 ]; then echo "(jq suite: run by diff)"; else python3 cmd/stury/test/jq_suite.py build/stury || exit 1; fi
	@n=$$(wc -c < build/stury); [ $$n -le $(CLI_MAX_BYTES) ] || { echo "build/stury is $$n B, over the $(CLI_MAX_BYTES) B cap"; exit 1; }
	@for e in examples/*/; do e=$${e%/}; echo "== $$e"; d=$$(mktemp -d) && $(ODIN) build $$e $(TEST_OPT) -collection:stury=. -out:$$d/x && $$d/x; s=$$?; rm -rf $$d; [ $$s -eq 0 ] || exit 1; done

# The suites built for x86-64, which takes the portable paths arm64 never runs, and the runtime's software
# conversions where arm64 has an instruction. On Apple silicon they run under Rosetta.
test-x86:
	$(call odin_each,test,$(TEST_PKGS),$(OPT) -collection:stury=. -target:darwin_amd64, (x86-64))
	@echo "== cmd/stury (linux_amd64)"
	@# Odin links linux_amd64 only on Linux; elsewhere `zig cc`, when there is one, links the object it leaves.
	@mkdir -p build; d=$$(mktemp -d build/.out.XXXXXX) && trap 'rm -rf $$d' EXIT; b=build/stury-linux-amd64; o=$$d/stury-linux-amd64; rm -f $$b; \
	$(ODIN) build cmd/stury $(OPT) $(CLI_DEFINES) -target:linux_amd64 -out:$$o >/dev/null || exit 1; \
	[ -f $$o ] || ! command -v zig >/dev/null || zig cc -target x86_64-linux-gnu -no-pie $$o.o -o $$o -lm -lc -lpthread || exit 1; \
	[ ! -f $$o ] || mv $$o $$b || exit 1; \
	if [ ! -f $$b ]; then echo "$$b: no linker for linux_amd64 here, its size is not checked"; \
	else n=$$(wc -c < $$b); [ $$n -le $(CLI_MAX_BYTES) ] || { echo "$$b is $$n B, over the $(CLI_MAX_BYTES) B cap"; exit 1; }; fi

# The CLI against jq 1.8.2: its suite, and jq_diff with regex_diff over each seed, a target per seed so that
# `make -j` runs the seeds at once. Without jq 1.8.2 on PATH it is skipped.
DIFF_SEEDS ?= 77 1016 5
DIFF_SEED_TARGETS := $(DIFF_SEEDS:%=diff-seed-%)
JQ_VERSION := $(shell jq --version 2>/dev/null)
.PHONY: diff-suite $(DIFF_SEED_TARGETS)
ifeq ($(JQ_VERSION),jq-1.8.2)
diff: diff-suite $(DIFF_SEED_TARGETS)
else
diff:
	@echo "== diff: no jq 1.8.2 on PATH, skipped"
endif
diff-suite: build-cli
	STURY_TEST_TIMEOUT=60 python3 cmd/stury/test/jq_suite.py build/stury --diff
$(DIFF_SEED_TARGETS): diff-seed-%: build-cli
	python3 cmd/stury/test/jq_diff.py build/stury --seed $*
	python3 cmd/stury/test/regex_diff.py build/stury --seed $*

# The engines a default build routes around, and the build the CLI ships (REFUSE_DUPLICATES=false), each under the
# whole api suite. csv/test has no mode: none of these defines reaches package csv.
test-modes:
	$(call odin_each,test,json/test/api,$(OPT) -collection:stury=. -define:FORCE_AUTOMATON=true, (FORCE_AUTOMATON))
	$(call odin_each,test,json/test/api,$(OPT) -collection:stury=. -define:SCAN_FORCE_SLOW=true, (SCAN_FORCE_SLOW))
	$(call odin_each,test,json/test/api,$(TEST_OPT) -collection:stury=. -define:REFUSE_DUPLICATES=false, (REFUSE_DUPLICATES=false))

lint:
	$(call odin_each,check,$(LIB_PKGS) $(TEST_PKGS),-no-entry-point -collection:stury=. $(LINT_FLAGS),)
	@for e in examples/*/ bench/probe/ bench/core_compare/; do echo "== $${e%/}"; $(ODIN) check $${e%/} -collection:stury=. $(LINT_FLAGS) || exit 1; done
	@# A program that uses the library builds under plain -vet (unused imports included, which $(VET) leaves out).
	@echo "== examples/quickstart (-vet, host and x86-64)"
	@$(ODIN) check examples/quickstart -collection:stury=. -vet -terse-errors || exit 1
	@$(ODIN) check examples/quickstart -collection:stury=. -vet -terse-errors -target:linux_amd64 || exit 1
	@echo "== cmd/stury"
	@$(ODIN) check cmd/stury $(LINT_FLAGS)
	@echo "== cmd/stury (linux_amd64)"
	@$(ODIN) check cmd/stury -target:linux_amd64 $(LINT_FLAGS)
	@echo "== cmd/stury (windows_amd64 objects)"
	@# Odin targets Windows only given an SDK path, which objects read nothing from: an empty directory serves.
	@d=$$(mktemp -d) && $(ODIN) build cmd/stury -build-mode:obj -target:windows_amd64 -windows-sdk-root:$$d $(LINT_FLAGS) -out:$$d/stury.obj; s=$$?; rm -rf $$d; exit $$s
	@# The code guard reads source text alone: a release archive runs it like a checkout does.
	@echo "== no mutable globals"; python3 tools/no_mutable_globals.py

# The comparison with other libraries and with other jq-like command lines (bench/README.md). bench-compare
# downloads its pinned inputs and the other libraries first; bench-cli fetches the corpus and needs jq, jaq, gojq and yq
# installed. Neither result is quotable unless the machine is idle.
bench-compare:
	python3 bench/fetch.py
	python3 bench/gen.py --check
	python3 bench/compare.py build
	python3 bench/compare.py time --out build/bench/report

bench-cli: build-cli
	python3 bench/fetch.py corpus
	python3 bench/gen.py --check
	zsh bench/cli/jq_compare.sh

# The public suites and the command line under a sanitizer
SAN_ENV := STURY_SANITIZED=1 STURY_TEST_TIMEOUT=300 ASAN_OPTIONS=use_sigaltstack=0:detect_leaks=0
SAN_STACK := ulimit -s 65520 2>/dev/null || ulimit -s unlimited

# `$(call sanitized,SANITIZER)` runs the suites and smoke.sh under -sanitize:SANITIZER.
define sanitized
	$(call odin_each,test,$(TEST_PKGS),-o:minimal -debug -sanitize:$(1) -collection:stury=., ($(1)))
	$(call odin_build,cmd/stury $(OPT) -debug -sanitize:$(1) $(CLI_DEFINES) $(if $(filter thread,$(1)),-define:BATCH_START_BUDGET_US=100000),build/stury-$(1))
	$(SAN_STACK); $(SAN_ENV) sh cmd/stury/test/smoke.sh build/stury-$(1)
endef

# AddressSanitizer: out-of-bounds reads and writes, use after free, stack overflow past a guard.
test-asan:
	$(call sanitized,address)
	$(SAN_STACK); $(SAN_ENV) python3 cmd/stury/test/jq_suite.py build/stury-address

# ThreadSanitizer
test-tsan:
	$(call sanitized,thread)
