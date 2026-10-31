;;; (scheme-desktop style) -- this shell's stylesheet
;;;
;;; PORTED FROM ags2-shell.  The rule bodies below are copied from its
;;; style/compile/main.css (itself compiled from style/base/*.scss and
;;; widget/Bar/style.scss), and the variables come from (scheme-desktop theme).
;;; The aim is that a bar built here looks the same as theirs, so the rule
;;; bodies are not paraphrased -- where a selector has been changed it is only to
;;; match this shell's widget structure, never the declaration.
;;;
;;; WHY THE BODIES ARE COPIED RATHER THAN REINVENTED.  The difference between a
;;; tray icon that looks right and one that has a rounded box around it is one
;;; declaration -- `all: unset' -- and there is no way to guess it.  Getting
;;; these right by trial costs a round trip to a pair of eyes each time; copying
;;; costs nothing.
;;;
;;; THE WIDGETS THEMSELVES CARRY NO STYLING.  (scheme-toolkit tray) emits a box
;;; with class `tray' and buttons with class `tray-item' and nothing else -- no
;;; colour, no radius, no shadow.  Everything visual lives here, in the shell,
;;; so a different shell can reuse the widget and style it differently.  The
;;; class names are the contract; this file is one implementation of it.
;;;
;;; PROVIDER PRIORITY is USER (800), from (scheme-toolkit style): it beats GTK's
;;; own stylesheet and libadwaita's, which is what a shell needs to own its
;;; appearance.

(define-module (scheme-desktop style)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit style)
  #:use-module (scheme-toolkit palette)
  ;; For `monitor-file', which is how a change to the desktop's palette reaches
  ;; the stylesheet while the shell is running.  PREFIXED, because `(g-golf)'
  ;; exports a `monitor-file' of its own (Gio's) and importing both is a name
  ;; that resolves by import order -- a warning now and a mystery later.
  #:use-module ((scheme-toolkit file) #:prefix file:)
  #:use-module (scheme-desktop theme)
  #:use-module (srfi srfi-11)
  #:export (apply-shell-css! shell-css shell-provider shell-palette
            watch-theme-file!))

(define (watch-theme-file!)
  "Re-apply the stylesheet when the desktop's palette file changes.

THE SHELL FOLLOWS OMARCHY'S THEME, which is a file the desktop rewrites when the
wallpaper or the theme changes -- and NOTHING WAS WATCHING IT.  So the shell was
themed correctly at startup and then stayed that way for the rest of the session,
however many times the desktop changed its mind.

The re-application is the whole mechanism: `shell-provider' re-parses only when
the CSS TEXT changes, and the text changes because the palette it is generated
from did.  Nothing else has to be told -- the one provider is shared by every
toplevel, so every window is recoloured at once.

A MONITOR, not a poll: `monitor-file' is a Gio file monitor, watching the path the
palette was found at.  That path is `~/.local/state/omarchy/current/theme/
colors.toml', and `current' is a real DIRECTORY on this desktop rather than a
symlink -- so a theme switch rewrites this file in place and the monitor sees it.
(Checked with `stat', because if it were a symlink the monitor would be on the
file it resolved to and a swap would go unnoticed.)"
  ;; `find-palette-file' ANSWERS A PAIR -- (path . reader) -- and monitoring the
  ;; pair instead of the path is what this did first: `monitor-file' refused it,
  ;; the `catch' here swallowed the refusal, and the shell ran with no watcher at
  ;; all while appearing to have one.  The failure is now SAID rather than caught
  ;; into silence, because "the theme never updates" and "the watcher was never
  ;; installed" look identical from the outside.
  (let ((found (catch #t (lambda () (find-palette-file)) (lambda args #f))))
    (let ((path (and (pair? found) (car found))))
      (if (not path)
          (format (current-error-port)
                  "scheme-desktop: theme: no palette file found to watch~%")
          (let ((stop (catch #t
                        (lambda ()
                          (file:monitor-file path
                                             (lambda (kind changed)
                                               (catch #t (lambda () (apply-shell-css!))
                                                      (lambda args #f)))))
                        (lambda args #f))))
            (if stop
                #t
                (format (current-error-port)
                        "scheme-desktop: theme: cannot watch ~a -- the shell will not follow theme changes~%"
                        path)))))))

(define (shell-palette)
  "The palette in force: the desktop's own theme, or the built-in default."
  (or (read-palette) default-palette))

;;; ---------------------------------------------------------------------------
;;; Base and controls -- ags2-shell style/base/{_foundation,_primitives,_native}
;;; ---------------------------------------------------------------------------

(define %base-css
  "
/* ---- base ------------------------------------------------------------- */

/* ags2-shell's `%outlined-button', which its bar's `%flat-button' extends.
   `all: unset' is the load-bearing line and the reason this file is a port
   rather than a design: without it GTK's own button background and shadow
   survive, and a tray icon gets the rounded box that prompted all of this. */
button {
  all: unset;
  transition: var(--transition);
  border-radius: var(--radius);
  color: var(--fg);
  padding: var(--padding);
  background-color: var(--widget-bg);
  box-shadow:
    inset 0 0 0 var(--border-width) var(--border-color),
    var(--neu-button-highlight),
    var(--neu-button-shadow);
  font-weight: bold;
}

button:hover:not(.active) {
  background-color: var(--hover-bg);
  color: var(--hover-fg);
  box-shadow:
    inset 0 0 0 var(--border-width) var(--border-color),
    var(--neu-button-hover-highlight),
    var(--neu-button-hover-shadow);
}

button:focus-visible {
  outline: calc(var(--border-width) / 2) solid var(--primary-bg);
  outline-offset: -1px;
}

button:active,
button.on,
button.active,
button:checked {
  background-image: var(--active-gradient);
  background-color: var(--primary-bg);
  color: var(--primary-fg);
  box-shadow:
    inset 0 0 0 var(--border-width) var(--border-color),
    var(--neu-button-active-highlight),
    var(--neu-button-active-shadow);
}

button:disabled {
  box-shadow: none;
  background-color: transparent;
  color: color-mix(in srgb, var(--fg) 30%, transparent);
}

/* `%flat-button': what every button IN THE BAR is.  Two declarations, and they
   are why the bar's buttons are flat while a dialog's are raised. */
window#bar button {
  background-color: transparent;
  box-shadow: none;
}

/* THE HOVER SHADOW HAS TO BE RE-ASSERTED WITH THE SAME ID, and this is a
 * pure specificity problem rather than a styling choice.
 *
 * `window#bar button' scores (1,0,2) -- it contains an ID.  The base rule
 * `button:hover:not(.active)' scores (0,2,1) -- two classes and an element.
 * An ID outranks any number of classes, so the flat rule above strips
 * box-shadow in EVERY state, hover included, and no amount of reordering
 * fixes it.
 *
 * The symptom is worth recognising: a shadow that appears on CLICK and never
 * on hover.  `:active' survives only because the base stylesheet happens to
 * name `window#bar button.active' in that selector too, which is why the
 * circle was visible for the instant of a press and absent otherwise.
 *
 * ags2-shell's compiled CSS has this same hole, so this is a second deliberate
 * difference.  The declarations are its own hover values, unchanged. */
window#bar button:hover:not(.active) {
  background-color: var(--hover-bg);
  color: var(--hover-fg);
  box-shadow:
    inset 0 0 0 var(--border-width) var(--border-color),
    var(--neu-button-hover-highlight),
    var(--neu-button-hover-shadow);
}

image {
  -gtk-icon-size: var(--icon-size, 16px);
}

window {
  background-color: var(--bg);
  color: var(--fg);
}

/* A POPUP IS AS BIG AS THE SCREEN, SO IT MUST NOT BE PAINTED LIKE A WINDOW.
   The rule above gives every window the theme's background, which is right for
   a bar or a dialog and wrong for a popup: a popup window is anchored to all
   four edges, so painting it paints the whole desktop -- which is what a panel
   opening looked like: the screen dimmed and a card appeared on it.  The panel's
   own card carries the background (box.datemenu, .menu, .network-panel all set
   it), so the window around it wants nothing.

   `#:darken-background #t' on a popup puts a background back, and this is the
   rule it gets: a translucent black, for a switcher that wants the desktop
   pushed back behind it. */
