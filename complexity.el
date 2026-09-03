;;; complexity.el --- How much of a function a reader must hold  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Marcel Arpogaus

;; Author: Marcel Arpogaus <znepry.necbtnhf@tznvy.pbz>
;; Assisted-by: Claude:claude-opus-5

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The check this repository is, which a pre-commit hook and `make hook'
;; both run:
;;
;;     bin/elisp-complexity --report FILE...
;;     bin/elisp-complexity --max 20 FILE...
;;
;; `complexity-gate' is what the hook calls: it prints nothing where
;; every function is at or under the gate, and exits with 1 where one is
;; over.  `--report' prints the table whatever the scores are.
;;
;; It scores every function by *cognitive complexity*: how much of it a
;; reader has to hold in their head at once.  The rules are those of the
;; SonarSource white paper, which is language-independent, read here as
;; Lisp:
;;
;; - A form that breaks the straight line costs one: `if', `when',
;;   `while', `dolist', `cond', `pcase', a `condition-case' handler, a
;;   `throw'.
;; - A form nested inside another such form costs one more for each
;;   level it is in.  Two nested `dolist' forms cost 1 + 2, not 1 + 1.
;; - A branch that also has an else costs one more, and a `cond' or
;;   `pcase' costs one for each clause after the first.
;; - A run of the same operator costs one however long it is: `(and a b
;;   c)' costs one, `(and a (or b c))' two.
;; - A sequence of plain calls costs nothing, however long.  Neither
;;   does a long `let', a long doc string, or a comment: the reader of
;;   the score reads code, and the reader of the code reads the prose.
;;
;; What the number is for: finding the functions worth splitting.  There
;; is no equivalent of complexipy or of ruff's rules for Emacs Lisp —
;; `checkdoc', `package-lint', `relint' and the byte-compiler all say
;; nothing about the shape of a function — so this stands in for them.
;;
;; The rules are checked in test/complexity-test.el.

;;; Code:

(require 'seq)
(require 'subr-x)

(defconst complexity-branching
  '((if . if) (if-let . if) (if-let* . if)
    (when . plain) (unless . plain)
    (when-let . plain) (when-let* . plain) (and-let* . plain)
    (while . loop) (while-let . loop) (dolist . loop) (dotimes . loop)
    (cl-loop . loop)
    (cl-dolist . loop) (cl-dotimes . loop) (seq-doseq . loop)
    (pcase-dolist . loop) (dolist-with-progress-reporter . loop)
    (cl-do . loop) (cl-do* . loop)
    (cond . clauses) (pcase . clauses) (pcase-exhaustive . clauses)
    (cl-case . clauses) (cl-ecase . clauses) (cl-typecase . clauses)
    (condition-case . handlers) (condition-case-unless-debug . handlers)
    (ignore-errors . plain)
    (and . run) (or . run)
    (throw . jump) (cl-return . jump) (cl-return-from . jump)
    (lambda . body)
    (cl-flet . nested) (cl-flet* . nested) (cl-labels . nested))
  "What each form costs, by the kind of break in the flow it is.
`if' takes one more for an else, `clauses' one for each clause after the
first, `handlers' one for each handler, `run' one for a sequence of the
same operator however long it is, and `jump' one without the nesting.")

(defconst complexity-definers
  '(defun defmacro defsubst cl-defun cl-defmacro cl-defmethod
          cl-defgeneric define-inline)
  "The forms that define a function this measures.")

(defvar complexity--score 0 "The score of the function being walked.")
(defvar complexity--depth 0 "The deepest nesting seen in it.")
(defvar complexity--forms 0 "How many forms it holds.")
(defvar complexity--name nil "The name of the function being walked.")
(defvar complexity--recurses nil "Whether it calls itself.")

(defun complexity--add (n nest)
  "Add N breaks in the flow, each of them NEST levels deep."
  (setq complexity--score (+ complexity--score n (* n nest))))

(defun complexity--walk-if (form nest)
  "Score the `if' shaped FORM, which sits NEST levels deep."
  (complexity--add 1 nest)
  ;; The else is a second way out of one question, which is cheaper to
  ;; read than a question of its own.
  (when (> (safe-length form) 3) (complexity--add 1 0))
  (complexity--walk (nth 1 form) nest)
  (complexity--walk-all (nthcdr 2 form) (1+ nest)))

