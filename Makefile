NAME  := rdf-bench
BENCH := bench
OUT   := build/$(NAME)

# Odin source collections. The parser is a sibling checkout rather than a
# vendored copy, so it is reached through a collection instead of a relative
# path -- `import "rdf:rdf"` for the data model, `import "rdf:rdf/quads"` and
# friends for the four format packages. ols.json declares the same collection
# so the language server resolves what the compiler does.
COLL := -collection:rdf=../odin-rdf-parser

# Every package with tests. tests/readme compiles the README's examples so the
# documentation cannot drift from the API.
#
# `conformance` is not here: it is the executable form of the contract, but it
# carries no tests of its own -- a backend instantiates it, and the suite runs
# inside that backend's package (store/kvstore/conformance_test.odin). Listing
# a package with no tests prints a header and no result, which reads like a
# hang. It is vetted below instead (STORE-T-0028).
PKGS := store \
				store/memstore \
				store/kvstore \
				tests/readme

# Packages to vet but not test: `conformance` is a library its consumers test.
CHECK_ONLY := conformance

# STORE-A-0001 guardrail: the Term_ID width is a build-time choice and both
# configurations stay green, so the suite runs twice rather than once. This is
# what CI should invoke -- `make test`, the whole matrix, no arguments.
WIDTHS := 64 32

.PHONY: all help test check bench build-bench clean

all: test

# The description of a target is the `##` on its own recipe line, which is what
# help greps for -- prose above a target is for a reader of this file, not the
# listing. A target with no `##` is internal and stays out of it.
help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9_.-]+:.*## / {printf "%-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# The test runner tracks allocations per test but only warns about leaks and bad
# frees by default, which a passing build hides. Promote them to failures.
TEST_FLAGS := -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $(COLL)

test: ## Run the full suite at both Term_ID widths
	@for width in $(WIDTHS); do \
		echo "== Term_ID $$width-bit =="; \
		for pkg in $(PKGS); do \
			echo "-- $$pkg --"; \
			odin test $$pkg $(TEST_FLAGS) \
				-define:RDF_STORE_TERM_ID_BITS=$$width || exit 1; \
		done; \
	done

# Vets every package including the ones with no tests -- vendor/lmdb is a
# binding nothing else checks, and bench is a main package the suite skips.
check: ## Vet every package at the default Term_ID width
	@for pkg in $(PKGS) $(CHECK_ONLY) vendor/lmdb; do \
		echo "-- $$pkg --"; \
		odin check $$pkg -no-entry-point -vet -strict-style $(COLL) || exit 1; \
	done
	odin check $(BENCH) -vet -strict-style $(COLL)

# Benchmarks measure the store, and a debug build measures the compiler
# instead, so they get the release flags. Reports statements/second and
# bytes/statement -- a silent extra copy per statement shows up in the latter.
bench: ## Build and run the benchmarks with release flags
	@mkdir -p build
	odin run $(BENCH) -out:$(OUT) -o:speed -no-bounds-check $(COLL)

build-bench: ## Build the benchmark binary without running it
	@mkdir -p build
	odin build $(BENCH) -out:$(OUT) -o:speed -no-bounds-check $(COLL)

clean: ## Remove build/
	rm -rf build
