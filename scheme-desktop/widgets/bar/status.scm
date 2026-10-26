;;; (scheme-desktop widgets bar status) -- battery, and the bar's right corner
;;;
;;; The simplest shape a live bar widget takes: an accessor over a service
;;; property, a computed that turns it into a string, and a label bound to that.
;;; Everything here updates itself; nothing polls the shell's main loop.
;;;
;;; A machine with no battery gets an empty widget rather than an error or a
;;; placeholder -- (battery) returns #f, (battery-percentage) becomes an
;;; accessor of #f, and the computed renders "".

(define-module (scheme-desktop widgets bar status)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit astal)
  #:use-module (oop goops)
  #:use-module (ice-9 format)

  #:export (battery-widget))

(define-gi-imports "Gtk" "Box" "Image" "Label")

(define (percent-string v)
  "0.84 => \"84%\".

`round' on a float returns a float in Guile, so ~a prints 84.0.  Converting to
an exact integer first is what makes the label read 84%."
  (if (number? v)
      (format #f "~a%" (inexact->exact (round (* 100 v))))
      ""))

(define (battery-icon charging? state percentage)
  "A symbolic icon name for the current charge.

Adwaita's own names, so the icon themes correctly.  Charging wins over the
level, because `battery-full-charging-symbolic' reads as charging at a glance
where a full battery does not."
  (cond
   ((not (number? percentage)) #f)
   (charging? "battery-full-charging-symbolic")
   ((>= percentage 0.9) "battery-full-symbolic")
   ((>= percentage 0.6) "battery-good-symbolic")
   ((>= percentage 0.3) "battery-low-symbolic")
   (else "battery-caution-symbolic")))

(define (battery-widget)
  "A box holding the battery icon and percentage, or an empty box."
  (if (not (battery))
      (element <gtk-box> #:class "battery")
      (let* ((pct (battery-percentage))
             (charging (battery-charging?))
             (state (battery-state))
             ;; A computed over three sources: the icon depends on charge level
             ;; AND charging state, and changes when either does.
             (icon-name (create-computed
                         (lambda ()
                           (battery-icon (st-peek charging)
                                         (st-peek state)
                                         (st-peek pct)))))
             (text (create-computed
                    (lambda () (percent-string (pct))))))
        (element <gtk-box>
                 #:orientation 'horizontal
                 #:class "battery"
                 ;; #:icon-name is a property like any other, so a computed
                 ;; binds to it directly.
                 (element <gtk-image> #:icon-name icon-name)
                 (element <gtk-label> #:label text #:class "battery-label")))))
