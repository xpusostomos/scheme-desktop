;;; (scheme-desktop widgets bar) -- the bar, one per monitor
;;;
;;; The D1 milestone: ~/GIT/ags/cli/data/gtk4/Bar.tsx reproduced in Scheme.  It
;;; exercises every part of the element runtime in thirty lines -- child slots,
;;; signal props, nesting, a non-intrinsic GI class, and an accessor bound to a
;;; property -- and it is the first thing you can look at.
;;;
;;; The STRUCTURE is colorshell's (src/window/bar/index.tsx): one window, one
;;; centerbox, a module per widget.  ags2-shell's bar is ~250 lines of
;;; options-driven variants -- position, transparency, screen corners, cairo
;;; input regions -- which arrive with options at D5, not here.

(define-module (scheme-desktop widgets bar)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit process)
  #:use-module (scheme-toolkit time)
  ;; The bar's own modules, one file each, as colorshell's bar/widgets/ is.
  #:use-module (scheme-desktop widgets bar workspaces)
  #:use-module (scheme-desktop widgets bar status)
  #:use-module (scheme-desktop widgets bar volume)
  #:use-module (scheme-desktop widgets bar network)
  #:use-module (scheme-desktop widgets bar bluetooth)
  #:use-module (scheme-desktop widgets bar media)
  #:use-module (scheme-desktop style)

  #:export (build-bar! bar-clock))

(define-gi-imports "Gtk"
  "Box" "CenterBox" "Label" "Button" "MenuButton" "Popover" "Calendar")
(define-gi-imports "Astal" "Window")

;; The clock, from the same poll the AGS template uses:
;;
;;   const time = Variable("", { poll: [1000, "date +%H:%M"] })
;;
;; Binding it to a label property is what makes it live: the element runtime
;; subscribes, and re-sets #:label whenever the accessor's value changes.
;; create-poll is cold, so this costs nothing until a label subscribes to it.
(define bar-clock (create-poll 1000 '("date" "+%H:%M")))

(define* (build-bar! monitor #:key (name "bar"))
  "Build the bar for MONITOR and return it.

NAME is the monitor's own identifier, passed on to the window so that a
hotplug can tell one bar from another; for-each-monitor supplies it."
  (let ((win
   (layer-window
   name
   #:anchor '(top left right)
   #:exclusivity 'exclusive
   #:layer 'top
   #:gdkmonitor monitor
   #:class "Bar"
   ;; NOTE: no #:namespace.  Setting a custom layer-shell namespace makes the
   ;; window build, present without error, and then never appear -- Hyprland
   ;; keeps no surface for it.  The default namespace works.  See
   ;; docs/known-issues.md in scheme-toolkit.

   (element <gtk-center-box>
            #:name (string-append "bar-" name)

            ;; start: workspace pills, then the Welcome button from the AGS
            ;; template.  The pills are the first `For'-style module -- they
            ;; rebuild themselves when the workspace list or the focus changes.
            (element <gtk-box> #:slot 'start
                     #:orientation 'horizontal
                     #:class "bar-start"
                     (workspaces-widget)
                     (element <gtk-button>
                              #:label "Welcome"
                              #:class "bar-button"
                              #:on-clicked (lambda (b)
                                             (exec-async '("notify-send"
                                                           "hello from Scheme")))))

            ;; centre: what is playing, between the clock and its own
            ;; controls.  Empty when no player is running.
            (element <gtk-box> #:slot 'center
                     #:orientation 'horizontal
                     #:class "bar-center"
                     (media-widget)
                     (element <gtk-label>
                              #:label bar-clock
                              #:class "clock"))

            ;; end: battery, then the calendar popover.
            (element <gtk-box> #:slot 'end
                     #:orientation 'horizontal
                     #:class "bar-end"
                     (network-widget)
                     (bluetooth-widget)
                     (volume-widget)
                     (battery-widget)
                     (element <gtk-menu-button>
                              #:class "bar-button"
                              (element <gtk-label> #:label "Calendar")
                              (element <gtk-popover>
                                       (element <gtk-calendar>))))))))
    ;; The stylesheet goes on the toplevel, so one call covers the whole bar
    ;; including the popover's contents.
    (apply-shell-css! win)
    win))
