;;; (scheme-desktop shell) -- entry point
;;;
;;; Run with:  bin/scheme-desktop run
;;;
;;; Small on purpose.  The work is in scheme-toolkit: this file says which
;;; windows this shell has, which is the one thing that makes it a shell rather
;;; than a toolkit demo.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit app))
(use-modules (scheme-desktop style))
(use-modules (scheme-desktop widgets bar))
;; Imported for its side effect of being loaded, so that a keybinding's
;; (scheme-desktop api) expression resolves over the REPL.  Nothing here calls
;; it -- the shell's own vocabulary is called FROM outside.
(use-modules (scheme-desktop api))

;; `guile -e main -s FILE' calls MAIN with ONE argument: the script's own
;; command line, as a list of strings.  A zero-argument main is the natural
;; thing to write and fails with "Wrong number of arguments to #<procedure
;; main ()>" -- after every module has loaded, so it reads like a deeper
;; problem than it is.
(define (main . args)
  ;; for-each-monitor keys a root per monitor, so a hotplug builds a bar for the
  ;; monitor that arrived and disposes the one that left.
  (for-each-monitor
   (lambda (monitor name)
     (build-bar! monitor #:name "bar"))))

(run-shell #:instance "scheme-desktop" #:main main)
