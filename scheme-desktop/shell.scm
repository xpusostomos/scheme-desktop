;;; (scheme-desktop shell) -- entry point
;;;
;;; Run with:  bin/scheme-desktop run
;;;
;;; Small on purpose.  The work is in scheme-toolkit: this file says which
;;; windows this shell has, which is the one thing that makes it a shell rather
;;; than a toolkit demo.

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit app))
;; THE SHELL CHOOSES ITS COMPOSITOR, by loading one implementation of
;; (scheme-desktop wm). Nothing else names Hyprland: the widgets ask `wm' for
;; monitors, workspaces and clients and would work unchanged on another.
(use-modules (scheme-desktop wm hyprland))
(use-modules (scheme-desktop style))
(use-modules (scheme-desktop widgets))      ; the root's class
;; The manifests, the plugins and the first-run config.  See below.
(use-modules (scheme-desktop manifest))
(use-modules (scheme-desktop widgets bar))
;; For `shell-config-file' and the one line that starts the widget config.
(use-modules (scheme-desktop config))
;; Imported for its side effect of being loaded, so that a keybinding's
;; (scheme-desktop api) expression resolves over the REPL.  Nothing here calls
;; it -- the shell's own vocabulary is called FROM outside.
(use-modules (scheme-desktop api))

;; THE REBUILD LIVES IN (scheme-desktop reload).  It moved there because this
;; file calls `(run-shell ...)' at the bottom, so importing it starts a shell --
;; and anything defined here could only be tested by starting one.
;;
;; `build-all-bars!` and `reload-shell!` were both defined here, and
;; `watch-bar-layout!` below carried a THIRD copy of the same destroy-and-rebuild.
;; That third one had the bug `reload-shell!` had already been fixed for: it
;; presented every window rather than only the visible ones.
(use-modules (scheme-desktop reload))

(define (main . args)
  ;; THE ROOT FIRST, AND IT MAKES EVERYTHING ELSE.  It is the one widget this
  ;; shell creates by hand -- it cannot be in its own list, so somebody has to
  ;; put it there -- and `root-start!' then does the two things a custodian does:
  ;; makes the live set match the list, and subscribes to the list so that
  ;; changing it changes the set.
  ;;
  ;; BY HAND, AND HERE RATHER THAN AT LOAD, because loading is what makes the
  ;; classes exist and the list is data: a registry filled at import is a
  ;; registry filled before anyone can have an opinion, which is what this
  ;; replaced.
  ;;
  ;; BEFORE THE CONFIG, because the widgets the file's options belong to have to
  ;; exist before it is read.  The bar is one of them now -- it used to be built
  ;; by hand here for that reason, and it comes out of the root like the rest.
  ;;
  ;; THE PLUGINS' MODULES RESOLVE FIRST, so that the names in the list can be.
  ;; And THE LIST IS THE FILE'S -- written now when there is none, by every
  ;; built-in widget and installed plugin enabling itself -- so the root has its
  ;; widgets before the rest of the file, their options, is applied to them.
  ;; An empty config is `run`'s, deliberately: a root made from a default list
  ;; would put every widget in `-e main`, which is the live shell.
  (add-plugin-load-paths!)
  (register-desktop-widget!
   (make <desktop-root-widget> #:widgets (config-root-widgets (ensure-config!))))
  ;; AND IT IS HANDED THE REBUILD, because changing the list is a model change
  ;; and the views have to follow: the root syncs the registry, then calls this,
  ;; and this is the same rebuild a changed bar layout option uses.  Without it
  ;; the registry loses a widget the trees still point at -- measured, and it
  ;; does not warn, it segfaults.
  ;; NO `#:on-change'.  A change to the list used to rebuild the shell; now the
  ;; root syncs the registry and every widget that built something out of it
  ;; re-looks -- the bar reconciles its sections -- so there is nothing for the
  ;; shell to do and no rebuild to ask for.
  (root-start! (desktop-widget-required 'root))
  ;; WITH THE REBUILD, so an edit to the config file rebuilds the shell.  The
  ;; loading and the watching are (scheme-utils)'s; the rebuild is ours, and
  ;; handing it over here is the whole of what this shell supplies -- see
  ;; (scheme-desktop config), which also says where a config loads to.
  (start-shell-config! reload-shell!)
  ;; THE SETTINGS MENU, spliced into the menu Omarchy provides.  AFTER the
  ;; config has been loaded, because the rows are generated from the widgets'
  ;; declarations and their CURRENT values -- so what the menu shows is what the
  ;; shell is actually running with.
  (catch #t
    (lambda () ((@ (scheme-desktop settings-menu) settings-splice!)))
    (lambda (key . args)
      (catch #t
        (lambda ()
          ((@ (scheme-toolkit result) log-error) (cons key args)
           "splicing the settings menu into the menu"))
        (lambda a #f))))
  (build-all-bars!)
  ;; AND FOLLOW THE DESKTOP'S THEME WHILE WE RUN.  The stylesheet is generated
  ;; from the palette, the palette is a file the desktop rewrites when the
  ;; wallpaper or theme changes, and until this line nothing watched it -- so the
  ;; shell was themed once at startup and never again.
  (watch-theme-file!)
  ;; Then the windows the bar's modules own -- the date menu, and later the
  ;; launcher and the control centre.  Built once rather than per monitor: a
  ;; popup follows the focused monitor instead of existing on every one.
  (build-bar-windows!)

  ;; A CHANGE TO A LAYOUT OPTION REBUILDS, the same as a change to the file.
  ;; This used to be its own copy of the sequence, which is how it came to miss
  ;; the fix for presenting every window.  One rebuild, called from two places.
  ;; NOTHING ELSE TO WIRE.  Every bar option applies itself now -- see the end of
  ;; (scheme-desktop widgets bar) -- so there is no list of options that rebuild
  ;; the shell and no hook to register a rebuild in.  What is left here is the
  ;; startup: the root, the config, the bars, the panels.
  #t)

(run-shell #:instance "scheme-desktop" #:main main)
