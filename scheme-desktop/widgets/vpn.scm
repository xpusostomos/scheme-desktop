;;; (scheme-desktop widgets vpn) -- the bar's VPN item and its panel
;;;
;;; PORTED FROM the Omarchy VPN plugin, `Panel.qml' (~/GIT/omarchy-vpn).  A
;;; padlock in the bar, closed and lit while a VPN is up; a panel listing every
;;; VPN NetworkManager knows, each started or stopped with a click.  The data --
;;; parsing `nmcli', the up/down commands -- is the plugin's `Model.js', and lives
;;; in (scheme-toolkit services vpn).
;;;
;;;   left click     open / close the panel
;;;   right click    stop the active VPN, or start the first one
;;;   middle click   refresh now
;;;   a row          start or stop that VPN
;;;
;;; WHAT THE BAR SHOWS is two options, as the wifi item's are:
;;;
;;;   #:icon-enabled      #t   the padlock
;;;   #:vpn-name-enabled  #f   the active VPN's name, while one is up
;;;
;;; and when neither would show anything -- both off, or only the name and no VPN
;;; is up -- the padlock is shown anyway.  An item that can draw nothing is an
;;; item nobody can click to open the panel.
;;;
;;; ONE STATE FOR THE WHOLE SHELL.  The list, the error and the action in flight
;;; are module-level, because every monitor's bar and the panel show the same
;;; thing, and one `nmcli' every refresh is enough for all of them.

(define-module (scheme-desktop widgets vpn)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit time)
  #:use-module (scheme-toolkit services vpn)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  ;; `string-join' and `string-null?' -- NOT core Guile, and leaving this out is
  ;; the bug that stopped the shell starting when the power menu went in.
  #:use-module (srfi srfi-13)
  #:use-module (ice-9 format)
  #:export (<vpn-desktop-widget> <vpn-panel-desktop-widget>
            vpn-refresh! vpn-toggle-active!))

(define-gi-imports "Gtk" "Box" "Label" "Button" "GestureClick")

;;; ---------------------------------------------------------------------------
;;; Glyphs
;;; ---------------------------------------------------------------------------
;;
;; Nerd Font, as the rest of this bar is -- the plugin draws its padlock with a
;; canvas for the same look, and these two are that padlock.  `integer->char',
;; never "\U...": Guile reads "\U000F033E" as two characters and a string, with
;; no error (see the memory note on it).  EACH WAS RENDERED BEFORE IT WAS USED:
;; U+F033F, which the name `lock-open' suggests, draws a second CLOSED padlock,
;; so the disconnected state would have looked exactly like the connected one.

