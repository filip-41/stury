ODIN ?= $(or $(wildcard $(abspath ../../Odin-master/bin/odin)),odin)

# A plain `make` runs the gate.
.DEFAULT_GOAL := gate

# The library packages, and the test packages that read them.
LIB_PKGS  := core/spell core host core/kernel core/compose core/build core/typed core/write core/records json dsv
TEST_PKGS := core/spell/test host/test core/kernel/test core/test core/write/test core/records/test json/test dsv/test
# The packages the tests share, checked by `lint` and built through their imports.
SUPPORT_PKGS := walktest
# The test packages that read `-define:TIER`.
TIER_PKGS := core/kernel/test
TEST_OPT  := -o:minimal
# A leak or a bad free fails the test that made it.
TEST_MEMORY := -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
# A text read on threads is cut at every byte in pieces of one byte, and at -o:speed chains run over several records.
TEST_PIECES := -define:RECORDS_SLICE=1
TEST_CHAINS := -define:RECORDS_SLICE=16
BUILD     := build

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

.PHONY: check gate build-cli test test-x86 test-asan test-tsan test-f32 lint bench bench-doc bench-paths bench-typed bench-records bench-write bench-peers fixtures size surface \
	$(TEST_TARGETS) $(ASAN_TARGETS) $(TSAN_TARGETS) $(X86_TARGETS)

# The document lanes' probe and peers, and the fixtures they read.
BENCH      := $(BUILD)/bench
BENCH_CC    ?= cc
BENCH_CXX   ?= c++
BENCH_CARGO ?= cargo
BENCH_FILES ?= logs.json citm_catalog.json table.csv logs.jsonc logs.json5

# `$(call odin_each,VERB,PACKAGES,FLAGS,LABEL)` runs `odin VERB` over each package and stops at the first failure.
define odin_each
@d=$$(mktemp -d) && trap 'rm -rf $$d' EXIT && for p in $(2); do \
	echo "== $$p$(4)"; $(ODIN) $(1) $$p $(3) $(if $(filter test,$(1)),-out:$$d/test) || exit 1; \
done
endef

# The command line at -o:speed. STURY_VERSION names the version `-V` prints, the commit's short hash by default.
ifeq ($(shell uname -s),Darwin)
CLI_LINK := "-extra-linker-flags:-L$(shell xcrun --show-sdk-path)/usr/lib/system -lsystem_m -lsystem_c -lsystem_kernel -lsystem_pthread -lsystem_malloc"
else ifeq ($(shell uname -s),Linux)
CLI_LINK := -reloc-mode:static
endif
CLI_VERSION := $(or $(STURY_VERSION),$(shell git log -1 --format=%h 2>/dev/null),dev)
CLI_DEFINES := -define:STURY_VERSION='"$(CLI_VERSION)"'
build-cli:
	@mkdir -p $(BUILD)
	$(ODIN) build cmd/stury -o:speed $(CLI_LINK) $(CLI_DEFINES) -out:$(BUILD)/stury

# The checks a change can reach, in `tools/gate.py`: `check` while editing, `gate` before a branch lands.
check:
	@ODIN=$(ODIN) python3 tools/gate.py quick

gate:
	@ODIN=$(ODIN) python3 tools/gate.py merge

# The tests at -o:minimal and at -o:speed, where the optimizer reasons about loads that the walk makes past an input's
# end. Each compile is its own target, so `make -j test` runs them at once.
test: $(TEST_TARGETS)

$(TEST_MINIMAL): $(BUILD)/test/minimal/%:
	@mkdir -p $(@D)
	@echo "== $* (-o:minimal)"
	@$(ODIN) test $* $(TEST_OPT) $(TEST_MEMORY) $(TEST_PIECES) -out:$@ || { echo "== $* (-o:minimal) failed"; exit 1; }

$(TEST_SPEED): $(BUILD)/test/speed/%:
	@mkdir -p $(@D)
	@echo "== $* (-o:speed)"
	@$(ODIN) test $* -o:speed $(TEST_MEMORY) $(TEST_CHAINS) -out:$@ || { echo "== $* (-o:speed) failed"; exit 1; }

# The x86-64 tiers v2 and v3 in a build for Odin's default CPU, as a caller's build is, at -o:none, where no kernel
# is inlined into the tier's procedures, and at -o:speed. TIER picks the kernels' tier and WALK_TIER the walks'.
# On Apple silicon they run under Rosetta. v4 runs only on a machine with AVX-512 (TIER=2), and `lint` compiles it.
test-x86: $(X86_TARGETS)

# `build/test/x86/OPT/TIER/PACKAGE` runs one package at one tier, `TIER` defined only where it is read.
$(X86_TARGETS): $(BUILD)/test/x86/%:
	@mkdir -p $(@D)
	@o=$(word 1,$(subst /, ,$*)); t=$(word 2,$(subst /, ,$*)); p=$(patsubst $(word 1,$(subst /, ,$*))/$(word 2,$(subst /, ,$*))/%,%,$*); \
	echo "== $$p (x86 tier $$t -o:$$o)"; \
	$(ODIN) test $$p -o:$$o -target:darwin_amd64 -define:WALK_TIER=$$t \
		$(if $(filter %/kernel/test,$*),-define:TIER=$$t) -out:$@ || { echo "== $$p (x86 tier $$t -o:$$o) failed"; exit 1; }

# Every binary32 pattern read back and checked shortest, on F32_THREADS threads at -o:speed, which the gate's full tier runs.
F32_THREADS ?= 6
test-f32:
	@mkdir -p $(BUILD)/test/f32
	$(ODIN) test core/spell/test -o:speed -define:F32_STRIDE=1 -define:F32_THREADS=$(F32_THREADS) \
		-define:ODIN_TEST_NAMES=spell_tests.f32_exhaustive -out:$(BUILD)/test/f32/spell

