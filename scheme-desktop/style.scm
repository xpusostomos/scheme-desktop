;;; (scheme-desktop style) -- the stylesheet
;;;
;;; Generated in Scheme rather than kept as a .css file, so that the palette can
;;; become variables at D6 without a templating step.  For now it is a plain
;;; string with the shape the theming work will fill in.
;;;
;;; Priority: USER (800), matching AGS.  libadwaita's own stylesheet is at a
;;; lower priority, so anything here wins -- which is what a shell wants and
;;; what makes the D6 palette able to recolour Adw widgets too.

(define-module (scheme-desktop style)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:export (apply-shell-css! shell-css))

(define-gi-imports "Gtk" "CssProvider" "StyleContext")

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

;; The provider is held here for the process's lifetime.
;;
;; A Gtk.CssProvider that nothing references is collected, and its styles then
;; stop being applied -- the same trap as Gio.FileMonitor in (scheme-toolkit
;; file), and it presents the same way: the stylesheet "works" for a while and
;; then stops.
(define %provider #f)

(define* (shell-provider #:optional (css shell-css))
  "Load CSS and return a provider, at USER priority (800).

Per-widget rather than per-display.  gtk_style_context_add_provider_for_display
is what a shell wants -- one call covers every window -- but GTK marks it
deprecated and G-Golf's importer skips deprecated symbols, so it is not
reachable by name.  Adding the provider to each toplevel's style context is the
supported path and behaves the same for a handful of windows."
  (unless %provider
    (let ((provider (make <gtk-css-provider>)))
      ;; GTK reports each bad rule through this signal with its line and
      ;; column, which is the only practical way to find a typo.
      (connect provider 'parsing-error
               (lambda (p section error)
                 (format (current-error-port) "scheme-desktop: css: ~a\n"
                         (catch #t (lambda () (slot-ref error 'message))
                                (lambda a "parse error")))))
      (load-from-string provider css)
      (set! %provider provider)))
  %provider)

(define (apply-shell-css! widget)
  "Apply the shell's stylesheet to WIDGET, which should be a toplevel.

Called on each window as it is built; the provider itself is created once."
  (catch #t
    (lambda ()
      (let ((ctx (get-style-context widget)))
        (add-provider ctx (shell-provider) 800)
        #t))
    (lambda (key . args)
      (format (current-error-port)
              "scheme-desktop: cannot apply css to ~a: ~a ~s\n"
              (catch #t (lambda () (class-name (class-of widget))) (lambda a '?))
              key args)
      #f)))
