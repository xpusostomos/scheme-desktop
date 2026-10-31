;;; (scheme-desktop widgets network model) -- what the wifi list is made of
;;;
;;; PORTED FROM Omarchy's `shell/plugins/panels/network/Model.js', which is
;;; exactly this: the pure half of the network panel, split out from the QML so
;;; it can be tested without a screen. Omarchy keeps the split because its
;;; Model.js has Node tests; the same split is worth having here for the same
;;; reason, and it keeps the window module about widgets.
;;;
;;; NOTHING IN HERE TOUCHES GTK. Everything is a record or a glyph in, a record
;;; or a glyph out, which is what makes the list rules -- the sort order, where
;;; the section headings fall -- readable in one place instead of being spread
;;; through the tree that draws them.

(define-module (scheme-desktop widgets network model)
  #:use-module (scheme-toolkit service-helpers)
  #:use-module (scheme-toolkit services network)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:use-module (ice-9 format)
  #:export (wifi-signal-icon connection-icon
            <wifi-row> wifi-row? wifi-row-ssid wifi-row-signal
            wifi-row-connected? wifi-row-known? wifi-row-secured? wifi-row-ap
            row-ssid-display
            wifi-rows sort-wifi-rows
            wifi-section-title section-title-known section-title-other
            requires-credentials? can-forget?
            hidden-ssid-label
            glyph-lock glyph-forget glyph-wifi-off glyph-ethernet
            glyph-wifi-restricted))

;;; ---------------------------------------------------------------------------
;;; Glyphs
;;; ---------------------------------------------------------------------------
;;
;; The five signal steps are Omarchy's, and so is the way the step is chosen:
;; `Math.ceil(strength / 20) - 1', clamped to 0..4. NOT a divide into fifths --
;; 1..20% is the first glyph, not 0..19%.
;;
;; These are Nerd Font private-use codepoints. The shell's font stack is Sans,
;; which does not have them, so Pango falls through fontconfig to
;; JetBrainsMono Nerd Font -- verified with pango-view, not assumed.

(define (glyph codepoint)
  "The character at CODEPOINT, as a string.

WRITTEN THIS WAY BECAUSE THE OBVIOUS WAY IS WRONG.  A Nerd Font glyph looks like
`\\U000F092F`, and in Guile that reads as the SIX-digit hex escape U+0F09 -- a
Tibetan mark that looks like a squiggle -- followed by the ordinary text `2F'.  So
every icon in this file was two characters of noise: the wifi panel showed the
squiggle and the hex digits beside every network name, and the lock at the end of
each row was `3E'.  `(integer->char ...)' cannot be misread.

Checked with `(map char->integer (string->list s))' rather than by eye, which is
how it was found."
  (string (integer->char codepoint)))

(define %signal-icons (list (glyph #x0F092F)   ; 0-20%
                             (glyph #x0F091F)   ; 21-40%
                             (glyph #x0F0922)   ; 41-60%
                             (glyph #x0F0925)   ; 61-80%
                             (glyph #x0F0928))) ; 81-100%

;; Portal or limited connectivity -- associated, but the internet is not there.
(define glyph-wifi-restricted (glyph #x0F0929))
(define %wifi-off        (glyph #x0F092E))
(define glyph-ethernet    (glyph #x0F0200))
(define %ethernet-restricted (glyph #x0F0202))

(define glyph-lock   (glyph #x0F033E))
(define glyph-forget (glyph #x0F0159))
(define glyph-wifi-off %wifi-off)

(define (wifi-signal-icon strength)
  "The signal glyph for STRENGTH, a percentage.

A strength that is not a number is the FIRST glyph rather than an error: an
access point that has not been measured yet is indistinguishable from a weak
one, and the reference does the same."
  (let* ((s (if (number? strength) strength 0))
         (index (max 0 (min 4 (- (inexact->exact (ceiling (/ s 20))) 1)))))
    (list-ref %signal-icons index)))

(define (connection-icon kind strength restricted?)
  "The glyph for the CONNECTION AS A WHOLE.

KIND is 'wifi, 'ethernet or 'disconnected. RESTRICTED? is portal or limited
connectivity, and it overrides the signal bars: bars that say the link is fine
while the internet is behind a login page are worse than no bars."
  (case kind
    ((wifi) (if restricted? glyph-wifi-restricted (wifi-signal-icon strength)))
    ((ethernet) (if restricted? %ethernet-restricted glyph-ethernet))
    (else %wifi-off)))

;;; ---------------------------------------------------------------------------
;;; A row
;;; ---------------------------------------------------------------------------

(define-record-type <wifi-row>
  (make-wifi-row ssid signal connected? known? secured? ap)
  wifi-row?
  ;; The SSID, or "" for a hidden network.
  (ssid       wifi-row-ssid)
  ;; Signal strength, 0-100.
  (signal     wifi-row-signal)
  ;; Is this the network in use?
  (connected? wifi-row-connected?)
  ;; Is there a saved connection profile for it?
  (known?     wifi-row-known?)
  ;; Does it ask for a password? (The access point's own `requires-password'.)
  (secured?   wifi-row-secured?)
  ;; The Astal access point, so a click can connect to it. #f for a synthetic
  ;; row, which is what a hidden network with no access point would be.
  (ap         wifi-row-ap))

