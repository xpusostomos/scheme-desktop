;;; (scheme-desktop widgets) -- which widgets this shell ships, and which are live
;;;
;;; TWO DIFFERENT THINGS, AND THIS FILE USED TO CONFUSE THEM.
;;;
;;;   WHAT THE SHELL SHIPS.  The classes -- `<clock-desktop-widget>' and the rest
;;;   -- in the widget modules, imported below.  These are compiled code: they
;;;   cannot change while the shell runs, and every one of them is available.
;;;
;;;   WHAT THE USER WANTS LIVE.  Below, as DEFAULT-WIDGET-NAMES: the set a fresh
;;;   install gets.  It is an OPTION, on the root widget, so it lives in the
;;;   user's config file and the user's own code overrides it.
;;;
;;; WHAT WAS WRONG BEFORE.  This file did `(make <x>)' fifteen times at import.
;;; So every widget the shell could ever draw was INSTANTIATED before anything --
;;; the user, the config file -- had an opinion, and a user who wanted no tray
;;; got a tray.  The list of live widgets is the user's decision, and a module is
;;; the wrong place for it twice over: it is read once per process, and it cannot
;;; hold an opinion about a file.
;;;
;;; SO THE ROOT WIDGET OWNS IT NOW.  `(root-desktop-widget)' holds the list, makes
;;; what it names, and drops what it stops naming.  This file only says what the
;;; list STARTS as, and where the classes are to be found.
;;;
;;; A WIDGET BEING LIVE DOES NOT PUT IT IN THE BAR.  The bar's own `layout'
;;; option names which live widgets go in which section, so a panel that is only
;;; opened by a keybinding is live and simply never named in the bar -- which is
;;; the whole point of the network panel being its own widget rather than part of
;;; the network bar button.
;;;
;;; THE ORDER BELOW IS THE ORDER a settings window would list them: by feature,
;;; a feature's bar item, then its panel.

(define-module (scheme-desktop widgets)
  #:use-module (scheme-toolkit app)
  ;; Every widget module, so this file is the only place that knows the set --
  ;; and so that every `<foo-desktop-widget>' is reachable from THIS module,
  ;; which is what `widget-class-named' resolves a name against.
  #:use-module (scheme-desktop widgets theme)
  #:use-module (scheme-desktop widgets bar clock)
  #:use-module (scheme-desktop widgets bar workspaces)
  #:use-module (scheme-desktop widgets battery)
  #:use-module (scheme-desktop widgets audio)
  #:use-module (scheme-desktop widgets bluetooth)
  #:use-module (scheme-desktop widgets bar media)
  #:use-module (scheme-desktop widgets bar tray)
  #:use-module (scheme-desktop widgets bar)
  #:use-module (scheme-desktop widgets date-menu)
  #:use-module (scheme-desktop widgets menu)
  #:use-module (scheme-desktop widgets network)
  #:use-module (scheme-desktop widgets overview)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:export (<desktop-root-widget> default-widget-names))

;;; ---------------------------------------------------------------------------
;;; The set this shell ships
;;; ---------------------------------------------------------------------------
;;
;; NAMES, not classes: a name is what the user writes in their file, and
;; `widget-class-named' turns it into a class -- accepting `clock' or
;; `<clock-desktop-widget>', because the mapping is mechanical both ways and a
;; user should not have to know which form this list happens to use.
;;
;; `bar' IS IN THE LIST like anything else.  It used to be a special case --
;; built by hand, registered by hand, thrown away by hand -- because it had to
;; exist before the config was read.  The root owns that now, so the bar is made
;; and unmade by the same path as the rest.

(define default-widget-names
  '(;; the theme.  Owns `ui-scale', which no bar item or panel has any business
    ;; owning.  It draws nothing; it is a thing the shell has, which is all a
    ;; widget has to be.
    theme
    ;; the bar itself
    bar
    ;; the menu
    menu
    menu-panel
    ;; workspaces.  THE PANEL IS ITS OWN WIDGET, not a sub-widget of the pill: a
    ;; window picker belongs on a keybinding -- alt-tab, a workspace key -- and
    ;; binding one must not mean reaching through the bar.
    workspaces
    overview
    ;; the date and time
    datemenu
    datemenu-panel
    clock
    ;; media
    media
    ;; network
    network
    network-panel
    ;; bluetooth, audio, battery
    bluetooth
    bluetooth-panel
    ;; audio -- the panel, and the now-playing block inside it.  THIS REPLACED
    ;; the old `volume' bar item, a separate widget that showed an image and a
    ;; percentage; the panel does everything it did and more, so the widget was
    ;; removed rather than left to draw a second, stale volume in the bar.
    audio
    audio-panel
    battery
    battery-panel
    ;; the tray
    tray))

;;; ---------------------------------------------------------------------------
;;; The root
;;; ---------------------------------------------------------------------------

;; WHERE A NAME IS LOOKED UP.  The toolkit resolves a name to a class through
;; GOOPS and cannot know where a shell keeps its classes, so the shell says --
;; once, here, in the module that imports them all.
(widget-class-module! (current-module))

;; THE SHELL'S ROOT, and the only reason it is a subclass at all is the default
;; above: the list is the shell's decision, so it belongs in the shell's code,
;; while the machinery that acts on it belongs to the toolkit.
;;
;; THE `#:init-value' IS LOAD-BEARING BEYOND STARTUP.  It is what the option
;; reverts to when the file stops naming it -- so deleting the config file gives
;; a shell with the shipped widgets, not a shell with none.
;;
;; WHICH IS WHY THE SLOT IS REDECLARED RATHER THAN THE VALUE PASSED IN.  A
;; `#:widgets' keyword on `make' would set the value and leave the DEFAULT as
;; the toolkit's empty list -- so a deleted file would leave the shell with no
;; widgets at all, which is the opposite of what a default is for.
;;
;; AND IT IS REDECLARED IN FULL, not just `#:init-value'.  A slot redefined in a
;; subclass is a NEW slot definition, so everything the parent said about it has
;; to be said again: without `#:accessor' the parent's accessor has no method for
;; this class (measured), and without `#:config' the option stops being one --
;; it would vanish from the file and from the settings widget with no error.
;;
;; THE CLASS NAME IS NOT `<root-desktop-widget>', which is what the naming rule
;; would want, because that is the class being subclassed.  The root's widget
;; name is fixed rather than derived for exactly this reason; see the method in
;; the toolkit.
(define-class <desktop-root-widget> (<root-desktop-widget>)
  (widgets #:init-value default-widget-names
           #:init-keyword #:widgets
           #:accessor root-widgets #:setter root-widgets-set!
           #:config '(list) #:label "Which widgets are live"))
