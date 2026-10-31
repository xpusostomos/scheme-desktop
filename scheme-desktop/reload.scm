;;; (scheme-desktop reload) -- rebuild the shell from the config
;;;
;;; THE ONE REBUILD.  It lives here rather than in `shell.scm' because
;;; `shell.scm' calls `(run-shell ...)' at load time -- importing it starts a
;;; shell -- so anything defined in it can only be tested by starting one.  This
;;; module has no such side effect: it imports, and nothing happens.
;;;
;;; IT REPLACES TWO THINGS.  `shell.scm' used to carry a `watch-bar-layout!'
;;; callback doing the same destroy-and-rebuild for a changed bar option, and
;;; `reload-shell!' doing it again for a changed file.  Two copies of one
;;; sequence, and the older one had a bug the newer one had already been fixed
;;; for: it presented EVERY window rather than only the visible ones, which is
;;; what takes the keyboard away from the user.
;;;
;;; WHY A REBUILD AT ALL, RATHER THAN RE-APPLYING VALUES.  An option that decides
;;; the bar's SHAPE -- its edge, its layout -- cannot take effect in place: the
;;; tree has to be built again.  And rather than work out which kind of option
;;; changed and rebuild only then, every change rebuilds: a bar is cheap, an
;;; editor that saves while you type produces one rebuild per pause, and a rule
;;; with a case per option is a rule to keep in step with the options.

(define-module (scheme-desktop reload)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit config)
  #:use-module (scheme-desktop widgets bar)
  ;; `build-dock!', which the per-monitor loop below calls beside `build-bar!'.
  #:use-module (scheme-desktop widgets dock)
  #:use-module (scheme-desktop style)
  #:use-module (scheme-desktop config)   ; load-user-config!, load-widget-config!
  #:use-module (ice-9 format)
  #:export (build-all-bars! reload-shell! present-visible-windows!))

(define* (build-all-bars! #:key (force? #f))
  "Build a bar for every monitor.

`for-each-monitor' keys a root per monitor, so a hotplug builds a bar for the
monitor that arrived and disposes the one that left.  A REBUILD passes force?:
the roots already exist, so without it nothing would be built and the bar would
simply disappear."
  (for-each-monitor
   (lambda (monitor name)
     (build-bar! monitor #:name "bar")
     ;; THE DOCK IS PER MONITOR TOO, and it is built in the same root as the bar
     ;; for the same reason: the root is what a hotplug disposes, so a monitor
     ;; that leaves takes its dock with it.  Only when the `dock' widget is LIVE
     ;; -- it is the user's list that says whether there is a dock, not this.
     (when (desktop-widget-named 'dock)
       (catch #t
         (lambda () (build-dock! monitor))
         (lambda (key . rest)
           ;; A dock that cannot be built must not take the bar down with it.
           (format (current-error-port) "scheme-desktop: cannot build the dock: ~a ~s~%"
                   key rest)))))
   #:force? force?))

(define (present-visible-windows!)
  "Show the windows that asked to be shown.

ONLY THE VISIBLE ONES, and this is the difference between a rebuild and a
keyboard lock.  `shell-windows' returns EVERY window of every window widget --
the bar's, and all the panels'.  Presenting them all means presenting the menu
and the workspace picker, which are `#:keymode 'exclusive` by design: asking for
the keyboard, and getting it.

`run-shell' says the same thing above its own present loop.  This is that loop,
and it is here so there is only one of it."
  (for-each (lambda (w)
              (when (window-visible? w)
                (catch #t (lambda () (present w)) (lambda args #f))))
            (shell-windows)))

(define (reload-shell!)
  "Re-read the config and the user's code, and rebuild the shell.

This is what a change to either file runs.  It is also what a keybinding can
call -- `scheme-toolkit eval '(reload-shell!)' -- which is how a user recovers
from a config they are halfway through editing.

The ROOTS go first.  Their cleanups are signal disconnects and child removals,
and those need the widgets alive: disposing after destroying is what produced
`instance with invalid (NULL) class pointer' in the monitor-root teardown."
  (catch #t
    (lambda ()
      (dispose-monitor-roots!)
      ;; The bar's windows are destroyed and built again.  A PANEL's are not:
      ;; `widget-window' is memoised, so asking again hands back the window that
      ;; is already there, and its own options were read when it was first built.
      (widget-destroy-windows! (bar))
      ;; THEN TELL EVERY WIDGET, because a widget is not only its windows: the
      ;; bar ITEMS built their trees inside the bar's window, which has just been
      ;; taken away, so each one has to forget what it built or the next apply
      ;; reaches a destroyed button.  #f is every output: a rebuild is the
      ;; teardown of the lot.
      ;;
      ;; AFTER the destroy, and the order matters: destroying the windows needs
      ;; the slots still populated to find them.
      (widgets-decommission! #f)
      ;; VALUES, THEN CODE, in the same order the shell started with -- values
      ;; into the slots, then the user's file, which may override them.  Both,
      ;; because a rebuild that re-read only config.scm would discard everything
      ;; init.scm set up.
      ;; FLUSH BEFORE READING, or the read undoes the change that asked for the
      ;; rebuild.  A change made from code is saved after a debounce, and this
      ;; reload was deferred by an idle, which runs first -- so without this the
      ;; file does not yet say what memory says, the load puts the old value
      ;; back, and the pending save then writes that old value out.  Silent, and
      ;; measured: widening the root's widget list did nothing at all.
      (when (widget-config-save-pending?) (widget-config-save!))
      (load-widget-config!)
      ;; THE LIVE SET FOLLOWS THE LIST before anything is built from it.  The
      ;; file may name a different set of widgets than the one that is live, and
      ;; `build-all-bars!' resolves the layout against the registry -- so the
      ;; registry has to be right first.  Idempotent, so the usual case (the list
      ;; did not change) costs a walk of the names and nothing else.
      (root-sync! (desktop-widget-required 'root))
      (load-user-config!)
      (apply-shell-css!)             ; the stylesheet is a function of them
      (build-all-bars! #:force? #t)
      (present-visible-windows!)
      #t)
    (lambda (key . rest)
      ;; A FAILED RELOAD MUST NOT TAKE THE SHELL DOWN.  The old bar is gone, but
      ;; the process still has a REPL, and the REPL is where the fix gets made --
      ;; which is exactly the moment a user needs it.  This runs from a GLib fd
      ;; callback, where an escaping error does not fail a reload, it fails the
      ;; process; the guard is here as well as in the watcher because this can
      ;; also be called from a keybinding.
      (format (current-error-port)
              "scheme-desktop: cannot reload: ~a ~s~%" key rest)
      #f)))
