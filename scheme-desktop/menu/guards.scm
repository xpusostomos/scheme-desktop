;;; (scheme-desktop menu guards) -- evaluating menu guard conditions
;;;
;;; A `when:', `checked:' or `disabled:' in a menu entry is a bash condition
;;; that came from Omarchy. This module runs them.
;;;
;;; ONE SHELL PER MENU OPEN, fed one expression at a time:
;;;
;;;   (define g (guard-session-start))
;;;   (guard-session-ask g "omarchy-hw-webcam")   ; => #t / #f / 'unknown
;;;   (guard-session-ask g "[[ \"$(omarchy-dns)\" == \"DHCP\" ]]")
;;;   (guard-session-stop g)
;;;
;;; WHY NOT ONE SHELL PER CONDITION. Forking bash is the expensive part of a
;;; guard -- several milliseconds each, against a probe that usually finishes in
;;; one -- and Omarchy's menu has 195 of them. One long-lived shell amortises
;;; that to a single fork per menu open.
;;;
;;; WHY NOT BATCH THEM LIKE OMARCHY DOES. Omarchy generates one script holding
;;; every guard, deals it into eight subshells and runs it whole, because it
;;; evaluates all 195 on every open. We evaluate only the rows of the submenu
;;; being DISPLAYED, which is a dozen, and most of those have no guard at all --
;;; the guards sit on leaves. So the batching machinery, and the cached
;;; `pacman -Q' snapshot it needs to be fast, buy us nothing we are not already
;;; getting by looking at less.
;;;
;;; WHY NOT ASYNCHRONOUSLY. Because then every answer has to find its way back
;;; to the row it belongs to, which is the same shape of complexity as
;;; Omarchy's batching. Synchronous costs a pause when a guarded submenu opens
;;; and nothing else. The interface here is one function returning one status,
;;; so making it asynchronous later is a change to the caller and not to this.
;;;
;;; NO DEPENDENCY ON scheme-toolkit -- ice-9 and srfi-9 only.

(define-module (scheme-desktop menu guards)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)          ; read-line -- NOT in (ice-9 textual-ports),
                                       ; which has get-line. The mistake compiles
                                       ; with a warning and fails at the first read.
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-9)
  #:export (guard-session-start guard-session-ask guard-session-ask-all guard-session-stop
            guard-value-status evaluate-menu-value
            guard-log
            guard-session? guard-timeout
            guard-status->visible? guard-status->checked? guard-status->disabled?
            guard-session-value guard-value guard-value->text))

;;; ---------------------------------------------------------------------------
;;; The shell
;;; ---------------------------------------------------------------------------

;; Stamped on every answer, and anything without it is DISCARDED.
;;
;; The protocol is one line out per line in, and it would be broken by a single
;; stray line -- a login shell's profile echo, or a guard that leaks output from
;; a background process. Neither announces itself; both would be read as the
;; next guard's answer, and every row after that would carry the wrong one.
;; A marker makes a desynchronised line skippable instead of fatal, and costs
;; one string comparison per answer.
(define %marker "__guard__:")

;; `-l' because the guards call Omarchy's own helpers (omarchy-hw-webcam,
;; omarchy-pkg-present, ...) and a login shell is what puts them on PATH.
;; Omarchy does the same. On this machine they are on the inherited PATH anyway,
;; so this is insurance rather than necessity.
;;
;; `-k 0.2' AFTER the timeout, not just the timeout: `timeout' sends SIGTERM and
;; then waits, so a probe that ignores SIGTERM would hang the shell for ever --
;; and with a synchronous protocol that hangs the menu. `-k' is what makes
;; "half a second" true rather than aspirational.
(define %value-marker "__value__:")

(define (guard-program timeout)
  ;; TWO KINDS OF QUESTION, AND THE LINE SAYS WHICH.  A condition is asked for its
  ;; EXIT STATUS, as it always was.  A VALUE is asked for its OUTPUT, so its
  ;; expression is sent with %value-marker in front and the answer carries both
  ;; the status and the first line of what it printed -- one line, because the
  ;; protocol is one line per question.
  (string-append
   "while IFS= read -r expr; do\n"
   "  case \"$expr\" in\n"
   "    " %value-marker "*)\n"
   "      out=$( { timeout -k 0.2 " (if (string? timeout) timeout (number->string timeout))
   " bash -c \"${expr#" %value-marker "}\"; } 2>/dev/null )\n"
   "      code=$?\n"
   "      line=$(printf '%s' \"$out\" | head -1)\n"
   "      printf '" %value-marker "%s\\t%s\\n' \"$code\" \"$line\"\n"
   "      ;;\n"
   "    *)\n"
   "      { timeout -k 0.2 " (if (string? timeout) timeout (number->string timeout))
   " bash -c \"$expr\"; } >/dev/null 2>&1\n"
   "      printf '" %marker "%s\\n' \"$?\"\n"
   "      ;;\n"
   "  esac\n"
   "done\n"))

;;; ---------------------------------------------------------------------------
;;; A session
;;; ---------------------------------------------------------------------------

(define-record-type <guard-session>
  (make-guard-session port timeout)
  guard-session?
  (port guard-session-port)
  (timeout guard-session-timeout))

;; Where the odd statuses go. A parameter so a test can capture them and a shell
;; can route them; the default writes to stderr, because a status of 124 or more
;; is a statement about the COMMAND and nobody sees it any other way.
(define guard-log
  (make-parameter
   (lambda (fmt . args)
     (apply format (current-error-port)
            (string-append "scheme-desktop: menu guards: " fmt "\n") args))))

;; Why a status of 124 or more is worth a line in the log.
;;
;; Everything below 124 is an ANSWER -- 0, or a plain non-zero from a test or a
;; probe, which is the condition saying no. From 124 up, the number is about the
;; command rather than the condition: we could not run it, it was killed, or
;; timeout(1) gave up. Those all silently read as "false" -- which is the right
;; verdict, and the reason a broken guard is invisible without this. A typo in a
;; helper name hides its row for ever and says nothing.
;;
;; Naming the code matters because the three groups mean different things and
;; only one of them is our doing.
(define %max-signal 64)                  ; Linux's SIGRTMAX; 128+N is only a
                                        ; signal while N is a signal.

(define (status-explanation n)
  (cond ((= n 124) "timed out")
        ((= n 125) "timeout(1) itself failed")
        ((= n 126) "cannot execute")
        ((= n 127) "command not found")
        ;; 129..192 is 128+N for a real N. Beyond that the number is just an
        ;; exit status that happens to be large -- `exit 200' is 200, and
        ;; reporting it as "killed by signal 72" is worse than saying nothing.
        ((<= 129 n (+ 128 %max-signal))
         (format #f "killed by signal ~a" (- n 128)))
        (else "exit status")))

