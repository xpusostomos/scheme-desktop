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

(define %padding 8)
(define %spacing 6)
(define %radius 12)
(define %border-width 1)
(define %transition 200)
(define %font-size 11)
(define %icon-size 16)
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
                 ("--padding" . ,(format #f "~apt" %padding))
                 ("--spacing" . ,(format #f "~apt" %spacing))
                 ("--radius" . ,(format #f "~apx" %radius))
                 ("--transition" . ,(format #f "~ams" %transition))
                 ("--border-width" . ,(format #f "~apx" %border-width))
                 ("--font-size" . ,(format #f "~apt" %font-size))
                 ("--icon-size" . ,(format #f "~apx" %icon-size))
                 ("--scale" . ,(format #f "~a" %scale))
                 ("--font-name" . ,(format #f "~s" %font-name))
                 ("--popover-padding" . ,(format #f "~apt" (* %padding 1.6)))
                 ("--popover-radius" . ,(format #f "~apx" (* %radius 2)))
                 ("--ui-padding" . ,(format #f "~apt" %padding))
                 ("--ui-spacing" . ,(format #f "~apt" %spacing))
                 ("--ui-radius" . ,(format #f "~apx" %radius))
                 ("--ui-border-width" . ,(format #f "~apx" %border-width))
                 ("--ui-font-size" . ,(format #f "~apt" %font-size))
                 ("--ui-icon-size" . ,(format #f "~apx" %icon-size))
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
