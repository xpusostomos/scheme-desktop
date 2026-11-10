;;; (scheme-desktop widgets battery) -- the battery, in the bar and as a menu
;;;
;;; PORTED FROM OMARCHY's power panel (`plugins/panels/power/`), which is both the
;;; bar item and the dropdown: the same file in QML, split here into the two
;;; widgets this shell gives every feature.
;;;
;;; WHERE THE NUMBERS COME FROM.  Charge and charging state are live properties
;;; from (scheme-toolkit services battery), which gets them from Astal and
;;; signals when they move.  Health, cycles, design capacity, voltage and
;;; temperature come from the same service's /sys readers, because Astal declares
;;; those properties and leaves them at zero; see that module for what was
;;; measured.
;;;
;;; THE GLYPHS ARE THEIRS, codepoint for codepoint, including the charge-limit
;;; rule: a laptop parked at 80% is NOT charging, and drawing a charging glyph
;;; there says the machine is filling up when it has deliberately stopped.

(define-module (scheme-desktop widgets battery)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit style)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit services battery)
  #:use-module (scheme-toolkit services power-profiles)
  #:use-module (oop goops)
  ;; `map' COMES FROM G-GOLF, which re-exports core Guile's own (its method is a
  ;; one-line wrapper around it -- see `hl-api/gobject.scm').  Taking it from
  ;; `(srfi srfi-1)' as well is the same procedure imported twice, and the
  ;; compiler says so on every start; `filter' is the reason this import is here.
  #:use-module ((srfi srfi-1) #:hide (map))
  #:use-module (ice-9 format)

  #:export (<battery-desktop-widget> <battery-panel-desktop-widget>
            battery-glyph))

;; The widget classes this module builds.  The classes are imported BY NAME --
;; whole-namespace `gi-import "Gtk"' costs 2.7 s -- and a class that is not
;; imported here is a compile-time warning and a runtime failure.
(define-gi-imports "Gtk" "Box" "Label" "Button" "ProgressBar")

;;; ---------------------------------------------------------------------------
;;; Glyphs
;;; ---------------------------------------------------------------------------

;; WRITTEN AS `integer->char' AND NEVER AS `"\U000F0079"'.  In Guile that escape
;; is not a Unicode escape at all: it reads as a SIX-digit hex escape plus literal
;; text, so the whole table would be two characters of noise per entry -- which is
;; what the wifi panel's icons were until it was caught.  The codepoints below
;; were read out of Omarchy's Model.js with `ord', not typed.
(define (glyph codepoint) (string (integer->char codepoint)))

