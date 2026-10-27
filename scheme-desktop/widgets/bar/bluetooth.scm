;;; (scheme-desktop widgets bar bluetooth) -- adapter state
;;;
;;; Powered versus connected are different things and both matter at a glance: a
;;; powered adapter with nothing attached is the common state, and showing the
;;; same icon for it as for a connected headset would make the bar useless.
;;; Adwaita's icon names carry that distinction.

(define-module (scheme-desktop widgets bar bluetooth)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit astal)
  #:use-module (oop goops)
  #:export (bluetooth-widget))

(define-gi-imports "Gtk" "Box" "Image")

(define (bluetooth-icon powered connected)
  (cond
   ((not powered) "bluetooth-disabled-symbolic")
   (connected "bluetooth-active-symbolic")
   (else "bluetooth-symbolic")))

(define (bluetooth-widget)
  "An icon reflecting the adapter, or an empty box when there is none.

Hidden rather than shown-disabled when the machine has no adapter: a permanently
greyed-out icon is noise on a desktop that never had bluetooth."
  (if (not (bluetooth))
      (element <gtk-box> #:class "bluetooth")
      (let* ((powered (create-binding (bluetooth) "is-powered" 'bt-powered))
             (connected (create-binding (bluetooth) "is-connected" 'bt-connected))
             (icon (create-computed
                    (lambda ()
                      (bluetooth-icon (st-peek powered) (st-peek connected))))))
        (element <gtk-box>
                 #:orientation 'horizontal
                 ;; As with network: powered off is dimmed, not hidden, so the
                 ;; bar's layout does not shift when bluetooth is toggled.
                 #:class (create-computed
                          (lambda ()
                            (if (st-peek powered)
                                "bluetooth"
                                "bluetooth unavailable")))
                 #:tooltip-text (create-computed
                                 (lambda ()
                                   (if (st-peek powered)
                                       (if (st-peek connected) "Bluetooth connected"
                                           "Bluetooth on")
                                       "Bluetooth off")))
                 (element <gtk-image> #:icon-name icon)))))
