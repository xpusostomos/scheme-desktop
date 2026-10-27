;;; tests/style-classes.scm -- the stylesheet and the widgets must agree
;;;
;;; A CSS rule for a class nothing emits is dead text.  It reads as though the
;;; feature exists -- .battery.low looks like low batteries go red -- and the
;;; only way to notice is to grep the source of both halves, which nobody does.
;;;
;;; This asserts the direction that is cheap to check: every class the
;;; stylesheet targets is named somewhere in the widget code.  The reverse
;;; (every widget class is styled) is not a failure, only a missed opportunity.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit file))
(use-modules (srfi srfi-1))
(use-modules (srfi srfi-13))
(use-modules (srfi srfi-64))

;; LOCATING THE CHECKOUT.  The suite is run three ways -- by hand from the repo,
;; from tests/, and by bin/run-tests from the toolkit repo -- so no single
;; assumption about the current directory holds, and (current-filename) is
;; unusable (it is RELATIVE under -s, and #f under -c).
;;
;; So a small set of CANDIDATE roots is tried, each checked for a marker file,
;; and the first that exists wins.  Candidates are the directories the suite is
;; plausibly run from or installed into, plus an explicit override.
;;
;; This is deliberately dumb: it verifies every candidate rather than
;; deriving one from a path computation, because a path computation that is
;; subtly wrong fails by producing an empty stylesheet and a check that
;; silently passes over nothing -- which is worse than an error.
(define (repo-dir? d)
  "Is D the scheme-desktop REPO (which holds the package of the same name)?"
  (and d (file-exists? (string-append d "/scheme-desktop/style.scm"))))

(define (repo-candidates)
  (let ((cwd (getcwd)))
    (filter (lambda (c) (and c (not (string=? c ""))))
            (list
             ;; An explicit override, for a caller that knows.
             (getenv "SCHEME_DESKTOP_ROOT")
             ;; The current directory and a few levels up: covers a run from
             ;; the repo, from tests/, or from inside the package.
             cwd
             (dirname cwd)
             (dirname (dirname cwd))
             (dirname (dirname (dirname cwd)))
             ;; The sibling of wherever we are: a run from the toolkit repo.
             (string-append cwd "/../scheme-desktop")
             (string-append (dirname cwd) "/scheme-desktop")
             (string-append (dirname (dirname cwd)) "/scheme-desktop")
             ;; The package directory itself.
             (string-append cwd "/scheme-desktop")))))

(define repo-dir
  (or (find repo-dir? (repo-candidates))
      (error "style-classes: cannot find the scheme-desktop checkout; \
run the suite from that repo, or set SCHEME_DESKTOP_ROOT")))

(define package-dir (string-append repo-dir "/scheme-desktop"))

(define (read-source path)
  (or (read-file path) ""))

(define toolkit-root
  ;; The SIBLING checkout's package directory.  The two repos sit side by side
  ;; under a common parent, each holding a module directory of its own name:
  ;;
  ;;   <parent>/scheme-desktop/scheme-desktop/    this shell's modules
  ;;   <parent>/scheme-toolkit/scheme-toolkit/    the toolkit's
  ;;
  ;; A class this shell styles may be emitted by a toolkit widget -- the tray
  ;; moved there -- so the check has to look in both.
  (string-append (dirname repo-dir) "/scheme-toolkit/scheme-toolkit"))

(define (widget-files)
  (let ((dir (string-append package-dir "/widgets")))
    (append
     (list (string-append package-dir "/widgets/bar.scm"))
     (map (lambda (name) (string-append dir "/bar/" name))
          '("workspaces.scm" "status.scm" "volume.scm" "network.scm"
            "bluetooth.scm" "media.scm" "clock.scm"))
     ;; TOOLKIT widgets too.  The tray moved there -- it is protocol handling
     ;; rather than a decision this shell made -- and it emits `tray',
     ;; `tray-item', `tray-menu', `model-item' and `check'.  Without this the
     ;; check would report every class the tray styles as unemitted, which is
     ;; the opposite of the truth.
     (map (lambda (name) (string-append toolkit-root "/" name))
          '("tray.scm" "widget.scm")))))

;; Every `.name' that appears in a SELECTOR.  Scanning for the `.name' shape
;; rather than parsing selectors properly: the question here is only "does any
;; widget mention this name", and a real CSS parser would be more code than the
;; check is worth.  Declarations are excluded by ignoring anything after a
;; '{' on the same line, so a value like rgba(0,0,0,.5) cannot look like a
;; class.
(define (stylesheet-class-names)
  (let* ((css (read-source (string-append package-dir "/style.scm")))
         (selector-text
          (string-join
           (filter-map (lambda (line)
                         (let ((trimmed (string-trim-both line #\space)))
                           ;; Skip declarations and comments; keep selectors.
                           (and (string-index line #\{)
                                (not (string-prefix? "/*" trimmed))
                                (not (string-index trimmed #\:))
                                (car (string-split line #\{)))))
                       (string-split css #\newline))
           " ")))
    (delete-duplicates
     (let loop ((i 0) (found '()))
       (cond ((>= i (- (string-length selector-text) 1)) (reverse! found))
             ((char=? (string-ref selector-text i) #\.)
              (let name-loop ((j (+ i 1)))
                (cond ((>= j (string-length selector-text))
                       (loop j (cons (substring selector-text (+ i 1) j) found)))
                      ((or (char-alphabetic? (string-ref selector-text j))
                           (char-numeric? (string-ref selector-text j))
                           (char=? (string-ref selector-text j) #\-))
                       (name-loop (+ j 1)))
                      (else
                       (loop j (cons (substring selector-text (+ i 1) j) found))))))
             (else (loop (+ i 1) found)))))))

(define (emitted? class)
  (let loop ((files (widget-files)))
    (cond ((null? files) #f)
          ((string-contains (read-source (car files)) (string-append "\"" class))
           #t)
          ((string-contains (read-source (car files)) class) #t)
          (else (loop (cdr files))))))

(test-begin "style-classes")

(test-group "every styled class is emitted by a widget"
  (let ((classes (stylesheet-class-names)))
    (test-assert "some classes were found at all" (pair? classes))
    (for-each
     (lambda (class)
       ;; Two kinds of exception, both meaning "not a widget file says this".
       ;;
       ;;   Bar          this shell's window class, set by widgets/bar.scm
       ;;   accelerator  emitted by GTK ITSELF -- GtkModelButton puts it on the
       ;;                accelerator label it builds for a menu item.  Styling
       ;;                it is legitimate and no file of ours names it, so the
       ;;                test's premise ("a widget says this") does not hold.
       ;;
       ;; Anything else is still a failure: that IS how the styled-but-never-
       ;; emitted classes .battery.low and .unavailable were caught.
       (unless (member class '("Bar" "accelerator"))
         (test-assert (format #f "~a is emitted somewhere" class)
           (emitted? class))))
     classes)))

(test-group "the classes this shell relies on exist"
  ;; Named individually as well: if the extractor above breaks, these still
  ;; fail rather than silently passing over an empty list.
  (for-each
   (lambda (class)
     (test-assert (format #f "~a is styled" class)
       (string-contains (read-source (string-append package-dir "/style.scm"))
                        (string-append "." class))))
   '("battery" "battery-label" "clock" "workspace" "bar-start" "bar-end"))
  (test-assert "the low-battery state class is styled"
    (string-contains (read-source (string-append package-dir "/style.scm"))
                     ".battery.low"))
  (test-assert "and emitted"
    (emitted? "low"))
  (test-assert "the unavailable state class is styled"
    (string-contains (read-source (string-append package-dir "/style.scm"))
                     ".unavailable"))
  (test-assert "and emitted"
    (emitted? "unavailable")))

(test-end "style-classes")
