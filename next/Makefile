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

test:
	@mkdir -p build; for p in $(TEST_PKGS); do \
		echo "== $$p"; $(ODIN) test $$p -o:minimal $(TEST_FLAGS) -out:build/test-$$(echo $$p | tr / -) || exit 1; \
	done