window.popup-window {
  background-color: transparent;
}

window.popup-window.dimmed {
  background-color: rgba(0, 0, 0, 0.35);
}

separator.horizontal { min-height: var(--border-width); }
separator.vertical   { min-width: var(--border-width); }

tooltip {
  background-color: transparent;
  border: none;
}

tooltip label {
  background-color: var(--bg);
  border-radius: var(--radius);
  border: var(--border-width) solid var(--popover-border-color);
  color: var(--fg);
  padding: 8px;
  margin: 4px;
  box-shadow:
    0 0 3px 0 var(--shadow-color),
    var(--neu-widget-highlight),
    var(--neu-widget-shadow);
}

/* ---- popovers: the tray's menus and the bar's own ---------------------- */

/* THE SELECTOR IS `window#bar popover contents', NOT `popover.menu > contents',
 * and that is not a style preference.
 *
 * `popover.menu' matches a Gtk.PopoverMenu -- GTK gives one that class.  A
 * plain Gtk.Popover has NO class at all, and the tray's menus are plain
 * popovers (they have to be: PopoverMenu cannot render a DBusMenuModel).
 * So a `popover.menu' selector matches NOTHING for a tray menu, and every rule
 * written that way is dead text -- which is what made the menu opaque, in the
 * wrong colour, with the wrong corners.  ags2-shell's own selector is
 * `window#bar popover contents', which matches both.
 *
 * The bare `popover' rules below are for the MENU container -- GTK draws its
 * own background and shadow behind the contents, and they have to be cleared or
 * a square shows through the rounded corners. */
window#bar popover {
  background: transparent;
  box-shadow: none;
  border: none;
}

window#bar popover > arrow {
  background: transparent;
  box-shadow: none;
  border: none;
}

window#bar popover contents {
  box-shadow: 0 0 5px 0 var(--shadow-color);
  margin: max(var(--spacing), 8px);
  margin-top: calc(max(var(--spacing), 8px) + var(--padding) * 0.3);
  border: var(--border-width) solid var(--popover-border-color);
  background-color: var(--bg);
  color: var(--fg);
  border-radius: calc(var(--popover-radius) / 2);
  padding: calc(var(--padding) / 2);
}

/* The tray's own menu box.  min-width is their value, and the padding on a row
 * is what gives a menu its height. */
window#bar popover contents .tray-menu {
  min-width: calc(180px * var(--scale, 1));
}

window#bar popover contents button.model-item {
  background-color: transparent;
  box-shadow: none;
  transition: var(--transition);
  border-radius: var(--radius);
  color: var(--fg);
  padding: calc(var(--padding) * 0.8);
  min-height: 0;
  margin: 0;
}

window#bar popover contents button.model-item:hover:not(.active) {
  background-color: var(--hover-bg);
  color: var(--hover-fg);
}

/* The tick sits before the label; the gap is what stops it touching the text. */
window#bar popover contents .tray-menu button.model-item .check {
  margin-right: calc(var(--spacing) / 2);
}

/* The dividing rule between menu sections.  Without this the separator has no
 * height and is invisible, which is why the line before Quit was missing. */
window#bar popover contents .tray-menu separator {
  margin: calc(var(--radius) / 2);
  min-height: 1px;
  background-color: color-mix(in srgb, var(--fg) 20%, transparent);
}

popover.menu > contents separator {
  margin: calc(var(--radius) / 2);
  min-height: 1px;
  background-color: color-mix(in srgb, var(--fg) 20%, transparent);
}
")

;;; ---------------------------------------------------------------------------
;;; The bar
;;; ---------------------------------------------------------------------------

(define %bar-css
  "
/* ---- the bar ---------------------------------------------------------- */

window#bar {
  background-color: transparent;
}

/* ags2-shell wraps its bar's contents in a box.panel that carries the
   background, which is what lets the window itself stay transparent -- the
   reason their screen-corner decorations can draw outside the bar.  This shell
   has no such wrapper yet, so the class carries the same declarations on the
   centrebox.  Same rule body, different element. */
window#bar .panel {
  transition: var(--transition);
  background-color: var(--bg);
  padding: calc(var(--padding) * 0.3);
}

window#bar .panel > box {
  margin: 0 calc(var(--spacing) / 2);
}

/* Every button in the bar, at the size ags2-shell uses.  `calc(var(--padding)
   / 2)' is 4pt, and on a 16px icon that makes a ~26px box -- which with
   --radius 12px is close enough to half its side to read as a circle on hover.
   That is the whole of the circle-vs-squircle question. */
window#bar button {
  padding: calc(var(--padding) / 2);
}

/* THE UNDERLINE UNDER THE BUTTON WHOSE PANEL IS OPEN.  A short pill on the INNER
   edge of the bar -- the edge facing the desktop -- centred on the button, in the
   accent colour, with the glyph taking the same colour.  It reads as 'this panel
   is open' rather than as a button being held down.

   `button.panel-button' AND NOT `button.active': `.active' is on every button
   that reports a state it OWNS -- a focused workspace is `.active' too -- so a
   plain `button.active' rule would underline the workspace pill.

   THE MARK IS THE FULL WIDTH OF THE BUTTON, which is the fix for two reported
   faults at once.  It used to be `55%` of the button, and that is wrong for both
   kinds of item for different reasons:

     - THE CLOCK was asked to be wider: at 55% its mark is 62.7px under a 114px
       button, which reads as a mark that does not belong to the thing above it.

     - THE ICON ITEMS CAME OUT AS AN ARC.  This is the real bug, and the reported
       theory -- 'as if the circle has affected it' -- is exactly right.  The base
       `button' rule gives every button `border-radius: var(--radius)' (12px), and
       an icon button is 24x24, so its radius is half BOTH sides: it is a CIRCLE.
       A 2px line at the very bottom of a circle is not a line at all -- only
       ~13.3px of the circle's width exists down there, and it curves away -- so
       the mark was clipped into an arc and looked truncated.  MEASURED: at the
       bottom 2px of a 24px circle the available width is 13.3px at the top of the
       band and 9.6px at the bottom.

   Two things hold it now, and both are needed:

     1. `border-radius: 0` on the button while its panel is open, so the bottom
        edge is straight and nothing can clip the mark.  The button paints no
        background of its own in this state (`background-color: transparent`), so
        the square corners are invisible -- the only thing on the button IS the
        mark.

     2. `background-size: 100% 2px`, so the mark spans the button exactly. */
window#bar button.panel-button.active {
  background-image: linear-gradient(var(--primary-bg), var(--primary-bg));
  background-size: 100% 2px;
  background-position: bottom center;
  background-repeat: no-repeat;
  background-color: transparent;
  border-radius: 0;
  box-shadow: none;
  color: var(--primary-bg);
}

/* THE ICON ITEMS GET THE SAME MARK AT THE WIDTH OF THEIR CIRCLE, which is NOT the
   width of the button.  The AUDIO icon button measures 29px against a 24px glyph
   box, because that glyph box carries a right padding of `0.4em` correcting a Nerd
   Font's off-centre ink (see the note at `.audio-icon`).  A mark across the whole
   29px would overhang the circle it belongs to by 5px.

   THE CIRCLE IS THE GLYPH BOX and it is a known size -- `--icon-button-size` -- so
   the mark is centred at that width.  `background-size` cannot express 'a fixed
   pixel width centred', so this is a gradient of the circle's width with `calc`.
   (The wide items above use `100%`, which IS expressible.) */
window#bar button.panel-button.icon-only.active {
  background-size: var(--icon-button-size) 2px;
}

/* A bar on the bottom edge.  Not an ags2-shell rule: theirs switches on the
   anchor in TypeScript, and this shell does it with a class from
   widgets/bar.scm. */
window#bar.bar-bottom .panel {
  border-top: var(--border-width) solid var(--border-color);
}

/* The mark goes on the inner edge whichever edge the bar is on: under a top bar,
   over a bottom one. */
window#bar.bar-bottom button.panel-button.active {
  background-position: top center;
}

window#bar .bar-start,
window#bar .bar-center,
window#bar .bar-end {
  margin: 0 calc(var(--spacing) / 2);
}

/* The clock is the bar's most-read text, so it keeps the emphasis ags2-shell
   gives its date menu button. */
