;;; (scheme-desktop widgets date-menu notifications) -- the notification column
;;;
;;; PORTED FROM ags2-shell `widget/Bar/components/DateMenu/', the NotifyColumn
;;; half.  Deliberately standalone: nothing here knows about the calendar, so
;;; the control centre's notification history and the popup list can use it too.
;;;
;;;   box.notifications.vertical
;;;     box.notifications-header        "Notifications" + Clear
;;;     scrolledwindow.notification-scrollable
;;;       box.vertical
;;;         the list                      (D8)
;;;         revealer
;;;           placeholder                 "No new notifications"
;;;
;;; WHAT IS MISSING IS D8, AND IT IS NOT A GAP IN THIS FILE.  The list itself is
;;; ags2-shell's `Notifications.NotificationList', which needs the shell to own
;;; org.freedesktop.Notifications; on this machine quickshell owns it, so
;;; `(notify-history)' is '() and the placeholder shows.  That is also what
;;; ags2-shell shows with no notifications, so what is on screen is right even
;;; though the reason is not.

(define-module (scheme-desktop widgets date-menu notifications)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit notify)
  #:use-module (ice-9 format)
  #:export (notifications-column notification-count refresh-notifications!))

(define-gi-imports "Gtk"
  "Label" "Box" "Button" "Image" "ScrolledWindow" "Revealer")

;;; ---------------------------------------------------------------------------
;;; The count
;;; ---------------------------------------------------------------------------

;; `(notify-history)' reads whatever daemon currently owns
;; org.freedesktop.Notifications.  On this machine that is quickshell, not this
;; shell, so it answers '() -- and "another daemon owns the name" is NOT the
;; same as "no notifications": `notify-status' tells the two apart, and the UI
;; is built to say nothing rather than to claim there is nothing.
;;
;; A STATE rather than a computed: `notify-history' subscribes to nothing, so a
;; computed over it would read once and never again.  A caller refreshes it when
;; the window opens, which is the only time it is on screen.
(define-values (%count set-count!) (create-state 0))

(define (refresh-notifications!)
  "Re-read the notification count from whatever daemon answers."
  (set-count!
   (catch #t (lambda () (length (notify-history))) (lambda args 0))))

(define (notification-count)
  "How many notifications the list currently holds."
  (%count))

(define (has-notifications)
  (> (%count) 0))

;;; ---------------------------------------------------------------------------
;;; The column
;;; ---------------------------------------------------------------------------

(define (clear-button)
  "The Clear button in the header.

Insensitive with nothing to clear, which is ags2-shell's
`sensitive={notification_list.as((entries) => entries.length > 0)}'.  Its
trash icon swaps between full and empty the same way; both are declared here
rather than in the stylesheet because an icon NAME is content, not appearance."
  (element <gtk-button>
           #:valign 'center
           #:sensitive (create-computed has-notifications)
           (element <gtk-box>
                    (element <gtk-label> #:label "Clear")
                    (element <gtk-image>
                             #:icon-name (create-computed
                                          (lambda ()
                                            (if (has-notifications)
                                                "user-trash-full-symbolic"
                                                "user-trash-symbolic")))))))

(define (header)
  (element <gtk-box> #:class "notifications-header"
           (element <gtk-label> #:label "Notifications"
                    #:hexpand #t #:xalign 0.0)
           (clear-button)))

(define (placeholder)
  "ags2-shell's Placeholder: an icon and a label, centred, for an empty column.

`use-fallback' is theirs and it matters: without it an icon name the theme does
not have renders as NOTHING, and a missing icon plus a zero-size image reads as
a broken widget rather than as a missing icon."
  (element <gtk-box> #:class "placeholder vertical"
           #:orientation 'vertical
           #:valign 'center #:halign 'center
           #:vexpand #t #:hexpand #t
           (element <gtk-image> #:icon-name "notifications-disabled-symbolic"
                    #:use-fallback #t
                    #:pixel-size 64)
           (element <gtk-label> #:label "No new notifications")))

(define (notifications-column)
  "The notification column: a header, a scrolled list, and an empty placeholder."
  (element <gtk-box> #:class "notifications"
           #:orientation 'vertical #:vexpand #t
           (header)
           (element <gtk-scrolled-window>
                    #:class "notification-scrollable"
                    #:hscrollbar-policy 'never
                    (element <gtk-box> #:orientation 'vertical #:vexpand #t
                             ;; The list is D8; the placeholder is shown
                             ;; exactly while the count is zero, which is the
                             ;; condition ags2-shell reveals it on.
                             (element <gtk-revealer>
                                      #:transition-duration 200
                                      ;; `(has-notifications)', not
                                      ;; `has-notifications'.  Without the call
                                      ;; this is `(not <procedure>)', which is
                                      ;; #f for ever -- so the placeholder was
                                      ;; built, correctly, and then never
                                      ;; revealed.  A one-character bug that
                                      ;; presents as a missing feature.
                                      #:reveal-child
                                      (create-computed
                                       (lambda () (not (has-notifications))))
                                      (placeholder))))))
