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
  ;; `timeout', for a launcher's quarter-second `launching' class.
  #:use-module (scheme-toolkit time)
  #:use-module (scheme-desktop wm)
  #:use-module (scheme-desktop widgets theme)
  ;; The trash at the end of the dock: whether it is full, and opening it.
  #:use-module (scheme-desktop widgets dock trash)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  ;; `string-null?'.  Not core Guile's -- the same trap as `let-values' in the
  ;; power menu, which stopped the shell starting.
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:export (<dock-desktop-widget> build-dock!))

(define-gi-imports "Gtk" "Box" "Button" "Image" "GestureClick" "Separator"
  "EventControllerMotion")

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
  ;; THE TRASH AT THE END OF THE DOCK, after a separator -- ags2-shell's
  ;; `options.dock.trash', on by default as it is there.  Turned off, the icon
  ;; goes and so does the watch on the trash: nothing looks at the trash that
  ;; nothing shows.
;; THE PINNED APPLICATIONS, as desktop entries -- "firefox.desktop", or
  ;; "firefox", or the name a person reads, "Firefox" -- first in the dock,
  ;; in this order.  A pinned app that is running holds its windows in its own
  ;; place; one that is not is a launcher.
  ;;
  ;; ags2-shell reads these from GNOME's `/org/gnome/shell/favorite-apps' --
  ;; through `dconf', watched -- and on a desktop that is not GNOME that key is
  ;; empty, as it is on the machine this was written on.  So here they are a
  ;; dock option, in config.scm with every other setting.
  (favorites #:init-value '() #:init-keyword #:favorites
             #:accessor dock-favorites
             #:config '(list)
             #:label "Pinned applications"
             #:apply (lambda (w names) (dock-options-changed! w)))
  ;; STATIC OR AUTOHIDE -- ags2-shell's `options.dock.mode', static by default.
  ;; Static takes its strip of the screen, as the bar does.  Autohide takes none:
  ;; the dock appears when the pointer reaches a thin strip along the bottom edge,
  ;; and goes again a quarter second after the pointer has left both.
