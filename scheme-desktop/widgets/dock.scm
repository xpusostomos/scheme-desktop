;;; (scheme-desktop widgets dock) -- the dock: an icon for each running app
;;;
;;; PORTED FROM ags2-shell `widget/Dock/index.tsx' and
;;; `widget/Dock/components/DockItems.tsx'.  One window per monitor, along the
;;; bottom edge, holding one icon per running APPLICATION -- windows grouped by
;;; class, as ags2-shell's `create_dock_items' groups them -- with a dot under
;;; it for each window (up to three), lit when one of them has the focus.
;;;
;;;   primary click    focus the group's next window   (`focus_next')
;;;   secondary click  focus its first, toggle fullscreen
;;;   middle click     close every window in the group
;;;
;;; WHAT IS PORTED AND WHAT IS NOT YET, so nobody has to diff to find out:
;;;
;;;   ported   the running groups, their icons (through the app each window
;;;            belongs to -- `match_client_app'), the dots and their focus, the
;;;            three clicks, the tooltip, the scale that shrinks the dock to fit
;;;            the monitor, static mode (an exclusive zone), hidden when empty.
;;;   not yet  favourites (pinned apps, launched by a click), the trash, the
;;;            left-edge dock, autohide with its hot zones, hiding under a
;;;            fullscreen window.  Each is a separate piece of ags2-shell's file
;;;            and can land on its own.
;;;
;;; THE WINDOW MANAGER IS `(scheme-desktop wm)', never Hyprland directly: the
;;; clients, the focused one, and the three actions are all its generics, so the
;;; dock knows nothing about the compositor -- the same rule the overview keeps.

(define-module (scheme-desktop widgets dock)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit services apps)
  #:use-module (scheme-desktop wm)
  #:use-module (scheme-desktop widgets theme)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  ;; `string-null?'.  Not core Guile's -- the same trap as `let-values' in the
  ;; power menu, which stopped the shell starting.
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:export (<dock-desktop-widget> build-dock!))

(define-gi-imports "Gtk" "Box" "Button" "Image" "GestureClick")

;;; ---------------------------------------------------------------------------
;;; The widget
;;; ---------------------------------------------------------------------------

