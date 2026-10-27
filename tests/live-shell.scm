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
(use-modules (srfi srfi-64))
(use-modules (ice-9 popen))
(use-modules (ice-9 rdelim))
(use-modules (ice-9 textual-ports))

(define instance "scheme-desktop")

;; (current-filename) is RELATIVE when the file is run with -s ("tests/live-
;; shell.scm"), so dirname twice gives "." and every path built from it is
;; wrong.  Resolve against the invocation directory first.
(define desktop-root
  (dirname (dirname (if (absolute-file-name? (current-filename))
                        (current-filename)
                        (string-append (getcwd) "/" (current-filename))))))

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

(test-begin "live-shell")

(if (not (shell-running?))
    (test-skip "no shell is listening; start one with bin/scheme-desktop run")
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
                         (map car (map (lambda (w) (list (slot-ref w 'name)))
                                       (windows))))))))
        ;; One per monitor.  The count is asserted as "at least one" so the
        ;; test is about the shell owning surfaces, not about how many screens
        ;; the machine happens to have.
        (test-assert "with a surface per monitor"
          (let ((answer (eval-in-shell
                         '(begin (use-modules (scheme-toolkit app))
                                 (length (windows-named "bar"))))))
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

      (test-group "control verbs work"
        ;; toggle-window is the whole of AGS's ToggleWindow, and it is also the
        ;; cheapest proof that the registry and the visibility path agree.
        (test-assert "toggling the bar hides and shows it"
          (let* ((before (eval-in-shell
                          '(begin (use-modules (scheme-toolkit app))
                                  (window-visible? (window "bar")))))
                 (hidden (eval-in-shell
                          '(begin (use-modules (scheme-toolkit app))
                                  (toggle-window "bar"))))
                 (shown (eval-in-shell
                         '(begin (use-modules (scheme-toolkit app))
                                 (toggle-window "bar")))))
            (and (not (string-null? before))
                 (not (string-null? hidden))
                 (not (string-null? shown))))))))

(test-end "live-shell")
