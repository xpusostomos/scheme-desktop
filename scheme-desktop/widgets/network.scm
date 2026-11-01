;;; (scheme-desktop widgets network) -- the wifi panel, and its bar button
;;;
;;; PORTED FROM Omarchy's `shell/plugins/panels/network/Panel.qml'.  That is the
;;; reference the user asked for by name, and it is the reason this is a
;;; SEPARATE widget rather than a page of an integrated quick-settings panel:
;;; Omarchy has one panel per concern (network, audio, bluetooth, power) and
;;; ags2-shell has one panel with pages.  This shell is following Omarchy here.
;;;
;;; TWO WIDGETS, NOT ONE.  `<network-desktop-widget>' is the bar button and
;;; `<network-panel-desktop-widget>' is the window.  Neither knows about the
;;; other: the button opens the panel with `(toggle-widget 'network-panel)', which is
;;; the same call a keybinding makes, and that is what lets the panel be bound to
;;; a key and left out of the bar entirely.
;;;
;;; WHAT IS PORTED AND WHAT IS NOT.
;;;
;;;   Ported: the hero (connection glyph, network name, state line, radio
;;;   switch), the scan line, the sorted list with KNOWN NETWORKS / OTHER
;;;   NETWORKS headings, the per-row signal glyph and lock, click to connect or
;;;   disconnect, the inline passphrase prompt, and forget.
;;;
;;;   NOT ported yet, all of it needing data Astal does not carry and Omarchy
;;;   gets from `omarchy-network-status --verbose': the throughput and ping
;;;   tiles, the IP / gateway / link-speed / DNS rows, the band pills, the
;;;   captive-portal sign-in button, the QR share and the speed test.  Those are
;;;   a second pass over this same window; the window is the part worth getting
;;;   right first.
;;;
;;; THE LIST IS REBUILT, NOT BOUND.  Astal's Wifi device announces
;;; `access-point-added', `access-point-removed' and `state-changed', and those
;;; three cover everything that changes a row.  Rebuilding a dozen buttons on
;;; those events is cheaper to read than a per-row reactive binding, and it is
;;; what the workspaces widget next door already does.
;;;
;;; THE PASS-THROUGH TEXT IS THE ONE AWKWARD PART.  A rebuild while somebody is
;;; typing a passphrase would destroy the entry and the password with it, so the
;;; text lives in a slot, is written on every keystroke, and is put back into the
;;; new entry -- which also puts the cursor at the end, which is where it was.

(define-module (scheme-desktop widgets network)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit service-helpers)
  #:use-module (scheme-toolkit services network)
  #:use-module (scheme-toolkit services hyprland)
  #:use-module (scheme-toolkit services bluetooth)
  #:use-module (scheme-toolkit time)
  #:use-module (scheme-toolkit config)
  #:use-module (scheme-desktop config)
  #:use-module (scheme-desktop widgets network model)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 format)
  #:export (<network-desktop-widget> <network-panel-desktop-widget>))

(define-gi-imports "Gtk"
  "Widget" "Editable" "Box" "Button" "Entry" "Image" "Label" "Switch"
  "ScrolledWindow" "Separator" "EventControllerKey" "EventControllerMotion")

;;; ---------------------------------------------------------------------------
;;; The panel, and its state
;;; ---------------------------------------------------------------------------
;;
;; EVERY ONE OF THESE IS THE PANEL'S OWN STATE, which is why they are slots and
;; not module variables.  The distinction is worth stating because the clock's
;; `%clock-poll' next door stays a module variable and is right to: that is a
;; SHARED RESOURCE -- one `date' process serving every bar -- while these
;; describe one panel and mean nothing apart from it.
;;
;; A widget is one per shell, so nothing here would have collided as module
;; variables either.  The reason is that reading the class tells you what the
;; widget holds; before, you had to know where to look.

