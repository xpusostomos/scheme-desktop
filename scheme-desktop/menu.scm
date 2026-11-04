;;; (scheme-desktop menu) -- the menu, in memory, and what you can ask of it
;;;
;;; The DATA is (scheme-desktop menu omarchy): a root entry holding a tree of
;;; entries. This module is everything you do with one -- loading it, resolving
;;; a path into it, turning a menu into the ROWS a window draws, and running a
;;; leaf. It holds no widgets, so it can be exercised without a display.
;;;
;;;   (menu)                          ; the menu, loaded on first use
;;;   (menu-resolve '(trigger reminder))   ; => that entry
;;;   (menu-rows (menu))              ; => the root's rows
;;;   (menu-run-path '(trigger reminder set))  ; runs it
;;;
;;; ROWS, NOT ENTRIES. A window does not draw entries; it draws rows. A row is
;;; an entry plus everything that had to be worked out to show it: its label
;;; with the tick already on it, whether it opens a submenu, whether it is
;;; dimmed -- and, for a provider-backed submenu, entries that are not in the
;;; menu at all because they came from asking the system. Keeping that in one
;;; function means the window never evaluates a guard or calls a provider.

(define-module (scheme-desktop menu)
  #:use-module (scheme-toolkit gi)
  #:use-module (scheme-desktop menu omarchy)
  #:use-module (scheme-desktop menu guards)
  #:use-module (scheme-toolkit process)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-9)
  ;; g-golf binds generics over the names srfi-1 uses (`map', `find', `any').
  ;; The same directive every other module here carries; without it the two
  ;; are a reported clash rather than a merge.
  #:duplicates (merge-generics replace warn-override-core warn last)
  #:export (menu menu-set! menu-reload! menu-fallback menu-module
            menu-rows menu-resolve menu-run menu-run-path menu-leaf?
            menu-splice
            menu-row? menu-row-entry menu-row-label menu-row-icon
            menu-row-icon-name menu-row-submenu? menu-row-disabled?
            menu-row-type menu-row-value row-of
            applisting)
  ;; RE-export, not export. These are bound in (scheme-desktop menu omarchy),
  ;; and `#:export' of a name this module only IMPORTED publishes nothing --
  ;; the name appears in the export list and is unbound at every use, which
  ;; fails at the first call rather than at compile time.
  #:re-export (entry-ref entry-key entry-children))

(define-gi-imports "AstalApps" "Apps" "Application")

;;; ---------------------------------------------------------------------------
;;; Where a menu's symbols are looked up
;;; ---------------------------------------------------------------------------

;; A menu is DATA, and a symbol in one -- `provider applisting', `when laptop?',
;; `action (launch "firefox")' -- has to be resolved in some module. Which one
;; is not obvious and cannot be guessed: the module a procedure happens to be
;; running in is not the module the menu was written in.
;;
;; So it is stated once, here, and defaults to THIS module -- which is where
;; `applisting' lives, so the shipped menu resolves with nothing configured.
;; A user menu that defines its own providers points this at whatever module
;; holds them:
;;
;;   (menu-module (resolve-module '(my-config)))
(define menu-module (make-parameter #f))

(define (menu-resolution-module)
  (or (menu-module) (resolve-module '(scheme-desktop menu))))

;;; ---------------------------------------------------------------------------
;;; Loading, lazily
;;; ---------------------------------------------------------------------------

;; #f until something asks for it. THE POINT OF THE DELAY is that a user's own
;; menu should be able to get there first -- `menu-set!' installs one without
;; anything having been read -- and a shell that never opens the menu should
;; never read the file at all.
(define %menu #f)
(define %loaded? #f)

(define (menu-fallback)
  "The menu to use when there is no Omarchy file.

Rooted, and holding the applications -- which is the one thing a menu can
always offer, because it comes from the system rather than from a file."
  (list 'label "Go" 'submenu
        (list (list 'key 'apps 'icon "" 'label "Apps" 'provider 'applisting))))

(define (menu-load!)
  "Read the menu from disk ONCE. Later calls return what was read."
  (unless %loaded?
    (set! %menu
          (catch #t
            (lambda ()
              (if (file-exists? omarchy-menu-default-path)
                  (omarchy-menu-file->scheme omarchy-menu-default-path)
                  (menu-fallback)))
            (lambda (key . args)
              ;; A menu that will not read must not take the shell with it, and
              ;; the reason has to be said out loud: the fallback looks like a
              ;; menu that is simply missing, which is a different problem.
              (format (current-error-port)
                      "scheme-desktop: menu: cannot read ~a: ~a ~s~%  using the fallback menu~%"
                      omarchy-menu-default-path key args)
              (menu-fallback))))
    (set! %loaded? #t))
  %menu)

(define (menu)
  "The menu, read on first use."
  (menu-load!))

(define (menu-set! root)
  "Install ROOT as the menu, whether or not one has been read yet.

This is the hook a user config uses: call it at startup with your own tree and
the Omarchy file is never opened."
  (set! %menu root)
  (set! %loaded? #t)
  root)

(define (menu-reload!)
  "Forget the menu and read it again."
  (set! %loaded? #f)
  (set! %menu #f)
  (menu-load!))

;;; ---------------------------------------------------------------------------
;;; The applications provider
;;; ---------------------------------------------------------------------------

;; ENUMERATED ON EVERY CALL, unlike everything else here. The menu is read once
;; because it comes from a file that does not change under us; the list of
;; installed applications does change, and a menu that was built at login would
;; not offer anything installed since.
(define (applisting)
  "One row per installed application, as of now.

Rows carry `icon-name' rather than `icon': an application's icon is a themed
icon that GTK draws as an image, where a menu row's is a font glyph that GTK
draws as text. One field per widget, and nothing has to guess which it is."
  (catch #t
    (lambda ()
      (let ((all (astal-apps-apps-get-list (astal-apps-apps-new))))
        (map (lambda (app)
               (list 'key (app-key app)
                     'icon-name (or (get-icon-name app) "")
                     'label (get-name app)
                     ;; A REAL CLOSURE, not a list naming a symbol: the
                     ;; application object is already in hand, and a list would
                     ;; have to name it and then be evaluated somewhere that
                     ;; name is bound. `evaluate-menu-value' calls a procedure
                     ;; it is handed, so this works with no module involved.
                     'action (lambda () (astal-apps-application-launch app))))
             (sort all (lambda (a b)
                         (string<? (string-downcase (get-name a))
                                   (string-downcase (get-name b))))))))
    (lambda (key . args)
      (format (current-error-port)
              "scheme-desktop: menu: cannot list applications: ~a ~s~%" key args)
      '())))

;; Keys are symbols, so an application's needs to be an identifier -- the same
;; rule the Omarchy reader applies to a key segment, and for the same reason.
(define (app-key app)
  (let* ((name (get-name app))
         (slug (string-map (lambda (c)
                             (if (or (char-alphabetic? c) (char-numeric? c))
                                 (char-downcase c)
                                 #\-))
                           name))
         ;; srfi-13's `string-trim' takes the STRING first and the criterion
         ;; second -- the opposite of how it reads.
         (slug (string-trim slug (lambda (c) (char=? c #\-)))))
    (string->symbol
     (if (or (string-null? slug) (string->number slug))
         (string-append "_" slug)
         slug))))

;;; ---------------------------------------------------------------------------
;;; Rows
;;; ---------------------------------------------------------------------------

(define-record-type <menu-row>
  (make-menu-row entry label icon icon-name submenu? disabled? type value)
  menu-row?
  (entry menu-row-entry)
  (label menu-row-label)
  (icon menu-row-icon)
  (icon-name menu-row-icon-name)
  (submenu? menu-row-submenu?)
  (disabled? menu-row-disabled?)
  ;; WHAT KIND OF SETTING THIS ROW IS -- 'boolean, 'number, 'string, 'option, or
  ;; #f for a row that is only an ACTION.  A row with a type can be EDITED, not
  ;; only chosen: see `menu-row-value' and the editors in (scheme-desktop widgets
  ;; menu).  TYPED ROWS ARE NOT INSTALLED OR NOT, the way Omarchy's menus are --
  ;; they are settings, and their box says what the setting currently is.
  (type menu-row-type)
  ;; THE CURRENT VALUE, as text, or #f when it could not be read.  Text rather
  ;; than the value itself, because a value comes from either bash's output or a
  ;; Scheme procedure, and text is what both can be.
  (value menu-row-value))

(define (guard-status session value module)
  "VALUE's status, or 'unknown when there is no session to ask.

A string guard with no session is 'unknown rather than #f, because the whole
point of 'unknown is that it is not a no."
  (cond ((not value) #f)
        ((and (string? value) (not session)) 'unknown)
        (else (guard-value-status session value #:module module))))

(define* (row-of entry #:key session (module (menu-resolution-module)))
  "ENTRY as a row, or #f when its `when' hides it.

A TYPED ROW -- one with a `type' -- is a SETTING: its `value' is read (that is
what the box shows) and its action, when it has one, runs when the row is
chosen.  Omarchy's `checked' still works and still means a boolean, so a menu
written the old way keeps working; `value' is what to write now."
  (let* ((type (let ((t (entry-ref entry 'type)))
                 (and t (if (string? t) (string->symbol t) t))))
         (value-field (or (entry-ref entry 'value) (entry-ref entry 'checked)))
         (checked (guard-status session value-field module))
         (disabled (guard-status session (entry-ref entry 'disabled) module))
         ;; NO `when' MEANS VISIBLE -- which is not the same as a `when' that
         ;; answered false, and the difference cost every row in the menu.
         ;; `guard-status' answers #f for "there is no condition", and
         ;; `guard-status->visible?' reads #f as "the condition said no", so
         ;; testing the absent case through both hid the entire top level.
         (visible (let ((when (entry-ref entry 'when)))
                    (or (not when)
                        (guard-status->visible?
                         (guard-status session when module)))))
         (base (or (entry-ref entry 'label) "")))
    (and visible
         (make-menu-row entry
                        ;; NO TICK ON THE LABEL ANY MORE.  It is drawn in a box at
                        ;; the end of the row, where a box belongs, and where a
                        ;; label's width does not move when the value changes.
                        base
                        (entry-ref entry 'icon)
                        (entry-ref entry 'icon-name)
                        ;; A SUBMENU IS ANY ROW THAT OPENS SOMETHING, and a
                        ;; provider-backed one opens its provider's rows rather
                        ;; than any children of its own. Asking only about
                        ;; `entry-children' made `Apps' -- whose rows are all
                        ;; generated -- indistinguishable from a leaf, so it
                        ;; got no `>' and selecting it ran nothing, because it
                        ;; has no action either. Clicking it did nothing at all.
                        (and (or (pair? (entry-children entry))
                                 (entry-provider entry))
                             #t)
                        (guard-status->disabled? disabled)
                        ;; A ROW WHOSE VALUE IS A PROCEDURE READS ITSELF: a
                        ;; generated row does not know its value until it is
                        ;; drawn, and reading it here is what makes the box show
                        ;; the current setting.
                        ;;
                        ;; A ROW WRITTEN THE OLD WAY IS A BOOLEAN.  `checked' was
                        ;; evaluated for its truth and a tick glued to the label;
                        ;; it is now the same thing as `type boolean' with that
                        ;; field as the value, so an existing Omarchy menu keeps
                        ;; its ticks -- in the box at the end of the row rather
                        ;; than on the label.  No type and no `checked' is a row
                        ;; with no value at all, which is most of them.
                        (cond (type type)
                              ((entry-ref entry 'checked) 'boolean)
                              (else #f))
                        ;; READ ONLY FOR A ROW THAT HAS ONE, and only when a
                        ;; session can read it: an untyped row has no value to
                        ;; show, and reading one for every row would ask the shell
                        ;; a question per row for nothing.
                        (cond
                         ((not value-field) #f)
                         ;; ALREADY A VALUE: a procedure, which the row carries
                         ;; and calls for itself -- no shell involved.
                         ((procedure? value-field) (guard-value->text (value-field)))
                         ;; A CONDITION OR A COMMAND, which needs the shell.
                         ((not session) #f)
                         (else
                          (let ((v (guard-value session value-field #:module module)))
                            (and (not (eq? v 'unknown)) v))))))))

(define* (menu-rows entry #:key session (module (menu-resolution-module)))
  "The rows ENTRY would show, in order: its children, then its provider's.

A provider's rows come AFTER any static children rather than replacing them.
Omarchy's own `swapProviderRows' keeps both and drops only the previous batch
from the same provider, so a submenu can be a fixed list with a generated tail."

  (let ((extra (let ((p (entry-provider entry)))
                 (if p
                     (catch #t
                       (lambda ()
                         (let ((rows (evaluate-menu-value p #:module module)))
                           (if (list? rows) rows '())))
                       (lambda (key . args)
                         (format (current-error-port)
                                 "scheme-desktop: menu: provider ~s failed: ~a ~s~%"
                                 p key args)
                         '()))
                     '()))))
    (filter-map (lambda (e) (row-of e #:session session #:module module))
                (append (or (entry-children entry) '()) extra))))

;;; ---------------------------------------------------------------------------
;;; Finding a place in the menu, and running what is there
;;; ---------------------------------------------------------------------------

(define* (menu-resolve path #:key (root (menu)))
  "The entry PATH names -- a list of keys -- or #f.

  (menu-resolve '())                    ; the root (an entry, or the top level)
  (menu-resolve '(trigger reminder))    ; that submenu

Only static children are searched. A provider's rows do not exist until it is
asked, so a path cannot name one; that is what running them by value is for."
  (let loop ((container root) (keys path))
    (cond ((null? keys) container)
          (else
           (let ((children (menu-children-of container)))
             (and children
                  (let ((child (find (lambda (e) (eq? (entry-key e) (car keys))) children)))
                    (and child (loop child (cdr keys))))))))))

;;; ---------------------------------------------------------------------------
;;; Putting a submenu into the menu
;;; ---------------------------------------------------------------------------
;;
;; A MENU IS A TREE OF PLISTS, and an entry's children live in `submenu'. So
;; splicing is: descend to a containing entry, and replace ITS `submenu' value
;; with one that has ENTRY at the right position. Nothing else in the tree is
;; touched, and the input is not modified -- the whole menu comes back.
;;
;; WHERE, exactly. LOCATION is a list of keys, and its LAST element says where
;; inside the containing submenu the new entry goes:
;;
;;   (menu-splice m sub '(apps share file))   ; after the `file' row
;;   (menu-splice m sub '(apps share #f))     ; as the FIRST row
;;
;; so the path to descend is `(apps share)' and the anchor is `file' -- the
;; anchor is not part of the path. Eating it is the whole subtlety: treating
;; `file' as a path segment would look for a CHILD named `file' and put the new
;; entry inside that row instead of beside it.
;;
;; #f AS THE ANCHOR MEANS THE FRONT, which is what a menu wants when the new
;; row should come before something the file already has -- Omarchy's own
;; `Before the clipboard item' case. `'()' would read as an empty path rather
;; than as a position, which is why the sentinel is #f and not `'()'.

(define (menu-children-or-#f entry)
  "ENTRY's children, or #f when it has none.

`entry-children' already answers #f for a missing `submenu', but an entry may
carry an EMPTY one, and the two cases are worth telling apart here: a submenu
value that exists is replaced in place, while one that does not is added."
  (let ((r (memq 'submenu entry)))
    (and r (cadr r))))

(define (menu-entry-with-children entry children)
  "ENTRY with its `submenu' set to CHILDREN, everything else unchanged.

Two shapes to handle, and the reason this is not a one-liner: an entry that
already has `submenu' has it REPLACED where it stands, and one that does not has
it ADDED at the end. `submenu' is not always the last field -- the converted
menu puts `submenu' in the middle for an entry that also has `aliases' -- so a
plain append would produce a plist with two `submenu' keys, and `entry-children'
would then answer with whichever came first."
  (let loop ((rest entry) (out '()))
    (cond ((null? rest) (append out (list 'submenu children)))
          ((eq? (car rest) 'submenu) (append out (list 'submenu children) (cddr rest)))
          (else (loop (cddr rest) (append out (list (car rest) (cadr rest))))))))

;; A MENU IS EITHER AN ENTRY OR A LIST OF ENTRIES, and telling them apart is the
;; whole difficulty.  AN ENTRY is a property list, whose head is a SYMBOL -- the
;; name of its first field, `key' or `label'.  AN ENTRY LIST is a list of entries,
;; whose head is a PAIR, or which is empty.  Both tests are needed: a list of
;; entries is not an entry (no `submenu' field), and an entry is not a list of
;; entries (its head is a symbol, not a pair).
;;
;; The top level of a menu is an entry list, which is why splicing into it used
;; to fail: every function assumed an entry.
(define (menu-entry-list? thing)
  "Whether THING is a list OF ENTRIES, rather than an entry."
  (and (list? thing) (or (null? thing) (pair? (car thing)))))

(define (menu-children-of thing)
  "THING's entries: an entry's `submenu', or the list itself when it is one of
the top level's.  #f for anything else, #f included."
  (cond ((menu-entry-list? thing) thing)
        ((and (pair? thing) (symbol? (car thing))) (menu-children-or-#f thing))
        (else #f)))

(define (menu-rebuild thing children)
  "THING with its entries replaced by CHILDREN, in its own shape."
  (if (menu-entry-list? thing)
      children
      (menu-entry-with-children thing children)))

(define (menu-splice-list children anchor sub)
  "CHILDREN with SUB after the entry keyed ANCHOR, or at the end, or at the front
when ANCHOR is #f.

A MISSING ANCHOR APPENDS: the path proved the container exists, and a row asked
to sit after one that has gone is closer to the intent than dropping it."
  (if (not anchor)
      (cons sub children)
      (let loop ((rest children) (out '()))
        (cond ((null? rest) (append out (list sub)))
              ((eq? (entry-key (car rest)) anchor)
               (append out (list (car rest) sub) (cdr rest)))
              (else (loop (cdr rest) (append out (list (car rest)))))))))

(define* (menu-splice main-menu sub-menu location)
  "MAIN-MENU with SUB-MENU spliced in at LOCATION. The full menu comes back.

LOCATION is a list of keys whose LAST element is the anchor:

  (menu-splice m sub '(apps share file))   ; after the `file' row of apps>share
  (menu-splice m sub '(apps share #f))     ; as the FIRST row of apps>share
  (menu-splice m sub '(#f))                ; at the very front of the menu

A PATH OF NO KEYS -- `(anchor)' -- splices into the TOP LEVEL, which is a list of
entries rather than an entry.

DOMAIN: the keys descend through `submenu' values only -- so an entry whose rows
come from a `provider' cannot be spliced into, because those rows do not exist
until the provider is asked; there is nothing to put a row beside.

RETURNS #F WHEN LOCATION DOES NOT NAME A PLACE, rather than the menu unchanged:
a splice that silently did nothing is the failure mode this exists to avoid.

HOW IT IS BUILT: `%menu-with' walks the tree from the ROOT, rebuilding each level
on the way out, and applies INSERT to the children of the entry the path names.
That is the one shape that gets both the failure and the rebuild right -- finding
the entry first and rebuilding it afterwards returns that entry alone."
  (if (or (null? location) (not main-menu))
      #f
      (let* ((anchor (car (last-pair location)))
             (keys (drop-right location 1))
             (insert (lambda (children) (menu-splice-list children anchor sub-menu))))
        ;; THE LAST KEY NAMES THE ENTRY WHOSE CHILDREN GET THE ROW, so it is
        ;; resolved before anything is inserted.  The first version treated an
        ;; exhausted path as "insert here", so `(trigger share file)' spliced
        ;; into the LIST of share's siblings rather than into share's submenu --
        ;; the row landed one level too high, and the tests said so.
        (define (walk container keys)
          (cond
           ;; THE TOP LEVEL, or any container reached with nothing left to
           ;; resolve: its entries are what the anchor is looked for among.
           ;; THE CONTAINER'S CHILDREN ARE REBUILT *INSIDE IT*.  Returning the
           ;; inserted list alone hands back the entry's `submenu' instead of the
           ;; entry -- the same mistake the entry branch had, one level up.
           ((null? keys) (menu-rebuild container (insert (menu-children-of container))))
           ((menu-entry-list? container)
            (let ((child (find (lambda (e) (eq? (entry-key e) (car keys))) container)))
              (and child
                   (let ((rebuilt (if (null? (cdr keys))
                                      ;; THE LAST KEY: insert among ITS children, and
                                      ;; an entry with no `submenu' yet GETS one --
                                      ;; that is the ordinary case for a row that is
                                      ;; a leaf, and failing there means a submenu
                                      ;; cannot be built by splicing.
                                      (menu-entry-with-children child (insert (or (menu-children-or-#f child) '())))
                                      (walk child (cdr keys)))))
                     (and rebuilt
                          (map (lambda (e) (if (eq? e child) rebuilt e)) container))))))
           (else
            ;; AN ENTRY: rebuild it around its rebuilt children.  THIS ONE LINE
            ;; IS THE WHOLE BUG THAT MADE THE TOP-LEVEL SPLICE RETURN A LIST --
            ;; the walk handed back the children and dropped the entry they
            ;; belonged to, so a root entry came back as its own `submenu'.
            (let ((children (menu-children-or-#f container)))
              (and children
                   (let ((rebuilt (walk children keys)))
                     (and rebuilt (menu-entry-with-children container rebuilt))))))))
        (walk main-menu keys))))

(define* (menu-run entry #:key (module (menu-resolution-module)))
  "Run ENTRY's action. Returns what the action returned."
  (let ((action (entry-ref entry 'action)))
    (cond ((not action) #f)
          ;; A string is a shell command; a symbol or a list is Scheme. The rule
          ;; and its implementation are the guards module's, so that a menu's
          ;; actions and its conditions cannot drift apart.
          ;; A STRING IS A SHELL COMMAND LINE, and it has to go through a
          ;; shell. These are Omarchy's actions verbatim -- pipes, `$(...)',
          ;; `&&' -- so splitting one into argv would change what it does, and
          ;; handing the string to `exec-async' (which takes argv) fails with
          ;; nothing more informative than "map". That is why every action in
          ;; the menu did nothing at all.
          ((string? action)
           (catch #t
             (lambda () (exec-shell action))
             (lambda (key . args)
               (format (current-error-port)
                       "scheme-desktop: menu: cannot run ~a: ~a ~s~%" action key args)
               #f)))
          (else (evaluate-menu-value action #:module module)))))

(define* (menu-run-path path #:key (root (menu)) (module (menu-resolution-module)))
  "What `menu-activate' does with a path: descend to it, and run it if it is a
leaf. Returns 'no-such-entry, or whatever running returned."
  (let ((entry (menu-resolve path #:root root)))
    (cond ((not entry) 'no-such-entry)
          ((menu-leaf? entry) (menu-run entry #:module module))
          (else entry))))
