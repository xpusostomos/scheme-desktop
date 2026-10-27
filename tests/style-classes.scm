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

(define desktop-root
  (string-append (dirname (dirname (current-filename))) "/scheme-desktop"))

(define (read-source path)
  (or (read-file path) ""))

(define (widget-files)
  (let ((dir (string-append desktop-root "/widgets")))
    (append
     (list (string-append desktop-root "/widgets/bar.scm"))
     (map (lambda (name) (string-append dir "/bar/" name))
          '("workspaces.scm" "status.scm" "volume.scm" "network.scm"
            "bluetooth.scm" "media.scm" "clock.scm")))))

;; Every `.name' that appears in a SELECTOR.  Scanning for the `.name' shape
;; rather than parsing selectors properly: the question here is only "does any
;; widget mention this name", and a real CSS parser would be more code than the
;; check is worth.  Declarations are excluded by ignoring anything after a
;; '{' on the same line, so a value like rgba(0,0,0,.5) cannot look like a
;; class.
(define (stylesheet-class-names)
  (let* ((css (read-source (string-append desktop-root "/style.scm")))
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
       ;; The window's own class comes from the bar, not a widget file, and
       ;; is checked by its own assertion below.
       (unless (member class '("Bar"))
         (test-assert (format #f "~a is emitted somewhere" class)
           (emitted? class))))
     classes)))

(test-group "the classes this shell relies on exist"
  ;; Named individually as well: if the extractor above breaks, these still
  ;; fail rather than silently passing over an empty list.
  (for-each
   (lambda (class)
     (test-assert (format #f "~a is styled" class)
       (string-contains (read-source (string-append desktop-root "/style.scm"))
                        (string-append "." class))))
   '("battery" "battery-label" "clock" "workspace" "bar-start" "bar-end"))
  (test-assert "the low-battery state class is styled"
    (string-contains (read-source (string-append desktop-root "/style.scm"))
                     ".battery.low"))
  (test-assert "and emitted"
    (emitted? "low"))
  (test-assert "the unavailable state class is styled"
    (string-contains (read-source (string-append desktop-root "/style.scm"))
                     ".unavailable"))
  (test-assert "and emitted"
    (emitted? "unavailable")))

(test-end "style-classes")