(define-class <network-panel-desktop-widget> (<popup-widget>)
  (window      #:init-value #f  #:accessor network-panel-window
               #:setter network-panel-window-set!)
  ;; The window's single child, and the only thing `refresh-network!' touches.
  ;; A STABLE box, because the popup window's child is a revealer that must not
  ;; be replaced: rebuilding into the window itself adds a second child and
  ;; leaves the first one still parented.
  (content     #:init-value #f  #:accessor network-panel-content
               #:setter network-panel-content-set!)
  ;; The scope the rebuilt widgets live in.
  (root        #:init-value #f  #:accessor network-panel-root
               #:setter network-panel-root-set!)
  ;; The <wifi-row>s on screen, in order.
  (rows        #:init-value '() #:accessor network-panel-rows
               #:setter network-panel-rows-set!)

  ;; The SSID whose passphrase prompt is open, or #f for none.
  ;;
  ;; #f AND NOT "". A hidden network has the empty SSID, so "" as the no-prompt
  ;; sentinel makes every hidden network match it and the panel comes up with a
  ;; passphrase box open under Hidden, having been asked for nothing.
  (prompt-ssid #:init-value #f  #:accessor network-panel-prompt-ssid
               #:setter network-panel-prompt-ssid-set!)
  ;; What has been typed into it, so a rebuild does not lose it.
  (password-text #:init-value "" #:accessor network-panel-password-text
                 #:setter network-panel-password-text-set!)
  ;; (kind . ssid) for the action in flight: 'connect or 'disconnect.
  (action      #:init-value #f  #:accessor network-panel-action
               #:setter network-panel-action-set!)
  ;; (reason . ssid) for a failed action, cleared when the row is next drawn.
  (failure     #:init-value #f  #:accessor network-panel-failure
               #:setter network-panel-failure-set!)
  ;; The debounce flag for a burst of device events.
  (refresh-pending #:init-value #f #:accessor network-panel-refresh-pending
                   #:setter network-panel-refresh-pending-set!)

  ;; Where the panel opens, horizontally.  The vertical half comes from the bar.
  (network-position #:init-value 'center #:init-keyword #:network-position
                    #:accessor network-position
                    #:config '(choice center top-center bottom-center)
                    #:label "Where it opens"))

(define (busy? w) (and (network-panel-action w) #t))

(define (clear-action! w)
  (network-panel-action-set! w #f))

;;; ---------------------------------------------------------------------------
;;; What the hero says
;;; ---------------------------------------------------------------------------
;;
;; None of these touch the panel: they read NetworkManager.  They take no widget
;; and are called the same way from a button and from the panel.

;; NMConnectivity, the same two states the bar's network module treats as up.
(define (connected? connectivity)
  (and connectivity (memq connectivity '(full limited)) #t))

(define (restricted? connectivity)
  (and connectivity (eq? connectivity 'portal) #t))

(define (primary-kind)
  "What the connection in use is, as 'wifi, 'ethernet or 'disconnected."

;; DISCONNECTED IS THE DEVICE'S STATE, NOT `connectivity'.  NetworkManager's
;; connectivity is whether the INTERNET is reachable -- probed and cached, so it
;; goes on saying `full' for a while after the wifi drops.  Read that way, this
;; said 'wifi while nothing was connected, and the panel's hero went on showing
;; signal BARS for a network that was gone instead of the crossed-out wifi glyph
;; that says disconnected.
;;
;; The ethernet question stays on `primary': the wired device is the one carrying
;; the connection, and it has no state test of its own here.
  (let ((n (network)))
    (cond ((not n) 'disconnected)
          ((eq? (catch #t (lambda () (slot-ref n 'primary)) (lambda a #f)) 'wired)
           'ethernet)
          ((wifi-connected?) 'wifi)
          (else 'disconnected))))

(define (panel-room w)
  "How tall the list may be: the screen between the bar and the bottom.

420 when the window does not exist yet -- the first build, before there is
anything to measure the panel against -- which is the old fixed cap standing in
until the real answer is available."
  (let ((win (network-panel-window w)))
    (or (and win (catch #t (lambda () (popup-available-height win)) (lambda args #f)))
        420)))

(define (hero-icon)
  (connection-icon (primary-kind)
                   (or (wifi-strength) 0)
                   (restricted? (catch #t
                                 (lambda () (slot-ref (network) 'connectivity))
                                 (lambda a #f)))))

(define (hero-title)
  "The name of the network in use, or what is happening instead."
  (case (primary-kind)
    ((wifi) (let ((ssid (wifi-ssid)))
              (if (and ssid (not (string=? ssid ""))) ssid "Wi-Fi")))
    ((ethernet) "Ethernet")
    (else "Disconnected")))

(define (hero-meta)
  "The state line under the name, in the reference's upper case."
  (cond ((restricted? (catch #t (lambda () (slot-ref (network) 'connectivity))
                             (lambda a #f)))
         "LIMITED ACCESS")
        ((eq? (primary-kind) 'disconnected) "NOT CONNECTED")
        (else "CONNECTED")))

;;; ---------------------------------------------------------------------------
;;; What a row says
;;; ---------------------------------------------------------------------------

(define (action-for w ssid)
  (let ((action (network-panel-action w)))
    (and action (equal? (cdr action) ssid) (car action))))

(define (failure-for w ssid)
  (let ((failure (network-panel-failure w)))
    (and failure (equal? (cdr failure) ssid) (car failure))))

(define (failure-text reason)
  "Omarchy's `networkFailureReason', as words.

The two cases it distinguishes are the ones a person can act on: a passphrase
that is needed and a passphrase that is wrong.  Everything else is the same
sentence, because nothing else can be fixed from this panel."
  (case reason
    ((no-secrets) "Passphrase required")
    ((supplicant-timeout) "Wrong password")
    ((supplicant-disconnect supplicant-config-failed supplicant-failed)
     "Wrong password")
    ((wifi-network-lost) "Network lost")
    (else "Failed to connect")))

(define (should-reprompt? reason secured?)
  "Whether a failure should reopen the passphrase prompt.

`no-secrets' and an auth timeout on a network that uses credentials both mean
the passphrase we sent was not the one it wanted, so the prompt comes back with
the text still in it.  A failure on an open network has nothing to re-enter."
  (and secured?
       (memq reason '(no-secrets supplicant-timeout supplicant-disconnect
                      supplicant-config-failed supplicant-failed))
       #t))

(define (row-status-text w row)
  "The second line of a row: an action in progress, or why the last one failed."
  (let ((ssid (wifi-row-ssid row))
        (prompt (network-panel-prompt-ssid w)))
    (cond ((and prompt (string=? prompt ssid)) "")
          ((eq? (action-for w ssid) 'connect) "Connecting…")
          ((eq? (action-for w ssid) 'disconnect) "Disconnecting…")
          ;; Forget has no in-progress state: `nmcli connection delete' is done
          ;; before it returns, so there is never a moment to show one in.
          ((failure-for w ssid) (failure-text (failure-for w ssid)))
          ((wifi-row-connected? row) "Connected")
          (else ""))))

;;; ---------------------------------------------------------------------------
;;; Actions
;;; ---------------------------------------------------------------------------

(define (run-action! w kind ssid thunk)
  "Do THUNK as KIND on SSID, marking the row while it runs.

The marking is the point: `activate' is asynchronous and says nothing until the
device's state changes, so without it a click looks like it did nothing at all
for the second and a half before the connection comes up."
  (network-panel-failure-set! w #f)
  (network-panel-action-set! w (cons kind ssid))
  (thunk)
  (refresh-network! w))

(define (connect! w row password)
  (let ((ap (wifi-row-ap row))
        (ssid (wifi-row-ssid row)))
    (if (not ap)
        (begin
          (network-panel-failure-set! w (cons 'failed ssid))
          (refresh-network! w))
        (run-action! w 'connect ssid (lambda () (wifi-connect! ap password))))))

(define (disconnect! w row)
  (run-action! w 'disconnect (wifi-row-ssid row) (lambda () (wifi-disconnect!))))

(define (forget! w row)
  "Delete ROW's saved profile.

NOT `run-action!': forgetting is `nmcli connection delete', which finishes
before it returns, so there is no waiting state to show and nothing to wait for
-- and `forget' does not move the device's state, so a handler watching for one
would never clear the row."
  (let ((ssid (wifi-row-ssid row)))
    (network-panel-failure-set! w #f)
    (unless (wifi-forget! ssid)
      (network-panel-failure-set! w (cons 'failed ssid)))
    (refresh-network! w)))

(define (open-prompt! w ssid)
  (let ((open (network-panel-prompt-ssid w)))
    (unless (and open (string=? open ssid))
      (network-panel-password-text-set! w "")))
  (network-panel-prompt-ssid-set! w ssid)
  (refresh-network! w))

(define (close-prompt! w)
  (network-panel-prompt-ssid-set! w #f)
  (network-panel-password-text-set! w "")
  (refresh-network! w))

;; Omarchy's `onClicked', in the same order.
(define (row-clicked! w row)
  (let ((ssid (wifi-row-ssid row)))
    (cond (;; CLICKING A ROW THAT IS ALREADY TRYING STOPS IT.  A connect that is
           ;; going nowhere -- a network that has gone out of range, an
           ;; activation NetworkManager never finishes -- would otherwise leave
           ;; the row saying Connecting... for ever, and the only way out was to
           ;; close the panel.  Clicking it again is what a person tries, so that
           ;; is what cancels: `deactivate-connection' stops an activation as
           ;; well as a connection.
           (and (busy? w) (equal? (cdr (network-panel-action w)) ssid))
           (catch #t (lambda () (wifi-disconnect!)) (lambda args #f))
           (clear-action! w)
           (refresh-network! w)
           #t)
          ((busy? w) #t)
          ((wifi-row-connected? row) (disconnect! w row))
          ((and (requires-credentials? row) (not (wifi-row-known? row)))
           (open-prompt! w ssid))
          ;; #f AND NOT "" FOR A NETWORK THAT NEEDS NO PASSWORD TYPED.  An empty
          ;; string IS a password -- an empty one -- and NetworkManager takes it
          ;; as such: it configures the connection with a key that cannot work and
          ;; waits at `config' for a handshake that never comes, which is the row
          ;; that sits on Connecting... for ever.  #f is what says "use the saved
          ;; profile", and it is why connecting works from a keybinding-and-API
          ;; test and not from a click: this call site had the "".
          (else (connect! w row #f)))))

;;; ---------------------------------------------------------------------------
;;; Drawing
;;; ---------------------------------------------------------------------------

(define (section-heading title)
  (case title
    ((known) "KNOWN NETWORKS")
    ((other) "OTHER NETWORKS")
    (else "")))

(define (row-widget w row index)
  "One network, as the widgets that draw it: an optional heading, then the row.

INDEX is its position in the sorted list, and it is what decides whether a
section heading goes above it -- the heading belongs to the RUN, not to the row,
so the same network shows one or not depending on what is sorted above it."
  (let* ((ssid (wifi-row-ssid row))
         (secured (requires-credentials? row))
         (forgettable (can-forget? row))
         (connected (wifi-row-connected? row))
         (prompt (network-panel-prompt-ssid w))
         (prompt-open (and prompt (string=? prompt ssid)))
         (failure (failure-for w ssid))
         (status (row-status-text w row))
         (icon (element <gtk-label>
                        #:class "network-row-icon"
                        #:label (wifi-signal-icon (wifi-row-signal row))))
         (name (element <gtk-label>
                        #:class "network-row-ssid"
                        #:label (row-ssid-display row)
                        #:halign 'start
                        #:ellipsize 'end))
         (status-label (element <gtk-label>
                                #:class "network-row-status"
                                #:label status
                                #:halign 'start
                                #:visible (not (string=? status ""))
                                #:ellipsize 'end))
         ;; HEXPAND IS WHAT PUTS THE LOCK AT THE RIGHT EDGE. A Gtk.Box packs its
         ;; children from the start, so without it the lock sits immediately
         ;; after the name, in the middle of the row -- the reference anchors it
         ;; to the parent's right edge and this is how that is said in GTK.
         (labels (element <gtk-box> #:orientation 'vertical #:class "network-row-labels"
                          #:hexpand #t name status-label))
         ;; THE RIGHT EDGE.  A lock says the network wants a password; a forget
         ;; button takes its place on a saved network that is not in use, which
         ;; is the only row where forgetting is a sensible thing to want.
         ;; Omarchy reveals it on hover for a secured network and shows it
         ;; outright for an open one; the reveal is the motion controller below.
         (lock (element <gtk-label> #:class "network-row-lock" #:label glyph-lock
                        #:visible secured))
         (forget-btn (element <gtk-button>
                              #:class "network-row-forget"
                              #:label glyph-forget
                              #:visible (and forgettable (not secured))
                              #:tooltip-text "Forget this network"
                              #:on-clicked (lambda (b) (forget! w row))))
         (right (element <gtk-box> #:orientation 'horizontal
                         #:class "network-row-actions" lock forget-btn))
         (body (element <gtk-box> #:orientation 'horizontal
                        #:class "network-row-body"
                        icon labels right))
         (btn (element <gtk-button>
                       #:class "network-row"
                       #:halign 'fill
                       #:can-focus #f
                       #:on-clicked (lambda (b) (row-clicked! w row))
                       body))
         (out '()))

    ;; The row's own state, as CSS classes: the stylesheet says what each looks
    ;; like, the model says which apply.
    (when connected (toggle-class! btn "connected" #t))
    (when (and (not connected) (wifi-row-known? row)) (toggle-class! btn "known" #t))
    (when failure (toggle-class! btn "failed" #t))

    ;; HOVER REVEALS FORGET on a saved secured network: the lock is what the row
    ;; normally shows and the forget button takes its place while the pointer is
    ;; on the row. A motion controller rather than CSS, because GTK4's `:hover`
    ;; matches the theme's own nodes and not a class we invented.
    (when (and forgettable secured)
      (let ((motion (make <gtk-event-controller-motion>)))
        (connect-signal! motion "enter"
                         (lambda (c x y)
                           (toggle-class! btn "forget-armed" #t)
                           (catch #t (lambda () (gtk-widget-set-visible lock #f)
                                              (gtk-widget-set-visible forget-btn #t))
                                  (lambda args #f))))
        (connect-signal! motion "leave"
                         (lambda (c)
                           (toggle-class! btn "forget-armed" #f)
                           (catch #t (lambda () (gtk-widget-set-visible lock #t)
                                              (gtk-widget-set-visible forget-btn #f))
                                  (lambda args #f))))
        (add-controller btn motion)))

    (set! out (list btn))

    ;; THE PASSPHRASE PROMPT, inline under the row, exactly as the reference
    ;; puts it: submitting fires the connect, Escape puts it away.
    (when prompt-open
      (let* ((entry (element <gtk-entry>
                             #:class "network-password"
                             #:placeholder-text "Password"
                             #:visibility #f
                             #:hexpand #t
                             #:text (network-panel-password-text w)))
             (submit (element <gtk-button>
                              #:class "network-password-submit"
                              #:label "Connect"))
             (cancel (element <gtk-button>
                              #:class "network-password-cancel"
                              #:label "Cancel"
                              #:on-clicked (lambda (b) (close-prompt! w))))
             (prompt-box (element <gtk-box> #:orientation 'horizontal
                                  #:class "network-prompt"
                                  entry submit cancel)))
        (connect-signal! submit "clicked"
                         (lambda (b)
                           (let ((text (gtk-editable-get-text entry)))
                             (network-panel-password-text-set! w text)
                             (network-panel-prompt-ssid-set! w #f)
                             (connect! w row text))))
        ;; Every keystroke is kept, because the next rebuild throws this entry
        ;; away and builds another one.
        (connect-signal! entry "changed"
                         (lambda (e)
                           (network-panel-password-text-set! w (gtk-editable-get-text e))))
        ;; RETURN SUBMITS, and the entry takes the keyboard as it appears -- a
        ;; prompt you have to click into is a prompt nobody uses.
        (let ((keys (make <gtk-event-controller-key>)))
          (connect-signal! keys "key-pressed"
                           (lambda (c keyval keycode modifiers)
                             (case keyval
                               ((65293 65421) (gtk-widget-activate submit) #t)
                               ((65307) (close-prompt! w) #t)
                               (else #f))))
          (add-controller entry keys))
        (catch #t (lambda () (gtk-widget-grab-focus entry)) (lambda args #f))
        (set! out (append out (list prompt-box)))))

    (let ((heading (section-heading (wifi-section-title (network-panel-rows w) index))))
      (if (string=? heading "")
          out
          (cons (element <gtk-label> #:class "network-section"
                         #:label heading #:halign 'start)
                out)))))

(define (render-list! w)
  "Every row in order, each under its section heading when it starts one.

A heading is a LABEL in the list rather than a separator: it scrolls with the
rows it introduces, which is what the reference's ListView delegate does."
  (let* ((rows (network-panel-rows w))
         (list (element <gtk-box> #:orientation 'vertical #:class "network-list")))
    (for-each (lambda (child) (add-child! list child #f))
              (append-map (lambda (row index) (row-widget w row index))
                          rows (iota (length rows))))
    list))

(define (render! w)
  "The whole panel: hero, scan line, list."
  (let ((body (element <gtk-box> #:orientation 'vertical #:class "network-panel")))
    (add-child! body
                (element <gtk-box> #:orientation 'horizontal #:class "network-hero"
                         (element <gtk-label> #:class "network-hero-icon"
                                  #:label (hero-icon))
                         (element <gtk-box> #:orientation 'vertical
                                  #:class "network-hero-labels"
                                  #:hexpand #t #:halign 'start
                                  (element <gtk-label> #:class "network-hero-title"
                                           #:label (hero-title) #:halign 'start)
                                  (element <gtk-label> #:class "network-hero-meta"
                                           #:label (hero-meta) #:halign 'start))
                         (element <gtk-switch>
                                  #:class "network-radio"
                                  #:active (or (wifi-enabled?) #f)
                                  #:valign 'center
                                  #:on-notify-active
                                  (lambda (s p)
                                    (wifi-enable! (gtk-switch-get-active s))
                                    (refresh-network! w))))
                #f)
    (when (wifi-scanning?)
      (add-child! body (element <gtk-label> #:class "network-scanning"
                                #:label "SCANNING FOR WI-FI…" #:halign 'start)
                  #f))
    ;; PROPAGATE + CAP, the same pair the menu uses: without the cap a busy
    ;; neighbourhood makes the panel as tall as the screen.
    ;;
    ;; THE CAP IS THE ROOM THE PANEL HAS, not a number: 420 was `about ten
    ;; networks', and the right question is how much screen there is between the
    ;; bar and the bottom.  The toolkit answers it (`popup-available-height',
    ;; which knows where the panel was placed), and the answer is only available
    ;; once the window exists -- so the very first build falls back and every
    ;; build after it is right.  `widget-show!' refreshes before showing, so the
    ;; panel is already the right height when it appears.
    (add-child! body
                (element <gtk-scrolled-window>
                         #:class "network-scroll"
                         #:hscrollbar-policy 'never
                         #:vscrollbar-policy 'automatic
                         #:propagate-natural-height #t
                         #:max-content-height (panel-room w)
                         (render-list! w))
                #f)
    body))

;;; ---------------------------------------------------------------------------
;;; Refreshing
;;; ---------------------------------------------------------------------------

(define (refresh-network! w)
  "Read the networks and draw them again.

THE ORDER IS: dispose the old scope, empty the box, build the new tree. Every
row connects click handlers and controllers, so the old scope has to go or the
handlers leak; and it has to go BEFORE the widgets are removed, because a
disconnect needs a live object -- disposing after destroying is what produced
`GLib-GObject-CRITICAL: instance with invalid (NULL) class pointer' in the
monitor-root teardown."
  (let ((content (network-panel-content w)))
    (when content
      (let ((root (network-panel-root w)))
        (when root (catch #t root (lambda args #f))))
      (network-panel-root-set! w #f)
      (clear-box! content)
      (network-panel-root-set!
       w
       (create-root
        (lambda (dispose)
          (network-panel-rows-set! w (wifi-rows))
          (add-child! content (render! w) #f)))))))

;;; ---------------------------------------------------------------------------
;;; The bar button
;;; ---------------------------------------------------------------------------

;; THE BAR HALF OF THE NETWORK FEATURE.  The panel below is its own widget and
;; neither knows about the other: this one opens it with `(toggle-widget
;; 'network-panel)' through `panel-button', the same call a keybinding makes.
(define-class <network-desktop-widget> (<bar-item-widget>)
  ;; WHAT THE BAR'S NETWORK ITEM SHOWS.  Two switches, because they answer two
  ;; different questions and a user wants them independently: the glyph says
  ;; whether there is a connection at a glance, the name says WHICH one, and the
  ;; name is long enough that some people want it and some do not.
  ;;
  ;;   icon off, name on   the icon only while DISCONNECTED, otherwise the name
  ;;   icon on,  name off  the icon, which is the default
  ;;   both on             the name after the icon
  ;;
  ;; The rules are in the two computeds below, one per label, so the widgets
  ;; themselves are built once and only their visibility moves.
  (show-wifi-icon #:init-value #t #:init-keyword #:show-wifi-icon
                  #:accessor network-show-wifi-icon
                  #:config '(boolean)
                  #:label "Show the wifi icon")
  (show-wifi-name #:init-value #f #:init-keyword #:show-wifi-name
                  #:accessor network-show-wifi-name
                  #:config '(boolean)
                  #:label "Show the network name"))

(define-method (widget-build (w <network-desktop-widget>) output)
  "The bar's network button: the connection glyph and the name, opening the panel.

A BUTTON, where this shell's network item used to be a plain box.  Omarchy's bar
item opens its network panel and ags2-shell's opens quick settings, so a network
indicator that cannot be clicked is the odd one out -- and there was no other way
to reach the panel.

THE TWO BINDINGS ARE NESTED ON PURPOSE. `connectivity' and `primary' are on the
Network object, but the icon and the SSID are on the WIFI DEVICE underneath it,
so they need `create-binding-path' -- binding to the parent's `wifi' property
only reports when the device itself is replaced.

IT DIMS RATHER THAN DISAPPEARING when the network is down, which is what the
module this replaces did and is still right: a widget that vanishes makes the
bar reflow every time the connection drops, which is more distracting than the
state it reports."
  (let* ((n (network))
         (primary (and n (create-binding n "primary" 'primary)))
         ;; THE WIFI DEVICE'S OWN STATE, NOT THE NETWORK'S `connectivity'.  They
         ;; are different questions -- connectivity is whether the INTERNET is
         ;; reachable, which NetworkManager probes and caches -- and the wrong one
         ;; is what made the bar go on showing a network name after the wifi was
         ;; disconnected from somewhere else.  Measured: the device says
         ;; `disconnected' at once, `connectivity' went on saying `full'.
         ;;
         ;; AND THROUGH AN ACCESSOR FED BY THE SIGNAL, not `create-binding': the
         ;; `state' property does not notify, so a binding here answered once and
         ;; never changed -- the bar kept its signal bars after the radio was
         ;; switched off while the panel, which reads when it draws, showed the
         ;; crossed-out glyph.  See `wifi-state-accessor' in the toolkit.
         (state (and n (wifi-state-accessor)))
         (ssid (and n (create-binding-path n '("wifi" "ssid") 'ssid)))
         (show-icon (widget-slot-ref w 'show-wifi-icon))
         (show-name (widget-slot-ref w 'show-wifi-name))
         ;; IS THE WIFI CARRYING A CONNECTION, as opposed to the internet being
         ;; up: one predicate, read by both computeds below and by the dimming.
         ;; TRACKING READS, NOT `st-peek'.  A `create-computed' finds its
         ;; dependencies by running its body under a tracking set, and `st-peek'
         ;; is the read that records NOTHING -- so a computed built on it has no
         ;; dependencies, is never recomputed, and is a snapshot of the moment it
         ;; was built.  That is what this was: the icon, the name and the dimming
         ;; were all decided once, when the bar was assembled, which is why the
         ;; bar alone went on showing a connection that had ended.
         (up (lambda () (eq? (state) 'activated)))
         (wifi-primary? (lambda () (eq? (primary) 'wifi)))
         (icon (and n (create-computed
                       (lambda ()
                         (cond ((eq? (primary) 'wired) glyph-ethernet)
                               ((not (up)) glyph-wifi-off)
                               ((restricted? (catch #t
                                               (lambda () (slot-ref n 'connectivity))
                                               (lambda a #f)))
                                glyph-wifi-restricted)
                               (else (connection-icon 'wifi (or (wifi-strength) 0) #f)))))))
         (text (and n (create-computed
                       (lambda ()
                         (if (and (up) (wifi-primary?))
                             (or (ssid) "")
                             "")))))
         (icon-visible (create-computed
                        (lambda ()
                          (or (show-icon)
                              (and (show-name) (not (up)))))))
         (name-visible (create-computed
                        (lambda ()
                          (and (show-name) (up)))))
         (btn (panel-button (desktop-widget-required <network-panel-desktop-widget>)
                            #:align (widget-section w)
                            ;; THE TWO LABELS GO IN A BOX, and a button needs one:
                            ;; a GtkButton has a SINGLE child, so passing the icon
                            ;; and the name as two children of the button means
                            ;; the second REPLACES the first -- silently, with no
                            ;; error and nothing missing to the eye except the
                            ;; icon, which is why the bar's network item has only
                            ;; ever shown the name.
                            (element <gtk-box> #:orientation 'horizontal
                                     #:class "network-item"
                                     ;; CENTRED, or the glyph sits at the LEFT of
                                     ;; the button's padding: a box fills its
                                     ;; parent and packs its children from the
                                     ;; start, so an icon-only item drew its
                                     ;; circle around a glyph in the corner.
                                     #:halign 'center
                                     (element <gtk-label> #:class "network-icon"
                                              #:label (or icon glyph-wifi-off)
                                              #:visible icon-visible)
                                     (element <gtk-label> #:class "network-ssid"
                                              #:label (or text (hero-title))
                                              #:visible name-visible)))))
    (when n
      (create-effect
       (lambda ()
         (toggle-class! btn "unavailable" (not (up))))
       #:immediate #t)
      ;; ICON-ONLY IS A CLASS, because it is what decides the hover shape: the
      ;; stylesheet draws a CIRCLE on an item that is just a glyph, the way the
      ;; workspace buttons do, and a rounded rectangle on one carrying a network
      ;; name -- a circle round a wide label is an ellipse, which is the `weird
      ;; oval' the old rule produced.
      (create-effect
       (lambda ()
         (toggle-class! btn "icon-only" (not (name-visible))))
       #:immediate #t))
    btn))

;;; ---------------------------------------------------------------------------
;;; The window
;;; ---------------------------------------------------------------------------

;; The widget is `network-panel' and its window is `network' -- the feature and
;; the surface it draws -- which is what style.scm calls it too.  See the note on
;; the date menu's panel for why this is a method rather than a `popup-window'
;; argument or a slot.
(define-method (widget-window-name (w <network-panel-desktop-widget>)) "network")

(define (network-popup-position w)
  "Where the panel opens: the bar's edge, and this panel's own horizontal half."
  (bar-popup-position #:horizontal (network-position w)))

(define (schedule-refresh! w)
  "Redraw soon, however many events arrive in the meantime.

A SCAN ARRIVES AS A BURST.  NetworkManager announces one `access-point-added'
per radio it finds, so a refresh on each event would rebuild the whole panel
thirty times for one scan -- and each rebuild runs `nmcli' for the saved-profile
list.  The flag turns the burst into one redraw, a quarter second after it
settles, which is faster than a person can see and slower than the events."
  (unless (network-panel-refresh-pending w)
    (network-panel-refresh-pending-set! w #t)
    (timeout 250 (lambda ()
                   (network-panel-refresh-pending-set! w #f)
                   (refresh-network! w)))))

(define (watch-wifi! w)
  "Redraw when the access point list or the device state changes."
  (let ((dev (wifi)))
    (when dev
      (for-each
       (lambda (signal)
         (catch #t
                (lambda ()
                  (connect-signal! dev signal
                                   (lambda args (on-wifi-event! w signal args))))
                (lambda args #f)))
       '("access-point-added" "access-point-removed" "state-changed")))))

(define (on-wifi-event! w signal args)
  "One device event, turned into the smallest correct response.

`state-changed' IS WHERE A FAILED CONNECTION ARRIVES, and it arrives with the
reason as a symbol -- 'failed with 'no-secrets for a wrong passphrase, measured
against a real network with a deliberately wrong one.  That is what lets the row
say Wrong password and reopen the prompt, rather than sitting on Connecting…
forever."
  ;; `string=?' AND NOT `eq?' ON TWO STRING LITERALS.  They are the same text in
  ;; the same file, which reads as though `eq?' would do -- and it does at a REPL,
  ;; where the reader interns them -- but a COMPILED module is free to emit two
  ;; separate constants, and then `eq?' is #f for ever.  That is what this was:
  ;; every device event was ignored, so a connect or a disconnect never finished
  ;; and its row sat on Connecting... or Disconnecting... while the list behind it
  ;; went on refreshing, which looks exactly like "it just sits there".
  ;; SAID OUT LOUD WHILE SOMETHING IS IN FLIGHT, and only then: the states a
  ;; connection goes through are the whole of the answer to "why is this row
  ;; stuck on Connecting...", and there is no other way to see them from outside.
  ;; Quiet when nothing is being attempted, which is almost always.
  (when (and (string=? signal "state-changed") (pair? args) (network-panel-action w))
    (format (current-error-port)
            "scheme-desktop: wifi: state ~a (was ~a, reason ~a) while ~a~%"
            (and (> (length args) 1) (list-ref args 1))
            (and (> (length args) 2) (list-ref args 2))
            (and (> (length args) 3) (list-ref args 3))
            (network-panel-action w)))
  (when (and (string=? signal "state-changed") (pair? args))
    ;; ARG 0 IS THE EMITTER, NOT THE FIRST SIGNAL ARGUMENT. `connect-signal!'
    ;; connects with `(lambda (o . rest) (apply proc o rest))', so a handler's
    ;; argument list is the emitting object followed by the signal's own
    ;; parameters -- new state, old state, reason. Reading index 0 as the new
    ;; state compares the Wifi device against 'failed, which is never true, and
    ;; the row sits on Connecting… for ever.
    (let* ((new (and (> (length args) 1) (list-ref args 1)))
           (reason (and (> (length args) 3) (list-ref args 3)))
           (action (network-panel-action w))
           (kind (and action (car action)))
           (ssid (and action (cdr action))))
      ;; WHICH STATE MEANS DONE DEPENDS ON WHAT WAS ASKED FOR, and getting this
      ;; wrong is not subtle. Connecting to a network DEACTIVATES the current
      ;; one first, so the first thing a connect attempt reports is
      ;; `disconnected' -- reading that as "the connect finished" clears the
      ;; action and the prompt about a second before the real answer arrives,
      ;; and the failure that follows is then dropped on the floor. Measured
      ;; against CHARLIE_PLACE with a wrong passphrase: disconnected,
      ;; prepare, config, need-auth, prepare, config, need-auth, failed.
      (cond
       ((and (eq? kind 'connect) (eq? new 'activated))
        (clear-action! w)
        (network-panel-prompt-ssid-set! w #f)
        (network-panel-password-text-set! w ""))
       ((and (eq? kind 'connect) (eq? new 'failed))
        (let ((row (find (lambda (r) (string=? (wifi-row-ssid r) ssid))
                         (network-panel-rows w))))
          (network-panel-failure-set! w (cons (or reason 'failed) ssid))
          (clear-action! w)
          ;; REOPEN THE PROMPT when the passphrase was the problem, with the
          ;; text still in it so it can be corrected rather than retyped.
          (when (and row (should-reprompt? reason (requires-credentials? row)))
            (network-panel-prompt-ssid-set! w ssid))))
       ((and (eq? kind 'disconnect) (eq? new 'disconnected))
        (clear-action! w)))))
  ;; OUTSIDE the state test, and that is the fix rather than a tidy-up: an
  ;; `access-point-added' is what says the list has grown, and the panel was
  ;; showing whatever the device happened to have at startup -- one access
  ;; point, before the first scan finished -- because only `state-changed'
  ;; redrew it.
  (schedule-refresh! w))

;; REDRAWN BEFORE IT IS SHOWN, so the list is the right height in the first frame
;; the user sees -- the cap depends on where the panel was placed, and placing
;; happens on the way to showing it.  The same reasoning as the menu's show
;; override; the network list also has a scan to start, which the toggle hook
;; below does.
(define-method (widget-show! (w <network-panel-desktop-widget>))
  (catch #t (lambda () (refresh-network! w)) (lambda args #f))
  (next-method))

(define-method (widget-window (w <network-panel-desktop-widget>))
  "The wifi panel, registered under the name `network'.

Registered at startup like the other windows, so the bar button's
`toggle-widget' finds it -- a lazily-built panel is one `widget-toggle!' cannot
find, which is how the menu button once came to do nothing."
  (unless (network-panel-window w)
    (let ((content (element <gtk-box> #:orientation 'vertical #:class "network-root")))
      (network-panel-content-set! w content)
      (network-panel-window-set!
       w
       (popup-window (widget-window-name w)
                     #:position (network-popup-position w)
                     #:keymode 'on-demand
                     content))
      (watch-wifi! w)
      (refresh-network! w)
      ;; Redrawn on every open, and a scan started with it: networks come and go
      ;; while the panel is shut, and a panel that shows the neighbourhood as it
      ;; was ten minutes ago is worse than one that shows nothing. The scan's
      ;; results arrive as `access-point-added' and redraw it again.
      (on-window-toggle "network"
                        (lambda (win)
                          (when (catch #t (lambda () (slot-ref win 'visible))
                                       (lambda args #f))
                            (wifi-scan!)
                            (refresh-network! w))))))
  (network-panel-window w))