;; Ten steps of charge, from empty to full, and the same ten while charging.
(define %default-icons
  (map glyph (list #x0F007A #x0F007B #x0F007C #x0F007D #x0F007E
                   #x0F007F #x0F0080 #x0F0081 #x0F0082 #x0F0079)))
(define %charging-icons
  (map glyph (list #x0F089C #x0F0086 #x0F0087 #x0F0088 #x0F089D
                   #x0F0089 #x0F089E #x0F008A #x0F008B #x0F0085)))
(define %icon-full  (glyph #x0F0085))
(define %icon-off   (glyph #x0F0084))

(define (battery-glyph charging? state percentage)
  "The battery glyph for CHARGE, as Omarchy's `batteryIcon'.

INDEX IS BY TENTH, so 83% and 88% are the same glyph -- which is the point of a
ten-step table: the icon says roughly how full it is, and the number says exactly."
  (if (not (number? percentage))
      %icon-off
      (let ((index (max 0 (min 9 (inexact->exact (floor (* percentage 10)))))))
        (cond ((eq? state 'fully-charged) %icon-full)
              ((not charging?) (list-ref %default-icons index))
              (else (list-ref %charging-icons index))))))

(define (percent-string v)
  "0.84 => \"84%\".

`round' on a float returns a float in Guile, so ~a prints 84.0.  Converting to an
exact integer first is what makes the label read 84%."
  (if (number? v)
      (format #f "~a%" (inexact->exact (round (* 100 v))))
      ""))

;;; ---------------------------------------------------------------------------
;;; The bar item
;;; ---------------------------------------------------------------------------

(define-class <battery-desktop-widget> (<bar-item-widget>)
  ;; WHAT THE BAR'S BATTERY ITEM SHOWS, the two switches Omarchy has, with his
  ;; defaults: the icon always, the number only if asked for.
  ;;
  ;;   both on     the number after the icon
  ;;   icon only   the default
  ;;   number only the number
  ;;   NEITHER     the icon anyway -- an item with nothing in it is not a
  ;;               smaller item, it is an absent one, and a switch that can make
  ;;               a widget vanish is a switch people set by accident
  (show-icon #:init-value #t #:init-keyword #:show-icon
             #:accessor battery-show-icon
             #:config '(boolean)
             #:label "Show the battery icon")
  (show-percentage #:init-value #f #:init-keyword #:show-percentage
                   #:accessor battery-show-percentage
                   #:config '(boolean)
                   #:label "Show the percentage"))

(define-method (widget-build (w <battery-desktop-widget>) output)
  "The bar's battery: a glyph, and the percentage when it is asked for.

A DESKTOP GETS AN EMPTY BOX, not a battery at 0%: `battery-present?' is #f there,
and a widget whose service is absent must be absent rather than show a
plausible-looking lie."
  (if (not (battery-present?))
      (element <gtk-box> #:class "battery" #:visible #f)
      (let* ((state (battery-state))
             (charging (battery-charging?))
             (pct (battery-percentage))
             ;; TRACKING READS: a computed whose body only peeks has no
             ;; dependencies and is a snapshot of when it was built.
             (icon (create-computed
                    (lambda ()
                      (battery-glyph (charging) (state) (pct)))
                    'battery-glyph))
             (text (create-computed (lambda () (percent-string (pct))) 'battery-percent))
             (show-icon (widget-slot-ref w 'show-icon))
             (show-pct (widget-slot-ref w 'show-percentage))
             (icon-visible (create-computed
                            (lambda () (or (show-icon) (not (show-pct))))))
             (pct-visible (create-computed (lambda () (show-pct))))
             (btn (panel-button (desktop-widget-required <battery-panel-desktop-widget>)
                                #:align (widget-section w)
                                ;; ONE CHILD, because a GtkButton has room for
                                ;; one: two labels passed to the button means the
                                ;; second replaces the first, silently.
                                (element <gtk-box> #:orientation 'horizontal
                                         #:class "battery-item"
                                         #:halign 'center
                                         (element <gtk-label> #:class "battery-icon"
                                                  #:label (or icon %icon-off)
                                                  #:visible icon-visible)
                                         (element <gtk-label> #:class "battery-label"
                                                  #:label (or text "")
                                                  #:visible pct-visible)))))
        (create-effect
         (lambda ()
           (toggle-class! btn "low" (and (number? (pct)) (< (pct) 0.15)
                                         (not (charging)))))
         #:immediate #t)
        (create-effect
         (lambda () (toggle-class! btn "icon-only" (not (pct-visible))))
         #:immediate #t)
        btn)))

;;; ---------------------------------------------------------------------------
;;; The panel
;;; ---------------------------------------------------------------------------

(define-class <battery-panel-desktop-widget> (<popup-widget>)
  (window #:init-value #f #:accessor battery-panel-window
          #:setter battery-panel-window-set!)
  (content #:init-value #f #:accessor battery-panel-content
           #:setter battery-panel-content-set!))

(define (detail-row label value)
  "One line of the menu: a name on the left, a number on the right.

#f VALUES ARE DROPPED, which is most of them on a machine that reports little: a
row reading `Cycles  --' is noise, and Omarchy's panel leaves those out too."
  (and value
       (element <gtk-box> #:orientation 'horizontal #:class "battery-row"
                (element <gtk-label> #:class "battery-row-label" #:label label
                         #:xalign 0.0 #:hexpand #t)
                (element <gtk-label> #:class "battery-row-value" #:label value
                         #:xalign 1.0))))

(define (wh v) (and v (format #f "~,1f Wh" v)))
(define (pct v) (and v (percent-string v)))
(define (deg v) (and v (format #f "~,1f°C" v)))
(define (volts v) (and v (format #f "~,2f V" v)))
(define (watts v) (and v (format #f "~,1f W" v)))

(define (profile-buttons w)
  "A button per power profile, the active one marked.

THE PROFILES COME FROM THE KERNEL (`platform_profile_choices') and the ACTIVE one
from Astal's property -- see (scheme-toolkit services power-profiles) for why not
from Astal's own profile LIST, which segfaults.  A machine that offers none gets
no buttons at all rather than a control that cannot do anything."
  ;; `power-profile' IS A PLAIN READ (see the service for why it is not an
  ;; accessor): the value, not a peek.
  (let ((profiles (power-profiles-list))
        (active (power-profile)))
    (if (null? profiles)
        (element <gtk-box> #:visible #f)
        ;; `apply': a LIST OF CHILDREN IS NOT A CHILD -- `element' passes the list
        ;; itself to `add-child!', which answers "No applicable method" naming the
        ;; buttons inside it.  Splice them.
        (apply element <gtk-box> #:orientation 'horizontal #:class "battery-profiles"
               (map (lambda (profile)
                        (element <gtk-button>
                                 ;; GLYPH AND NAME, and the name is what a
                                 ;; person reads: the glyph alone is three
                                 ;; shapes nobody recognises.
                                 #:label (format #f "~a ~a"
                                                 (power-profile-icon profile)
                                                 (power-profile-label profile))
                                 ;; MARKED, so the active one is legible as the
                                 ;; active one rather than by elimination.
                                 ;;
                                 ;; ONE `#:class' AND NOT TWO: an earlier version
                                 ;; of this line and a later one were left
                                 ;; stacked, and the first wins -- so the
                                 ;; conditional below never ran and nothing was
                                 ;; ever marked.
                                 #:class (if (eq? profile active)
                                             "battery-profile active"
                                             "battery-profile")
                                 #:on-clicked (lambda (b)
                                                (power-profile-set! profile)
                                                (refresh-battery-panel! w))))
                    profiles)))))

(define (state-phrase)
  "What the battery is doing, in a word.

OMARCHY HAS PHRASES HERE (`onBatteryPhrases') and this shell has states, because
the states are what the data actually distinguishes.  THRESHOLD is the one worth
having: a laptop held at 80% by a charge limit is not charging and is not
discharging, and neither word is true of it."
  (let ((state (st-peek (battery-state))))
    (cond ((eq? state 'charging) "Charging")
          ((eq? state 'discharging) "Discharging")
          ((eq? state 'empty) "Empty")
          ((battery-charge-threshold?) "Threshold -- holding at a charge limit")
          ((eq? state 'fully-charged) "Full")
          ((eq? state 'pending-charge) "Not charging")
          (else "Unknown"))))

(define (stat-column rows)
  (apply element <gtk-box> #:orientation 'vertical (filter values rows)))

(define (build-battery-content! w)
  "The menu's contents, to Omarchy's shape: a big glyph and the number at the
head, the charge as a bar under them, then two columns of stats, then the
profile buttons.

BUILT FRESH EACH TIME: the stats are file reads taken now, and a menu that shows
yesterday's cycle count is worse than one that shows none."
  (let ((content (battery-panel-content w)))
    (clear-box! content)
    (add-child! content
                (element <gtk-box> #:orientation 'vertical #:class "battery-panel"
                         ;; THE HEAD: glyph, the word, the state under it, and the
                         ;; number at the far right.
                         (element <gtk-box> #:orientation 'horizontal #:class "battery-head"
                                  (element <gtk-label> #:class "battery-big-icon"
                                           #:label (battery-glyph (st-peek (battery-charging?))
                                                                  (st-peek (battery-state))
                                                                  (st-peek (battery-percentage)))
                                           #:valign 'center)
                                  (element <gtk-box> #:orientation 'vertical #:hexpand #t
                                           #:valign 'center
                                           (element <gtk-label> #:class "battery-title"
                                                    #:label "Battery" #:xalign 0.0)
                                           (element <gtk-label> #:class "battery-state"
                                                    #:label (state-phrase) #:xalign 0.0))
                                  (element <gtk-label> #:class "battery-big-pct"
                                           #:label (or (percent-string (st-peek (battery-percentage)))
                                                       "--")
                                           #:valign 'center))
                         ;; THE GRAPH: the same charge, across the card.
                         (element <gtk-progress-bar> #:class "battery-bar"
                                  #:fraction (or (st-peek (battery-percentage)) 0)
                                  #:show-text #f)
                         ;; TWO COLUMNS OF NAME AND NUMBER.
                         (element <gtk-box> #:orientation 'horizontal #:class "battery-stats"
                                  (stat-column
                                   (list (detail-row "Health" (pct (battery-health)))
                                         (detail-row "Cycles" (let ((c (battery-cycles)))
                                                                (and c (format #f "~a" c))))
                                         (detail-row "Design" (wh (battery-design-energy)))))
                                  (stat-column
                                   (list (detail-row "Draw" (watts (battery-energy-rate)))
                                         (detail-row "Voltage" (volts (battery-voltage)))
                                         (detail-row "Temperature" (deg (battery-temperature))))))
                         ;; THE PROFILES, at the bottom.
                         (profile-buttons w))
                #f)
    content))

(define (refresh-battery-panel! w)
  (when (battery-panel-content w)
    (catch #t (lambda () (build-battery-content! w)) (lambda args #f)))
  #t)

(define-method (widget-show! (w <battery-panel-desktop-widget>))
  "Rebuilt before it is shown: the details are file reads taken when the menu
opens, not live properties, so the menu is as fresh as the moment it appeared."
  (refresh-battery-panel! w)
  (next-method))

(define-method (widget-window-name (w <battery-panel-desktop-widget>)) "battery-panel")

(define-method (widget-window (w <battery-panel-desktop-widget>))
  "The battery menu, built once and shown many times."
  (unless (battery-panel-window w)
    (let ((content (element <gtk-box> #:orientation 'vertical #:class "battery-root")))
      (battery-panel-content-set! w content)
      (refresh-battery-panel! w)
      (battery-panel-window-set!
       w
       (popup-window (widget-window-name w)
                     #:position (bar-popup-position #:horizontal 'right)
                     content))
      ;; AND IT FOLLOWS THE DAEMON WHILE IT IS OPEN.  The profile can be changed
      ;; from another shell -- Omarchy has a panel for it -- and a menu that goes
      ;; on highlighting the old one is wrong about which profile is in force.
      ;; The accessor is watched for the CHANGE, not for its value: the answer is
      ;; a string and this module speaks symbols, and a rebuild re-reads it.
      (let ((live (power-profile-live)))
        (create-effect
         (lambda () (live) (refresh-battery-panel! w))
         #:immediate #f))))
  (battery-panel-window w))
