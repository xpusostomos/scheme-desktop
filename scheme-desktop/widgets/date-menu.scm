;;; (scheme-desktop widgets date-menu) -- the bar's date button and its menu
;;;
;;; PORTED FROM ags2-shell `widget/Bar/components/DateMenu/index.tsx'.  This
;;; module is the COMPOSITION and nothing else: it decides that the date menu is
;;; a notification column, a rule and a calendar column, and where it opens.  The
;;; two columns live next door in (scheme-desktop widgets date-menu calendar)
;;; and (scheme-desktop widgets date-menu notifications), each usable on its own
;;; -- the control centre wants the notification list without the calendar, and
;;; a future clock popover wants the calendar without the list.
;;;
;;;   Button()   PanelButton targetWindow="datemenu", labelled with the clock
;;;   Window()   PopupWindow "datemenu" holding box.datemenu: three columns
;;;
;;; THE THREE-COLUMN LAYOUT.  ags2-shell uses a custom Gtk.Widget subclass whose
;;; vfunc_measure gives the two sides EQUAL width and whose vfunc_size_allocate
;;; places them, leaving the separator its natural width in the middle.
;;; Gtk.CenterBox already measures start and end to the SAME width -- see
;;; gtk_center_box_measure in gtkcenterbox.c, which takes the max of the two for
;;; both -- so a CenterBox with the separator in its centre slot gives the
;;; identical geometry with a stock widget.  A define-vfunc widget over
;;; <gtk-widget> is the fallback if that ever stops being true.

(define-module (scheme-desktop widgets date-menu)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit time)
  ;; For `run-command', which the poll's command procedure calls.
  #:use-module (scheme-toolkit process)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-desktop splice)
  #:use-module (scheme-toolkit config)
  #:use-module (scheme-desktop config)
  #:use-module (scheme-desktop widgets date-menu calendar)
  #:use-module (scheme-desktop widgets date-menu notifications)
  #:use-module (oop goops)
  #:export (<datemenu-desktop-widget> <datemenu-panel-desktop-widget>
            datemenu-popup-position))

(define-gi-imports "Gtk" "Label" "Box" "CenterBox" "Separator")

;;; ---------------------------------------------------------------------------
;;; The bar button
;;; ---------------------------------------------------------------------------

