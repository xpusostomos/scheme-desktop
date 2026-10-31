;;; tests/bluetooth.scm -- the bluetooth widget's rules, and the traps under it
;;;
;;; Two kinds of assertion here.  The first kind is PURE: the three-glyph rule and
;;; the \"a name that is not a name\" rule, both of which are decisions this shell
;;; makes and neither of which needs a Bluetooth device to check.
;;;
;;; The second kind guards the two G-Golf traps that (scheme-toolkit services
;;; bluetooth) exists to hide, because both of them fail SILENTLY:
;;;
;;;   - a GList-valued property read through `slot-ref' gives an opaque pointer,
;;;     and `as-list' of that is '() -- so a panel built that way shows NO
;;;     DEVICES, FOREVER, WITH NO ERROR.  `bluetooth-devices' must always be a
;;;     proper list, and that is asserted whatever the machine has.
;;;   - Astal says -1.0 for \"this device does not report a battery\", so a widget
;;;     that trusts `number?' draws \"-100%\" on almost every row.  The battery
;;;     reader must answer #f or a fraction.
;;;
;;; NOTHING HERE TOUCHES THE RADIO.  Starting a scan or switching the adapter
;;; would make this suite change the state of the machine it runs on -- and would
;;; stop a scan somebody else started -- so the scanning code is exercised by
;;; hand and its measurement is written up in the service module.
;;;
;;; Run from the scheme-desktop repo, or by ../scheme-toolkit/bin/run-tests
;;; --with-desktop.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit file))
(use-modules (scheme-toolkit widget))
(use-modules (scheme-toolkit app))
(use-modules (scheme-toolkit services bluetooth))
(use-modules (scheme-desktop widgets bluetooth))
(use-modules (oop goops))
(use-modules (srfi srfi-1))
(use-modules (srfi srfi-13))
(use-modules (srfi srfi-64))
(use-modules (ice-9 format))

;; FINDING THE CHECKOUT, by looking rather than by deriving -- the same candidate
;; list tests/style-classes.scm uses, and for the same reason: a path computation
;; that is subtly wrong fails by finding NOTHING and passing over it.
(define (repo-dir? d)
  (and d (file-exists? (string-append d "/scheme-desktop/style.scm"))))

(define (candidate-roots)
  (let ((cwd (getcwd)))
    (filter (lambda (c) (and c (not (string=? c ""))))
            (list (getenv "SCHEME_DESKTOP_ROOT")
                  cwd
                  (dirname cwd)
                  (dirname (dirname cwd))
                  (string-append cwd "/../scheme-desktop")
                  (string-append (dirname cwd) "/scheme-desktop")
                  (string-append (dirname (dirname cwd)) "/scheme-desktop")
                  (string-append cwd "/scheme-desktop")))))

(define (codepoint-of glyph)
  "The single codepoint in GLYPH, as an integer -- Nerd Font glyphs are one
character, and a table built with the wrong escape is two."
  (and (string? glyph) (= 1 (string-length glyph))
       (char->integer (string-ref glyph 0))))

;; GTK must be up before any widget is made.  This suite makes one, hidden.
(gtk-bootstrap!)

(test-begin "bluetooth")

;;; ---------------------------------------------------------------------------
;;; The three-glyph rule
;;; ---------------------------------------------------------------------------

