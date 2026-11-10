#!/usr/bin/env guile
!#
;;; tools/dump-menu.scm -- the command line around (scheme-desktop dump-menu).
;;;
;;;   scheme-desktop dump-menu [FILE]
;;;
;;; The work is in the module, because a running shell wants the same dump from
;;; its REPL, where there is no command line to run:
;;;
;;;   (import (scheme-desktop dump-menu))
;;;   (dump-menu "/tmp/menu.scm")
;;;
;;; No shell is needed here: with no registry, the module makes the widgets the
;;; config names.  See that module for why a procedure in a row is written as
;;; `(option-function …)' rather than `#<procedure …>'.
;;;
;;; Run it through `scheme-desktop dump-menu', which supplies the two -L paths.

(use-modules (scheme-desktop dump-menu))

(exit (if (dump-menu (and (pair? (cdr (command-line))) (cadr (command-line))))
          0
          1))
