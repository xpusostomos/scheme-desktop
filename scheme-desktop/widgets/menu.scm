;;; (scheme-desktop widgets menu) -- the menu window
;;;
;;; Omarchy's menu, drawn with GTK: a title, then a list of rows, each an icon
;;; and a label, with `>' on the rows that open something. Navigated entirely
;;; by keyboard, and closed by Escape or a click outside.
;;;
;;;   Up / Down      move
;;;   Right / Return open a submenu, or run a leaf and close
;;;   Left           go up a level
;;;   Escape         close
;;;
;;; The window is a stack of state and one render function. The PATH is where
;;; you are -- a list of keys -- and the INDEX which row is under the cursor; every
;;; key changes one of those, and the render redraws from them. Nothing walks
;;; the widget tree looking for the selected row, and no widget holds menu
;;; state, so the tree can be rebuilt from scratch on every move without
;;; anything getting out of step.
;;;
;;; THE ROWS ARE REBUILT, NOT PATCHED. A submenu holds at most a few dozen rows
;;; and moving the cursor only changes which one carries `selected' -- rebuilding
;;; is a few hundred microseconds and removes every class of bug that comes from
;;; a view that is partly updated.

(define-module (scheme-desktop widgets menu)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  ;; For `idle', which is how the scroll-to-the-cursor runs after the rows have
  ;; been laid out.
  #:use-module (scheme-toolkit time)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-desktop wm)
  #:use-module (scheme-desktop menu)
  #:use-module (scheme-desktop menu guards)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:duplicates (merge-generics replace warn-override-core warn last)
  #:export (<menu-desktop-widget> <menu-panel-desktop-widget>
            menu-activate toggle-menu menu-open?
            menu-move! menu-descend! menu-ascend! menu-close!
            menu-path menu-selected))

(define-gi-imports "Gtk"
  "Box" "Label" "Button" "Image" "ScrolledWindow" "EventControllerKey"
  "IconTheme" "Settings"
  ;; For keeping the cursor on screen: the scroll view's adjustment, and the
  ;; geometry of the row the cursor is on.
  "Adjustment")
(define-gi-imports "Graphene" "Rect")
(define-gi-imports "Gdk" "Display")
(define-gi-imports "GLib" "get_os_info")

;;; ---------------------------------------------------------------------------
;;; Key values
;;; ---------------------------------------------------------------------------

;; GDK keyvals. Spelled out rather than as `Gdk.KEY_Up', which is not importable
;; as a constant -- a keyval is a number and the names live in a header.
(define %KEY-Escape 65307)
(define %KEY-Return 65293)
(define %KEY-KP-Enter 65421)
(define %KEY-Left 65361)
(define %KEY-Up 65362)
(define %KEY-Right 65363)
(define %KEY-Down 65364)
(define %KEY-Home 65360)
(define %KEY-End 65367)

;;; ---------------------------------------------------------------------------
;;; State
;;; ---------------------------------------------------------------------------

;; WHERE THE MENU IS AND WHAT IS ON SCREEN, on the panel widget rather than in
;; the module.  One menu per shell, so the two are equivalent in effect; the
;; difference is that reading the class tells you what the menu holds, which a
;; module-level `%index' did not.
(define-class <menu-panel-desktop-widget> (<popup-widget>)
  ;; Where in the menu we are, as the path `menu-resolve' takes. Empty is root.
  (path      #:init-value '() #:accessor menu-panel-path
             #:setter menu-panel-path-set!)
  (index     #:init-value 0   #:accessor menu-panel-index
             #:setter menu-panel-index-set!)

  ;; The guard shell, alive only while the window is open. Every condition in
  ;; the displayed submenu is evaluated against it, and closing the window closes
  ;; it -- one shell per time-the-menu-is-open, which is the whole design.
  (session   #:init-value #f  #:accessor menu-panel-session
             #:setter menu-panel-session-set!)

  (window    #:init-value #f  #:accessor menu-panel-window
             #:setter menu-panel-window-set!)
  (items     #:init-value #f  #:accessor menu-panel-items
             #:setter menu-panel-items-set!)
  ;; THE SCROLL VIEW, kept so the cursor can be kept on screen: it is the only
  ;; way to reach the adjustment that says where the list is scrolled to.
  (scroll    #:init-value #f  #:accessor menu-panel-scroll
             #:setter menu-panel-scroll-set!)
  (title     #:init-value #f  #:accessor menu-panel-title
             #:setter menu-panel-title-set!)

  ;; THE ROWS OF THE SUBMENU BEING SHOWN, evaluated once each time the path
  ;; changes. This is not an optimisation: evaluating them runs the submenu's
  ;; guards, and a guarded submenu costs a fifth of a second. Re-evaluating on
  ;; every arrow key would spend that per keystroke, and applisting would
  ;; re-enumerate every installed application on every cursor move.
  (rows      #:init-value '() #:accessor menu-panel-rows
             #:setter menu-panel-rows-set!)

  ;; THE ROWS' OWN SCOPE, disposed before the next render.
  ;;
  ;; The window is built inside a root, but the rows are rebuilt on every render
  ;; and a render happens from a keypress -- which is a signal handler, emitted
  ;; by C, where no scope is current. So each render gets a root of its own, and
  ;; the previous one is disposed first: without that, every row of every render
  ;; would leave its cleanup behind, and holding down an arrow key would grow the
  ;; list for as long as the key was held.
  (rows-root #:init-value #f  #:accessor menu-panel-rows-root
             #:setter menu-panel-rows-root-set!))

;; THE ONE MENU, from the registry.
;;
;; The public API below is singleton-flavoured -- `(toggle-menu)' and
;; `(menu-activate '(system))' -- because a keybinding names THE menu, and
;; api.scm re-exports those names for exactly that reason. So they resolve the
;; widget here; everything that does the work takes it as an argument, so a
;; second menu could exist without any of that changing.
(define (menu-panel)
  (desktop-widget-required 'menu-panel))

;; The widget is `menu-panel' and its window is `menu'.  See the note on the date
;; menu's panel for why the window's name is declared this way.
(define-method (widget-window-name (w <menu-panel-desktop-widget>)) "menu")

;;; ---------------------------------------------------------------------------
;;; The distro logo, the way ags2-shell finds it
;;; ---------------------------------------------------------------------------

;; `GLib.get_os_info("LOGO")' is the `LOGO=' key in /etc/os-release, and it is
;; used ONLY IF the icon theme actually has an icon by that name -- a distro
;; that names a logo it does not ship gets the fallback rather than a blank.
(define (distro-icon-name)
  (catch #t
    (lambda ()
      (let ((logo (g-get-os-info "LOGO")))
        (and logo
             (not (string=? logo ""))
             (gtk-icon-theme-has-icon
              (gtk-icon-theme-get-for-display (gdk-display-get-default))
              logo)
             logo)))
    (lambda args #f)))

(define %fallback-icon "system-search-symbolic")

;;; ---------------------------------------------------------------------------
;;; Rendering
;;; ---------------------------------------------------------------------------

(define (entry->title entry)
  "The heading for ENTRY: its `title', else its `label', else nothing.

The distinction is Omarchy's: a row can read \"Browser\" in the Defaults list
while the submenu it opens is headed \"Default Browser\"."
  (or (and entry (entry-ref entry 'title))
      (and entry (entry-ref entry 'label))
      ""))

(define (icon-widget row)
  "ROW's icon: an image when it is a themed icon, else a font glyph.

The two kinds are different fields because they are different widgets, and
nothing here has to guess which it is holding."
  (let ((name (menu-row-icon-name row))
        (glyph (menu-row-icon row)))
    (if (and name (not (string=? name "")))
        (element <gtk-image> #:class "menu-item-icon"
                 #:icon-name name #:pixel-size 18 #:use-fallback #t)
        (element <gtk-label> #:class "menu-item-icon"
                 #:label (or glyph "")))))

(define (row-widget w row selected?)
  "One row: a button, so it is clickable, holding icon, label and arrow."
  (let ((button (element <gtk-button>
                   #:class (string-append
                            "menu-item"
                            (if selected? " selected" "")
                            (if (menu-row-disabled? row) " disabled" ""))
                   #:can-focus #f
                   (element <gtk-box> #:orientation 'horizontal
                            (icon-widget row)
                            (element <gtk-label>
                                     #:class "menu-item-label"
                                     #:label (menu-row-label row)
                                     #:xalign 0.0
                                     #:hexpand #t
                                     ;; The window has a fixed width, so a label
                                     ;; too long for it is cut here and ends in
                                     ;; an ellipsis rather than widening the menu.
                                     #:ellipsize 'end)
                            (element <gtk-label>
                                     #:class "menu-item-arrow"
                                     #:label (if (menu-row-submenu? row) ">" ""))))))
    (unless (menu-row-disabled? row)
      (connect-signal! button "clicked"
                       (lambda (b)
                         (let ((i (row-index-of w button)))
                           (when i (menu-panel-index-set! w i) (descend! w))))))
    button))

;; The index is found by asking the box, not stored on the button: the buttons
;; are rebuilt on every render, so a stored index would have to be kept in step
;; with a list that is thrown away.
(define (row-index-of w button)
  (let loop ((child (gtk-widget-get-first-child (menu-panel-items w))) (i 0))
    (cond ((not child) #f)
          ((eq? child button) i)
          (else (loop (gtk-widget-get-next-sibling child) (+ i 1))))))

(define (current-rows w) (menu-panel-rows w))

(define (refresh-rows! w)
  (menu-panel-rows-set! w (menu-rows (or (menu-resolve (menu-panel-path w)) (menu)) #:session (menu-panel-session w))))

(define (render-into! w)
  "Redraw the window from its rows and its index. Nothing else holds menu state."
  (clear-box! (menu-panel-items w))
  (when (menu-panel-title w)
    (catch #t
      (lambda () (slot-set! (menu-panel-title w) 'label (entry->title (or (menu-resolve (menu-panel-path w)) (menu)))))
      (lambda args #f)))
  ;; The cursor is clamped HERE rather than at every move, so coming up out of a
  ;; long submenu into a short one cannot leave it past the end.
  (when (pair? (menu-panel-rows w))
    (menu-panel-index-set! w (max 0 (min (menu-panel-index w) (- (length (menu-panel-rows w)) 1)))))
  (let loop ((rest (menu-panel-rows w)) (i 0))
    (when (pair? rest)
      (add-child! (menu-panel-items w) (row-widget w (car rest) (= i (menu-panel-index w))) #f)
      (loop (cdr rest) (+ i 1)))))

(define (%render! w)
  "Redraw the rows, in a scope of their own."
  (menu-fit-to-screen! w)
  (when (menu-panel-rows-root w)
    (catch #t (menu-panel-rows-root w) (lambda args #f)))
  (menu-panel-rows-root-set! w #f)
  (menu-panel-rows-root-set! w (create-root (lambda (dispose) (render-into! w))))
  ;; AND THEN KEEP THE CURSOR WHERE IT CAN BE SEEN, in an idle rather than here:
  ;; the rows were built a moment ago and GTK has not laid them out yet, so a
  ;; row's position is not known until the loop comes back round.
  (idle (lambda () (scroll-selected-into-view! w))))

;;; ---------------------------------------------------------------------------
;;; How tall the list is
;;; ---------------------------------------------------------------------------

;; AS TALL AS THE ROWS NEED, AND NO TALLER, up to the screen.  This was a fixed
;; 380 -- `about ten rows', following Omarchy, which caps its list at 70% of the
;; panel -- and that is the wrong question: a menu of twelve items on a screen
;; with room for thirty should SHOW TWELVE rather than scroll to reach the last
;; two.  The number that answers it is the room the panel was placed with, which
;; the toolkit knows (`popup-available-height': the screen less the bar's edge),
;; and it is asked for on every render so a menu on a shorter screen, or under a
;; taller bar, comes out right without being told.
;;
;; WHAT IT REPLACES IS THE CAP, NOT THE SCROLLING: a list with more rows than the
;; screen still scrolls, and the cursor is still kept in view while it does.
(define (menu-fit-to-screen! w)
  "Let the list be as tall as its rows, up to the room the panel has."
  (let* ((win (menu-panel-window w))
         (scroller (menu-panel-scroll w))
         (room (and win (popup-available-height win))))
    (when (and scroller (number? room) (> room 0))
      (catch #t
        (lambda ()
          (slot-set! scroller 'max-content-height (inexact->exact (round room)))
          #t)
        (lambda args #f)))))

;;; ---------------------------------------------------------------------------
;;; Keeping the cursor on screen
;;; ---------------------------------------------------------------------------

;; GTK DOES THIS FOR FOCUS AND NOT FOR ANYTHING ELSE, which is the whole of the
;; answer to "why does it let you make that mistake": a scrolled window keeps the
;; FOCUSED child in view (`scroll-to-focus', on by default), and this menu's rows
;; are deliberately not focusable -- the menu holds the keyboard itself and tracks
;; a cursor rather than a focus, because a focus ring on a row you are merely
;; passing through is not what a menu looks like.  So the row carrying `selected'
;; is NOTHING TO GTK: a CSS class on a button nobody focused.  Arrowing to the
;; eleventh of ninety-six rows moved the highlight off the bottom of the cap and
;; the list stayed where it was.
;;
;; So the arithmetic is here, and it is the minimum move that helps: bring the row
;; to the edge it went past, rather than centring it, so the list does not lurch
;; when the cursor moves one row at a time.

(define (selected-row-widget w)
  "The row button the cursor is on, or #f.

Found by walking the box, for the same reason `row-index-of' does: the buttons
are rebuilt on every render and nothing on them survives to be remembered."
  (let loop ((child (and (menu-panel-items w)
                         (gtk-widget-get-first-child (menu-panel-items w))))
             (i 0))
    (cond ((not child) #f)
          ((= i (menu-panel-index w)) child)
          (else (loop (gtk-widget-get-next-sibling child) (+ i 1))))))

(define (scroll-value-for top bottom value page)
  "Where a scroll view should sit for a row spanning TOP..BOTTOM to be visible.

VALUE is where it sits now and PAGE how much of it is on screen.  A row above the
top pulls the view up to it; a row below the bottom pushes it down just far enough
to show that row's last pixel; a row already visible leaves it ALONE -- which is
the case that matters, because it is the common one and any other answer would
make the list creep as the cursor walks through it."
  (cond ((< top value) top)
        ((> bottom (+ value page)) (- bottom page))
        (else value)))

(define (scroll-selected-into-view! w)
  "Move the menu's scroll view just far enough to show the selected row."
  (let ((scroller (menu-panel-scroll w))
        (row (selected-row-widget w)))
    (when (and scroller row (menu-panel-items w))
      (catch #t
        (lambda ()
          (let* ((adj (gtk-scrolled-window-get-vadjustment scroller))
                 (bounds (call-with-values
                             (lambda ()
                               (gtk-widget-compute-bounds row (menu-panel-items w)))
                           (lambda (ok rect) (and ok rect)))))
            (when (and adj bounds)
              (let* ((top (graphene-rect-get-y bounds))
                     (bottom (+ top (graphene-rect-get-height bounds)))
                     (value (gtk-adjustment-get-value adj))
                     (page (gtk-adjustment-get-page-size adj))
                     (want (scroll-value-for top bottom value page)))
                (unless (= want value) (gtk-adjustment-set-value adj want)))))
          #t)
        (lambda args #f)))))

;;; ---------------------------------------------------------------------------
;;; Moving
;;; ---------------------------------------------------------------------------

(define (move! w delta)
  (let ((n (length (menu-panel-rows w))))
    (when (pair? (menu-panel-rows w))
      (menu-panel-index-set! w (modulo (+ (menu-panel-index w) delta) n))
      (%render! w))))

(define (descend! w)
  "Right or Return: open the selected row, or run it and close."
  (let ((row (and (pair? (menu-panel-rows w)) (list-ref (menu-panel-rows w) (menu-panel-index w)))))
    (when row
      (cond
       ((menu-row-disabled? row) #f)     ; already installed; nothing to do
       ((menu-row-submenu? row)
        (menu-panel-path-set! w (append (menu-panel-path w) (list (entry-key (menu-row-entry row)))))
        (menu-panel-index-set! w 0)
        (refresh-rows! w)
        (%render! w))
       (else
        (menu-run (menu-row-entry row))
        (close-menu! w))))))

(define (ascend! w)
  "Left: up a level. The rest of the menu is untouched -- you entered here, you
are not cut off from the rest of it."
  (unless (null? (menu-panel-path w))
    (menu-panel-path-set! w (drop-right (menu-panel-path w) 1))
    (menu-panel-index-set! w 0)
    (refresh-rows! w)
    (%render! w)))

;;; ---------------------------------------------------------------------------
;;; The window
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; The navigation, as procedures
;;; ---------------------------------------------------------------------------
;;
;; The key handler calls these rather than doing the work inline, so a
;; keybinding can drive the menu without a keyboard -- which is how it is
;; tested, and how `hyprctl dispatch' would drive it if the menu ever needed
;; to be walked from outside.

(define (menu-path) "Where the menu is: a list of keys, '() for the root."
  (menu-panel-path (menu-panel)))

(define (menu-selected) "The index of the selected row."
  (menu-panel-index (menu-panel)))

(define (menu-move! delta) (move! (menu-panel) delta))
(define (menu-ascend!) (ascend! (menu-panel)))
(define (menu-descend!) (descend! (menu-panel)))
(define (menu-close!) (close-menu! (menu-panel)))
(define (menu-open?) (menu-open-panel? (menu-panel)))

(define (close-menu! w)
  (when (menu-panel-window w)
    (catch #t (lambda () (widget-hide! w)) (lambda args #f))))

(define (menu-open-panel? w)
  (and (menu-panel-window w) (window-visible? (menu-panel-window w))))

;; OPENING THE MENU REDRAWS IT, on BOTH ways in.  The rows are not a fixed list:
;; the submenu's entries are evaluated when they are shown, and the top level is
;; the desktop's applications, which come and go.  The keybinding path did this
;; by hand and the BAR BUTTON did not -- it toggled the window and showed
;; whatever rows happened to be in the box -- so the same menu could be two
;; different menus depending on how it was opened.
(define-method (widget-show! (w <menu-panel-desktop-widget>))
  (refresh-rows! w)
  (%render! w)
  (next-method))

(define-method (widget-window (w <menu-panel-desktop-widget>))
  "The menu window, built once and registered under the name `menu'."
  (unless (menu-panel-window w)
    (menu-panel-title-set! w (element <gtk-label> #:class "menu-title"
                          #:xalign 0.0 #:label ""))
    (menu-panel-items-set! w (element <gtk-box> #:orientation 'vertical #:class "menu-items"))
    ;; THE SCROLL VIEW IS BUILT HERE RATHER THAN IN THE TREE BELOW so it can be
    ;; kept: the cursor is kept on screen by moving this window's adjustment, and
    ;; nothing else in the panel can reach it.
    (menu-panel-scroll-set!
     w
     (element <gtk-scrolled-window>
              #:class "menu-scroll"
              #:hscrollbar-policy 'never
              #:vscrollbar-policy 'automatic
              #:propagate-natural-height #t
              #:max-content-height 380
              (menu-panel-items w)))
    (set! (menu-panel-window w)
          (popup-window (widget-window-name w)
                        ;; OUT FROM THE BAR'S EDGE, like the other two panels.
                        ;; It used to be a bare 'center, which put the menu in
                        ;; the middle of the screen and -- once the button's
                        ;; place is what places it -- would have left it centred
                        ;; VERTICALLY as well: the vertical half of the position
                        ;; is what decides which margin the bar's height lands
                        ;; on, so a menu with no vertical half opens over the bar.
                        #:position (bar-popup-position)
                        ;; MODAL: a menu is navigated by arrow keys, so it has
                        ;; to hold the keyboard while it is up. `on-demand' would
                        ;; give it focus only when nothing else wants it, which
                        ;; is exactly when a menu is not useful.
                        #:keymode 'exclusive
                        (element <gtk-box> #:orientation 'vertical #:class "menu"
                                 (menu-panel-title w)
                                 ;; PROPAGATING THE NATURAL HEIGHT IS ONLY HALF
                                 ;; OF IT. `propagate-natural-height' makes the
                                 ;; scrolled window ask for the height its child
                                 ;; wants -- and `apps' wants ninety-six rows, so
                                 ;; without a cap the menu is as tall as the
                                 ;; screen. The cap is what turns "as tall as the
                                 ;; content" into "as tall as the content, up to
                                 ;; about ten rows, then scroll".
                                 ;;
                                 ;; Omarchy does the same thing by arithmetic --
                                 ;; its card is min(content + header + visible
                                 ;; rows, panel height - gaps) -- and caps the
                                 ;; list at 70% of the panel.
                                 (menu-panel-scroll w))))
    (let ((keys (make <gtk-event-controller-key>)))
      (connect-signal! keys "key-pressed"
                       (lambda (c keyval keycode modifiers)
                         (case keyval
                           ((65362) (move! w -1) #t)                 ; Up
                           ((65364) (move! w 1) #t)                  ; Down
                           ((65360) (menu-panel-index-set! w 0) (%render! w) #t) ; Home
                           ((65367)                                  ; End
                            (menu-panel-index-set! w (max 0 (- (length (menu-panel-rows w)) 1)))
                            (%render! w) #t)
                           ((65363 65293 65421) (descend! w) #t)     ; Right/Return
                           ((65361) (ascend! w) #t)                  ; Left
                           ((65307) (close-menu! w) #t)              ; Escape
                           (else #f))))
      (add-controller (menu-panel-window w) keys))
    ;; THE WINDOW RENDERS ITSELF WHEN IT IS SHOWN.
    ;;
    ;; Show it however you like -- the bar button, a keybinding, the REPL --
    ;; and it draws itself, because this is the only thing that knows it has
    ;; become visible. Before this the rendering lived in `toggle-menu', so a
    ;; button whose `on-clicked' did not reach it opened an empty window, and
    ;; the bar's own default (a plain window toggle) opened one too.
    ;;
    ;; The guard shell lives exactly as long as the window is open.
    (connect-signal! (menu-panel-window w) "notify::visible"
                     (lambda args
                       (if (window-visible? (menu-panel-window w))
                           (begin
                             (unless (menu-panel-session w) (menu-panel-session-set! w (guard-session-start)))
                             (refresh-rows! w)
                             (%render! w))
                           (when (menu-panel-session w)
                             (guard-session-stop (menu-panel-session w))
                             (menu-panel-session-set! w #f))))))
  (menu-panel-window w))

;;; ---------------------------------------------------------------------------
;;; The way in
;;; ---------------------------------------------------------------------------

(define* (menu-activate path #:key (root (menu)))
  "Open the menu AT PATH; run it instead if PATH names a leaf.

  (menu-activate '())                  ; the top level
  (menu-activate '(trigger reminder))  ; entered there, and free to go up
  (menu-activate '(system lock))       ; a leaf: runs it, no window

A path that names nothing opens the top level and says so, rather than opening
an empty menu that looks like a bug in the menu."
  (let* ((w (menu-panel))
         (entry (menu-resolve path #:root root)))
    (cond
     ((not entry)
      (format (current-error-port)
              "scheme-desktop: menu: no entry at ~s; opening the top level~%" path)
      (menu-panel-path-set! w '())
      (menu-panel-index-set! w 0)
      (show-menu! w))
     ((menu-leaf? entry)
      (menu-run entry))
     (else
      (menu-panel-path-set! w path)
      (menu-panel-index-set! w 0)
      (show-menu! w)))))

(define (show-menu! w)
  ;; THE WINDOW IS BUILT INSIDE A ROOT. It is created on the first activation,
  ;; which is a REPL call or a click -- neither of which is inside any scope --
  ;; so every `connect-signal!' it makes would warn that its cleanup will never
  ;; run and then hold the handler for the life of the process. Same bug the
  ;; tray and the workspace pills had; same fix.
  (unless (menu-panel-window w)
    (create-window-root (lambda () (widget-window w))))
  ;; THROUGH THE WIDGET VERB, NOT `present'.  `present' shows the window and
  ;; nothing else: it skipped both the placement that `window-set-visible!' does
  ;; -- so a menu opened from a keybinding came up at its position rather than
  ;; under the bar -- and the redraw, which is now `widget-show!'s own method.
  (widget-show! w))

(define (toggle-menu)
  "THE KEYBINDING's way in: open at the top, or close if open.

FROM THE KEYBOARD, SO IT OPENS CENTRED, and the opener says so -- see
`popup-anchor-centred!' -- because the gesture did not come from the bar and a
menu hung off a bar button would point at something that had no part in opening
it.  The bar button takes the other route (`panel-button''s own click) and says
the other thing.

WHICH SCREEN the middle is on is the focused monitor, since a popup is one window
and the keyboard went to whichever screen has the focus."
  (let ((w (menu-panel)))
    (if (menu-open-panel? w)
        (close-menu! w)
        (begin
          (menu-panel-path-set! w '())
          (menu-panel-index-set! w 0)
          (popup-anchor-centred! (widget-window-name w) (focused-monitor))
          (show-menu! w)))))

(define (focused-monitor)
  "The monitor with the focus, as an object a popup can be moved to, or #f.

The compositor answers by NAME (see `wm-focused-monitor'); a popup wants the
GdkMonitor, and ours are keyed by the same name."
  (let ((name (and (wm-loaded?) (wm-focused-monitor (wm)))))
    (and name (find (lambda (m) (equal? (monitor-name m) name)) (monitors)))))

;;; ---------------------------------------------------------------------------
;;; The bar button
;;; ---------------------------------------------------------------------------

(define-class <menu-desktop-widget> (<bar-item-widget>))

(define-method (widget-build (w <menu-desktop-widget>) output)
  "The bar's far-left button: the distro's logo, or a search glyph.

This is the icon that made ags2-shell look like it \"knew\" it was on Omarchy:
it is the distro's own LOGO, read from /etc/os-release.

No `on-clicked': `panel-button' already toggles the named window, which is the
same path the date menu's button takes and the same one that is known to work.
There is nothing a click needs to do beyond make the window visible -- the
window renders itself when it is."
  (panel-button (desktop-widget-required 'menu-panel)
                #:align (widget-section w)
                (element <gtk-image>
                         #:icon-name (or (distro-icon-name) %fallback-icon)
                         #:use-fallback #t)))
