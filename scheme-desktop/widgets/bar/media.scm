;;; (scheme-desktop widgets bar media) -- now playing
;;;
;;; The busiest module in the bar, and the best test of the reactive core: the
;;; label depends on a PLAYER, which may not exist; on that player's metadata;
;;; and on which player is first when several are running.  Each of those can
;;; change independently, and any of them can be absent.
;;;
;;; Hence the paths below rather than plain bindings.  MPRIS exposes `players'
;;; as a list and the metadata lives on the first ELEMENT, so the path is
;;
;;;   ("players" first-player "title")
;;
;;; which (scheme-toolkit reactive) walks null-safely and re-subscribes along as
;;; the list's first element changes.

(define-module (scheme-desktop widgets bar media)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit widget)
  #:use-module (scheme-toolkit astal)
  #:use-module (scheme-toolkit process)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:export (media-widget))

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

(define (prop obj name)
  (and obj (catch #t (lambda () (slot-ref obj (string->symbol name))) (lambda args #f))))

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

(define (media-widget)
  "A button showing what is playing, or an empty box when nothing is."
  (let* ((m (mpris))
         (players (create-binding m "players" 'mpris-players))
         ;; Reading the list is enough to know whether to build at all.
         (player (first-player (st-peek players))))
    (if (not player)
        (element <gtk-box> #:class "media")
        (let* ((title (create-binding-path m (list "players" first-player "title")
                                           'media-title))
               (artist (create-binding-path m (list "players" first-player "artist")
                                            'media-artist))
               (status (create-binding-path m (list "players" first-player "playback-status")
                                            'media-status))
               (text (create-computed
                      (lambda () (media-text (st-peek artist) (st-peek title)))))
               (icon (create-computed
                      (lambda () (playback-icon (st-peek status))))))
          (element <gtk-box>
                   #:orientation 'horizontal
                   #:class "media"
                   (element <gtk-button>
                            #:class "media-play"
                            #:on-clicked (lambda (b) (exec-async '("playerctl" "play-pause")))
                            (element <gtk-image> #:icon-name icon))
                   (element <gtk-label> #:label text #:class "media-label")
                   (element <gtk-button>
                            #:class "media-next"
                            #:on-clicked (lambda (b) (exec-async '("playerctl" "next")))
                            (element <gtk-image>
                                     #:icon-name "media-skip-forward-symbolic")))))))
