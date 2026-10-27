;;; (scheme-desktop widgets bar network) -- connection state
;;;
;;; Shows the wifi signal icon and the SSID when wifi is primary, a wired icon
;;; when ethernet is, and a disconnected icon when neither.
;;;
;;; The service layer here is (scheme-toolkit astal): `network' is the
;;; NetworkManager singleton and the properties are read through create-binding,
;;; so this module never touches GI itself.  That is the seam the plan asks for
;;; -- which Astal properties to surface is the shell's decision, but reading
;;; them is the toolkit's job.

(define-module (scheme-desktop widgets bar network)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit astal)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:export (network-widget))

(define-gi-imports "Gtk" "Box" "Image" "Label")

;; NMConnectivity: 'full is what "connected" means.
(define (connected? connectivity)
  (and connectivity (memq connectivity '(full limited)) #t))

(define (network-icon connectivity primary wifi-icon)
  "An Adwaita symbolic icon for the current connection.

Wifi prefers NetworkManager's own icon-name, which distinguishes signal
strength; strength itself is not readable through Astal here (both the device
and the access point raise on that property), so this is the only way to show
it."
  (cond
   ((not (connected? connectivity)) "network-offline-symbolic")
   ((eq? primary 'wired) "network-wired-symbolic")
   ((eq? primary 'wifi)
    (or wifi-icon "network-wireless-symbolic"))
   (else "network-wireless-symbolic")))

(define (network-text connectivity primary ssid)
  "The SSID when on wifi, nothing when wired -- an ethernet connection has no
name worth showing, and both reference shells leave it blank."
  (cond
   ((not (connected? connectivity)) "")
   ((eq? primary 'wifi) (or ssid ""))
   (else "")))

(define (network-widget)
  "An image and label reflecting the current connection, or an empty box."
  (if (not (network))
      (element <gtk-box> #:class "network")
      (let* ((nm (network))
             ;; create-binding on the Network object gives us `connectivity'
             ;; and `primary'; the wifi device is reached through it, and may
             ;; be absent on a machine with no wireless card at all.
             (connectivity (create-binding nm "connectivity" 'connectivity))
             (primary (create-binding nm "primary" 'primary))
             ;; The SSID and the signal icon live on the wifi DEVICE, so they
             ;; need the nested binding: binding to the parent's `wifi'
             ;; property only reports when the device itself changes.
             (wifi-icon (create-binding-path nm '("wifi" "icon-name") 'wifi-icon))
             (ssid (create-binding-path nm '("wifi" "ssid") 'ssid))
             (icon (create-computed
                    (lambda ()
                      (network-icon (st-peek connectivity) (st-peek primary)
                                    (st-peek wifi-icon)))))
             (text (create-computed
                    (lambda ()
                      (network-text (st-peek connectivity) (st-peek primary)
                                    (st-peek ssid))))))
        (element <gtk-box>
                 #:orientation 'horizontal
                 ;; Dimmed when offline rather than removed: a widget that
                 ;; disappears makes the bar reflow every time the network
                 ;; drops, which is more distracting than the state it reports.
                 #:class (create-computed
                          (lambda ()
                            (if (connected? (st-peek connectivity))
                                "network"
                                "network unavailable")))
                 #:tooltip-text text
                 (element <gtk-image> #:icon-name icon)
                 (element <gtk-label> #:label text)))))
