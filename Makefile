# Development tasks.  Run `make' to check everything, as the CI does.
#
#   make compile   byte-compile, warnings are errors
#   make checkdoc  documentation style
#   make test      ERT test suite
#   make format    indent every Lisp file in place
#   make hook      the hook over this repository's own Lisp
#   make clean     remove build output
#
# There is nothing to install: the tool is one file and Emacs.

EMACS ?= emacs

SRC  := complexity.el
TEST := $(wildcard test/*.el)
# Everything written in Lisp, the parts that are no package included.
LISP := $(SRC) $(TEST) $(wildcard tools/*.el)

checkdoc = (progn (require (quote checkdoc)) \
                  (setq checkdoc-verb-check-experimental-flag nil) \
                  (dolist (f command-line-args-left) (checkdoc-file f)))

BATCH = $(EMACS) -Q --batch -L . -L test

.PHONY: all compile checkdoc test hook format clean

all: compile checkdoc test hook

compile:
	@$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC) $(TEST)
	@rm -f ./*.elc test/*.elc

# checkdoc reports on stderr and always exits zero, so treat any output
# as a failure.
checkdoc:
	@out=$$($(BATCH) --eval '$(checkdoc)' $(SRC) 2>&1); \
	  if [ -n "$$out" ]; then printf '%s\n' "$$out"; exit 1; fi

test:
	@$(BATCH) $(addprefix -l ,$(TEST)) -f ert-run-tests-batch-and-exit

# The tool measures itself, at the gate it ships with.
hook:
	@EMACS=$(EMACS) ./bin/elisp-complexity --report $(SRC)

# The formatter loads each file before indenting it, so a macro of this
# repository indents its body the way its `declare' says.  It answers 1
# when it had to change something, which is how the hook stops a
# commit; from make that is a job done, not a failure.
format:
	@$(BATCH) -l tools/indent.el $(LISP) || true

clean:
	@rm -f ./*.elc test/*.elc
