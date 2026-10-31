;;; (scheme-desktop theme) -- ags2-shell's CSS variable system
;;;
;;; Ported from ags2-shell's style/runtime-css.ts.  Every variable it emits is
;;; emitted here with the same name and the same derivation, because the goal is
;;; that a rule copied from their stylesheet resolves identically.
;;;
;;; WHY THIS EXISTS AT ALL.  The bar's appearance is not a handful of colours:
;;; it is 40 variables including DERIVED ones -- neumorphic highlight and shadow
;;; strings built from the theme's mode and scale, a hover foreground mixed from
;;; the foreground, a popover border one opacity step lighter than the border.
;;; Guessing at those individually is how a bar ends up "almost right", which is
;;; the thing being fixed.
;;;
;;; THE COLOUR MATHS IS DONE BY CSS.  ags2-shell's color_mix is literally
;;;
;;;   `color-mix(in srgb, ${color} ${percent}%, transparent)'
;;;
;;; -- a CSS function, not a computed value -- so nothing here needs to mix
;;; colours in Scheme.  GTK 4.24 parses color-mix, which is what makes that
;;; possible; the emission is then a faithful copy rather than an approximation.
;;;
;;; Source of the palette: the desktop's own theme (see (scheme-toolkit
;;; palette)), so the shell follows Omarchy rather than carrying its own idea of
;;; what the colours are.

(define-module (scheme-desktop theme)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit palette)
  ;; For the bar's own options: `icon-button-size' is the bar's, read here when
  ;; the stylesheet is generated.
  #:use-module (scheme-toolkit app)
  ;; The theme widget, which owns `ui-scale'.  Importing the widget rather than
  ;; the shell's config module is the point: the option's reader and the
  ;; option's declaration are now the same module.
  #:use-module (scheme-desktop widgets theme)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (theme-vars theme-css theme-mode theme-dark?))

;;; ---------------------------------------------------------------------------
;;; Layout constants
;;; ---------------------------------------------------------------------------
;;
;; ags2-shell's defaults, from shell/options.ts, at scale 1.0:
;;    theme.padding   8      theme.spacing  6      theme.roundness 12
;;    theme.border.width 1   transition.duration 200
;;    font 11pt             icon 16px
;;
;; These are not CSS variables in their system -- they are computed in
;; TypeScript and emitted as numbers -- so they live here as ordinary values.

(define %base-padding 8)
(define %base-spacing 6)
(define %base-radius 12)
(define %base-border-width 1)
(define %transition 200)
(define %base-font-size 11)
(define %base-icon-size 16)

;; THE ONE NUMBER THAT SCALES THE SHELL.
;;
;; Everything the stylesheet sizes is multiplied by it, so the text and the
;; boxes around it grow together. Raising only the font size is the obvious
;; thing to reach for and the wrong one: the labels then outgrow their padding
;; and the bar looks cramped rather than bigger.
;;
;; Read on every call, not captured at load: a module's top-level defines run
;; once, and this is meant to be changeable from the config file.
(define (ui-scale)
  (catch #t
    (lambda () (theme-scale (theme-widget)))
    (lambda args 1.0)))

;; Rounded, and never below 1: a 0.4px border is not a thin border, it is a
;; border that is not drawn, and a 0pt font is not a small font.
(define (scaled n)
  (inexact->exact (max 1 (round (* n (ui-scale))))))
(define %scale 1.0)
(define %font-name "Sans")

;;; ---------------------------------------------------------------------------
;;; Palette derivation
;;; ---------------------------------------------------------------------------
;;
;; ags2-shell's compute_palette, with the desktop's colours substituted for its
;; hard-coded theme options.  The SHAPE is what is being ported: which colour
;; becomes the background, which is mixed at what opacity to make a widget, and
;; so on.

(define (mix color percent)
  "ags2-shell's color_mix -- a CSS colour-mix, not a computed value."
  (format #f "color-mix(in srgb, ~a ~a%, transparent)" color percent))

(define (darken-hex hex)
  "ags2-shell's darken_hex_color: each channel times 0.96."
  (if (and (string? hex) (= 7 (string-length hex)) (char=? (string-ref hex 0) #\#))
      (let* ((r (string->number (substring hex 1 3) 16))
             (g (string->number (substring hex 3 5) 16))
             (b (string->number (substring hex 5 7) 16))
             (d (lambda (c) (inexact->exact (round (* c 0.96))))))
        (format #f "#~2,'0x~2,'0x~2,'0x" (d r) (d g) (d b)))
      hex))

(define (theme-mode)
  "The theme's mode as a symbol: 'dark or 'light."
  (let* ((p (read-palette))
         (m (and p (palette-ref p 'mode))))
    (if (and (string? m) (string-ci=? m "light")) 'light 'dark)))

(define (theme-dark?) (eq? 'dark (theme-mode)))

(define (col key fallback)
  "The palette's KEY, or FALLBACK.

The Omarchy names do not match ags2-shell's option names, so the mapping is
explicit rather than a rename: omarchy's `background' is their `bg', its
`accent' is their `primary.bg'."
  (let ((p (read-palette)))
    (or (and p (palette-ref p key)) fallback)))

