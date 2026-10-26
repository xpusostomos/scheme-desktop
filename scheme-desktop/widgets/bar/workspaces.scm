;;; (scheme-desktop widgets bar workspaces) -- workspace pills
;;;
;;; One button per workspace, the focused one marked.  The first For consumer in
;;; the project, and the pattern the rest of the bar's dynamic modules follow:
;;; an accessor over the workspace list, a computed over the focused name, and a
;;; fragment whose children follow both.
;;;
;;; AstalHyprland, not AstalWorkspace: see the note in (scheme-toolkit astal) --
;;; the ext-workspace protocol is supported here but G-Golf cannot read the
;;; GList it returns.

(define-module (scheme-desktop widgets bar workspaces)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit astal)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit process)
  #:use-module (oop goops)
  #:use-module (ice-9 format)

  #:export (workspaces-widget))

(define-gi-imports "Gtk" "Box" "Button" "Label")

(define (prop obj name)
  (catch #t (lambda () (slot-ref obj (string->symbol name))) (lambda args #f)))

(define (special? name)
  (and (string? name) (string-prefix? "special:" name)))

(define (workspaces-widget)
  "The workspace pill box.

Each pill is a button that focuses its workspace when clicked.  The pill for the
focused workspace carries the `active' class, which is CSS's business -- the
module only says which one is current."
  (let* ((ws-acc (workspaces))
         (focused-acc (focused-workspace))
         (box (element <gtk-box> #:orientation 'horizontal #:class "workspaces"))
         ;; What is in the box now, so a rebuild only touches what changed.
         ;; Rebuilding every pill on every focus change would throw away the
         ;; CSS transition mid-flight.
         (shown '())
         (shown-focused #f)
         (pills '()))

    (define (pill-class ws)
      (let ((name (prop ws "name"))
            (focused (and (focused-acc) (prop (st-peek focused-acc) "name"))))
        (string-append
         "workspace"
         (if (equal? name focused) " active" "")
         (if (special? name) " special" ""))))

    (define (make-pill ws)
      (let ((name (prop ws "name")))
        (element <gtk-button>
                 #:label (if (special? name)
                             (substring name (string-length "special:"))
                             name)
                 #:class (pill-class ws)
                 #:on-clicked (lambda (b)
                                ;; dispatch is the Hyprland-only extra the plan
                                ;; allows AstalHyprland to keep for.
                                (exec-async
                                 (list "hyprctl" "dispatch" "workspace" name))))))

    (define (current-workspaces)
      (let ((v (st-peek ws-acc)))
        (if (list? v) v '())))

    ;; The children this module put in the box.  Tracked HERE rather than read
    ;; from %element-children: that table records what `element' inserted, and
    ;; these are inserted by add-child! directly afterwards, so it stays empty
    ;; and the rebuild would remove nothing while adding more.
    (define (refresh!)
      ;; Rebuild the pills.  Simple and correct: the plan notes Gnim's For has
      ;; no "insert at index" either and re-appends in order.
      (let* ((wss (filter (lambda (w) (not (special? (prop w "name"))))
                          (current-workspaces)))
             (names (map (lambda (w) (prop w "name")) wss))
             (focused (let ((f (focused-acc))) (and f (prop (st-peek focused-acc) "name")))))
        ;; Rebuild when the SET of workspaces changed, or when the focused one
        ;; moved -- the latter because the `active' class has to move with it.
        (unless (and (equal? names shown)
                     (equal? focused shown-focused))
          (set! shown names)
          (set! shown-focused focused)
          (for-each (lambda (child)
                      (catch #t (lambda () (remove-child! box child #f))
                             (lambda args #f)))
                    pills)
          (set! pills (map make-pill wss))
          (for-each (lambda (p) (add-child! box p #f)) pills))))

    ;; Rebuild when the workspace list changes, and again when focus moves.
    ;; Both subscriptions are owned by whatever root built this widget, so
    ;; disposing the bar disposes them.
    (subscribe ws-acc (lambda () (refresh!)))
    (subscribe focused-acc (lambda () (refresh!)))
    (refresh!)
    box))
