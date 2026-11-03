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
  #:use-module (scheme-desktop splice)
  #:use-module (scheme-desktop wm)
  #:use-module (scheme-desktop menu)
  #:use-module (scheme-desktop menu guards)
  ;; `exec-shell', for a string-valued `action' that takes a value.
  #:use-module (scheme-toolkit process)
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
  ;; For the string and number editors, which are a text field.
  "Entry"
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
  ;; THE ROW BEING EDITED, while an editor is open -- the widget for a choice or
  ;; a value, the row itself for the yes/no question -- or #f for the ordinary
  ;; menu.  At most one of these two is set, and the menu is a list of rows again
  ;; when both are #f.
  (editing   #:init-value #f #:accessor menu-panel-editing
             #:setter menu-panel-editing-set!)
  (confirm   #:init-value #f #:accessor menu-panel-confirm
             #:setter menu-panel-confirm-set!)
  ;; WHERE IN THE ROWS THE EDITED ONE IS, the widget its row drew (for a choice,
  ;; whose setter is on the widget), and what has been typed into a string or
  ;; number editor.
  (editor-row-index #:init-value #f #:accessor menu-panel-editor-row-index
                    #:setter menu-panel-editor-row-index-set!)
  (typed      #:init-value "" #:accessor menu-panel-typed
              #:setter menu-panel-typed-set!)
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
  (desktop-widget-required <menu-panel-desktop-widget>))

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

;; THE BOX AT THE RIGHT OF A ROW, and what it says.  A typed row is a SETTING,
;; and the box is its value:
;;
;;   boolean   an empty box, or one with a tick -- U+2610 and U+2611, a matched
;;             pair, so a row does not change width when it is toggled
;;   option    the same two boxes, one per choice, and the box for the option the
;;             value names carries the tick (the editors are next; today the
;;             current option is shown as text)
;;   number    the number, as text
;;   string    the text, in quotes
;;
;; A ROW WITH NO TYPE SHOWS NOTHING, which is every Omarchy row -- their menus
;; install and remove things and have no settings in them.
(define glyph-ticked (string (integer->char #x2611)))
(define glyph-unticked (string (integer->char #x2610)))

(define (box-text row)
  "What the box at the end of ROW says, or #f for no box."
  (let ((type (menu-row-type row))
        (value (menu-row-value row)))
    (case type
      ((boolean) (if (equal? value "true") glyph-ticked glyph-unticked))
      ((number string option) (or value ""))
      (else #f))))

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
                            ;; THE BOX FIRST, THEN THE ARROW: a typed row shows
                            ;; its value, and the arrow still says it opens
                            ;; something -- which, for a typed row, is its editor.
                            (let ((box (box-text row)))
                              (if box
                                  (element <gtk-label> #:class "menu-item-box"
                                           #:label box #:xalign 1.0)
                                  (element <gtk-label> #:class "menu-item-box"
                                           #:label "" #:xalign 1.0)))
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
  (cond
   ;; AN EDITOR, or the question that comes before one: rows of its own, built by
   ;; the editor, in the same box the menu's rows use.
   ((menu-panel-confirm w)
    (for-each (lambda (tree) (add-child! (menu-panel-items w) tree #f))
              (confirm-rows w (menu-panel-confirm w))))
   ((menu-panel-editing w)
    (for-each (lambda (tree) (add-child! (menu-panel-items w) tree #f))
              (editor-rows w (menu-panel-editing w))))
   (else
    (let loop ((rest (menu-panel-rows w)) (i 0))
      (when (pair? rest)
        (add-child! (menu-panel-items w) (row-widget w (car rest) (= i (menu-panel-index w))) #f)
        (loop (cdr rest) (+ i 1)))))))

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
       ;; A TYPED ROW IS A SETTING AND OPENS ITS EDITOR, before the submenu test:
       ;; a generated row may have both, and the value is what choosing it means.
       ((menu-row-type row)
        (case (menu-row-type row)
          ((boolean) (toggle-menu-row! w row))
          ((choice) (open-editor! w row #:editor 'choice))
          ((string) (open-editor! w row #:editor 'string))
          ((number) (open-editor! w row #:editor 'number))
          (else (run-row! w row))))
       ((menu-row-submenu? row)
        (menu-panel-path-set! w (append (menu-panel-path w) (list (entry-key (menu-row-entry row)))))
        (menu-panel-index-set! w 0)
        (refresh-rows! w)
        (%render! w))
       (else (run-row! w row))))))

(define (run-row! w row)
  "Run ROW's action and close the menu -- what a row with no type does."
  (menu-run (menu-row-entry row))
  (close-menu! w))

(define (ascend! w)
  "Left: up a level. The rest of the menu is untouched -- you entered here, you
are not cut off from the rest of it.

AN OPEN EDITOR IS A LEVEL, so Left leaves it first -- and the menu it was opened
from is still there, because the editor never changed the path."
  (cond
   ((or (menu-panel-editing w) (menu-panel-confirm w)) (close-editor! w))
   ((null? (menu-panel-path w)) #f)
   (else
    (menu-panel-path-set! w (drop-right (menu-panel-path w) 1))
    (menu-panel-index-set! w 0)
    (refresh-rows! w)
    (%render! w))))

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


;; THE MENU GOES AT THE LEFT END OF THE BAR, ahead of the workspaces.
(define-method (widget-enable! (w <menu-desktop-widget>) config)
  (config-splice-into-bar (config-splice-add-widget config w) w 'left 'beginning))

(define-method (widget-build (w <menu-desktop-widget>) output)
  "The bar's far-left button: the distro's logo, or a search glyph.

This is the icon that made ags2-shell look like it \"knew\" it was on Omarchy:
it is the distro's own LOGO, read from /etc/os-release.

No `on-clicked': `panel-button' already toggles the named window, which is the
same path the date menu's button takes and the same one that is known to work.
There is nothing a click needs to do beyond make the window visible -- the
window renders itself when it is."
  (panel-button (desktop-widget-required <menu-panel-desktop-widget>)
                #:align (widget-section w)
                (element <gtk-image>
                         #:icon-name (or (distro-icon-name) %fallback-icon)
                         #:use-fallback #t)))

;;; ---------------------------------------------------------------------------
;;; Editors: choosing a row's value, rather than running it
;;; ---------------------------------------------------------------------------
;;
;; A TYPED ROW IS A SETTING, and choosing it opens its editor rather than running
;; its action -- except a boolean, where the editor IS the action (turn it on,
;; turn it off) and the only question is whether to ask first.
;;
;; The editors go down one level inside the menu, so they look like a submenu and
;; are left the same way (Left, or Escape).
;;
;; **THE MENU KNOWS NOTHING ABOUT WHAT IT IS EDITING.**  A row says what its value
;; IS (`value'), what to run to change it (`action', called with the new value),
;; and -- for a choice -- what the choices are (`options').  That is the whole of
;; it: the same three fields a hand-written row uses for anything else.  Which
;; rows exist, and that some of them come from a widget's config, is the
;; generator's business, not this file's.

(define (choice-values row)
  "ROW's options, as strings, for a `choice' -- from its own `options' field."
  (let ((own (entry-ref (menu-row-entry row) 'options)))
    (map (lambda (v) (if (string? v) v (symbol->string v)))
         (cond ((pair? own) own)
               ((vector? own) (vector->list own))
               (else '())))))

(define (value-matches? a b)
  "Whether A and B are the same value.  Case-insensitive: a value is a word a
person typed somewhere, and its spelling is not load-bearing."
  (and a b (string-ci=? (if (string? a) a (symbol->string a))
                        (if (string? b) b (symbol->string b)))))

;; WHAT A ROW IS BEING SET TO *IS* ITS ACTION -- that is the whole mechanism, and
;; it is why a choice is a plain `action' that takes an argument.

(define (row-set-value! w row value)
  "Set ROW to VALUE, by running its action WITH the value.

A PROCEDURE ACTION IS CALLED WITH THE VALUE -- `(lambda (v) …)' is what a
generated row's setter is.  A STRING ACTION IS A COMMAND LINE with the value
appended as an argument: a command is arbitrary shell, and editing one to place a
value would be guesswork.  A SYMBOL names a procedure, as everywhere else in a
menu."
  (let ((action (and row (entry-ref (menu-row-entry row) 'action))))
    (cond
     ((procedure? action) (catch #t (lambda () (action value)) (lambda args #f)))
     ((symbol? action) (catch #t (lambda () (evaluate-menu-value action)) (lambda args #f)))
     ((string? action)
      (catch #t
        (lambda ()
          (exec-shell (format #f "~a ~a" action
                              (if (string? value) value (symbol->string value)))))
        (lambda args #f)))
     (else #f))
    (refresh-rows! w)))

(define (editor-choice-tree w row option)
  "One option of a `choice', with the box that says whether it is the current one."
  (let ((current? (value-matches? option (menu-row-value row))))
    (element <gtk-button>
             #:class (string-append "menu-item" (if current? " current" ""))
             #:can-focus #f
             #:on-clicked (lambda (b)
                            (row-set-value! w row option)
                            (close-editor! w))
      (element <gtk-box> #:orientation 'horizontal
        (element <gtk-label> #:class "menu-item-label" #:xalign 0.0 #:hexpand #t
                 #:label option)
        (element <gtk-label> #:class "menu-item-box" #:xalign 1.0
                 #:label (if current? glyph-ticked glyph-unticked))))))

(define (editor-entry-tree w kind)
  "A row with something to type in it -- a string, or a number."
  (let ((entry (element <gtk-entry> #:class "menu-editor-entry"
                        #:text (menu-panel-typed w)
                        #:hexpand #t)))
    ;; EVERY KEYSTROKE IS KEPT, so the text survives a redraw -- and so that the
    ;; Ok button below can read it without reaching into the widget again.
    (connect-signal! entry "changed"
                     (lambda (e) (menu-panel-typed-set! w (slot-ref e 'text))))
    (element <gtk-box> #:orientation 'vertical #:class "menu-editor"
      (element <gtk-label> #:class "menu-editor-hint" #:xalign 0.0
               #:label (if (eq? kind 'number) "New number" "New text"))
      entry
      (element <gtk-button> #:class "menu-item" #:can-focus #f
               #:on-clicked (lambda (b)
                              (let ((text (menu-panel-typed w)))
                                (row-set-value! w (menu-panel-row-being-edited w)
                                                (if (eq? kind 'number)
                                                    (or (string->number text) text)
                                                    text))
                                (close-editor! w)))
        (element <gtk-label> #:class "menu-item-label" #:xalign 0.0 #:hexpand #t
                 #:label "Set")))))

(define (editor-rows w kind)
  "The rows of whichever editor KIND is -- 'choice, 'string or 'number."
  (let ((row (menu-panel-row-being-edited w)))
    (case kind
      ((choice) (map (lambda (o) (editor-choice-tree w row o)) (choice-values row)))
      ((string number) (list (editor-entry-tree w kind)))
      (else '()))))

(define (confirm-rows w row)
  "The yes/no question a boolean row asks before its action runs."
  (list (element <gtk-label> #:class "menu-editor-hint" #:xalign 0.0
                 #:label (format #f "~a?" (menu-row-label row)))
        (element <gtk-button> #:class "menu-item" #:can-focus #f
                 #:on-clicked (lambda (b) (run-editor! w row))
          (element <gtk-label> #:class "menu-item-label" #:xalign 0.0 #:hexpand #t
                   #:label "Yes"))
        (element <gtk-button> #:class "menu-item" #:can-focus #f
                 #:on-clicked (lambda (b) (close-editor! w))
          (element <gtk-label> #:class "menu-item-label" #:xalign 0.0 #:hexpand #t
                   #:label "No"))))

;;; The state an editor keeps while it is open.

(define (menu-panel-row-being-edited w)
  "The row the open editor belongs to, or #f.

FOUND FROM THE INDEX AND THE ROWS, not kept: a row is rebuilt whenever the menu
refreshes, so a stored one would be a row from before the last refresh."
  (let ((i (menu-panel-editor-row-index w))
        (rows (menu-panel-rows w)))
    (and i (pair? rows) (< i (length rows)) (list-ref rows i))))

(define* (open-editor! w row #:key (editor 'choice))
  "Open ROW's editor: 'choice, 'string or 'number."
  (menu-panel-editor-row-index-set! w (menu-panel-index w))
  (menu-panel-typed-set! w (or (menu-row-value row) ""))
  (menu-panel-editing-set! w editor)
  (%render! w))

(define (close-editor! w)
  "Leave the editor and go back to the menu it was opened from."
  (menu-panel-editing-set! w #f)
  (menu-panel-confirm-set! w #f)
  (menu-panel-editor-row-index-set! w #f)
  (%render! w))

(define (run-editor! w row)
  "Run ROW's action -- what a boolean's Yes does -- and leave the editor."
  (catch #t (lambda () (menu-run (menu-row-entry row))) (lambda args #f))
  (close-editor! w))

(define (toggle-menu-row! w row)
  "Ask before running ROW's action, which for a boolean is how it is turned on or
off: a setting changed from a menu is worth one question."
  (menu-panel-editor-row-index-set! w (menu-panel-index w))
  (menu-panel-confirm-set! w row)
  (%render! w))
