;;; (scheme-desktop widgets power-menu button) -- the bar's power button
;;;
;;; PORTED FROM ags2-shell `widget/PowerMenu/index.tsx', `PowerMenu.Button': a
;;; PanelButton whose target is the power menu, showing the shutdown icon.
;;;
;;; IT IS THE FEATURE'S BAR ITEM AND NOTHING ELSE.  What the menu contains is
;;; next door in `(scheme-desktop widgets power-menu window)', and the "are you
;;; sure?" that stands between a click and a logout is
;;; `(scheme-desktop widgets power-menu verification)'.  ags2-shell has all three
;;; in one file; this is the split the date menu already uses, and it buys the
;;; same thing here -- a keybinding can open the menu without a bar item
;;; existing, which is why every panel in this shell is its own widget.

(define-module (scheme-desktop widgets power-menu button)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (oop goops)
  #:export (<powermenu-desktop-widget>))

(define-gi-imports "Gtk" "Image")

(define-class <powermenu-desktop-widget> (<bar-item-widget>))

;; ags2-shell's `icons.powermenu.shutdown', and the same icon the menu's own
;; shutdown button uses: the bar button and the thing it opens should not
;; disagree about what it is.
(define %shutdown-icon "system-shutdown-symbolic")

(define-method (widget-build (w <powermenu-desktop-widget>) output)
  "The bar's power button: PanelButton targetWindow=\"powermenu\".

The target is the PANEL widget, and the window it opens is named `powermenu' --
see the window module.  PanelButton tracks that window's visibility to set its
own `active' class, which is how the button shows the menu is open."
  (panel-button (desktop-widget-required 'powermenu-panel)
                #:align (widget-section w)
                (element <gtk-image> #:icon-name %shutdown-icon)))