;; Omarchy's `icon' rule, codepoint for codepoint.  Asserted as INTEGERS because
;; the point of the rule is which of three glyphs comes out, and three glyphs
;; that look similar in a terminal are exactly how a table built with `"\U..."'
;; escapes -- which are not escapes -- goes unnoticed.
(test-group "the bar glyph says which of three states the radio is in"
  (test-equal "off is the crossed-out radio" #x0F00B2
    (codepoint-of (bluetooth-glyph #f #f)))
  (test-equal "on with nothing attached is the plain radio" #x0F00AF
    (codepoint-of (bluetooth-glyph #t #f)))
  (test-equal "on with something connected is the marked radio" #x0F00B1
    (codepoint-of (bluetooth-glyph #t #t)))
  (test-assert "off wins over connected, as in Omarchy's branch order"
    (= #x0F00B2 (codepoint-of (bluetooth-glyph #f #t)))))

;;; ---------------------------------------------------------------------------
;;; A name that is not a name
;;; ---------------------------------------------------------------------------

(test-group "a device name that is really an identifier gets no row"
  (for-each
   (lambda (name)
     (test-assert (format #f "~s is not a name" name) (bluetooth-name-unusable? name)))
   ;; Every one of these was seen on this machine or is BlueZ's own shape.  The
   ;; dashed address is the real one: a scan here turned up a device calling
   ;; itself `66-3C-C3-BF-6F-C0', and it must stay out of the lists.
   (list "66-3C-C3-BF-6F-C0"
         "D0:56:FB:77:A0:B1"
         "00000000000000000000000000000000"
         "0x000000000000abcd"
         ""
         "   "))
  (for-each
   (lambda (name)
     (test-assert (format #f "~s is a name" name) (not (bluetooth-name-unusable? name))))
   (list "Chris's Buds3 Pro" "Sony WH-1000XM4" "p14s-om" "Living Room TV")))

;;; ---------------------------------------------------------------------------
;;; The traps under the service
;;; ---------------------------------------------------------------------------

(test-group "the device list is a LIST, whatever the machine has"
  ;; This is the assertion that matters most in this file.  The property path
  ;; (`slot-ref' on a GList-valued property) answers a pointer, `as-list' of a
  ;; pointer is '(), and the panel then draws nothing with no error anywhere --
  ;; the same shape of bug that once emptied the wifi list and killed the shell
  ;; while the bar was being assembled.
  (let ((devices (bluetooth-devices)))
    (test-assert "is a proper list" (list? devices))
    (test-assert "is never #f" (not (eq? devices #f)))
    (test-assert "every element is a device object"
      (every (lambda (d) (is-a? d <gobject>)) devices))))

(test-group "every device reads safely"
  (let ((devices (bluetooth-devices)))
    (test-assert "each has a non-empty label"
      (every (lambda (d)
               (let ((label (bluetooth-device-label d)))
                 (and (string? label) (not (string-null? label)))))
             devices))
    ;; -1.0 IS NOT A BATTERY LEVEL.  Astal answers it for every device that does
    ;; not publish one, which is most of them, and a widget that trusts
    ;; `number?' prints "-100%".
    (test-assert "each battery is #f or a fraction"
      (every (lambda (d)
               (let ((b (bluetooth-device-battery d)))
                 (or (not b) (and (number? b) (>= b 0) (<= b 1)))))
             devices))
    (test-assert "each glyph is one of the two row glyphs"
      (every (lambda (d)
               (memv (codepoint-of (bluetooth-device-glyph d))
                     (list #x0F00B1 #x0F00AF)))
             devices))))

(test-group "the groups partition the named devices"
  (let* ((groups (bluetooth-device-groups))
         (connected (cdr (assq 'connected groups)))
         (known (cdr (assq 'known groups)))
         (discovered (cdr (assq 'discovered groups))))
    (test-assert "the three groups are present"
      (and (list? connected) (list? known) (list? discovered)))
    ;; Disjoint and complete: a device that is in two groups is drawn twice, and
    ;; one in none is a device the panel silently hides.
    (test-equal "no device is in two groups"
      (length (append connected known discovered))
      (length (delete-duplicates (append connected known discovered))))
    (test-equal "every human-named device is in exactly one group"
      (length (filter bluetooth-human-name? (bluetooth-devices)))
      (length (append connected known discovered)))
    (test-assert "a connected device is not also listed as known"
      (not (any (lambda (d) (memq d known)) connected)))
    ;; Climbing out of the service's view: the same list, reached the slow way.
    (test-assert "the connected group is exactly the connected devices"
      (every bluetooth-device-connected? connected))))

;;; ---------------------------------------------------------------------------
;;; The panel
;;; ---------------------------------------------------------------------------

(define (descendants w)
  "Every widget below W, recursively.

A NAMED `let' AND NO `append-map': (scheme-toolkit gi) rebinds `map' and `append'
to GTK generics in this module, and Guile's inliner copies small procedures like
`append-map' into the caller -- where they then call GTK's `map'.  The symptom is
`wrong-type-arg (\"map\" ... (#f))` and, inside a catch, an empty answer that looks
like \"no widgets\", which is how the same mistake made style-classes.scm report
every CSS class as unemitted."
  (let loop ((c (gtk-widget-get-first-child w)) (acc '()))
    (if (not c)
        (reverse acc)
        (loop (gtk-widget-get-next-sibling c)
              (let inner ((d (descendants c)) (a (cons c acc)))
                (if (null? d) a (inner (cdr d) (cons (car d) a))))))))

(define (classes-of x)
  (let ((cs (catch #t (lambda () (slot-ref x 'css-classes)) (lambda args '()))))
    (if (list? cs)
        (let loop ((cs cs) (acc '()))
          (if (null? cs) (reverse acc)
              (loop (cdr cs)
                    (cons (if (string? (car cs)) (car cs) (symbol->string (car cs))) acc))))
        '())))

(define (texts win)
  "Every non-empty label in the tree under WIN."
  (let loop ((xs (descendants win)) (acc '()))
    (if (null? xs)
        (reverse acc)
        (let ((t (catch #t (lambda () (slot-ref (car xs) 'label)) (lambda args #f))))
          (loop (cdr xs)
                (if (and (string? t) (not (string-null? t))) (cons t acc) acc))))))

(test-group "the panel builds, and its window has the name the stylesheet uses"
  (let* ((w (make <bluetooth-panel-desktop-widget>))
         (win (widget-window w))
         (inside (descendants win)))
    ;; THE NAME IS A CSS SCOPE.  Every rule for this panel is written
    ;; `window#bluetooth ...', so a rename here silently unstyles the whole
    ;; panel -- and a stylesheet that matches nothing is not an error GTK
    ;; reports.
    (test-equal "the window is named bluetooth" "bluetooth"
      (catch #t (lambda () (slot-ref win 'name)) (lambda args #f)))
    (test-assert "the window is not shown by being built"
      (not (catch #t (lambda () (slot-ref win 'visible)) (lambda args #t))))
    (test-assert "the panel card is in the tree"
      (any (lambda (x) (member "bluetooth-panel" (classes-of x))) inside))
    (test-assert "the hero says which radio it is"
      (member "Bluetooth" (texts win)))
    ;; THE SWITCH IS THE ONLY WAY TO CHANGE THE RADIO, as in Omarchy's panel, so
    ;; a panel that built without one would be a panel you can only look at.
    (test-assert "the radio switch is there"
      (any (lambda (x) (is-a? x <gtk-switch>)) inside))
    (test-assert "the scan control is there"
      (any (lambda (x) (member "bluetooth-scan-button" (classes-of x))) inside))))

(test-group "the panel's width is fixed, and cannot be pushed by its contents"
  (let* ((w (make <bluetooth-panel-desktop-widget>))
         (win (widget-window w))
         (width ((widget-slot-ref w 'width))))
    ;; THE BUG THIS GUARDS: the panel used to be sized by its content, and the
    ;; hero's status line is a different length in every state -- "On, nothing
    ;; connected" / "Scanning for devices…" / "Connected to <device>" -- so the
    ;; card changed width and re-laid-out its widgets whenever the radio changed
    ;; what it was doing.  A fixed request plus ellipsized text is what stops it.
    (test-assert "the width option is a positive number"
      (and (number? width) (> width 0)))
    (test-assert "the card requests exactly that width"
      (any (lambda (x) (equal? width (catch #t (lambda () (slot-ref x 'width-request))
                                            (lambda args #f))))
           (descendants win)))
    ;; AND SO DOES THE BOX THAT SURVIVES A REBUILD.  The tree inside is
    ;; destroyed and rebuilt on every refresh; for that instant the box is
    ;; empty, and a width living only on the rebuilt card made the panel
    ;; collapse and spring back -- the flicker seen on a click.  Measured: the
    ;; card was a stable 380, so the movement was never a new size.
    (test-assert "the persistent content box carries the width too"
      (let* ((revealer (gtk-widget-get-first-child win))
             (box (gtk-widget-get-first-child revealer)))
        (equal? width (catch #t (lambda () (slot-ref box 'width-request))
                             (lambda args #f)))))
    ;; THE ELLIPSIS IS LOAD-BEARING, not cosmetic: without it a label longer than
    ;; the request wins over the request and the panel grows after all.
    (test-assert "the hero's status phrase is ellipsized"
      (any (lambda (x)
             (and (member "bluetooth-hero-meta" (classes-of x))
                  (eq? 'end (catch #t (lambda () (slot-ref x 'ellipsize))
                                  (lambda args #f)))))
           (descendants win)))
    (test-assert "device names are ellipsized too"
      (any (lambda (x)
             (and (member "bluetooth-row-name" (classes-of x))
                  (eq? 'end (catch #t (lambda () (slot-ref x 'ellipsize))
                                  (lambda args #f)))))
           (descendants win)))
    ;; THE OTHER HALF, and the one the first fix missed: `width-request' is a
    ;; FLOOR, so anything inside that reports a larger natural width still grows
    ;; the card.  Clicking a device adds a spinner and a "Connecting…" line, the
    ;; row's natural width grows, and the GtkScrolledWindow propagates it up.
    ;; Measured after the first fix: the panel still widened on a device click.
    (test-assert "the list does not propagate the rows' width upward"
      (any (lambda (x)
             (and (member "bluetooth-scroll" (classes-of x))
                  (eq? #f (catch #t (lambda () (slot-ref x 'propagate-natural-width))
                                 (lambda args 'n/a)))))
           (descendants win)))
    ;; AND THE SPINNER IS ALWAYS ALLOCATED, so the row does not change shape as
    ;; a connection starts: a non-spinning GtkSpinner draws nothing but still
    ;; takes its space.
    (test-assert "the per-row spinner is allocated even when idle"
      (any (lambda (x)
             (and (member "bluetooth-row-spinner" (classes-of x))
                  (eq? #t (catch #t (lambda () (slot-ref x 'visible)) (lambda args #f)))))
           (descendants win)))))

(test-group "the stylesheet and this window name agree"
  (let* ((root (find repo-dir? (candidate-roots)))
         (css (and root (read-file (string-append root "/scheme-desktop/style.scm")))))
    (test-assert "style.scm was found and read" (and css (string? css)
                                                    (> (string-length css) 1000)))
    (when (and css (string? css))
      ;; The check style-classes.scm does not make: it checks that a CLASS is
      ;; emitted by widget code, but a WINDOW name is a scope rather than a
      ;; class, so a renamed window leaves every rule matching nothing.
      (test-assert "the bar item's glyph is styled" (string-contains css ".bluetooth-icon"))
      (test-assert "the panel is scoped to window#bluetooth"
        (string-contains css "window#bluetooth .bluetooth-panel"))
      (test-assert "the radio switch is styled too"
        (string-contains css "window#bluetooth switch")))))

(test-end "bluetooth")
