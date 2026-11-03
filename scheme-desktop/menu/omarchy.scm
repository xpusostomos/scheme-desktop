;;; (scheme-desktop menu omarchy) -- an Omarchy menu file as Scheme data
;;;
;;; This module turns `omarchy-menu.jsonc' into the menu AS DATA -- a list of
;;; property lists -- and stops there. Writing it to a file is somebody else's
;;; job, and deliberately so: the menu a shell runs on should BE this value, not
;;; a text rendering of it that has to be parsed back before it can be used.
;;;
;;;   (omarchy-menu-file->scheme "/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc")
;;;   => (label "Go" submenu
;;;        ((key apps icon "" label "Apps" aliases ("app" "applications") provider applisting)
;;;         (key learn icon "" label "Learn" submenu
;;;          ((key keybindings icon "" label "Keybindings" action "…")
;;;           …))))
;;;
;;; THE MENU IS THE ROOT ENTRY. `key' is a SYMBOL -- it names a row and is what
;;; a lookup is keyed by. `submenu' holds a list of entries, the only value that
;;; is not a scalar, so every entry is a well-formed property list.
;;;
;;; KIND IS THE TAIL of the plist, and the kind of an entry can be read off it
;;; without a separate field:
;;;
;;;   (key x … action "cmd")              a shell command
;;;   (key x … action some-procedure)     a Scheme procedure
;;;   (key x … provider applisting)       rows from a Scheme procedure
;;;   (key x … submenu ((entry …) …))     static children
;;;
;;; EVERYTHING IS DATA. A bare symbol IS the symbol -- `provider applisting',
;;; never `provider 'applisting', which would be the two-element list
;;; (quote applisting). Resolving a symbol to a procedure happens where the
;;; value is used, not when the menu is read.
;;;
;;; NO DEPENDENCY ON scheme-toolkit. Only guile-json, so a shell can read an
;;; Omarchy file whether or not the toolkit is loaded -- and so this can be
;;; tested on its own.
;;;
;;; See docs/omarchy-menu-format.md for the source format and the field-by-field
;;; mapping.

(define-module (scheme-desktop menu omarchy)
  #:use-module (json)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:export (omarchy-menu-file->scheme
            omarchy-menu-jsonc->scheme
            omarchy-menu->string
            omarchy-menu-index
            omarchy-menu-warn omarchy-menu-warnings
            omarchy-menu-count
            entry-ref entry-key entry-children entry-provider
            omarchy-menu-default-path))

(define omarchy-menu-default-path
  "/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc")

;;; ---------------------------------------------------------------------------
;;; Reporting
;;; ---------------------------------------------------------------------------

;; A PARAMETER, not a write to (current-error-port). This runs inside a shell as
;; well as inside a build tool, and a library that prints to stderr on its own
;; is a library that cannot be used quietly. The default is to collect, so a
;; caller that did not ask still has the evidence.
(define omarchy-menu-warn
  (make-parameter
   (lambda (fmt . args)
     (set! %warnings (cons (apply format #f fmt args) %warnings)))))

(define %warnings '())

(define (omarchy-menu-warnings) (reverse %warnings))

(define (note fmt . args)
  (warn-level "! " fmt args))

(define (die fmt . args)
  (apply format (current-error-port) (string-append fmt "\n") args)
  (exit 1))

;; Forward: `note' and `warn-level' are the same thing, named once.
(define (warn-level prefix fmt args)
  (apply (omarchy-menu-warn) (string-append prefix fmt) args))

;;; ---------------------------------------------------------------------------
;;; 1. JSONC -> JSON text
;;; ---------------------------------------------------------------------------

(define (string-substitute* s rules)
  "Apply RULES -- a list of (REGEXP REPLACEMENT) -- left to right.

`regexp/newline' so `^' matches at the start of a line, which is what the
comment rule depends on."
  (fold (lambda (rule acc)
          (regexp-substitute/global #f (make-regexp (car rule) regexp/newline)
                                    acc 'pre (cadr rule) 'post))
        s
        rules))

