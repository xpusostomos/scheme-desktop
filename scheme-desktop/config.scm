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
;;;
;;; LOADING AND WATCHING ARE (scheme-utils)'s.  This module used to carry its
;;; own loader and its own copy of Hyprscheme's watcher, which made a third
;;; copy of machinery that is not about this shell: a shell decides WHAT to
;;; load and what a reload means, and the reading and the watching are the
;;; same wherever they happen.  What is left here is those two decisions and
;;; nothing else.

(define-module (scheme-desktop config)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit config)
  #:use-module (scheme-toolkit file)
  #:use-module (scheme-toolkit app)
  ;; The loader and the watcher, from the tree that is neither this shell nor
  ;; the toolkit.  `(scheme-utils watch)' also carries Hyprscheme's inotify
  ;; layer, so (scheme-toolkit inotify) is gone with it.
  #:use-module (scheme-utils load)
  #:use-module (scheme-utils watch)
  #:export (shell-config-dir shell-config-file shell-init-file
            start-shell-config! load-user-config!
            user-module user-load user-load-config))

;; Where the shell's options live, following the XDG spec rather than a
;; hard-coded ~/.config: a user with XDG_CONFIG_HOME set expects it honoured,
;; and a test can point it at a scratch directory.
(define shell-config-dir
  (string-append (xdg-config-home) "/scheme-desktop"))

(define shell-config-file
  (string-append shell-config-dir "/config.scm"))

;; THE USER'S OWN CODE, which is a different thing from the file above and is
;; loaded after it.  config.scm holds VALUES the shell reads and rewrites;
;; init.scm holds CODE the user writes and we never touch.  Loading it second is
;; what lets it read and override what config.scm set, and what makes
;; `(user-load-config "keybinds")' from inside it work.
(define shell-init-file
  (string-append shell-config-dir "/init.scm"))

;; NO SEPARATE WIDGET REGISTRATION, and no call for the shell to remember: the
;; widgets are registered by `(scheme-desktop widgets)', which is the one
;; registration this shell has, and the engine RESOLVES names through that
;; registry when it reads or writes. So all this says is where the file is.
;;
;; The widgets are a THUNK because the bar does not exist until the first
;; `build-bar!', and it must still be written: a list captured here would be a
;; shell that never saves its own layout.
(widget-config-setup! (lambda () (desktop-widgets)) shell-config-file)

;; THE FLAT ENGINE IS GONE, and with it the schema that duplicated what the
;; widgets now declare.  `(scheme-toolkit config)' still holds that engine for a
;; shell that wants it -- the value machinery, the file monitor, the atomic
;; write -- but this shell's options are all widget options, and one engine
;; reading one file is the whole point of the change.
;;
;; What replaced `define-config' here is a single line saying WHERE the file is.
;; There is no list of options because there is no longer a second declaration
;; of them: each widget declares its own, and the engine finds them by walking
;; the registry.

;;; ---------------------------------------------------------------------------
;;; The user's own code
;;; ---------------------------------------------------------------------------
;;
;; TWO FILES, TWO JOBS.
;;
;;   config.scm   VALUES.  The shell writes it, the user reads it, and it is
;;                rewritten whenever an option changes -- including by a settings
;;                widget, and including by init.scm below.
;;
;;   init.scm     CODE.  The user writes it and the shell never touches it.  This
;;                is where anything that is not a static value goes: something
;;                computed, something conditional, something that depends on
;;                which machine this is.
;;
;; LOADED SECOND, so the user can read and override what config.scm set -- and so
;; that a value init.scm computes is the one a settings widget then shows.
;;
;; WHY A MODULE RATHER THAN A PLAIN `load'.  The user's file is evaluated in
;; `(scheme-desktop user)', which imports the shell's modules, so their code can
;; call `widget-config-set!', `bar-add-widget!', `user-load-config' and anything
;; else by name.  A plain `load' would run it in whatever module happened to be
;; current -- for a shell started with `-e main -s', that is `(guile-user)',
;; where none of those names exist.
;;
;; AND WHY NOT `use-modules'.  One generation only, ever, and never re-read on a
;; change: the point of a reload is to evaluate the file again, and only `load'
;; does that.

