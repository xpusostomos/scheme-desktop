;;; (scheme-desktop dump-menu) -- write the whole menu out, settings included.
;;;
;;; The menu as the shell opens it: Omarchy's rows, plus the Settings row
;;; generated from every widget the config file makes live, spliced in after
;;; `system'.  Written as s-expressions, one entry per line, so the file can be
;;; read back and looked at.
;;;
;;; TWO CALLERS, ONE PIECE OF CODE.  `tools/dump-menu.scm' is the command line
;;; (`scheme-desktop dump-menu [FILE]'), and a REPL inside a running shell is
;;; the other:
;;;
;;;     (import (scheme-desktop dump-menu))
;;;     (dump-menu "/tmp/menu.scm")
;;;
;;; The difference is which widgets are asked for their options: a running shell
;;; has its registry (`desktop-widgets', from `(scheme-toolkit app)'), and a
;;; fresh process has none, so it makes the ones the config names.  `shell-widgets'
;;; is that choice, made once.
;;;
;;; A ROW'S `value' AND `action' ARE PROCEDURES, and `write' prints a procedure as
;;; `#<procedure …>' -- which cannot be read back.  They are named in the settings
;;; module (`read-option', `write-option') and written here as
;;; `(option-function read-option)', so the dump stays valid, inspectable Scheme.

(define-module (scheme-desktop dump-menu)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (oop goops)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-desktop menu)
  #:use-module (scheme-desktop settings-menu)
  #:use-module (scheme-desktop manifest)
  #:export (dump-menu write-menu menu-with-settings shell-widgets live-widgets))

;;; ---------------------------------------------------------------------------
;;; The widgets the config makes live
;;; ---------------------------------------------------------------------------

(define (live-widgets)
  "Every widget the config file names, made -- the set the shell starts with,
minus the root, which makes the rest.

For a process with NO shell: the registry is empty there, so the config is the
only way to know which widgets exist."
  (add-plugin-load-paths!)
  (let ((names (config-root-widgets (ensure-config!))))
    (filter-map (lambda (n)
                  (catch #t
                    (lambda ()
                      (let ((w (make (widget-class-named n))))
                        ;; The QUALIFIED NAME is what the root sets on each
                        ;; widget; without it `widget-name' derives a short one and
                        ;; the row keys here would differ from the shell's.
                        (slot-set! w 'qualified-name n)
                        w))
                    (lambda (key . args)
                      (format (current-error-port) ";; cannot make ~s: ~a~%" n key)
                      #f)))
                names)))

(define (shell-widgets)
  "The widgets a RUNNING shell has, or the config's when there is no shell.

THE REGISTRY IS THE TRUTH WHEN IT KNOWS ANYTHING: a live shell may have widgets
the config does not name yet (a plugin enabled at runtime), and those are exactly
the ones a dump is being used to look at."
  (let ((running (catch #t desktop-widgets (lambda args '()))))
    (if (pair? running) running (live-widgets))))

;;; ---------------------------------------------------------------------------
;;; The menu
;;; ---------------------------------------------------------------------------

(define* (menu-with-settings #:optional (widgets (shell-widgets)))
  "The whole menu: the menu in use, with Settings generated from WIDGETS spliced
in after the top-level row called `system'.  #f when there is no such row.

`menu-splice' answers #f rather than silently doing nothing, and a caller has to
know -- a dump that quietly writes the menu WITHOUT the settings would be the
exact thing this is for."
  (menu-splice (menu)
               (list 'key 'settings 'label "Settings"
                     'submenu (settings-menu-entries widgets))
               '("system")))

;;; ---------------------------------------------------------------------------
;;; Writing
;;; ---------------------------------------------------------------------------

(define (printable datum)
  "DATUM with every procedure replaced by a readable marker.

A row's two procedures are the only ones in a menu, and what matters about them
is that the row HAS one, not which closure it is."
  (cond
   ((procedure? datum)
    ;; A LIST, not a string: `(option-function)` reads back as data and says what
    ;; the row would do.  `#<procedure …>' is a reader ERROR, and a quoted string
    ;; would be a lie about the type -- the live row holds a procedure.
    (let ((n (catch #t (lambda () (procedure-name datum)) (lambda a #f))))
      (list 'option-function (or n '?))))
   ((pair? datum) (cons (printable (car datum)) (printable (cdr datum))))
   ((vector? datum) (list->vector (printable (vector->list datum))))
   (else datum)))

(define (write-indented datum port depth)
  "DATUM with one field per line, indented by DEPTH.

AN ENTRY IS RECOGNISED BY ITS FIRST ELEMENT: a property list starts with a
symbol (`key', `label'), and a list of entries starts with a pair.  So the
indentation follows the tree instead of printing every subtree on one line."
  (define (entry? x) (and (pair? x) (symbol? (car x))))
  ;; A LIST OF ENTRIES -- the top level, or any `submenu' -- is laid out one
  ;; entry per line too, so the whole tree reads top to bottom.
  (define (entry-list? x)
    (and (list? x) (pair? x) (and (pair? (car x)) (symbol? (caar x)))))
  (cond
   ((entry-list? datum)
    (display "(" port)
    (let loop ((rest datum) (first #t))
      (unless (null? rest)
        (unless first (display "\n" port) (display (make-string (+ depth 1) #\space) port))
        (write-indented (car rest) port (+ depth 1))
        (loop (cdr rest) #f)))
    (display ")" port))
   ((not (entry? datum))
    (write (printable datum) port))
   (else
    (display "(" port)
    (write (printable (car datum)) port)
    (let loop ((rest (cdr datum)))
      (unless (null? rest)
        (display "\n" port) (display (make-string (+ depth 1) #\space) port)
        ;; A FIELD VALUE IS LAID OUT TOO WHEN IT IS A TREE: `submenu' holds
        ;; either an entry list or an entry, and printing it flat is what made
        ;; the whole menu one line.
        (write-indented (car rest) port (+ depth 1))
        (loop (cdr rest))))
    (display ")" port))))

(define* (write-menu menu #:optional (port (current-output-port)))
  "Write MENU to PORT, with a summary of what is in it.  Answers #t."
  (format port ";; ~a top-level rows after the splice~%"
          (let ((sub (catch #t (lambda () (cadr (memq 'submenu menu))) (lambda a #f))))
            (if (and sub (list? sub)) (length sub) 0)))
  (write-indented menu port 0)
  (newline port)
  #t)

(define* (dump-menu #:optional path)
  "Write the whole menu to PATH -- or to stdout when PATH is #f -- and answer
#t, or #f when the menu has no `system' row to splice after.

ANSWERS A BOOLEAN, NOT THE MENU: this is typed at a REPL and evaluated from a
script, and a 55 KB menu echoed at the prompt is not an answer anybody wanted."
  (let ((full (menu-with-settings)))
    (and full
         (let ((port (or (and path (open-output-file path)) (current-output-port))))
           (write-menu full port)
           (when path (close-port port))
           #t))))
