;;; (scheme-desktop widgets power-menu verification) -- "are you sure?"
;;;
;;; PORTED FROM ags2-shell `widget/PowerMenu/index.tsx': `request_action_
;;; confirmation' and `VerificationModal'.  The four actions, what each is called
;;; and what each runs live here rather than in the menu, because this is the
;;; widget that runs them.
;;;
;;; **NOTHING IS DONE WITHOUT ASKING.**  The menu's buttons do not shut the
;;; machine down; they set an action and open this window.  That is the whole
;;; reason it exists -- a bar button is one click away from the thing a user
;;; least wants to do by accident.
;;;
;;; **A FAILED ACTION COMES BACK HERE**, in the window that asked, rather than in
;;; a log nobody is reading: the command is started, and if it exits non-zero the
;;; window says so and stays open.  That is ags2-shell's behaviour
;;; (`attempt_async', then `set_action_error' and show again), and it is worth
;;; copying -- a shutdown button that silently does nothing is worse than one
;;; that says why.
;;;
;;; It is `subprocess' with `#:on-exit' and not `exec-async', and that is not a
;;; preference: `exec-async' answers whether the command STARTED and never its
;;; exit status, so the failure half of this widget cannot be built on it.
;;; `run-command' does report failure but BLOCKS, and blocking the main loop on
;;; `systemctl' is a shell that freezes when the command hangs.

(define-module (scheme-desktop widgets power-menu verification)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit process)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  ;; `let-values', for the window's three `create-state' pairs.  It is NOT core
  ;; Guile, and without this the shell DID NOT START: the registry builds every
  ;; window at startup, so an unbound name here is "Unbound variable: let-values"
  ;; before the first frame.  `style.scm' imports it the same way.
  #:use-module (srfi srfi-11)
  #:export (<powermenu-verification-desktop-widget>
            power-actions power-action-title power-action-icon
            request-power-action!))

(define-gi-imports "Gtk" "Box" "Label" "Button")

;;; ---------------------------------------------------------------------------
;;; The four actions
;;; ---------------------------------------------------------------------------

