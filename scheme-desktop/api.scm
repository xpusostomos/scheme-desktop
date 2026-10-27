;;; (scheme-desktop api) -- the procedures a keybinding or a test calls
;;;
;;; This is the shell's vocabulary, and it replaces what AGS calls a request
;;; handler: instead of a string switch over four verbs, these are ordinary
;;; procedures that a Hyprland binding reaches with
;;;
;;;     scheme-toolkit eval -i scheme-desktop '(toggle-window "launcher")'
;;;
;;; and a test calls the same way.  Anything not anticipated needs no new verb
;;; -- it is one expression: `(set! (!visible (window "bar")) #f)'.
;;;
;;; Every one of these is guarded, because a keybinding must not be able to take
;;; the shell down.  A command that fails logs and returns #f.

(define-module (scheme-desktop api)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit astal)
  #:use-module (scheme-toolkit process)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:use-module (ice-9 format)

  #:re-export (toggle-window window windows quit-shell)
  #:export (volume-up! volume-down! volume-mute!
            media-play-pause! media-next! media-previous!
            screenshot screenshot-area
            launcher-search launcher-run-first!
            notification-status
            describe-state))

;;; ---------------------------------------------------------------------------
;;; Volume
;;; ---------------------------------------------------------------------------

(define (sink)
  "The default sink object, or #f when there is no audio server."
  (let ((w (wp)))
    (and w
         (catch #t (lambda () (slot-ref w 'default-speaker)) (lambda args #f)))))

(define (adjust-volume! delta)
  "Move the default sink's volume by DELTA, clamped to 0..1.

The clamp matters: a keybinding held down should stop at full, not wrap or
error."
  (let ((s (sink)))
    (if (not s)
        #f
        (catch #t
          (lambda ()
            (let* ((current (slot-ref s 'volume))
                   (next (max 0.0 (min 1.0 (+ current delta)))))
              (slot-set! s 'volume next)
              ;; Changing the volume should un-mute: turning it up and hearing
              ;; nothing is the most common complaint about a volume key.
              (when (and (> next 0.0) (slot-ref s 'mute))
                (slot-set! s 'mute #f))
              next))
          (lambda (key . rest)
            (log-error (cons key rest) "volume")
            #f)))))

(define* (volume-up! #:optional (amount 0.05))
  (adjust-volume! amount))

(define* (volume-down! #:optional (amount 0.05))
  (adjust-volume! (- amount)))

(define (volume-mute!)
  "Flip the default sink's mute.  The bar button calls the same toolkit
procedure, so a keybinding and a click cannot disagree."
  (speaker-mute-toggle!))

;;; ---------------------------------------------------------------------------
;;; Media
;;; ---------------------------------------------------------------------------

(define (playerctl . args)
  "Run playerctl with ARGS, logging and returning #f if it is not installed.

A missing playerctl is an ordinary state on a machine that has never played
anything, so it must not be an error."
  (exec-async (cons "playerctl" args)))

(define (media-play-pause!) (playerctl "play-pause"))
(define (media-next!) (playerctl "next"))
(define (media-previous!) (playerctl "previous"))

;;; ---------------------------------------------------------------------------
;;; Screenshots
;;; ---------------------------------------------------------------------------

;; The one place in this shell that runs a pipeline, and it has to be a shell:
;; grim writes to stdout and wl-copy reads it, and there is no way to say that
;; with a program list.  Both reference shells do the same.
(define (screenshot-area)
  "Select a region and put it on the clipboard."
  (exec-async '("sh" "-c" "grim -g \"$(slurp)\" - | wl-copy")))

(define* (screenshot #:key (area? #f) (output #f))
  "Screenshot the focused output, or a selected AREA, to the clipboard."
  (cond
   (area? (screenshot-area))
   (output (exec-async (list "sh" "-c"
                             (format #f "grim -o ~a - | wl-copy" output))))
   (else (exec-async '("sh" "-c" "grim - | wl-copy")))))

;;; ---------------------------------------------------------------------------
;;; Launcher
;;; ---------------------------------------------------------------------------
;;
;; The launcher's WINDOW is D7; these are the two things a keybinding or a test
;; needs before there is one, and they are worth having on their own: searching
;; from a terminal is how the plugin set gets exercised without a UI.

(define (launcher-search query)
  "The results QUERY produces, as a list of <result>.

This is the same call the launcher window will make, so a plugin broken here is
broken there -- and it can be checked without opening anything."
  (catch #t
    (lambda ()
      (let ((iface (resolve-interface '(scheme-toolkit launcher))))
        ((module-ref iface 'route) query)))
    (lambda (key . args)
      (format (current-error-port)
              "scheme-desktop: launcher-search failed: ~a ~s~%" key args)
      '())))

(define (launcher-run-first! query)
  "Run the first result for QUERY.  Returns its title, or #f.

The smallest useful launcher: a keybinding that runs what you typed.  It also
exercises the whole path -- plugin, action, subprocess -- from one expression."
  (let ((results (launcher-search query)))
    (if (null? results)
        (begin (format (current-error-port)
                       "scheme-desktop: nothing matches ~s~%" query)
               #f)
        ;; result-title / result-action, not slot-ref: a <result> is a Scheme
        ;; record, not a GObject, so the generic property path does not apply to
        ;; it.  slot-ref here would fail with "no slot named title" at exactly
        ;; the moment a keybinding tried to run something.
        (let* ((iface (resolve-interface '(scheme-toolkit launcher)))
               (title ((module-ref iface 'result-title) (car results)))
               (action ((module-ref iface 'result-action) (car results))))
          (when action
            (catch #t action
                   (lambda (key . args)
                     (format (current-error-port)
                             "scheme-desktop: launcher action failed: ~a ~s~%"
                             key args))))
          title))))

;;; ---------------------------------------------------------------------------
;;; Notifications
;;; ---------------------------------------------------------------------------

(define (notification-status)
  "Who is receiving notifications on this session bus.

'owner means this shell's notification data is real; 'elsewhere means another
process (quickshell, dunst, mako) owns the name and this shell can see nothing.
A UI that ignored the difference would render an empty list, which looks exactly
like a quiet desktop."
  (catch #t
    (lambda ()
      (let ((iface (resolve-interface '(scheme-toolkit notify))))
        ((module-ref iface 'notify-status))))
    (lambda args 'unknown)))

;;; ---------------------------------------------------------------------------
;;; Diagnostics
;;; ---------------------------------------------------------------------------

(define* (describe-state #:optional (port (current-output-port)))
  "Print what the shell currently holds.  The first thing to reach for from a
keybinding when something looks wrong."
  ;; windows-named gives (name . window), which is what is worth reporting: the
  ;; registry keeps several windows per name (one bar per monitor).
  (format port "windows:\n")
  (for-each (lambda (name)
              (for-each (lambda (pair)
                          (format port "  ~a  ~a~%"
                                  name
                                  (if (window-visible? (cdr pair)) "visible" "hidden")))
                        (windows-named name)))
            (catch #t (lambda () (window-names)) (lambda args '())))
  (format port "monitors: ~a~%" (length (monitors)))
  ;; Reported here because it is the one piece of state that looks identical
  ;; when broken: a shell that cannot see notifications shows an empty list,
  ;; which is what a quiet desktop shows too.
  (format port "notifications: ~a~%" (notification-status))
  (format port "repl: ~a~%"
          (catch #t
            (lambda ()
              (let ((iface (resolve-interface '(scheme-toolkit repl))))
                (if ((module-ref iface 'repl-running?)) "running" "stopped")))
            (lambda args "not loaded")))
  #t)
