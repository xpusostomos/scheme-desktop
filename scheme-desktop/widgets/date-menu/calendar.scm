;;; (scheme-desktop widgets date-menu calendar) -- the clock and the calendar
;;;
;;; PORTED FROM ags2-shell `widget/Bar/components/DateMenu/', the DateColumn
;;; half.  Deliberately standalone: nothing here knows about notifications, so
;;; another window that wants a clock and a calendar can use it as it is.
;;;
;;;   box.date-column.vertical
;;;     box.clock-box.vertical
;;;       label.clock          5em, the time, empty while the window is shut
;;;       label.uptime         "uptime: h:mm", refreshed once a minute
;;;     box.calendar
;;;       Gtk.Calendar
;;;
;;; The clock is empty until SHOWN is true, and the uptime timer runs only while
;;; it is, because that is what ags2-shell does -- a closed date menu is not
;;; formatting a string every second.
;;;
;;; WHOSE CLOCK IS IT.  The visibility gate is the CALLER's: `date-menu-window'
;;; passes its own window's, so this module can be dropped into any window that
;;; can say when it is open.  Everything else -- the poll, the timer, the
;;; formatting -- is this module's.

(define-module (scheme-desktop widgets date-menu calendar)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit time)
  #:use-module (scheme-toolkit app)
  #:use-module (ice-9 format)
  #:export (calendar-column watch-calendar!))

(define-gi-imports "Gtk" "Label" "Box" "Calendar")

;;; ---------------------------------------------------------------------------
;;; The clock
;;; ---------------------------------------------------------------------------

;; The time alone: ags2-shell's date column shows `%H:%M' at 5em, and the full
;; date is already on the bar button above it.
(define %time-poll #f)

(define (time-poller)
  "The clock accessor, created on first use.  Returns the ACCESSOR, not its
value -- a caller that wants the time calls it again, as `date-poller' does on
the bar button, where handing `element' an accessor is exactly how a property
gets bound."
  (unless %time-poll
    (set! %time-poll (create-poll 1000 '("date" "+%H:%M"))))
  %time-poll)

;; A STATE, not a Guile parameter: a parameter's value is not something an
;; accessor can subscribe to, and `parameterize' is thread-local besides.
(define-values (%shown set-shown!) (create-state #f))

(define (clock-visible-text)
  "The time while the window is open, the empty string while it is not.

THE EXTRA SET OF PARENTHESES IS THE WHOLE PROCEDURE.  `time-poller' hands back
an accessor, so `(time-poller)' is the accessor and `((time-poller))' is the
time.  Returning the accessor made this computed's VALUE an accessor object,
which the label then displayed as the empty string -- a wrong answer that looked
exactly like the gate being closed."
  (if (%shown) ((time-poller)) ""))

;;; ---------------------------------------------------------------------------
;;; Uptime
;;; ---------------------------------------------------------------------------

;; ags2-shell reads /proc/uptime and refreshes it once a minute WHILE THE MENU
;; IS OPEN:
;;
;;   const unsubscribe = on_window_toggle("datemenu", (window) => {
;;       uptime_timer?.cancel(); uptime_timer = null
;;       set_shown(window.visible)
;;       if (window.visible) uptime_timer = interval(60_000, update)
;;   })

;; A STATE, not a Guile parameter, and that is the whole point: the label is a
;; `create-computed' over this value, and a parameter is not something a
;; computed can track.  As a parameter the label read 0:00 once at build time
;; and never changed again -- silently, since the value it printed was valid.
(define-values (%uptime-minutes set-uptime-minutes!) (create-state 0))
(define %uptime-timer #f)

(define (read-uptime-minutes)
  "Whole minutes since boot, from /proc/uptime, or #f when unreadable.

`read', not `read-line'.  /proc/uptime is \"<seconds> <idle-seconds>\\n\" and
`read' parses the first field as a number outright, which is one call instead of
three.  It is also the only version that WORKS here: `read-line' is unbound in
this module, because (scheme-toolkit gi) re-exports G-Golf's interface and
G-Golf takes the name.  The failure was silent -- the `catch' below turned
\"Unbound variable: read-line\" into #f, and the label showed `uptime: 0:00'."
  (catch #t
    (lambda ()
      (call-with-input-file "/proc/uptime"
        (lambda (port)
          (let ((secs (read port)))
            (and (number? secs) (inexact->exact (floor (/ secs 60))))))))
    (lambda args #f)))

(define (format-uptime minutes)
  "ags2-shell's `uptime: h:mm', with the minutes zero-padded to two."
  (format #f "uptime: ~a:~2,'0d" (quotient minutes 60) (remainder minutes 60)))

(define (uptime-tick)
  (let ((m (read-uptime-minutes)))
    (when m (set-uptime-minutes! m))))

;;; ---------------------------------------------------------------------------
;;; The column
;;; ---------------------------------------------------------------------------

(define (calendar-column)
  "The clock, the uptime and the calendar, as one vertical box."
  (element <gtk-box> #:class "date-column vertical"
           #:orientation 'vertical
           (element <gtk-box> #:class "clock-box vertical"
                    #:orientation 'vertical
                    (element <gtk-label> #:class "clock"
                             #:label (create-computed clock-visible-text))
                    (element <gtk-label> #:class "uptime"
                             #:label (create-computed
                                      (lambda () (format-uptime (%uptime-minutes))))))
           (element <gtk-box> #:class "calendar" #:hexpand #t
                    (element <gtk-calendar> #:halign 'center))))

;;; ---------------------------------------------------------------------------
;;; Following a window
;;; ---------------------------------------------------------------------------

(define (watch-calendar! win)
  "Follow WIN: show the clock and run the minute timer exactly while it is open.

Takes the WINDOW rather than a name so any window can own a calendar column."
  (on-window-toggle
   (catch #t (lambda () (slot-ref win 'name)) (lambda args #f))
   (lambda (w)
     (let ((open (catch #t (lambda () (slot-ref w 'visible)) (lambda a #f))))
       (set-shown! (and open #t))
       (timer-cancel %uptime-timer)
       (set! %uptime-timer #f)
       (when open
         (uptime-tick)
         (set! %uptime-timer (interval 60000 uptime-tick)))))))
