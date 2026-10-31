;;; (scheme-desktop widgets overview) -- the workspace switcher
;;;
;;; PORTED FROM ags2-shell's `Overview.Window' (`widget/Bar/components/Overview/
;;; index.tsx').  A row of workspace tiles, one per workspace number, each sized
;;; to the monitor it belongs to, with a rectangle for every window on it placed
;;; where that window actually is and sized the way it actually is.
;;;
;;; THE RECTANGLES ARE NOT SCREENSHOTS. They are buttons at the window's real
;;; geometry showing the application's icon, which is what the reference does:
;;; its `Client' renders a `Gtk.Image' with `iconName={client.get_class()}', and
;;; the `Gdk.ContentProvider' in the same component is for DRAG AND DROP, not
;;; for drawing. Worth knowing before assuming this needs window capture.
;;;
;;; CLICKING A TILE switches to that workspace and closes. Clicking a WINDOW, or
;;; selecting one with the arrows and pressing Space or Return, goes to that
;;; window and closes -- the reference only clicks, and a switcher you cannot
;;; drive from the keyboard is the thing a keyboard-driven menu exists to avoid.
;;;
;;; NO COMPOSITOR IS NAMED HERE either: monitors, workspaces and windows all
;;; come from `(scheme-desktop wm)' as plain records.
;;;
;;; IT IS A TOP-LEVEL WIDGET, NOT A PART OF THE BAR'S WORKSPACE PILL.  That is
;;; the point of it: a window picker belongs on a keybinding -- alt-tab, or a
;;; workspace key -- and binding one must not mean reaching through the bar.
;;; The pill's click calls `(toggle-widget 'overview)' like any other caller,
;;; and this module never learns that the bar exists.
;;;
;;; Dragging a window onto another tile is the one part of the reference not
;;; ported: it needs Gtk.DragSource/DropTarget with a content provider, and it
;;; is a separate piece of work from the switcher being usable.

(define-module (scheme-desktop widgets overview)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit config)
  #:use-module (scheme-desktop config)
  #:use-module (scheme-desktop wm)
  ;; For `workspaces-count', the option this switcher shares with the workspace
  ;; numbers in the bar.  No cycle: that module does not import this one -- it
  ;; opens this picker with `(toggle-widget 'overview)'.
  #:use-module (scheme-desktop widgets bar workspaces)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)

  #:duplicates (merge-generics replace warn-override-core warn last)
  #:export (<overview-desktop-widget>))

(define-gi-imports "Gtk" "Box" "Button" "Image" "Fixed" "Label"
                   "EventControllerKey" "GestureClick")

(define (px n)
  "N as an exact integer.

`round' returns a FLOAT in Guile when handed one, and every one of these ends up
as a GTK property that wants an exact integer:

  ERROR: Wrong type (expecting exact integer): 45.0

It bit the icon size first, because that is the one the failure names -- the
other sizes go into a CSS string, where 173.0px is merely wrong-looking."
  (inexact->exact (round n)))

;; The tiles are the real monitors shrunk by this. 9% is ags2-shell's factor for
;; a scale setting above 15, which is the default path its own `scale_factor'
;; takes -- the /100 branch is for values used as a percentage.
(define %tile-scale 0.09)

;; ASKED OF THE WIDGET THAT OWNS IT.  The count is the workspace bar item's
;; option, and this switcher shows the same workspaces -- so there is one
;; declaration and one place to change it, rather than two that drift.
;;
;; The registry lookup falls back to the default rather than failing: a shell
;; that leaves the workspace numbers out of its bar still has a workspace
;; picker, and it must not die for want of a widget it does not use.
(define %default-count 7)

(define (workspace-count)
  (let ((w (desktop-widget-named 'workspaces)))
    (if w (workspaces-count w) %default-count)))

;;; ---------------------------------------------------------------------------
;;; The widget
;;; ---------------------------------------------------------------------------
;;
;; EVERYTHING THAT WAS A MODULE-LEVEL VARIABLE IS A SLOT.  This is a single
;; window per shell, so the two are equivalent in effect -- but a slot says so,
;; and it means a second overview (on a second shell, or in a test) cannot
;; collide with this one's selection.

(define-class <overview-desktop-widget> (<popup-widget>)
  (window     #:init-value #f #:accessor overview-window
              #:setter overview-window-set!)
  (tiles      #:init-value #f #:accessor overview-tiles
              #:setter overview-tiles-set!)
  (tiles-root #:init-value #f #:accessor overview-tiles-root
              #:setter overview-tiles-root-set!)
  ;; (button . client), in display order.
  (selection  #:init-value '() #:accessor overview-selection
              #:setter overview-selection-set!)
  ;; An index into `selection'.
  (selected   #:init-value 0  #:accessor overview-selected
              #:setter overview-selected-set!))

;;; ---------------------------------------------------------------------------
;;; What a tile is drawn from
;;; ---------------------------------------------------------------------------

(define (workspace-monitor id)
  "The monitor workspace ID belongs to, or #f if ID does not exist.

ASK THE WORKSPACE, do not search the monitors for it. A monitor names only its
ACTIVE workspace -- the one on screen -- and every other workspace it holds is
invisible to that search, so the lookup failed for them and fell through to
whatever monitor came first. That is why workspace 3, which lives on the small
screen, was drawn the size of the big one."
  (let ((ws (wm-workspace-by-id (wm) id)))
    (and ws (wm-monitor-by-name (wm) (wm-workspace-monitor ws)))))

(define (workspace-size id)
  "The size of the monitor workspace ID is on, in logical pixels.

Falls back to the focused monitor, which is where a workspace that does not
exist yet will be created when somebody switches to it."
  (let ((mon (or (workspace-monitor id)
                 (let ((focused (wm-focused-workspaces (wm))))
                   (and (pair? focused) (wm-monitor-by-name (wm) (caar focused)))))))
    (if mon
        (list (/ (wm-monitor-width mon) (wm-monitor-scale mon))
              (/ (wm-monitor-height mon) (wm-monitor-scale mon)))
        (list 1920 1080))))

;; A workspace that does not exist has no monitor to name, and naming one -- the
;; focused monitor, say -- labels the tile with a monitor the workspace is not
;; on. Better to say nothing than to say the wrong screen.
(define (workspace-monitor-name id)
  (let ((mon (workspace-monitor id))) (and mon (wm-monitor-name mon))))

;;; ---------------------------------------------------------------------------
;;; Selecting a window
;;; ---------------------------------------------------------------------------
;;
;; Arrows move a selection across every window on show, in tile order, and Space
;; or Return goes to the selected one and closes.

(define (select! w i)
  (let ((selection (overview-selection w)))
    (when (pair? selection)
      (overview-selected-set! w (modulo i (length selection)))
      (let ((pair (list-ref selection (overview-selected w))))
        (for-each (lambda (other)
                    (catch #t
                      (lambda () (toggle-class! (car other) "selected" (eq? other pair)))
                      (lambda args #f)))
                  selection)))))

(define (move-selection! w delta) (select! w (+ (overview-selected w) delta)))

(define (selected-client w)
  (let ((selection (overview-selection w)))
    (and (pair? selection) (cdr (list-ref selection (overview-selected w))))))

;;; ---------------------------------------------------------------------------
;;; Drawing
;;; ---------------------------------------------------------------------------

(define (client-widget w client)
  "One window: a rectangle where the window is, showing its application's icon."
  (let* ((origin (let ((mon (wm-monitor-by-name (wm) (wm-client-monitor client))))
                   (cons (if mon (wm-monitor-x mon) 0)
                         (if mon (wm-monitor-y mon) 0))))
         ;; CLIENT x AND y ARE ABSOLUTE, spanning the whole desktop -- a window
         ;; on the second monitor has x around 3236, not 0 -- so placing one in
         ;; a tile means subtracting where its monitor starts. Skipping that put
         ;; the rectangles in the bottom-right of their tiles and, because a
         ;; Gtk.Fixed sizes itself to the bounding box of its children,
         ;; STRETCHED those tiles to fit: three different tile widths on a
         ;; two-monitor machine, and every window looking like it filled less of
         ;; its monitor than it did.
         (rx (px (max 0 (* (- (wm-client-x client) (car origin)) %tile-scale))))
         (ry (px (max 0 (* (- (wm-client-y client) (cdr origin)) %tile-scale))))
         (tw (max 12 (px (* (wm-client-width client) %tile-scale))))
         (th (max 12 (px (* (wm-client-height client) %tile-scale))))
         (class (wm-client-class client))
         ;; THE ICON SCALES WITH THE RECTANGLE. ags2-shell draws every icon at
         ;; one fixed size, which makes a full-screen window look like a
         ;; full-screen window with a postage stamp in it. A fraction of the
         ;; SHORTER side, so a wide short window does not get an icon taller
         ;; than itself, and clamped so a tiny one is still recognisable.
         (icon-size (max 16 (min 96 (px (* (min tw th) 0.55)))))
         (btn (element <gtk-button>
                       #:class "client"
                       #:tooltip-text (wm-client-title client)
                       #:css (format #f "min-width: ~apx; min-height: ~apx;" tw th)
                       (element <gtk-image>
                                #:icon-name (if (string=? class "")
                                                "application-x-executable-symbolic"
                                                class)
                                #:use-fallback #t
                                #:pixel-size icon-size
                                #:halign 'center #:valign 'center))))
    ;; A click goes there and closes, the same as Space or Return.
    (connect-signal! btn "clicked"
                     (lambda (b) (wm-focus-client! (wm) client) (close-overview! w)))
    ;; Middle click closes, as ags2-shell's GestureClick does. A SECOND
    ;; controller on the same widget: `clicked' is the primary button's signal
    ;; and cannot see the middle one.
    (let ((gesture (make <gtk-gesture-click>)))
      (catch #t (lambda () (slot-set! gesture 'button 2)) (lambda args #f))
      (connect-signal! gesture "pressed" (lambda (c n gx gy) (wm-close-client! (wm) client)))
      (add-controller btn gesture))
    (cons (cons rx ry) btn)))

(define (workspace-tile w id)
  "One workspace: a tile the shape of its monitor, holding its windows.

The tile is a COLUMN -- the picture, then the name of the monitor it belongs to.
Which screen a workspace is on is not otherwise visible, and with two monitors of
different sizes the tile's own shape is a hint rather than an answer."
  (let* ((size (workspace-size id))
         (w-px (px (* (list-ref size 0) %tile-scale)))
         (h-px (px (* (list-ref size 1) %tile-scale)))
         (fixed (element <gtk-fixed> #:hexpand #t #:vexpand #t))
         (btn (element <gtk-button>
                       #:name (number->string id)
                       #:class "workspace"
                       #:tooltip-text (number->string id)
                       #:css (format #f "min-width: ~apx; min-height: ~apx;" w-px h-px)
                       #:valign 'center
                       fixed))
         (column (element <gtk-box> #:orientation 'vertical #:class "workspace-cell"
                          btn
                          (element <gtk-label>
                                   #:class "workspace-caption"
                                   #:label (or (workspace-monitor-name id) "")
                                   #:justify 'center))))
    ;; `gtk_fixed_put', not `add-child!': a Gtk.Fixed has no `child' property,
    ;; because putting a child in it IS choosing its coordinates. So this is the
    ;; one container the element runtime cannot insert into, and it is used
    ;; directly rather than given an add-child! method with nowhere to get x and
    ;; y from.
    (for-each
     (lambda (entry)
       (let ((pos (car entry)) (widget (cdr entry)))
         (catch #t
           (lambda ()
             (gtk-fixed-put fixed widget (car pos) (cdr pos))
             ;; Collected here rather than by walking the tree afterwards: the
             ;; display order IS the selection order, and this is where it is
             ;; known.
             (overview-selection-set! w (cons entry (overview-selection w))))
           (lambda (key . args)
             (format (current-error-port)
                     "scheme-desktop: overview: cannot place a window: ~a ~s~%"
                     key args)))))
     (map (lambda (client) (client-widget w client)) (wm-clients-on (wm) id)))
    ;; Choosing a workspace CLOSES the picker, the same as choosing a window.
    (connect-signal! btn "clicked"
                     (lambda (b) (wm-focus-workspace! (wm) id) (close-overview! w)))
    column))

;;; ---------------------------------------------------------------------------
;;; The window
;;; ---------------------------------------------------------------------------

(define (close-overview! w)
  (let ((win (overview-window w)))
    (when win
      (catch #t (lambda () (gtk-widget-set-visible win #f)) (lambda args #f)))))

(define (render! w)
  "Rebuild every tile, and the selection with them."
  (overview-selection-set! w '())
  (clear-box! (overview-tiles w))
  (for-each (lambda (id) (add-child! (overview-tiles w) (workspace-tile w id) #f))
            (iota (workspace-count) 1))
  ;; `workspace-tile' PREPENDS as it builds, so the order is reversed here.
  (overview-selection-set! w (reverse (overview-selection w)))
  ;; The selection starts on the first window, so Space or Return does something
  ;; sensible before anything has been pressed.
  (select! w 0))

(define (on-key w keyval)
  (case keyval
    ((65361 65362) (move-selection! w -1) #t)   ; Left / Up
    ((65363 65364) (move-selection! w 1) #t)    ; Right / Down
    ((32 65293 65421)                           ; Space / Return / KP_Enter
     (let ((client (selected-client w)))
       (when client (wm-focus-client! (wm) client))
       (close-overview! w)
       #t))
    ((65307) (close-overview! w) #t)            ; Escape
    (else #f)))

;; The tiles get their own scope, disposed before the next render: they are
;; rebuilt on every render, and each one connects click handlers.
(define (refresh-tiles! w)
  (let ((root (overview-tiles-root w)))
    (when root (catch #t root (lambda args #f))))
  (overview-tiles-root-set! w #f)
  (overview-tiles-root-set! w (create-root (lambda (dispose) (render! w)))))

(define-method (widget-window (w <overview-desktop-widget>))
  "The workspace switcher, built once and registered under the name `overview'.

Registered at startup like every other widget, so `toggle-widget' finds it -- a
lazily-created one is something `widget-toggle!' cannot find, which is how the
menu button once came to do nothing."
  (unless (overview-window w)
    (let ((tiles (element <gtk-box> #:orientation 'horizontal #:class "overview")))
      (overview-tiles-set! w tiles)
      (let ((win (popup-window "overview"
                               #:position 'center
                               #:layer 'overlay
                               ;; It takes the keyboard, because the arrows and
                               ;; Space are half of how it is meant to be used.
                               #:keymode 'exclusive
                               tiles)))
        (overview-window-set! w win)
        (let ((keys (make <gtk-event-controller-key>)))
          (connect-signal! keys "key-pressed"
                           (lambda (c keyval keycode modifiers) (on-key w keyval)))
          (add-controller win keys))
        ;; Redrawn whenever it is shown, and again on every compositor event
        ;; while it is up: a switcher showing where the windows were when it
        ;; opened is worse than useless, because you would trust it.
        (connect-signal! win "notify::visible"
                         (lambda args
                           (when (window-visible? win) (refresh-tiles! w))))
        (wm-on-change (wm) (lambda ()
                             (when (window-visible? win) (refresh-tiles! w)))))))
  (overview-window w))
