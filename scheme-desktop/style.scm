;;; (scheme-desktop style) -- this shell's stylesheet
;;;
;;; Only the CSS lives here.  Provider lifetime, parse-error reporting and
;;; priority are (scheme-toolkit style)'s job -- they are the same for every
;;; shell, and getting them wrong (an unheld provider, a swallowed parse error)
;;; is a trap each shell should not rediscover.
;;;
;;; Generated in Scheme rather than kept as a .css file, so the palette can
;;; become variables at D6 without a templating step.  For now it is a plain
;;; string.
;;;
;;; Priority: USER (800), matching AGS.  libadwaita's own stylesheet sits
;;; lower, so anything here wins -- which is what a shell wants and what lets
;;; the D6 palette recolour Adw widgets too.

(define-module (scheme-desktop style)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit style)
  #:use-module (srfi srfi-11)
  #:export (apply-shell-css! shell-css shell-provider))

(define shell-css
  "
/* The bar itself.  Astal.Window already gets .background from GTK, so this
   overrides it rather than relying on it. */
.Bar {
  background: rgba(20, 20, 26, 0.92);
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  padding: 0 6px;
  font-size: 13px;
}

/* A bar on the bottom edge needs its border on top.  The class is set by
   widgets/bar.scm from the bar-position option, because the anchor and the
   border side have to agree -- anchoring to one edge and styling for the other
   looks like a CSS bug and is an option bug. */
.Bar.bar-bottom {
  border-bottom: none;
  border-top: 1px solid rgba(255, 255, 255, 0.06);
}

.Bar button,
.Bar menubutton > button {
  background: transparent;
  border: none;
  box-shadow: none;
  min-height: 0;
  padding: 2px 8px;
  border-radius: 6px;
  color: rgba(255, 255, 255, 0.85);
}

.Bar button:hover {
  background: rgba(255, 255, 255, 0.10);
}

/* The focused workspace.  This is the class the workspace module toggles; the
   module decides WHICH pill is current, the stylesheet decides what that looks
   like. */
.Bar .workspace {
  min-width: 22px;
  font-feature-settings: \"tnum\";
  color: rgba(255, 255, 255, 0.55);
}

.Bar .workspace.active {
  background: rgba(120, 170, 255, 0.85);
  color: #10131a;
  font-weight: 600;
}

.Bar .workspace.special {
  font-style: italic;
}

.Bar .clock {
  font-weight: 600;
  color: #fff;
  padding: 0 10px;
}

.Bar .battery {
  padding: 0 6px;
}

.Bar .battery-label {
  font-feature-settings: \"tnum\";
  color: rgba(255, 255, 255, 0.85);
}

.Bar .bar-start, .Bar .bar-end {
  padding: 4px 2px;
}
")

;; One provider for the whole shell, parsed once and reused by every toplevel.
;; The toolkit holds it, so it cannot be collected out from under the windows.
(define %provider #f)

(define (shell-provider)
  "The shell's CSS provider, created on first use."
  (unless %provider
    (let-values (((p errors) (css-provider-for shell-css)))
      (for-each (lambda (e)
                  (format (current-error-port) "scheme-desktop: css: ~a\n" e))
                errors)
      (set! %provider p)))
  %provider)

(define (apply-shell-css! widget)
  "Apply the shell's stylesheet to WIDGET, which should be a toplevel.

Called on each window as it is built; the provider itself is shared."
  (apply-provider! widget (shell-provider)))
