;;; (scheme-desktop wm hyprland) -- the window-manager surface, on Hyprland
;;;
;;; The only module that reads Hyprland objects or knows Hyprland's property
;;; names. It turns them into the plain records `(scheme-desktop wm)' defines,
;;; and it acts through `(scheme-desktop hyprland)' -- the layer that owns the
;;; Lua dispatch syntax.
;;;
;;; LOADING THIS FILE INSTALLS IT as the shell's window manager, so a shell picks
;;; a compositor by importing one module.
;;;
;;; AstalHyprland is the READER throughout, and it is good at that: typed
;;; Monitor/Workspace/Client objects, and the `event' signal that says when any
;;; of it changed. What it cannot do is ACT (see (scheme-desktop hyprland)).

(define-module (scheme-desktop wm hyprland)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit service-helpers)
  #:use-module (scheme-toolkit services hyprland)
  #:use-module (scheme-toolkit reactive)
  ;; For `set-window-edge-box!', which is how the toolkit learns where the bar
  ;; is: a question only a compositor can answer.
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-desktop wm)
  #:use-module (scheme-desktop hyprland)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (<wm-hyprland> load-wm-backend!))

;; `slot-ref' IS (oop goops). Without the import above it resolves to whatever
;; else exports the name, the read raises, and a `catch' around it becomes a
;; silent #f -- which is how `client-selector' came to return nothing and
;; choosing a window came to do nothing at all.
(define (prop obj name)
  "OBJ's property NAME, or #f. Compositor objects come and go under us."
  (catch #t (lambda () (slot-ref obj (string->symbol name))) (lambda args #f)))

;; `#:name' HERE IS A SLOT INIT, not a class option: `<wm>' has a `name' slot,
;; and `(define-class ... #:name "hyprland")' would set the CLASS's name and
;; leave the instance answering "wm".
(define-class <wm-hyprland> (<wm>))

;;; ---------------------------------------------------------------------------
;;; Reading
;;; ---------------------------------------------------------------------------

(define (number-or value fallback)
  (if (and (number? value) (> value 0)) value fallback))

(define (monitor-of obj)
  "The monitor NAME that OBJ (a workspace or a client) belongs to."
  (let ((m (prop obj "monitor")))
    (and m (prop m "name"))))

(define-method (wm-monitors (self <wm-hyprland>))
  (map (lambda (m)
         (make-wm-monitor (prop m "name")
                          (or (prop m "x") 0) (or (prop m "y") 0)
                          (number-or (prop m "width") 1920)
                          (number-or (prop m "height") 1080)
                          (number-or (prop m "scale") 1)))
       (hyprland-monitors)))

(define-method (wm-workspaces (self <wm-hyprland>))
  (map (lambda (w)
         (make-wm-workspace (prop w "id") (prop w "name") (monitor-of w)))
       (catch #t (lambda () (st-peek (workspaces))) (lambda args '()))))

(define-method (wm-clients (self <wm-hyprland>))
  (map (lambda (c)
         (make-wm-client (prop c "address")
                         (let ((w (prop c "workspace"))) (and w (prop w "id")))
                         (monitor-of c)
                         (or (prop c "x") 0) (or (prop c "y") 0)
                         (number-or (prop c "width") 0)
                         (number-or (prop c "height") 0)
                         (or (prop c "class") "")
                         (or (prop c "title") "")))
       (hyprland-client-list)))

;; Monitor name -> the id of the workspace it is showing. This is the question
;; the bar asks, and it is why the answer is an alist rather than a list.
(define-method (wm-focused-monitor (self <wm-hyprland>))
  "The name of the monitor with the focus, or #f."
  (let loop ((ms (hyprland-monitors)))
    (cond ((null? ms) #f)
          ((prop (car ms) "focused") (prop (car ms) "name"))
          (else (loop (cdr ms))))))

(define-method (wm-focused-workspaces (self <wm-hyprland>))
  (filter-map (lambda (m)
                (let ((ws (prop m "active-workspace")))
                  (and ws (cons (prop m "name") (prop ws "id")))))
              (hyprland-monitors)))

;; THE COMPOSITOR'S OWN EVENT STREAM, not a poll and not a set of property
;; bindings. Which workspace a monitor is showing changes without anything
;; `notify::' on this side firing -- another monitor's focus moves and this
;; monitor's focused workspace does not change at all -- so the event signal is
;; the only thing that sees all of it.
(define-method (wm-on-change (self <wm-hyprland>) proc)
  (let ((h (hyprland)))
    (if (not h)
        (lambda () #f)
        (let ((id (connect h 'event (lambda (obj name data) (proc)))))
          (lambda () (catch #t (lambda () (disconnect h id)) (lambda args #f)))))))

;;; ---------------------------------------------------------------------------
;;; Acting
;;; ---------------------------------------------------------------------------

(define-method (wm-focus-workspace! (self <wm-hyprland>) id) (focus-workspace! id))
(define-method (wm-focus-monitor! (self <wm-hyprland>) name) (focus-monitor! name))

(define-method (wm-focus-client! (self <wm-hyprland>) client)
  ;; MONITOR, THEN WORKSPACE, THEN WINDOW, IN ONE ORDERED CALL. Focusing a
  ;; window alone handles the case where it is on its monitor's active
  ;; workspace; when it is on one that is not showing, the workspace has to be
  ;; switched to as well, and issuing those separately races.
  (hyprctl-batch!
   (append
    (let ((m (wm-client-monitor client)))
      (if m (list (format #f "hl.dsp.focus({ monitor = ~s })" m)) '()))
    (let ((ws (wm-client-workspace client)))
      (if ws (list (format #f "hl.dsp.focus({ workspace = ~s })" (number->string ws)))
          '()))
    (list (format #f "hl.dsp.focus({ window = ~s })"
                  (window-selector! (wm-client-address client)))))))

(define-method (wm-close-client! (self <wm-hyprland>) client)
  (close-window! (wm-client-address client)))

;;; ---------------------------------------------------------------------------
;;; Installing
;;; ---------------------------------------------------------------------------

;;; ---------------------------------------------------------------------------
;;; Where the bar actually is
;;; ---------------------------------------------------------------------------

;; THIS IS WHY THE TOOLKIT HAS A HOOK FOR THIS AT ALL.  A panel has to start
;; below the bar, and GDK will not say where the bar is -- a layer surface's
;; position is the compositor's decision.  Hyprland will say: it reports how much
;; of each screen edge its EXCLUSIVE surfaces have taken, and the bar is the
;; thing that took it.
;;
;; THE BAR IS NOT ALWAYS AT THE EDGE, which is the whole point.  Exclusive
;; surfaces on the same edge STACK, so with two other bars on the top edge ours
;; sits at y=82 with a height of 45 -- and a panel placed 45 down from the top
;; covers the two bars above it.  This is measured, not theorised: `hyprctl
;; layers' on this machine shows our bar at 82 while the reserved band is 128.
;;
;; THE ASSUMPTION IS THAT OURS IS THE LAST EXCLUSIVE SURFACE ON ITS EDGE, which
;; is what makes the band's far side our bar's far side.  If another one is below
;; us the panel opens below that too -- further away than it needs to be, and
;; never on top of the bar, which is the failure that matters.
;; THE SURFACE IS FOUND BY PROCESS AND SIZE, because a layer surface cannot be
;; given a name: this shell's bar tried a namespace and the bar then never
;; appeared at all.  Our process has other layer surfaces of its own -- every
;; popup is one, and a popup is the size of the screen -- so the size is what
;; tells the bar from them.
(define (bar-surface-box monitor-name width height)
  "The bar's own rectangle on MONITOR-NAME, as (x y width height), or #f."
  (let ((mine (getpid)))
    (let loop ((rows (layer-surfaces)))
      (cond ((null? rows) #f)
            (else
             (let ((r (car rows)))
               (if (and (equal? (car r) monitor-name)
                        (equal? (caddr r) mine)
                        (equal? (list-ref r 5) width)
                        (equal? (list-ref r 6) height))
                   (list (list-ref r 3) (list-ref r 4)
                         (list-ref r 5) (list-ref r 6))
                   (loop (cdr rows)))))))))

(define (load-wm-backend!)
  "Install the Hyprland window manager, once."
  (unless (wm-loaded?) (wm-use! (make <wm-hyprland> #:name "hyprland")))
  ;; AND TELL THE TOOLKIT WHERE A BAR'S EDGE IS, which only a compositor can
  ;; answer.  Installed here rather than in the shell's startup because this
  ;; module is already "the one that knows Hyprland".
  (set-window-edge-box! bar-surface-box))

;; LOADING THE MODULE IS CHOOSING THE COMPOSITOR. A shell writes
;; `(use-modules (scheme-desktop wm hyprland))' and gets a working `(wm)'.
(load-wm-backend!)