window#bar .clock {
  font-weight: bold;
  color: var(--fg);
  padding: 0 calc(var(--spacing) / 2);
}

/* ---- the workspace numbers -------------------------------------------- */

/* The module says which workspace is in which STATE; every shape is here.

   A BUTTON, but a bare one: the bar's button rule gives it a background, a
   shadow and padding, all of which have to go before a number can look like a
   number. The three states are then the three things the user asked for --
   plain, a pill, a circle -- and the fourth class, `occupied', only changes the
   colour, because a workspace can be occupied without being focused. */
window#bar button.workspace {
  background-color: transparent;
  box-shadow: none;
  padding: 0;
  margin: 0 calc(var(--spacing) * 0.15);
  min-width: 1.6em;
  min-height: 1.6em;
  color: color-mix(in srgb, var(--fg) 40%, transparent);
  font-weight: normal;
}

/* Has windows on it. A modifier, not a shape: occupied and unfocused is the
   ordinary case, and it should read as: something is there. */
window#bar button.workspace.occupied {
  color: color-mix(in srgb, var(--fg) 80%, transparent);
  font-weight: bold;
}

/* THE CIRCLE: the workspace this bar's monitor is on. Equal sides with
   `border-radius: 50%', the same shape as the other monitor's -- the two differ
   by FILL, not by outline, which is what makes them read as the same kind of
   thing: one is here, one is elsewhere.

   IN THE FOREGROUND COLOUR, NOT THE ACCENT.  The accent is a palette colour that
   changes with the wallpaper, so the circle drifted away from the numbers beside
   it; the foreground is what the workspace numbers themselves are drawn in, so
   the circle is now the same ink as the thing it is marking.  The NUMBER inside
   it is the bar's own background, which is what contrast means here. */
window#bar button.workspace.active {
  /* `background-image: none' IS THE LINE THAT MAKES THIS WORK.  The base
     stylesheet's `button.active' rule paints `var(--active-gradient)' -- a
     gradient built from the ACCENT -- and an image is drawn OVER a background
     colour, so setting the colour alone left the circle accent-coloured however
     the colour was declared.  Declared by us, at a weight that beats it. */
  background-image: none;
  background-color: var(--fg);
  color: var(--bg);
  border-radius: 50%;
  padding: 0;
  min-width: 1.7em;
  min-height: 1.7em;
}

/* THE CIRCLE: focused on ANOTHER monitor. Equal sides with `border-radius:
   50%', and an outline rather than a fill so it reads as related to the pill
   without competing with it -- you are not here, you are somewhere else. */
window#bar button.workspace.active-other {
  background-color: transparent;
  color: var(--fg);
  border-radius: 50%;
  box-shadow: inset 0 0 0 var(--border-width) var(--fg);
  min-width: 1.7em;
  min-height: 1.7em;
}

window#bar button.workspace:hover:not(.active) {
  color: var(--fg);
  background-color: var(--hover-bg);
  border-radius: var(--radius);
}

/* Present but dimmed, rather than removed: a widget that disappears makes the
   bar reflow every time a device comes and goes. */
window#bar .unavailable {
  color: color-mix(in srgb, var(--fg) 40%, transparent);
}

window#bar .battery.low .battery-label {
  color: var(--error-bg);
}

/* ---- the tray --------------------------------------------------------- */

/* The tray's buttons need NO declarations of their own.  They are bar buttons,
   so %flat-button already made them transparent with no shadow, and the base
   button rule already gave them --radius and `all: unset'.  Anything added here
   is a difference from ags2-shell; an earlier attempt added a fixed
   border-radius and a box-shadow and produced exactly the rounded box that
   prompted this port. */
window#bar .tray {
  margin: 0 calc(var(--spacing) / 2);
}

/* A DELIBERATE DIFFERENCE FROM ags2-shell, and the only one in this file.
 *
 * Everything else here is copied so the bar looks the same; this makes it look
 * different on purpose, because the copy produces a rounded SQUARE and the
 * wanted shape is a circle.
 *
 * `50%' IS HALF THE SIDE, SO THE BOX HAS TO *HAVE* A SIDE.  This rule was
 * written believing a tray button was square -- an icon plus equal padding --
 * and it is not: it is content-sized SIDEWAYS and fills the bar's height
 * VERTICALLY, measured here at 31 wide by 42 tall.  `50%' of that is a VERTICAL
 * OVAL, which is what it drew.
 *
 * So the circle is drawn on the ICON'S OWN BOX instead, which is given equal
 * sides, and the button paints nothing itself.  The shape is then a circle
 * whatever the icon is and whatever the bar's height happens to be.
 *
 * The alternative -- squaring the BUTTON -- would make the item as wide as the
 * bar is tall, which is what made the network item look gappy. */
/* `button.tray-item' AND NOT `.tray-item', which is a SPECIFICITY MATTER rather
   than a style one.  The bar's own hover rule is `window#bar button:hover:not(
   .active)' -- an id, two classes and TWO ELEMENTS -- and `.tray-item' alone is
   an id, one class and one element, so the bar's rule WON and painted the button
   with its hover colour and its shadow.  With the radius taken off the button
   (the circle is on the icon now) that shadow is a RECTANGLE.  Naming `button'
   raises this rule to the same weight, and being later in the file it wins. */
window#bar button.tray-item {
  padding: 0;
  background-color: transparent;
  box-shadow: none;
  border-radius: 0;
}

window#bar button.tray-item > image {
  min-width: var(--icon-button-size);
  min-height: var(--icon-button-size);
}

/* The hover is the icon's box, the same way the wifi item's is. */
window#bar button.tray-item:hover,
window#bar button.tray-item:active,
window#bar button.tray-item:checked {
  background-color: transparent;
  box-shadow: none;
}

window#bar button.tray-item:hover > image,
window#bar button.tray-item:active > image,
window#bar button.tray-item:checked > image {
  background-color: var(--hover-bg);
  border-radius: 50%;
}
")

;;; ---------------------------------------------------------------------------
;;; The date menu -- ags2-shell widget/Bar/components/DateMenu/style.scss
;;; ---------------------------------------------------------------------------
;;
;; The selector names are theirs: `window#datemenu' is the popup window's own
;; name, and box.datemenu / box.notifications / box.date-column / box.calendar
;; are the classes their JSX puts on the same elements here.  %floating, %widget
;; and %flat-button are INLINED, because this stylesheet is plain CSS text and
;; not SCSS -- their bodies are copied verbatim from style/base/.
;;
;; ONE SELECTOR CHANGED, and only because the element changed: ags2-shell lays
;; the three columns out in a custom Gtk.Widget subclass, so its rules target
;; `box.datemenu > *' implicitly.  Here the columns sit in a Gtk.CenterBox
;; inside box.datemenu, which measures start and end to the same width -- the
;; same geometry (see widgets/date-menu.scm).  The declarations are untouched.

(define %datemenu-css
  "
/* ---- the date menu ---------------------------------------------------- */

/* %floating */
window#datemenu box.datemenu {
  box-shadow:
    0 0 5px 0 var(--shadow-color),
    var(--neu-widget-highlight),
    var(--neu-widget-shadow);
  margin: max(var(--spacing), 8px);
  border: var(--border-width) solid var(--popover-border-color);
  background-color: var(--bg);
  color: var(--fg);
  border-radius: var(--popover-radius);
  padding: var(--popover-padding);
}

window#datemenu box.datemenu box.notifications box.notifications-header {
  margin-bottom: calc(var(--padding) * 1.5);
  margin-right: calc(var(--padding) * 1.5);
}

window#datemenu box.datemenu box.notifications box.notifications-header button {
  padding: calc(var(--padding) * 0.7) var(--padding);
}

/* @include spacing(0.5) on the header button's box */
window#datemenu box.datemenu box.notifications box.notifications-header button box.horizontal > * {
  margin: 0 calc(var(--spacing) * 0.25);
}

window#datemenu box.datemenu box.notifications box.notifications-header button box.horizontal > *:first-child {
  margin-left: 0;
}

window#datemenu box.datemenu box.notifications box.notifications-header button box.horizontal > *:last-child {
  margin-right: 0;
}

window#datemenu box.datemenu box.notifications scrolledwindow.notification-scrollable {
  margin-right: calc(var(--padding) * 1.5);
}

