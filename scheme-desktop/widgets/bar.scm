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
  ;; `config-splice', for `add-widget!': a layout section is the same shape as
  ;; any config list, so it is edited the way a plugin edits the config.
  #:use-module (scheme-toolkit config-splice)
  #:use-module (scheme-toolkit time)
  ;; NO WIDGET MODULES AND NO REGISTRY.  The bar resolves the names in its
  ;; layout against the REGISTRY -- `desktop-widget-named', from the toolkit --
  ;; so it has no table of constructors and imports no widget.
  ;;
  ;; IT USED TO IMPORT `(scheme-desktop widgets)' HERE, for the SIDE EFFECT:
  ;; importing that module is what filled the registry.  It no longer can, and
  ;; that is the improvement rather than a loss -- that module now imports THIS
  ;; one, for the class below, so the old import was a cycle.  Nothing is lost
  ;; because the registry is the ROOT's to fill: the bar is made when the list
  ;; names it, like every other widget.
  #:use-module (scheme-desktop style)
  ;; The schema is (scheme-desktop config); config-ref and config-value are the
  ;; toolkit's readers.
  #:use-module (scheme-toolkit config)
  #:use-module (scheme-desktop config)
  ;; GOOPS for the bar MODEL -- `define-class', `make' and `is-a?'.
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)

  #:export (build-bar! build-bar-windows! bar-clock
            ;; the bar model, and how a widget gets into it
            <bar-desktop-widget> bar add-widget! centerbox-slot widgets-in))

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

;; THE BAR'S OPTIONS, DECLARED WHERE THEY ARE READ.  These used to be five lines
;; in the shell's central schema that this module looked up by name --
;; `(config-ref 'desktop 'bar-position)' -- which meant the bar's own options
;; were declared somewhere the bar is not.
;;
;; Read through `cfg' below, which resolves the slot's reactive accessor, so a
;; `#:config' slot is still something a widget can BIND to and not only read.
(define (cfg name)
  "A reactive accessor for one of the bar's options."
  (widget-slot-ref (bar) name))

(define (bar-edge)
  "The edge the bar sits on: 'top or 'bottom."
  (bar-position (bar)))

(define (bar-anchor edge)
  "The three anchors for EDGE.  Anchor and border side must agree, or the bar is
anchored to one edge and styled for the other."
  (if (eq? edge 'bottom) '(bottom left right) '(top left right)))

;; THE BAR HAS NO TABLE OF WIDGETS ANY MORE.  It resolves the names in its
;; config against `(scheme-desktop widgets)', which is the only thing that knows
;; what exists -- so a widget is added by editing that file and nothing here.
;;
;; That also deletes the two memo tables that used to sit beside the two
;; constructor tables.  Those existed only because the tables held lambdas:
;; "what could exist" and "which object is it" needed a table each.  A registry
;; that holds objects answers both, so `model-for' and `panel-for' become
;; `desktop-widget-named' and the memoising goes away with them.

;;; ---------------------------------------------------------------------------
;;; The bar model
;;; ---------------------------------------------------------------------------
;;
;; THE BAR IS A MODEL TOO, AND LAYOUT IS ITS JOB.  Which widgets appear, in
;; which section, in what order, is a fact about the bar and not about the
;; widgets: `<clock-desktop-widget>' says what a clock looks like and has no opinion
;; about being third from the left.  That is why `add-widget!' is handed the
;; position rather than the widget carrying one -- and why moving a widget is a
;; change to the bar, which can rebuild, rather than a pretend-local edit on a
;; widget that GTK cannot re-parent.
;;
;; ONE MODEL PER SHELL, ONE VIEW PER MONITOR.  `build-bar!' is handed a monitor
;; and produces a tree; nothing in this section is per-monitor.

