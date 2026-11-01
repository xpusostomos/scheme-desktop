;; The widgets scheme-desktop provides, in the format every plugin uses: the module
;; that defines each widget, followed by its class.  Read, never evaluated.
;;
;; THE ORDER IS THE DEFAULT CONFIG'S.  A first run enables each of these in turn,
;; and each one that goes in the bar goes at the end of its section -- so the bar's
;; right section comes out in the order its widgets are listed here.
((scheme-desktop widgets theme <theme-desktop-widget>)
 (scheme-desktop widgets bar <bar-desktop-widget>)
 (scheme-desktop widgets menu <menu-desktop-widget>)
 (scheme-desktop widgets menu <menu-panel-desktop-widget>)
 (scheme-desktop widgets bar workspaces <workspaces-desktop-widget>)
 (scheme-desktop widgets overview <overview-desktop-widget>)
 (scheme-desktop widgets date-menu <datemenu-desktop-widget>)
 (scheme-desktop widgets date-menu <datemenu-panel-desktop-widget>)
 (scheme-desktop widgets bar clock <clock-desktop-widget>)
 (scheme-desktop widgets bar media <media-desktop-widget>)
 (scheme-desktop widgets bar tray <tray-desktop-widget>)
 (scheme-desktop widgets network <network-desktop-widget>)
 (scheme-desktop widgets network <network-panel-desktop-widget>)
 (scheme-desktop widgets vpn <vpn-desktop-widget>)
 (scheme-desktop widgets vpn <vpn-panel-desktop-widget>)
 (scheme-desktop widgets audio <audio-desktop-widget>)
 (scheme-desktop widgets audio <audio-panel-desktop-widget>)
 (scheme-desktop widgets bluetooth <bluetooth-desktop-widget>)
 (scheme-desktop widgets bluetooth <bluetooth-panel-desktop-widget>)
 (scheme-desktop widgets battery <battery-desktop-widget>)
 (scheme-desktop widgets battery <battery-panel-desktop-widget>)
 (scheme-desktop widgets power-menu button <powermenu-desktop-widget>)
 (scheme-desktop widgets power-menu window <powermenu-panel-desktop-widget>)
 (scheme-desktop widgets power-menu verification <powermenu-verification-desktop-widget>)
 (scheme-desktop widgets dock <dock-desktop-widget>))
