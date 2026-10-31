;;; (scheme-desktop hyprland) -- Hyprland's Lua dispatch syntax, and nothing else
;;;
;;; THE LOWEST LAYER: it knows how to say something to Hyprland and nothing
;;; about what a shell wants to say. Every function here takes and returns plain
;;; values -- numbers, strings -- so this module needs no Astal, no compositor
;;; objects and no `slot-ref'.
;;;
;;; THE SYNTAX IS NOT THE OBVIOUS ONE HERE.
;;;
;;; This Hyprland (0.56.2, configured in Lua) rejects the classic form:
;;;
;;;   $ hyprctl dispatch workspace 3
;;;   error: 3 [string "return hl.dispatch(workspace 3)"]:1: ')' expected near '3'
;;;    -> Note: dispatch in lua is a shorthand for hl.dispatch(...)
;;;
;;; It translates the arguments into a Lua call, so a bare `workspace 3' becomes
;;; `hl.dispatch(workspace 3)' and does not parse. The whole expression has to be
;;; the Lua. ags2-shell spells it the same way (`dispatch hl.dsp.focus({...})'),
;;; and Astal DOES NOT: its `Monitor.focus()', `Workspace.focus()' and
;;; `Client.focus()' all build the classic string and are therefore unusable
;;; here. That is why this module exists at all.
;;;
;;; A WORKSPACE GOES AS A STRING. Lua number is a workspace ID that has to exist
;;; already; Lua string is a workspace NAME, which the compositor creates on
;;; demand. Both answer `ok':
;;;
;;;   hl.dsp.focus({ workspace = 3 })     -> switches, only if 3 exists
;;;   hl.dsp.focus({ workspace = 5 })     -> ok, and nothing happens
;;;   hl.dsp.focus({ workspace = "5" })   -> switches, creating 5

(define-module (scheme-desktop hyprland)
  #:use-module (scheme-toolkit process)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (hyprctl-dispatch! hyprctl-batch! hyprctl-query layer-surfaces
            focus-workspace! focus-monitor! focus-window! close-window!
            window-selector!))

;;; ---------------------------------------------------------------------------
;;; Asking Hyprland questions
;;; ---------------------------------------------------------------------------