;; Seconds a single condition may take before it is abandoned.
;; (A comment, not a docstring: Guile's `define' has no docstring form -- only a
;; procedure's first body form is a docstring. `(define x "doc" val)' is a
;; syntax error, and the message points at the whole form rather than the string.)
(define guard-timeout 0.5)

(define* (guard-session-start #:key (timeout guard-timeout))
  "A shell ready to evaluate guard conditions, or #f if it could not be started.

The shell is created here; no condition has run yet."
  (catch #t
    (lambda ()
      (make-guard-session
       (open-pipe* OPEN_BOTH "bash" "-l" "-c" (guard-program timeout))
       timeout))
    (lambda args #f)))

;;; ---------------------------------------------------------------------------
;;; Asking
;;; ---------------------------------------------------------------------------

;; THE EXIT STATUS IS THE ANSWER. The expression is run as a command with its
;; output thrown away, and what it returns is the condition:
;;
;;   0     true
;;   124   TIMED OUT -- `timeout' could not decide, and Omarchy has no answer
;;         here because it has no timeout. Reported as 'unknown rather than as
;;         false, because "we could not find out" is not "no".
;;   other false
;;
;; 124 EXACTLY, not ">= 124". Measured on this machine: 125/126/127 are
;; timeout(1)'s and the shell's own "could not run it" codes, 128+N means the
;; command died by a signal, and a condition that exits with a status of its own
;; passes it straight through -- `exit 200' really does report 200. Only 124
;; means "timed out".
;;
;; Everything that is not 0 or 124 is false, which is exactly what Omarchy's own
;; `if { expr; }' would have concluded -- including 127 when a helper is not
;; installed, which hides the row there too.
(define %timeout-status 124)

(define (read-status port expression)
  (let loop ()
    (let ((line (read-line port)))
      (cond
       ((eof-object? line)
        ;; The shell is gone -- it died, or stop! closed it. Every remaining
        ;; condition is undecided rather than false.
        'unknown)
       ((string-prefix? %marker line)
        (let ((n (string->number (substring line (string-length %marker)))))
          (cond
           ((not n)
            ;; The marker with nothing sensible after it: the protocol itself is
            ;; off, which nothing else would report.
            ((guard-log) "unreadable answer ~s for: ~a" line expression)
            'unknown)
           ((zero? n) #t)
           (else
            (when (>= n 124)
              ((guard-log) "~a (~a): ~a" n (status-explanation n) expression))
            (if (= n %timeout-status) 'unknown #f)))))
       (else (loop))))))

(define (read-value port)
  "The answer to a VALUE question: (STATUS . TEXT), or 'unknown.

The text is what the command printed, first line only.  A status other than 0 is
'unknown -- for a value, a command that failed did not tell us the value, which
is not the same as an empty one."
  (let loop ()
    (let ((line (read-line port)))
      (cond
       ((eof-object? line) 'unknown)
       ((string-prefix? %value-marker line)
        (let* ((rest (substring line (string-length %value-marker)))
               (tab (string-index rest #\tab))
               (status (and tab (string->number (substring rest 0 tab))))
               (text (if tab (substring rest (+ tab 1)) "")))
          (cond ((not status)
                 ((guard-log) "unreadable value answer ~s" line)
                 'unknown)
                ((zero? status) text)
                ((= status %timeout-status) 'unknown)
                (else
                 (when (>= status 124)
                   ((guard-log) "~a (~a) asking for a value" status (status-explanation status)))
                 'unknown))))
       (else (loop))))))

(define (guard-session-value session expression)
  "What EXPRESSION prints: its first line, or 'unknown."
  (let ((port (guard-session-port session)))
    (catch #t
      (lambda ()
        (display %value-marker port)
        (display expression port)
        (newline port)
        (force-output port)
        (read-value port))
      (lambda args 'unknown))))

(define (guard-session-ask session expression)
  "EXPRESSION's status: #t, #f, or 'unknown if it could not be decided."
  (let ((port (guard-session-port session)))
    (catch #t
      (lambda ()
        (display expression port)
        (newline port)
        (force-output port)
        (read-status port expression))
      (lambda args 'unknown))))

;;; Asking for a whole submenu at once.
;;;
;;; The shell's `while read' loop is already serial -- one line in, one answer
;;; out -- so writing every expression before reading any answer changes nothing
;;; about the protocol and removes a whole round trip per row. Measured on this
;;; machine: 12 real conditions cost 576ms one round trip at a time and 79ms
;;; written together, because most of the per-row cost was the wait, not the
;;; probe.
;;;
;;; Each expression still carries its own `timeout', so a slow one delays only
;;; the answers behind it in the same write, never a wedged shell.
(define (guard-session-ask-all session expressions)
  "The statuses of EXPRESSIONS, in order -- one #t, #f or 'unknown each."
  (let ((port (guard-session-port session)))
    (catch #t
      (lambda ()
        (for-each (lambda (e) (display e port) (newline port)) expressions)
        (force-output port)
        (map (lambda (e) (read-status port e)) expressions))
      (lambda args (map (lambda (ignored) 'unknown) expressions)))))

(define (guard-session-stop session)
  "Close the shell. Closing its input is what ends it -- the read loop sees EOF
and returns -- so the kill is a backstop for a shell wedged in a condition."
  (let ((port (guard-session-port session)))
    (catch #t
      (lambda ()
        (close-pipe port)
        #t)
      (lambda args #f))))

;;; ---------------------------------------------------------------------------
;;; What a status means for a row
;;; ---------------------------------------------------------------------------

;; Omarchy's rule, generalised to all three conditions: a row is changed only by
;; an EXPLICIT answer, never by a missing one.
;;
;;   when      hides the row only on an explicit #f  -- so 'unknown SHOWS it
;;   checked   ticks it only on an explicit #t        -- so 'unknown does not
;;   disabled  dims it only on an explicit #t         -- so 'unknown does not
;;
;; `when' is the odd one out, and deliberately: failing to prove a condition
;; false is not proving it false, and hiding a row is the more destructive of
;; the two mistakes.

(define (guard-status->visible? status)
  "Whether a `when' status leaves the row visible."
  (not (eq? status #f)))

(define (guard-status->checked? status)
  "Whether a `checked' status earns the tick."
  (eq? status #t))

(define (guard-status->disabled? status)
  "Whether a `disabled' status dims the row."
  (eq? status #t))


;;; ---------------------------------------------------------------------------
;;; A field value, which may not be bash at all
;;; ---------------------------------------------------------------------------
;;
;; A menu field's value is one of three things, and the shape says which:
;;
;;   "omarchy-hw-webcam"                 a STRING -> a bash condition
;;   omarchy-hw-webcam                   a SYMBOL -> the Scheme procedure of
;;                                                  that name, called
;;   (file-exists? "/etc/os-release")    a LIST   -> a Scheme form, evaluated
;;
;; This is what lets a hand-written menu be Scheme the whole way down while the
;; generated Omarchy one stays bash: entry for entry, the same tree, and only
;; the leaves differ.
;;
;; A LIST IS EVALUATED, and IF THAT YIELDS A PROCEDURE IT IS CALLED. That makes
;; both spellings work, and they are both natural to write:
;;
;;   (key x … when (file-exists? "/etc/os-release"))
;;   (key x … when (lambda () (file-exists? "/etc/os-release")))
;;
;; A symbol is looked up rather than evaluated, because `(eval 'omarchy-hw-webcam)'
;; would be a variable reference and would need the symbol to be BOUND to a
;; procedure -- which it is not, and should not have to be. Looking it up in
;; MODULE gets the procedure whatever else that name means.

(define* (evaluate-menu-value value #:key (module (current-module)))
  "Run a Scheme-valued menu field: a symbol names a procedure, a list is a form.

Every field that can be Scheme goes through here -- `when', `checked',
`disabled', `action', `provider' -- so the three-way rule is defined once."
  (let ((result (cond ;; Already a procedure -- what a provider builds when it
                      ;; holds the object it wants to act on and would otherwise
                      ;; have to name it in a form and hope it resolves.
                      ((procedure? value) value)
                      ((symbol? value) (module-ref module value))
                      ((list? value) (eval value module))
                      (else (error "menu value is neither a string, symbol nor list"
                                   value)))))
    (if (procedure? result) (result) result)))

(define* (guard-value-status session value #:key (module (current-module)))
  "VALUE as a condition: #t, #f, or 'unknown.

A string is a bash condition, evaluated in SESSION. A symbol or a list is Scheme,
run here -- and a Scheme condition that RAISES is 'unknown rather than false, on
the same principle as a timeout: we did not find out, which is not the same as
no."
  (if (string? value)
      (guard-session-ask session value)
      (catch #t
        (lambda ()
          (let ((result (evaluate-menu-value value #:module module)))
            ;; Truthiness, not `(eq? result #t)': a Scheme predicate may return
            ;; any true value, and bash's 0/1 has no equivalent here.
            (if result #t #f)))
        (lambda (key . args)
          ((guard-log) "condition raised ~a ~s: ~s" key args value)
          'unknown))))

;;; ---------------------------------------------------------------------------
;;; A field's VALUE -- what it is, not whether it is true
;;; ---------------------------------------------------------------------------
;;
;; The other half of the same idea as `guard-value-status'.  A condition asks a
;; command whether it succeeded; a VALUE asks it what it printed.  Both shapes are
;; accepted, and they mean the same thing they do everywhere else in a menu:
;;
;;   "omarchy-pkg-present foo"     a string -> a bash command, its output read
;;   my-widget-cost                a symbol -> the Scheme procedure of that name
;;   (lambda () 42)                a list   -> a Scheme form
;;
;; A SCHEME VALUE IS MADE INTO TEXT HERE, and a bash one is already text: the two
;; arrive at the menu as the same thing, which is what lets the type field decide
;; what a value MEANS rather than where it came from.

(define (guard-value->text value)
  "VALUE as text, for a way of not telling it apart: #t/#f as \"#t\"/\"#f\", a
symbol as its name, a number and a string as themselves, anything else written."
  (cond ((eq? value #t) "#t")
        ((eq? value #f) "#f")
        ((symbol? value) (symbol->string value))
        ((string? value) value)
        ((number? value) (number->string value))
        (else (format #f "~s" value))))

(define* (guard-value session value #:key (module (current-module)))
  "VALUE's value: text, or 'unknown when it could not be had.

A string is a bash command and its OUTPUT is the value; a symbol or a list is
Scheme, run here.  Scheme that raises is 'unknown, as a condition that raises is."
  (if (string? value)
      (guard-session-value session value)
      (catch #t
        (lambda () (guard-value->text (evaluate-menu-value value #:module module)))
        (lambda (key . args)
          ((guard-log) "value raised ~a ~s: ~s" key args value)
          'unknown))))