/* %widget */
window#datemenu box.datemenu box.notification {
  transition: var(--transition);
  border-radius: var(--radius);
  color: var(--fg);
  background-color: var(--widget-bg);
  border: none;
  box-shadow:
    inset 0 0 0 var(--border-width) var(--border-color),
    var(--neu-widget-highlight),
    var(--neu-widget-shadow);
  padding: var(--padding);
  margin-left: 1px;
  margin-right: 1px;
  margin-bottom: var(--spacing);
}

window#datemenu box.datemenu separator {
  background-color: var(--popover-border-color);
  border-radius: var(--radius);
  margin-right: calc(var(--padding) * 1.5);
}

window#datemenu box.datemenu box.clock-box label.clock {
  font-size: 5em;
}

window#datemenu box.datemenu box.clock-box label.uptime {
  color: color-mix(in srgb, var(--fg) 80%, transparent);
  margin-bottom: calc(var(--padding) * 2);
}

/* %widget again, on the calendar's own box */
window#datemenu box.datemenu box.calendar {
  transition: var(--transition);
  border-radius: var(--radius);
  color: var(--fg);
  background-color: var(--widget-bg);
  border: none;
  box-shadow:
    inset 0 0 0 var(--border-width) var(--border-color),
    var(--neu-widget-highlight),
    var(--neu-widget-shadow);
  padding: var(--padding) var(--padding) 0;
}

window#datemenu box.datemenu box.calendar calendar {
  all: unset;
  font-size: 1.1em;
  padding: 0.3em;
}

window#datemenu box.datemenu box.calendar calendar:focus {
  outline: none;
}

/* %flat-button on the calendar's day cells */
window#datemenu box.datemenu box.calendar calendar button {
  all: unset;
  transition: var(--transition);
  border-radius: var(--radius);
  color: var(--fg);
  background-color: transparent;
  box-shadow: none;
  padding: calc(var(--padding) / 2);
}

window#datemenu box.datemenu box.calendar calendar label:focus {
  outline: calc(var(--border-width) / 2) solid var(--primary-bg);
  outline-offset: -1px;
  border-radius: calc(var(--radius) * 0.6);
}

window#datemenu box.datemenu box.calendar calendar label:selected {
  background-color: var(--primary-bg);
  border-radius: calc(var(--radius) * 0.6);
}

window#datemenu box.datemenu box.calendar calendar label:selected:focus {
  outline: calc(var(--border-width) / 2) solid var(--primary-fg);
  outline-offset: -1px;
}

window#datemenu box.datemenu box.calendar calendar header {
  background-color: transparent;
  border: none;
  color: color-mix(in srgb, var(--fg) 50%, transparent);
}

window#datemenu box.datemenu box.calendar calendar label.day-name {
  background-color: transparent;
  color: color-mix(in srgb, var(--primary-bg) 50%, transparent);
}

window#datemenu box.datemenu box.calendar calendar label.other-month {
  color: color-mix(in srgb, var(--fg) 10%, transparent);
}

/* ---- the empty-notifications placeholder ------------------------------ */

/* ags2-shell widget/shared/Placeholder.scss.  Nothing here is in the widget:
 * the icon name and the label are content and live in
 * widgets/date-menu/notifications.scm, and everything that makes them read as
 * a placeholder rather than as stray text is here -- the padding that gives the
 * column a body, the 70% colour that makes it recede, and the 1.25em label
 * that makes it legible at that colour.  Without this the column showed a bare
 * grey sentence in the corner. */
window#datemenu box.datemenu box.placeholder {
  padding: calc(var(--padding) * 2);
}

window#datemenu box.datemenu box.placeholder image {
  color: color-mix(in srgb, var(--fg) 70%, transparent);
  margin-bottom: 0.1em;
}

window#datemenu box.datemenu box.placeholder label {
  color: color-mix(in srgb, var(--fg) 70%, transparent);
  font-size: 1.25em;
}

/* @include spacing(0.5) -- the gap between the icon and the label. */
window#datemenu box.datemenu box.placeholder.vertical > * {
  margin: calc(var(--spacing) * 0.25) 0;
}

window#datemenu box.datemenu box.placeholder.vertical > *:first-child {
  margin-top: 0;
}

window#datemenu box.datemenu box.placeholder.vertical > *:last-child {
  margin-bottom: 0;
}
")

(define %menu-css
  "
/* ---- the menu --------------------------------------------------------- */

/* Proportions from Omarchy's Menu.qml: a 300-unit card, 50-unit rows, a
 * 34-unit header. Rendered as pixels because that is what CSS wants, and the
 * ratio is what matters -- a card a little wider than three rows is tall. */
window#menu .menu {
  background-color: var(--bg);
  border: var(--border-width) solid var(--popover-border-color);
  border-radius: var(--popover-radius);
  padding: calc(var(--padding) * 1.5);
  min-width: 380px;
}

window#menu .menu-title {
  font-size: 1.15em;
  font-weight: bold;
  color: color-mix(in srgb, var(--fg) 75%, transparent);
  margin-bottom: calc(var(--spacing) * 0.8);
  padding: 0 calc(var(--padding) * 0.6);
}

/* The list is capped rather than the window: a submenu with 96 rows in it --
 * `apps' -- has to scroll, and every other submenu has to be exactly as tall
 * as it needs. */
window#menu .menu-scroll {
  min-height: 0;
}

window#menu button.menu-item {
  all: unset;
  transition: var(--transition);
  border-radius: var(--radius);
  padding: calc(var(--padding) * 0.7) var(--padding);
  color: var(--fg);
  min-height: 0;
}

window#menu button.menu-item.selected,
window#menu button.menu-item:hover {
  background-color: var(--hover-bg);
  color: var(--hover-fg);
}

/* A row that is installed but not actionable -- Omarchy's `disabled'. It keeps
 * its place and its ✓ and goes dim, so the list stays a catalogue. */
window#menu button.menu-item.disabled {
  color: color-mix(in srgb, var(--fg) 35%, transparent);
}

window#menu .menu-item-icon {
  min-width: 1.6em;
  color: color-mix(in srgb, var(--fg) 80%, transparent);
}

window#menu .menu-item-label {
  margin-left: calc(var(--spacing) * 0.6);
}

window#menu .menu-item-arrow {
  color: color-mix(in srgb, var(--fg) 50%, transparent);
  margin-left: calc(var(--spacing) * 0.6);
}
")

(define %overview-css
  "
/* ---- the workspace switcher ------------------------------------------- */
/* Ported from ags2-shell widget/Bar/components/Overview/style.scss: the card
 * floats, a tile is a picture of a monitor so it keeps a border to read as one,
 * and the focused window inside it gets an outline. */

/* %floating */
window#overview .overview {
  box-shadow:
    0 0 5px 0 var(--shadow-color),
    var(--neu-widget-highlight),
    var(--neu-widget-shadow);
  margin: max(var(--spacing), 8px);
  border: var(--border-width) solid var(--popover-border-color);
  background-color: var(--bg);
  color: var(--fg);
  border-radius: var(--popover-radius);
  padding: var(--popover-padding);
}

/* A monitor, shrunk. It has to read as a bounded area -- the window rectangles
 * inside are positioned against it -- so it keeps a background and a border of
 * its own rather than floating like the bar's buttons. */
window#overview button.workspace {
  background-color: color-mix(in srgb, var(--fg) 6%, transparent);
  box-shadow: inset 0 0 0 var(--border-width) var(--border-color);
  border-radius: calc(var(--radius) * 0.6);
  padding: 0;
  margin: calc(var(--spacing) * 0.4);
}

/* THE CURRENT WORKSPACE, OUTLINED IN THE FOREGROUND COLOUR rather than the
   accent -- the same change as the bar's workspace circles, and for the same
   reason: the accent is a palette colour that moves with the wallpaper, and this
   outline marks the workspace the user is ON.  In the foreground it matches the
   captions and the window rectangles it sits among. */
window#overview button.workspace.active {
  /* The same leak as the bar's: the base `button.active' gradient would fill the
     tile under this outline. */
  background-image: none;
  box-shadow: inset 0 0 0 calc(var(--border-width) * 2) var(--fg);
}

/* The column: the picture, then the monitor's name under it. */
window#overview .workspace-cell {
  margin: calc(var(--spacing) * 0.4);
}