;; WHICH EDGE -- ags2-shell's `options.dock.position': `bottom-center', its
  ;; default, or `center-left', a column down the left side.  Changed live: the
  ;; windows are re-anchored and the icons redrawn, and nothing is rebuilt.
  (position #:init-value 'bottom #:init-keyword #:position
            #:accessor dock-position
            #:config '(choice bottom left)
            #:label "Dock edge"
            #:apply (lambda (w side) (dock-options-changed! w)))
  (mode #:init-value 'static #:init-keyword #:mode
        #:accessor dock-mode
        #:config '(choice static autohide)
        #:label "Dock behaviour"
        #:apply (lambda (w mode) (dock-options-changed! w)))
  (trash-enabled #:init-value #t #:init-keyword #:trash-enabled
                 #:accessor dock-trash-enabled
                 #:config '(boolean)
                 #:label "Show the trash in the dock"
                 #:apply (lambda (w on) (dock-options-changed! w)))
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
;;
;; AND THE HOT ZONES WITH THEM.  They are not in `widget-windows' -- showing the
;; dock must not show the strip, which follows its own rule -- so they are
;; destroyed here by name, from the entry that keeps them.
(define-method (widget-destroy-windows! (w <dock-desktop-widget>))
  (let ((wins (append (widget-windows w)
                      (filter-map (lambda (e) (and (> (length e) 4) (list-ref e 4)))
                                  (dock-windows w)))))
    (for-each (lambda (win) (catch #t (lambda () (destroy win)) (lambda args #f))) wins)
    (dock-windows-set! w '())
    (length wins)))

(define (dock) (desktop-widget-required <dock-desktop-widget>))

;;; ---------------------------------------------------------------------------
;;; The trash's watch, following the option
;;; ---------------------------------------------------------------------------

;; THE RELEASE PROCEDURE, while this shell's docks watch the trash, or #f.  ONE
;; for the dock widget rather than one per monitor: every monitor's dock shows
;; the same trash.
(define %release-trash #f)

(define (sync-trash-watcher! w)
  "Watch the trash when the option says to show it, and not otherwise."
  (cond ((and (dock-trash-enabled w) (not %release-trash))
         (set! %release-trash (acquire-trash-watcher!)))
        ((and (not (dock-trash-enabled w)) %release-trash)
         (%release-trash)
         (set! %release-trash #f))))

(define (dock-options-changed! w)
  "A dock option changed -- the trash, the pinned apps: start or stop the trash's
watch to match, and redraw every monitor's dock."
  (sync-trash-watcher! w)
  ;; EACH MONITOR'S REDRAW IN ITS OWN ROOT, for the bar's reason: this runs from
  ;; a config watcher, where no scope is current, so a rebuilt tree's cleanups
  ;; would be registered nowhere.
  (for-each (lambda (entry)
              (when (> (length entry) 3)
                (catch #t
                       (lambda ()
                         (in-monitor-scope (car entry) (lambda () ((list-ref entry 3)))))
                       (lambda a #f))))
            (dock-windows w)))

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

(define (group-app class clients apps)
  "The application a group's windows belong to, or #f -- #f, too, when they do
not agree (see `group-icon')."
  (let* ((matches (map (lambda (c)
                         (app-for-window class #:title (wm-client-title c) #:apps apps))
                       clients))
         (first-app (car matches)))
    (and first-app (every (lambda (m) (eq? m first-app)) matches) first-app)))

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
  "The dock's items, in order: a running group is (CLASS ICON CLIENT ...), a
pinned application that is not running is (favorite APP).

ags2-shell's `create_dock_items', in its order.  The PINNED apps first, each in
its place: a running one holds its windows there -- the group moves to the pinned
slot rather than appearing twice -- and one with no windows is a launcher.  Then
every running group no pinned app claimed, in workspace order."
  (let* ((apps (apps-catalog))
         (groups (map (lambda (g)
                        (list (car g) (group-app (car g) (cdr g) apps) (cdr g)))
                      (group-by-class (dock-clients))))
         (group-item (lambda (g)
                       (let ((class (list-ref g 0)) (app (list-ref g 1)) (clients (list-ref g 2)))
                         (cons* class
                                (or (and app (app-icon-name app))
                                    (and (not (string-null? class)) class)
                                    "application-x-executable-symbolic")
                                clients))))
         (pinned (apps-named (dock-favorites (dock)) #:apps apps))
         (claimed? (lambda (g) (any (lambda (f) (same-app? (list-ref g 1) f)) pinned))))
    (append
     (map (lambda (f)
            (let ((g (find (lambda (g) (same-app? (list-ref g 1) f)) groups)))
              (if g (group-item g) (list 'favorite f))))
          pinned)
     (map group-item (remove claimed? groups)))))

(define (favorite? item) (eq? (car item) 'favorite))

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

;; ONE ICON'S BOX, BOTH WAYS ROUND -- ags2-shell's `DockIconBox'.  Along the
;; bottom an icon is a column, its dots under it; down the left side it is a row,
;; its dots beside it, on the side towards the edge.  Written once so the two
;; layouts cannot drift.
(define (side-class side) (if (eq? side 'left) "dock-vertical" "dock-horizontal"))

(define (icon-box side . children)
  (apply element <gtk-box>
         #:class (string-append "dock-icon " (side-class side))
         #:orientation (if (eq? side 'left) 'horizontal 'vertical)
         #:halign 'center
         children))

(define (group-icon-tree item icon-size side)
  "One application: its button, and a dot per window (up to three) -- under it
along the bottom, beside it down the left."
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
    (let ((dots
      ;; THE DOTS ARE POSITIONAL CHILDREN, APPLIED.  This said `#:children (map
      ;; ...)' first, which `element' does not have -- a comment in
      ;; (scheme-toolkit widget) lists it, the code does not -- so the keyword was
      ;; taken for a GTK property, dropped without a word, and every dock icon had
      ;; an empty dot box under it.  Found by counting the box's children in the
      ;; running shell: 0.
      (apply element <gtk-box> #:class "window-dots"
             #:orientation (if (eq? side 'left) 'vertical 'horizontal)
             #:halign 'center #:valign 'center
             (map (lambda (i)
                    (element <gtk-box>
                             #:class (if is-focused "window-dot focused" "window-dot")
                             #:halign 'center #:valign 'center))
                  (iota (min (length clients) 3))))))
      (if (eq? side 'left)
          (icon-box side dots (this! button))
          (icon-box side (this! button) dots)))))

;;; ---------------------------------------------------------------------------
;;; One monitor's dock
;;; ---------------------------------------------------------------------------

(define (favorite-tree item icon-size side)
  "A pinned application with no windows: its icon, starting it on a click.

ags2-shell's `FavoriteIcon', including its `launching' class for a quarter of a
second -- the bounce that says the click was heard, before the window exists."
  (let* ((app (cadr item))
         (button (element <gtk-button> #:class "app-button"
                          #:tooltip-text (or (app-name app) "")
                          #:can-focus #f
                          (element <gtk-image>
                                   #:icon-name (or (app-icon-name app)
                                                   "application-x-executable-symbolic")
                                   #:use-fallback #t #:pixel-size icon-size))))
    (connect-signal! button "clicked"
                     (lambda (b)
                       (toggle-class! button "launching" #t)
                       (app-launch! app)
                       (timeout 250 (lambda () (toggle-class! button "launching" #f)))))
    (icon-box side (this! button))))

(define (trash-tree icon-size side)
  "The trash: full or empty, opening it on a click.  ags2-shell's `TrashIcon'."
  (let ((full (trash-has-items)))
    (icon-box side
      (element <gtk-button> #:class "app-button" #:tooltip-text "Trash"
               #:can-focus #f
               #:on-clicked (lambda (b) (open-trash!))
        (element <gtk-image> #:icon-name (trash-icon-name full)
                 #:use-fallback #t #:pixel-size icon-size
                 #:halign 'center #:valign 'center)))))

(define (render-dock! win box monitor items trash? side)
  "Put ITEMS -- and the trash, when TRASH? -- in BOX, size it for MONITOR, and
show WIN only when there is something in it.

Answers (COUNT PIXEL-SCALE): how many things it drew -- the trash counts, so a
dock with the trash on is never empty -- and the scale it drew them at.

THE SEPARATOR IS ONLY BETWEEN THINGS: with no apps running there is nothing for
it to separate the trash from, and ags2-shell leaves it out then too."
  (let* ((geometry (monitor-geometry monitor))
         ;; THE LENGTH THE DOCK RUNS ALONG: the monitor's width along the
         ;; bottom, its height down the side -- ags2-shell's `monitor_length'.
         (length-along (list-ref geometry (if (eq? side 'left) 3 2)))
         (count (+ (length items) (if trash? 1 0)))
         (scale (dock-scale count length-along))
         (pixel-scale (* scale (ui-scale)))
         (icon-size (max 16 (px (* 64 pixel-scale))))
         (thickness (max 48 (px (* 94 scale (ui-scale))))))
    (clear-box! box)
    (for-each (lambda (item)
                (add-child! box (if (favorite? item)
                                    (favorite-tree item icon-size side)
                                    (group-icon-tree item icon-size side))
                            #f))
              items)
    (when trash?
      (when (pair? items)
        ;; ACROSS THE DOCK, whichever way it runs: upright along the bottom,
        ;; flat down the side.
        (add-child! box (if (eq? side 'left)
                            (element <gtk-separator> #:class "dock-separator"
                                     #:orientation 'horizontal #:halign 'center
                                     #:width-request icon-size)
                            (element <gtk-separator> #:class "dock-separator"
                                     #:orientation 'vertical #:valign 'center
                                     #:height-request icon-size))
                    #f))
      (add-child! box (trash-tree icon-size side) #f))
    ;; THE GAP TO THE EDGE, and the window's thickness, on the axis across the
    ;; dock -- and the other axis put back, so switching edges leaves nothing of
    ;; the last one behind.
    (catch #t
      (lambda ()
        (let ((gap (px (* 16 pixel-scale))))
          (slot-set! box 'margin-bottom (if (eq? side 'left) 0 gap))
          (slot-set! box 'margin-start (if (eq? side 'left) gap 0)))
        (slot-set! win 'height-request (if (eq? side 'left) -1 thickness))
        (slot-set! win 'width-request (if (eq? side 'left) thickness -1)))
      (lambda a #f))
    ;; WHETHER IT IS SHOWN IS NOT DECIDED HERE: that depends on the mode, the
    ;; pointer and fullscreen windows as well -- see `build-dock!'.  What this
    ;; answers is what that needs: whether there is anything, and how big.
    (list count pixel-scale)))

(define (items-signature items focused trash side)
  "What decides whether the dock must be redrawn -- TRASH is #f when it is off,
and 'full or 'empty when it is on.

ags2-shell keeps the previous items and reuses any that did not change, for the
same reason: the compositor reports EVERY change -- a title, a move, a focus
anywhere -- and rebuilding the icons on each is a dock that flickers while you
type.  So the dock is redrawn only when this changes."
  (cons* side focused trash
        (map (lambda (item)
               (if (favorite? item)
                   (list 'favorite (app-entry (cadr item)))
                   (cons* (list-ref item 0) (list-ref item 1)
                          (map wm-client-address (drop item 2)))))
             items)))

(define* (build-dock! monitor #:key (name "dock"))
  "Build MONITOR's dock and keep it current.  Called once per monitor, inside the
root `for-each-monitor' makes, so the monitor leaving disposes it.

TWO WINDOWS: the dock, and -- in autohide mode -- the strip along the bottom edge
that the pointer reaches to bring it up.  ags2-shell's `Hotzone' and
`DockSurface'.

WHEN IT IS SHOWN, ags2-shell's rule: there must be something in it, no window on
this monitor may be fullscreen, and it is either static or being hovered.  The
strip is shown exactly when an autohide dock could be."
  (let* ((model (dock))
         (output (monitor-name monitor))
         (box (element <gtk-box> #:class "dock-container dock-horizontal"
                       #:orientation 'horizontal #:halign 'center #:valign 'end))
         (side-now #f)
         (win (layer-window name
                            #:anchor '(bottom left right)
                            #:exclusivity 'exclusive
                            #:layer 'top
                            #:keymode 'none
                            #:gdkmonitor monitor
                            #:class "dock"
                            #:visible #f
                            box))
         ;; THE HOT ZONE: an invisible strip, which must still be HIT by the
         ;; pointer -- a fully transparent surface is input-transparent on some
         ;; compositors, which is why ags2-shell paints it 1% black and so does
         ;; this.
         (zone (layer-window (string-append name "-hotzone")
                             #:anchor '(bottom left right)
                             #:exclusivity 'ignore
                             #:layer 'top
                             #:keymode 'none
                             #:gdkmonitor monitor
                             #:class "dock-hotzone"
                             #:visible #f
                             (element <gtk-box> #:class "dock-hotzone"
                                      #:hexpand #t #:vexpand #t)))
         (last #f)
         (drawn '(0 1.0))
         (zones '())          ; the windows the pointer is in: 'dock, 'zone
         (hovered #f)
         (hiding #f))
    (define (apply-side! side)
      ;; RE-ANCHORED IN PLACE, when the option changes -- ags2-shell's
      ;; `side_config': the bottom edge, or the left edge top to bottom, with the
      ;; container turned to run along it.
      (unless (eq? side side-now)
        (set! side-now side)
        (catch #t
          (lambda ()
            (let ((anchor (if (eq? side 'left) '(left top bottom) '(bottom left right))))
              (slot-set! win 'anchor anchor)
              (slot-set! zone 'anchor anchor))
            (slot-set! box 'orientation (if (eq? side 'left) 'vertical 'horizontal))
            (slot-set! box 'halign (if (eq? side 'left) 'start 'center))
            (slot-set! box 'valign (if (eq? side 'left) 'center 'end))
            (toggle-class! box "dock-vertical" (eq? side 'left))
            (toggle-class! box "dock-horizontal" (not (eq? side 'left))))
          (lambda (key . rest)
            (format (current-error-port) "scheme-desktop: dock: ~a ~s~%" key rest)))))
    (define (apply-visibility!)
      ;; DECIDED ON EVERY REFRESH, not only when the icons change: a fullscreen
      ;; window or the pointer leaving changes it with the icons the same.
      (let* ((count (car drawn))
             (pixel-scale (cadr drawn))
             (autohide? (eq? (dock-mode model) 'autohide))
             (fullscreen? (catch #t (lambda () (wm-monitor-fullscreen? (wm) output))
                                 (lambda a #f)))
             (active? (and (> count 0) (not fullscreen?))))
        (catch #t
          (lambda ()
            (slot-set! win 'exclusivity (if (and active? (not autohide?)) 'exclusive 'ignore))
            (let ((thick (max 16 (px (* 22 pixel-scale))))
                  (left? (eq? side-now 'left)))
              (slot-set! zone 'height-request (if left? -1 thick))
              (slot-set! zone 'width-request (if left? thick -1)))
            (slot-set! zone 'visible (and active? autohide?))
            (slot-set! win 'visible (and active? (or (not autohide?) hovered))))
          (lambda (key . rest)
            (format (current-error-port) "scheme-desktop: dock: ~a ~s~%" key rest)))))
    (define (refresh!)
      (let* ((items (dock-items))
             (focused (catch #t (lambda () (wm-focused-client (wm))) (lambda a #f)))
             (trash? (dock-trash-enabled model))
             (side (dock-position model))
             (signature (items-signature items focused
                                         (and trash? (if (trash-has-items) 'full 'empty))
                                         side)))
        (apply-side! side)
        (unless (equal? signature last)
          (set! last signature)
          (catch #t
            (lambda () (set! drawn (render-dock! win box monitor items trash? side)))
            (lambda (key . rest)
              (format (current-error-port) "scheme-desktop: dock: ~a ~s~%" key rest))))
        (apply-visibility!)))
    ;; THE HOVER, ags2-shell's: entering either window shows the dock and cancels
    ;; a pending hide; leaving the last of them hides it 250ms later, so moving
    ;; from the strip up into the dock does not close it on the way.
    (define (enter! which)
      (set! zones (lset-adjoin eq? zones which))
      (set! hiding #f)
      (unless hovered (set! hovered #t) (apply-visibility!)))
    (define (leave! which)
      (set! zones (delete which zones))
      (when (null? zones)
        (let ((token (list 'hide)))
          (set! hiding token)
          (timeout 250 (lambda ()
                         (when (eq? hiding token)
                           (set! hiding #f)
                           (set! hovered #f)
                           (apply-visibility!)))))))
    (define (watch-hover! window which)
      (let ((motion (make <gtk-event-controller-motion>)))
        (connect-signal! motion "enter" (lambda (m x y) (enter! which)))
        (connect-signal! motion "leave" (lambda (m) (leave! which)))
        (add-controller window motion)))
    (watch-hover! win 'dock)
    (watch-hover! zone 'zone)
    ;; REFRESH! IS KEPT WITH THE WINDOW, so the options and the trash's own state
    ;; can redraw every monitor's dock without rebuilding any of them.  The hot
    ;; zone is kept too, so it is destroyed with the dock.
    (dock-windows-set! model (cons (list output win box refresh! zone)
                                   (remove (lambda (e) (equal? (car e) output))
                                           (dock-windows model))))
    (sync-trash-watcher! model)
    (refresh!)
    ;; THE TRASH FILLING OR EMPTYING REDRAWS THE DOCK.  An effect on its
    ;; accessor, in this monitor's root, so it ends with the dock.
    ;; AND THIS ONE: an effect runs in the root that created it, but `refresh!'
    ;; is called from inside it with the effect's own tracking -- harmless here,
    ;; and NOT the same thing as the effect being the scope.  Kept explicit.
    (create-effect (lambda () (trash-has-items) (in-monitor-scope output refresh!)))
    ;; THE COMPOSITOR SAYS WHEN ANYTHING CHANGED -- a window, the focus, a
    ;; fullscreen -- and `refresh!' decides what that means for the dock.  The
    ;; disconnect is registered with the monitor's root, so an unplugged monitor
    ;; stops being redrawn.
    ;; THE COMPOSITOR'S CALLBACK RUNS OUTSIDE ANY SCOPE.  `wm-on-change' is a
    ;; GObject signal, so nothing parameterized is in force when it fires --
    ;; and `refresh!' builds trees that register timers and handlers, which went
    ;; nowhere.  The dock coming back from the left edge is what showed it:
    ;; re-anchoring both windows makes the compositor report a change, and every
    ;; rebuild after that printed a warning per cleanup.
    (let ((stop (wm-on-change (wm) (lambda () (in-monitor-scope output refresh!)))))
      (on-cleanup (lambda ()
                    (catch #t stop (lambda a #f))
                    (catch #t (lambda () (destroy zone)) (lambda a #f))
                    (catch #t (lambda () (destroy win)) (lambda a #f))
                    (dock-windows-set! model (remove (lambda (e) (equal? (car e) output))
                                                     (dock-windows model))))))
    win))