(define-class <dock-desktop-widget> (<edge-widget>)
  ;; ags2-shell's `options.dock.scale', which is a PERCENTAGE there (100) and a
  ;; ratio here (1.0), as every scale in this shell is.  It is a REQUEST: a dock
  ;; with more apps than fit is shrunk below it -- see `dock-scale'.
  (scale #:init-value 1.0 #:init-keyword #:scale
         #:accessor dock-requested-scale
         #:config '(number 0.3 3.0)
         #:label "Dock size")
  ;; ONE WINDOW PER MONITOR, keyed by its output, and the box in each that the
  ;; icons go in.  The same arrangement as the bar's, for the same reason: these
  ;; lists are the only record of the windows, so `widget-windows' answers from
  ;; them and the verbs move every monitor's dock together.
  (windows #:init-value '() #:accessor dock-windows #:setter dock-windows-set!))

(define-method (widget-windows (w <dock-desktop-widget>))
  (map (lambda (entry) (list-ref entry 1)) (dock-windows w)))

;; FORGOTTEN WHEN DESTROYED, for the bar's reason: a list of destroyed windows
;; is a list of dead GObjects, and the first thing to walk it after a rebuild
;; touches one.
(define-method (widget-destroy-windows! (w <dock-desktop-widget>))
  (let ((wins (widget-windows w)))
    (for-each (lambda (win) (catch #t (lambda () (destroy win)) (lambda args #f))) wins)
    (dock-windows-set! w '())
    (length wins)))

(define (dock) (desktop-widget-required 'dock))

;;; ---------------------------------------------------------------------------
;;; The items: running windows, grouped by application
;;; ---------------------------------------------------------------------------

(define (dock-clients)
  "The windows the dock shows, in workspace order.

ags2-shell's `create_window_client_list' sorts by workspace and drops what is
not a real window; a client with no class and no title is one of those (a
layer, a half-mapped window), and an icon for it would be an icon for nothing."
  (let ((clients (catch #t (lambda () (wm-clients (wm))) (lambda args '()))))
    (stable-sort
     (filter (lambda (c) (or (not (string-null? (wm-client-class c)))
                             (not (string-null? (wm-client-title c)))))
             clients)
     (lambda (a b) (< (or (wm-client-workspace a) 0) (or (wm-client-workspace b) 0))))))

(define (group-by-class clients)
  "CLIENTS as ((CLASS CLIENT ...) ...), groups in order of first appearance."
  (fold-right (lambda (c groups)
                (let* ((class (wm-client-class c))
                       (found (assoc class groups)))
                  (if found
                      (map (lambda (g) (if (eq? g found) (cons* class c (cdr g)) g))
                           groups)
                      (cons (list class c) groups))))
              '()
              clients))

(define (group-icon class clients apps)
  "The icon for a group: its application's, or the class itself.

ags2-shell's rule, including the part that is easy to miss: when the windows of
one class match DIFFERENT applications, the group gets no application at all --
one of the two icons would be wrong, and a wrong icon is worse than a generic
one.  The class is then the icon name, and `application-x-executable-symbolic'
is the last resort."
  (let* ((matches (map (lambda (c)
                         (app-for-window class #:title (wm-client-title c) #:apps apps))
                       clients))
         (first-app (car matches))
         (agreed (and first-app (every (lambda (m) (eq? m first-app)) matches)
                      first-app)))
    (or (and agreed (app-icon-name agreed))
        (and (not (string-null? class)) class)
        "application-x-executable-symbolic")))

(define (dock-items)
  "The dock's groups, as ((CLASS ICON CLIENT ...) ...)."
  (let ((apps (apps-catalog)))
    (map (lambda (group)
           (let ((class (car group)) (clients (cdr group)))
             (cons* class (group-icon class clients apps) clients)))
         (group-by-class (dock-clients)))))

;;; ---------------------------------------------------------------------------
;;; Sizes
;;; ---------------------------------------------------------------------------
;;
;; ags2-shell's arithmetic, number for number: a 64px icon and 11px of spacing
;; per item at scale 1, across 88% of the monitor, so a dock with too many apps
;; SHRINKS (never below 0.3) rather than running off the screen.

(define (ui-scale) (theme-scale (theme-widget)))

(define (dock-scale count monitor-width)
  (let ((requested (dock-requested-scale (dock))))
    (if (zero? count)
        requested
        (let* ((ui (ui-scale))
               (usable (- (* monitor-width 0.88) 2))
               (spacing (* count 11 ui))
               (icons (* count 64 ui))
               (fits (/ (- usable spacing) icons)))
          (max 0.3 (min requested fits))))))

(define (px x) (inexact->exact (round x)))

;;; ---------------------------------------------------------------------------
;;; One icon
;;; ---------------------------------------------------------------------------

(define (on-button! widget button proc)
  "Run PROC when mouse BUTTON is pressed on WIDGET.

ONE GESTURE PER BUTTON, as the overview does for its middle click: a GtkButton's
`clicked' is the primary button only, and a second controller is how the other
two are heard."
  (let ((gesture (make <gtk-gesture-click>)))
    (catch #t (lambda () (slot-set! gesture 'button button)) (lambda args #f))
    (connect-signal! gesture "pressed" (lambda (g n x y) (proc)))
    (add-controller widget gesture)))

(define (focus-next! clients)
  "Focus the window after the focused one in CLIENTS, or the first.

ags2-shell's `focus_next': clicking an app's icon again walks its windows."
  (let* ((focused (catch #t (lambda () (wm-focused-client (wm))) (lambda a #f)))
         (index (list-index (lambda (c) (equal? (wm-client-address c) focused)) clients))
         (next (if index (modulo (+ index 1) (length clients)) 0)))
    (wm-focus-client! (wm) (list-ref clients next))))

(define (group-icon-tree item icon-size)
  "One application: its button, and under it a dot per window (up to three)."
  (let* ((class (list-ref item 0))
         (icon (list-ref item 1))
         (clients (drop item 2))
         (focused (catch #t (lambda () (wm-focused-client (wm))) (lambda a #f)))
         (is-focused (any (lambda (c) (equal? (wm-client-address c) focused)) clients))
         ;; ags2-shell's tooltip: the title for one window, the count for more.
         (tooltip (if (= (length clients) 1)
                      (let ((t (wm-client-title (car clients))))
                        (if (string-null? t) class t))
                      (format #f "~a (~a windows)" class (length clients))))
         (button (element <gtk-button> #:class "app-button"
                          #:tooltip-text tooltip
                          #:can-focus #f
                          (element <gtk-image> #:icon-name icon
                                   #:use-fallback #t
                                   #:pixel-size icon-size))))
    (connect-signal! button "clicked" (lambda (b) (focus-next! clients)))
    (on-button! button 3 (lambda () (wm-fullscreen-client! (wm) (car clients))))
    (on-button! button 2 (lambda ()
                           (for-each (lambda (c) (wm-close-client! (wm) c)) clients)))
    (element <gtk-box> #:class "dock-icon dock-horizontal"
             #:orientation 'vertical #:halign 'center
      (this! button)
      ;; THE DOTS ARE POSITIONAL CHILDREN, APPLIED.  This said `#:children (map
      ;; ...)' first, which `element' does not have -- a comment in
      ;; (scheme-toolkit widget) lists it, the code does not -- so the keyword was
      ;; taken for a GTK property, dropped without a word, and every dock icon had
      ;; an empty dot box under it.  Found by counting the box's children in the
      ;; running shell: 0.
      (apply element <gtk-box> #:class "window-dots" #:orientation 'horizontal
             #:halign 'center #:valign 'center
             (map (lambda (i)
                    (element <gtk-box>
                             #:class (if is-focused "window-dot focused" "window-dot")
                             #:halign 'center #:valign 'center))
                  (iota (min (length clients) 3)))))))

;;; ---------------------------------------------------------------------------
;;; One monitor's dock
;;; ---------------------------------------------------------------------------

(define (render-dock! win box monitor items)
  "Put ITEMS in BOX, size it for MONITOR, and show WIN only when there are any.

HIDDEN WHEN EMPTY, as ags2-shell's is (`dock_items().length > 0'): an empty dock
is a bar of nothing with an exclusive zone, taking screen for no reason."
  (let* ((width (list-ref (monitor-geometry monitor) 2))
         (scale (dock-scale (length items) width))
         (pixel-scale (* scale (ui-scale)))
         (icon-size (max 16 (px (* 64 pixel-scale))))
         (thickness (max 48 (px (* 94 scale (ui-scale))))))
    (clear-box! box)
    (for-each (lambda (item) (add-child! box (group-icon-tree item icon-size) #f)) items)
    (catch #t (lambda () (slot-set! box 'margin-bottom (px (* 16 pixel-scale))))
           (lambda a #f))
    (catch #t (lambda () (slot-set! win 'height-request thickness)) (lambda a #f))
    (catch #t (lambda () (slot-set! win 'visible (pair? items))) (lambda a #f))))

(define (items-signature items focused)
  "What decides whether the dock must be redrawn.

ags2-shell keeps the previous items and reuses any that did not change, for the
same reason: the compositor reports EVERY change -- a title, a move, a focus
anywhere -- and rebuilding the icons on each is a dock that flickers while you
type.  So the dock is redrawn only when this changes."
  (cons focused
        (map (lambda (item)
               (cons* (list-ref item 0) (list-ref item 1)
                      (map wm-client-address (drop item 2))))
             items)))

(define* (build-dock! monitor #:key (name "dock-bottom"))
  "Build MONITOR's dock and keep it current.  Called once per monitor, inside the
root `for-each-monitor' makes, so the monitor leaving disposes it."
  (let* ((model (dock))
         (output (monitor-name monitor))
         (box (element <gtk-box> #:class "dock-container dock-horizontal"
                       #:orientation 'horizontal #:halign 'center #:valign 'end))
         (win (layer-window name
                            #:anchor '(bottom left right)
                            ;; STATIC MODE, ags2-shell's default: the dock takes
                            ;; its strip of the screen, as the bar does.
                            #:exclusivity 'exclusive
                            #:layer 'top
                            #:keymode 'none
                            #:gdkmonitor monitor
                            #:class "dock"
                            #:visible #f
                            box))
         (last #f))
    (define (refresh!)
      (let* ((items (dock-items))
             (focused (catch #t (lambda () (wm-focused-client (wm))) (lambda a #f)))
             (signature (items-signature items focused)))
        (unless (equal? signature last)
          (set! last signature)
          (catch #t
            (lambda () (render-dock! win box monitor items))
            (lambda (key . rest)
              (format (current-error-port) "scheme-desktop: dock: ~a ~s~%" key rest))))))
    (dock-windows-set! model (cons (list output win box)
                                   (remove (lambda (e) (equal? (car e) output))
                                           (dock-windows model))))
    (refresh!)
    ;; THE COMPOSITOR SAYS WHEN ANYTHING CHANGED, and the signature above decides
    ;; whether it changed for the dock.  The disconnect is registered with the
    ;; monitor's root, so an unplugged monitor stops being redrawn.
    (let ((stop (wm-on-change (wm) refresh!)))
      (on-cleanup (lambda ()
                    (catch #t stop (lambda a #f))
                    (catch #t (lambda () (destroy win)) (lambda a #f))
                    (dock-windows-set! model (remove (lambda (e) (equal? (car e) output))
                                                     (dock-windows model))))))
    win))
