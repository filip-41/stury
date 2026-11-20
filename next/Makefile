ODIN ?= odin

PKGS := $(sort $(patsubst ./%/,%,$(dir $(shell find . -name '*.odin' -not -path './build/*'))))
TEST_PKGS := $(filter %/test,$(PKGS))
LIB_PKGS := $(filter-out $(TEST_PKGS) cli,$(PKGS))

COLLECTION := -collection:stury=$(CURDIR)
VET := -vet-unused-variables -vet-shadowing -vet-using-stmt -vet-cast -vet-semicolon -vet-tabs -vet-unused-imports -strict-style
LINT_FLAGS := $(COLLECTION) $(VET) -warnings-as-errors -terse-errors -max-error-count:500
TEST_FLAGS := $(COLLECTION) -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true


# Tests need an OS (`core:testing` imports `core:os`), so only the library is checked for wasm.
TEST_LINT_TARGETS := linux_amd64 windows_amd64 linux_riscv64
LINT_TARGETS := $(TEST_LINT_TARGETS) freestanding_wasm32

# Test packages whose kernels pick an x86-64 tier, run at each tier and `X86_OPTS` level. On an x86-64 machine these
# runs replace the plain one.
TIER_PKGS := lib/base/kernel/test
X86_TIERS := 0 1
X86_OPTS ?= minimal speed
OBJDUMP ?= $(shell command -v llvm-objdump || echo /opt/homebrew/opt/llvm@22/bin/llvm-objdump)
PLAIN_PKGS := $(TEST_PKGS)
ifeq ($(shell uname -sm),Darwin arm64)
X86_RUNS := 1
X86_FLAGS := -target:darwin_amd64
else ifeq ($(shell uname -m),x86_64)
X86_RUNS := 1
PLAIN_PKGS := $(filter-out $(TIER_PKGS),$(TEST_PKGS))
endif

.PHONY: check lint test

check: lint test

lint:
	@for p in $(LIB_PKGS); do \
		echo "== $$p"; $(ODIN) check $$p -no-entry-point $(LINT_FLAGS) || exit 1; \
		for t in $(LINT_TARGETS); do \
			echo "== $$p ($$t)"; $(ODIN) check $$p -no-entry-point $(LINT_FLAGS) -target:$$t || exit 1; \
		done; \
	done
	@for p in $(TEST_PKGS); do \
		echo "== $$p"; $(ODIN) check $$p -no-entry-point $(LINT_FLAGS) || exit 1; \
		for t in $(TEST_LINT_TARGETS); do \
			echo "== $$p ($$t)"; $(ODIN) check $$p -no-entry-point $(LINT_FLAGS) -target:$$t || exit 1; \
		done; \
	done
	@mkdir -p build; for p in $(TIER_PKGS); do \
		echo "== $$p (linux_amd64 tiers)"; \
		$(ODIN) test $$p -build-mode:obj -use-single-module -target:linux_amd64 -o:none $(LINT_FLAGS) -out:build/tiers.o || exit 1; \
		$(ODIN) test $$p -build-mode:obj -use-single-module -target:linux_amd64 -o:speed $(LINT_FLAGS) -out:build/tiers.o || exit 1; \
		python3 tools/tier_check.py $(OBJDUMP) build/tiers.o || exit 1; \
	done

test:
	@mkdir -p build; for p in $(PLAIN_PKGS); do \
		echo "== $$p"; $(ODIN) test $$p -o:minimal $(TEST_FLAGS) -out:build/test-$$(echo $$p | tr / -) || exit 1; \
	done
ifdef X86_RUNS
	@for p in $(TIER_PKGS); do for o in $(X86_OPTS); do for t in $(X86_TIERS); do \
		echo "== $$p (x86-64 tier $$t, -o:$$o)"; \
		$(ODIN) test $$p -o:$$o $(TEST_FLAGS) $(X86_FLAGS) -define:TIER=$$t -out:build/test-tier$$t || exit 1; \
	done; done; done
endif
