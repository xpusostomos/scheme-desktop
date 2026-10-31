;;; (scheme-desktop widgets theme) -- the one number that scales the shell
;;;
;;; THIS WIDGET EXISTS TO OWN AN OPTION.  `ui-scale` is not a bar item, not a
;;; panel, and not any other widget's business -- but it is a user option, and
;;; options belong to widgets now, so it needs one to belong to.
;;;
;;; That is not a workaround for the rule; it is the rule doing its job. Before,
;;; the scale was a line in a central schema that nothing owned, and the file
;;; said `(ui-scale . 1.4)` with no indication of what would read it. Now it
;;; appears in the settings widget under "theme", because the thing that reads
;;; it declares it.
;;;
;;; It is a plain `<desktop-widget>' -- no window, no bar presence, no tree to
;;; build. A widget is a thing the shell has; most of them draw something, and
;;; this one does not.

(define-module (scheme-desktop widgets theme)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-desktop style)
  #:use-module (oop goops)
  #:export (<theme-desktop-widget> theme-widget theme-scale theme-panel-opacity))

(define-class <theme-desktop-widget> (<desktop-widget>)
  ;; 1.0 is the size the stylesheet was ported at.  Everything sized in the
  ;; stylesheet is multiplied by this: font, padding, spacing, radius, icons.
  (scale #:init-value 1.0 #:init-keyword #:scale
         #:accessor theme-scale
         #:config '(number 0.75 3.0)
         #:label "Interface scale")

  ;; HOW OPAQUE A PANEL IS, for every panel at once.  ONE POINT OH BY DEFAULT:
  ;; the other panels are fully opaque and this is what makes one of them lighter
  ;; than the others, so the default is the look they already had.
  ;;
  ;; (In case the arithmetic is unclear: 0.92 is 92% OPAQUE -- nearly solid --
  ;; which was still too see-through in practice, so the default is now opaque
  ;; and the option is for making panels LIGHTER than each other, not darker.)  The windows are transparent
  ;; -- a popup is the size of the screen, so painting it would dim the desktop --
  ;; which leaves each panel's card to paint itself, and this is what it paints
  ;; with.  One value rather than one per panel, because four panels set
  ;; separately are four chances to disagree; the bar's own `opacity' option is
  ;; its counterpart, and this is the one for the windows that open.
  (panel-opacity #:init-value 1.0 #:init-keyword #:panel-opacity
                 #:accessor theme-panel-opacity
                 #:config '(number 0.2 1.0)
                 #:label "Panel opacity"
                 ;; The stylesheet is generated from the palette and this, so a
                 ;; change restyles rather than rebuilds.
                 #:apply (lambda (w v) (apply-shell-css!))))

(define (theme-widget)
  "THE theme widget, from the registry."
  (desktop-widget-required 'theme))