;; A QUERY, WHERE EVERYTHING ELSE HERE IS A COMMAND.  `hyprctl layers' prints one
;; stanza per monitor and one line per surface, with the surface's own geometry
;; -- which is the only place a layer surface's POSITION is available at all: the
;; layer-shell protocol does not tell a client where its surface went, GDK has no
;; API for it, and AstalHyprland's `reserved-*' properties answer something else
;; entirely (measured: it reports 55 and 81 where Hyprland's own reserved band is
;; [left 55, top 128]).
;;
;; IT BLOCKS, unlike the dispatches above, and the difference matters: a dispatch
;; is fired from a click and may not wait for a process, while this is asked once
;; when a panel is about to open and `hyprctl' answers in single-digit
;; milliseconds.  `run-command' is the blocking one, deliberately.
(define (hyprctl-query . args)
  "What `hyprctl ARGS...' prints, or #f."
  (catch #t (lambda () (run-command (cons "hyprctl" args))) (lambda a #f)))

;; The lines, as records: `(monitor namespace pid x y width height)'.  A text
;; format rather than `-j', because this project has no JSON reader and the
;; format is regular:
;;
;;   Monitor eDP-1:
;;     Layer level 2 (top):
;;       Layer 55ba9d8955c0: xywh: 56 82 1479 45, a: 1, namespace: gtk4-layer-shell, pid: 3481930
(define (layer-surfaces)
  "Every layer surface Hyprland has, as records.  Empty when it cannot be asked."
  (let* ((text (hyprctl-query "layers"))
         (lines (and text (string-split text #\newline))))
    (let loop ((rest lines) (monitor #f) (acc '()))
      (cond ((null? rest) (reverse acc))
            (else
             (let* ((line (car rest))
                    (name (and (string-prefix? "Monitor " line)
                               (string-trim-both
                                (substring line 8
                                           (or (string-index line #\:) (string-length line))))))
                    (xywh (and (not name) (number-list-after "xywh:" line)))
                    (pid (and (not name) (number-list-after "pid:" line)))
                    (ns (and (not name) (string-after "namespace:" line))))
               (loop (cdr rest)
                     (or name monitor)
                     (if (and xywh pid (= 4 (length xywh)))
                         (cons (list monitor (or ns "")
                                     (car pid)
                                     (list-ref xywh 0) (list-ref xywh 1)
                                     (list-ref xywh 2) (list-ref xywh 3))
                               acc)
                         acc))))))))

(define (string-after marker line)
  "The text after MARKER in LINE, up to a comma, trimmed."
  (let ((i (string-contains line marker)))
    (and i
         (string-trim-both
          (let ((rest (substring line (+ i (string-length marker))
                                 (string-length line))))
            (let ((comma (string-index rest #\,)))
              (if comma (substring rest 0 comma) rest)))))))

(define (number-list-after marker line)
  "The numbers after MARKER in LINE, up to a comma."
  (let ((text (string-after marker line)))
    (and text
         (let ((parts (string-split text #\space)))
           (map (lambda (p) (string->number (string-trim-both p)))
                (list-head parts (length (take-while (lambda (p)
                                                       (string->number (string-trim-both p)))
                                                     parts))))))))

(define (hyprctl-dispatch! expression)
  "Run EXPRESSION as a Hyprland Lua dispatch, detached.

Detached because every caller is a click handler or a keybinding, and neither
may block the main loop on a subprocess."
  (catch #t
    (lambda () (exec-async (list "hyprctl" "dispatch" expression)))
    (lambda (key . args)
      (format (current-error-port)
              "scheme-desktop: hyprland: dispatch failed: ~a ~s~%" key args)
      #f)))

;; SEVERAL DISPATCHES THAT MUST HAPPEN IN ORDER, IN ONE PROCESS.
;;
;; Not several calls to `hyprctl-dispatch!': each of those starts its own process
;; asynchronously, so the order they reach the compositor is whatever the
;; scheduler decides. Measured: asking for "focus this monitor" and then "focus
;; this window" as two calls sometimes landed the monitor focus LAST, which put
;; the monitor back on the workspace it was already showing and undid the window
;; focus -- so choosing a window on another monitor's non-active workspace did
;; nothing.
(define (hyprctl-batch! expressions)
  "Run EXPRESSIONS as Hyprland Lua dispatches, in one process, in order."
  (catch #t
    (lambda ()
      (exec-async
       (list "hyprctl" "--batch"
             (string-join (map (lambda (e) (string-append "dispatch " e))
                               expressions)
                          ";"))))
    (lambda (key . args)
      (format (current-error-port)
              "scheme-desktop: hyprland: batch failed: ~a ~s~%" key args)
      #f)))

;;; ---------------------------------------------------------------------------
;;; The four things a shell wants to say
;;; ---------------------------------------------------------------------------

(define (focus-workspace! id)
  "Switch to workspace ID, creating it if it does not exist."
  (hyprctl-dispatch! (format #f "hl.dsp.focus({ workspace = ~s })"
                             (number->string id))))

(define (focus-monitor! name)
  "Focus the monitor called NAME."
  (and name (hyprctl-dispatch! (format #f "hl.dsp.focus({ monitor = ~s })" name))))

(define (window-selector! address)
  "ADDRESS as a Hyprland window selector, or #f.

AstalHyprland STRIPS the 0x from a client address and Hyprland's selectors want
it back. `class:' would be friendlier and is ambiguous the moment two windows
share an application, so the address is what these use -- it names exactly one
window."
  (and (string? address)
       (not (string=? address ""))
       (string-append "address:0x" (string-downcase address))))

(define (focus-window! address)
  "Focus the window at ADDRESS."
  (let ((selector (window-selector! address)))
    (and selector
         (hyprctl-dispatch! (format #f "hl.dsp.focus({ window = ~s })" selector)))))

(define (close-window! address)
  "Close the window at ADDRESS."
  (let ((selector (window-selector! address)))
    (and selector
         (hyprctl-dispatch! (format #f "hl.dsp.window.close({ window = ~s })"
                                    selector)))))