(defun complexity--walk-plain (form nest)
  "Score the one-branch FORM, which sits NEST levels deep."
  (complexity--add 1 nest)
  (complexity--walk (nth 1 form) nest)
  (complexity--walk-all (nthcdr 2 form) (1+ nest)))

(defconst complexity-loop-keywords
  '(if when unless while until thereis always never)
  "The `cl-loop' keywords that are a question, `else' apart.")

(defun complexity--walk-loop (form nest)
  "Score the looping FORM, which sits NEST levels deep.
`cl-loop' says its branches in keywords, which read as bare symbols
and would otherwise cost nothing: each one costs what the same question
in the body costs, and `else' what an else costs."
  (complexity--add 1 nest)
  (when (eq (car form) 'cl-loop)
    (complexity--add (seq-count (lambda (x)
                                  (memq x complexity-loop-keywords))
                                (cdr form))
                     (1+ nest))
    (complexity--add (seq-count (lambda (x) (eq x 'else)) (cdr form)) 0))
  (complexity--walk-all (cdr form) (1+ nest)))

(defun complexity--walk-clauses (form head nest)
  "Score FORM, a HEAD of clauses, which sits NEST levels deep.
Every clause after the first is another way through."
  (complexity--add 1 nest)
  (let ((clauses (if (eq head 'cond) (cdr form) (nthcdr 2 form))))
    (complexity--add (max 0 (1- (safe-length clauses))) 0)
    (if (eq head 'cond)
        (complexity--walk-all clauses (1+ nest))
      (complexity--walk (nth 1 form) nest)
      ;; The car of a clause is a pattern, and `or', `and' and a
      ;; backquote in a pattern are not the questions of the same name.
      (dolist (clause clauses)
        (complexity--walk-all (cdr-safe clause) (1+ nest))))))

(defun complexity--walk-handlers (form nest)
  "Score the handler FORM, which sits NEST levels deep.
One for each handler, and one for a form that catches nothing: the jump
out of the body is the break in the flow."
  (complexity--add (max 1 (safe-length (nthcdr 3 form))) nest)
  (complexity--walk-all (cdr form) (1+ nest)))

(defun complexity--walk-run (form head nest operator)
  "Score the run FORM of HEAD, which sits NEST levels deep.
OPERATOR is the run this one stands directly inside, where it does: a
run of one operator costs one however long the run is."
  (unless (eq operator head) (complexity--add 1 0))
  (dolist (x (cdr form)) (complexity--walk x nest head)))

(defun complexity--walk-jump (form nest)
  "Score the jumping FORM, which sits NEST levels deep."
  (complexity--add 1 0)
  (complexity--walk-all (cdr form) nest))

(defun complexity--walk-call (form nest)
  "Score FORM, which breaks nothing, at NEST levels deep.
Along the tail, so a dotted or improper form is walked as far as it
goes rather than signalling."
  (when (eq (car form) complexity--name) (setq complexity--recurses t))
  (let ((tail form))
    (while (consp tail)
      (complexity--walk (car tail) nest)
      (setq tail (cdr tail)))))

(defun complexity--walk (form nest &optional operator)
  "Score FORM, which sits NEST levels deep.
OPERATOR is the `and' or `or' it stands directly inside, where it
does.  Every kind of form has its own function; this one says which."
  (setq complexity--depth (max complexity--depth nest))
  (when (consp form)
    (setq complexity--forms (1+ complexity--forms))
    (let* ((head (car form))
           (kind (and (symbolp head)
                      (cdr (assq head complexity-branching)))))
      (pcase kind
        ((guard (memq head '(quote declare))) nil)
        ('if (complexity--walk-if form nest))
        ('plain (complexity--walk-plain form nest))
        ('loop (complexity--walk-loop form nest))
        ('clauses (complexity--walk-clauses form head nest))
        ('handlers (complexity--walk-handlers form nest))
        ('run (complexity--walk-run form head nest operator))
        ('jump (complexity--walk-jump form nest))
        ('body (complexity--walk-all (cddr form) (1+ nest)))
        ('nested (complexity--walk-all (cdr form) (1+ nest)))
        (_ (complexity--walk-call form nest))))))

(defun complexity--walk-all (forms nest)
  "Score every form of FORMS, each of them NEST levels deep."
  (dolist (form forms) (complexity--walk form nest)))

(defun complexity-of (definition)
  "Return what the function DEFINITION costs a reader, as a plist.
DEFINITION is a `defun' form as `read' answers it.  The keys are
`:score', `:depth', `:forms' and `:recurses'."
  (setq complexity--score 0
        complexity--depth 0
        complexity--forms 0
        complexity--name (nth 1 definition)
        complexity--recurses nil)
  (complexity--walk-all (nthcdr 3 definition) 0)
  ;; A function that calls itself asks the reader to hold it twice.
  (when complexity--recurses (complexity--add 1 0))
  (list :score complexity--score :depth complexity--depth
        :forms complexity--forms :recurses complexity--recurses))

(defun complexity-file (file)
  "Return a plist for every function FILE defines.
Beside what `complexity-of' answers: `:name', `:line', `:file', and
the lines of the definition told apart as `:code', `:doc', `:comment'
and `:blank'.  Comments never reach the score — the reader drops them —
so a long explanation costs nothing and a dense line costs a great
deal."
  (with-temp-buffer
    (insert-file-contents file)
    (emacs-lisp-mode)
    (goto-char (point-min))
    (let (found)
      (while (progn (forward-comment (buffer-size)) (not (eobp)))
        (let* ((beg (point))
               (line (line-number-at-pos beg))
               (form (condition-case err (read (current-buffer))
                       ;; A file this Emacs cannot read is not a file
                       ;; this can measure, and a gate that passes it
                       ;; unmeasured says the wrong thing.
                       (error (error "%s:%d: %s" file line
                                     (error-message-string err)))))
               (text (buffer-substring-no-properties beg (point))))
          (when (and (consp form) (memq (car form) complexity-definers))
            (let* ((doc (and (stringp (nth 3 form)) (nth 3 form)))
                   (lines (split-string text "\n"))
                   (blank (seq-count (lambda (l)
                                       (string-match-p "\\`[ \t]*\\'" l))
                                     lines))
                   (comment (seq-count (lambda (l)
                                         (string-match-p "\\`[ \t]*;" l))
                                       lines))
                   (docl (if doc
                             (1+ (seq-count (lambda (c) (eq c ?\n)) doc))
                           0)))
              (push (append (list :name (nth 1 form) :file file :line line
                                  :lines (length lines) :doc docl
                                  :comment comment :blank blank
                                  :code (- (length lines) docl comment blank))
                            (complexity-of form))
                    found)))))
      (nreverse found))))

(defun complexity--print (all max)
  "Print the table of ALL, and say which functions cost more than MAX."
  (let* ((scores (mapcar (lambda (r) (plist-get r :score)) all))
         (over (seq-filter (lambda (r) (> (plist-get r :score) max)) all)))
    (princ (format "%-42s %-26s %4s %4s %6s %5s\n"
                   "FUNCTION" "FILE:LINE" "COST" "DEEP" "FORMS" "CODE"))
    (dolist (r all)
      (princ (format "%-42s %-26s %4d %4d %6d %5d\n"
                     (plist-get r :name)
                     (format "%s:%d"
                             (file-name-nondirectory (plist-get r :file))
                             (plist-get r :line))
                     (plist-get r :score) (plist-get r :depth)
                     (plist-get r :forms) (plist-get r :code))))
    (princ (format "\n%d functions, %d in all, %.1f each, most %d.\n"
                   (length all) (apply #'+ 0 scores)
                   (/ (float (apply #'+ 0 scores)) (max 1 (length all)))
                   (apply #'max 0 scores)))
    ;; Fifteen is where SonarSource puts its own gate.
    (princ (format "%d over %d%s\n" (length over) max
                   (if over
                       (concat ": " (mapconcat
                                     (lambda (r)
                                       (format "%s" (plist-get r :name)))
                                     over ", "))
                     "")))))

(defun complexity-gate (max &optional report)
  "Score `command-line-args-left' and fail where a function costs over MAX.
Prints nothing where every function is at or under MAX, unless REPORT
says to print the table anyway: a hook that speaks on every commit is a
hook people turn off.  Exits with 1 where something is over."
  (let* ((all (sort (mapcan #'complexity-file command-line-args-left)
                    (lambda (a b) (> (plist-get a :score)
                                     (plist-get b :score)))))
         (over (seq-filter (lambda (r) (> (plist-get r :score) max)) all)))
    (when (or over report)
      (complexity--print all max))
    (kill-emacs (if over 1 0))))

(provide 'complexity)
;;; complexity.el ends here
