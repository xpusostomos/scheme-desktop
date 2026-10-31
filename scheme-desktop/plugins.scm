;;; (scheme-desktop plugins) -- the launcher's search sources
;;;
;;; The framework is (scheme-toolkit launcher); these are THIS shell's decisions
;;; about what to search.  Colorshell's seven are the parity target, and each
;;; here is small on purpose: a plugin is a prefix, a name, and a procedure that
;;; pushes results.
;;;
;;; Ordering matters and is not alphabetical.  The applications plugin has no
;;; prefix, so it claims every query; the prefixed ones are tried first so that
;;; `?linux' is a web search rather than an application named "?linux".
;;;
;;; Nothing here blocks.  A plugin that would have to wait (clipboard history is
;;; a subprocess, wallpapers a directory walk) pushes what it has and can push
;;; more later -- the launcher's handler signature exists for exactly that.

(define-module (scheme-desktop plugins)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-toolkit launcher)
  #:use-module (scheme-toolkit service-helpers)
  #:use-module (scheme-toolkit process)
  #:use-module (scheme-toolkit file)
  #:use-module (scheme-toolkit result)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (install-default-plugins! uninstall-plugins!
            web-search-engines url-encode))

;;; ---------------------------------------------------------------------------
;;; Applications
;;; ---------------------------------------------------------------------------

;; AstalApps: the applications database.  Note the constructor is
;; astal_apps_apps_new, NOT a get_default -- there is no default instance, which
;; is worth knowing because every other Astal namespace has one.
(define %apps-db #f)

(define (apps-db)
  "The applications database, or #f when the namespace is unavailable.

Built once and kept: constructing it scans every .desktop file, so doing that
per keystroke would make the launcher the slowest thing on the desktop."
  (unless %apps-db
    (set! %apps-db
          (catch #t
            (lambda ()
              (g-irepository-require "AstalApps" #:version "0.1")
              (gi-import-by-name "AstalApps" "Apps")
              (gi-import-by-name "AstalApps" "Application")
              (make <astal-apps-apps>))
            (lambda (key . args)
              (format (current-error-port)
                      "scheme-desktop: launcher: no application database: ~a~%" key)
              #f))))
  %apps-db)

;; The Application objects carry their own `launch', which is better than
;; guessing an executable: a desktop file's Exec line has field codes (%U, %f)
;; that must be stripped, and launch does that.
(define (launch-application app)
  (catch #t
    (lambda () (launch app))
    (lambda (key . args)
      (format (current-error-port)
              "scheme-desktop: launcher: cannot launch ~s: ~a~%"
              (catch #t (lambda () (slot-ref app 'name)) (lambda a "?")) key)
      #f)))

(define (apps-plugin)
  (make-plugin
   "Applications"
   (lambda (query push)
     (let ((db (apps-db)))
       (when db
         ;; fuzzy_query, not "fuzzy-search" -- the latter does not exist, and
         ;; inventing a name is a runtime "unbound variable" inside the plugin's
         ;; catch, which shows up as a launcher that simply finds nothing.
         (for-each
          (lambda (app)
            (push (make-result
                   (catch #t (lambda () (slot-ref app 'name)) (lambda a query))
                   #:description (catch #t (lambda () (slot-ref app 'description))
                                       (lambda a #f))
                   #:icon (catch #t (lambda () (slot-ref app 'icon-name))
                                 (lambda a #f))
                   ;; The key, not the name: it is stable across locale and
                   ;; rename, which is what frecency needs.
                   #:id (catch #t (lambda () (slot-ref app 'key))
                               (lambda a #f))
                   #:action (lambda () (launch-application app)))))
          ;; fuzzy_query answers #f -- not '() -- when nothing matches, and a
          ;; for-each over #f is an error.  Normalising here rather than at each
          ;; use is what keeps a no-match search from being reported as a
          ;; broken plugin.
          (let ((hits (catch #t (lambda () (fuzzy-query db query))
                             (lambda args '()))))
            (if (list? hits) hits '()))))))))

;;; ---------------------------------------------------------------------------
;;; Web search
;;; ---------------------------------------------------------------------------

(define web-search-engines
  '(("duckduckgo" . "https://duckduckgo.com/?q=")
    ("google" . "https://google.com/search?q=")
    ("yahoo" . "https://search.yahoo.com/search?p=")))

;; Percent-encoding, because a query with a space or an ampersand in it must
;; reach the search engine intact -- pasting "rock & roll" unencoded truncates
;; the search at the ampersand.
(define (url-encode s)
  (let loop ((chars (string->list s)) (out '()))
    (cond ((null? chars) (list->string (reverse! out)))
          (else
           (let ((c (car chars)))
             (if (or (char-alphabetic? c) (char-numeric? c)
                     (memv c '(#\- #\_ #\. #\~)))
                 (loop (cdr chars) (cons c out))
                 ;; Reverse the escape before consing: building the list back
                 ;; to front means each multi-character piece has to be added
                 ;; in its final order, or %20 comes out as 02%.
                 (loop (cdr chars)
                       (append (reverse (string->list
                                         (format #f "%~2,'0X" (char->integer c))))
                               out))))))))

(define (web-search-plugin)
  (make-plugin
   "Web Search"
   (lambda (query push)
     (let ((engine (cdr (assoc "google" web-search-engines))))
       (push (make-result
              (if (string-null? query) "Type your search..." query)
              #:description "Search the web"
              #:icon "system-search-symbolic"
              #:action (lambda ()
                         (exec-async (list "xdg-open"
                                           (string-append engine (url-encode query)))))))))
   #:prefix "?" #:prioritize? #t #:icon "system-search-symbolic"))

;;; ---------------------------------------------------------------------------
;;; Run a command
;;; ---------------------------------------------------------------------------

(define (shell-plugin)
  (make-plugin
   "Run Command"
   (lambda (query push)
     (when (not (string-null? (string-trim query)))
       (push (make-result
              query
              #:description "Run in a shell"
              #:icon "utilities-terminal-symbolic"
              #:id (string-append "cmd:" query)
              #:action (lambda ()
                         (exec-async (list "sh" "-c" query)))))))
   #:prefix "!" #:prioritize? #t #:icon "utilities-terminal-symbolic"))

;;; ---------------------------------------------------------------------------
;;; Clipboard history (cliphist)
;;; ---------------------------------------------------------------------------

(define (cliphist-available?)
  (catch #t
    (lambda ()
      (let* ((p (open-input-pipe "command -v cliphist 2>/dev/null"))
             (out (get-string-all p)))
        (close-pipe p)
        (and out (not (string-null? (string-trim out))))))
    (lambda args #f)))

(define (clipboard-entries)
  "The clipboard history, newest first, as (ID . TEXT) pairs.

`cliphist list' prints `<id>\t<text>', where the text may be an image
descriptor rather than anything readable.  Only text entries are offered --
running an image descriptor as a command is not a clipboard paste."
  (if (not (cliphist-available?))
      '()
      (catch #t
        (lambda ()
          (let* ((p (open-input-pipe "cliphist list 2>/dev/null"))
                 (out (get-string-all p)))
            (close-pipe p)
            (filter-map
             (lambda (line)
               (let ((tab (string-index line #\tab)))
                 (and tab
                      (let ((id (substring line 0 tab))
                            (text (substring line (+ tab 1) (string-length line))))
                        ;; An image entry is "[[ binary data ... ]]".
                        (and (not (string-prefix? "[[" text))
                             (cons id text))))))
             (string-split (or out "") #\newline))))
        (lambda args '()))))

(define (clipboard-plugin)
  (make-plugin
   "Clipboard"
   (lambda (query push)
     (for-each
      (lambda (entry)
        (let ((id (car entry)) (text (cdr entry)))
          (when (or (string-null? query)
                    (string-contains-ci text query))
            (push (make-result
                   text
                   #:description "Copy to clipboard"
                   #:icon "edit-paste-symbolic"
                   #:action (lambda ()
                              (exec-async
                               (list "sh" "-c"
                                     (format #f "cliphist decode ~a | wl-copy" id)))))))))
      ;; take on an EMPTY list is an error in srfi-1, and an empty history is
      ;; the normal state on a machine without cliphist -- so the guard is not
      ;; defensive padding, it is the common case.
      (let ((entries (clipboard-entries)))
        (take entries (min 20 (length entries))))))
   #:prefix ">" #:prioritize? #t #:icon "edit-paste-symbolic"))

;;; ---------------------------------------------------------------------------
;;; Installation
;;; ---------------------------------------------------------------------------

(define (install-default-plugins!)
  "Register this shell's plugins.  Idempotent: registering the same prefix twice
replaces rather than duplicates, so re-evaluating in a live shell is safe."
  (for-each register-plugin!
            (list (apps-plugin)
                  (web-search-plugin)
                  (shell-plugin)
                  (clipboard-plugin)))
  (length (plugins)))

(define (uninstall-plugins!)
  (clear-plugins!))