(define (bg-color)   (col 'background "#171717"))
(define (fg-color)   (col 'foreground "#eeeeee"))
(define (accent)     (col 'accent "#51a4e7"))
(define (error-bg)   (col 'red "#e55f86"))

;; Opacities, from ags2-shell's defaults.  Their `widget' and `border' options
;; name a COLOUR to tint with; the desktop's equivalents are the foreground and
;; the muted shade, which is what makes a widget surface read as part of the
;; theme rather than as a grey overlay.
(define %bg-opacity 30)
(define %widget-opacity 94)
(define %border-opacity 86)

(define (bg)          (mix (bg-color) (- 100 %bg-opacity)))
(define (widget-bg)   (mix (fg-color) (- 100 %widget-opacity)))
(define (hover-bg)    (mix (fg-color) (- 100 (* %widget-opacity 0.9))))
(define (border-color) (mix (fg-color) (- 100 %border-opacity)))
(define (popover-border-color)
  (mix (fg-color) (- 100 (max (- %border-opacity 1) 0))))

(define (primary-bg) (accent))
(define (primary-fg) (if (theme-dark?) (bg-color) (fg-color)))

;; The active gradient is what makes a toggled button look pressed.
(define (active-gradient)
  (format #f "linear-gradient(to right, ~a, ~a)" (primary-bg) (darken-hex (primary-bg))))

(define (shadow-color)
  (if (theme-dark?) "rgba(0, 0, 0, 0.6)" "rgba(0, 0, 0, 0.4)"))

;;; ---------------------------------------------------------------------------
;;; Neumorphic effect strings
;;; ---------------------------------------------------------------------------
;;
;; ags2-shell's `neu` block.  These are box-shadow VALUES built from the mode:
;; in dark mode the highlight is white and the shadow black; in light mode both
;; come from the foreground, at lower percentages.  Reproduced exactly, because
;; a bar with the wrong neumorphic depth looks subtly wrong in a way that is
;; hard to name and easy to see next to the original.

(define (highlight-color) (if (theme-dark?) "white" (fg-color)))
(define (shadow-base)    (if (theme-dark?) "black" (fg-color)))

(define (pct dark light) (if (theme-dark?) dark light))
(define (px n) (format #f "~apx" (* n %scale)))

(define (neu-button-highlight)
  (format #f "inset 0 ~a 0 0 ~a" (px 1) (mix (highlight-color) (pct 15 10))))

(define (neu-button-shadow)
  (format #f "0 ~a ~a 0 ~a" (px 1) (px 2) (mix (shadow-base) (pct 20 14))))

(define (neu-button-hover-highlight)
  (format #f "inset 0 ~a 0 0 ~a" (px 1) (mix (highlight-color) (pct 20 14))))

(define (neu-button-hover-shadow)
  (format #f "0 ~a ~a 0 ~a" (px 1) (px 3) (mix (shadow-base) (pct 25 18))))

(define (neu-button-active-highlight)
  (format #f "inset 0 ~a 0 0 ~a" (px 1) (mix "white" 35)))

(define (neu-button-active-shadow)
  (format #f "0 ~a ~a 0 ~a" (px 1) (px 3) (mix "black" 35)))

(define (neu-widget-highlight)
  (format #f "inset 0 ~a 0 0 ~a" (px 1) (mix (highlight-color) 12)))

(define (neu-widget-shadow)
  (format #f "0 ~a ~a 0 ~a" (px 1) (px 2) (mix (shadow-base) (pct 17 12))))

(define (neu-trough-inset)
  (format #f "inset 0 ~a ~a 0 ~a, inset 0 ~a 0 0 ~a"
          (px 1) (px 2) (mix (shadow-base) (pct 15 10))
          (px -1) (mix (highlight-color) (pct 5 4))))

(define (neu-progress-highlight)
  (format #f "inset 0 ~a 0 0 ~a" (px 1) (mix (highlight-color) (pct 20 14))))

(define (neu-progress-shadow)
  (format #f "0 ~a ~a 0 ~a" (px 1) (px 1) (mix (shadow-base) (pct 20 14))))

(define (neu-slider-highlight)
  (format #f "inset 0 ~a 0 0 ~a" (px 1) (mix (highlight-color) (pct 30 22))))

;;; ---------------------------------------------------------------------------
;;; Emission
;;; ---------------------------------------------------------------------------

(define %default-icon-button-size 24)

(define (icon-button-size)
  "The bar's icon-button size in pixels, for `--icon-button-size'.

READ OFF THE BAR WIDGET, which owns the option, rather than declared here: this
is the value the stylesheet is generated from, and generating it at the moment it
is asked for is what makes changing the option a restyle."
  (let ((bar (catch #t (lambda () (desktop-widget-named 'bar)) (lambda args #f))))
    (or (and bar (catch #t (lambda () (slot-ref bar 'icon-button-size))
                        (lambda args #f)))
        %default-icon-button-size)))

(define %default-panel-opacity 0.92)

(define (panel-opacity)
  "How opaque a panel's background is, from the shell's own option.

A GLOBAL VALUE FOR PANELS, because they are all the same kind of surface and
setting four of them separately is four chances to disagree.  The bar has had an
`opacity' option all along; this is its counterpart for the windows that open.

`color-mix' rather than an rgba literal: the palette is sRGB hex, and mixing it
towards transparent keeps whatever hue the wallpaper chose."
  (let ((theme (catch #t (lambda () (desktop-widget-named 'theme)) (lambda args #f))))
    (let ((v (and theme (catch #t (lambda () (slot-ref theme 'panel-opacity))
                               (lambda args #f)))))
      (if (and (number? v) (>= v 0.2) (<= v 1)) v %default-panel-opacity))))

(define (theme-vars)
  "Every variable ags2-shell emits, in its order, as a string.

`*' is the selector because GTK has no document root: matching every widget is
what makes the variables visible throughout the tree, and it is what
ags2-shell's `*' rule does too."
  (string-append
   "* {\n"
   (apply string-append
          (map (lambda (pair) (format #f "  ~a: ~a;\n" (car pair) (cdr pair)))
               `(("--bg" . ,(bg))
                 ("--fg" . ,(fg-color))
                 ("--primary-bg" . ,(primary-bg))
                 ("--primary-fg" . ,(primary-fg))
                 ("--error-bg" . ,(error-bg))
                 ("--padding" . ,(format #f "~apt" (scaled %base-padding)))
                 ("--spacing" . ,(format #f "~apt" (scaled %base-spacing)))
                 ("--radius" . ,(format #f "~apx" (scaled %base-radius)))
                 ("--transition" . ,(format #f "~ams" %transition))
                 ("--border-width" . ,(format #f "~apx" (scaled %base-border-width)))
                 ("--font-size" . ,(format #f "~apt" (scaled %base-font-size)))
                 ("--icon-size" . ,(format #f "~apx" (scaled %base-icon-size)))
                 ;; WHAT A PANEL IS PAINTED WITH, for every panel.  The windows
                 ;; themselves are transparent -- a popup covers the screen and
                 ;; painting it would dim the desktop -- so each panel's CARD
                 ;; carries this.
                 ("--panel-bg" . ,(format #f "color-mix(in srgb, ~a ~a%, transparent)"
                                          (bg) (inexact->exact (round (* 100 (panel-opacity))))))
                 ;; The hover circle behind a bar icon: one number for the whole
                 ;; bar, from the bar's own option.
                 ("--icon-button-size" . ,(format #f "~apx" (scaled (icon-button-size))))
                 ("--scale" . ,(format #f "~a" %scale))
                 ("--font-name" . ,(format #f "~s" %font-name))
                 ("--popover-padding" . ,(format #f "~apt" (* (scaled %base-padding) 1.6)))
                 ("--popover-radius" . ,(format #f "~apx" (* (scaled %base-radius) 2)))
                 ("--ui-padding" . ,(format #f "~apt" (scaled %base-padding)))
                 ("--ui-spacing" . ,(format #f "~apt" (scaled %base-spacing)))
                 ("--ui-radius" . ,(format #f "~apx" (scaled %base-radius)))
                 ("--ui-border-width" . ,(format #f "~apx" (scaled %base-border-width)))
                 ("--ui-font-size" . ,(format #f "~apt" (scaled %base-font-size)))
                 ("--ui-icon-size" . ,(format #f "~apx" (scaled %base-icon-size)))
                 ("--shadow-color" . ,(shadow-color))
                 ("--active-gradient" . ,(active-gradient))
                 ("--widget-bg" . ,(widget-bg))
                 ("--hover-bg" . ,(hover-bg))
                 ("--border-color" . ,(border-color))
                 ("--popover-border-color" . ,(popover-border-color))
                 ("--neu-button-highlight" . ,(neu-button-highlight))
                 ("--neu-button-shadow" . ,(neu-button-shadow))
                 ("--neu-button-hover-highlight" . ,(neu-button-hover-highlight))
                 ("--neu-button-hover-shadow" . ,(neu-button-hover-shadow))
                 ("--neu-button-active-highlight" . ,(neu-button-active-highlight))
                 ("--neu-button-active-shadow" . ,(neu-button-active-shadow))
                 ("--neu-widget-highlight" . ,(neu-widget-highlight))
                 ("--neu-widget-shadow" . ,(neu-widget-shadow))
                 ("--neu-trough-inset" . ,(neu-trough-inset))
                 ("--neu-progress-highlight" . ,(neu-progress-highlight))
                 ("--neu-progress-shadow" . ,(neu-progress-shadow))
                 ("--neu-slider-highlight" . ,(neu-slider-highlight)))))
   "}\n"))

(define (theme-css)
  "The variables plus the two derived values ags2-shell defines on `*'.

`--hover-fg', `--border' and `--surface-edge-color' are shorthands their
foundation stylesheet sets for everything, and rules copied from it reference
them."
  (string-append
   (theme-vars)
   "* {\n"
   (format #f "  --hover-fg: color-mix(in srgb, var(--fg), white 8%);~%")
   (format #f "  --border: var(--border-width) solid var(--border-color);~%")
   (format #f "  --surface-edge-color: color-mix(in srgb, var(--fg) 14%, transparent);~%")
   (format #f "  font-size: var(--font-size);~%")
   (format #f "  font-family: var(--font-name);~%")
   "}\n"))