(define (glyph cp) (string (integer->char cp)))
(define glyph-locked (glyph #x0F033E))      ; a VPN is up -- shackle down
(define glyph-unlocked (glyph #x0F0FC6))    ; none is -- shackle lifted
(define glyph-refresh (glyph #x0F0450))     ; the plugin's refresh
(define glyph-stop (glyph #x0F04DB))        ; the plugin's disconnect
(define glyph-start (glyph #x0F0415))       ; the plugin's connect

;;; ---------------------------------------------------------------------------
;;; The state
;;; ---------------------------------------------------------------------------

;; THE VPN CONNECTIONS, active first; the last `nmcli' error, or ""; and the
;; action in flight as (NAME . 'up/'down), or #f -- the plugin's `pendingName'
;; and `pendingOp', which is what lets a row say Connecting... the instant it is
;; clicked, while `nmcli' runs detached.
(define-values (vpns set-vpns!) (create-state '()))
(define-values (vpn-error set-vpn-error!) (create-state ""))
(define-values (pending set-pending!) (create-state #f))

(define (active-names) (map vpn-connection-name (filter vpn-active? (vpns))))
(define (any-active?) (pair? (active-names)))

(define (vpn-refresh!)
  "Read the connections again.  What the poll, the panel opening, an action and
a middle click all call.

AND IT ENDS THE ACTION IN FLIGHT when the list shows it done -- the connection
up after an `up', down after a `down'.  The plugin leaves its Connecting... up
for its full fifteen-second timeout whatever happens, so a VPN that came up in a
second went on saying Connecting... for fourteen more.  The timeout is still
here, for an action that never finishes."
  (let ((conns (vpn-connections)))
    (if (not conns)
        (set-vpn-error! "nmcli failed")
        (begin
          (set-vpn-error! "")
          (set-vpns! conns)
          (let ((p (pending)))
            (when p
              (let ((c (find (lambda (c) (string=? (vpn-connection-name c) (car p))) conns)))
                (when (or (not c)
                          (eq? (vpn-active? c) (eq? (cdr p) 'up)))
                  (set-pending! #f))))))))
  #t)

(define (toggle-vpn! c)
  "Start C if it is down, stop it if it is up.

The plugin's `toggleConnection': mark it pending, run `nmcli' detached, and read
the list again a little later -- 1.2 seconds, its delay -- because the change
does not show at once.  The pending mark gives up after fifteen."
  (let ((name (vpn-connection-name c))
        (op (if (vpn-active? c) 'down 'up)))
    (set-pending! (cons name op))
    (if (eq? op 'down) (vpn-down! name) (vpn-up! name))
    (timeout 1200 (lambda () (vpn-refresh!)))
    (timeout 15000 (lambda ()
                     (when (equal? (pending) (cons name op)) (set-pending! #f))))
    #t))

(define (vpn-toggle-active!)
  "Stop the active VPN, or start the first one: the bar's right click.

The plugin's `toggleActiveVpn', and exported so a keybinding can do the same."
  (let* ((conns (vpns))
         (active (find vpn-active? conns)))
    (cond (active (toggle-vpn! active))
          ((pair? conns) (toggle-vpn! (car conns)))
          (else #f))))

;; THE POLL, started once by whichever bar item is built first.  Its period is the
;; option's at that moment; changing the option takes effect at the next start.
(define %poll #f)

(define (start-poll! seconds)
  (unless %poll
    (set! %poll (interval (* 1000 (max 3 seconds)) vpn-refresh! #:immediate #t))))

;;; ---------------------------------------------------------------------------
;;; The bar item
;;; ---------------------------------------------------------------------------

(define-class <vpn-desktop-widget> (<bar-item-widget>)
  (icon-enabled #:init-value #t #:init-keyword #:icon-enabled
                #:accessor vpn-icon-enabled
                #:config '(boolean)
                #:label "Show the VPN icon")
  (vpn-name-enabled #:init-value #f #:init-keyword #:vpn-name-enabled
                    #:accessor vpn-name-enabled
                    #:config '(boolean)
                    #:label "Show the VPN name")
  ;; The plugin's `refreshIntervalSec': 3 to 600, default 10.
  (refresh-interval #:init-value 10 #:init-keyword #:refresh-interval
                    #:accessor vpn-refresh-interval
                    #:config '(number 3 600)
                    #:label "Status refresh interval (seconds)"))

(define (on-button! widget button proc)
  "Run PROC when mouse BUTTON is pressed on WIDGET -- a gesture per button,
because a GtkButton's `clicked' is the primary button only."
  (let ((gesture (make <gtk-gesture-click>)))
    (catch #t (lambda () (slot-set! gesture 'button button)) (lambda args #f))
    (connect-signal! gesture "pressed" (lambda (g n x y) (proc)))
    (add-controller widget gesture)))

(define-method (widget-build (w <vpn-desktop-widget>) output)
  "The padlock, and the VPN's name when the option says so, opening the panel.

THE RULE, in the two computeds: the name shows when it is enabled AND a VPN is
up; the padlock shows when it is enabled OR the name is not showing -- which is
what puts the padlock back when both options are off."
  (start-poll! (vpn-refresh-interval w))
  (let* ((show-icon (widget-slot-ref w 'icon-enabled))
         (show-name (widget-slot-ref w 'vpn-name-enabled))
         (names (create-computed (lambda () (string-join (active-names) ", "))))
         (name-visible (create-computed (lambda () (and (show-name) (any-active?)))))
         (icon-visible (create-computed (lambda () (or (show-icon) (not (name-visible))))))
         (icon (create-computed (lambda () (if (any-active?) glyph-locked glyph-unlocked))))
         (btn (panel-button (desktop-widget-required 'vpn-panel)
                            #:align (widget-section w)
                            ;; A BOX, because a button has ONE child -- the second
                            ;; label would silently replace the first (the network
                            ;; item learned this the hard way).
                            (element <gtk-box> #:orientation 'horizontal
                                     #:class "vpn-item" #:halign 'center
                                     (element <gtk-label> #:class "vpn-icon"
                                              #:label icon #:visible icon-visible)
                                     (element <gtk-label> #:class "vpn-name"
                                              #:label names #:visible name-visible)))))
    (on-button! btn 3 vpn-toggle-active!)
    (on-button! btn 2 vpn-refresh!)
    ;; DIMMED WHILE NOTHING IS UP, and lit when something is -- the plugin's
    ;; `dimmed: !anyActive' -- and an `icon-only' class so the hover draws a
    ;; circle round a lone glyph, the way the network item's does.
    (create-effect (lambda () (toggle-class! btn "unavailable" (not (any-active?))))
                   #:immediate #t)
    (create-effect (lambda () (toggle-class! btn "active-vpn" (any-active?)))
                   #:immediate #t)
    (create-effect (lambda () (toggle-class! btn "icon-only" (not (name-visible))))
                   #:immediate #t)
    (create-effect (lambda ()
                     (catch #t
                       (lambda ()
                         (slot-set! btn 'tooltip-text
                                    (if (any-active?)
                                        (string-append "VPN · " (names))
                                        "VPN · Not connected")))
                       (lambda a #f)))
                   #:immediate #t)
    btn))

;;; ---------------------------------------------------------------------------
;;; The panel
;;; ---------------------------------------------------------------------------

(define-class <vpn-panel-desktop-widget> (<popup-widget>)
  (window #:init-value #f #:accessor vpn-panel-window #:setter vpn-panel-window-set!))

;; The widget is `vpn-panel' and its window is `vpn', which is what the
;; stylesheet calls it -- the date menu's split, for the date menu's reason.
(define-method (widget-window-name (w <vpn-panel-desktop-widget>)) "vpn")

(define (status-text)
  "The line under the title: the plugin's `statusMetaText'."
  (let ((p (pending)))
    (cond (p (format #f "~a ~a…" (if (eq? (cdr p) 'up) "Connecting to" "Disconnecting")
                     (car p)))
          ((any-active?) (string-append "Connected · " (string-join (active-names) ", ")))
          ((null? (vpns)) "No VPN connections")
          (else "Not connected"))))

(define (row-status c)
  "A row's second line: Connecting…, or the type and the device."
  (let ((p (pending)))
    (if (and p (string=? (car p) (vpn-connection-name c)))
        (if (eq? (cdr p) 'up) "Connecting…" "Disconnecting…")
        (string-append (if (vpn-wireguard? c) "WireGuard" "VPN")
                       (if (string-null? (vpn-connection-device c))
                           ""
                           (string-append " · " (vpn-connection-device c)))))))

(define (vpn-row c)
  "One connection: the padlock, its name and status, and start or stop.

THE WHOLE ROW IS THE BUTTON, where the plugin has a row click AND an action
button that do the same thing; the glyph at the right end says which it will
do.  Insensitive while that row's action is in flight."
  (let* ((active (vpn-active? c))
         (p (pending))
         (busy (and p (string=? (car p) (vpn-connection-name c)))))
    (element <gtk-button> #:class (if active "vpn-row connected" "vpn-row")
             #:sensitive (not busy)
             #:tooltip-text (if active "Disconnect" "Connect")
             #:on-clicked (lambda (b) (toggle-vpn! c))
      (element <gtk-box> #:orientation 'horizontal #:class "vpn-row-body"
        (element <gtk-label> #:class "vpn-row-icon"
                 #:label (if active glyph-locked glyph-unlocked))
        (element <gtk-box> #:orientation 'vertical #:hexpand #t
          (element <gtk-label> #:class "vpn-row-name" #:xalign 0.0
                   #:ellipsize 'end #:max-width-chars 32
                   #:label (vpn-connection-name c))
          (element <gtk-label> #:class "vpn-row-status" #:xalign 0.0
                   #:label (row-status c)))
        (element <gtk-label> #:class "vpn-row-action"
                 #:label (if active glyph-stop glyph-start))))))

(define (panel-content)
  "The whole panel, as it stands now: the header, any error, the rows or the
empty state, and the hint."
  ;; `conns' AND NOT `list': a binding called `list' SHADOWS Guile's `list', and
  ;; every `(list ...)' below then applied the VPN list as a procedure --
  ;; "Wrong type to apply", raised while the bar was being built, which stopped
  ;; the shell starting.  The unbound-name check cannot see it: the name IS bound.
  (let ((conns (vpns))
        (err (vpn-error)))
    (apply element <gtk-box> #:orientation 'vertical #:class "vpn-panel"
           (append
            (list
             (element <gtk-box> #:orientation 'horizontal #:class "vpn-hero"
               (element <gtk-label> #:class "vpn-hero-icon"
                        #:label (if (any-active?) glyph-locked glyph-unlocked))
               (element <gtk-box> #:orientation 'vertical #:hexpand #t
                 (element <gtk-label> #:class "vpn-hero-title" #:xalign 0.0 #:label "VPN")
                 (element <gtk-label> #:class "vpn-hero-meta" #:xalign 0.0
                          #:ellipsize 'end #:label (status-text)))
               (element <gtk-button> #:class "vpn-refresh" #:tooltip-text "Refresh"
                        #:valign 'center
                        #:on-clicked (lambda (b) (vpn-refresh!))
                 (element <gtk-label> #:label glyph-refresh))))
            (if (string-null? err)
                '()
                (list (element <gtk-label> #:class "vpn-error" #:xalign 0.0
                               #:wrap #t #:label err)))
            (if (null? conns)
                (list (element <gtk-label> #:class "vpn-empty" #:xalign 0.0
                               #:label "No VPN connections")
                      (element <gtk-label> #:class "vpn-hint" #:xalign 0.0 #:wrap #t
                               #:label "Import one with: nmcli connection import type openvpn file <profile.ovpn>"))
                (append (map vpn-row conns)
                        (list (element <gtk-label> #:class "vpn-hint" #:xalign 0.0
                                       #:label "Click a row to connect or disconnect"))))))))

(define-method (widget-window (w <vpn-panel-desktop-widget>))
  "The VPN panel, registered under the name `vpn'.

REDRAWN FROM THE STATE, in an effect: the list, the error and the action in
flight are accessors, so any change to them -- a poll, a click -- rebuilds the
panel's content and nothing else.  Read again when it opens, as the plugin's
`onOpenedChanged' does: what NetworkManager did while the panel was shut should
not wait for the next poll."
  (unless (vpn-panel-window w)
    (let ((holder (element <gtk-box> #:orientation 'vertical)))
      (vpn-panel-window-set!
       w
       (popup-window (widget-window-name w)
                     #:position (bar-popup-position #:horizontal 'right)
                     #:keymode 'on-demand
                     holder))
      ;; `create-root' and not `create-window-root': the latter expects its
      ;; procedure to RETURN a window, and this one is only a standing scope for
      ;; the effect to live in -- the overview's arrangement.
      (create-root
       (lambda (dispose)
         (create-effect (lambda ()
                          (let ((content (panel-content)))
                            (clear-box! holder)
                            (add-child! holder content #f)))
                        #:immediate #t)))
      (on-window-toggle "vpn"
                        (lambda (win)
                          (when (catch #t (lambda () (slot-ref win 'visible))
                                       (lambda a #f))
                            (vpn-refresh!))))))
  (vpn-panel-window w))