;; THE SAME TWO RELAXATIONS OMARCHY USES, deliberately: a reader that accepts a
;; dialect its source rejects, or rejects one it accepts, disagrees with
;; upstream about what the input is. That includes the limitation -- `//' must
;; be the first thing on its line, so a trailing comment is NOT stripped, and a
;; file relying on one fails to parse exactly as it would upstream.
;;
;; Written with POSIX classes rather than \t and \n: in a SCHEME string those
;; are real control characters, so "\t" is a tab and "\\t" is the
;; two-character regex escape -- easy to get backwards, and the failure is a
;; silently-wrong strip rather than an error.
(define (strip-jsonc raw)
  (string-substitute* raw
    '(("^[[:space:]]*//[^\n]*" "")
      (",\\([[:space:]]*[}\\]]\\)" "\\1"))))

;;; ---------------------------------------------------------------------------
;;; 2. Parse, and restore key order
;;; ---------------------------------------------------------------------------

;; guile-json builds every object by CONSING onto an alist, so what it returns
;; is in REVERSE FILE ORDER:
;;
;;   (json-string->scm "{\"z\":1,\"y\":2,\"x\":3}")  =>  (("x" . 3) ("y" . 2) ("z" . 1))
;;
;; This matters more than it looks. Omarchy's file order is load-bearing: it is
;; the tie-break in the search score (`+ entry.order'), so a reader that forgets
;; this produces a menu that is upside down, silently.
;;
;; The recovery is unambiguous because guile-json's types are: an OBJECT is an
;; alist and an ARRAY is a vector, so anything that is a list is an object and
;; can simply be reversed.
(define (restore-order node)
  (cond ((vector? node)
         ;; list->vector, not vector-map: vector-map lives in (srfi srfi-43),
         ;; which is not the (srfi srfi-1) already loaded here.
         (list->vector (map restore-order (vector->list node))))
        ((list? node)
         (reverse (map (lambda (pair)
                         (cons (car pair) (restore-order (cdr pair))))
                       node)))
        (else node)))

(define (menu-entries doc path)
  "The (id . entry) alist from a parsed menu document, in file order."
  (cond ((not (list? doc))
         (die "~a: not a menu: the top level is not a JSON object" path))
        ;; Both shapes are accepted upstream: a bare map of id -> entry, or
        ;; {"items": {...}}. The shipped file uses the bare form.
        ((assoc-ref doc "items")
         => (lambda (inner)
              (if (list? inner)
                  inner
                  (die "~a: `items' is not an object" path))))
        (else doc)))

;;; ---------------------------------------------------------------------------
;;; 3. Field mapping
;;; ---------------------------------------------------------------------------

;; Upstream's provider named `apps' collides with the menu ROW named `apps', so
;; the two cannot share a name. Renamed to `applisting'; every other provider
;; keeps its own name.
;; An R7RS identifier: starts with a letter or one of the usual special
;; initials, and contains only identifier characters. Checked against a
;; conservative pattern rather than by round-tripping through the reader,
;; because the reader ACCEPTS things the standard does not.
(define %plain-identifier
  (make-regexp "^[a-zA-Z!$%&*/:<=>?^_~][a-zA-Z0-9!$%&*/:<=>?^_~+.-]*$"))