window#overview label.workspace-caption {
  font-size: 0.85em;
  color: color-mix(in srgb, var(--fg) 55%, transparent);
  margin-top: calc(var(--spacing) * 0.25);
}

/* A window, where it is and the shape it is. */
window#overview button.client {
  background-color: var(--widget-bg);
  box-shadow:
    inset 0 0 0 var(--border-width) var(--border-color),
    var(--neu-widget-shadow);
  border-radius: var(--radius);
  padding: 0;
}

window#overview button.client:hover {
  background-color: var(--hover-bg);
}

/* The selected window. `box-shadow' rather than `border' so the rectangle does
 * not change size when it is selected -- the whole point of the tile is that
 * the rectangles are the windows' true shapes, and a border would make the
 * selected one a lie. */
window#overview button.client.selected {
  box-shadow:
    inset 0 0 0 calc(var(--border-width) * 2) var(--primary-bg),
    var(--neu-widget-shadow);
  background-color: var(--hover-bg);
}
")

(define %network-css
  "
/* ---- the wifi panel --------------------------------------------------- */
/*
 * Proportions from Omarchy's Ui/PanelSectionHeader.qml and Commons/Style.qml:
 * its font tokens are multiples of a 12px base (caption 0.833, body 1.0,
 * title 1.167, display 2.0) and its spacing tokens are multiples of the same
 * base (row-padding-x 12, panel-gap 14, panel-padding 18). Written here as em
 * multiples of --font-size, which is this shell's equivalent of that base.
 */

window#network .network-panel {
  background-color: var(--bg);
  border: var(--border-width) solid var(--popover-border-color);
  border-radius: var(--popover-radius);
  padding: var(--popover-padding);
  min-width: 400px;
}

/* ---- the bar's network item -------------------------------------------- */

/* A CIRCLE WHEN IT IS JUST A GLYPH, which is the shape the workspace buttons
   already have and the one a single icon wants: the bar's buttons are square
   enough for `50%' to BE a circle.  With a network name beside the glyph the
   item is wide, and `50%' of a wide box is an ELLIPSE -- the `weird oval' the
   hover used to draw -- so that case keeps the ordinary rounded rectangle. */
/* EQUAL SIDES, WHICH IS THE WHOLE OF IT: `50%' of a box that is taller than it
   is wide is a VERTICAL OVAL, and that is what a glyph alone in a padded button
   gives -- the icon is one character wide and the button is not.  `50%' of a
   square is a circle, so the square has to be said out loud, exactly as the
   workspace buttons say it. */
/* THE ITEM IS THE SIZE OF ITS NEIGHBOURS AND THE CIRCLE IS DRAWN INSIDE IT.
   Sizing the BUTTON to a square is what made the bar look gappy: a 12px glyph in
   a 35px box has 11px of nothing either side, where the bluetooth item next to it
   is 22px wide.  So the button stays as small as the others -- glyph plus the
   bar's padding -- and the round highlight goes on the GLYPH'S OWN BOX, driven by
   the button's hover.

   THE CIRCLE IS 1.2em, which is about the width of the items beside it, and that
   is as small as it can be: see the note on the ink below. */
window#bar button.panel-button.icon-only {
  min-width: 0;
  min-height: 0;
  /* the bar's own vertical padding and none sideways, so the item is exactly as
     tall as its neighbours and only as wide as its circle */
  padding: calc(var(--padding) / 2) 0;
}

window#bar button.panel-button.icon-only .network-icon {
  /* MINUS THE PADDING, because the box is a CONTENT box: `min-width' does not
     include padding, so a slot plus a right padding is a box WIDER than it is
     tall -- a horizontal oval, which is the vertical oval's twin.  The two
     together are the slot. */
  min-width: calc(var(--icon-button-size) - 0.4em);
  min-height: var(--icon-button-size);
  /* A NERD FONT'S PATCHED GLYPH IS WIDER THAN ITS MONO CELL, and Pango centres
     by the CELL: measured on this machine, the wifi glyph's ink is 20px wide
     while its advance is 12px, so its centre falls 4px to the RIGHT of every box
     it is centred in -- which is the off-centre icon, and no amount of resizing
     moves it, because the offset is a property of the font.  A right padding of
     twice the error moves the centred text half of it back to the left.
     Measured with pango-layout-get-pixel-extents, not by eye. */
  padding: 0 0.4em 0 0;
}

/* The button paints nothing itself in this state: the shape is the glyph's box. */
window#bar button.panel-button.icon-only:hover:not(.active),
window#bar button.panel-button.icon-only:active {
  background-color: transparent;
  box-shadow: none;
  border-radius: 0;
}

window#bar button.panel-button.icon-only:hover:not(.active) .network-icon,
window#bar button.panel-button.icon-only:active .network-icon {
  background-color: var(--hover-bg);
  border-radius: 50%;
}

/* AND A PILL WHEN THERE IS A NAME BESIDE THE GLYPH: a radius past half the
   height is clamped to it by the CSS spec, so this is a pill at any width --
   which is the shape a wide item wants, and never the oval. */
window#bar button.panel-button:not(.icon-only):hover:not(.active),
window#bar button.panel-button:not(.icon-only):active {
  border-radius: 999px;
}

window#bar button.panel-button .network-item {
  margin: 0;
}

/* THE BATTERY GLYPH NEEDS NO COMPENSATION, and asking for it is what pushed this
   icon to the left of its own circle.  The wifi glyph's ink is 20px wide in a
   12px advance -- a Nerd Font patch wider than its cell -- so it needed a nudge;
   the battery glyph's ink is 29px in a 34px advance, centred to within half a
   pixel.  Both were written from `pango-layout-get-pixel-extents'. */
window#bar button.panel-button.icon-only .battery-icon {
  min-width: var(--icon-button-size);
  min-height: var(--icon-button-size);
  padding: 0;
}

window#bar button.panel-button.icon-only:hover:not(.active) .battery-icon,
window#bar button.panel-button.icon-only:active .battery-icon {
  background-color: var(--hover-bg);
  border-radius: 50%;
}

/* ---- the battery panel ------------------------------------------------- */

/* THE CARD.  A popup window is transparent on purpose (it is the size of the
   screen), so a panel that does not paint its own background is a panel you can
   read the desktop through -- which is what this one was. */
window#battery-panel .battery-panel {
  background-color: var(--panel-bg);
  border: var(--border-width) solid var(--popover-border-color);
  border-radius: var(--popover-radius);
  padding: var(--popover-padding);
  min-width: 340px;
}

window#battery-panel .battery-head {
  margin-bottom: calc(var(--spacing) * 1.4);
}

/* The big glyph, the title and its state, and the percentage at the far right:
   the layout of Omarchy's power panel, where the eye lands on the icon and the
   number and reads the words in between if it wants to. */
window#battery-panel .battery-big-icon {
  font-size: 2.8em;
  color: var(--fg);
  margin-right: calc(var(--spacing) * 1.4);
}

window#battery-panel .battery-title {
  font-size: 1.3em;
  font-weight: bold;
  color: var(--fg);
}

window#battery-panel .battery-state {
  font-size: 0.95em;
  color: color-mix(in srgb, var(--fg) 65%, transparent);
}

window#battery-panel .battery-big-pct {
  font-size: 2.4em;
  font-weight: bold;
  color: var(--fg);
}

/* The graph: the charge, across the whole card. */
window#battery-panel progressbar.battery-bar {
  min-height: 6px;
  margin-bottom: calc(var(--spacing) * 1.6);
}

window#battery-panel progressbar.battery-bar trough {
  background-color: color-mix(in srgb, var(--fg) 12%, transparent);
  border-radius: 3px;
  min-height: 6px;
}

window#battery-panel progressbar.battery-bar progress {
  background-color: var(--fg);
  border-radius: 3px;
  min-height: 6px;
}

/* Two columns of name-and-number, which is what the stats are. */
window#battery-panel .battery-stats > box {
  margin-right: calc(var(--spacing) * 2);
}

window#battery-panel .battery-row {
  margin-bottom: calc(var(--spacing) * 0.4);
}

window#battery-panel .battery-row-label {
  color: color-mix(in srgb, var(--fg) 60%, transparent);
  margin-right: calc(var(--spacing) * 1.6);
}

