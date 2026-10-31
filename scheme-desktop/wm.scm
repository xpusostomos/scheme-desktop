;;; (scheme-desktop wm) -- what this shell needs from a window manager
;;;
;;; ONE PLACE THAT KNOWS THE COMPOSITOR. Widgets ask this module for monitors,
;;; workspaces and clients, and never see a Hyprland object, a Hyprland property
;;; name, or a `slot-ref'.
;;;
;;; THE OPERATIONS ARE GOOPS GENERICS on a `<wm>', and an implementation is a
;;; SUBCLASS of it. That is what makes a second compositor a new file rather
;;; than an edit: `(scheme-desktop wm sway)' would define `<wm-sway>', implement
;;; the same generics, and be installed in place of the Hyprland one. A record
;;; holding a table of procedures would have done the job too, until the day an
;;; implementation wanted to share half its behaviour with another -- which is
;;; the day GOOPS was invented for.
;;;
;;; WHAT IS A GENERIC AND WHAT IS NOT. Only the seven things a compositor has
;;; to answer for itself are generics. Everything a widget actually asks --
;;; "the monitor called this", "the windows on that workspace", "which
;;; workspaces have anything on them" -- is a METHOD ON `<wm>' ITSELF, written
;;; once in terms of the primitives, so every implementation inherits it and
;;; none of them can answer those differently.
;;;
;;; WHY THE NAMES CARRY `wm-'. It is the DOMAIN, not the compositor: `wm-monitors'
;;; is "the window manager's monitors", and reads the same for Sway. The bare
;;; names are not free -- `(scheme-toolkit app)' already exports `monitors', for
;;; the GdkMonitors that roots are keyed by, and every widget here imports both.
;;;
;;; WHY THIS EXISTS AT ALL, given the plan says "compositor abstraction --
;;; neither; it's Astal". Astal IS the backend, and this is not a second one:
;;; the reading here is Astal's typed objects and signals, unchanged. What the
;;; plan did not anticipate is that Astal's ACTION methods do not work on this
;;; Hyprland -- `Monitor.focus()' and friends build the classic dispatcher
;;; string, and this compositor wraps whatever follows `dispatch' in
;;; `hl.dispatch(...)', which only parses as Lua:
;;;
;;;   Astal's Monitor.focus()  ->  dispatch focusmonitor eDP-1
;;;   error: [string "return hl.dispatch(focusmonitor eDP-1)"]:1: ')' near 'eDP'
;;;
;;; So acting has to be compositor-specific, and the moment one part of the
;;; surface is specific the whole of it belongs behind an interface rather than
;;; spread through widgets.
;;;
;;; VALUES ARE PLAIN RECORDS, not the compositor's objects. A widget holding an
;;; `AstalHyprland.Client' holds Hyprland; a widget holding a `<wm-client>'
;;; holds what this shell needs to draw a rectangle.

(define-module (scheme-desktop wm)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (;; the data a widget is handed
            make-wm-monitor make-wm-workspace make-wm-client
            <wm-monitor> wm-monitor? wm-monitor-name wm-monitor-x wm-monitor-y
            wm-monitor-width wm-monitor-height wm-monitor-scale
            <wm-workspace> wm-workspace? wm-workspace-id wm-workspace-name
            wm-workspace-monitor
            <wm-client> wm-client? wm-client-address wm-client-workspace
            wm-client-monitor wm-client-x wm-client-y wm-client-width
            wm-client-height wm-client-class wm-client-title

            ;; the install
            <wm> wm-name wm-use! wm wm-loaded?

            ;; the generics an implementation answers
            wm-monitors wm-workspaces wm-clients wm-focused-workspaces
            wm-focused-monitor
            wm-on-change
            wm-focus-workspace! wm-focus-client! wm-focus-monitor!
            wm-close-client!

            ;; the questions a widget asks
            wm-monitor-by-name wm-workspace-by-id wm-clients-on
            wm-focused-workspace wm-occupied-workspaces wm-client-at))

;;; ---------------------------------------------------------------------------
;;; What a widget is given
;;; ---------------------------------------------------------------------------

(define-record-type <wm-monitor>
  (make-wm-monitor name x y width height scale)
  wm-monitor?
  (name wm-monitor-name)
  (x wm-monitor-x) (y wm-monitor-y)
  (width wm-monitor-width) (height wm-monitor-height)
  (scale wm-monitor-scale))

;; ID IS THE COMPOSITOR'S WORKSPACE NUMBER, and it is what a keybinding names:
;; `workspace 3'. A name is the string the bar shows, which for an ordinary
;; workspace is the number again and for a special one is `special:scratchpad'.
(define-record-type <wm-workspace>
  (make-wm-workspace id name monitor)
  wm-workspace?
  (id wm-workspace-id) (name wm-workspace-name) (monitor wm-workspace-monitor))

