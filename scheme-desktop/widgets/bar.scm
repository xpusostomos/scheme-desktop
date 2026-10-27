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
  #:use-module (scheme-desktop widgets bar clock)
  #:use-module (scheme-desktop style)
  ;; The schema is (scheme-desktop config); config-ref and config-value are the
  ;; toolkit's readers.
  #:use-module (scheme-toolkit config)
  #:use-module (scheme-desktop config)

  #:export (build-bar! bar-clock watch-bar-layout!))

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

;; --- options ---------------------------------------------------------------
;;
;; These are read at BUILD time.  A changed module list or position means the
;; tree is rebuilt, which is what rebuild-bar-on-option-change! at the end of
;; this file does: a widget cannot usefully be swapped out of a centerbox slot
;; in place, and moving the bar to the other edge means re-anchoring the layer
;; surface.  Options that a widget binds to directly -- clock-format, say --
;; need no rebuild, because the label is subscribed to the accessor.

(define (cfg name) (config-ref 'desktop name))

(define (bar-edge)
  "The edge the bar sits on: 'top or 'bottom."
  (st-peek (cfg 'bar-position)))

(define (bar-anchor edge)
  "The three anchors for EDGE.  Anchor and border side must agree, or the bar is
anchored to one edge and styled for the other."
  (if (eq? edge 'bottom) '(bottom left right) '(top left right)))

;; A module symbol to its widget constructor.  A symbol the table does not
;; know is skipped with a message rather than crashing the bar: a typo in a
;; list of widget names should cost one widget, not the shell.
(define %modules
  `((workspaces . ,workspaces-widget)
    (clock      . ,clock-widget)
    (media      . ,media-widget)
    (network    . ,network-widget)
    (bluetooth  . ,bluetooth-widget)
    (volume     . ,volume-widget)
    (battery    . ,battery-widget)
    (welcome    . ,(lambda ()
                     (element <gtk-button>
                              #:label "Welcome"
                              #:class "bar-button"
                              #:on-clicked (lambda (b)
                                             (exec-async '("notify-send"
                                                           "hello from Scheme"))))))
    (calendar   . ,(lambda ()
                     (element <gtk-menu-button>
                              #:class "bar-button"
                              (element <gtk-label> #:label "Calendar")
                              (element <gtk-popover>
                                       (element <gtk-calendar>)))))))

(define (modules-built names where)
  "The widgets for NAMES, in order."
  (let loop ((rest names) (out '()))
    (cond ((null? rest) (reverse! out))
          (else
           (let ((ctor (assq-ref %modules (car rest))))
             (if ctor
                 (loop (cdr rest) (cons (ctor) out))
                 (begin
                   (format (current-error-port)
                           "scheme-desktop: no such bar widget ~s in ~s~%"
                           (car rest) where)
                   (loop (cdr rest) out))))))))

(define* (build-bar! monitor #:key (name "bar"))
  "Build the bar for MONITOR and return it.

NAME is the monitor's own identifier, passed on to the window so that a
hotplug can tell one bar from another; for-each-monitor supplies it."
  (let* ((edge (bar-edge))
         (win
   (layer-window
   name
   #:anchor (bar-anchor edge)
   #:exclusivity 'exclusive
   #:layer 'top
   #:gdkmonitor monitor
   #:class (if (eq? edge 'bottom) "Bar bar-bottom" "Bar")
   ;; NOTE: no #:namespace.  Setting a custom layer-shell namespace makes the
   ;; window build, present without error, and then never appear -- Hyprland
   ;; keeps no surface for it.  The default namespace works.  See
   ;; docs/known-issues.md in scheme-toolkit.

   (element <gtk-center-box>
            #:name (string-append "bar-" name)

            ;; start: workspace pills, then the Welcome button from the AGS
            ;; template.  The pills are the first `For'-style module -- they
            ;; rebuild themselves when the workspace list or the focus changes.
            ;; The three sections are built from the config's module lists, in
            ;; the order the config gives.  Each box is created even when its
            ;; list is empty: a centerbox with a missing slot is fine, but
            ;; having all three always present means a config change never has
            ;; to reason about which slots exist.
            (apply element <gtk-box> #:slot 'start
                   #:orientation 'horizontal
                   #:class "bar-start"
                   (modules-built (config-value 'desktop 'bar-start) 'bar-start))

            (apply element <gtk-box> #:slot 'center
                   #:orientation 'horizontal
                   #:class "bar-center"
                   (modules-built (config-value 'desktop 'bar-center) 'bar-center))

            (apply element <gtk-box> #:slot 'end
                   #:orientation 'horizontal
                   #:class "bar-end"
                   (modules-built (config-value 'desktop 'bar-end) 'bar-end))))))
    ;; The stylesheet goes on the toplevel, so one call covers the whole bar
    ;; including the popover's contents.
    (apply-shell-css! win)
    win))

;;; ---------------------------------------------------------------------------
;;; Live layout changes
;;; ---------------------------------------------------------------------------
;;
;; The options below only take effect on a rebuild, because they decide the
;; SHAPE of the tree or the anchoring of the surface:
;;
;;   bar-position   which edge, so the anchor and the CSS class
;;   bar-start/center/end   which widgets exist, so the children
;;
;; Everything else is bound to an accessor by the widget that uses it and needs
;; no rebuild.
;;
;; A rebuild destroys the windows and builds them again.  That is deliberately
;; blunt: the alternative is diffing two widget trees, and a bar is cheap enough
;; to rebuild that the complexity would not pay for itself.

(define %layout-options '(bar-position bar-start bar-center bar-end bar-height))

(define (layout-option? name) (memq name %layout-options))

(define %rebuild-hook #f)

(define (on-layout-change! proc)
  "Call PROC whenever an option that changes the bar's SHAPE changes.

The shell registers a rebuild here once, after its first build.  PROC runs on
the main loop, from the config's file monitor, so it is safe to touch GTK."
  (set! %rebuild-hook proc))

(define* (watch-bar-layout! rebuild #:key (options %layout-options))
  "Arrange for REBUILD to run when any of OPTIONS changes.

Returns a procedure that stops watching, so a shell that tears its bar down can
unsubscribe rather than keeping a dead closure alive."
  (on-layout-change! rebuild)
  (let ((subscriptions
         (map (lambda (name)
                (subscribe (cfg name)
                           (lambda ()
                             (when %rebuild-hook (%rebuild-hook)))))
              options)))
    (lambda ()
      (set! %rebuild-hook #f)
      (for-each (lambda (dispose) (catch #t (lambda () (dispose)) (lambda a #f)))
                subscriptions)
      #t)))