;; One poll for the process, like (scheme-desktop widgets bar clock): every
;; monitor's bar reads the same accessor, so three monitors cost one `date' a
;; second rather than three.
(define-class <datemenu-desktop-widget> (<bar-item-widget>)
  (date-format #:init-value "%a %b %-d %H:%M" #:init-keyword #:date-format
               #:accessor datemenu-date-format
               #:config '(string)
               #:label "Date format"))


;; THE DATE IS THE CENTRE OF THE BAR.
(define-method (widget-enable! (w <datemenu-desktop-widget>) config)
  (config-splice-into-bar (config-splice-add-widget config w) w 'center 'end))

(define (date-command w)
  (list "date" (string-append "+" (datemenu-date-format w))))

(define %date-poll #f)

(define (date-poller)
  "The one date poll, made on first ask.

THE SAME SHAPE AS THE CLOCK'S, and for the same reason: the command is a
PROCEDURE, so `create-poll' calls it on every tick and the format is read at each
one.  A list command is fixed when the poll is made, so a changed format would
need a new poll and a re-pointed label; this needs neither, and the label follows
the option within a tick.

BY NAME, not by captured widget: this poll outlives whichever widget asked for it
first."
  (unless %date-poll
    (set! %date-poll
          (create-poll 1000
                       (lambda ()
                         (run-command (date-command
                                       (desktop-widget-required <datemenu-desktop-widget>)))))))
  %date-poll)

(define-method (widget-build (w <datemenu-desktop-widget>) output)
  "The bar's date button: PanelButton targetWindow=\"datemenu\".

The label is the clock in the configured format -- ags2-shell's default
\"%a %b %-d %H:%M\", which reads \"Tue Oct 27 23:37\"."
  (panel-button (desktop-widget-required <datemenu-panel-desktop-widget>)
                #:align (widget-section w)
                #:halign 'center
                (element <gtk-label> #:valign 'center #:label (date-poller))))

;;; ---------------------------------------------------------------------------
;;; Where it opens
;;; ---------------------------------------------------------------------------

(define (datemenu-popup-position w)
  "Where the date menu opens: the bar's edge, and this panel's own horizontal half."
  (bar-popup-position #:horizontal (datemenu-position w)))

;;; ---------------------------------------------------------------------------
;;; The window
;;; ---------------------------------------------------------------------------

(define-class <datemenu-panel-desktop-widget> (<popup-widget>)
  ;; Where the panel opens, horizontally.  The vertical half comes from the bar,
  ;; as ags2-shell's `create_popup_position' does; only the horizontal half is
  ;; this option's, which is why the bar's own value is not repeated here.
  (datemenu-position #:init-value 'center #:init-keyword #:datemenu-position
                     #:accessor datemenu-position
                     #:config '(choice center top-center bottom-center)
                     #:label "Where it opens")
  ;; THE WINDOW, REMEMBERED.  `widget-window' is called every time anything asks
  ;; this panel for its window -- `widget-toggle!', `widget-visible?', the
  ;; registry walk at startup -- so a method that builds without storing builds a
  ;; WINDOW PER CALL: each one is a layer surface nobody destroys, and the one
  ;; that gets shown is never the one that gets read back.  Measured: two calls
  ;; returned two different windows, so `(widget-toggle! panel)' reported success
  ;; and `(widget-visible? panel)' still said no.
  ;;
  ;; The other two panels have always done this; this one did not, and it is the
  ;; reason for the "on-cleanup called outside a scope" lines at startup -- every
  ;; build subscribes the clock to a scope that is already gone.
  (window #:init-value #f #:accessor datemenu-panel-window
          #:setter datemenu-panel-window-set!))

;; THE WIDGET IS `datemenu-panel' AND THE WINDOW IS `datemenu'.  The widget's
;; name is the FEATURE -- the bar button and the panel together -- and the
;; window's is what the stylesheet and the layer shell call it, which is why
;; every rule in style.scm says `window#datemenu'.  Declared once here rather
;; than written out at the `popup-window' call so the window's name, the button's
;; visibility hook and the place the panel opens from cannot drift apart.
(define-method (widget-window-name (w <datemenu-panel-desktop-widget>)) "datemenu")

(define-method (widget-window (w <datemenu-panel-desktop-widget>))
  "The date menu popup: notifications, a rule, the calendar.

Built once and remembered -- see the note on the `window' slot."
  (or (datemenu-panel-window w)
      (let ((win (popup-window (widget-window-name w)
                               #:position (datemenu-popup-position w)
                               (element <gtk-box> #:class "datemenu horizontal"
                                        (element <gtk-center-box>
                                                 ;; The slots are EXPLICIT, and
                                                 ;; they have to be: add-child!
                                                 ;; puts an untyped child in a
                                                 ;; CenterBox's CENTRE slot, so
                                                 ;; three untyped children end with
                                                 ;; the last one having silently
                                                 ;; replaced the other two -- which
                                                 ;; showed up as a date menu
                                                 ;; containing only its calendar.
                                                 (this! (notifications-column)
                                                        #:slot 'start)
                                                 (this! (element <gtk-separator>
                                                                 #:orientation 'vertical)
                                                        #:slot 'center)
                                                 (this! (calendar-column)
                                                        #:slot 'end))))))
        ;; Both columns follow this window: the clock and the uptime timer run
        ;; only while it is open, and the notification count is read when it
        ;; opens.
        (watch-calendar! win)
        (on-window-toggle (widget-window-name w)
                          (lambda (win)
                            (when (catch #t (lambda () (slot-ref win 'visible))
                                         (lambda a #f))
                              (refresh-notifications!))))
        (datemenu-panel-window-set! w win))))
