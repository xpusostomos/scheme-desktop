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
  #:use-module (scheme-desktop theme)
  #:use-module (srfi srfi-11)
  #:export (apply-shell-css! shell-css shell-provider shell-palette))

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

image {
  -gtk-icon-size: var(--icon-size, 16px);
}

window {
  background-color: var(--bg);
  color: var(--fg);
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

/* ---- popovers, including the tray's menus ----------------------------- */

popover.menu {
  background: transparent;
  box-shadow: none;
  border: none;
}

popover.menu > arrow {
  background: transparent;
  box-shadow: none;
  border: none;
}

popover.menu > contents {
  box-shadow: 0 0 5px 0 var(--shadow-color);
  margin: max(var(--spacing), 8px);
  border: var(--border-width) solid var(--popover-border-color);
  background-color: var(--bg);
  color: var(--fg);
  border-radius: calc(var(--popover-radius) / 2);
  padding: calc(var(--padding) / 2);
  min-width: 180px;
}

popover.menu > contents stack,
popover.menu > contents box {
  padding: 0;
  margin: 0;
}

popover.menu > contents modelbutton {
  background-color: transparent;
  box-shadow: none;
  transition: var(--transition);
  border-radius: var(--radius);
  color: var(--fg);
  padding: calc(var(--padding) * 0.8);
  min-height: 0;
  margin: 0;
}

popover.menu > contents modelbutton:focus-visible:hover {
  outline: none;
}

popover.menu > contents modelbutton check,
popover.menu > contents modelbutton radio,
popover.menu > contents modelbutton arrow {
  min-width: 0;
  min-height: 0;
  margin: 0;
  padding: 0;
}

popover.menu > contents modelbutton .accelerator {
  color: color-mix(in srgb, var(--fg) 60%, transparent);
  font-size: 0.9em;
  margin-left: calc(var(--spacing) / 2);
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

/* A bar on the bottom edge.  Not an ags2-shell rule: theirs switches on the
   anchor in TypeScript, and this shell does it with a class from
   widgets/bar.scm. */
window#bar.bar-bottom .panel {
  border-top: var(--border-width) solid var(--border-color);
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

/* The focused workspace, toggled by the workspaces module.  The module decides
   WHICH pill is current; this decides what that looks like. */
window#bar .workspace {
  min-width: 24px;
  color: color-mix(in srgb, var(--fg) 60%, transparent);
  font-weight: bold;
}

window#bar .workspace.active {
  background-color: var(--primary-bg);
  color: var(--primary-fg);
}

window#bar .workspace.special {
  font-style: italic;
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
 * The arithmetic: a tray button is an icon plus `calc(var(--padding) / 2)' of
 * padding either side -- about 27px square -- and ags2-shell gives it
 * `border-radius: var(--radius)', which is 12px.  12px on a 27px box is 89% of
 * the way to a circle, which reads as a squircle rather than as either shape.
 * `50%' is always exactly half the side, so it stays a circle whatever the
 * icon size or padding becomes.
 *
 * The alternative -- raising --radius -- would change every other widget in the
 * bar too, since that is what the whole stylesheet's corners are built from. */
window#bar .tray-item {
  border-radius: 50%;
}
")

(define (shell-css)
  "The whole stylesheet: theme variables, ags2-shell's base, then the bar."
  (string-append (theme-css) %base-css %bar-css))

;; One provider for the whole shell, parsed once and reused by every toplevel.
;; The toolkit holds it, so it cannot be collected out from under the windows.
(define %provider #f)

(define (shell-provider)
  "The shell's CSS provider, created on first use."
  (unless %provider
    (let-values (((p errors) (css-provider-for (shell-css))))
      (for-each (lambda (e)
                  (format (current-error-port) "scheme-desktop: css: ~a\n" e))
                errors)
      (set! %provider p)))
  %provider)

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