(define (plain-identifier? name)
  (and (not (string-null? name))
       (not (string->number name))
       (regexp-exec %plain-identifier name)
       #t))

;; MANGLING, because there is no escape hatch that works.
;;
;; `1password' is the one key in the shipped menu that is not an identifier, and
;; it needs a symbol that reads back. The obvious answer -- bar-quote it as
;; `|1password|' -- DOES NOT WORK in Guile: this was measured, and
;; (symbol->string (read (open-input-string "|1password|"))) returns the
;; eleven-character string "|1password|" with the bars IN the name. Guile reads
;; bare `1password' fine but writes it back as `#{1password}#', its own notation.
;;
;; So the rule is a RENAME: a name that is not an identifier gets an underscore
;; in front. `1password' becomes `_1password'.
;;
;; It is a PURE FUNCTION of the Omarchy segment, which is what makes it safe:
;; every path, index lookup and route that names a row mangles the same way, so
;; the tree and the names in it cannot disagree. Anything else that has to name
;; a row -- a keybinding, a `target', a translation catalogue -- must mangle too,
;; and that is why this is one function rather than a call to string->symbol
;; scattered around.
(define %non-identifier-char (make-regexp "[^a-zA-Z0-9!$%&*/:<=>?^_~+.-]"))

;;   (key-symbol "apps")       => apps
;;   (key-symbol "1password")  => _1password
(define (key-symbol segment)
  "SEGMENT as the symbol a key should be, renamed if it is not an identifier."
  (let* ((cleaned (regexp-substitute/global #f %non-identifier-char segment
                                            'pre "-" 'post))
         (cleaned (if (string-null? cleaned) "key" cleaned)))
    (unless (string=? cleaned segment)
      (note "key ~s: characters not allowed in an identifier replaced" segment))
    (string->symbol
     (if (plain-identifier? cleaned) cleaned (string-append "_" cleaned)))))

(define (provider-symbol name)
  (string->symbol (if (string=? name "apps") "applisting" name)))

;; Scheme names are KEBAB-CASE and Omarchy's JSON is camelCase. An explicit map
;; rather than a case conversion, because `iconFont' -> `icon-font' is not a
;; rule you want to discover you got wrong by regenerating 333 rows.
;;
;; SPLIT INTO GROUPS, each iterated exactly once. As one list it has to be
;; filtered three times, and the first pass reads every entry -- which emitted
;; `when' TWICE, once from that pass and once from the guard pass. It parses, it
;; looks nearly right, and `memq' finding the first occurrence means a field
;; comparison does not notice.
(define %scalar-fields
  '(("icon" . icon) ("iconFont" . icon-font) ("label" . label) ("title" . title)))

(define %list-fields
  '(("aliases" . aliases) ("description" . description) ("searchTerms" . search-terms)))

(define %guard-fields
  ;; `checked' IS NOT ONE OF THEM ANY MORE.  It said "is this thing on", which is
  ;; the boolean half of a SETTING, and a setting is `value' with a `type' now --
  ;; so it is written as `type boolean' and `value', and the runtime reads one
  ;; shape rather than two.  See `value-fields' just below.
  '(("when" . when) ("disabled" . disabled)))

;; A ROW WITH `checked' IS A BOOLEAN SETTING: the same field, under the name the
;; rest of the menu uses.
(define (value-fields entry)
  (let ((checked (string-field entry "checked")))
    (if checked
        (list 'type ''boolean 'value checked)
        '())))

(define %known-fields
  '("icon" "iconFont" "label" "title" "action" "target" "provider"
    "aliases" "description" "searchTerms" "when" "checked" "disabled"
    "type" "value" "options"
    "parent" "items"))

(define (string-field entry name)
  "ENTRY's string NAMEs, or #f when absent or empty.

Empty counts as absent: upstream sets `icon' on all 333 rows but leaves e.g.
`title' off 317 of them, and carrying `title \"\"' through the whole pipeline
would mean every consumer testing for emptiness instead of absence."
  (let ((v (assoc-ref entry name)))
    (and (string? v) (not (string=? v "")) v)))

(define (string-list-field entry name)
  "ENTRY's NAMEs as a list of strings. Upstream allows a bare string or an array."
  (let ((v (assoc-ref entry name)))
    (cond ((string? v) (list v))
          ((vector? v) (filter (lambda (x) (and (string? x) (not (string=? x ""))))
                               (vector->list v)))
          (else '()))))

(define (check-fields! id entry)
  (for-each (lambda (k)
              (unless (member k %known-fields)
                (note "~a: unknown field ~s, dropped" id k)))
            (map car entry)))

;;; ---------------------------------------------------------------------------
;;; 4. Building the tree
;;; ---------------------------------------------------------------------------

(define (segments id) (string-split id #\.))

(define (parent-of id)
  (let ((parts (segments id)))
    (if (null? (cdr parts))
        ""
        (string-join (drop-right parts 1) "."))))

;; parent id ("" for the root) -> its children, in file order.
(define (children-by-parent entries)
  (let ((table (make-hash-table)))
    (for-each
     (lambda (pair)
       (let* ((id (car pair))
              (parent (parent-of id))
              (bucket (hash-ref table parent '())))
         (hash-set! table parent (append bucket (list pair)))))
     entries)
    table))

;; A child whose parent is not declared anywhere would be unreachable: upstream
;; keeps the row in its map but never draws it, because the walk starts at
;; `root' and follows parents. Reported and attached to the root instead -- a
;; row that exists should be visible, and a silently unreachable one is the kind
;; of thing that is only noticed months later.
(define (check-parents! entries)
  (let ((ids (map car entries)))
    (for-each
     (lambda (pair)
       (let ((parent (parent-of (car pair))))
         (unless (or (string=? parent "") (member parent ids))
           (note "~a: parent ~s is not declared; attaching to the root"
                 (car pair) parent))))
     entries)))

(define (entry->plist id entry children)
  "ENTRY -- an (id . json-object) -- and its subtree, as one property list.

THE WHOLE CONVERSION IS THIS FUNCTION. Everything above prepares its inputs and
everything below only renders its result."
  (let* ((kids (hash-ref children id '()))
         (action (string-field entry "action"))
         (provider (string-field entry "provider"))
         (target (string-field entry "target")))

    (unless (list? entry)
      (die "~a: entry is not an object" id))

    (check-fields! id entry)

    ;; `target' is a link to another submenu by ABSOLUTE id. Upstream supports it
    ;; and ships ZERO of them. Dropped rather than half-supported: keeping it
    ;; would mean the format needs dotted paths, which is the thing nesting
    ;; exists to remove.
    (when target
      (note "~a: `target' (~s) dropped -- links are not supported" id target))

    ;; PAIR?, not a truth test on the list. `(and action kids)' is true for an
    ;; EMPTY list -- only #f is false in Scheme -- so it fires "has both an
    ;; action and 0 child(ren)" for every leaf.
    (when (and action (pair? kids))
      (note "~a: has both an action and ~a child(ren); the children are unreachable"
            id (length kids)))

    (append
     ;; A SYMBOL, not a string. A key is an identifier -- it names a row, it is
     ;; what a lookup is keyed by, and `(assq 'apps rows)' is the natural way to
     ;; ask for a row. Quotes around it would make it a value to be compared
     ;; with string=? instead.
     (list 'key (key-symbol (last (segments id))))
     (append-map (lambda (pair)
                   (let ((v (string-field entry (car pair))))
                     (if v (list (cdr pair) v) '())))
                 %scalar-fields)
     (append-map (lambda (pair)
                   (let ((vs (string-list-field entry (car pair))))
                     (if (pair? vs) (list (cdr pair) vs) '())))
                 %list-fields)
     ;; Guards. Upstream's are bash and arrive as strings; a symbol means a
     ;; Scheme procedure. Strings are the compatibility form -- see
     ;; docs/omarchy-menu-format.md, "Guards" -- and the runtime is expected to
     ;; recognise one and route it through a single batched shell rather than
     ;; forking per row.
     (append-map (lambda (pair)
                   (let ((v (string-field entry (car pair))))
                     (if v (list (cdr pair) v) '())))
                 %guard-fields)
     (value-fields entry)
     (cond (action (list 'action action))
           (provider (list 'provider (provider-symbol provider)))
           ((pair? kids)
            ;; THE VALUE OF `submenu' IS ONE LIST, not a tail of loose children.
            ;;
            ;; `(key "learn" ... submenu (key "a") (key "b"))' is not a property
            ;; list: `submenu' has no value and the entry ends in a variadic
            ;; tail, so nothing can walk it by pairs -- `assq', a plist reader,
            ;; a merge, a formatter that assumes key/value alternation. The
            ;; entry has to be `(key "learn" ... submenu ((key "a") (key "b")))'
            ;; so that every element after `key' pairs with the one before it.
            (list 'submenu
                  (map (lambda (kid) (entry->plist (car kid) (cdr kid) children))
                       kids)))
           (else
            ;; Neither action, provider nor children. Upstream would call this a
            ;; submenu and draw a row that opens nothing.
            (note "~a: no action, provider or children" id)
            (list 'submenu '()))))))

;;; ---------------------------------------------------------------------------
;;; 5. The menu
;;; ---------------------------------------------------------------------------

;; THE MENU HAS A ROOT ENTRY, and it is the whole point of the shape.
;;
;; Upstream injects one too -- `{"id":"root","parent":"","label":"Go"}' -- when
;; neither source declares it, and for the same reason: something has to hold
;; the top-level rows, and something has to be left when the user navigates back
;; up out of a submenu.
;;
;; It has NO `key'. Every other entry has one because it is a row and needs to
;; be told apart from its siblings; the root has no siblings and is not a row.
;; `omarchy-menu-count' counts entries WITH a key for exactly this reason.
(define (root-entry by-parent rows label)
  (list 'label label
        'submenu (map (lambda (pair) (entry->plist (car pair) (cdr pair) by-parent))
                      rows)))

(define* (omarchy-menu-jsonc->scheme text
                                     #:optional (path "<string>")
                                     #:key (root-label "Go"))
  "TEXT of an omarchy-menu.jsonc, as the menu, rooted.

  (label \"Go\" submenu
    ((key \"apps\" icon \"…\" label \"Apps\" …)
     (key \"learn\" icon \"…\" label \"Learn\" submenu
      ((key \"keybindings\" …)))))

THE MENU IS THE ROOT ENTRY. It is not a list containing one -- that would be a
singleton wrapper around the entry, always exactly one element, carrying
nothing. `submenu' holds a LIST of entries because a submenu may have any
number; the top level has exactly one holder and that holder is the menu."
  (let* ((doc (restore-order (json-string->scm (strip-jsonc text))))
         (entries (menu-entries doc path)))
    (when (null? entries)
      (die "~a: no entries (is the file mid-write?)" path))
    (check-parents! entries)
    (let* ((children (children-by-parent entries))
           (roots (hash-ref children "" '())))
      (when (null? roots)
        (die "~a: nothing at the root of the menu" path))
      (root-entry children roots root-label))))

(define* (omarchy-menu-file->scheme path #:key (root-label "Go"))
  "PATH to an omarchy-menu.jsonc, as the menu, rooted."
  (omarchy-menu-jsonc->scheme (call-with-input-file path get-string-all) path
                              #:root-label root-label))

;;; ---------------------------------------------------------------------------
;;; 6. An index, for routing
;;; ---------------------------------------------------------------------------

;; "The menu", normalised. The menu is the ROOT ENTRY, but its `submenu' value
;; is a LIST of entries, and a caller holding one may reasonably pass the other.
;; Accepting both costs one test and removes a class of "wrong shape" bug from
;; every call site.
(define (menu-rows menu)
  (if (and (pair? menu) (symbol? (car menu)))
      (or (entry-children menu) '())
      menu))

(define (entry-ref entry key)
  "ENTRY's value for KEY, or #f.

An entry is a property list, so this is `assq' with the plist walked by pairs --
which is only possible because `submenu' holds one list rather than being a
marker with a variadic tail."
  (let ((r (memq key entry))) (and r (cadr r))))

(define (entry-key entry) (entry-ref entry 'key))
(define (entry-children entry) (let ((r (memq 'submenu entry))) (and r (cadr r))))
(define (entry-provider entry) (entry-ref entry 'provider))
(define (has-key? entry) (and (memq 'key entry) #t))

;; Nesting is the tree, so an id only exists as a PATH: `key' is the last
;; segment. Anything that resolves a route (`omarchy menu summon
;; setup.default.browser') or looks a row up by name needs the paths, and
;; computing them by walking is the only place they exist.
(define (omarchy-menu-count menu)
  "How many ROWS MENU holds, at every level, not counting the root.

Not `(length menu)': that counts the top-level entries, of which the shipped
menu has one -- the root. And the root is not a row: it has no `key', so
counting entries with one is both the right number and the right definition."
  (fold (lambda (entry n)
          (+ n
             (if (has-key? entry) 1 0)
             (let ((kids (entry-children entry)))
               (if (pair? kids) (omarchy-menu-count kids) 0))))
        0
        (menu-rows menu)))

(define (omarchy-menu-index menu)
  "MENU as a hash of dotted path -> entry, plus the rows in tree order.

  (call-with-values (lambda () (omarchy-menu-index menu))
    (lambda (by-path order) …))

BY-PATH is keyed by the full dotted path, e.g. \"setup.default.browser\", and
holds ROWS -- the root is not in it, having no path. ORDER is the rows in tree
order, which is what a search tie-break wants.

  (hash-ref by-path \"setup.default.browser\")   ; => the Browser row"
  (let ((by-path (make-hash-table))
        (order '()))
    (define (walk entry prefix)
      (let* ((key (entry-key entry))
             ;; Paths stay STRINGS even though keys are symbols: a path is what a
             ;; route is compared against, and a route arrives as text the user
             ;; typed. Normalising both to text keeps that comparison in one place.
             (path (if (not key)
                       prefix
                       (let ((seg (symbol->string key)))
                         (if (string=? prefix "") seg
                             (string-append prefix "." seg)))))
             (kids (entry-children entry)))
        (when key
          (hash-set! by-path path entry)
          (set! order (cons entry order)))
        (when (pair? kids)
          (for-each (lambda (kid) (walk kid path)) kids))))
    (for-each (lambda (e) (walk e "")) (menu-rows menu))
    (values by-path (reverse order))))

;;; ---------------------------------------------------------------------------
;;; 7. Rendering -- the only part that is about text
;;; ---------------------------------------------------------------------------

(define (scheme-string s)
  "S as a Scheme string literal, escapes included.

Actions are shell commands full of quotes and backslashes -- 275 of them in the
shipped menu -- so this is not a formality."
  (let ((out (open-output-string)))
    (write-char #\" out)
    (string-for-each
     (lambda (c)
       (cond ((char=? c #\") (display "\\\"" out))
             ((char=? c #\\) (display "\\\\" out))
             ((char=? c #\newline) (display "\\n" out))
             ((char=? c #\tab) (display "\\t" out))
             (else (write-char c out))))
     s)
    (write-char #\" out)
    (get-output-string out)))

;;; A LIST OF ENTRIES IS NOT A LIST OF VALUES, and the difference is the whole
;;; renderer. `((key "a") (key "b"))' is a menu -- one entry per line, aligned
;;; under the first. `("app" "applications")' is a value -- inline. Test by the
;;; first element: an entry is a list, a scalar is not.
(define (list-of-entries? v)
  (and (pair? v) (list? (car v))))

;; COLUMN, not depth. Working in columns is what removes the special case: an
;; entry's children align under the entry's own first element wherever that
;; happens to be, so the root needs no rule of its own and neither does anything
;; nested inside it. The previous version counted levels and had to write the
;; top level's `'(' by hand to make the first row land in the right place.
(define (symbol->text s)
  "S as a Scheme symbol literal.

Bare, always: `key-symbol' and `provider-symbol' are the only producers of the
symbols that reach here, and both return plain identifiers. There is nothing to
escape, because the escape that would be needed does not exist in Guile."
  (symbol->string s))

(define* (value->text v column #:optional (indent 2))
  (cond
   ((string? v) (scheme-string v))
   ((symbol? v) (symbol->text v))
   ((null? v) "()")
   ((list? v)
    (if (list-of-entries? v)
        (let ((pad (make-string (+ column 1) #\space)))
          (string-append
           "("
           (entry->text (car v) (+ column 1) indent)
           (string-concatenate
            (map (lambda (e)
                   (string-append "\n" pad (entry->text e (+ column 1) indent)))
                 (cdr v)))
           ")"))
        (string-append "("
                       (string-join (map (lambda (x) (value->text x 0 indent)) v) " ")
                       ")")))
   ((number? v) (number->string v))
   (else (object->string v))))

;; AN ENTRY IS A PROPERTY LIST, so its values are read by pairs -- which is only
;; true because `submenu' now holds ONE list rather than being a marker with a
;; variadic tail. The `submenu' value is the only thing that breaks the line;
;; every other value is a scalar and stays inline.
(define* (entry->text entry column #:optional (indent 2))
  (let* ((kids (entry-children entry))
         (pad (make-string (+ column 1) #\space)))
    (if (not (pair? kids))
        (string-append "("
                       (string-join (map (lambda (x) (value->text x 0 indent)) entry) " ")
                       ")")
        (let ((head (take entry (+ 1 (list-index (lambda (x) (eq? x 'submenu)) entry)))))
          (string-append
           "(" (string-join (map (lambda (x) (value->text x 0 indent)) head) " ")
           "\n" pad
           (value->text kids (+ column 1) indent)
           ")")))))

(define* (omarchy-menu->string menu #:key (name "omarchy-menu") (indent 2))
  "MENU as Scheme source: a header, then one `define'.

  (define omarchy-menu
    '((label \"Go\" submenu
       ((key \"apps\" …)
        …))))

NO LEVEL IS SPECIAL-CASED. The value is a menu -- a list of entries -- and the
renderer knows only how to render a menu and how to render an entry. That the
top level happens to hold one entry, the root, needs no rule: it falls out of
the same code that renders every other list of entries.

`  '' puts the list's opening paren in column 3, which is the only number the
renderer is given about the `define' it is being written into."
  (string-append
   (format #f ";;; ~a -- generated by bin/omarchy-menu-to-scheme~%" name)
   (format #f ";;; ~a rows.  DO NOT EDIT: re-run the generator.~%~%"
           (omarchy-menu-count menu))
   ;; `entry->text' for an entry -- the same function that renders every nested
   ;; submenu holder. No text is forced and no level is special-cased; the only
   ;; number passed in is the column `  '' leaves the opening paren at.
   (format #f "(define ~a~%  '" name)
   (entry->text menu 3 indent)
   ")\n"))
