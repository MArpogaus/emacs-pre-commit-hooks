;;; hooks-test.el --- Tests for the hooks  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Marcel Arpogaus

;; Author: Marcel Arpogaus <znepry.necbtnhf@tznvy.pbz>
;; Assisted-by: Claude:claude-opus-5
;; URL: https://github.com/MArpogaus/elisp-complexity

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

;; Run with: make test
;;
;; The three hooks that are scripts, `bin/elisp-indent',
;; `bin/elisp-checkdoc' and `bin/elisp-check-declare', over files in a
;; directory of their own.  They shell out: the tests ask what a commit
;; would be told, not what a function inside this one would answer.

;;; Code:

(require 'ert)

(defconst hooks-test-bin
  (if load-file-name
      (expand-file-name "../bin/" (file-name-directory load-file-name))
    "bin/")
  "The directory of the scripts under test.")

(defconst hooks-test-emacs
  (expand-file-name invocation-name invocation-directory)
  "The Emacs this suite runs on, for the scripts to call.")

(defun hooks-test--run (script dir &rest files)
  "Run bin/SCRIPT from DIR over FILES, answer (STATUS OUTPUT)."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir))
          (process-environment (cons (concat "EMACS=" hooks-test-emacs)
                                     process-environment)))
      (list (apply #'call-process
                   (expand-file-name script hooks-test-bin)
                   nil (list t t) nil files)
            (buffer-string)))))

(defun hooks-test--write (dir name &rest lines)
  "Write LINES to NAME in DIR, answer the file's absolute name."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert (apply #'concat lines)))
    file))

(ert-deftest hooks-test-indent-an-unchanged-file-passes ()
  "A file already indented is left at exit zero and silence."
  (let* ((dir (make-temp-file "hooks-test" t))
         (file (hooks-test--write dir "clean.el"
                                  ";;; clean.el --- Clean  -*- lexical-binding: t; -*-\n"
                                  "(defun clean-one ()\n  \"Return one.\"\n  (list 1))\n"
                                  "(provide 'clean)\n")))
    (unwind-protect
        (let ((answer (hooks-test--run "elisp-indent" dir file)))
          (should (= 0 (car answer)))
          (should (string-empty-p (cadr answer))))
      (delete-directory dir t))))

(ert-deftest hooks-test-indent-names-what-it-changed-and-fails ()
  "A file that had to be indented is named, and the run stops."
  (let* ((dir (make-temp-file "hooks-test" t))
         (file (hooks-test--write dir "messy.el"
                                  ";;; messy.el --- Messy  -*- lexical-binding: t; -*-\n"
                                  "(defun messy-one (x)\n  \"Return X.\"\n(list x))\n")))
    (unwind-protect
        (let ((answer (hooks-test--run "elisp-indent" dir file)))
          (should (= 1 (car answer)))
          (should (string-match-p "indented" (cadr answer)))
          (should (string-match-p (regexp-quote file) (cadr answer))))
      (delete-directory dir t))))

(ert-deftest hooks-test-indent-names-what-it-cannot-load ()
  "A file that does not load is left alone and named, not a failure."
  (let* ((dir (make-temp-file "hooks-test" t))
         (file (hooks-test--write dir "broken.el"
                                  ";;; broken.el --- Broken  -*- lexical-binding: t; -*-\n"
                                  "(require 'hooks-test-no-such-feature)\n")))
    (unwind-protect
        (let ((answer (hooks-test--run "elisp-indent" dir file)))
          (should (= 0 (car answer)))
          (should (string-match-p "left" (cadr answer)))
          (should (string-match-p (regexp-quote file) (cadr answer))))
      (delete-directory dir t))))

(ert-deftest hooks-test-indent-loads-what-it-can-and-changes-the-rest ()
  "A file that does not load does not stop the files beside it."
  (let* ((dir (make-temp-file "hooks-test" t))
         (broken (hooks-test--write dir "broken.el"
                                    ";;; broken.el --- Broken  -*- lexical-binding: t; -*-\n"
                                    "(require 'hooks-test-no-such-feature)\n"))
         (messy (hooks-test--write dir "messy.el"
                                   ";;; messy.el --- Messy  -*- lexical-binding: t; -*-\n"
                                   "(defun messy-one (x)\n  \"Return X.\"\n(list x))\n")))
    (unwind-protect
        (let ((answer (hooks-test--run "elisp-indent" dir messy broken)))
          (should (= 1 (car answer)))
          (should (string-match-p "indented" (cadr answer)))
          (should (string-match-p "left .+broken" (cadr answer))))
      (delete-directory dir t))))