window#battery-panel .battery-row-value {
  color: var(--fg);
  font-weight: bold;
}

/* The three profiles, held off from the stats above them. */
window#battery-panel .battery-profiles {
  margin-top: calc(var(--spacing) * 1.8);
}

window#battery-panel button.battery-profile {
  background-color: transparent;
  box-shadow: none;
  color: color-mix(in srgb, var(--fg) 55%, transparent);
  font-weight: normal;
  padding: calc(var(--spacing) * 0.8) var(--padding);
}

window#battery-panel button.battery-profile.active {
  background-color: color-mix(in srgb, var(--fg) 12%, transparent);
  color: var(--fg);
  font-weight: bold;
  border-radius: var(--radius);
}

/* ---- the bluetooth radio in the bar ------------------------------------ */

/* THE GLYPH IN THE CIRCLE, with the min-width/min-height pair that makes the
   hover a circle rather than a box drawn round the ink -- the same pair the
   battery icon has, and for the same reason (`.icon-only' is what the toolkit's
   rule keys on, and this item is always icon-only because it has no name to
   show). */
window#bar button.panel-button.icon-only .bluetooth-icon {
  min-width: var(--icon-button-size);
  min-height: var(--icon-button-size);
  padding: 0;
}

window#bar button.panel-button.icon-only:hover:not(.active) .bluetooth-icon,
window#bar button.panel-button.icon-only:active .bluetooth-icon {
  background-color: var(--hover-bg);
  border-radius: 50%;
}

/* WHEN THE RADIO IS OFF the item takes the toolkit's own `unavailable' class,
   which `window#bar .unavailable' above already dims -- and the class is added
   by an effect in the widget, so OFF IS DIMMED WITHOUT A RULE OF ITS OWN HERE.
   An item that disappears instead would make the bar reflow every time the radio
   was switched; the glyph already says which of the three states it is in.
   There is deliberately no rule naming this item's class: `panel-button' names
   the button after the PANEL it opens (`bluetooth-panel'), not after the item,
   so a selector built from the feature's name would silently match nothing. */

/* ---- the bluetooth panel ----------------------------------------------- */

window#bluetooth .bluetooth-panel {
  background-color: var(--panel-bg);
  border: var(--border-width) solid var(--popover-border-color);
  border-radius: var(--popover-radius);
  padding: var(--popover-padding);
  min-width: 340px;
}

/* The hero: glyph, name and state, and the radio switch -- the same shape as the
   network panel's, so the two panels for the two radios read as one kind of
   thing. */
window#bluetooth .bluetooth-hero {
  margin-bottom: calc(var(--spacing) * 1.6);
}

window#bluetooth .bluetooth-hero-icon {
  font-size: 2em;
  min-width: 1.6em;
  color: var(--fg);
  margin-right: 0.5em;
}

window#bluetooth .bluetooth-hero-title {
  font-size: 1.167em;
  font-weight: bold;
  color: var(--fg);
}

window#bluetooth .bluetooth-hero-meta {
  font-size: 0.833em;
  font-weight: bold;
  letter-spacing: 1.2px;
  color: color-mix(in srgb, var(--fg) 65%, transparent);
}

/* THE SWITCH, in this shell's palette and not the theme's: GTK would paint the
   knob white and the trough blue whatever the wallpaper is doing.  The same
   rules the network panel's radio switch has, repeated rather than shared --
   a GTK stylesheet has no way to share a rule between two windows, because the
   window's name IS the scope. */
window#bluetooth switch {
  background-color: color-mix(in srgb, var(--fg) 15%, transparent);
  border: none;
  box-shadow: none;
  min-width: 44px;
  min-height: 24px;
}

window#bluetooth switch > slider {
  background-color: var(--fg);
  border: none;
  box-shadow: none;
  min-width: 18px;
  min-height: 18px;
}

window#bluetooth switch:checked {
  background-color: var(--primary-bg);
}

window#bluetooth switch:checked > slider {
  background-color: var(--fg);
}

/* The scan line: what is happening on the left, the one button that starts and
   stops a scan on the right. */
window#bluetooth .bluetooth-scan {
  margin-bottom: calc(var(--spacing) * 0.8);
}

window#bluetooth .bluetooth-scan-state {
  font-size: 0.833em;
  font-weight: bold;
  letter-spacing: 1.2px;
  color: color-mix(in srgb, var(--fg) 65%, transparent);
}

window#bluetooth button.bluetooth-scan-button {
  background-color: transparent;
  box-shadow: none;
  color: var(--fg);
  font-size: 0.833em;
  font-weight: bold;
  padding: calc(var(--spacing) * 0.4) var(--padding);
  min-height: 0;
}

window#bluetooth button.bluetooth-scan-button:hover {
  background-color: var(--hover-bg);
  border-radius: var(--radius);
}

/* NO SECTION HEADINGS, so no rule for them.  The list is one flat, sorted list
   rather than Omarchy's PAIRED / AVAILABLE groups: a device MOVES between groups
   when it connects, moving it needs the list rebuilt, and rebuilding the list is
   what made the panel flicker and what stopped a row from updating in place.
   ags2-shell -- the parity target -- has one list too.  `style-classes.scm`
   caught the leftover rule when the groups went. */

/* A DEVICE ROW: transparent until you touch it, because a list of pill buttons
   is a list of things that all look pressed at once. */
window#bluetooth button.bluetooth-row {
  background-color: transparent;
  box-shadow: none;
  border-radius: var(--radius);
  padding: calc(var(--spacing) * 0.5) calc(var(--spacing) * 0.8);
  min-height: 0;
}

window#bluetooth button.bluetooth-row:hover {
  background-color: var(--hover-bg);
}

window#bluetooth button.bluetooth-row.connected {
  background-color: color-mix(in srgb, var(--fg) 8%, transparent);
}

window#bluetooth .bluetooth-row-icon {
  font-size: 1.4em;
  color: var(--fg);
  margin-right: 0.6em;
}

window#bluetooth .bluetooth-row-name {
  color: var(--fg);
}

window#bluetooth .bluetooth-row-status {
  font-size: 0.833em;
  color: color-mix(in srgb, var(--fg) 65%, transparent);
}

window#bluetooth .bluetooth-empty {
  font-size: 0.833em;
  color: color-mix(in srgb, var(--fg) 55%, transparent);
  margin: calc(var(--spacing) * 1.2) 0;
}

/* ---- the audio item in the bar ----------------------------------------- */

/* THE GLYPH IN THE CIRCLE, with the min-width/min-height pair that makes the
   hover a circle rather than a box drawn round the ink -- the same pair the
   bluetooth and battery icons have.  Without it the item is as wide as the
   glyph's ADVANCE, which for a Nerd Font glyph is not its ink, so the circle
   comes out an ellipse or is not drawn at all. */
window#bar button.panel-button.icon-only .audio-icon {
  min-width: var(--icon-button-size);
  min-height: var(--icon-button-size);
  /* A NERD FONT GLYPH IS WIDER THAN ITS MONO CELL, so Pango centres it by the
     CELL and the ink sits to one side -- reported as the icon sitting too far
     right within the hover circle, which is the same complaint the wifi glyph
     drew.  COPIED FROM THE NETWORK ICON RATHER THAN MEASURED for this glyph
     (the pango-layout-get-pixel-extents probe did not run), so if this one is
     off it wants the same measurement the wifi icon got -- see the note there. */
  padding: 0 0.4em 0 0;
}

window#bar button.panel-button.icon-only:hover:not(.active) .audio-icon,
window#bar button.panel-button.icon-only:active .audio-icon {
  background-color: var(--hover-bg);
  border-radius: 50%;
}

/* ---- the audio panel -------------------------------------------------- */

window#audio .audio-panel {
  background-color: var(--panel-bg);
  border: var(--border-width) solid var(--popover-border-color);
  border-radius: var(--popover-radius);
  padding: var(--popover-padding);
  min-width: 340px;
}

/* The hero: the glyph, the title, the state under it, and the mute switch -- the same
   shape as the bluetooth panel's, so the two panels read as one kind of thing. */
window#audio .audio-hero {
  margin-bottom: calc(var(--spacing) * 1.4);
}

window#audio .audio-hero-icon {
  font-size: 2em;
  min-width: 1.6em;
  color: var(--fg);
  margin-right: 0.5em;
}