;; THE ORDER IS ags2-shell's, and it is the order both layouts are written in: a
;; `line' is one row of the four, a `box' is (shutdown logout) over (reboot
;; sleep).
(define power-actions '(shutdown logout reboot sleep))

;; `action_titles', verbatim.
(define (power-action-title action)
  (case action
    ((sleep) "Sleep")
    ((reboot) "Reboot")
    ((logout) "Log Out")
    ((shutdown) "Shutdown")
    (else "")))

;; `icons.powermenu', verbatim -- including that sleep is a moon rather than a
;; "suspend" glyph, which is what ags2-shell ships.
(define (power-action-icon action)
  (case action
    ((sleep) "weather-clear-night-symbolic")
    ((reboot) "system-reboot-symbolic")
    ((logout) "system-log-out-symbolic")
    ((shutdown) "system-shutdown-symbolic")
    (else "")))

(define (power-action-command w action)
  "What ACTION runs, from this widget's own options.

THE COMMANDS ARE OPTIONS AND NOT CONSTANTS, which is ags2-shell's arrangement
(`options.powermenu[action]'): what \"log out\" means is a fact about the
session and not about the shell -- `systemctl' here, a compositor dispatch
there.  #f for an action this shell does not have, which the caller has already
excluded."
  (case action
    ((sleep) (powermenu-sleep-command w))
    ((reboot) (powermenu-reboot-command w))
    ((logout) (powermenu-logout-command w))
    ((shutdown) (powermenu-shutdown-command w))
    (else #f)))

;;; ---------------------------------------------------------------------------
;;; The widget
;;; ---------------------------------------------------------------------------

(define-class <powermenu-verification-desktop-widget> (<popup-widget>)
  ;; THE FOUR COMMANDS.  They belong to the widget that RUNS them -- this shell's
  ;; rule is that the thing reading an option declares it -- so they are here
  ;; rather than on the panel, even though a user will think of them as the power
  ;; menu's.
  ;;
  ;; The defaults are ags2-shell's `options.powermenu', verbatim, down to the
  ;; dispatcher in the logout command: `hyprctl dispatch ...' is a command line,
  ;; and what it dispatches is this session's business rather than the shell's.
  (shutdown-command #:init-value "shutdown now"
                    #:init-keyword #:shutdown-command
                    #:accessor powermenu-shutdown-command
                    #:config '(string) #:label "Command for Shutdown")
  (reboot-command #:init-value "systemctl reboot"
                  #:init-keyword #:reboot-command
                  #:accessor powermenu-reboot-command
                  #:config '(string) #:label "Command for Reboot")
  (logout-command #:init-value "hyprctl dispatch 'hl.dsp.exit()'"
                  #:init-keyword #:logout-command
                  #:accessor powermenu-logout-command
                  #:config '(string) #:label "Command for Log Out")
  (sleep-command #:init-value "systemctl suspend"
                 #:init-keyword #:sleep-command
                 #:accessor powermenu-sleep-command
                 #:config '(string) #:label "Command for Sleep")

  ;; WHICH ACTION IS BEING ASKED ABOUT, WHETHER ONE IS RUNNING, AND WHAT WENT
  ;; WRONG.  `create-state' rather than slots, because the labels follow them --
  ;; but the state is made with the WINDOW, so these three hold the accessor and
  ;; the setter the window's scope gave us.  ags2-shell's `control' is the same
  ;; three pieces.
  (selected #:init-value #f #:accessor powermenu-verification-selected
            #:setter powermenu-verification-selected-set!)
  (pending #:init-value #f #:accessor powermenu-verification-pending
           #:setter powermenu-verification-pending-set!)
  (error-text #:init-value #f #:accessor powermenu-verification-error
              #:setter powermenu-verification-error-set!)
  ;; The Cancel button, so that the focus can be put on it when the window
  ;; appears -- ags2-shell's `cancel_button', grabbed in `onNotifyVisible'.
  (cancel #:init-value #f #:accessor powermenu-verification-cancel
          #:setter powermenu-verification-cancel-set!)
  ;; Built once and remembered -- see (scheme-desktop widgets date-menu) for what
  ;; building on every call costs.
  (window #:init-value #f #:accessor powermenu-verification-window
          #:setter powermenu-verification-window-set!))

;; The WIDGET is `powermenu-verification' and the WINDOW is `verification', which
;; is ags2-shell's name for it and what the stylesheet says.
(define-method (widget-window-name (w <powermenu-verification-desktop-widget>))
  "verification")

;;; ---------------------------------------------------------------------------
;;; The tree
;;; ---------------------------------------------------------------------------
;;
;; IT IS THREE PROCEDURES AND NOT ONE NESTED EXPRESSION, which is a correction:
;; the first version built the whole tree inside `widget-window', six levels
;; deep, and the closing brackets were counted wrong twice -- once leaving two
;; forms open (the syntax checker caught that) and once leaving the `let' with no
;; body at all, which is BALANCED AND STILL WRONG, so the checker passed it and
;; only compiling it in the shell found it.  AGENTS.md says to stop and use a
;; tool rather than squint; both tools said yes and no, and the real answer is
;; that a six-deep tree is not worth reading.

(define (modal-content w selected pending error-text)
  "The modal's tree: a title, a line of explanation or of error, and two buttons.

TITLE is the action's name; DETAIL is `Confirm action', or what went wrong when
something did; both buttons are insensitive while an action runs -- ags2-shell's
`action_pending', because a `systemctl' that has not answered must not be asked
for a second shutdown."
  (let ((title (create-computed
                (lambda ()
                  (let ((a (selected)))
                    (if a (power-action-title a) "")))))
        (detail (create-computed
                 (lambda ()
                   (let ((e (error-text)))
                     (if (and e (not (string=? e "")))
                         e
                         "Confirm action")))))
        (idle (create-computed (lambda () (not (pending))))))
    (element <gtk-box> #:class "verification" #:orientation 'vertical
      (element <gtk-box> #:class "text-box" #:orientation 'vertical
        (element <gtk-label> #:class "title" #:label title)
        (element <gtk-label> #:class "desc" #:label detail))
      (element <gtk-box> #:class "buttons horizontal" #:orientation 'horizontal
               #:homogeneous #t #:valign 'end #:vexpand #t
        (element <gtk-button> #:sensitive idle
                 #:setup (lambda (b) (powermenu-verification-cancel-set! w b))
                 #:on-clicked (lambda (b) (widget-hide! w))
          (element <gtk-label> #:label "Cancel"))
        (element <gtk-button> #:sensitive idle
                 #:on-clicked (lambda (b) (confirm! w))
          (element <gtk-label> #:label "Confirm"))))))

(define (watch-modal! w win)
  "Put the focus on Cancel when the window appears.

ags2-shell does it in `onNotifyVisible', and the reason is worth keeping: a modal
that opens with the destructive button focused is a modal waiting to be
mis-keyed.  It takes the keyboard (`#:keymode 'exclusive'), so Escape closes it
too -- this is about which button the *Enter* key would press."
  (connect-signal! win "notify::visible"
                   (lambda (window . rest)
                     (when (catch #t (lambda () (slot-ref window 'visible))
                                   (lambda a #f))
                       (let ((cancel (powermenu-verification-cancel w)))
                         (when cancel
                           (catch #t
                                  (lambda () (gtk-widget-grab-focus cancel))
                                  (lambda a #f))))))))

(define-method (widget-window (w <powermenu-verification-desktop-widget>))
  "The confirm window: a title, a line of explanation or of error, two buttons.

`#:position 'center' with `#:layer 'overlay', which is the overview's shape and
not the panels': this is a MODAL rather than a panel opened from the bar, so it is
centred on the screen and sits above everything instead of following a button."
  (unless (powermenu-verification-window w)
    (let ((win (create-window-root
                (lambda ()
                  (let-values (((selected set-selected!) (create-state #f))
                               ((pending set-pending!) (create-state #f))
                               ((error-text set-error!) (create-state "")))
                    (powermenu-verification-selected-set! w selected)
                    (powermenu-verification-pending-set! w set-pending!)
                    (powermenu-verification-error-set! w set-error!)
                    (popup-window (widget-window-name w)
                                  #:position 'center
                                  #:layer 'overlay
                                  #:keymode 'exclusive
                                  #:transition 'crossfade
                                  (modal-content w selected pending error-text)))))))
      (powermenu-verification-window-set! w win)
      (watch-modal! w win)))
  (powermenu-verification-window w))

;;; ---------------------------------------------------------------------------
;;; Asking, and doing
;;; ---------------------------------------------------------------------------

(define (request-power-action! action)
  "Ask the user to confirm ACTION: set it, clear any error, and open the window.

THE GUARD IS ags2-shell's: nothing happens while the window is already open or an
action is running, so a second click cannot re-answer for the first.  A keybinding
may call this with anything, which is why an action outside the four is ignored
rather than run."
  (let ((w (desktop-widget-required <powermenu-verification-desktop-widget>)))
    (when (and (member action power-actions)
               (not (catch #t (lambda () (widget-visible? w)) (lambda a #f)))
               (not ((powermenu-verification-pending w))))
      ((powermenu-verification-selected w) action)
      ((powermenu-verification-error w) "")
      (widget-show! w))
    #t))

(define (fail! w action)
  "Tell the user ACTION did not happen, in the window that asked for it."
  (catch #t
    (lambda ()
      (log-error (format #f "~a did not run" action) "powermenu")
      ((powermenu-verification-error w)
       (format #f "Could not ~a. Check the shell log." action))
      (widget-show! w))
    (lambda a #f))
  #f)

(define (confirm! w)
  "Run the selected action.  If it fails, say so in the window that asked.

THE MENU IS HIDDEN FIRST, as ags2-shell does, and this window with it: what
follows is either the session ending or an error to read in a window of its own,
and neither wants the menu still on screen behind it.

The command's own words go to the log as they arrive, and the exit status decides
whether the user is told -- `Could not shutdown. Check the shell log.' is
ags2-shell's sentence with the action's own name in it."
  (let ((action ((powermenu-verification-selected w))))
    (when action
      ((powermenu-verification-pending w) #t)
      (catch #t
        (lambda ()
          (catch #t (lambda () (widget-hide! (desktop-widget-required '(scheme-desktop widgets power-menu window <powermenu-panel-desktop-widget>))))
                    (lambda a #f))
          (widget-hide! w))
        (lambda a #f))
      (let ((started?
             (subprocess (power-action-command w action)
                         #:stderr (lambda (line)
                                    (log-error line (format #f "powermenu.~a" action)))
                         #:on-exit (lambda (code)
                                     ((powermenu-verification-pending w) #f)
                                     (unless (zero? code)
                                       (fail! w action))))))
        ;; A COMMAND THAT COULD NOT BE STARTED AT ALL -- a binary that is not
        ;; installed, the likeliest failure of the four -- reaches no exit
        ;; status, so this is the other half of the same report.
        (unless started?
          ((powermenu-verification-pending w) #f)
          (fail! w action))))
    #t))
