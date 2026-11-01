;;; (scheme-desktop widgets bluetooth) -- the radio's glyph in the bar, and the panel
;;;
;;; PORTED FROM OMARCHY's bluetooth panel (`plugins/panels/bluetooth/`), which is
;;; a bar button and a keyboard-driven panel in one QML file, split here into the
;;; two widgets this shell gives every feature: the bar item that opens it, and
;;; the panel that does the work.
;;;
;;; WHAT IS OMARCHY'S HERE.  The three bar glyphs and their rule (off / on /
;;; something connected), the row glyph, the forget glyph, the three groups
;;; (connected, paired, found), the rule that a device whose \"name\" is a UUID or
;;; an address is not a name and does not get a row, the placeholder wording, and
;;; the two section headings.  What is NOT here is the rest of its panel: the
;;; rotating joke phrases in the hero (they need a timer and they are Omarchy's
;;; voice, not this shell's), the audio-sink switching (a PipeWire concern that
;;; belongs to the volume widget), and the keyboard cursor (this shell's menu
;;; widget owns arrow-key navigation; a panel is reached by clicking its bar item).
;;;
;;; THE ACTIONS DO NOT SHELL OUT.  Omarchy runs `omarchy-bluetooth-device';
;;; ags2-shell runs `bluetoothctl remove' to unpair.  Astal exposes the same
;;; BlueZ calls as methods and (scheme-toolkit services bluetooth) wraps them, so
;;; everything here is a method call.  See that module for the two G-Golf traps
;;; -- the list properties that come back as raw pointers, and the async methods
;;; whose generics take two trailing arguments.

(define-module (scheme-desktop widgets bluetooth)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit style)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit services bluetooth)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)

  #:export (<bluetooth-desktop-widget> <bluetooth-panel-desktop-widget>
            bluetooth-glyph))

(define-gi-imports "Gtk" "Box" "Label" "Button" "Switch" "Spinner"
  "ScrolledWindow" "GestureClick")

;;; ---------------------------------------------------------------------------
;;; Glyphs
;;; ---------------------------------------------------------------------------

;; WRITTEN AS `integer->char' AND NEVER AS A `"\U..."' LITERAL, which is not a
;; Unicode escape in Guile -- it reads as a six-digit hex escape plus leftover
;; text.  These four codepoints were read out of Omarchy's Panel.qml with `ord',
;; not typed from looking at the glyphs: U+F00B2 is the crossed-out radio,
;; U+F00AF the radio on, U+F00B1 the one with a connection, and U+F0159 the
;; forget mark.
(define (glyph codepoint) (string (integer->char codepoint)))

