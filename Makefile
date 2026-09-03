# Development tasks.  Run `make' to check everything, as the CI does.
#
#   make compile   byte-compile, warnings are errors
#   make checkdoc  documentation style
#   make relint    the regular expressions and the docstring escapes
#   make test      ERT test suite
#   make format    indent every Lisp file in place
#   make hook      the hook over this repository's own Lisp
#   make clean     remove build output and the tool sandbox
#
# There is no `lint' target: this is a script rather than a package, so
# package-lint has no main file to read.  `relint' does apply, and it
# installs itself into $(SANDBOX), so a fresh checkout needs nothing
# but Emacs and make.

EMACS   ?= emacs
SANDBOX ?= .sandbox
# The sandbox is done when the stamp is there: a run that dies half
# way leaves the directory behind, and a directory target would then
# count as made and the tools stay missing.
STAMP   := $(SANDBOX)/.installed
DEPS    ?= relint

SRC  := complexity.el
TEST := $(wildcard test/*.el)
# Everything written in Lisp, the parts that are no package included.
LISP := $(SRC) $(TEST) $(wildcard tools/*.el)

# Elisp programs live in variables: make joins their continuation lines,
# while a backslash inside a quoted recipe line would reach Emacs as is.
init = (progn (setq package-user-dir (expand-file-name "$(SANDBOX)")) \
              (require (quote package)) \
              (add-to-list (quote package-archives) \
                           (cons "melpa" "https://melpa.org/packages/") t) \
              (package-initialize))
bootstrap = (progn (package-refresh-contents) \
                   (dolist (p (quote ($(DEPS)))) \
                     (unless (package-installed-p p) (package-install p))))
checkdoc = (progn (require (quote checkdoc)) \
                  (setq checkdoc-verb-check-experimental-flag nil) \
                  (dolist (f command-line-args-left) (checkdoc-file f)))

BATCH = $(EMACS) -Q --batch -L . -L test --eval '$(init)'

.PHONY: all compile checkdoc relint test hook format clean

all: compile checkdoc relint test hook

$(STAMP):
	@$(EMACS) -Q --batch --eval '$(init)' --eval '$(bootstrap)'
	@touch $@

# Nothing here needs the sandbox but relint: the tool is one file and
# Emacs.
compile:
	@$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRC) $(TEST)
	@rm -f ./*.elc test/*.elc

# checkdoc reports on stderr and always exits zero, so treat any output
# as a failure.
checkdoc:
	@out=$$($(BATCH) --eval '$(checkdoc)' $(SRC) 2>&1); \
	  if [ -n "$$out" ]; then printf '%s\n' "$$out"; exit 1; fi

# What checkdoc lets through: a docstring escape written \= rather than
# \\=, which the reader eats, so `describe-function' shows the reader
# the = as text.  Eleven of them lived here until this target did.
relint: $(STAMP)
	@$(BATCH) -l relint -f relint-batch $(SRC) $(TEST)

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
	@rm -rf $(SANDBOX) ./*.elc test/*.elc
