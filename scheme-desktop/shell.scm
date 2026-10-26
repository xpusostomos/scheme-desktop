;;; (scheme-desktop shell) -- entry point
;;;
;;; Run with:  bin/scheme-desktop run
;;;
;;; Small on purpose.  The work is in scheme-toolkit: this file says which
;;; windows this shell has, which is the one thing that makes it a shell rather
;;; than a toolkit demo.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit app))
(use-modules (scheme-desktop widgets bar))

(define (main)
  ;; for-each-monitor keys a root per monitor, so a hotplug builds a bar for the
  ;; monitor that arrived and disposes the one that left.
  (for-each-monitor
   (lambda (monitor name)
     (build-bar! monitor #:name "bar"))))

(run-shell #:instance "scheme-desktop" #:main main)