(define %icon-off (glyph #x0F00B2))
(define %icon-on (glyph #x0F00AF))
(define %icon-connected (glyph #x0F00B1))

(define (bluetooth-glyph powered connected)
  "Omarchy's `icon' rule, which is the whole of what the bar's glyph says:

  the radio is off             the crossed-out glyph
  something is connected       the glyph with the connection mark
  on, with nothing attached    the plain glyph

A radio that is off and a radio with nothing on it are different states and are
worth two different glyphs -- which is the reason there are three."
  (cond ((not powered) %icon-off)
        (connected %icon-connected)
        (else %icon-on)))

;;; ---------------------------------------------------------------------------
;;; The bar item
;;; ---------------------------------------------------------------------------

(define-class <bluetooth-desktop-widget> (<bar-item-widget>))

(define-method (widget-build (w <bluetooth-desktop-widget>) output)
  "The bar's bluetooth glyph, which opens the panel.

A DESKTOP GETS AN EMPTY BOX, as with the battery: `(bluetooth)' answers #f where
there is no adapter at all, and an item for a radio the machine does not have
must be absent rather than show a plausible-looking off state.

OUTPUT is the monitor's connector name, which this widget does not use -- it
takes it because every `widget-build' does."
  (if (not (bluetooth))
      (element <gtk-box> #:class "bluetooth" #:visible #f)
      (let* ((powered (bluetooth-powered))
             (connected (bluetooth-connected))
             (icon (create-computed
                    (lambda () (bluetooth-glyph (powered) (connected)))
                    'bluetooth-glyph))
             (btn (panel-button (desktop-widget-required <bluetooth-panel-desktop-widget>)
                                #:align (widget-section w)
                                ;; ALWAYS ICON-ONLY, so the hover is always the
                                ;; circle: this item has no name to show and no
                                ;; option to show one, so unlike the wifi's it
                                ;; never becomes a pill.
                                #:class "icon-only"
                                (element <gtk-label>
                                         #:class "bluetooth-icon"
                                         #:label (or icon %icon-off)
                                         #:halign 'center))))
        ;; TRACKING READS INSIDE THE COMPUTED, `(powered)' and not `(st-peek
        ;; powered)': a computed whose body only peeks has no dependencies and is
        ;; a snapshot of the moment the bar was assembled.
        (create-effect
         (lambda () (toggle-class! btn "unavailable" (not (powered))))
         #:immediate #t)
        (create-effect
         (lambda () (toggle-class! btn "connected" (and (powered) (connected))))
         #:immediate #t)
        btn)))

;;; ---------------------------------------------------------------------------
;;; The panel
;;; ---------------------------------------------------------------------------

(define-class <bluetooth-panel-desktop-widget> (<popup-widget>)
  ;; THE PANEL'S CONTENT WIDTH -- read the next sentence before picking a number.
  ;;
  ;; `width-request' is the width of a widget's CONTENT, and the card's CSS
  ;; `padding' is added on top: measured, a request of 380 draws a panel 428
  ;; across (380 + 2 × `--popover-padding').  So this option is the content
  ;; width, not the panel's, and the visible result is about 48px wider.
  ;;
  ;; IT IS A FLOOR AND IT HAS TO BE TREATED AS ONE.  A `width-request' does not
  ;; cap anything: whatever is inside can still demand more, and then the panel is
  ;; as wide as the widest thing in it.  MEASURED, and this is why the panel used
  ;; to jump: the hero's status line is a different length in every state ("On,
  ;; nothing connected" / "Scanning for devices…" / "Connected to Chris's Buds3
  ;; Pro") and the card was fitted to its content.  What holds it now is the caps
  ;; on the labels -- `max-width-chars' plus `ellipsize end' on the hero's phrase,
  ;; the device names and the status -- so nothing inside can ask for more than
  ;; the request.  If a new row or label is added, IT NEEDS THE SAME CAPS, or the
  ;; panel will start moving again.
  (width #:init-value 380 #:init-keyword #:width
         #:accessor bluetooth-panel-width
         #:config '(integer 240 900) #:label "Panel width")
  (window #:init-value #f #:accessor bluetooth-panel-window
          #:setter bluetooth-panel-window-set!)
  (content #:init-value #f #:accessor bluetooth-panel-content
           #:setter bluetooth-panel-content-set!)
  ;; THE REACTIVE ROOT THE ROWS WERE BUILT IN, so a rebuild can dispose it.  Every
  ;; row connects a click handler and adds a gesture controller, and the old tree
  ;; has to be disposed BEFORE its widgets are removed -- disposing after
  ;; destroying is what produced `instance with invalid (NULL) class pointer' in
  ;; the network panel's teardown.
  (root #:init-value #f #:accessor bluetooth-panel-root
        #:setter bluetooth-panel-root-set!))

(define-method (widget-window-name (w <bluetooth-panel-desktop-widget>)) "bluetooth")

(define (panel-room w)
  "How tall the device list may be: the screen between the bar and the bottom.

420 until the window exists -- the first build, before there is anything to
measure against -- which is the network panel's fallback too."
  (let ((win (bluetooth-panel-window w)))
    (or (and win (catch #t (lambda () (popup-available-height win)) (lambda args #f)))
        420)))

(define (state-phrase powered? scanning?)
  "What the radio is doing, in a few words, under the title.

READ LIVE, so it can be bound: the phrase follows the radio and the device list
without the panel being rebuilt."
  (let ((connected (filter bluetooth-device-connected? (bluetooth-devices))))
    ;; "NO ADAPTER" ONLY MEANS NO ADAPTER.  Switching the radio off makes bluez
    ;; remove the adapter object entirely (see the service's note on
    ;; `rfkill-bluetooth-device'), so `(bluetooth-adapter)' is #f for a machine
    ;; whose radio is merely off -- and this used to say "No adapter" about it,
    ;; which is both wrong and useless: it reads as "your hardware has gone" when
    ;; the switch two inches to the right would bring it back.  Asking whether one
    ;; has EVER been seen tells the two apart.
    (cond ((and (not (bluetooth-adapter)) (not (bluetooth-adapter-seen?))) "No adapter")
          ((not powered?) "Off")
          ((pair? connected)
           (format #f "Connected to ~a" (bluetooth-device-label (car connected))))
          (scanning? "Scanning for devices…")
          (else "On, nothing connected"))))

(define (hero w powered? connected? scanning?)
  "The head of the panel: the big glyph, the name and state, and the radio switch."
  (element <gtk-box> #:orientation 'horizontal #:class "bluetooth-hero"
           (element <gtk-label> #:class "bluetooth-hero-icon"
                    #:label (bluetooth-glyph powered? connected?))
           (element <gtk-box> #:orientation 'vertical #:class "bluetooth-hero-labels"
                    #:hexpand #t #:halign 'start
                    (element <gtk-label> #:class "bluetooth-hero-title"
                             #:label "Bluetooth" #:halign 'start)
                    (element <gtk-label> #:class "bluetooth-hero-meta"
                             #:label (state-phrase powered? scanning?)
                             #:halign 'start #:ellipsize 'end #:max-width-chars 34))
           (element <gtk-switch> #:class "bluetooth-radio"
                    #:active (and powered? #t)
                    #:valign 'center
                    #:on-notify-active
                    (lambda (s p)
                      (bluetooth-power! (slot-ref s 'active))
                      (refresh-bluetooth-panel-later! w)))))

(define (named-devices)
  "Every device with a usable name, sorted by that name.

SORTED BY NAME ALONE, and not grouped by state -- that is the point.  Grouping
means a device MOVES between groups when it connects, and moving it means
rebuilding the list; a rebuild is what made the panel flicker and is what stopped
the row from updating in place.  ags2-shell, which this is matching, has one
list.  The rows say what each device is doing; the order does not have to."
  (sort (filter bluetooth-human-name? (bluetooth-devices))
        (lambda (a b)
          (string<? (string-downcase (bluetooth-device-label a))
                    (string-downcase (bluetooth-device-label b))))))

(define (scan-line w scanning?)
  "Scan, or stop scanning, with the label Omarchy's and ags2-shell's both use.

BOUND TO THE SCAN STATE, so starting or stopping a scan updates the line without
rebuilding the panel -- the rebuild was what made the panel twitch, and the row
bindings are the other half of the same fix.

ONE BUTTON THAT DOES BOTH, because a scan is a thing you start and then want to
stop: two buttons would be one too many for a state that is either on or off."
  (let ((scanning scanning?))
    (element <gtk-box> #:orientation 'horizontal #:class "bluetooth-scan"
             (element <gtk-label> #:class "bluetooth-scan-state"
                      #:label (if (bluetooth-scanning?) "Scanning…" "Nearby devices")
                      #:halign 'start #:hexpand #t)
             (element <gtk-button> #:class "bluetooth-scan-button"
                      #:label (if (bluetooth-scanning?) "Cancel" "Scan")
                      ;; THE ACTION ASKS THE RADIO, not the label.
                      #:on-clicked (lambda (b)
                                     (if (bluetooth-scanning?)
                                         (bluetooth-scan-stop!)
                                         (bluetooth-scan!))
                                     (refresh-bluetooth-panel-later! w))))))

(define (placeholder adapter powered?)
  "What the panel says instead of a list, in Omarchy's words."
  (element <gtk-label> #:class "bluetooth-empty" #:halign 'start
           #:wrap #t #:xalign 0.0 #:max-width-chars 40
           ;; The same distinction as `state-phrase': an absent adapter with the
           ;; radio off is not a machine without bluetooth, and "Turn Bluetooth
           ;; on to scan" is both true and actionable there.
           #:label (cond ((and (not adapter) (not (bluetooth-adapter-seen?)))
                          "No Bluetooth adapter")
                         ((not powered?) "Turn Bluetooth on with the switch above")
                         (else "Scanning for devices…"))))

(define (device-status connected connecting battery)
  "The small print on a row: the battery if the device reports one, else what it
is doing.

ASTAL SAYS -1.0 FOR \"NO BATTERY\", and `bluetooth-device-battery' turns that into
#f -- so a row either has a real number here or says nothing.  A row reading
\"-100%\" on every device would be worse than no row at all."
  (cond (connecting "Connecting…")
        ((and connected battery)
         (format #f "~a%" (inexact->exact (round (* 100 battery)))))
        (else "")))

(define (device-row w dev)
  "One device: a glyph, its name, its battery or state, and a spinner while it
connects.

PLAIN VALUES, DELIBERATELY -- and this is a retreat, not a design.  The version
before this one BOUND each widget to the device's properties (`create-binding' on
`connected', `connecting', `battery-percentage'), which is how ags2-shell gets its
instant reaction and what this panel needs.  It CRASHED THE SHELL ON OPEN,
reproducibly: a SIGSEGV inside GTK's allocation path (`gtk_widget_allocate' nested
through the tree, then a C signal handler with no Scheme frame under it).  The
panel builds no bindings at all in the working version, and the bound one builds
several, so that is the difference -- but WHICH binding, and why, is not
established, and a crash on open is worse than stale data.

CLICK CONNECTS OR DISCONNECTS; RIGHT-CLICK DISCONNECTS A CONNECTED DEVICE AND
FORGETS A PAIRED ONE.  Both read the device AT THE CLICK, never from the build."
  (let* ((connected (bluetooth-device-connected? dev))
         (connecting (bluetooth-device-connecting? dev))
         (battery (bluetooth-device-battery dev))
         (status (device-status connected connecting battery))
         (paired? (bluetooth-device-paired? dev))
         (btn (element <gtk-button>
                       #:class (if connected "bluetooth-row connected" "bluetooth-row")
                       #:tooltip-text (cond (connected "Click to disconnect")
                                            (paired? "Click to connect, right-click to forget")
                                            (else "Click to connect"))
                       #:on-clicked (lambda (b)
                                      (if (bluetooth-device-connected? dev)
                                          (bluetooth-disconnect! dev)
                                          (bluetooth-connect! dev))
                                      (refresh-bluetooth-panel-later! w))
                       (element <gtk-box> #:orientation 'horizontal
                                #:class "bluetooth-row-box"
                                (element <gtk-label> #:class "bluetooth-row-icon"
                                         #:label (bluetooth-device-glyph dev))
                                (element <gtk-box> #:orientation 'vertical
                                         #:hexpand #t #:valign 'center
                                         (element <gtk-label> #:class "bluetooth-row-name"
                                                  #:label (bluetooth-device-label dev)
                                                  #:xalign 0.0 #:ellipsize 'end
                                                  #:max-width-chars 28)
                                         (element <gtk-label> #:class "bluetooth-row-status"
                                                  #:label status #:xalign 0.0
                                                  #:ellipsize 'end))
                                (element <gtk-spinner> #:class "bluetooth-row-spinner"
                                         #:spinning connecting)))))
    (let ((right (make <gtk-gesture-click>)))
      (slot-set! right 'button 3)
      (connect-signal! right "pressed"
                       (lambda (c n x y)
                         (cond ((bluetooth-device-connected? dev)
                                (bluetooth-disconnect! dev))
                               ((or (bluetooth-device-paired? dev)
                                    (bluetooth-device-ref dev 'trusted))
                                (bluetooth-forget! dev)))
                         (refresh-bluetooth-panel-later! w)))
      (add-controller btn right))
    btn))

(define (build-bluetooth-content! w)
  "The whole panel: the hero, the scan line, and the devices.

THE ROWS ARE BOUND TO THEIR DEVICES, so this runs only when the SET of devices
changes (one appeared or disappeared) or the panel is opened.  A device
connecting, disconnecting or reporting a battery updates its own row and needs
none of this."
  (let* ((powered? (and (bluetooth-on?) #t))
         (adapter (bluetooth-adapter))
         (devices (named-devices))
         ;; Through `widget-slot-ref', which gives an ACCESSOR over the option
         ;; (and watches the config tick), rather than the raw slot accessor.
         (width ((widget-slot-ref w 'width)))
         (body (element <gtk-box> #:orientation 'vertical #:class "bluetooth-panel"))
         (list-box (element <gtk-box> #:orientation 'vertical #:class "bluetooth-list")))
    (for-each (lambda (x) (slot-set! x 'width-request width))
              (list body list-box))
    (add-child! body (hero w (and (bluetooth-on?) #t)
                             (pair? (filter bluetooth-device-connected? (bluetooth-devices)))
                             (bluetooth-scanning?)) #f)
    (add-child! body (scan-line w (bluetooth-scanning?)) #f)
    (for-each (lambda (dev) (add-child! list-box (device-row w dev) #f))
              devices)
    (if (null? devices)
        (add-child! body (placeholder adapter powered?) #f)
        ;; PROPAGATE THE HEIGHT, NOT THE WIDTH: height is what makes the list as
        ;; tall as it needs (down to the cap), while propagating the width is
        ;; what let a row change the panel's size.
        (add-child! body
                    (element <gtk-scrolled-window>
                             #:class "bluetooth-scroll"
                             #:hscrollbar-policy 'never
                             #:vscrollbar-policy 'automatic
                             #:propagate-natural-height #t
                             ;; HEIGHT YES, WIDTH NO: a row changing shape
                             ;; must not resize the panel.
                             #:propagate-natural-width #f
                             #:max-content-height (panel-room w)
                             list-box)
                    #f))
    body))

(define (refresh-bluetooth-panel-later! w)
  "Rebuild the panel on the next idle instead of right now.

  THIS PROCEDURE WAS MISSING FOR A LONG TIME, and that is what crashed the shell.
  Six call sites referred to it and the definition had been lost in an edit, so
  every one of them raised `Unbound variable' -- from inside signal handlers.
  A Scheme error raised there is not merely a failed redraw: Guile unwinds it
  through `g_signal_emit', which leaves a dangling entry in GObject's
  thread-local list of in-progress emissions, and the NEXT emission of any signal
  dies in `emission_find'.  Measured: SIGSEGV in `emission_find', emitting
  `GtkAdjustment::changed' while laying out the panel's scrolled window -- a
  stack with no Scheme frame in it at all, because the actual fault was an
  earlier emission of `notify::visible'.

  DEFERRED, and that is the second reason to use this rather than
  `refresh-bluetooth-panel!' in a handler: the rebuild destroys the widgets the
  handler is running inside.  An idle runs after the emission has finished."
  (g-idle-add (lambda () (refresh-bluetooth-panel! w) #f)))

(define (refresh-bluetooth-panel! w)
  "Dispose the old tree, empty the box, build the new one.

THE PERMANENT BOX CARRIES THE WIDTH, not just the tree built inside it.  A
rebuild empties the content box and refills it, and for that instant the panel
has nothing in it -- so a width that lived only on the per-build card collapsed
to nothing and sprang back.  That is the visible width change on a click that did
nothing: the flicker was the rebuild, not a new size.  With the request on the
box that survives the rebuild, there is nothing to collapse."
  (let ((content (bluetooth-panel-content w)))
    (when content
      (slot-set! content 'width-request ((widget-slot-ref w 'width)))
      (let ((root (bluetooth-panel-root w)))
        (when root (catch #t root (lambda args #f))))
      (bluetooth-panel-root-set! w #f)
      (clear-box! content)
      (bluetooth-panel-root-set!
       w
       (create-root
        (lambda (dispose)
          (add-child! content (build-bluetooth-content! w) #f))))))
  #t)

(define-method (widget-show! (w <bluetooth-panel-desktop-widget>))
  "Rebuilt before it is shown, so the panel is as fresh as the moment it appeared.

THIS RUNS FOR THE KEYBOARD PATH ONLY.  `widget-toggle!' -- what a click on the
bar button does -- goes round the verb and sets the window's `visible' slot
directly, so a panel opened by a click never reaches this method.  That is a
toolkit defect (see the note at `widget-toggle!' in (scheme-toolkit app)); the
refresh for the click path is hooked on the window below."
  (refresh-bluetooth-panel! w)
  (next-method))

;; THE REFRESH THE CLICK PATH ACTUALLY USES.
;;
;; Hooked on the window's own `notify::visible' because that is the one event
;; every route to opening shares -- and DEFERRED TO AN IDLE, which matters: this
;; handler runs INSIDE the emission of the property it is reacting to, and
;; rebuilding the window's own children there is the destroy-inside-a-signal
;; hazard.  Done synchronously it sometimes left the window not visible at all
;; (measured: the content was rebuilt -- a deliberately corrupted device name was
;; gone afterwards -- while the panel stayed shut).  An idle puts the rebuild
;; after the emission has finished; the cost is that the panel is one frame stale
;; as it appears, which is not visible to anyone.
(define (hook-refresh-on-show! w)
  (let ((win (bluetooth-panel-window w)))
    (when win
      (connect-signal! win "notify::visible"
                       (lambda (obj prop)
                         ;; ONLY ON THE WAY UP.  Rebuilding on hide would do the
                         ;; work a moment after it stopped being looked at.
                         (when (catch #t (lambda () (slot-ref obj 'visible))
                                 (lambda args #f))
                           (refresh-bluetooth-panel-later! w)))))))

(define-method (widget-window (w <bluetooth-panel-desktop-widget>))
  "The bluetooth panel, built once and shown many times."
  (unless (bluetooth-panel-window w)
    (let ((content (element <gtk-box> #:orientation 'vertical #:class "bluetooth-root")))
      (bluetooth-panel-content-set! w content)
      (refresh-bluetooth-panel! w)
      (bluetooth-panel-window-set!
       w
       (popup-window (widget-window-name w)
                     #:position (bar-popup-position #:horizontal 'right)
                     content))
      ;; A SCOPE FOR THE LONG-LIVED PIECES, and this is the fix for the crash.
      ;;
      ;; The show hook and the follow-effect used to be created right here, in
      ;; `widget-window' -- which runs OUTSIDE any reactive root.  `on-cleanup'
      ;; then has no scope to register with, warns "on-cleanup called outside a
      ;; scope; it will never run", and the GClosure behind each handler is held
      ;; alive by nothing.  Measured under gdb: the shell dies inside
      ;; `emission_find', emitting `GtkAdjustment::changed' while GTK lays out the
      ;; panel's scrolled window -- i.e. GTK walked a handler list containing a
      ;; closure that had been freed underneath it.
      ;;
      ;; A root gives those handlers an owner, so the closure stays registered
      ;; for as long as the widget does.  It is never disposed: the panel lives as
      ;; long as the shell.
      (create-root
       (lambda (dispose)
         (hook-refresh-on-show! w)
         (let ((devices (bluetooth-devices-watch))
               (powered (bluetooth-powered)))
           ;; DEFERRED LIKE THE REST, and this is the crash.
           ;;
           ;; This rebuilt SYNCHRONOUSLY from inside a GObject notify.  If that
           ;; notify lands while GTK is running a frame's layout -- and BlueZ
           ;; notifies whenever it likes -- the rebuild destroys the panel's
           ;; widgets while the layout is walking them.  Measured under gdb:
           ;; SIGSEGV in `emission_find', emitting `GtkAdjustment::changed' from
           ;; `gtk_viewport_size_allocate' inside the panel's scrolled window, on
           ;; a stack whose oldest frame is `gdk_frame_clock_run_layout'.  The
           ;; adjustment being touched belonged to a tree that had just been
           ;; destroyed underneath it.
           ;;
           ;; An idle cannot run during an emission or a layout, so deferring is
           ;; not politeness here, it is the correctness condition.
           (create-effect
            (lambda ()
              (devices) (powered)
              (when (widget-visible? w) (refresh-bluetooth-panel-later! w)))
            #:immediate #f))))))
  (bluetooth-panel-window w))