(define-class <bar-desktop-widget> (<edge-widget>)

  ;; --- the bar's options -------------------------------------------------
  ;;
  ;; POSITION decides the anchor and the border side together; they must agree
  ;; or the bar is anchored to one edge and styled for the other, which looks
  ;; like a CSS bug and is not.
  (position #:init-value 'top #:init-keyword #:position
            #:accessor bar-position
            #:config '(choice top bottom)
            #:label "Which edge the bar sits on"
            ;; WHAT IT DOES WHEN IT CHANGES, said here rather than in a list of
            ;; options that rebuild.  `window-set-anchored!' is the toolkit's --
            ;; it existed already, for exactly this -- and the class has to move
            ;; with the anchor or the bar is anchored to one edge and styled for
            ;; the other, which looks like a CSS bug and is not.
            #:apply (lambda (bar edge)
                      (for-each (lambda (win)
                                  (window-set-anchored! win (bar-anchor edge))
                                  (toggle-class! win "bar-bottom" (eq? edge 'bottom)))
                                (widget-windows bar))))

  ;; THE ROUND HIGHLIGHT BEHIND A BAR BUTTON, in pixels -- the wifi item and the
  ;; tray items both draw their hover as a circle, and this is the circle.  It is
  ;; ONE size for the bar rather than a size per widget because the point of it is
  ;; that the circles match: they were 1.2em each, which is a different number of
  ;; pixels in a label and in an image, so they came out different sizes.
  ;;
  ;; IT IS A STYLE, SO CHANGING IT RESTYLES.  The value is read by the theme when
  ;; the stylesheet is generated, and the stylesheet is one provider that is
  ;; re-parsed only when its text changes, so this is a re-parse and not a
  ;; rebuild -- no widget is touched.
  (icon-button-size #:init-value 24 #:init-keyword #:icon-button-size
                    #:accessor bar-icon-button-size
                    #:config '(integer 14 48)
                    #:label "Size of a bar icon's hover circle"
                    #:apply (lambda (bar pixels) (apply-shell-css!)))

  ;; THESE REACH THE SCREEN NOW.  Each was declared "read by nothing yet": the
  ;; window was built with its own values and nothing could change them, so the
  ;; only way an option could take effect was a rebuild -- which made a hotkey
  ;; for transparency cost a tear-down of every bar.
  ;;
  ;; THE LAMBDA CYCLES THROUGH THE WINDOWS.  One widget, one window per monitor:
  ;; the watcher is attached once, in the constructor, so an option has to act on
  ;; all of them rather than close over the one it was built with.
  (height   #:init-value 30 #:init-keyword #:height
            #:accessor bar-height #:config '(integer 16 96) #:label "Height"
            #:apply (lambda (bar value)
                      (for-each (lambda (win) (slot-set! win 'height-request value))
                                (widget-windows bar))))
  (margin   #:init-value 0 #:init-keyword #:margin
            #:accessor bar-margin #:config '(integer 0 64) #:label "Margin"
            ;; All four edges, as `layer-window' does when it is handed margins:
            ;; the anchored edges are what a gap between the bar and the screen
            ;; edge means, and the two unanchored ones cost nothing.
            #:apply (lambda (bar value)
                      (for-each (lambda (win)
                                  (slot-set! win 'margin-top value)
                                  (slot-set! win 'margin-right value)
                                  (slot-set! win 'margin-bottom value)
                                  (slot-set! win 'margin-left value))
                                (widget-windows bar))))
  (opacity  #:init-value 0.92 #:init-keyword #:opacity
            #:accessor bar-opacity
            #:config '(number 0.0 1.0) #:label "Background opacity"
            ;; GtkWidget's own opacity, so it fades the whole surface including
            ;; the text rather than only the background the class paints.  That
            ;; is what a translucent bar means in practice, and it is one
            ;; property set -- which is the point.
            #:apply (lambda (bar value)
                      (for-each (lambda (win) (slot-set! win 'opacity value))
                                (widget-windows bar))))

  ;; --- the layout --------------------------------------------------------
  ;;
  ;; ((position . widget) ...), in the order they were added.  This one is NOT
  ;; a config option: it holds widget objects, and a file can only name them.
  ;; `layout' below is the option the file carries, and `add-widget!' is its
  ;; runtime form.
  (widgets #:init-value '() #:accessor bar-widgets #:setter bar-widgets-set!)
  ;; THE LAYOUT IS THE OPTION, and it holds NAMES, because a file can only name
  ;; things.  `widgets' above is the same layout RESOLVED -- the names looked up
  ;; in the registry -- and is what the tree is built from.  One is data, the
  ;; other is data with the registry applied; they are not two copies of a
  ;; value, and `add-widget!' is the only thing that writes both.
  ;;
  ;; The descriptor is `(list)' -- an opaque list, which the settings widget
  ;; will show read-only rather than pretend it can offer a control for.
  ;; `audio' REPLACED `volume' -- the panel does the volume, and the old bar
  ;; item was removed.  A default is not enough on its own: the config FILE is
  ;; authoritative once it exists, and the shell writes its in-memory layout back
  ;; to it, so a machine whose file still says `volume' keeps saying it.  Keeping
  ;; this in step is what makes a fresh install correct.
  ;; EMPTY BY DEFAULT, in the shape a section has: (left (NAME ...)).  What is in
  ;; the bar on a first run is not written here any more -- each widget puts
  ;; itself in with its `widget-enable!', and the first run writes the result to
  ;; config.scm.  A default here would be a second list to keep in step, and it
  ;; went out of step the first time a widget was added.
  (layout #:init-value '((left ()) (center ()) (right ()))
          #:accessor bar-layout #:setter bar-layout-set!
          #:config '(list) #:label "Which widgets, and where"
          ;; NOT A REBUILD ANY MORE.  A layout change adds, removes and moves
          ;; the widgets that changed, in each monitor's bar, and leaves the
          ;; windows and everything else standing.  This was the last option
          ;; that tore the whole bar down.
          #:apply (lambda (w layout) (bar-apply-layout! w)))
  ;; This monitor's bar windows, one per monitor.  `<bar-desktop-widget>' is ONE widget and
  ;; `build-bar!' runs once per monitor, so the widget is where they collect --
  ;; which is what makes `widget-toggle!', `widget-visible?' and the presenting
  ;; at startup work on the bar exactly as they do on a panel.
  (windows #:init-value '() #:accessor bar-windows #:setter bar-windows-set!)

  ;; THE GUI IT CONTROLS, one entry per monitor -- the same shape as the
  ;; workspaces widget's boxes, because being built once per output is the same
  ;; problem.  Two of them, because reconciling a section needs both the box to
  ;; put children in and the trees to know which child came from which widget.
  ;;
  ;;   sections  ((output . ((left . box) (center . box) (right . box))) ...)
  ;;   trees     ((output . ((left . ((widget . tree) ...)) ...)) ...)
  (sections #:init-value '() #:accessor bar-sections #:setter bar-sections-set!)
  (trees #:init-value '() #:accessor bar-trees #:setter bar-trees-set!))

;; A BAR IS A WIDGET LIKE ANY OTHER, and this is the only thing that makes it
;; different: it owns more than one window.  Overriding `widget-windows' is the
;; whole of it -- `widget-show!', `widget-hide!', `widget-toggle!' and
;; `widget-visible?' are all written in terms of it, so they move every monitor
;; together without knowing there is more than one.
(define-method (widget-windows (w <bar-desktop-widget>)) (bar-windows w))

;; AND IT FORGETS THEM WHEN THEY GO.  The default destroys what `widget-windows'
;; returns and leaves the list alone, which is right for a widget that caches a
;; window it can build again -- but a bar's list is the ONLY record of its
;; windows, so destroying them without clearing it leaves dead objects in it.
;; The next rebuild appends to that list, and the first `widget-visible?' or
;; `present' that walks it touches a destroyed GObject:
;;
;;   GLib-GObject-CRITICAL: g_object_get_property: assertion 'G_IS_OBJECT' failed
;;
;; which took the whole shell down on the first config edit -- the reload, not
;; the config, being the thing that found it.
(define-method (widget-destroy-windows! (w <bar-desktop-widget>))
  (let ((wins (bar-windows w)))
    (for-each (lambda (win) (catch #t (lambda () (destroy win)) (lambda args #f)))
              wins)
    (bar-windows-set! w '())
    (length wins)))

;; AND THE SECTION BOXES GO THE SAME WAY, for the same reason: they were inside
;; the window that has just been destroyed.
(define-method (widget-decommission! (w <bar-desktop-widget>) output)
  (if output
      (begin
        (bar-sections-set! w (assoc-remove! (bar-sections w) output))
        (bar-trees-set! w (assoc-remove! (bar-trees w) output)))
      (begin
        (bar-sections-set! w '())
        (bar-trees-set! w '())))
  #t)

;; AND THE SAME WHEN THE SET OF WIDGETS CHANGES, which is the other half of the
;; story: a widget the layout names may have just been created, and one it names
;; may just have gone.  Both questions are answered by looking in the registry,
;; and the reconcile does exactly that -- so all this has to do is ask it to look
;; again.  That is what replaced rebuilding the shell to make one widget appear.
(define-method (widget-registry-changed! (w <bar-desktop-widget>))
  (bar-apply-layout! w))

(define (bar-add-window! w win)
  "Record WIN as one of W's per-monitor windows."
  (bar-windows-set! w (cons win (bar-windows w)))
  win)

(define* (add-widget! bar widget #:key (position 'right))
  "Put WIDGET at the END of BAR's POSITION section.

POSITION IS 'left, 'center OR 'right, which is what a bar has -- not
Gtk.CenterBox's start/center/end.  `centerbox-slot' is the translation and it
happens here, so the vocabulary a config file uses is the vocabulary a bar has
rather than GTK's."
  ;; THE HIERARCHY IS WHAT ANSWERS THIS.  A bar holds `<bar-item-widget>'s --
  ;; things that are built into something else -- and a `<window-widget>' is not
  ;; one, so putting a panel in a bar is caught here rather than failing later
  ;; with "no applicable method for widget-build".
  (unless (is-a? widget <bar-item-widget>)
    (error "add-widget!: not a bar item:" (widget-name widget)))
  (unless (memq position '(left center right))
    (error "add-widget!: position is left, center or right, got:" position))
  (bar-widgets-set! bar (append (bar-widgets bar) (list (cons position widget))))
  ;; Both, so the option and the resolved view cannot drift.  This is the
  ;; RUNTIME form -- a settings window or a drag between sections -- not the
  ;; path a rebuild takes, which resolves `layout' into `widgets' directly.
  (bar-layout-set! bar (config-splice (bar-layout bar) (list '() position '())
                                      (widget-name widget) 'end))
  bar)

(define (centerbox-slot position)
  "The Gtk.CenterBox slot for a bar POSITION."
  (case position ((left) 'start) ((right) 'end) (else 'center)))

(define (widgets-in bar position)
  "BAR's widgets for POSITION, in order."
  (map cdr (filter (lambda (pair) (eq? (car pair) position)) (bar-widgets bar))))

(define (bar-widget-names)
  "Every registered widget's name, as text, sorted.  For the warning below."
  (sort (map (lambda (n) (format #f "~s" n)) (desktop-widget-names)) string<?))

(define (section-names section)
  "The names in one layout SECTION, `(right (NAME ...))'."
  (if (and (pair? (cdr section)) (list? (cadr section))) (cadr section) '()))

(define (prune-layout! model)
  "Drop the names in MODEL's layout that no live widget has.

WHY THIS IS NOT JUST A WARNING.  `resolve-layout!' used to SKIP an unknown name
and say so, which is right for one startup -- the bar comes up one widget short
and the message explains it.  But the layout is a SAVED option and the shell
writes its in-memory layout back to config.scm, so the unknown name was written
out again, and again, for ever.  A plugin that is removed, or a widget disabled
without being taken out of the bar, leaves exactly that behind.

The repair runs BEFORE the file is next written, not only when the layout is
read: the corrected layout is what gets saved, so one startup heals the file
permanently instead of re-reporting it every run.

AND IT ASKS FOR THE WRITE ITSELF.  `bar-layout-set!' is the plain GOOPS setter
rather than the config engine's ticking one, so writing the slot marks nothing
dirty and schedules no save -- correct for the ordinary path (the engine owns
that) and wrong for a repair made during startup, where there is no later change
to carry it out.  `widget-config-save!' writes now.

Returns #t when the layout changed."
  (let* ((layout (bar-layout model))
         (fixed (map (lambda (section)
                       (let ((known (filter (lambda (n) (desktop-widget-named n))
                                            (section-names section))))
                         (list (car section) (delete-duplicates known))))
                     layout)))
    (if (equal? fixed layout)
        #f
        (begin
          (bar-layout-set! model fixed)
          (catch #t (lambda () (widget-config-save!)) (lambda args #f))
          #t))))

(define (resolve-layout! model)
  "Fill MODEL's widgets from its layout, which holds names.

A NAME THE WIDGET TABLE DOES NOT KNOW IS SKIPPED rather than fatal -- a typo
should cost one widget, not the bar.  `prune-layout!' has already removed any it
could find, so reaching the message below means a name vanished between the two
calls, which is worth saying loudly.  With the two things that make it fixable:
which section listed it, and what the valid names are."
  (bar-widgets-set!
   model
   (append-map
    (lambda (section)
      (let ((position (car section)))
        (filter-map
         (lambda (name)
           (let ((w (desktop-widget-named name)))
             (if w
                 (cons position w)
                 (begin
                   (format (current-error-port)
                           "scheme-desktop: ~s is not a bar widget, skipping it (listed in the ~s section).~%  valid names: ~s~%"
                           name position (bar-widget-names))
                   #f))))
         (section-names section))))
    (bar-layout model))))

(define (bar)
  "The bar widget.

AN ORDINARY LOOKUP, which is the change.  This used to be a memoised singleton
that built its own model and REGISTERED ITSELF, because it had to exist before
the config was read -- its options are read from a file that cannot be opened
until the bar is there to own them.  So the bar was a second special case beside
the root: created by hand, registered by hand, thrown away by hand through
`reset-bar!'.

THE ROOT OWNS THAT NOW, so there is nothing left here to own.  The bar is made
when the list names it, unmade when the list stops naming it, and remade on a
reload -- all by the same code path every other widget takes.

AND THE LAYOUT IS STILL RESOLVED AT BUILD TIME, in `build-bar!'.  That has not
changed and must not: the layout is a file option, so the names it holds cannot
become widgets until the file has been read, which is after this returns."
  (desktop-widget-required <bar-desktop-widget>))

;;; ---------------------------------------------------------------------------
;;; Filling a section, and keeping it filled
;;; ---------------------------------------------------------------------------
;;
;; ONE OPERATION, USED BY BOTH.  A bar being built and a bar whose layout just
;; changed are the same problem -- "make these boxes hold these widgets, in this
;; order" -- and doing it in one place is what makes a layout change stop being a
;; rebuild: a bar is already standing, so the second caller only moves children.
;;
;; A SECTION IS RECONCILED, NOT REBUILT.  A widget that is still in the section
;; keeps the tree it already has, so moving the clock from left to right neither
;; destroys it nor makes a second one -- which matters beyond tidiness, because a
;; widget's tree is STATEFUL: the workspaces widget holds its pills in a slot
;; keyed by output, and a tree built behind its back would leave it pointing at
;; buttons that no longer exist.

(define (section-boxes model output)
  "MODEL's three section boxes on OUTPUT, or #f when that bar is not built."
  (assoc-ref (bar-sections model) output))

(define (section-trees model output)
  "What is in each of MODEL's sections on OUTPUT: ((widget . tree) ...) per section."
  (or (assoc-ref (bar-trees model) output) '()))

(define (set-section-trees! model output position pairs)
  (bar-trees-set! model
                  (assoc-set! (bar-trees model) output
                              (assoc-set! (section-trees model output) position pairs))))

(define (reconcile-section! model output position box)
  "Make BOX hold POSITION's widgets, in order, touching only what changed."
  ;; `or ... '()': a section with nothing in it yet -- every build, for the
  ;; first one -- has no entry, and `assq' on #f is an error rather than an
  ;; empty answer.
  (let* ((old (or (assoc-ref (section-trees model output) position) '()))
         (want (widgets-in model position))
         ;; WHAT SURVIVES KEEPS ITS TREE; what is new is built now.  `assq', not
         ;; `assoc': a widget is found by IDENTITY.
         ;; THE SECTION IS SAID BEFORE THE TREE IS BUILT, because the tree is
         ;; what reads it: a bar item's button asks its widget which part of the
         ;; bar it is in, and the panel it opens is aligned to that.  This is the
         ;; one place that knows -- the layout is what decides a section, and a
         ;; widget moves between sections without its own code hearing about it.
         (pairs (map (lambda (w)
                       (mark-item-section! w position)
                       (or (assq w old) (cons w (widget-build w output))))
                     want))
         ;; THE DEPARTED GO FIRST, and each is TOLD as well as destroyed: the
         ;; widget holds references to the GUI inside its tree -- workspaces
         ;; holds its pills -- and a reference to a destroyed button is the
         ;; `G_IS_OBJECT' crash arriving by another road.
         (gone (filter (lambda (p) (not (memq (car p) want))) old)))
    ;; REMOVED, NOT DESTROYED, AND THAT IS THE POINT.
    ;;
    ;; `destroy' is a generic with methods only for the classes that need more
    ;; than a removal -- windows -- and NONE for a plain box or button.  So
    ;; `(destroy <a bar item's tree>)' threw "No applicable method for destroy",
    ;; the catch below swallowed it, and THE DEPARTED CHILD SIMPLY STAYED IN THE
    ;; BOX while this widget's record of its trees dropped it.  The bar then
    ;; showed a second menu button, on screen and in no record anywhere -- and
    ;; when that widget came back, a new tree was appended beside the old one, so
    ;; it showed two.
    ;;
    ;; `remove-child!' is what takes a widget out of a box, and the reference
    ;; going away is what lets GTK finalise it -- the ordinary GTK4 arrangement.
    (for-each (lambda (p)
                (catch #t (lambda () (remove-child! box (cdr p) #f)) (lambda args #f))
                ;; TOLD as well as removed: the widget holds references to the GUI
                ;; inside its tree -- workspaces holds its pills -- and a
                ;; reference to a removed button is the thing that must not
                ;; survive.
                (catch #t (lambda () (widget-decommission! (car p) output))
                       (lambda args #f)))
              gone)
    ;; THEN THE BOX IS MADE TO EQUAL THE MODEL, rather than adjusted towards it.
    ;; Everything comes out, and the survivors and the new ones go back in order.
    ;;
    ;; THIS REPLACED "REMOVE IT IF IT HAS A PARENT, THEN APPEND IT", and the
    ;; difference is not stylistic: that version trusted
    ;; `gtk-widget-get-parent' to answer truly for a child of a box, and when it
    ;; does not, the append puts the child in a second time and the old copy
    ;; stays -- the bar grew a SECOND MENU BUTTON while the widget's own record
    ;; of its trees said there was one.  Making the box equal the model needs no
    ;; such assumption, and the cost is one remove-and-append per child on a
    ;; layout change, which is rare and local.
    ;;
    ;; `clear-box!' walks GTK's own child list, not the element runtime's table
    ;; -- the trap its own docstring warns about, where a module that adds
    ;; children with `add-child!' leaves that table empty and clearing from it
    ;; removes nothing.
    (clear-box! box)
    (for-each (lambda (p) (add-child! box (cdr p) #f)) pairs)
    (set-section-trees! model output position pairs)
    pairs))

(define (reconcile-bar! model output)
  "Make OUTPUT's bar show exactly what MODEL's layout says; #f if it has none.

THE MODEL IS RESOLVED FIRST.  `widgets-in' reads it, so the layout has to have
become widgets before any section is reconciled against it.

THE PRUNE COMES BEFORE THE RESOLVE, so a name the registry no longer knows is
removed from the layout -- and therefore from the next save -- rather than
skipped at every startup for ever.  See `prune-layout!'."
  (prune-layout! model)
  (resolve-layout! model)
  (let ((boxes (section-boxes model output)))
    (if (not boxes)
        #f
        (begin
          (for-each (lambda (position)
                      (let ((box (assoc-ref boxes position)))
                        (when box
                          (reconcile-section! model output position box))))
                    '(left center right))
          #t))))

(define (bar-apply-layout! w)
  "A changed layout: reconcile every monitor's bar, and build none of them."
  ;; EACH MONITOR'S REDRAW RUNS IN THAT MONITOR'S ROOT.  This runs from a config
  ;; watcher on the main loop -- the layout option's `#:apply', and the widget
  ;; list changing -- so no scope is current here, and every `on-cleanup' in a
  ;; rebuilt tree was registered nowhere: timers and signal handlers that never
  ;; went away.  One warning per build was the only sign.
  (let ((outputs (map car (bar-sections w))))
    (if (null? outputs)
        ;; NO BAR IS BUILT YET -- startup, where the file is read before the
        ;; first `build-bar!'.  The model is resolved anyway, so the bar that
        ;; does get built is right, and pruned first for the same reason as
        ;; `reconcile-bar!': the repair must reach the file.
        (begin (prune-layout! w) (resolve-layout! w))
        (for-each (lambda (output)
                    (in-monitor-scope output (lambda () (reconcile-bar! w output))))
                  outputs)))
  #t)

(define (build-sections! model output)
  "The three empty section boxes for OUTPUT, recorded on MODEL."
  (let ((boxes (list (cons 'left   (element <gtk-box> #:slot (centerbox-slot 'left)
                                                #:orientation 'horizontal
                                                #:class "bar-start"))
                     (cons 'center (element <gtk-box> #:slot (centerbox-slot 'center)
                                                #:orientation 'horizontal
                                                #:class "bar-center"))
                     (cons 'right  (element <gtk-box> #:slot (centerbox-slot 'right)
                                                #:orientation 'horizontal
                                                #:class "bar-end")))))
    (bar-sections-set! model (assoc-set! (bar-sections model) output boxes))
    boxes))

;;; ---------------------------------------------------------------------------
;;; The panels
;;; ---------------------------------------------------------------------------
;;
;; A PANEL IS A WIDGET, and its window comes from the widget.  This used to walk
;; a separate table of window factories, and that table was a second place to
;; keep in step with the widget table -- which is how `network' came to be a bar
;; button whose panel nothing built.
;;
;; ONE PER SHELL, NOT ONE PER MONITOR.  A popup follows the focused monitor
;; rather than existing on every one, which is what ags2-shell's popups do: the
;; layer surface is created without a gdkmonitor and the compositor puts it on
;; whichever output has focus.

(define (build-bar-windows!)
  "Build the windows owned by the bar's panels.  Returns how many were built.

Inside `create-window-root', so every binding and signal these windows create
has a scope to be cleaned up in.  Built outside one they would warn once per
widget and then hold their handlers for the life of the process.

ASKING A WIDGET FOR ITS WINDOW is the whole of this now.

ONLY THE `<window-widget>`s ARE ASKED.  A bar item has no window and no
`widget-window' method, so a bar without this filter fails with `no applicable
method for widget-window' once per item -- which is the hierarchy working, and
the filter is the caller saying which kind of widget it is looking for."
  (create-window-root
   (lambda ()
     (count (lambda (built) built)
            ;; One result per window widget: the window, or #f if it would not
            ;; build.  A window that cannot be built must not take the bar down
            ;; with it -- the bar is still usable and the REPL is still there to
            ;; say why, which is the whole reason the failure is reported here
            ;; rather than allowed to propagate.
            (map (lambda (w)
                   (catch #t
                     (lambda () (widget-window w))
                     (lambda (key . rest)
                       (format (current-error-port)
                               "scheme-desktop: cannot build the ~a window: ~a ~s~%"
                               (widget-name w) key rest)
                       #f)))
                 (filter (lambda (w) (is-a? w <window-widget>))
                         (desktop-widgets)))))))

(define* (build-bar! monitor #:key (name "bar"))
  "Build the bar for MONITOR and return it.

NAME is the monitor's own identifier, passed on to the window so that a
hotplug can tell one bar from another; for-each-monitor supplies it."
  (let* ((edge (bar-edge))
         ;; The MODEL, not a fresh layout: the widgets it holds are the shell's
         ;; one instance of each, and `widget-build' makes this monitor's tree.
         ;;
         ;; RESOLVED HERE rather than once when the model was made, because the
         ;; layout is a FILE option and the file cannot be read until the bar
         ;; exists to own it:
         ;;
         ;;   the bar's options live on the bar
         ;;   the bar is created by `(bar)', which registers it
         ;;   the config is read after that, and writes the layout slot
         ;;   so the names become widgets HERE, when both are in place
         ;;
         ;; Reading the config first would find no bar to apply the bar's own
         ;; options to -- which is how `bar-margin 1' in the file was silently
         ;; skipped while every other option applied.
         (model (bar))
         (output (monitor-name monitor))
         ;; THE BOXES ARE MADE FIRST so the window can take them as its three
         ;; centerbox slots, and they are recorded on the MODEL as they are made
         ;; -- which is what a later layout change looks them up in.
         (boxes (build-sections! model output))
         (left-box (cdr (assq 'left boxes)))
         (center-box (cdr (assq 'center boxes)))
         (right-box (cdr (assq 'right boxes)))
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
            ;; The `panel' class is ags2-shell's: it is the element that carries
            ;; the bar's background, which is what lets the WINDOW itself stay
            ;; transparent.  Named here so their stylesheet rule applies to this
            ;; shell's tree unchanged.
            #:class "panel"

            ;; THE BOXES COME FIRST, EMPTY, AND ARE FILLED BELOW.  Each is
            ;; created even when its section is empty: a centerbox with a missing
            ;; slot is fine, but having all three always present means nothing
            ;; has to reason about which slots exist -- and it is what lets a
            ;; layout change find the box it needs to change.
            ;;
            ;; The CSS classes stay start/center/end because that is what the
            ;; stylesheet selects on; `centerbox-slot' is the only place the
            ;; bar's left/center/right meets GTK's.
            left-box center-box right-box))))
    ;; The stylesheet is applied to the DISPLAY, once, not to this window.
    ;; Calling it here is harmless (it is idempotent) and keeps the entry point
    ;; where a reader looks for it, but the effect is global -- see
    ;; apply-shell-css! for why a per-window call does not work in GTK4.
    (apply-shell-css!)
    ;; THE WINDOW BELONGS TO THE WIDGET.  One per monitor, all recorded on the
    ;; one `<bar-desktop-widget>', which is what lets the bar be presented, toggled and
    ;; destroyed through `widget-windows' like any other widget.
    ;; FILL THE SECTIONS, through the same call a layout change makes.  One code
    ;; path, so "what the bar is built with" and "what a layout change produces"
    ;; cannot drift.
    (reconcile-bar! model output)
    (bar-add-window! model win)
    ;; THE NEW WINDOW GETS THE CURRENT VALUES NOW.  The watchers are attached
    ;; when the WIDGET is made, and they cover every change from then on -- but a
    ;; window built after an option was set had nothing to act on at the time.
    ;; That is not a corner case: it is every startup, where the config file is
    ;; read before anything is built, and it is every hotplug.
    (widget-apply-options! model)
    win))

;;; ---------------------------------------------------------------------------
;;; Nothing here rebuilds the bar any more
;;; ---------------------------------------------------------------------------
;;
;; WHAT USED TO BE HERE: `%layout-options', `on-layout-change!',
;; `watch-bar-layout!` and `%rebuild-hook' -- a list of the options that changed
;; the bar's SHAPE, and a hook the shell registered `reload-shell!' in, so that a
;; change to one of them tore the shell down and built it again.
;;
;; ALL FIVE OPTIONS NOW SAY WHAT TO DO ABOUT THEMSELVES, on their own slots:
;;
;;   position  anchor and class, set in place        `window-set-anchored!'
;;   height    a size                                `height-request'
;;   margin    four margins                          `margin-*'
;;   opacity   one property                          GtkWidget's own
;;   layout    the section children reconciled       `bar-apply-layout!'
;;
;; which leaves NOTHING in this shell that rebuilds on a config change.  The only
;; things that rebuild it now are a change to the user's own init.scm, which the
;; watcher sees, and an explicit `reload!'.
