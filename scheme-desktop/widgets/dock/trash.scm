;;; (scheme-desktop widgets dock trash) -- the dock's trash: whether it has
;;; anything in it, and opening it
;;;
;;; PORTED FROM ags2-shell `widget/Dock/components/Trash.tsx'.  An icon at the end
;;; of the dock, full or empty, kept current by a watch on the trash, which a
;;; click opens -- or brings forward, when a window is already showing it.
;;;
;;; THE LOCAL TRASH, `$XDG_DATA_HOME/Trash/files', where ags2-shell watches
;;; `trash:///'.  That URI is GVFS's, and covers the trash folders of other
;;; drives too; this is the one a desktop's own deletions go to, watched with the
;;; toolkit's `monitor-directory' and no GVFS in the way.  Opening it is still
;;; `trash:///', in whatever the user's file manager is, as ags2-shell does.
;;;
;;; ONE WATCH FOR THE WHOLE SHELL, shared by every monitor's dock and dropped when
;;; the last of them lets go -- ags2-shell's `acquire_trash_watcher' and its count.

(define-module (scheme-desktop widgets dock trash)
  #:use-module (scheme-toolkit reactive)
  #:use-module (scheme-toolkit time)
  #:use-module (scheme-toolkit process)
  #:use-module ((scheme-toolkit file) #:select (monitor-directory mkdir-p))
  #:use-module (scheme-desktop wm)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (trash-has-items acquire-trash-watcher! open-trash!
            trash-icon-name))

;; ags2-shell's `icons.trash_detailed'.
(define (trash-icon-name full?) (if full? "user-trash-full" "user-trash"))

(define (trash-files-directory)
  (string-append (or (let ((d (getenv "XDG_DATA_HOME")))
                       (and d (not (string-null? d)) d))
                     (string-append (or (getenv "HOME") "") "/.local/share"))
                 "/Trash/files"))

;; WHETHER THERE IS ANYTHING IN IT, as an accessor, so the icon follows it.
(define-values (trash-has-items set-trash-has-items!) (create-state #f))

(define (refresh-trash!)
  "Look in the trash again.  The answer is whether it has ANY entry -- the icon
is full or empty, and how many there are is not something it shows."
  (set-trash-has-items!
   (pair? (filter (lambda (n) (not (member n '("." ".."))))
                  (or (catch #t (lambda () (scandir (trash-files-directory)))
                             (lambda a #f))
                      '())))))

;;; ---------------------------------------------------------------------------
;;; The watch
;;; ---------------------------------------------------------------------------

(define %users 0)
(define %stop #f)
(define %pending #f)

(define (schedule-refresh!)
  ;; A BURST BECOMES ONE LOOK.  Emptying the trash deletes every entry, one event
  ;; each; ags2-shell debounces by 120ms, and so does this.
  (unless %pending
    (set! %pending #t)
    (timeout 120 (lambda () (set! %pending #f) (refresh-trash!)))))

(define (acquire-trash-watcher!)
  "Watch the trash, and answer the procedure that stops watching.

COUNTED: the first caller starts the watch and the last to release stops it, so
two monitors' docks share one.

THE DIRECTORY IS MADE IF IT IS NOT THERE -- it is the freedesktop trash, which a
file manager creates on the first deletion -- because a watch on a directory
that does not exist hears nothing, so the first file deleted would never show."
  (set! %users (+ %users 1))
  (when (= %users 1)
    (catch #t (lambda () (mkdir-p (trash-files-directory))) (lambda a #f))
    (refresh-trash!)
    (set! %stop (catch #t
                  (lambda () (monitor-directory (trash-files-directory)
                                                (lambda (kind path) (schedule-refresh!))))
                  (lambda a #f))))
  (let ((released #f))
    (lambda ()
      (unless released
        (set! released #t)
        (set! %users (max 0 (- %users 1)))
        (when (and (zero? %users) %stop)
          (catch #t %stop (lambda a #f))
          (set! %stop #f))))))

;;; ---------------------------------------------------------------------------
;;; Opening it
;;; ---------------------------------------------------------------------------

(define (open-trash!)
  "Bring forward a window already showing the trash, or open it.

ags2-shell's `open_or_focus_trash': a click on the trash is not a request for a
SECOND window of it.  A window titled \"Trash\" is taken to be one -- which is
what file managers title it.  ags2-shell also checks that the window belongs to
the default file manager and moves it to the current workspace first; focusing
it here goes to its workspace instead, which `wm-focus-client!' already does."
  (let ((open (find (lambda (c) (string=? (wm-client-title c) "Trash"))
                    (catch #t (lambda () (wm-clients (wm))) (lambda a '())))))
    (if open
        (wm-focus-client! (wm) open)
        ;; The user's file manager, for `trash:///': GIO's default handler for
        ;; the URI, which is what ags2-shell's `app_info_launch_default_for_uri'
        ;; reaches.
        (exec-async '("gio" "open" "trash:///")))))
