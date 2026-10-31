;;; (scheme-desktop widgets audio) -- the audio panel, and the bar's audio item
;;;
;;; OMARCHY'S AUDIO PANEL (`plugins/panels/audio/`) for the layout, with the
;;; now-playing block from AGS2-SHELL (`QuickSettings/components/MediaPlayer.tsx`)
;;; at the bottom.  The sketch this was built to:
;;;
;;;   glyph  Audio            [switch]      hero: what the radio is doing
;;;   Muted                                 the state, under the title
;;;   ------------------------------------
;;;   output                   85%
;;;   ================================      the volume, full width
;;;   <device rows>                         the sinks, click to switch
;;;   ------------------------------------
;;;   input                    20%
;;;   ================================      the microphone
;;;   <device rows>
;;;   ------------------------------------
;;;   [art]  Title            [app icon]    now playing: a GdkTexture, the
;;;          author                         title and artist, how far through,
;;;          ==----  0:00  [pause]  8:40     the elapsed and total, one button
;;;
;;; NO INPUT LEVEL METER.  Omarchy draws one under the microphone bar; it comes
;;; from pipewire's own level monitoring, and AstalWp exposes no level or peak
;;; property at all (checked across Audio, Channel, Device, Endpoint, Node, Route,
;;; Stream and Wp).  Rather than draw a bar that would never move, it is left out
;;; -- by the user's call as much as by the API's.
;;;
;;; WHAT CARRIES OVER FROM THE BLUETOOTH PANEL, because both were bugs there:
;;;
;;;   - THE ROWS ARE BOUND TO THE SERVICE, not built from a snapshot of it.  A
;;;     volume change, a mute, or the default moving from one sink to another
;;;     updates the row IN PLACE, so the panel never needs rebuilding after it is
;;;     visible -- which is also what stops it changing size on screen.
;;;   - THE PANEL IS REBUILT BEFORE IT IS SHOWN.  `widget-show!' does that (see
;;;     the note at `widget-toggle!' in (scheme-toolkit app)); an earlier version
;;;     rebuilt on `notify::visible' instead, so the panel was watched emptying
;;;     and refilling.
;;;
;;; AND THE WATCHER WATCHES FOR THE RIGHT THING.  AstalWp's `Audio' emits
;;; `speaker-added' / `speaker-removed' and their microphone and device
;;; counterparts -- NOT a change of volume or of which sink is default.  Those
;;; are `notify::' on the endpoint, which is what the rows bind to.

(define-module (scheme-desktop widgets audio)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit style)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit service-helpers)
  ;; `interval' and `timer-cancel', for the now-playing clock.  The calendar's
  ;; uptime column takes the same route.
  #:use-module (scheme-toolkit time)
  #:use-module (scheme-toolkit services wireplumber)
  #:use-module (scheme-toolkit services mpris)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (ice-9 format)
  ;; `uri-decode', for turning an artUrl's percent-escapes back into a path.
  ;; ITS ABSENCE IS WHY THERE WAS NO ARTWORK: it sat inside the `catch' that
  ;; guards the texture load, so "Unbound variable" became "no picture" with no
  ;; error anywhere -- the same trap as the rfkill calls in the bluetooth
  ;; service.  `check-unbound' did not flag it, which is worth a look.
  #:use-module (web uri)

  #:export (<audio-desktop-widget> <audio-panel-desktop-widget> audio-glyph))

(define-gi-imports "Gtk" "Box" "CenterBox" "Label" "Button" "Switch" "Image" "Scale"
  "Adjustment" "Range" "ProgressBar")
(define-gi-imports "Gdk" "Texture")

;;; ---------------------------------------------------------------------------
;;; Glyphs
;;; ---------------------------------------------------------------------------
;;
;; WRITTEN WITH `integer->char', never a "\U..." literal -- that escape is not a
;; Unicode escape in Guile, it reads as six digits plus leftover text, and the
;; wifi panel's icons were two characters of noise per entry until it was caught.
;; Read out of Omarchy's Model.js and Panel.qml with `ord'.

(define (glyph codepoint) (string (integer->char codepoint)))

