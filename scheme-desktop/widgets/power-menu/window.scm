;;; (scheme-desktop widgets power-menu window) -- the power menu itself
;;;
;;; PORTED FROM ags2-shell `widget/PowerMenu/index.tsx', `PowerMenu.Window' and
;;; its `ActionButton': a popup holding the four session actions, laid out one
;;; way or another by an option, with their names shown or not by a second one.
;;;
;;; **PRESSING AN ACTION DOES NOT DO IT.**  Every button calls
;;; `request-power-action!' in `(scheme-desktop widgets power-menu
;;; verification)', which asks first -- see that module, and ags2-shell's
;;; `request_action_confirmation'.
;;;
;;; THE WIDGET IS `powermenu-panel' AND THE WINDOW IS `powermenu': the widget's
;;; name is the feature and the window's is what the layer shell and the
;;; stylesheet call it.  (scheme-desktop widgets date-menu) makes the same split
;;; for the same reason, and the bar button next door names the PANEL widget it
;;; opens rather than the window.

(define-module (scheme-desktop widgets power-menu window)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-desktop widgets theme)
  #:use-module (scheme-desktop widgets power-menu verification)
  #:use-module (oop goops)
  #:export (<powermenu-panel-desktop-widget>))

(define-gi-imports "Gtk" "Box" "Label" "Image" "Button")

(define-class <powermenu-panel-desktop-widget> (<popup-widget>)
  ;; HOW THE FOUR ARE LAID OUT.  ags2-shell's `options.powermenu.layout':
  ;; `line' is one row of four, `box' is two rows of two.
  (layout #:init-value 'line #:init-keyword #:layout
          #:accessor powermenu-layout
          #:config '(choice line box)
          #:label "Power menu layout")
  ;; WHETHER EACH ACTION'S NAME IS SHOWN UNDER ITS ICON -- ags2-shell's
  ;; `options.powermenu.labels'.  #t there, so #t here.
  (labels #:init-value #t #:init-keyword #:labels
          #:accessor powermenu-labels
          #:config '(boolean)
          #:label "Show action names")
  ;; Built once and remembered -- see (scheme-desktop widgets date-menu).
  (window #:init-value #f #:accessor powermenu-panel-window
          #:setter powermenu-panel-window-set!))

(define-method (widget-window-name (w <powermenu-panel-desktop-widget>))
  "powermenu")

(define (action-button w action)
  "One action: its icon, its name when the option says so, and the ask.

The icon's size is ags2-shell's 52 scaled by the user's interface scale --
`Math.round((52 * scale) / 100)' there, where its `scale' is a PERCENTAGE (100
being normal) and this shell's `ui-scale' is a ratio (1.0 being normal).  The
same look, so the division by a hundred is the one part of that expression that
does not come across.

**AND `inexact->exact' IS NOT DECORATION.**  `theme-scale' is inexact (1.0), so
`(round (* 52 1.0))' is 52.0 -- and `pixel-size' is an INT property, so building
the menu raised `Wrong type (expecting exact integer): 52.0' the first time it
ran.  A name being right is not the same as its value being the right type, which
is exactly what compiling cannot check."
  (element <gtk-button>
           #:on-clicked (lambda (b) (request-power-action! action))
    (element <gtk-box> #:orientation 'vertical
      (element <gtk-image>
               #:icon-name (power-action-icon action)
               #:pixel-size (inexact->exact
                             (round (* 52 (theme-scale (theme-widget))))))
      (element <gtk-label>
               #:label (power-action-title action)
               #:visible (powermenu-labels w)))))

(define-method (widget-window (w <powermenu-panel-desktop-widget>))
  "The power menu popup: the four actions, in the configured layout.

`#:position (bar-popup-position)' and a crossfade, which is what ags2-shell's
`PopupWindow' does -- it follows the bar button it was opened from, rather than
appearing in the middle of the screen the way a modal does."
  (unless (powermenu-panel-window w)
    (let* ((buttons (map (lambda (action) (action-button w action)) power-actions))
           (content
            (case (powermenu-layout w)
              ;; ONE ROW OF FOUR.  `homogeneous' is ags2-shell's: four buttons of
              ;; equal width, so the row does not shift as the labels change.
              ((line)
               (element <gtk-box> #:orientation 'horizontal #:homogeneous #t
                        (this! (list-ref buttons 0))
                        (this! (list-ref buttons 1))
                        (this! (list-ref buttons 2))
                        (this! (list-ref buttons 3))))
              ;; TWO ROWS OF TWO: (shutdown logout) over (reboot sleep).
              ((box)
               (element <gtk-box> #:orientation 'horizontal
                        (element <gtk-box> #:orientation 'vertical
                                 (this! (list-ref buttons 0))
                                 (this! (list-ref buttons 1)))
                        (element <gtk-box> #:orientation 'vertical
                                 (this! (list-ref buttons 2))
                                 (this! (list-ref buttons 3)))))
              (else (element <gtk-box>)))))
      (powermenu-panel-window-set!
       w
       (popup-window (widget-window-name w)
                     #:position (bar-popup-position)
                     #:transition 'crossfade
                     ;; The class carries the layout, as ags2-shell's does:
                     ;; `powermenu horizontal line' or `... box'.  It is what the
                     ;; stylesheet keys the spacing off.
                     (element <gtk-box>
                              #:class (string-append "powermenu horizontal "
                                                     (symbol->string (powermenu-layout w)))
                              (this! content))))))
  (powermenu-panel-window w))
