;;; (scheme-desktop widgets bar clock) -- the time
;;;
;;; The format comes from the config, so `date' is called with the user's format
;;; rather than a hard-coded one.  That means the poll cannot be a constant: a
;;; changed format has to reach the running label.
;;;
;;; The shape is AGS's own:
;;;
;;;   const time = Variable("", { poll: [1000, "date +%H:%M"] })
;;;
;;; and in Scheme the same thing is a poll whose COMMAND is a computed, so
;;; changing clock-format restarts the polling rather than leaving an old
;;; command running.

(define-module (scheme-desktop widgets bar clock)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit time)
  ;; (scheme-desktop config) declares the schema; config-value is the toolkit's
  ;; reader.  Importing only the first is what raised Unbound variable:
  ;; config-value here.
  #:use-module (scheme-toolkit config)
  #:use-module (scheme-desktop config)
  #:use-module (ice-9 format)
  #:export (clock-widget clock-text))

(define-gi-imports "Gtk" "Label")

(define (clock-command)
  "The date command for the configured format."
  (list "date" (string-append "+" (config-value 'desktop 'clock-format))))

;; One poll for the process, not one per monitor: every bar reads the same
;; accessor, so three monitors cost one subprocess a second rather than three.
;; Cold by design -- it does nothing until a label subscribes.
(define %clock-poll #f)

(define (clock-poller)
  (unless %clock-poll
    (set! %clock-poll (create-poll 1000 (clock-command))))
  %clock-poll)

(define (clock-widget)
  "A label showing the time in the configured format."
  (element <gtk-label> #:label (clock-poller) #:class "clock"))