(ert-deftest hooks-test-indent-loads-a-macro-before-indenting ()
  "A body behind `(declare (indent 1))' is indented as its macro says."
  (let* ((dir (make-temp-file "hooks-test" t))
         (macros (hooks-test--write dir "macros.el"
                                    ";;; macros.el --- Macros  -*- lexical-binding: t; -*-\n"
                                    "(defmacro hooks-test-glove (var &rest body)\n"
                                    "  \"Bind VAR for BODY.\"\n"
                                    "  (declare (indent 1))\n"
                                    "  `(let ((,var 1)) ,@body))\n"
                                    "(provide 'macros)\n"))
         (file (hooks-test--write dir "wearer.el"
                                  ";;; wearer.el --- Wearer  -*- lexical-binding: t; -*-\n"
                                  "(require 'macros)\n"
                                  "(defun wearer (x)\n  \"Use X.\"\n"
                                  "  (hooks-test-glove g\n(g)\n(g)))\n"
                                  "(provide 'wearer)\n")))
    (unwind-protect
        (let* ((answer (hooks-test--run "elisp-indent" dir macros file))
               (indented (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))))
          (delete-file macros)
          (should (= 1 (car answer)))
          (should (string-match-p "indented" (cadr answer)))
          (should (string-match-p
                   (regexp-quote "(hooks-test-glove g\n    (g)\n    (g)))")
                   indented)))
      (delete-directory dir t))))

(ert-deftest hooks-test-checkdoc-passes-clean-files ()
  "A file checkdoc has nothing to say about stops nothing."
  (let* ((dir (make-temp-file "hooks-test" t))
         (file (hooks-test--write dir "clean.el"
                                  ";;; clean.el --- Clean  -*- lexical-binding: t; -*-\n"
                                  ";;; Commentary:\n\n;; Nothing to say.\n\n"
                                  ";;; Code:\n\n(defun clean-one ()\n"
                                  "  \"Return one.\"\n  (list 1))\n\n"
                                  "(provide 'clean)\n;;; clean.el ends here\n")))
    (unwind-protect
        (let ((answer (hooks-test--run "elisp-checkdoc" dir file)))
          (should (= 0 (car answer)))
          (should (string-empty-p (cadr answer))))
      (delete-directory dir t))))

(ert-deftest hooks-test-checkdoc-fails-on-a-docstring-fault ()
  "A sentence without its period is named, and the run fails."
  (let* ((dir (make-temp-file "hooks-test" t))
         (file (hooks-test--write dir "broken.el"
                                  ";;; broken.el --- Broken  -*- lexical-binding: t; -*-\n"
                                  ";;; Commentary:\n\n;; Nothing to say.\n\n"
                                  ";;; Code:\n\n(defun broken-one ()\n"
                                  "  \"Return one\"\n  (list 1))\n\n"
                                  "(provide 'broken)\n;;; broken.el ends here\n")))
    (unwind-protect
        (let ((answer (hooks-test--run "elisp-checkdoc" dir file)))
          (should (= 1 (car answer)))
          (should (string-match-p "punctuation" (cadr answer))))
      (delete-directory dir t))))

(ert-deftest hooks-test-check-declare-passes-on-fresh-declares ()
  "A declare whose function is where it says stops nothing."
  (let* ((dir (make-temp-file "hooks-test" t))
         (_ (hooks-test--write dir "target.el"
                               "(defun declare-target-one (x) (+ x 1))\n"
                               "(provide 'target)\n"))
         (file (hooks-test--write dir "caller.el"
                                  "(declare-function declare-target-one \"target.el\")\n"
                                  "(defun declare-caller-one (x) (declare-target-one x))\n")))
    (unwind-protect
        (let ((answer (hooks-test--run "elisp-check-declare" dir file)))
          (should (= 0 (car answer)))
          (should (string-empty-p (cadr answer))))
      (delete-directory dir t))))

(ert-deftest hooks-test-check-declare-fails-on-a-stale-declare ()
  "A declare whose function is no longer there is named, and the run fails."
  (let* ((dir (make-temp-file "hooks-test" t))
         (_ (hooks-test--write dir "target.el"
                               "(defun declare-target-one (x) (+ x 1))\n"
                               "(provide 'target)\n"))
         (file (hooks-test--write dir "caller.el"
                                  "(declare-function declare-target-gone \"target.el\")\n"
                                  "(defun declare-caller-one (x) (declare-target-gone x))\n")))
    (unwind-protect
        (let ((answer (hooks-test--run "elisp-check-declare" dir file)))
          (should (= 1 (car answer)))
          (should (string-match-p "function not found" (cadr answer)))
          (should (string-match-p "declare-target-gone" (cadr answer))))
      (delete-directory dir t))))

(provide 'hooks-test)
;;; hooks-test.el ends here