window#audio .audio-hero-title {
  font-size: 1.167em;
  font-weight: bold;
  color: var(--fg);
}

window#audio .audio-hero-meta {
  font-size: 0.833em;
  font-weight: bold;
  letter-spacing: 1.2px;
  color: color-mix(in srgb, var(--fg) 65%, transparent);
}

/* The switch, in this shell's palette rather than the theme's (GTK would paint
   the knob white and the trough blue).  Repeated rather than shared: a GTK
   stylesheet has no way to share a rule between windows, because the window's
   name IS the scope. */
window#audio switch {
  background-color: color-mix(in srgb, var(--fg) 15%, transparent);
  border: none;
  box-shadow: none;
  min-width: 44px;
  min-height: 24px;
}

window#audio switch > slider {
  background-color: var(--fg);
  border: none;
  box-shadow: none;
  min-width: 18px;
  min-height: 18px;
}

window#audio switch:checked { background-color: var(--primary-bg); }
window#audio switch:checked > slider { background-color: var(--fg); }

/* the section head: the name on the left, the percentage on the right */
window#audio .audio-head {
  margin-top: calc(var(--spacing) * 0.8);
}

window#audio .audio-head-name {
  font-size: 0.833em;
  font-weight: bold;
  letter-spacing: 1.2px;
  color: color-mix(in srgb, var(--fg) 65%, transparent);
}

window#audio .audio-head-value {
  font-weight: bold;
  color: var(--fg);
}

/* THE VOLUME BAR IS A GtkScale, not a progress bar -- so these rules are for
   `scale', and the old `progressbar' ones never matched anything, which is why
   the bars came out in GTK's own blue rather than this shell's palette.  A
   scale has three parts: `trough' (the empty track), `highlight' (the filled
   part) and `slider' (the handle). */
window#audio scale.audio-bar {
  min-height: 6px;
  padding: 0;
  margin: calc(var(--spacing) * 0.5) 0 calc(var(--spacing) * 0.8);
}

window#audio scale.audio-bar trough {
  background-color: color-mix(in srgb, var(--fg) 12%, transparent);
  border: none;
  border-radius: 3px;
  min-height: 6px;
}

window#audio scale.audio-bar highlight {
  /* THE THEME'S HIGHLIGHT, not the font colour: `--primary-bg' is the palette's
     accent, the same variable the switch's checked state uses. */
  background-color: var(--primary-bg);
  border-radius: 3px;
}

/* A FLAT HANDLE, because this bar is a level as much as a control: a big round
   knob in the middle of a thin track is a slider, and a thin bar is a level you
   can drag. */
window#audio scale.audio-bar slider {
  background-color: var(--primary-bg);
  border: none;
  box-shadow: none;
  min-width: 4px;
  min-height: 12px;
  margin: -3px 0;
  border-radius: 2px;
}

/* GTK paints a scale's fill BLUE through `:focus`/`:hover` as well, so the
   plain state is not enough. */
window#audio scale.audio-bar:hover highlight,
window#audio scale.audio-bar:focus highlight { background-color: var(--primary-bg); }

/* A device row: transparent until touched, because a column of pill buttons is
   a column of things that all look pressed at once. */
window#audio button.audio-device {
  background-color: transparent;
  box-shadow: none;
  border-radius: var(--radius);
  padding: calc(var(--spacing) * 0.4) calc(var(--spacing) * 0.6);
  min-height: 0;
}

window#audio button.audio-device:hover { background-color: var(--hover-bg); }

/* THE ONE IN USE IS MARKED, not left to be worked out by elimination -- the same
   lesson the battery panel's profile buttons taught. */
window#audio button.audio-device.current {
  background-color: color-mix(in srgb, var(--fg) 8%, transparent);
}

window#audio .audio-device-name { color: var(--fg); }

/* NO `.audio-device-card' RULE: the second line moved to the row's tooltip. */

/* ---- now playing, from ags2-shell -------------------------------------- */

window#audio .audio-media {
  margin-top: calc(var(--spacing) * 1.2);
  padding-top: calc(var(--spacing) * 1.2);
  border-top: var(--border-width) solid color-mix(in srgb, var(--fg) 15%, transparent);
}

window#audio .audio-art {
  border-radius: var(--radius);
  margin-right: 0.9em;
  background-color: color-mix(in srgb, var(--fg) 8%, transparent);
  /* MATCHING THE PIXEL SIZE the widget asks for, or the box is smaller than the
     picture and the picture is scaled down inside it. */
  min-width: 104px;
  min-height: 104px;
}

window#audio .audio-media-title {
  font-weight: bold;
  color: var(--fg);
}

window#audio .audio-media-artist {
  font-size: 0.833em;
  color: color-mix(in srgb, var(--fg) 65%, transparent);
}

/* THE PROGRESS LINE SPANS THE PANEL, under the title AND the artist, from the
   edge of the artwork to the right-hand edge -- ags2-shell's shape.  The bar
   expands and the numbers and the button take what they need. */
window#audio .audio-media-line {
  margin-top: calc(var(--spacing) * 0.5);
}

window#audio .audio-media-head {
  margin-bottom: calc(var(--spacing) * 0.3);
}

/* SPACE BETWEEN THE TITLE AND THE APP GLYPH, so they do not read as one word. */
window#audio .audio-media-app {
  margin-left: 0.6em;
}

window#audio .audio-media-elapsed,
window#audio .audio-media-total {
  font-size: 0.75em;
  color: color-mix(in srgb, var(--fg) 60%, transparent);
}

window#audio progressbar.audio-media-bar {
  min-height: 4px;
  /* NO SIDE MARGINS: the bar runs from the artwork to the panel's own edge. */
  margin: 0 0 calc(var(--spacing) * 0.4) 0;
}

window#audio .audio-media-progress {
  margin-top: calc(var(--spacing) * 0.3);
}

window#audio progressbar.audio-media-bar trough {
  background-color: color-mix(in srgb, var(--fg) 15%, transparent);
  border-radius: 2px;
  min-height: 4px;
}

window#audio progressbar.audio-media-bar progress {
  background-color: var(--fg);
  border-radius: 2px;
  min-height: 4px;
}

window#audio button.audio-media-button {
  background-color: transparent;
  box-shadow: none;
  color: var(--fg);
  padding: 0;
  min-height: 0;
  min-width: 0;
}

/* A CIRCLE, NOT AN OVAL.  Without a fixed size the button takes its natural
   width from the glyph, and `border-radius: 50%' of a box wider than it is tall
   is an ellipse -- the absurdly wide oval shadow.  Equal sides make it a
   circle, which is the same rule the bar's icon buttons follow. */
window#audio button.audio-media-button:hover,
window#audio button.audio-media-button:active {
  background-color: var(--hover-bg);
  border-radius: 50%;
}

window#audio button.audio-media-button {
  min-width: 1.9em;
  min-height: 1.9em;
}

/* The app icon keeps its own colours: no `-symbolic', so no rules here to
   recolour it. */

/* ---- the radio switch -------------------------------------------------- */

/* GTK PAINTS ITS SWITCHES IN THE THEME'S COLOURS, which on this desktop are not
   this shell's palette: the knob came out white and the trough blue, whatever
   the wallpaper was doing.  Both are ours now.

   THE TROUGH IS THE PANEL'S OWN BACKGROUND when the radio is off and the ACCENT
   when it is on, and the KNOB is the foreground colour -- so the switch reads as
   part of the card rather than as a piece of Adwaita sitting on it.  Declared for
   `:checked' as well as the plain state, because GTK's own `switch:checked' rule
   would otherwise win on specificity and put the blue back. */
window#network switch {
  background-color: color-mix(in srgb, var(--fg) 15%, transparent);
  border: none;
  box-shadow: none;
  min-width: 44px;
  min-height: 24px;
}

window#network switch > slider {
  background-color: var(--fg);
  border: none;
  box-shadow: none;
  min-width: 18px;
  min-height: 18px;
}

window#network switch:checked {
  background-color: var(--primary-bg);
}

window#network switch:checked > slider {
  background-color: var(--fg);
}

/* The hero: glyph, name and state, and the radio switch.  The gap is the
 * reference's `anchors.leftMargin: Style.space(14)' between the glyph and the
 * text; the icon's own min-width is what keeps the two-line text block from
 * moving when the glyph is a narrow one. */
