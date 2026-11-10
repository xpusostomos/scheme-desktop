;;; (scheme-desktop manifest) -- which widgets exist, and plugins that add more
;;;
;;; EVERY WIDGET COMES FROM A MANIFEST: a `widgets.scm' at the top of a tree,
;;; listing what that tree provides as `(module ... <class>)' entries.
;;; scheme-desktop has one, and every plugin has one.  It is READ, never
;;; evaluated, so finding out what a plugin offers runs none of its code.
;;;
;;; PLUGINS LIVE IN $XDG_DATA_HOME/scheme-desktop/plugins/NAME -- not the cache
;;; directory, which a user or a cleaning tool is entitled to empty, and which
;;; would uninstall them.  Each plugin directory is put on the load path at
;;; startup, so its modules resolve like scheme-desktop's own.
;;;
;;; THE OPERATIONS, each a function from a config to a config, applied either to
;;; the running shell or to the file:
;;;
;;;   (plugin-install! url)    clone it, then enable every widget it has
;;;   (plugin-enable! name)    every widget in NAME, `widget-enable!'d in turn
;;;   (plugin-disable! name)   every widget in NAME, `widget-disable!'d
;;;   (plugin-remove! name)    disable it, then delete its directory
;;;
;;; THE FIRST RUN IS THE SAME OPERATION.  With no config.scm, every built-in
;;; widget is enabled, in manifest order, into an empty config, and the result is
;;; written -- so what the shell starts with is decided by the widgets' own
;;; `widget-enable!' methods, and there is no second default list to drift.

(define-module (scheme-desktop manifest)
  #:use-module (scheme-toolkit app)
  ;; TWO DIFFERENT `config-ref`s, both 2-argument, both plausible-looking:
  ;; `(scheme-toolkit config)`'s takes (NAME OPTION) and reads a live option,
  ;; `(scheme-toolkit config-splice)`'s takes (CONFIG PATH) and walks a config
  ;; datum.  THIS MODULE WANTS THE LATTER (see `config-root-widgets'), and
  ;; leaving the choice to import order is how a call silently starts reading
  ;; the wrong thing when a `use-module' line moves.  Hiding the one it does not
  ;; want makes the choice the file's, and the compiler's.
  #:use-module ((scheme-toolkit config) #:hide (config-ref))
  #:use-module (scheme-toolkit config-splice)
  #:use-module ((scheme-toolkit file) #:select (mkdir-p))
  #:use-module (scheme-desktop splice)
  #:use-module (scheme-desktop config)
  #:use-module (oop goops)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (plugins-directory plugin-directories plugin-names
            builtin-manifest plugin-manifest
            add-plugin-load-paths!
            read-config-datum write-config-datum! ensure-config!
            config-root-widgets
            plugin-install! plugin-enable! plugin-disable! plugin-remove!
            plugin-clone! plugin-delete! plugin-update!
            enable-entries disable-entries))

;;; ---------------------------------------------------------------------------
;;; Where things are
;;; ---------------------------------------------------------------------------

(define (plugins-directory)
  "Where plugins are installed: $XDG_DATA_HOME/scheme-desktop/plugins."
  (string-append (or (let ((d (getenv "XDG_DATA_HOME")))
                       (and d (not (string-null? d)) d))
                     (string-append (or (getenv "HOME") "") "/.local/share"))
                 "/scheme-desktop/plugins"))

(define (plugin-directories)
  "Every installed plugin's directory: those with a `widgets.scm' at the top."
  (let ((root (plugins-directory)))
    (map (lambda (n) (string-append root "/" n))
         (plugin-names))))