(define (hidden-ssid-label) "Hidden")

(define (row-ssid-display row)
  "The SSID to show, which is the word Hidden when there is not one.

An access point with no SSID is a network that has been told not to broadcast
it. Showing an empty line makes it look like a rendering bug; showing nothing at
all hides a network the user may be looking for."
  (let ((ssid (wifi-row-ssid row)))
    (if (string=? ssid "") (hidden-ssid-label) ssid)))

(define (requires-credentials? row)
  "Whether this network needs a password we do not have.

TRUE FOR A KNOWN NETWORK TOO, and that is deliberate: the question the panel
asks is whether to OPEN A PROMPT, and a saved profile answers it with its stored
password instead. `can-forget?' is the predicate that cares about `known?'."
  (and (wifi-row-secured? row) #t))

(define (can-forget? row)
  "A known network that is not the one in use can be forgotten.

Not the connected one: forgetting the profile you are using is a disconnect with
extra steps, and the row already offers that."
  (and (wifi-row-known? row) (not (wifi-row-connected? row)) #t))

;;; ---------------------------------------------------------------------------
;;; The list
;;; ---------------------------------------------------------------------------

(define (access-point->row ap active known)
  "AP as a <wifi-row>, given the ACTIVE access point and the KNOWN ssid list."
  (let ((ssid (or (access-point-ref ap 'ssid) "")))
    (make-wifi-row ssid
                   (or (access-point-ref ap 'strength) 0)
                   (and active (eq? ap active))
                   (and (not (string=? ssid "")) (member ssid known) #t)
                   (and (access-point-ref ap 'requires-password) #t)
                   ap)))

(define (best-per-ssid rows)
  "One row per SSID: the connected one if there is one, else the strongest.

A RADIO IS NOT A NETWORK. NetworkManager reports one access point per radio, so
a router with a 2.4GHz and a 5GHz radio, and a mesh of four nodes, are four
access points that a person thinks of as one network -- and Omarchy's list is
one row per SSID because Quickshell's `wifiNetworks' is already grouped that
way. Astal's is not, so the grouping happens here.

Hidden networks all share the empty SSID and therefore collapse to a single
Hidden row, which is what the reference does as well.

Sorting before `delete-duplicates' is what picks the survivor: the sort puts the
connected row first within its group and the strongest first otherwise, and
`delete-duplicates' keeps the first of each group."
  (delete-duplicates
   (sort rows
         (lambda (a b)
           (cond ((and (wifi-row-connected? a) (not (wifi-row-connected? b))) #t)
                 ((and (wifi-row-connected? b) (not (wifi-row-connected? a))) #f)
                 (else (> (wifi-row-signal a) (wifi-row-signal b))))))
   (lambda (a b) (string=? (wifi-row-ssid a) (wifi-row-ssid b)))))

(define (wifi-rows)
  "Every network the wifi device can see, as a sorted list of <wifi-row>.

ONE `nmcli' CALL FOR THE WHOLE LIST, not one per access point: `known-wifi-ssids'
is what tells a row whether it has a saved profile, and asking it per row would
spawn a process per row. See (scheme-toolkit services network) for why the answer does not
come from `AccessPoint.get_connections'."
  (let ((known (known-wifi-ssids))
        (active (wifi-active-access-point)))
    (sort-wifi-rows
     (best-per-ssid
      (filter-map (lambda (ap) (and ap (access-point->row ap active known)))
                  (wifi-access-points))))))

(define (sort-wifi-rows rows)
  "ROWS ordered the way the panel shows them.

  connected first, then known, then strongest first.

The order is Omarchy's `sortWifiRows' and the reason it is a separate procedure
is that the section headings are DERIVED from it: KNOWN NETWORKS is the run of
rows where `known?' is true, and the run only exists because the sort put them
together."
  (sort rows
        (lambda (a b)
          (cond ((and (wifi-row-connected? a) (not (wifi-row-connected? b))) #t)
                ((and (wifi-row-connected? b) (not (wifi-row-connected? a))) #f)
                ((and (wifi-row-known? a) (not (wifi-row-known? b))) #t)
                ((and (wifi-row-known? b) (not (wifi-row-known? a))) #f)
                (else (> (wifi-row-signal a) (wifi-row-signal b)))))))

;; The two heading strings, as symbols: which heading a row gets is a fact about
;; the list, and the words are a presentation decision the window makes.
(define section-title-known 'known)
(define section-title-other 'other)

(define (wifi-section-title rows index)
  "Which heading belongs ABOVE ROWS[INDEX], or #f for none.

The heading is emitted on the first row of each run, so it is a property of the
position in the sorted list and not of the row: the same network shows a heading
or not depending on whether anything stronger is above it."
  (if (or (< index 0) (>= index (length rows)))
      #f
      (let ((row (list-ref rows index))
            (previous (and (> index 0) (list-ref rows (- index 1)))))
        (cond ((and (wifi-row-known? row) (= index 0)) section-title-known)
              ((and (not (wifi-row-known? row))
                    (or (= index 0) (and previous (wifi-row-known? previous))))
               section-title-other)
              (else #f)))))
