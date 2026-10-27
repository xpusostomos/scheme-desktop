;;; (scheme-desktop config) -- this shell's options
;;;
;;; Only the SCHEMA lives here.  Validation, persistence, debounced atomic
;;; writes, corrupt-file recovery and live reload are (scheme-toolkit config)'s
;;; job -- they are the same for every shell.
;;;
;;; The file is s-expressions, not JSON.  `read' and `write' are built into
;;; Guile, they allow comments, they need no escaping rules, and they can embed
;;; a computed value.  Every reference shell uses JSON because in JavaScript
;;; JSON is a one-liner; that reason does not transfer here.
;;;
;;; An option is an ACCESSOR, so a widget binds to it exactly as it binds to an
;;; Astal property:
;;;
;;;   (element <gtk-label> #:label (config-ref 'desktop 'clock-format))
;;;
;;; and editing the file reaches the running shell without a restart.

(define-module (scheme-desktop config)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit config)
  #:use-module (scheme-toolkit file)
  #:export (shell-config-file))

;; Where the shell's options live, following the XDG spec rather than a
;; hard-coded ~/.config: a user with XDG_CONFIG_HOME set expects it honoured,
;; and a test can point it at a scratch directory.
(define shell-config-file
  (string-append (xdg-config-home) "/scheme-desktop/config.scm"))

(define (one-of . allowed)
  "A validator accepting only ALLOWED.  Written out rather than built from a
macro so the error a user sees names the option, not a closure."
  (lambda (v) (and (memq v allowed) #t)))

(define (list-of pred)
  (lambda (v) (and (list? v) (every pred v))))

(define-config <desktop>
  #:file shell-config-file

  ;; --- the bar ---------------------------------------------------------
  ;;
  ;; POSITION decides the anchor and the border side together; they must agree
  ;; or the bar is anchored to one edge and styled for the other, which looks
  ;; like a CSS bug and is not.
  (bar-position        top    (one-of 'top 'bottom))
  (bar-height          30     (lambda (v) (and (integer? v) (<= 16 v 96))))
  (bar-margin          0      (lambda (v) (and (integer? v) (<= 0 v 64))))
  (bar-opacity         0.92   (lambda (v) (and (number? v) (<= 0.0 v 1.0))))

  ;; Which modules appear, and in which order, per section.  A list of symbols
  ;; rather than a boolean per widget: adding a widget then means naming it in
  ;; the list, and there is no second place to keep in sync.
  (bar-start           (workspaces welcome)  (list-of symbol?))
  (bar-center          (media clock)         (list-of symbol?))
  (bar-end             (network bluetooth volume battery calendar)
                       (list-of symbol?))

  ;; --- widgets ---------------------------------------------------------
  (clock-format        "%H:%M" string?)
  (show-seconds?       #f      boolean?)

  ;; --- behaviour -------------------------------------------------------
  (notification-timeout 6000   (lambda (v) (and (integer? v) (<= 0 v 60000))))
  (osd-enabled?        #t      boolean?))
