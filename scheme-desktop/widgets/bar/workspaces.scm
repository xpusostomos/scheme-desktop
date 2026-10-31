;;; (scheme-desktop widgets bar workspaces) -- the workspace numbers
;;;
;;; PORTED FROM ags2-shell's `Overview.Button' (`widget/Bar/components/Overview/
;;; index.tsx'), with one change the reference does not have: the workspaces are
;;; NUMBERS rather than unlabelled dots, so a keybinding can name one.
;;;
;;;   1 2 3 4 5 6 7
;;;   ^   ^
;;;   |   `-- a circle: this workspace is focused on ANOTHER monitor
;;;   `------ a filled circle: this workspace is focused on THIS bar's monitor
;;;
;;; Everything else is a plain number. `occupied' -- has windows on it -- is a
;;; fourth state, and it is a modifier rather than a shape: a workspace can be
;;; occupied and not focused.
;;;
;;; THE COMPOSITOR IS NOT NAMED ANYWHERE HERE. It comes from
;;; `(scheme-desktop wm)': which workspace each monitor is showing, which
;;; workspaces have windows, when any of it changed, and how to switch. This
;;; module says which workspace is in which state and what a click means.

(define-module (scheme-desktop widgets bar workspaces)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit config)
  #:use-module (scheme-desktop config)
  #:use-module (scheme-desktop wm)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)

  #:duplicates (merge-generics replace warn-override-core warn last)
  #:export (<workspaces-desktop-widget> workspaces-count))

(define-gi-imports "Gtk" "Box" "Button" "Label")

(define %default-count 7)

;; THE COUNT IS THIS WIDGET'S OPTION.  It is the thing that shows the numbers,
;; so it is the thing that says how many -- and the workspace picker next door
;; asks this widget for it rather than declaring a second copy.
(define-class <workspaces-desktop-widget> (<bar-item-widget>)
  (count #:init-value 7 #:init-keyword #:count
         #:accessor workspaces-count
         #:config '(integer 1 32)
         #:label "How many workspace numbers"
         ;; WHAT IT DOES WHEN IT CHANGES: put the right number of pills in each
         ;; box it built.  A count is not a rebuild -- the boxes are right here,
         ;; one per monitor, and nothing outside this widget is touched.
         #:apply (lambda (w count)
                   (for-each (lambda (pair) (set-pill-count! w (car pair) count))
                             (workspaces-boxes w))))

  ;; THE GUI IT CONTROLS, ONE ENTRY PER MONITOR -- the same shape as the bar's
  ;; `windows' slot, because being built once per monitor is the same problem.
  ;;
  ;; THESE WERE CLOSURE VARIABLES INSIDE `widget-build', AND THEY HAD TO MOVE.  A
  ;; config slot's `#:apply' is handed the WIDGET, so everything it has to reach
  ;; must be reachable FROM the widget; a local of the build call is reachable
  ;; from nothing but the callbacks that happened to close over it.  The argument
  ;; for the closures was that a slot would be shared by every monitor's bar --
  ;; which is true of a slot on this widget holding ONE box, and not true of one
  ;; entry per monitor.  A closure was not the only alternative; it was the only
  ;; one considered.
  (boxes #:init-value '()
         #:accessor workspaces-boxes #:setter workspaces-boxes-set!)
  (pills #:init-value '()
         #:accessor workspaces-pills #:setter workspaces-pills-set!)
  (ours  #:init-value '()
         #:accessor workspaces-ours #:setter workspaces-ours-set!))

(define (workspace-count w)
  "How many numbers W shows.

A FIXED COUNT, as ags2-shell has, not the workspaces that happen to exist. The
point of a number is that it is always there to be named by a keybinding; a
list that grows and shrinks moves the numbers under the fingers."
  (workspaces-count w))

(define (apply-state! btn id ours others occupied)
  "Mark BTN with ID's states.

`toggle-class!' rather than `(slot-set! btn 'css-classes ...)': that property is
a GStrv, and assigning a single string to it either fails inside G-Golf's
conversion or replaces every class with one odd name, including GTK's own
`text-button', which is not ours to remove."
  (toggle-class! btn "active" (= id ours))
  (toggle-class! btn "active-other" (and (not (= id ours)) (and (member id others) #t)))
  (toggle-class! btn "occupied" (and (member id occupied) #t)))

;;; ---------------------------------------------------------------------------
;;; What the tree asks of the widget
;;; ---------------------------------------------------------------------------
;;
;; THREE READS, ONE PER SLOT, so the build does not walk an alist by hand and a
;; missing entry answers something sensible rather than #f -- a bar being built
;; has no pills YET, and that is not an error.

(define (box-for w output) (assoc-ref (workspaces-boxes w) output))
(define (pills-for w output) (or (assoc-ref (workspaces-pills w) output) '()))
(define (ours-for w output) (or (assoc-ref (workspaces-ours w) output) 0))

;; TO COUNT PILLS, IN ONE BAR'S BOX.  The old ones are DESTROYED, not merely
;; removed from the box: this widget holds a reference to every pill -- that is
;; what lets it talk to them -- so unparenting alone would leave them alive and
;; off screen, which is the leak that only shows up as a picture of a bar that
;; has been rebuilt a hundred times.
(define (set-pill-count! w output count)
  (let ((box (box-for w output)))
    (when box
      (for-each (lambda (pair)
                  (catch #t (lambda () (destroy (cdr pair))) (lambda args #f)))
                (pills-for w output))
      (let ((made (build-pills w output count)))
        (workspaces-pills-set! w (assoc-set! (workspaces-pills w) output made))
        (for-each (lambda (pair) (add-child! box (cdr pair) #f)) made)))))

(define (build-pills w output count)
  "COUNT buttons for the bar on OUTPUT, in order."
  (map (lambda (id)
         (let ((btn (element <gtk-button>
                             #:name (number->string id)
                             #:class "workspace"
                             #:valign 'center
                             #:can-focus #f
                             (element <gtk-label>
                                      #:label (number->string id)))))
           (connect-signal!
            btn "clicked"
            ;; WHICH WORKSPACE IS FOCUSED IS ASKED FOR AT CLICK TIME, not
            ;; captured: the focused workspace moves, and a closure would go on
            ;; answering with the value it had when the button was made.
            (lambda (b)
              ;; The focused workspace opens the switcher; anything else goes
              ;; there. Clicking your own workspace to switch to it would be a
              ;; no-op, so it earns the click.
              (if (= id (ours-for w output))
                  (toggle-widget 'overview)
                  (wm-focus-workspace! (wm) id))))
           (cons id btn)))
       (iota count 1)))

(define (restate! w output)
  "Mark each pill of OUTPUT's bar with the states the compositor reports."
  (let* ((focused (wm-focused-workspaces (wm)))
         (mine (or (assoc-ref focused output) 0))
         (others (filter (lambda (id) (not (= id mine))) (filter-map cdr focused)))
         (occupied (wm-occupied-workspaces (wm))))
    (workspaces-ours-set! w (assoc-set! (workspaces-ours w) output mine))
    (for-each (lambda (pair)
                (apply-state! (cdr pair) (car pair) mine others occupied))
              (pills-for w output))))

(define-method (widget-build (w <workspaces-desktop-widget>) output)
  "The workspace numbers, for the bar on OUTPUT.

OUTPUT is the monitor's connector name, and it is what separates \"the workspace
I am on\" from \"a workspace some other monitor is on\". Without it every focused
workspace would look the same, which a single-monitor shell can get away with
and a two-monitor one cannot.

THIS BAR'S FOCUSED WORKSPACE IS CACHED from the last refresh rather than asked
for on click: a click handler must not make a synchronous call into the
compositor for something the last event already told us."
  (let ((box (element <gtk-box> #:orientation 'horizontal #:class "workspaces")))
    (workspaces-boxes-set! w (assoc-set! (workspaces-boxes w) output box))
    (set-pill-count! w output (workspace-count w))
    ;; THE COMPOSITOR'S EVENT STREAM, not a pair of property bindings. Which
    ;; workspace is focused on ANOTHER monitor changes without this monitor's
    ;; focused workspace changing at all, so a binding on the focused workspace
    ;; would not fire and the circle would sit on the wrong number.
    (wm-on-change (wm) (lambda () (restate! w output)))
    (restate! w output)
    box))

;; THE TEARDOWN MESSAGE, from the root, when the bar's tree goes.
;;
;; NOTHING IS DESTROYED HERE.  The pills went with the box and the box went with
;; the bar's window before this arrives; what is left is this widget's own idea
;; of what exists, and leaving that populated means the next apply reaches a
;; destroyed button -- the `G_IS_OBJECT' crash arriving by another road.
(define-method (widget-decommission! (w <workspaces-desktop-widget>) output)
  (if output
      (begin
        (workspaces-boxes-set! w (assoc-remove! (workspaces-boxes w) output))
        (workspaces-pills-set! w (assoc-remove! (workspaces-pills w) output))
        (workspaces-ours-set! w (assoc-remove! (workspaces-ours w) output)))
      (begin
        (workspaces-boxes-set! w '())
        (workspaces-pills-set! w '())
        (workspaces-ours-set! w '())))
  #t)