test-asan: $(ASAN_TARGETS)

$(ASAN_TARGETS): $(BUILD)/test/asan/%:
	@mkdir -p $(@D)
	@echo "== $* (address)"
	@$(ODIN) test $* -o:speed -sanitize:address -debug $(TEST_PIECES) -out:$@ || { echo "== $* (address) failed"; exit 1; }

# The pool's start budget is raised, since a loaded host would otherwise stop it short of every helper under the sanitizer.
test-tsan: $(TSAN_TARGETS)

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
	$(ODIN) check bench $(LINT_FLAGS)
	$(ODIN) check bench/doc $(LINT_FLAGS)
	$(ODIN) check bench/editbench $(LINT_FLAGS)
	$(ODIN) check bench/paths $(LINT_FLAGS)
	$(ODIN) check bench/records $(LINT_FLAGS)
	$(ODIN) check bench/typed $(LINT_FLAGS)
	$(ODIN) check bench/write $(LINT_FLAGS)
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

# The lean lines of each library package and each command line package, with each sum and its budget. Past a budget
# the command fails.
size:
	python3 tools/checks.py size

# The public declarations of each library package, sorted. `api` compares their signatures with API.txt, and
# `python3 tools/checks.py api --write` regenerates it.
surface:
	python3 tools/checks.py surface

# Kernel timings at release optimization, of the tier at place TIER of `Tier`. ROUNDS, CASES and COUNT pass through
# to run.py.
TIER ?= 0
bench: ROUNDS ?= 5
bench:
	@mkdir -p $(BUILD)
	$(ODIN) build bench -o:speed -define:TIER=$(TIER) -out:$(BUILD)/kernelbench
	ROUNDS=$(ROUNDS) python3 -I bench/run.py $(BUILD)/kernelbench

# The document lanes' fixtures: the pinned corpus and peer sources, then the generated JSON and dsv files.
fixtures:
	python3 bench/fetch.py
	python3 bench/gen.py --check

# The path lanes' probe at -o:speed, then paths.py over the peers `bench-doc` built. ROUNDS passes through.
bench-paths: ROUNDS ?= 5
bench-paths:
	@mkdir -p $(BENCH)
	$(ODIN) build bench/paths -o:speed -out:$(BENCH)/paths
	ROUNDS=$(ROUNDS) python3 bench/paths.py

# The typed read's probe at -o:speed, then typed.py, which adds the old tree's arm where the checkout holds it. ROUNDS
# passes through.
bench-typed: ROUNDS ?= 5
bench-typed:
	@mkdir -p $(BENCH)
	$(ODIN) build bench/typed -o:speed -out:$(BENCH)/typed
	ODIN=$(ODIN) ROUNDS=$(ROUNDS) python3 bench/typed.py

# The record lanes on the NDJSON and CSV fixtures, beside the peers' record readers. ROUNDS passes through.
bench-records: ROUNDS ?= 5
bench-records: bench-peers
	$(ODIN) build bench/records -o:speed -out:$(BENCH)/records
	ROUNDS=$(ROUNDS) python3 bench/records.py

# The peers whose toolchain and sources are present: yyjson, simdjson (threaded, as its document_stream runs stage 1 in a
# thread of its own), and the Rust binaries (sonic-rs, serde_json, simd-csv).
bench-peers:
	@mkdir -p $(BENCH)
	@if command -v $(BENCH_CC) >/dev/null && [ -f $(BENCH)/deps/yyjson/yyjson.c ]; then \
		$(BENCH_CC) -O3 -DNDEBUG -o $(BENCH)/yy_bench bench/peers/yy_bench.c \
			$(BENCH)/deps/yyjson/yyjson.c -I$(BENCH)/deps/yyjson && echo "yy: built"; \
	else echo "yy: left out (C compiler or yyjson source missing; run make fixtures)"; fi
	@if command -v $(BENCH_CXX) >/dev/null && [ -f $(BENCH)/deps/simdjson/simdjson.cpp ]; then \
		$(BENCH_CXX) -O3 -DNDEBUG -std=c++17 -pthread -o $(BENCH)/cpp_bench bench/peers/cpp_bench.cpp \
			$(BENCH)/deps/simdjson/simdjson.cpp -I$(BENCH)/deps/simdjson && echo "simd: built"; \
	else echo "simd: left out (C++ compiler or simdjson source missing; run make fixtures)"; fi
	@if command -v $(BENCH_CARGO) >/dev/null; then \
		CARGO_TARGET_DIR=$(abspath $(BENCH)/rust) $(BENCH_CARGO) build --release --locked \
			--manifest-path bench/peers/rust/Cargo.toml && echo "sonic, serde, simd-csv: built"; \
	else echo "sonic, serde, simd-csv: left out (cargo missing)"; fi

# The write lanes: next's probe at -o:speed when bench/write exists, the peers, then write.py. ROUNDS passes through.
bench-write: ROUNDS ?= 5
bench-write: bench-peers
	@if [ -d bench/write ]; then $(ODIN) build bench/write -o:speed -out:$(BENCH)/write; \
	else echo "next: left out (bench/write is not there yet)"; fi
	ROUNDS=$(ROUNDS) python3 bench/write.py $(LANES)

# The document lanes' probe at -o:speed, the peers, then doc.py. ROUNDS and BENCH_FILES pass through.
bench-doc: ROUNDS ?= 5
bench-doc: bench-peers
	$(ODIN) build bench/doc -o:speed -out:$(BENCH)/doc
	ROUNDS=$(ROUNDS) python3 bench/doc.py $(BENCH_FILES)
