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
;;;
;;; THE FIRST WIDGET TO BE AN OBJECT rather than a procedure.  It is the
;;; simplest one to convert and the least interesting: no window, no per-monitor
;;; state, one label.  What it demonstrates is the whole contract --
;;; `widget-build' is handed the monitor's output name and returns the GTK tree,
;;; and the name "clock" comes from the class rather than from a table.

(define-module (scheme-desktop widgets bar clock)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-desktop splice)
  #:use-module (scheme-toolkit time)
  ;; For `run-command', which is what the poll's command procedure calls.
  #:use-module (scheme-toolkit process)
  #:use-module (oop goops)
  #:export (<clock-desktop-widget>))

(define-gi-imports "Gtk" "Label")

;; THE CLOCK'S OWN OPTION, declared where it is read.  This used to be a line in
;; the shell's central schema and the widget looked it up by the string
;; 'clock-format; now the widget IS the schema and the value lives in its slot.
(define-class <clock-desktop-widget> (<bar-item-widget>)
  (format #:init-value "%H:%M" #:init-keyword #:format
          #:accessor clock-format
          #:config '(string)
          #:label "Time format"))


;; LIVE BUT NOT IN THE BAR: the date menu's button shows the time already, so the
;; clock is there for a user who wants a second one, and is placed by hand.
(define-method (widget-enable! (w <clock-desktop-widget>) config)
  (config-splice-add-widget config w))

(define (clock-command w)
  "The date command for W's configured format."
  (list "date" (string-append "+" (clock-format w))))

;; One poll for the process, not one per monitor: every bar reads the same
;; accessor, so three monitors cost one subprocess a second rather than three.
;; Cold by design -- it does nothing until a label subscribes.
(define %clock-poll #f)

(define (clock-poller)
  "The one poll, made on first ask.

THE COMMAND IS A PROCEDURE, and `create-poll' calls it on EVERY TICK -- so the
format is read at each tick, and a changed format needs no new poll, no
re-pointing of the labels, and no watcher on the slot at all.  A list command is
fixed when the poll is made, and that is the whole difference: the label stays
bound to one accessor for the life of the shell, and what it shows follows the
option within a tick.

IT RESOLVES THE WIDGET BY NAME rather than closing over W.  The widget this poll
was first made for is not necessarily the one that exists later, and a captured
one would go on formatting with a dropped object's option."
  (unless %clock-poll
    (set! %clock-poll
          (create-poll 1000
                       (lambda ()
                         (run-command (clock-command
                                       (desktop-widget-required <clock-desktop-widget>)))))))
  %clock-poll)

(define-method (widget-build (w <clock-desktop-widget>) output)
  "A label showing the time in the configured format.

OUTPUT is the monitor's connector name.  The clock does not care which bar it
is on -- the poll is shared, so three monitors cost one `date' a second -- and
it takes the argument because every widget does.  A widget that DOES care is
the point of the argument, not this one.

THE FORMAT IS READ BY THE POLL, once a tick -- see `clock-poller'.  So there is
nothing to do here about it, and no `#:apply' on the format slot: the label is
bound to one accessor for the life of the shell, and the accessor asks `date'
with whatever format the option holds when it runs."
  (element <gtk-label> #:label (clock-poller) #:class "clock"))
