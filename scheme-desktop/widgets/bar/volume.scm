;;; (scheme-desktop widgets bar volume) -- speaker volume
;;;
;;; The shape every one of these small bar modules takes: an accessor over a
;;; service property, a computed that turns the value into an icon name, and a
;;; widget bound to that.
;;;
;;; Clicking the widget toggles mute, which is what both reference shells do.
;;; The volume itself is only CHANGED from a keybinding or the OSD -- a bar
;;; widget that swallowed a scroll wheel would fight the compositor's own
;;; volume keys.

(define-module (scheme-desktop widgets bar volume)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit astal)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:export (volume-widget))

(define-gi-imports "Gtk" "Box" "Image" "Label")

(define (volume-icon muted volume)
  "An Adwaita symbolic icon for the current level."
  (cond
   (muted "audio-volume-muted-symbolic")
   ((not (number? volume)) "audio-volume-medium-symbolic")
   ((<= volume 0.001) "audio-volume-muted-symbolic")
   ((< volume 0.33) "audio-volume-low-symbolic")
   ((< volume 0.66) "audio-volume-medium-symbolic")
   (else "audio-volume-high-symbolic")))

(define (volume-text muted volume)
  (if (not (number? volume))
      ""
      (format #f "~a%" (inexact->exact (round (* 100 volume))))))

(define (volume-widget)
  "A button showing the speaker volume, or an empty box when there is no sink."
  (if (not (wp))
      (element <gtk-box> #:class "volume")
      (let* ((volume (speaker-volume))
             (muted (speaker-muted?))
             ;; Both the icon and the text depend on the level AND the mute
             ;; flag, so each is a computed over both rather than a derived
             ;; accessor of one.
             (icon (create-computed
                    (lambda () (volume-icon (st-peek muted) (st-peek volume)))))
             (text (create-computed
                    (lambda () (volume-text (st-peek muted) (st-peek volume))))))
        (element <gtk-button>
                 #:class "volume"
                 #:tooltip-text "Volume -- click to mute"
                 #:on-clicked (lambda (b)
                                (let ((sink (wp-default "default-speaker")))
                                  (when sink
                                    (catch #t
                                      (lambda () (slot-set! sink 'mute
                                                            (not (slot-ref sink 'mute))))
                                      (lambda args #f)))))
                 (element <gtk-image> #:icon-name icon)
                 (element <gtk-label> #:label text)))))