;; x, y, WIDTH AND HEIGHT ARE IN THE COMPOSITOR'S ABSOLUTE DESKTOP SPACE, so a
;; window on the second monitor has an x past the first monitor's width. A widget
;; placing one inside a picture of its monitor subtracts `wm-monitor-x' of
;; `wm-client-monitor' -- which is exactly the subtraction that was missing when
;; the switcher's tiles came out three different sizes.
(define-record-type <wm-client>
  (make-wm-client address workspace monitor x y width height class title)
  wm-client?
  (address wm-client-address)
  (workspace wm-client-workspace)   ; a workspace id
  (monitor wm-client-monitor)       ; a monitor name
  (x wm-client-x) (y wm-client-y)
  (width wm-client-width) (height wm-client-height)
  (class wm-client-class) (title wm-client-title))

;;; ---------------------------------------------------------------------------
;;; The class every compositor subclasses
;;; ---------------------------------------------------------------------------

(define-class <wm> ()
  (name #:init-keyword #:name #:init-value "wm" #:accessor wm-name))

;;; The seven things a compositor answers for itself.

(define-generic wm-monitors)
(define-generic wm-workspaces)
(define-generic wm-clients)
(define-generic wm-focused-workspaces)

;; WHICH SCREEN THE USER IS LOOKING AT, which is a question only the compositor
;; can answer and which a popup needs: a popup is ONE window rather than one per
;; monitor, so something has to say which monitor it belongs on, and the focused
;; one is the answer for anything opened from the keyboard.
(define-generic wm-focused-monitor)
(define-generic wm-on-change)
(define-generic wm-focus-workspace!)
(define-generic wm-focus-client!)
(define-generic wm-focus-monitor!)
(define-generic wm-close-client!)

;; A DEFAULT METHOD FOR EACH, so an unimplemented operation says which one and
;; on which compositor rather than "no applicable method for #<generic ...>".
(define-syntax-rule (unimplemented (name arg ...) what)
  (define-method (name (self <wm>) arg ...)
    (error (format #f "the ~a window manager does not implement ~a"
                   (wm-name self) what))))

(unimplemented (wm-monitors) "listing monitors")
(unimplemented (wm-workspaces) "listing workspaces")
(unimplemented (wm-clients) "listing windows")
(unimplemented (wm-focused-workspaces) "which workspace each monitor is showing")
(unimplemented (wm-focused-monitor) "which monitor has the focus")
(unimplemented (wm-on-change proc) "change notification")
(unimplemented (wm-focus-workspace! id) "switching workspace")
(unimplemented (wm-focus-client! client) "focusing a window")
(unimplemented (wm-focus-monitor! name) "focusing a monitor")
(unimplemented (wm-close-client! client) "closing a window")

;;; ---------------------------------------------------------------------------
;;; The questions a widget asks, written once for every compositor
;;; ---------------------------------------------------------------------------

(define-method (wm-monitor-by-name (self <wm>) name)
  (find (lambda (m) (equal? (wm-monitor-name m) name)) (wm-monitors self)))

(define-method (wm-workspace-by-id (self <wm>) id)
  (find (lambda (w) (= (wm-workspace-id w) id)) (wm-workspaces self)))

(define-method (wm-clients-on (self <wm>) id)
  (filter (lambda (c) (and (wm-client-workspace c)
                           (= (wm-client-workspace c) id)))
          (wm-clients self)))

(define-method (wm-client-at (self <wm>) address)
  (find (lambda (c) (equal? (wm-client-address c) address)) (wm-clients self)))

(define-method (wm-focused-workspace (self <wm>) monitor-name)
  "The id of the workspace MONITOR-NAME is showing, or #f."
  (assoc-ref (wm-focused-workspaces self) monitor-name))

(define-method (wm-occupied-workspaces (self <wm>))
  "The ids of every workspace with at least one window on it."
  (delete-duplicates (filter-map wm-client-workspace (wm-clients self))))

;;; ---------------------------------------------------------------------------
;;; Which compositor this shell is talking to
;;; ---------------------------------------------------------------------------

(define %wm (make-parameter #f))

(define (wm-use! instance)
  "Install INSTANCE as this shell's window manager.

Called by an implementation as it loads, so a shell chooses a compositor by
importing one. Two at once is a bug rather than a feature, and saying so beats
silently using whichever loaded last."
  (when (and (%wm) (not (eq? (%wm) instance)))
    (error "a window manager is already installed" (wm-name (%wm))))
  (%wm instance)
  instance)

(define (wm)
  "The installed window manager."
  (or (%wm) (error "no window manager is installed; load (scheme-desktop wm hyprland)")))

(define (wm-loaded?) (and (%wm) #t))
