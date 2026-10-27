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
(define* (build-all-bars! #:key (force? #f))
  ;; for-each-monitor keys a root per monitor, so a hotplug builds a bar for the
  ;; monitor that arrived and disposes the one that left.  A REBUILD passes
  ;; force?: the roots already exist, so without it nothing would be built and
  ;; the bar would simply disappear.
  (for-each-monitor
   (lambda (monitor name)
     (build-bar! monitor #:name "bar"))
   #:force? force?))

(define (main . args)
  (build-all-bars!)

  ;; Options that decide the bar's SHAPE apply on a rebuild rather than in
  ;; place -- moving the bar to the other edge means re-anchoring the layer
  ;; surface, and a changed module list means different children.  Options a
  ;; widget binds to directly (clock-format) need nothing here: the label is
  ;; subscribed to the accessor.
  ;;
  ;; Rebuilding is cheap and blunt on purpose.  The alternative is diffing two
  ;; widget trees, which would cost more complexity than a bar is worth.
  (watch-bar-layout!
   (lambda ()
     ;; Only the bars, on purpose: the option being watched is a bar option, and
     ;; destroying every window in the registry would take out anything else
     ;; that happened to be registered under another name.
     (catch #t
       (lambda ()
         (destroy-windows! "bar")
         (build-all-bars! #:force? #t)
         ;; Present the new windows.  run-shell presents only on the
         ;; application's ACTIVATE, which fires once, so without this the
         ;; rebuilt bar is registered, visible in the registry, and has no
         ;; surface at all -- the windows exist and nothing is on screen.
         (for-each (lambda (w)
                     (catch #t (lambda () (present w)) (lambda args #f)))
                   (windows)))
       (lambda (key . rest)
         ;; A failed rebuild must not take the shell down: the bar is gone but
         ;; the process still has a REPL, which is where the fix gets made.
         (format (current-error-port)
                 "scheme-desktop: cannot rebuild the bar: ~a ~s~%" key rest))))))

(run-shell #:instance "scheme-desktop" #:main main)