(define %user-module #f)

(define (user-module)
  "The module the user's config is evaluated in, created on first ask.

It imports the shell's modules so the user's code has the shell's names, and it
is created with `define-module' rather than by hand so that those imports are
declared rather than assembled -- an assembled use-list is a thing to keep in
step with, and this one has no reason to be dynamic.

IT ALSO TELLS THE LOADER WHERE TO EVALUATE.  `auto-load' reads its target from
`auto-load-module!', and naming it here -- the one place the module is made --
is what keeps the two from drifting apart."
  (unless %user-module
    (eval '(define-module (scheme-desktop user)
             #:use-module (ice-9 format)
             #:use-module (scheme-toolkit config)
             #:use-module (scheme-toolkit app)
             #:use-module (scheme-desktop config)
             ;; THE MENU, so a config can edit it. `menu-splice' is what makes
             ;; that worth doing: a user adds one row to the Omarchy tree rather
             ;; than retyping the whole menu, and `menu-set!' installs the result:
             ;;
             ;;   (menu-set! (menu-splice (menu) my-entry '(trigger share file)))
             #:use-module (scheme-desktop menu)
             #:use-module (scheme-desktop widgets bar))
          (current-module))
    (set! %user-module (resolve-module '(scheme-desktop user)))
    (auto-load-module! %user-module))
  %user-module)

(define (user-load path)
  "Load PATH into the user's module; #t when it loaded, #f when it raised.

This is the call a config uses to pull in a file, and the contract is
Hyprscheme's: the file's defines land where the next reload will discard them,
an error in it does NOT stop the rest of the config, and this answers whether it
loaded so a caller can tell a file that died halfway from one that worked.

PATH is used exactly as given: no search, and no `.scm' appended.  `user-load-config'
is the one that resolves a name under the config directory."
  (user-module)                 ; the target, set if this is the first call
  (auto-load path))

(define (user-load-config name)
  "Load NAME.scm from the shell's config directory, and return its path or #f.

A convenience, and only that.  It resolves a name the way a user means it --
`(user-load-config \"keybinds\")' for ~/.config/scheme-desktop/keybinds.scm --
and then it is `user-load'.

The resolution is what earns it. A path written by hand in init.scm has to
repeat the config directory, and a config directory that moves (XDG_CONFIG_HOME
set on one machine and not another) then breaks the file rather than the lookup."
  (user-module)
  (auto-load-config name))

(define (load-user-config!)
  "Evaluate the user's init.scm, if there is one.  #t, #f, or #f when absent.

ABSENT IS NOT A FAILURE.  A user who has written no init.scm is the normal case
on a fresh install, not an error, and the shell must come up exactly as it does
with an empty one."
  (and (file-exists? shell-init-file)
       (user-load shell-init-file)))

(define* (start-shell-config! #:optional reload)
  "Load the config, then the user's code, and apply any change to either.

RELOAD, when given, is called with no arguments instead for a change -- that is
how a shell rebuilds rather than re-applying values.  A shell-level name so that
`shell.scm' says what it means rather than naming toolkit procedures."
  ;; A PENDING SAVE IS FLUSHED ON THE WAY OUT, and without this a repair made in
  ;; memory can be lost entirely.
  ;;
  ;; Saves are DEBOUNCED -- 400 ms -- so that dragging a slider writes once rather
  ;; than once a frame, and only the RELOAD path ever flushed a pending one (see
  ;; `reload-shell!', which flushes because a read that raced a pending write
  ;; would undo the change).  Nothing flushed on SHUTDOWN, so a layout corrected
  ;; during startup -- `prune-layout!' translating a renamed widget, which is
  ;; exactly the repair that matters -- was written back only if the shell
  ;; happened to live past the debounce.  Killing a shell within that window left
  ;; the stale file in place, so the repair was repeated on every start and the
  ;; user saw the same "my config lost a widget" for ever.
  ;;
  ;; Once per call: `start-shell-config!' runs at startup, so this is one
  ;; connection, not one per rebuild.
  (catch #t
    (lambda ()
      (let ((app (app-instance)))
        (when app
          (connect app 'shutdown
                   (lambda (a)
                     (catch #t
                       (lambda () (when (widget-config-save-pending?) (widget-config-save!)))
                       (lambda args #f)))))))
    (lambda args #f))
  ;; THE LOADER'S TWO FACTS, said here because only the shell knows them: where
  ;; a bare config name resolves, and which module the user's code is
  ;; evaluated in.
  (auto-config-dir! shell-config-dir)
  (user-module)
  ;; THE WATCHER IS ARMED BEFORE ANYTHING IS LOADED, and that ordering is the
  ;; whole of how it works.  `auto-watch-start!' turns recording on, and
  ;; recording is driven by Guile's `%load-hook' -- so every file the config
  ;; pulls in from this point is recorded, including files reached by
  ;; `user-load-config' from inside init.scm, which nothing here could name.
  ;;
  ;; `#:watch? #f' on the widget engine, and it is not a contradiction: THAT
  ;; watcher is the reload engine's job now.  A change means a rebuild rather
  ;; than a pass over the values, and the rebuild re-reads the file anyway.
  (when reload
    (auto-watch-configure! #:reload reload)
    (auto-watch-start!))
  (widget-config-start! #:watch? #f)
  ;; THE ORDER MATTERS: values, then code.
  (load-user-config!)
  (when reload
    ;; CONFIG.SCM IS NOT WATCHED, DELIBERATELY.  It is the shell's own file: the
    ;; engine writes it whenever an option changes, so a watch on it means the
    ;; shell reloads itself in response to its own save -- every option change,
    ;; however small, dragging a whole rebuild behind it.  That is what made a
    ;; hotkey for transparency cost a rebuild.
    ;;
    ;; WHAT IT COSTS.  Editing config.scm by hand does nothing until the shell
    ;; is restarted, or until something calls the reload API.  That is the right
    ;; way round: it holds VALUES the shell reads and rewrites, and removing a
    ;; widget from it is a config editor's job, not a text editor's.
    ;;
    ;; INIT.SCM IS WATCHED, and it is the only file that is.  It holds CODE the
    ;; user writes and the shell never touches, so a change to it is always
    ;; genuinely the user's.
    ;;
    ;; NAMED, and not because the load hook misses it: the hook records a file as
    ;; it STARTS to load, while this records it as it now stands, which is what
    ;; the first change is compared against.
    (auto--watch-begin! shell-init-file))
  #t)