(define %icon-muted (glyph #x0EEE8))     ; Omarchy's off/none glyph
;; The fallback when there is no level to show at all, and the two transport
;; glyphs.  These three were left dangling when the level set replaced the old
;; table -- `Unbound variable: %icon-pause' at panel build time, which is the
;; kind of thing `check-unbound' reports and a restart does not.
(define %icon-volume (glyph #x0F028))
(define %icon-play (glyph #x0F040A))
(define %icon-pause (glyph #x0F03E4))
(define %icon-low (glyph #x0F026))
(define %icon-medium (glyph #x0F027))
(define %icon-high (glyph #x0F028))
(define %icon-headphones (glyph #x0F02CB))
(define %icon-bluetooth (glyph #x0F00AF))
(define %icon-display (glyph #x0F0379))

;; OMARCHY'S OWN RULE, from its `outputIcon' -- and the codepoints are read out
;; of its Panel.qml rather than remembered, which is why they are these and not
;; the Material Design speaker set: Omarchy's comment says those "render
;; visually smaller in JetBrainsMono Nerd Font", so it uses the Waybar pulseaudio
;; glyph set instead.
(define (audio-glyph muted? volume)
  "The speaker glyph for a level: OFF, LOW, MEDIUM or HIGH."
  (let ((v (if (number? volume) volume 0)))
    (cond (muted? %icon-muted)
          ((<= v 0.0) %icon-muted)
          ((>= v 0.67) %icon-high)
          ((>= v 0.34) %icon-medium)
          (else %icon-low))))

(define (device-glyph label)
  "A glyph for what a device IS, from Omarchy's `sinkGlyph' order.

It tests headphones first, then the words in the description, which is why the
rows for an HDMI output and for a Bluetooth headset do not look the same."
  (let ((text (string-downcase (or label ""))))
    (cond ((or (string-contains text "headphone") (string-contains text "headset")
               (string-contains text "buds")) %icon-headphones)
          ((string-contains text "bluetooth") %icon-bluetooth)
          ((or (string-contains text "hdmi") (string-contains text "display")) %icon-display)
          (else %icon-high))))

(define (percent v)
  (if (number? v) (format #f "~a%" (inexact->exact (round (* 100 v)))) ""))

;;; ---------------------------------------------------------------------------
;;; Small shared pieces
;;; ---------------------------------------------------------------------------

(define (section-head name value)
  "`output' on the left, the percentage on the right."
  (element <gtk-box> #:orientation 'horizontal #:class "audio-head"
           (element <gtk-label> #:class "audio-head-name" #:label name
                    #:xalign 0.0 #:hexpand #t)
           (element <gtk-label> #:class "audio-head-value" #:label value
                    #:xalign 1.0)))

(define (endpoint-slider ep)
  "A slider over EP's volume, across the whole card.

IT IS A CONTROL, NOT A READOUT.  Omarchy's own panel draws the level as a
`PanelLevelBar' with a MouseArea that seeks on click and drag; a
`GtkProgressBar' here would look the same and do nothing, which is the
difference between a picture of a volume and a volume.

BOUND IN BOTH DIRECTIONS: its value is set from the endpoint on every notify
(so a volume key or another shell moves the slider), and a drag writes the
endpoint's volume (so the slider moves the sound).  A scale built from one
reading of the endpoint shows a stale level for ever -- the snapshot bug the old
volume bar item had.

TWO SILENT FAILURES ARE AVOIDED HERE, both measured on this machine:

  1. A `GtkScale' built with NO ADJUSTMENT gets one with the range [0, 0], so
     it cannot hold a value at all -- every read answers 0.0 and every write is
     clamped away.  Hence the explicit adjustment below.

  2. `#:value' ON A GtkAdjustment CONSTRUCTOR IS IGNORED.  `(make
     <gtk-adjustment> #:value 42.0 ...)' reads back 0.0.  The value has to be
     set with `slot-set!' after construction, or the slider opens at zero every
     time the panel is rebuilt while the percentage beside it is correct -- which
     is precisely what was reported.

The scale is 0-100 and the endpoint is 0.0-1.0, so the conversion lives here
rather than at every call site."
  (let* ((level (* 100.0 (or (endpoint-volume ep) 0.0)))
         (adjustment (make <gtk-adjustment>
                           #:lower 0.0 #:upper 100.0
                           #:step-increment 5.0 #:page-increment 10.0))
         (scale (element <gtk-scale>
                         #:class "audio-bar"
                         #:orientation 'horizontal
                         #:draw-value #f
                         #:hexpand #t
                         #:digits 0
                         #:adjustment adjustment)))
    ;; THE VALUE GOES IN AFTER CONSTRUCTION -- see (2) above.
    (slot-set! adjustment 'value level)
    ;; THE USER DRAGGING IT.  `value-changed' fires for programmatic sets too,
    ;; so the endpoint is written only when the value really moved; that is also
    ;; what stops the two directions pushing each other in a loop.
    (connect-signal! scale "value-changed"
                     (lambda (s)
                       (let ((want (/ (get-value s) 100.0)))
                         (unless (and (number? (endpoint-volume ep))
                                      (< (abs (- want (endpoint-volume ep))) 0.001))
                           (endpoint-set-volume! ep want)))))
    ;; AND THE ENDPOINT MOVING THE SLIDER: `notify::volume' is what a volume key
    ;; produces, and without it the slider keeps whatever level it was built at.
    (catch #t
      (lambda ()
        (connect-signal! ep "notify::volume"
                         (lambda (obj prop)
                           (let ((v (* 100.0 (or (endpoint-volume ep) 0.0))))
                             (unless (< (abs (- v (get-value scale))) 0.5)
                               (set-value scale v))))))
      (lambda args #f))
    scale))

(define (endpoint-row ep current?)
  "One sink or source: its name, marked when it is the one in use.

ONE LINE, AND THE CARD IN THE TOOLTIP.  The row used to carry two lines -- the
endpoint and the card it belongs to -- and since PipeWire builds the endpoint's
description by prefixing the card's name, the two read as the same words twice.
The card is still worth having, so it moved to the tooltip rather than being
dropped.

THE TOOLTIP CARRIES THE CARD AND NOTHING ELSE.  It used to repeat the row's own
label, which tells a person nothing they cannot already see, and it used to
carry the endpoint's `route' -- WHICH IS NOT THE ENDPOINT'S ROUTE.  AstalWp's
`astal_wp_endpoint_get_route_id' delegates to the DEVICE
(lib/wireplumber/src/endpoint.c):

    return is_speaker ? astal_wp_device_get_output_route_id(dev)
                      : astal_wp_device_get_input_route_id(dev);

so every sink on a card reports the card's ACTIVE port, whatever its own is.
Measured here: all three Renoir HDMI/DisplayPort sinks report \"HDMI / DisplayPort
2 Output\", which is how a row labelled \"HDMI / DisplayPort 3 Output\" came to
have a tooltip saying \"DisplayPort 2\" -- and it was not a stale tooltip or a
wrong row, it was the device's port, identical on its three siblings.  The port
is already in the label; the card is the part that is not, so the card is what
the tooltip holds.

CLICKING MAKES IT THE DEFAULT, which is a plain property write -- `is-default' is
writable, so there is no subprocess and no `wpctl'."
  (let ((label (endpoint-label ep))
        (card (endpoint-device-label ep)))
    (element <gtk-button>
             #:class (if current? "audio-device current" "audio-device")
             ;; The tooltip is where the second line went: which card.
             #:tooltip-text (if (and (string? card) (not (string-null? card))) card "")
             #:on-clicked (lambda (b) (endpoint-set-default! ep))
             (element <gtk-label> #:class "audio-device-name"
                      #:label label #:xalign 0.0 #:ellipsize 'end
                      ;; MAX-WIDTH-CHARS FOR THE SAME REASON AS THE MEDIA TITLE,
                      ;; and this one was the WORST offender: a device label is a
                      ;; long string ("HDMI / DisplayPort 2 Output [Q16NB]
                      ;; (Stereo)"), and `ellipsize' alone leaves the label
                      ;; reporting its full natural width -- MEASURED at 409px,
                      ;; the widest child in the panel and therefore what sized
                      ;; the whole thing.  A clamp here is what lets the panel
                      ;; hold its configured width no matter what is plugged in.
                      #:max-width-chars 30
                      #:hexpand #t))))

(define (sorted-endpoints endpoints)
  "ENDPOINTS by name, because PipeWire's order is an enumeration order.

Asked for, and answered from measurement rather than guessed: `audio-speakers'
on this machine returns, in this order,

    HDMI / DisplayPort 3 Output (Stereo)
    HDMI / DisplayPort 1 Output (Stereo)
    HDMI / DisplayPort 2 Output [Q16NB] (Stereo)
    Speaker

which is the order WirePlumber created the nodes in.  It is stable -- the rows
do not shuffle between two openings -- but it is not an order anyone can use, so
the panel sorts the rows by their LABEL and leaves `audio-speakers' itself
faithful to the service.  The toolkit reports what WirePlumber says; which of
those a person reads first is this shell's decision."
  (sort endpoints (lambda (a b) (string<? (endpoint-label a) (endpoint-label b)))))

(define (device-list endpoints)
  "The rows for a set of endpoints, or nothing when there are none.

THE EMPTY CASE IS SILENT, not a row saying \"no devices\": a section with nothing
in it is a section that should not be there, and that is the rule everywhere in
this bar."
  (if (null? endpoints)
      (element <gtk-box> #:visible #f)
      (apply element <gtk-box> #:orientation 'vertical #:class "audio-devices"
             (map (lambda (ep) (endpoint-row ep (endpoint-default? ep))) endpoints))))

;;; ---------------------------------------------------------------------------
;;; The hero: glyph, title, state, and the mute switch
;;; ---------------------------------------------------------------------------

(define (speaker-state muted? volume)
  (cond (muted? "Muted")
        ((and (number? volume) (<= volume 0.001)) "Silenced")
        (else "")))

(define (hero)
  "The two the panel is about -- output and input -- with one switch.

THE SWITCH MUTES THE DEFAULT SINK, and its state is the sink's own `mute'.  It is
the only control in the hero for the same reason the bluetooth panel's is: the
status text is status, the switch is the action."
  (let ((muted (speaker-muted?))
        (volume (speaker-volume)))
    (element <gtk-box> #:orientation 'horizontal #:class "audio-hero"
             (element <gtk-label> #:class "audio-hero-icon"
                      #:label (create-computed
                               (lambda () (audio-glyph (muted) (volume)))
                               'audio-hero-icon))
             (element <gtk-box> #:orientation 'vertical #:class "audio-hero-labels"
                      #:hexpand #t #:halign 'start
                      (element <gtk-label> #:class "audio-hero-title"
                               #:label "Audio" #:halign 'start)
                      (element <gtk-label> #:class "audio-hero-meta"
                               #:label (create-computed
                                        (lambda () (speaker-state (muted) (volume)))
                                        'audio-hero-meta)
                               #:halign 'start #:ellipsize 'end #:max-width-chars 30))
             (element <gtk-switch> #:class "audio-switch"
                      ;; BOUND, SO IT FOLLOWS THE SINK.  `#:active' is an
                      ;; accessor, so a mute from a keybinding -- or from
                      ;; Omarchy's own panel -- moves the switch.
                      #:active (create-computed
                               (lambda () (not ((speaker-muted?)))))
                      #:valign 'center
                      #:on-notify-active
                      (lambda (s p)
                        ;; THE ACCESSOR HAS TO BE CALLED.  It was written
                        ;; `(speaker-muted?)' -- the accessor itself, which is a
                        ;; procedure and therefore always true -- so the switch
                        ;; read "muted" whatever the sink said, and this
                        ;; comparison was only ever true in one direction, which
                        ;; is why turning the audio ON did nothing at all.
                        (let* ((want (and (slot-ref s 'active) #t))
                               (muted-now (and ((speaker-muted?)) #t))
                               (want-muted (not want)))
                          (unless (eq? want-muted muted-now)
                            (endpoint-set-muted! (audio-default-speaker)
                                                 want-muted))))))))

(define (clock seconds)
  "Seconds as m:ss or h:mm:ss -- ags2-shell's `format_clock'."
  (if (not (number? seconds))
      "0:00"
      (let* ((total (max 0 (inexact->exact (floor seconds))))
             (h (quotient total 3600))
             (m (quotient (remainder total 3600) 60))
             (s (remainder total 60)))
        (if (> h 0)
            (format #f "~a:~2,'0d:~2,'0d" h m s)
            (format #f "~a:~2,'0d" m s)))))

(define (art-texture url)
  "URL as a GdkTexture, or #f.

AGS2-SHELL DOES THIS WITH `Gdk.Texture.new_from_file' (see its
`create_texture_accessor').  THE ONLY ACCESSIBLE ROUTE TO THAT HERE.  (Measured,
which is worth recording because the obvious call is the one that fails:
`gdk-texture-new-from-file' raises a goops error, and `GdkTexture.new_for_pixbuf'
-- the documented way -- is not reachable either, because its class is not
importable by name.  What does work is the pixbuf CONSTRUCTOR, which G-Golf binds
as a plain function, plus `gdk-texture-new-for-pixbuf', which IS importable once
the Texture class is.)

An `artUrl' is a file URI, so it is turned into a path first.  Every step is
caught: a player may publish an art URL whose file has gone, and a now-playing
block that dies over a missing thumbnail takes the shell with it."
  (and url
       (string? url)
       (not (string-null? url))
       (catch #t
         (lambda ()
           (let* ((path (if (string-prefix? "file://" url)
                            (uri-decode (substring url 7))
                            url))
                  (pixbuf (gdk-pixbuf-new-from-file path)))
             (and pixbuf (gdk-texture-new-for-pixbuf pixbuf))))
         (lambda args #f))))

(define (panel-open? w)
  "Is W's panel window on screen?  Read through `widget-slot-ref' rather than
`audio-panel-window' so this can be defined above the widget class that owns the
slot.

WHY IT IS ASKED AT ALL: the tick below is a clock, and a clock that keeps
ticking on a hidden panel is a wakeup nobody asked for.  The panel's tree is
built on every open and disposed on the next one, so the timer's whole life is
inside that tree -- but the tree outlives the visit, so the test is what stops a
closed panel polling once a second."
  (let ((win (catch #t (lambda () ((widget-slot-ref w 'window))) (lambda args #f))))
    (and win (catch #t (lambda () (slot-ref win 'visible)) (lambda args #f)))))

(define (now-playing w)
  "The block at the bottom: art, title, author, progress, elapsed, one button.

IT IS ABSENT WHEN NOTHING IS PLAYING, and absent means the whole box is
invisible rather than empty -- the same rule as every other service-backed
section in this shell.

THE TITLE, ARTIST AND POSITION ARE RE-READ WHEN THE PLAYER CHANGES, and a change
of track re-reads the art too, which is the part that is easy to get wrong: the
thumbnail belongs to the track, not to the player, so a texture fetched once and
kept would show the previous video's artwork forever.  The last-seen track is
compared on every update, and the image is replaced only when it differs.

AND THE READOUTS ALSO HAVE A CLOCK OF THEIR OWN -- see the note at the timer
below, which is what makes the numbers right on the FIRST open rather than only
after something else pokes the player.

W is the panel widget, passed only so the timer can ask whether the panel is on
screen."
  (let* ((watch (mpris-players-watch))
         ;; The widgets exist either way; visibility is what changes, so the
         ;; block does not appear and disappear underneath the pointer.
         (art (element <gtk-image> #:class "audio-art" #:pixel-size 104
                       #:valign 'start))
         ;; THE TITLE IS CLAMPED, AND THAT IS WHAT STOPS THE PANEL RESIZING.
         ;;
         ;; `ellipsize' alone does NOT cap a label's natural width: the label
         ;; still reports the full string as its preferred size, and the panel
         ;; that holds it grows to fit -- MEASURED, with a long video title:
         ;; title 385px inside a 380px request, panel box 530px.  So every new
         ;; track resized the whole panel by however long its title happened to
         ;; be, which is exactly what was reported.  `max-width-chars' is what
         ;; puts a ceiling on the request, and only then does `ellipsize' have
         ;; something to ellipsize.  The artist and the hero's meta line already
         ;; had one; the title is the one that needed it and was missed.
         ;;
         ;; 34 CHARS, chosen against the panel's own default width: the title
         ;; shares its row with the app icon and sits beside 104px of artwork, so
         ;; this leaves the row comfortably inside 380 at the default font size.
         (title (element <gtk-label> #:class "audio-media-title"
                         #:label "" #:xalign 0.0 #:ellipsize 'end
                         #:max-width-chars 34
                         #:hexpand #t))
         ;; THE APP ICON IS NOT SYMBOLIC, so it keeps Firefox's own colours.
         ;; "-symbolic" asks the theme for a monochrome recolour, which is what
         ;; made it come out flat -- Omarchy's own rows use the plain name.
         (icon (element <gtk-image> #:class "audio-media-app" #:pixel-size 20
                        #:valign 'center))
         ;; THE ARTIST IS A BINDING OF ITS OWN NOW, because it has to be SET:
         ;; the effect below writes each label, and the artist was built inline
         ;; inside the box, so there was nothing to write to -- which is why the
         ;; line under the title came out empty.
         (artist (element <gtk-label> #:class "audio-media-artist"
                          #:label "" #:xalign 0.0 #:ellipsize 'end
                          ;; Clamped like the title above it -- see the note
                          ;; there.  An artist string can be a whole list of
                          ;; names and would otherwise widen the panel for as
                          ;; long as that track is playing.
                          #:max-width-chars 34))
         (elapsed (element <gtk-label> #:class "audio-media-elapsed"
                           #:label "0:00" #:xalign 0.0))
         (total (element <gtk-label> #:class "audio-media-total"
                         #:label "0:00" #:xalign 1.0))
         (bar (element <gtk-progress-bar> #:class "audio-media-bar"
                       #:fraction 0.0 #:show-text #f #:hexpand #t))
         (button (element <gtk-button> #:class "audio-media-button"
                          #:label %icon-pause
                          #:valign 'center
                          #:on-clicked
                          (lambda (b)
                            (let ((p (mpris-active-player)))
                              (when p (player-toggle! p))))))
         ;; AGS2-SHELL'S TREE: art on the left, then a column with the title and
         ;; the app icon, the artist under it, and the progress line ACROSS THE
         ;; WHOLE WIDTH beneath both -- `elapsed [bar] button total`.
         ;;
         ;; THE PROGRESS LINE IS BESIDE THE PICTURE, NOT INSIDE THE TEXT COLUMN,
         ;; which is the difference between a bar that reaches the right-hand
         ;; edge and one that stops where the title does.
         (box (element <gtk-box> #:orientation 'horizontal #:class "audio-media"
                       #:visible #f
                       art
                       (element <gtk-box> #:orientation 'vertical
                                #:class "audio-media-info" #:hexpand #t
                                (element <gtk-box> #:orientation 'horizontal
                                         #:class "audio-media-head"
                                         title icon)
                                artist
                                ;; THE BAR GETS ITS OWN ROW, so it can reach
                                ;; from the artwork to the panel's edge; the
                                ;; numbers and the button sit UNDER it, with the
                                ;; button centred BETWEEN them -- a centre box,
                                ;; which is what one is for.
                                (element <gtk-box> #:orientation 'vertical
                                         #:class "audio-media-progress" #:hexpand #t
                                         bar
                                         (element <gtk-center-box>
                                                  #:class "audio-media-line"
                                                  (element <gtk-box> #:slot 'start elapsed)
                                                  (element <gtk-box> #:slot 'center button)
                                                  (element <gtk-box> #:slot 'end total)))))))
    ;; ONE EFFECT DOES THE UPDATING, driven by the watch accessor -- reading it is
    ;; what subscribes, and everything after is a plain read of a service that has
    ;; already told us it moved.
    (create-effect
     (lambda ()
       (watch)
       (let* ((p (mpris-active-player))
              (show? (and p #t))
              (track (and p (player-ref p 'trackid)))
              (url (and p (player-art-url p))))
         (slot-set! box 'visible (and show? #t))
         (when show?
           (slot-set! title 'label (player-title p))
           (slot-set! artist 'label (player-artist p))
           (slot-set! elapsed 'label (clock (player-position p)))
           (slot-set! total 'label (clock (player-length p)))
           (slot-set! bar 'fraction (player-progress p))
           (slot-set! button 'label (if (player-playing? p) %icon-pause %icon-play))
           ;; THE PLAIN NAME, NOT "-symbolic": see the note on `icon' above.
           (slot-set! icon 'icon-name
                      (let ((e (player-entry p)))
                        (if (string-null? e) "audio-x-generic" e)))))
     #:immediate #t))
    ;; THE ARTWORK, ON ITS OWN EFFECT, keyed on the URL.
    ;;
    ;; IT HAD NO DEPENDENCIES AT ALL AND THEREFORE NEVER RAN AGAIN, which is why
    ;; the thumbnail kept the previous video.  `create-effect' re-runs when
    ;; something the body READ -- as an ACCESSOR -- changes; this body called
    ;; only plain procedures (`mpris-active-player', `player-art-url'), which
    ;; record nothing, so the effect ran once at build time and then sat inert.
    ;; The URL comparison below was correct and never got the chance to matter.
    ;;
    ;; So it reads `watch' first, exactly as the effect above does.  That accessor
    ;; changes on a track change, and the URL it is keyed on is what decides
    ;; whether the picture is replaced -- the comparison stays, because the watch
    ;; also fires for position and playback-status, where the artwork must NOT be
    ;; reloaded from disk.
    ;;
    ;; THE TRACK ID IS PART OF THE KEY TOO.  A player that republishes the SAME
    ;; art URL for a new track (a podcast series, a channel avatar) would otherwise
    ;; be skipped, and its new picture -- same path, new file -- would never load.
    (let ((last-key (make-parameter 'unset)))
      (create-effect
       (lambda ()
         (watch)
         (let* ((p (mpris-active-player))
                (url (and p (player-art-url p)))
                (key (list (and p (player-ref p 'trackid)) url)))
           (unless (equal? key (last-key))
             (last-key key)
             (let ((tex (art-texture url)))
               ;; BOTH, ALWAYS.  A `GtkImage' keeps whatever paintable it was last
               ;; given, so a track with NO artwork has to have the old picture
               ;; taken away as well as hidden -- a player between tracks reports
               ;; an empty `art-url', and leaving the paintable in place is how the
               ;; previous video's thumbnail stayed on screen.  Measured: an empty
               ;; url with a live <gdk-memory-texture> still attached.
               (slot-set! art 'paintable tex)
               (slot-set! art 'visible (and tex #t))))))
       #:immediate #t))
    ;; THE READOUTS HAVE A CLOCK OF THEIR OWN, and this is the fix for the
    ;; numbers being blank on open and only appearing after a pause/play.
    ;;
    ;; THE EFFECT ABOVE WRITES THE NUMBERS FOR THE WRONG REASON.  It writes them
    ;; when something TELLS it the player moved -- a `notify::position', which
    ;; AstalMpris emits from a poll that runs once a second WHILE PLAYING and not
    ;; at all while paused (`lib/mpris/src/player.vala': `init_position_poll' and
    ;; `check_position').  So a value that moves with wall-clock time was wired to
    ;; an event that only sometimes happens:
    ;;
    ;;   - a player that has not been polled yet answers `position' -1, which
    ;;     reads on screen as 0:00 with an empty bar, and nothing corrects it
    ;;     until the next notify;
    ;;   - a PAUSED player is never polled again, so the numbers freeze at
    ;;     whatever the last poll left;
    ;;   - and the panel is rebuilt on every open, so every open is a fresh
    ;;     reading of that cache.
    ;;
    ;; The event the numbers belong to is the passage of a second, so that is what
    ;; drives them here.  `interval' (the calendar's uptime column uses the same
    ;; one) ticks once a second, WHILE THE PANEL IS OPEN -- the tree is rebuilt on
    ;; each open and disposed on the next, and `on-cleanup' is what stops the
    ;; timer with it, so a closed panel costs nothing and an open one costs a
    ;; property read.
    ;;
    ;; THE TITLE, ARTIST AND ICON COME OFF THE SAME CLOCK, and that is not
    ;; belt-and-braces -- it is the fix for a SECOND way the block went stale, in
    ;; which even the numbers were wrong (reported as: closing YouTube, reopening
    ;; it on a new video, and the block coming back showing the PREVIOUS video at
    ;; 0:00).
    ;;
    ;; The text fields had exactly one writer, the watch effect, and the watch
    ;; effect only fires when a player's own `notify::' does.  AstalMpris sets
    ;; `available = true' AFTER `sync' has filled title/artist/art_url in
    ;; (`player.vala': `on_appeared'), and only THEN emits `player-added' -- so a
    ;; watch summary built at that moment is complete.  But the effect is re-run by
    ;; EVERY watched notify, including ones that arrive while a freshly appeared
    ;; player is still half-filled, and its summary is built by reading
    ;; `mpris-active-player' afresh -- so whichever notify comes last wins.  When a
    ;; half-filled player wins, the block is left showing the last fully-known
    ;; values, which for a player that went away and came back are the PREVIOUS
    ;; video's: cached in AstalMpris, not stale in this widget, so nothing on this
    ;; side can tell the difference by looking at the objects.
    ;;
    ;; A clock the panel owns is what makes that self-correcting.  Re-reading the
    ;; fields once a second is cheap, their values compared before writing
    ;; anything, `icon-name' compared too -- assigning it unconditionally would
    ;; reload the icon every second, because GtkImage reloads on a set rather than
    ;; on a change.
    ;;
    ;; AND THE THIRD WAY, which the clock alone did NOT fix and the user reported
    ;; after it was in: starting a track while the panel is already open leaves
    ;; the block at 0:00 until a pause/play.  AstalMpris holds `length' -1 and
    ;; `position' 0.0 for a track it has not synced yet while `playback-status'
    ;; already reads `playing' -- its own poll calls check_position only WHILE
    ;; playing, and that call is what delivers the first real position and, through
    ;; the properties-changed handler, the metadata.  Until it lands there is
    ;; nothing on this side to read: a clock reading a frozen cache is still a
    ;; clock reading a frozen cache.
    ;;
    ;; `player-length' and `player-position' now fall through to the TRACK
    ;; METADATA (`mpris:length', which the player publishes with the track and
    ;; which is therefore correct at exactly that moment), so the total is right
    ;; immediately and the elapsed time stops being a confident 0:00.  That is
    ;; ags2-shell's `metadata_length', which this port had documented as
    ;; impossible until the GLib variant functions turned out to be bound.
    (letrec ((tick (lambda ()
                     (when (panel-open? w)
                       (let* ((p (mpris-active-player))
                              (title-text (and p (player-title p)))
                              (artist-text (and p (player-artist p)))
                              (icon-name (and p
                                              (let ((e (player-entry p)))
                                                (if (or (not e) (string-null? e))
                                                    "audio-x-generic"
                                                    e)))))
                         ;; THE BLOCK'S OWN VISIBILITY IS RECONCILED HERE TOO.
                         ;; Showing and hiding is the effect's job and it does it on
                         ;; the real signals, but a block whose text is repaired by
                         ;; a clock and whose visibility is not can be left showing
                         ;; a player that has gone -- so the clock covers both
                         ;; directions and the effect stays the fast path.
                         (unless (equal? (slot-ref box 'visible) (and p #t))
                           (slot-set! box 'visible (and p #t)))
                         (when p
                           (unless (equal? (slot-ref title 'label) title-text)
                             (slot-set! title 'label title-text))
                           (unless (equal? (slot-ref artist 'label) artist-text)
                             (slot-set! artist 'label artist-text))
                           (unless (equal? (slot-ref icon 'icon-name) icon-name)
                             (slot-set! icon 'icon-name icon-name))
                           (slot-set! elapsed 'label (clock (player-position p)))
                           (slot-set! total 'label (clock (player-length p)))
                           (slot-set! bar 'fraction (player-progress p))
                           (slot-set! button 'label
                                      (if (player-playing? p) %icon-pause %icon-play)))))))
             (timer (interval 1000 tick)))
      (on-cleanup (lambda () (timer-cancel timer))))
    box))

;;; ---------------------------------------------------------------------------
;;; The panel
;;; ---------------------------------------------------------------------------

(define-class <audio-panel-desktop-widget> (<popup-widget>)
  (width #:init-value 380 #:init-keyword #:width
         #:accessor audio-panel-width
         #:config '(integer 240 900) #:label "Panel width")
  (window #:init-value #f #:accessor audio-panel-window
          #:setter audio-panel-window-set!)
  (content #:init-value #f #:accessor audio-panel-content
           #:setter audio-panel-content-set!)
  ;; THE REACTIVE ROOT THE ROWS WERE BUILT IN, so a rebuild can dispose it.
  ;; Every row connects a click handler, and the old tree has to be disposed
  ;; BEFORE its widgets are removed -- disposing after destroying is what
  ;; produced "instance with invalid (NULL) class pointer" elsewhere.
  (root #:init-value #f #:accessor audio-panel-root
        #:setter audio-panel-root-set!))

(define-method (widget-window-name (w <audio-panel-desktop-widget>)) "audio")

(define (panel-room w)
  (let ((win (audio-panel-window w)))
    (or (and win (catch #t (lambda () (popup-available-height win)) (lambda args #f)))
        420)))

(define (build-audio-content! w)
  "The whole panel, top to bottom, in the sketch's order."
  (let* ((width ((widget-slot-ref w 'width)))
         (body (element <gtk-box> #:orientation 'vertical #:class "audio-panel"))
         (sink (audio-default-speaker))
         (mic (audio-default-microphone))
         (inner (element <gtk-box> #:orientation 'vertical
                         (hero)
                         ;; OUTPUT
                         (section-head "output" (percent (endpoint-volume sink)))
                         (endpoint-slider sink)
                         (device-list (sorted-endpoints (audio-speakers)))
                         ;; INPUT
                         (section-head "input" (percent (endpoint-volume mic)))
                         (endpoint-slider mic)
                         (device-list (sorted-endpoints (audio-microphones)))
                         ;; NOW PLAYING
                         (now-playing w))))
    (slot-set! body 'width-request width)
    (add-child! body inner #f)
    body))

(define (refresh-audio-panel! w)
  "Dispose the old tree, empty the box, build the new one.

THE WIDTH LIVES ON THE BOX THAT SURVIVES THE REBUILD, not on the tree inside it:
a rebuild empties the content box, and a width that lived only inside would
collapse and spring back -- which is what the bluetooth panel's flicker was."
  (let ((content (audio-panel-content w)))
    (when content
      ;; The rows built handlers and bindings inside this root, so it goes first.
      (let ((root (audio-panel-root w)))
        (when root (catch #t root (lambda args #f))))
      (audio-panel-root-set! w #f)
      (slot-set! content 'width-request ((widget-slot-ref w 'width)))
      (clear-box! content)
      (audio-panel-root-set!
       w
       (create-root
        (lambda (dispose)
          (add-child! content (build-audio-content! w) #f))))))
  #t)

(define (hook-refresh-on-show! w)
  "Rebuild when the window becomes visible.

FOR THE CLICK PATH.  `widget-toggle!' now goes through `widget-show!' so a panel
with a `widget-show!' override is rebuilt BEFORE it appears -- but this panel has
no override (it has nothing to re-read that the bindings do not handle), and the
hook is still what guarantees a fresh tree on every open.  Deferred to an idle,
because this runs inside the emission of the property it reacts to and rebuilding
a window's own children there is the destroy-inside-a-signal hazard."
  (let ((win (audio-panel-window w)))
    (when win
      (connect-signal! win "notify::visible"
                       (lambda (obj prop)
                         (when (catch #t (lambda () (slot-ref obj 'visible))
                                 (lambda args #f))
                           (g-idle-add
                            (lambda () (refresh-audio-panel! w) #f))))))))

(define-method (widget-window (w <audio-panel-desktop-widget>))
  "The audio panel, built once and shown many times."
  (unless (audio-panel-window w)
    (let ((content (element <gtk-box> #:orientation 'vertical #:class "audio-root")))
      (audio-panel-content-set! w content)
      (refresh-audio-panel! w)
      (audio-panel-window-set!
       w
       (popup-window (widget-window-name w)
                     #:position (bar-popup-position #:horizontal 'right)
                     content))
      (hook-refresh-on-show! w)))
  (audio-panel-window w))

;;; ---------------------------------------------------------------------------
;;; The bar item
;;; ---------------------------------------------------------------------------

(define-class <audio-desktop-widget> (<bar-item-widget>))

(define-method (widget-build (w <audio-desktop-widget>) output)
  "The bar's audio glyph, which opens the panel.

A DESKTOP WITH NO SINK GETS AN EMPTY BOX, as with the battery and the radio: the
item for a service the machine does not have must be absent rather than show a
plausible-looking zero.

OUTPUT is the monitor's connector name, which this widget does not use -- it
takes it because every `widget-build' does."
  ;; THE TEST IS ON THE SERVICE, NOT ON THE ENDPOINT.  `(audio-default-speaker)'
  ;; is #f for the first seconds of the shell's life -- AstalWp connects
  ;; asynchronously -- so an item that renders an invisible box when it is #f
  ;; renders an invisible box for ever, because the bar is built once.  That is
  ;; what "there's no audio widget in the bar" was.  The endpoints themselves
  ;; are followed by `speaker-volume' and `speaker-muted?', which re-subscribe
  ;; when the default sink appears.
  (if (not (wp))
      (element <gtk-box> #:class "audio" #:visible #f)
      (let* ((muted (speaker-muted?))
             (volume (speaker-volume))
             (icon (create-computed
                    (lambda () (audio-glyph (muted) (volume)))
                    'audio-glyph))
             (btn (panel-button (desktop-widget-required 'audio-panel)
                                #:align (widget-section w)
                                #:class "icon-only"
                                (element <gtk-label>
                                         #:class "audio-icon"
                                         #:label (or icon %icon-volume)
                                         #:halign 'center))))
        ;; BOTH TRACKING READS -- `(muted)' and `(volume)' -- so the glyph
        ;; follows a mute from a keybinding.  A computed built on `st-peek' has
        ;; no dependencies and is a snapshot of the moment the bar was assembled.
        (create-effect
         (lambda () (toggle-class! btn "unavailable" (and (muted) #t)))
         #:immediate #t)
        btn)))
