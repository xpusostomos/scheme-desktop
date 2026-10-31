;;; (scheme-desktop widgets bar media) -- now playing
;;;
;;; The busiest module in the bar, and the best test of the reactive core: the
;;; label depends on a PLAYER, which may not exist; on that player's metadata;
;;; and on which player is first when several are running.  Each of those can
;;; change independently, and any of them can be absent.
;;;
;;; Hence the paths below rather than plain bindings.  MPRIS exposes `players'
;;; as a list and the metadata lives on the first ELEMENT, so the path is
;;;
;;;   ("players" first-player "title")
;;;
;;; which (scheme-toolkit reactive) walks null-safely and re-subscribes along as
;;; the list's first element changes.
;;;
;;; ---------------------------------------------------------------------------
;;; WHY THE TREE IS SWAPPED AT RUNTIME, WHICH IS THE UNUSUAL PART
;;; ---------------------------------------------------------------------------
;;
;; THIS ITEM USED TO BE ABSENT FROM THE BAR PERMANENTLY, and the bug is worth
;; spelling out because the symptom pointed at the config.
;;
;; `widget-build' runs ONCE, when the bar is built.  This widget used to read the
;; player list there and return either a full player tree or a bare empty box --
;; and at startup the list is ALWAYS empty, because AstalMpris is populated
;; asynchronously.  So the bar got the empty box, and nothing ever looked again:
;; no media in the bar, ever, however much was playing.
;;
;; THE USER'S SYMPTOM WAS "the config lost my media widget", and it does look
;; like that: the item is invisible, the shell writes its in-memory layout back
;; to config.scm, and the file still lists `media' -- so the one thing that looks
;; like the cause is the one thing that is not.  Deleting config.scm only helped
;; by accident of timing.
;;
;; The other bar items never had this problem because they read a SERVICE object
;; that exists before its data does; this is the only one whose SHAPE depends on
;; data that arrives late.  So the shape is now decided by an effect instead of
;; at build time: `mpris-players-model' (see the mpris service) is an accessor
;; over the players that changes when a player appears or goes, and the effect
;; swaps between an empty box and the player tree to match.
;;
;; THE CHILDREN ARE REBUILT RATHER THAN SHOWN AND HIDDEN, because the metadata
;; bindings are PATHS rooted at "the first player": a path built while there is no
;; player subscribes to nothing, so a hidden-but-built tree would come back wrong.
;; The swap is rare -- a player appearing or leaving, not a track change.

(define-module (scheme-desktop widgets bar media)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit service-helpers)
  #:use-module (scheme-toolkit services mpris)
  #:use-module (scheme-toolkit app)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:export (<media-desktop-widget>))

(define-gi-imports "Gtk" "Box" "Image" "Label" "Button")

(define (first-player players)
  "The first of MPRIS's players, or #f.

Whichever player MPRIS lists first is the one to show.  The reference shells do
the same, rather than tracking a notion of the active player -- that needs its
own state and is still wrong half the time.

NOTE: do not put a bare double quote in a Scheme docstring.  One here -- around
the word active -- ended the string and left the rest of the sentence as code,
which surfaced as \"Unbound variable: active\" pointing at this line."
  (and (list? players) (pair? players) (car players)))

(define (playback-icon status)
  (if (eq? status 'playing)
      "media-playback-pause-symbolic"
      "media-playback-start-symbolic"))

(define (media-text artist title)
  "Artist and title on one line, tolerating either being missing.

Nothing at all without a title: a player that has not reported metadata yet
would otherwise show a bare dash."
  (cond
   ((not title) "")
   ((and (string? artist) (not (string=? artist "")))
    (format #f "~a -- ~a" artist title))
   (else title)))

(define (player-tree p)
  "The player controls bound to P, the player object itself.

BOUND TO THE PLAYER, NOT TO A PATH THROUGH THE LIST, and that is a fix rather
than a preference.  The obvious port of ags2-shell's shape is a binding path
rooted at the service --

    (create-binding-path m (list \"players\" first-player \"title\"))

-- and it reads #f for ever.  `Mpris.players' is a GList-valued property, so
through `slot-ref' it is a raw <foreign> pointer (the trap the service header
documents), `path-step' asks it for `title' on the way past, gets #f, and the
whole chain collapses.  MEASURED: that accessor answered #f while the player was
on the bus with a title, so the label came up empty in a bar item that otherwise
looked correct -- six children and a blank.

What does work is `create-binding' straight onto the player, which reads a real
property on a real object and subscribes to `notify::title' on it.  The player is
handed in by the caller, which is what `mpris-players-model' is for: the effect
that owns this tree re-runs when a player appears or goes, so the bindings are
always attached to a player that exists."
  (let* ((title (create-binding p "title" 'media-title))
         (artist (create-binding p "artist" 'media-artist))
         (status (create-binding p "playback-status" 'media-status))
         (text (create-computed
                (lambda () (media-text (st-peek artist) (st-peek title)))))
         (icon (create-computed
                (lambda () (playback-icon (st-peek status))))))
    (element <gtk-box>
             #:orientation 'horizontal
             #:class "media"
             (element <gtk-button>
                      #:class "media-play"
                      #:on-clicked (lambda (b) (mpris-toggle-active!))
                      (element <gtk-image> #:icon-name icon))
             (element <gtk-label> #:label text #:class "media-label")
             (element <gtk-button>
                      #:class "media-next"
                      #:on-clicked (lambda (b) (mpris-next-active!))
                      (element <gtk-image>
                               #:icon-name "media-skip-forward-symbolic")))))

;; THE CONTROLS GO THROUGH THE SERVICE, not through `playerctl'.
;;
;; The module used to shell out for both buttons.  Nothing was wrong with that on
;; this machine, but it is a subprocess per click for something the player is
;; already listening for, and it made the media item the one bar control that
;; needs an external program to exist.  `player-toggle!' and `player-next!' call
;; MPRIS's own `play-pause' and `next'.
(define (mpris-toggle-active!)
  (let ((p (mpris-active-player)))
    (when p (player-toggle! p))))

(define (mpris-next-active!)
  (let ((p (mpris-active-player)))
    (when p (player-next! p))))

(define-class <media-desktop-widget> (<bar-item-widget>))

(define-method (widget-build (w <media-desktop-widget>) output)
  "A button showing what is playing, appearing when something starts.

OUTPUT is the monitor's connector name, which this widget does not use
-- it takes it because every `widget-build' does.

THE BOX IS BUILT EMPTY AND FILLED BY AN EFFECT.  What is inside it is decided
now and re-decided whenever a player appears or goes -- see the note at the top
of this file for why a decision made here alone left the bar permanently
media-less."
  (let ((box (element <gtk-box> #:orientation 'horizontal #:class "media")))
    (let ((players (mpris-players-model)))
      (create-effect
       (lambda ()
         (let ((p (first-player (players))))
           (if (not p)
               ;; Nothing playing: an empty box, which is how every absent
               ;; service in this bar looks -- no placeholder, no padding.
               (clear-box! box)
               ;; Something playing.  The tree is built only when it is not
               ;; already there: the effect re-runs on every track change (the
               ;; model's version moves), and rebuilding then would rebuild the
               ;; bindings for nothing.
               (when (null? (box-children box))
                 (add-child! box (player-tree p) #f)))))
       #:immediate #t))
    box))

(define (box-children box)
  "BOX's children, as a list -- the test for whether the player tree is in place."
  (let loop ((c (gtk-widget-get-first-child box)) (acc '()))
    (if c
        (loop (gtk-widget-get-next-sibling c) (cons c acc))
        (reverse acc))))
