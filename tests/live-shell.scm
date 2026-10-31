;;; tests/live-shell.scm -- assert against a RUNNING shell, over its REPL
;;;
;;; This is the tier the plan calls the testing story: rather than screenshots
;;; and synthesized keypresses, attach to the shell's own REPL and ask it
;;; questions.  It inspects the real widget tree, so there is no stub to drift
;;; from reality -- which is the failure mode ags2-shell can only approximate
;;; with node:vm fakes.
;;;
;;; Run with the shell up:
;;;
;;;   bin/scheme-desktop run &
;;;   ../scheme-toolkit/bin/scheme-toolkit guile -s tests/live-shell.scm
;;;
;;; If no shell is listening the suite SKIPS rather than failing: a test that
;;; fails because nothing is running teaches a reader nothing.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit repl))
(use-modules (srfi srfi-1))
(use-modules (srfi srfi-13))
(use-modules (srfi srfi-64))
(use-modules (ice-9 popen))
(use-modules (ice-9 rdelim))
(use-modules (ice-9 textual-ports))

(define instance "scheme-desktop")

;; (current-filename) is RELATIVE when the file is run with -s ("tests/live-
;; shell.scm"), so dirname twice gives "." and every path built from it is
;; wrong.  Resolve against the invocation directory first.
;; AND IT CAN BE #f.  When this file is LOADED FROM A COMPILED COPY the source
;; location is not available and `current-filename' answers #f -- so the
;; `absolute-file-name?' below throws and the suite reports an ABORT with no
;; tests run, which reads as a broken shell rather than a broken path.  It made a
;; freshly-cleaned checkout look broken, and again after any recompile.
;; `(command-line)' has this script's own path in both cases.
(define (this-file)
  (or (current-filename) (car (command-line))))

(define desktop-root
  (dirname (dirname (if (absolute-file-name? (this-file))
                        (this-file)
                        (string-append (getcwd) "/" (this-file))))))

(define toolkit-bin
  (string-append desktop-root "/../scheme-toolkit/bin/scheme-toolkit"))

;; A STALE socket file is left behind when a shell exits without cleaning up,
;; so `test -S' answers "yes" for a shell that is not there and every
;; assertion below then fails against a dead endpoint -- which reads as seven
;; broken features rather than one absent shell.
;;
;; `scheme-toolkit list' already makes the distinction: it prints
;; "scheme-desktop  (stale)" for a socket that does not answer.  So the test is
;; "a line naming this instance that is NOT marked stale".
(define (shell-running?)
  (let* ((p (open-input-pipe
             (string-append toolkit-bin " list 2>/dev/null")))
         (answer (get-string-all p)))
    (close-pipe p)
    (let ((mine (filter (lambda (line)
                          (string-prefix? instance line))
                        (string-split (or answer "") #\newline))))
      (and (pair? mine)
           (not (any (lambda (line) (string-contains line "(stale)")) mine))))))

;; evaluate ONE expression in the live shell and return its printed value.
;; The client is the same one a keybinding uses, so this exercises the
;; control path as well as the answer.
(define (eval-in-shell expr)
  ;; The expression must be SHELL-QUOTED.  ~s renders it as valid Scheme, but
  ;; the string goes through /bin/sh, which reads the parens as syntax and
  ;; fails before scheme-toolkit is ever reached -- so every assertion below
  ;; would report an empty answer rather than the answer it asked for.
  (let* ((cmd (string-append
               toolkit-bin " eval -i " instance
               " '" (format #f "~s" expr) "' 2>/dev/null"))
         (p (open-input-pipe cmd)))
    (let ((out (get-string-all p)))
      (close-pipe p)
      (string-trim-both out))))

;; The client prints "$12 = (#t #t #t)", and the number is a counter over the
;; whole session: it says how many expressions have been evaluated, not anything
;; about this one.  So a test compares what follows the last "=".
(define (answer-value answer)
  (let ((eq (string-rindex answer #\=)))
    (if eq (string-trim-both (substring answer (+ eq 1))) answer)))

(test-begin "live-shell")

(if (not (shell-running?))
    (begin
      ;; A plain marker as well as the srfi-64 skip.  srfi-64 prints NOTHING
      ;; for a suite whose only decision was to skip -- no summary line, no
      ;; "* SKIP" -- which is indistinguishable from a file that aborted
      ;; partway.  bin/run-tests greps for this line to tell the two apart.
      (display "*** LIVE-SHELL SKIPPED: no shell is listening ***\n")
      (test-skip "no shell is listening; start one with bin/scheme-desktop run"))
    (begin
      (test-group "the shell answers over its REPL"
        ;; (current-thread) being the GTK thread is the property M0.5's plan
        ;; singles out: a coop server that evaluated off-thread would work
        ;; until the first widget was touched.
        (test-assert "an expression comes back"
          (not (string-null? (eval-in-shell '(+ 1 2)))))
        (test-assert "and evaluates correctly"
          (string-contains (eval-in-shell '(* 6 7)) "42")))

      (test-group "the bar is really there"
        (test-assert "a window is named bar"
          (not (string-null?
                (eval-in-shell
                 '(begin (use-modules (scheme-toolkit app))
                         (map (lambda (w) (slot-ref w 'name)) (shell-windows)))))))
        ;; One per monitor.  The count is asserted as "at least one" so the
        ;; test is about the shell owning surfaces, not about how many screens
        ;; the machine happens to have.
        (test-assert "with a surface per monitor"
          (let ((answer (eval-in-shell
                         '(begin (use-modules (scheme-toolkit app))
                                 (length (widget-windows
                                         (desktop-widget-named 'bar)))))))
            ;; The client prints "$2 = 2", so take the number after the last
            ;; '='.  This also asserts the shell says the window exists on at
            ;; least one monitor -- how many screens the machine has is not
            ;; this test's business.
            (and (string? answer)
                 (let* ((eq (string-rindex answer #\=))
                        (text (and eq (string-trim-both (substring answer (+ eq 1))))))
                   (and text
                        (> (string-length text) 0)
                        (let ((n (string->number text)))
                          (and n (>= n 1)))))))))

      (test-group "the stylesheet reached the windows"
        ;; The palette is read from the desktop's theme, so the accent is a
        ;; real colour from this machine rather than a literal in the source.
        (test-assert "the palette has an accent"
          (string-contains
           (eval-in-shell '(begin (use-modules (scheme-desktop style)
                                               (scheme-toolkit palette))
                                  (palette-ref (shell-palette) 'accent)))
           "#"))
        (test-assert "the stylesheet parses without errors"
          (string-contains
           (eval-in-shell
            '(begin (use-modules (scheme-desktop style) (scheme-toolkit style)
                                 (srfi srfi-11))
                    (call-with-values
                     (lambda () (css-provider-for (shell-css)))
                     (lambda (p errs) (length errs)))))
           "0")))

      ;; WHERE A PANEL OPENS, asserted WITHOUT OPENING ONE.
      ;;
      ;; The placement is the arithmetic that puts a panel under its button, and
      ;; none of it needs the panel on screen: `popup-anchored!' is the call
      ;; `window-set-visible!' makes just before showing, so running it here
      ;; exercises the same path and leaves the desktop alone.  Worth the
      ;; trouble, because showing a panel from a test is not harmless -- the
      ;; menu's surface takes the KEYBOARD (`#:keymode 'exclusive'), so a test
      ;; that toggled it would lock the keyboard of whoever is sitting there.
      (test-group "a panel knows which window is its own"
        ;; THE BUG THIS CATCHES: a widget is `datemenu-panel' and its window is
        ;; `datemenu', and everything that follows a panel's visibility -- the
        ;; button's `active' class, the anchor lookup -- is keyed by the WINDOW's
        ;; name.  While `panel-button' used the widget's name instead, nothing
        ;; ever matched: the button's `active' class never appeared, so the
        ;; underline that says which panel is open could not appear either.
        (test-equal "the date menu's panel has a window named datemenu"
          "\"datemenu\""
          (answer-value
           (eval-in-shell '(begin (use-modules (scheme-toolkit app))
                                  (widget-window-name
                                   (desktop-widget-required 'datemenu-panel)))))))

      (test-group "a panel is placed under the bar, by its section"
        ;; A PANEL'S PLACE IS THREE FACTS, and these are the three, checked on a
        ;; window that is never shown: which edge the section gives it, the
        ;; clearance that puts it BELOW the bar rather than over it, and the
        ;; monitor the bar is on -- because a popup made once on one screen used
        ;; to open there whatever screen its button was on, which is what "it
        ;; covers the menu bar instead of going under it" turned out to be.
        ;; EVERY PLACEMENT ASSERTION IS MADE AGAINST THE COMPOSITOR'S OWN REPORT
        ;; OF WHERE THE BAR IS, because that is the thing the placement is
        ;; supposed to follow and the thing a window cannot be asked.  Exclusive
        ;; layer surfaces STACK: with another bar above ours, the bar is at y=82
        ;; with a height of 45 rather than at the screen's edge -- and a panel
        ;; placed at the height alone covers the bar instead of starting below it.
        (define (placement panel section)
          `(begin
             (use-modules (scheme-toolkit gi) (scheme-toolkit app) (oop goops))
             (define-gi-imports "Gtk" "Widget")
             (let* ((barwin (car (widget-windows (desktop-widget-required 'bar))))
                    (monitor (slot-ref barwin 'gdkmonitor))
                    (geom (monitor-geometry monitor))
                    (box ((@@ (scheme-desktop wm hyprland) bar-surface-box)
                          (monitor-name monitor)
                          (gtk-widget-get-width barwin)
                          (gtk-widget-get-height barwin)))
                    ;; The bar's rectangle re-based on its own monitor: the
                    ;; compositor reports x across the whole desk, so a bar 56
                    ;; pixels into the second screen reads as 1592.
                    (bar-x (- (list-ref box 0) (list-ref geom 0)))
                    (bar-w (list-ref box 2))
                    (mon-w (list-ref geom 2))
                    (pan (desktop-widget-required ',panel))
                    (win (widget-window pan))
                    (revealer (gtk-widget-get-first-child win))
                    (valign (slot-ref revealer 'valign)))
               (popup-anchor! (widget-window-name pan) ',section 'top
                              (+ (list-ref box 1) (list-ref box 3)) monitor box)
               (popup-anchored! win)
               (list
                ;; BELOW THE BAR: the clearance is the bar's far edge, and it
                ;; lands on whichever side the bar hangs from -- asked rather
                ;; than assumed, because the bar's edge is an option.
                (= (+ (list-ref box 1) (list-ref box 3))
                   (if (eq? valign 'end)
                       (slot-ref revealer 'margin-bottom)
                       (slot-ref revealer 'margin-top)))
                ;; AGAINST THE BAR SIDEWAYS, not the screen: a left panel is held
                ;; off the BAR's left edge, a right panel off the bar's right,
                ;; and a centred one sits on the bar's centre -- `(W + m) / 2'
                ;; for a centred widget, so that last one is `2c - W'.
                (case ',section
                  ((left) (and (eq? (slot-ref revealer 'halign) 'start)
                               (= (slot-ref revealer 'margin-start) bar-x)))
                  ((right) (and (eq? (slot-ref revealer 'halign) 'end)
                                (= (slot-ref revealer 'margin-end)
                                   (- mon-w (+ bar-x bar-w)))))
                  (else (and (eq? (slot-ref revealer 'halign) 'center)
                             (= (slot-ref revealer 'margin-start)
                                (inexact->exact
                                 (round (max 0 (- (* 2 (+ bar-x (/ bar-w 2))) mon-w))))))))
                ;; AND ON THE BAR'S MONITOR.
                (eq? (slot-ref win 'gdkmonitor) monitor)))))

        ;; EACH OF THE THREE SECTIONS, because they take three different pieces
        ;; of arithmetic and only one of them is exercised by any other test.
        (test-equal "a centre panel sits on the bar's centre, below it, on its monitor"
          "(#t #t #t)"
          (answer-value (eval-in-shell (placement 'datemenu-panel 'center))))
        (test-equal "a right panel is held off the bar's right edge"
          "(#t #t #t)"
          (answer-value (eval-in-shell (placement 'network-panel 'right))))
        (test-equal "a left panel is held off the bar's left edge"
          "(#t #t #t)"
          (answer-value (eval-in-shell (placement 'menu-panel 'left))))

        ;; AND IT ARRIVES WITHOUT AN ANIMATION, which is a decision rather than a
        ;; default: a panel belongs to a button on the bar, and a slide from the
        ;; screen's edge says it came from the edge instead.  Asserted because it
        ;; is the kind of thing that comes back the next time a popup is copied
        ;; from ags2-shell, whose position table carries a transition per corner.
        ;; A SYMBOL PRINTS BARE, as `none' rather than `"none"'.
        (test-equal "it appears rather than sliding in"
          "none"
          (answer-value
           (eval-in-shell
            '(begin (use-modules (scheme-toolkit gi) (scheme-toolkit app))
                    (define-gi-imports "Gtk" "Widget")
                    (slot-ref (gtk-widget-get-first-child
                               (widget-window (desktop-widget-required 'datemenu-panel)))
                              'transition-type)))))

        ;; THE POPUP WINDOW IS NOT PAINTED, so the desktop around the panel is
        ;; not dimmed -- which it was, because every window gets the theme's
        ;; background and a popup window is the size of the screen.
        ;;
        ;; THE CLASS LIST IS ASKED FOR BY NAME rather than compared whole: a
        ;; window that has been shown also carries `fullscreen', so the exact list
        ;; depends on whether the panel has been opened yet, and this test must
        ;; not care.
        (test-assert "and it does not paint the screen behind it"
          (let ((classes (answer-value
                          (eval-in-shell
                           '(begin (use-modules (scheme-toolkit gi) (scheme-toolkit app))
                                   (define-gi-imports "Gtk" "Widget")
                                   (gtk-widget-get-css-classes
                                    (widget-window
                                     (desktop-widget-required 'datemenu-panel))))))))
            (and (string-contains classes "popup-window")
                 (not (string-contains classes "dimmed")))))

      (test-group "a panel's section follows the bar, not the widget"
        ;; THE PANEL IS ALIGNED BY THE SECTION ITS BUTTON IS IN, and the bar is
        ;; the only thing that knows it.  Moving `workspaces` -- a left-section
        ;; widget -- to the right section is therefore a change the PLACEMENT has
        ;; to see, and it is the one arrangement a unit test on the toolkit
        ;; cannot see at all: both halves are in this shell.
        (define (section-of name)
          (answer-value
           (eval-in-shell
            `(begin (use-modules (scheme-toolkit app))
                    (widget-section (desktop-widget-required ',name))))))
        ;; A SYMBOL PRINTS BARE -- `left', not `"left"' -- because the client
        ;; prints values the way `write' would.
        (test-equal "the menu is a left item" "left" (section-of 'menu))
        (test-equal "the date menu is a centre item" "center" (section-of 'datemenu))
        (test-equal "the network is a right item" "right" (section-of 'network)))

      ;; THE MENU'S OWN SCROLLING, and only its arithmetic: GTK keeps the
      ;; FOCUSED child of a scrolled window in view and the menu's rows are
      ;; deliberately never focused -- the menu holds the keyboard and tracks a
      ;; cursor -- so the list has to be moved by hand as the cursor walks.
      ;;
      ;; THE ARITHMETIC IS TESTED AND THE MOVING IS NOT, on purpose: asserting
      ;; that the list really moves would mean opening the menu, whose surface
      ;; takes the keyboard, and a test may not do that to whoever is sitting at
      ;; the machine.  What is here is the part that can be wrong.
      (test-group "the bar's network item shows what its options say"
        ;; THE TWO OPTIONS AND THEIR RULES, asserted by READING THE LABELS rather
        ;; than by trusting the code: icon alone by default, the name as well when
        ;; asked for, and the icon STILL SHOWN when the name has it to itself and
        ;; there is no connection to name.
        ;;
        ;; THIS ALSO GUARDS A BUG THAT HID FOR A WHILE: a GtkButton has a single
        ;; child, so passing the icon and the name as two children of the button
        ;; meant the SECOND REPLACED THE FIRST -- no error, no gap in the tree,
        ;; just a bar item that had never once shown its icon.  The first line
        ;; here would have failed.
        (test-equal "icon alone, then both, then the name alone, then nothing"
          "((#t #f) (#t #t) (#f #t) (#f #f))"
          (answer-value
           (eval-in-shell
            '(begin
               (use-modules (scheme-toolkit gi) (scheme-toolkit app)
                            (scheme-toolkit config) (oop goops) (srfi srfi-1))
               (define-gi-imports "Gtk" "Widget")
               (define barwin (car (widget-windows (desktop-widget-required 'bar))))
               (define (kids w)
                 (let loop ((c (gtk-widget-get-first-child w)) (acc '()))
                   (if c (loop (gtk-widget-get-next-sibling c) (cons c acc))
                       (reverse acc))))
               (define (all w) (append (list w) (append-map all (kids w))))
               (define (shown? cls)
                 (let ((x (find (lambda (y) (member cls (gtk-widget-get-css-classes y)))
                                (all barwin))))
                   (and x (gtk-widget-get-visible x) #t)))
               (define (look) (list (shown? "network-icon") (shown? "network-ssid")))
               (define (opt k v) (widget-config-set! 'network k v))
               (let ((a (look)))
                 (opt 'show-wifi-name #t)
                 (let ((b (look)))
                   (opt 'show-wifi-icon #f)
                   (let ((c (look)))
                     (opt 'show-wifi-name #f)
                     (let ((d (look)))
                       ;; PUT BACK, so a test run leaves the user's config as it
                       ;; found it -- the defaults.
                       (opt 'show-wifi-icon #t)
                       (list a b c d))))))))))

      (test-group "the menu keeps its cursor on screen"
        (test-equal "the list moves the least it can to show the cursor"
          "(0 50 10 100)"
          (answer-value
           (eval-in-shell
            '(begin
               (define f (@@ (scheme-desktop widgets menu) scroll-value-for))
               (list (f 100 130 0 380)      ; on screen already: leave it alone
                     (f 400 430 0 380)      ; below the view: just far enough
                     (f 10 40 100 380)      ; above the view: up to the row
                     (f 100 130 100 380)))))))  ; at the very top edge: no move

      (test-group "the opener says where, and each kind says everything"
        ;; THE RULE: the thing opening a panel tells it where, and the panel never
        ;; goes asking.  A bar button says UNDER THE BAR (which section, which
        ;; edge, how far down); a keybinding says CENTRED, because it did not come
        ;; from the bar.
        ;;
        ;; AND EACH KIND MUST SAY EVERYTHING IT USES, which is what makes the menu
        ;; work when the same window is opened both ways: a menu centred once and
        ;; then opened from the bar kept the centred alignment's VALIGN, which put
        ;; it in the middle of the screen with a margin under the bar.  Asserted by
        ;; alternating the two and asking whether the first answer comes back.
        (test-equal "under the bar, then centred, then under the bar again"
          "(#t #t #t)"
          (answer-value
           (eval-in-shell
            '(begin
               (use-modules (scheme-toolkit gi) (scheme-toolkit app))
               (define-gi-imports "Gtk" "Widget")
               (let* ((barwin (car (widget-windows (desktop-widget-required 'bar))))
                      (monitor (slot-ref barwin 'gdkmonitor))
                      (box ((@@ (scheme-desktop wm hyprland) bar-surface-box)
                            (monitor-name monitor)
                            (gtk-widget-get-width barwin)
                            (gtk-widget-get-height barwin)))
                      (edge (+ (list-ref box 1) (list-ref box 3)))
                      (win (widget-window (desktop-widget-required 'menu-panel)))
                      (revealer (gtk-widget-get-first-child win))
                      (state (lambda ()
                               (list (slot-ref revealer 'halign)
                                     (slot-ref revealer 'valign)
                                     (slot-ref revealer 'margin-start)
                                     (slot-ref revealer 'margin-top))))
                      (at-bar (lambda ()
                                (popup-anchor! "menu" 'left 'top edge monitor box)
                                (popup-anchored! win)
                                (state)))
                      (centred (lambda ()
                                 (popup-anchor-centred! "menu" monitor)
                                 (popup-anchored! win)
                                 (state))))
                 (let ((first (at-bar)) (middle (centred)) (last (at-bar)))
                   (list (equal? first last)
                         (equal? middle (list 'center 'center 0 0))
                         (= (list-ref first 3) edge)))))))))

      (test-group "the menu is as tall as the room it has"
        ;; THE LIST TAKES THE ROOM IT NEEDS AND ONLY SCROLLS WHEN IT RUNS OUT.
        ;; It used to be capped at a fixed 380 -- `about ten rows' -- which is the
        ;; wrong question: twelve items on a screen with room for thirty should
        ;; show twelve.  The room is the toolkit's answer (`popup-available-height'
        ;; -- the screen less the bar's edge), so this asserts it against the
        ;; bar's real position rather than against a number.
        (test-equal "the room is the screen above the bar's far edge"
          "(#t)"
          (answer-value
           (eval-in-shell
            '(begin
               (use-modules (scheme-toolkit gi) (scheme-toolkit app))
               (define-gi-imports "Gtk" "Widget")
               (let* ((barwin (car (widget-windows (desktop-widget-required 'bar))))
                      (monitor (slot-ref barwin 'gdkmonitor))
                      (geom (monitor-geometry monitor))
                      (box ((@@ (scheme-desktop wm hyprland) bar-surface-box)
                            (monitor-name monitor)
                            (gtk-widget-get-width barwin)
                            (gtk-widget-get-height barwin)))
                      (edge (+ (list-ref box 1) (list-ref box 3)))
                      (win (widget-window (desktop-widget-required 'menu-panel))))
                 ;; Anchored as a click would anchor it, so the answer is the
                 ;; real one and not the no-anchor fallback.
                 (popup-anchor! "menu" 'left 'top edge monitor box)
                 (list (= (popup-available-height win)
                          (- (list-ref geom 3) edge)))))))))

      (test-group "control verbs work"
        ;; toggle-widget is the whole of AGS's ToggleWindow, and it is also the
        ;; cheapest proof that the registry and the visibility path agree.
        (test-assert "toggling the bar hides and shows it"
          (let* ((before (eval-in-shell
                          '(begin (use-modules (scheme-toolkit app))
                                  (widget-visible? (desktop-widget-named 'bar)))))
                 (hidden (eval-in-shell
                          '(begin (use-modules (scheme-toolkit app))
                                  (toggle-widget 'bar))))
                 (shown (eval-in-shell
                         '(begin (use-modules (scheme-toolkit app))
                                 (toggle-widget 'bar)))))
            (and (not (string-null? before))
                 (not (string-null? hidden))
                 (not (string-null? shown)))))))))

      ;; THE MODEL AGAINST THE SCREEN, which is the check this whole file was
      ;; missing: every other assertion here compares records to records.
      ;;
      ;; AND IT HAS TO MAKE A WIDGET LEAVE A SECTION, because that is where the
      ;; duplicate came from.  The departure path was broken: the departed tree
      ;; was never taken out of the box -- `destroy' has no method for a plain
      ;; box or button, so it threw `No applicable method' and the catch swallowed
      ;; it -- and the screen kept a child the model had dropped.  When that
      ;; widget came back, a new tree was appended beside the old one: a SECOND
      ;; MENU BUTTON on the far left, on screen and in no record anywhere.
      ;;
      ;; SO A RE-LOOK IS NOT ENOUGH.  That is how this was written first, and why
      ;; it was worthless: a re-look with nothing departing never reaches the
      ;; broken branch and passes either way.  Proved by reinstating the bug and
      ;; watching this file stay green.
      (define boxes-vs-model
        '(begin
           (use-modules (scheme-toolkit app))
           (let* ((bm (resolve-module '(scheme-desktop widgets bar)))
                  (w (desktop-widget-required 'bar))
                  (sections ((module-ref bm 'bar-sections) w))
                  (trees ((module-ref bm 'bar-trees) w))
                  (widgets-in (module-ref bm 'widgets-in)))
             (define (kids box)
               (let loop ((c (gtk-widget-get-first-child box)) (acc '()))
                 (if (not c)
                     (reverse acc)
                     (loop (gtk-widget-get-next-sibling c) (cons c acc)))))
             (let ((rows
                    (append-map
                     (lambda (out)
                       (let* ((output (car out))
                              (boxes (cdr out))
                              (recorded (or (assoc-ref trees output) '())))
                         (map (lambda (position)
                                (let* ((box (assoc-ref boxes position))
                                       (real (map object-address (kids box)))
                                       (want (map (lambda (p) (object-address (cdr p)))
                                                  (or (assoc-ref recorded position) '())))
                                       (model (length (widgets-in w position))))
                                  (list output position model (length real)
                                        (and (= model (length real))
                                             (equal? real want)))))
                              '(left center right))))
                     sections)))
               (let ((bad (filter (lambda (row) (not (list-ref row 4))) rows)))
                 (if (null? bad)
                     "every section box matches its layout"
                     bad))))))

      (define (boxes-match?)
        (string-contains (eval-in-shell boxes-vs-model)
                         "every section box matches its layout"))

      (test-group "the bar's boxes match its layout"
        ;; THE LAYOUT IS CHANGED AND PUT BACK, and that is the one thing in this
        ;; file that touches the shell's state: a real option, really changed,
        ;; which the engine writes to the user's config.  The restore is its OWN
        ;; assertion rather than a conditional, so it happens whether the check
        ;; before it passed or not.
        (test-assert "a widget leaving a section takes its box with it"
          (and (not (string-null?
                     (eval-in-shell
                      '(begin
                         (use-modules (scheme-toolkit config))
                         ;; `workspaces' leaves the left section: a departure.
                         (widget-config-set! 'bar 'layout
                                             '((left menu)
                                               (center datemenu)
                                               (right media tray network bluetooth volume battery)))
                         "changed"))))
               (boxes-match?)))

        (test-assert "and an arriving one does not find the old box still there"
          (and (not (string-null?
                     (eval-in-shell
                      '(begin
                         (use-modules (scheme-toolkit config))
                         (widget-config-set! 'bar 'layout
                                             '((left menu workspaces)
                                               (center datemenu)
                                               (right media tray network bluetooth volume battery)))
                         "restored"))))
               (boxes-match?))))

(test-end "live-shell")
