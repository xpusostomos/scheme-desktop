;;; (scheme-desktop style) -- this shell's stylesheet
;;;
;;; The CSS lives here; provider lifetime, parse-error reporting and priority
;;; are (scheme-toolkit style)'s job, and colour files are
;;; (scheme-toolkit palette)'s.  That split is the point: every shell has a
;;; stylesheet, and none of them should rediscover that an unheld provider is
;;; collected or that a colour literal begins with '#'.
;;;
;;; COLOURS COME FROM THE PALETTE, substituted at generation time, and the
;;; stylesheet is rebuilt when the palette changes.  The alternative -- emitting
;;; a `:root { --accent: ... }' block and writing var(--accent) in every rule --
;;; was tried and dropped for two reasons:
;;;
;;;   - half the palette's keys are not valid custom-property names.  Omarchy
;;;     writes dark_background and bright_foreground; a custom property name has
;;;     to be a CSS identifier, and underscores are legal but the file's own
;;;     convention is hyphens, so the emitted block silently declared nothing
;;;     anybody could reference.
;;;   - it bought nothing here.  GTK has no document root; `:root' matches every
;;;     widget, which is a weaker guarantee than it looks, and a substituted
;;;     literal cannot fail to resolve.
;;;
;;; Regenerating the provider is cheap and certain, so that is what a palette
;;; change does.
;;;
;;; The palette itself is READ from whatever this machine provides -- on an
;;; Omarchy system that is ~/.local/state/omarchy/current/theme/colors.toml, so
;;; the shell follows the desktop's own theme rather than competing with it.
;;; Nothing found means the built-in default, so a fresh machine is merely
;;; less pretty, never broken.

(define-module (scheme-desktop style)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit style)
  #:use-module (scheme-toolkit palette)
  #:use-module (srfi srfi-11)
  #:export (apply-shell-css! shell-css shell-provider shell-palette))

;; The palette in force.  Read once: a theme change is followed by a reload,
;; not by re-reading the file on every redraw.
(define %palette #f)

(define (shell-palette)
  "The palette this machine provides, or the built-in default."
  (unless %palette
    (set! %palette (or (read-palette) default-palette)))
  %palette)

;; A colour from the palette with an alpha applied, since several surfaces want
;; the background a little translucent and GTK's rgba() is the only way to say
;; so from a hex value.
(define (alpha key a)
  (let ((hex (palette-ref (shell-palette) key)))
    (if (and hex (string? hex) (char=? (string-ref hex 0) #\#)
             (= 7 (string-length hex)))
        (format #f "rgba(~a, ~a, ~a, ~a)"
                (string->number (substring hex 1 3) 16)
                (string->number (substring hex 3 5) 16)
                (string->number (substring hex 5 7) 16)
                a)
        hex)))

(define (shell-css)
  "The whole stylesheet, with the palette's colours substituted into it."
  (string-append
   "
/* ---- the bar ---------------------------------------------------------- */

.Bar {
  background: " (alpha 'background 0.92) ";
  border-bottom: 1px solid " (alpha 'foreground 0.06) ";
  padding: 0 6px;
  font-size: 13px;
  color: " (palette-ref (shell-palette) 'foreground) ";
}

/* A bar on the bottom edge needs its border on top.  The class is set by
   widgets/bar.scm from the bar-position option, because the anchor and the
   border side have to agree -- anchoring to one edge and styling for the other
   looks like a CSS bug and is an option bug. */
.Bar.bar-bottom {
  border-bottom: none;
  border-top: 1px solid " (alpha 'foreground 0.06) ";
}

.Bar button,
.Bar menubutton > button {
  background: transparent;
  border: none;
  box-shadow: none;
  min-height: 0;
  padding: 2px 8px;
  border-radius: 6px;
  color: " (alpha 'foreground 0.85) ";
}

.Bar button:hover {
  background: " (alpha 'foreground 0.10) ";
}

/* The focused workspace.  The class is toggled by the workspaces module; the
   module decides WHICH pill is current, the stylesheet decides what that looks
   like. */
.Bar .workspace {
  min-width: 22px;
  color: " (alpha 'muted 1.0) ";
}

.Bar .workspace.active {
  background: " (palette-ref (shell-palette) 'accent) ";
  color: " (palette-ref (shell-palette) 'background) ";
  font-weight: 600;
}

.Bar .workspace.special {
  font-style: italic;
}

.Bar .clock {
  font-weight: 600;
  color: " (palette-ref (shell-palette) 'foreground) ";
  padding: 0 10px;
}

.Bar .battery {
  padding: 0 6px;
}

.Bar .battery-label {
  color: " (alpha 'foreground 0.85) ";
}

.Bar .bar-start, .Bar .bar-end {
  padding: 4px 2px;
}

/* A battery low enough to matter.  The class comes from the battery module,
   which is alone in knowing what 'low' means for the current state. */
.Bar .battery.low .battery-label {
  color: " (palette-ref (shell-palette) 'red) ";
}

/* Network and bluetooth share the 'unavailable' convention: present in the
   layout, dimmed rather than removed, so the bar does not reflow when a device
   comes and goes. */
.Bar .unavailable {
  color: " (alpha 'muted 0.55) ";
}
"))

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

(define (apply-shell-css! widget)
  "Apply the shell's stylesheet to WIDGET, which should be a toplevel.

Called on each window as it is built; the provider itself is shared."
  (apply-provider! widget (shell-provider)))
