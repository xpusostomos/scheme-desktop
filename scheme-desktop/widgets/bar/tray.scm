;;; (scheme-desktop widgets bar tray) -- the system tray
;;;
;;; THE SMALLEST DESKTOP WIDGET, and it exists to say one thing: everything the
;;; tray actually does is the toolkit's.  StatusNotifier item handling, the
;;; dbusmenu action-group requirement, the menu-model plumbing and the popover
;;; are all in `(scheme-toolkit tray)' because they are the same for any shell.
;;; What is left for this shell to decide is the CSS class names and nothing
;;; else -- which is exactly the kind of decision that belongs in DESKTOP.
;;;
;;; It is a widget rather than a line in the bar's table because the bar no
;;; longer has a table: a widget is registered, and the bar's config says which
;;; registered widgets go in which section.

(define-module (scheme-desktop widgets bar tray)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit tray)
  #:use-module (oop goops)
  #:export (<tray-desktop-widget>))

(define-class <tray-desktop-widget> (<bar-item-widget>))

(define-method (widget-build (w <tray-desktop-widget>) output)
  "The StatusNotifier items, as a box.

OUTPUT is the monitor's connector name, which the tray does not use: every bar
shows the same items.  Each bar does get its OWN box and its own item buttons,
because `tray-widget' builds a fresh tree with its own reactive root per call --
so nothing here is shared between monitors, and the output name would be
misleading if anything read it."
  (tray-widget #:class "tray" #:item-class "tray-item"))