window#network .network-hero {
  margin-bottom: calc(var(--spacing) * 2);
}

window#network .network-hero-icon {
  font-size: 2em;                      /* Style.font.display */
  min-width: 1.6em;
  color: var(--fg);
  margin-right: 0.5em;
}

window#network .network-hero-title {
  font-size: 1.167em;                  /* Style.font.title */
  font-weight: bold;
  color: var(--fg);
}

window#network .network-hero-meta {
  font-size: 0.833em;                  /* Style.font.caption */
  font-weight: bold;
  letter-spacing: 1.2px;
  color: color-mix(in srgb, var(--fg) 65%, transparent);
}

window#network .network-scanning {
  font-size: 0.833em;
  font-weight: bold;
  color: color-mix(in srgb, var(--fg) 65%, transparent);
  margin-bottom: var(--spacing);
}

/* The list is capped rather than the window: a dense neighbourhood has to
 * scroll, and a sparse one has to be exactly as tall as it needs. */
window#network .network-scroll {
  min-height: 0;
}

window#network .network-list {
  min-height: 0;
}

/* A section heading sits above the run of rows it introduces and scrolls with
 * them. The top padding is the reference's, and it is not cosmetic: Nerd Font
 * outlines run about 10% of the em past their own ascent, and the top of a
 * clipping list eats that sliver -- the first heading renders beheaded. */
window#network .network-section {
  font-size: 0.833em;
  font-weight: bold;
  color: color-mix(in srgb, var(--fg) 65%, transparent);
  padding-top: 0.15em;
  margin-top: calc(var(--spacing) * 1.2);
  margin-bottom: calc(var(--spacing) * 0.6);
}

window#network button.network-row {
  all: unset;
  transition: var(--transition);
  border-radius: var(--radius);
  color: var(--fg);
  min-height: 0;
}

window#network button.network-row:hover {
  background-color: var(--hover-bg);
}

/* The network in use is marked with the accent, not with a fill: it is a
 * state, and the hover fill already means something else. */
window#network button.network-row.connected .network-row-icon {
  color: var(--primary-bg);
}

window#network .network-row-body {
  padding: calc(var(--spacing) * 1.2) var(--padding);
}

window#network .network-row-icon {
  font-size: 1.167em;                  /* Style.font.title */
  min-width: 1.6em;
  color: var(--fg);
}

window#network .network-row-ssid {
  font-size: 1em;                      /* Style.font.body */
  color: var(--fg);
}

window#network .network-row-status {
  font-size: 0.833em;                  /* Style.font.caption */
  color: color-mix(in srgb, var(--fg) 65%, transparent);
}

window#network button.network-row.failed .network-row-status {
  color: var(--error-bg);
}

window#network .network-row-lock {
  font-size: 1.083em;                  /* Style.font.subtitle */
  min-width: 1.5em;
  color: color-mix(in srgb, var(--fg) 70%, transparent);
}

window#network button.network-row-forget {
  all: unset;
  font-size: 1.083em;
  min-width: 1.5em;
  color: var(--error-bg);
}

/* The passphrase prompt, inline under its row. */
window#network .network-prompt {
  padding: 0 var(--padding) calc(var(--spacing) * 1.2) var(--padding);
}

window#network .network-prompt entry {
  min-height: 0;
  padding: calc(var(--spacing) * 0.6) var(--padding);
  border-radius: var(--radius);
  background-color: var(--widget-bg);
  color: var(--fg);
}

window#network .network-prompt button {
  all: unset;
  padding: calc(var(--spacing) * 0.6) var(--padding);
  border-radius: var(--radius);
  color: var(--fg);
}

window#network .network-prompt button:hover {
  background-color: var(--hover-bg);
}

window#network .network-password-submit {
  color: var(--primary-bg);
}
")

(define %powermenu-css
  "
/* ---- the power menu ---------------------------------------------------- */

/* The card, as the date menu's and the menu's are cards: a popup window is the
   size of the screen, so the CARD is what gets painted.  The class carries the
   layout (`powermenu horizontal line' or `... box'), which is ags2-shell's
   arrangement -- it styles the buttons by position and the class tells the two
   layouts apart. */
window#powermenu box.powermenu {
  box-shadow:
    0 0 5px 0 var(--shadow-color),
    var(--neu-widget-highlight),
    var(--neu-widget-shadow);
  margin: max(var(--spacing), 8px);
  border: var(--border-width) solid var(--popover-border-color);
  background-color: var(--bg);
  color: var(--fg);
  border-radius: var(--popover-radius);
  padding: var(--popover-padding);
}

window#powermenu box.powermenu button {
  padding: calc(var(--spacing) * 0.5);
  border-radius: var(--border-width);
}

window#powermenu box.powermenu button:hover {
  background-color: var(--hover-bg);
}

/* ---- the confirmation modal -------------------------------------------- */

/* Centred and its own card, because it is a modal rather than a panel: there is
   no bar button behind it for it to line up with. */
window#verification box.verification {
  box-shadow:
    0 0 5px 0 var(--shadow-color),
    var(--neu-widget-highlight),
    var(--neu-widget-shadow);
  margin: max(var(--spacing), 8px);
  border: var(--border-width) solid var(--popover-border-color);
  background-color: var(--bg);
  color: var(--fg);
  border-radius: var(--popover-radius);
  padding: var(--popover-padding);
  min-width: calc(var(--spacing) * 14);
}

window#verification box.verification box.text-box {
  border-spacing: calc(var(--spacing) * 0.5);
}

window#verification box.verification box.text-box label.title {
  font-size: calc(var(--font-size) * 1.2);
  font-weight: bold;
}

window#verification box.verification box.text-box label.desc {
  opacity: 0.8;
}

window#verification box.verification box.buttons {
  border-spacing: var(--spacing);
}
")

(define (shell-css)
  "The whole stylesheet: theme variables, ags2-shell's base, then the bar."
  (string-append (theme-css) %base-css %bar-css %datemenu-css %menu-css
                 %overview-css %network-css %powermenu-css))

;; One provider for the whole shell, parsed once and reused by every toplevel.
;; The toolkit holds it, so it cannot be collected out from under the windows.
(define %provider #f)

;; THE CSS THE CACHE WAS BUILT FROM, not just a boolean.
;;
;; The stylesheet is a function of the theme, and the theme now reads the scale
;; from config -- so "have I built a provider yet" is the wrong question. It was
;; built once, and a changed scale produced identical CSS afterwards because the
;; old provider was still handed back. Comparing the text costs a string
;; comparison per call and makes a scale change take effect on the next rebuild.
(define %provider-css #f)

(define (shell-provider)
  "The shell's CSS provider: built once, RELOADED when the stylesheet changes.

RELOADED AND NOT REPLACED.  This used to make a second provider whenever the CSS
text changed, and a provider for the display is ADDED and never removed -- so a
recolour left two of them attached at the same priority, and the old one went on
winning wherever it was consulted first.  The visible result: switching the
desktop theme recoloured some of the bar and not the rest, which reads as a
half-applied theme rather than as a provider that never went away."
  (let ((css (shell-css)))
    (cond ((not %provider)
           (let-values (((p errors) (css-provider-for css)))
             (for-each (lambda (e)
                         (format (current-error-port) "scheme-desktop: css: ~a\n" e))
                       errors)
             (set! %provider p)
             (set! %provider-css css)))
          ((not (equal? css %provider-css))
           (for-each (lambda (e)
                       (format (current-error-port) "scheme-desktop: css: ~a\n" e))
                     (provider-load! %provider css))
           (set! %provider-css css)))
    %provider))

(define (apply-shell-css!)
  "Apply the shell's stylesheet to the DISPLAY.

DISPLAY-level, not per-widget, and that is the whole reason the bar looks like
anything now.  GTK4 does not inherit a provider attached to a widget's context
to its descendants -- unlike GTK3 -- so applying this to each toplevel's
context styled the toplevels alone.  Every button, label and image inside them
kept the theme's styling, which presents as a stylesheet that parses with zero
errors and changes nothing.

Takes no widget, because there is nothing per-window about it: one call covers
every window this shell will ever open, including the ones built later."
  (apply-provider-for-display! (shell-provider)))