(define (plugin-names)
  "The installed plugins' names, sorted."
  (let ((root (plugins-directory)))
    (sort (filter (lambda (n)
                    (and (not (member n '("." "..")))
                         (file-exists? (string-append root "/" n "/widgets.scm"))))
                  (or (catch #t (lambda () (scandir root)) (lambda a #f)) '()))
          string<?)))

(define (scheme-desktop-root)
  "The directory scheme-desktop itself is in: the one holding its `widgets.scm'
manifest and its `scheme-desktop/' module tree.  Found from where THIS module
was loaded, so a checkout and an install both work."
  (let ((me (%search-load-path "scheme-desktop/manifest.scm")))
    (and me (dirname (dirname me)))))

;;; ---------------------------------------------------------------------------
;;; Manifests
;;; ---------------------------------------------------------------------------

(define (read-manifest path)
  "The entries in the manifest at PATH, or '() -- with a word on stderr -- when it
cannot be read.

A LEADING QUOTE IS ALLOWED: the file is data, and `'(...)' is how a list is
written by hand in Scheme even where nothing evaluates it."
  (catch #t
    (lambda ()
      (let ((datum (call-with-input-file path read)))
        (let ((entries (if (and (pair? datum) (eq? (car datum) 'quote))
                           (cadr datum)
                           datum)))
          (if (list? entries) entries '()))))
    (lambda (key . args)
      (format (current-error-port) "scheme-desktop: cannot read ~a: ~a ~s~%" path key args)
      '())))

(define (builtin-manifest)
  "scheme-desktop's own widgets, in default order."
  (let ((root (scheme-desktop-root)))
    (if root (read-manifest (string-append root "/widgets.scm")) '())))

(define (plugin-manifest name)
  "The widgets plugin NAME provides."
  (read-manifest (string-append (plugins-directory) "/" name "/widgets.scm")))

(define (add-plugin-load-paths!)
  "Put every installed plugin's directory on the load path, so its modules
resolve -- `(scheme-widget-demo widgets x)' from the plugin `scheme-widget-demo'.

AT THE FRONT, as a launcher's own tree is: a plugin's modules are found before
anything with the same name installed system-wide."
  (for-each (lambda (dir)
              (unless (member dir %load-path)
                (set! %load-path (cons dir %load-path))))
            (plugin-directories))
  (plugin-directories))

;;; ---------------------------------------------------------------------------
;;; Enabling and disabling, on a config list
;;; ---------------------------------------------------------------------------

(define (fold-entries proc entries config)
  "CONFIG with PROC -- `widget-enable!' or `widget-disable!' -- applied for each
ENTRY in turn.  An entry whose class cannot be loaded is reported and skipped:
one broken widget in a plugin must not stop the rest of it."
  (fold (lambda (entry cfg)
          (catch #t
            (lambda () (proc (widget-prototype entry) cfg))
            (lambda (key . args)
              (format (current-error-port)
                      "scheme-desktop: cannot enable or disable ~s: ~a ~s~%" entry key args)
              cfg)))
        config
        entries))

(define (enable-entries entries config) (fold-entries widget-enable! entries config))
(define (disable-entries entries config) (fold-entries widget-disable! entries config))

;;; ---------------------------------------------------------------------------
;;; The file
;;; ---------------------------------------------------------------------------

(define (read-config-datum)
  "config.scm's contents, or #f when there is no file."
  (and (file-exists? shell-config-file)
       (catch #t
         (lambda () (call-with-input-file shell-config-file read))
         (lambda args #f))))

(define (write-config-datum! datum)
  "Write DATUM as config.scm, through a temporary file and a rename."
  (let ((tmp (string-append shell-config-file ".tmp")))
    (mkdir-p (dirname shell-config-file))
    (call-with-output-file tmp
      (lambda (port)
        (display ";; scheme-desktop config.  Each widget is named by its module and\n" port)
        (display ";; class; the root lists which are live, the bar's layout which go\n" port)
        (display ";; where.  Rewritten when the shell changes an option.\n" port)
        ;; One line per widget, as the config engine writes it -- see there.
        (write-config-lines datum port)))
    (rename-file tmp shell-config-file)
    datum))

(define (ensure-config!)
  "The config, writing a first one when there is none.

THE FIRST ONE IS EVERY BUILT-IN WIDGET ENABLED, then every installed plugin's,
into nothing -- see the header."
  (or (read-config-datum)
      (write-config-datum!
       (fold (lambda (name cfg) (enable-entries (plugin-manifest name) cfg))
             (enable-entries (builtin-manifest) '())
             (plugin-names)))))

(define (config-root-widgets datum)
  "The root's list of live widgets in DATUM."
  (config-ref datum root-widgets-path))

;;; ---------------------------------------------------------------------------
;;; Applying a change: to the running shell, or to the file
;;; ---------------------------------------------------------------------------

(define (running-shell?)
  "Whether this code is running IN the shell, which has a root and widgets."
  (and (desktop-widget-named 'root) #t))

(define (apply-to-running-shell! change)
  "Apply CHANGE -- a config-to-config function -- to the shell this runs in.

IN TWO STEPS, AND THE ORDER IS THE POINT.  The root's list first, synced at
once, so that every widget the change names EXISTS; then the rest of the config.
The other way round, the bar would be told to show widgets that are not yet
there, and it drops names no live widget has -- that is its job -- so a widget
enabled into the bar would come up enabled and not in it."
  (let* ((before (widget-config-datum))
         (after (change before))
         (root (desktop-widget-required 'root)))
    (root-widgets-set! root (config-root-widgets after))
    (root-sync! root)
    (widgets-registry-changed!)
    (apply-widget-config-datum! after)
    (widget-config-save!)
    after))

(define (apply-change! change)
  "Apply CHANGE to the running shell if this is it, otherwise to config.scm."
  (if (running-shell?)
      (apply-to-running-shell! change)
      (write-config-datum! (change (or (read-config-datum) '())))))

;;; ---------------------------------------------------------------------------
;;; The operations
;;; ---------------------------------------------------------------------------

(define (require-plugin name)
  (unless (member name (plugin-names))
    (error (format #f "no plugin called ~a is installed (have: ~a)"
                   name (string-join (plugin-names) ", "))))
  name)

(define (plugin-enable! name)
  "Enable every widget plugin NAME provides."
  (require-plugin name)
  (add-plugin-load-paths!)
  (apply-change! (lambda (cfg) (enable-entries (plugin-manifest name) cfg)))
  #t)

(define (plugin-disable! name)
  "Disable every widget plugin NAME provides.  It stays installed."
  (require-plugin name)
  (add-plugin-load-paths!)
  (apply-change! (lambda (cfg) (disable-entries (plugin-manifest name) cfg)))
  #t)

(define (url-plugin-name url)
  "The plugin name a URL gives: its last component, without `.git'."
  (let* ((trimmed (string-trim-right url #\/))
         (base (last (string-split trimmed #\/))))
    (if (string-suffix? ".git" base) (string-drop-right base 4) base)))

(define (plugin-install! url)
  "Clone URL into the plugins directory, then enable everything in it."
  (let ((name (plugin-clone! url)))
    (plugin-enable! name)
    name))

(define (plugin-clone! url)
  "Clone URL into the plugins directory and answer the plugin's name.  Enables
nothing: the command line clones, and then asks a RUNNING shell to enable, so the
shell's main loop never waits on `git'.

REFUSES A CLONE WITH NO MANIFEST, and removes it again: a repository without a
`widgets.scm' is not a plugin, and leaving it installed would leave something
`remove' then cannot find."
  (let* ((name (url-plugin-name url))
         (dir (string-append (plugins-directory) "/" name)))
    (when (file-exists? dir)
      (error (format #f "~a is already installed, in ~a" name dir)))
    (mkdir-p (plugins-directory))
    (unless (zero? (status:exit-val (system* "git" "clone" "--depth" "1" url dir)))
      (error (format #f "git clone ~a failed" url)))
    (unless (file-exists? (string-append dir "/widgets.scm"))
      (system* "rm" "-rf" dir)
      (error (format #f "~a has no widgets.scm at its top, so it is not a plugin" url)))
    name))

(define (plugin-update! name)
  "Pull plugin NAME's latest commits.  Its options and its place in the config are
kept -- which is the difference from removing and installing it again.

FAST-FORWARD ONLY: a plugin directory is a clone nobody edits, so anything but a
fast-forward means somebody did, and merging into their work is not this
command's to do.

A RUNNING SHELL KEEPS THE CODE IT LOADED: Guile does not reload a module because
its file changed, so the new code arrives at the shell's next start."
  (require-plugin name)
  (let ((dir (string-append (plugins-directory) "/" name)))
    (unless (zero? (status:exit-val (system* "git" "-C" dir "pull" "--ff-only")))
      (error (format #f "git pull in ~a failed" dir))))
  #t)

(define (plugin-remove! name)
  "Disable plugin NAME, then delete it."
  (plugin-disable! name)
  (plugin-delete! name))

(define (plugin-delete! name)
  "Delete plugin NAME's directory.  Disables nothing -- see `plugin-remove!'."
  (require-plugin name)
  (let ((dir (string-append (plugins-directory) "/" name)))
    (unless (zero? (status:exit-val (system* "rm" "-rf" dir)))
      (error (format #f "could not delete ~a" dir))))
  #t)
