;;; (scheme-desktop settings-menu) -- each widget's options, as menu rows
;;;
;;; A WIDGET ALREADY DECLARES ITS OPTIONS: name, type, label, default, and the
;;; descriptor the settings UI would need to draw a control.  This turns that
;;; declaration into MENU ROWS -- one row per option, under one submenu per
;;; widget -- so the menu can edit the shell's settings with no knowledge of what
;;; a widget is.
;;
;; THE MENU STAYS GENERIC.  A row says what its value IS (`value'), what to run
;; to change it (`action', called with the new value), and, for a choice, what the
;; choices are (`options').  Those three fields are all the editor needs -- see
;; (scheme-desktop widgets menu) -- and none of them mentions a widget.  What
;; knows about widgets is THIS file, which builds the rows and closes over the
;; widget and the option name in the two procedures a row carries.
;;
;; TYPES MAP ONE FOR ONE:
;;
;;   (boolean)          -> boolean   a tick box; choosing it asks, then toggles
;;   (number lo hi)     -> number    the value as text; choosing it opens a field
;;   (string)           -> string    likewise
;;   (choice a b c)     -> choice    a list, one box per choice
;;   (list)             -> nothing   see below
;;
;; `(list)' IS LEFT OUT, and deliberately: `favorites' is a list of desktop
;; entries and the bar's layout is a nesting of widgets and positions.  Neither is
;; A VALUE someone types, and a generic editor for either would be a lie about
;; what it is.  They get their own editors when they are wanted, and are visible
;; in config.scm meanwhile.

(define-module (scheme-desktop settings-menu)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit config)
  #:use-module (scheme-desktop config)
  #:use-module (scheme-desktop menu)
  #:use-module (oop goops)
  #:use-module (ice-9 format)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (widget-menu-entries widget-submenu settings-menu-entries
            settings-menu settings-splice!))

;;; ---------------------------------------------------------------------------
;;; One option, as a row
;;; ---------------------------------------------------------------------------

;; A row's KEY has to be unique in the menu, because `menu-resolve' finds a row
;; by key.  The qualified name plus the option name is: two widgets cannot have
;; the same qualified name, and a widget cannot have one option twice.
(define (entry-key-for w option)
  (format #f "settings.~a.~a" (widget-short-name w) option))

(define (current-value w option)
  "W's OPTION, as the text a row shows."
  (catch #t
    (lambda ()
      (let ((v (widget-config-value (widget-name w) option)))
        (cond ((eq? v #t) "#t")
              ((eq? v #f) "#f")
              ((symbol? v) (symbol->string v))
              ((string? v) v)
              ((number? v) (number->string v))
              (else (format #f "~s" v)))))
    (lambda args #f)))

;; THE TWO PROCEDURES A ROW CARRIES, and they are the whole of the coupling: one
;; reads the option, one writes it.  Both close over the widget and the option
;; name, so the menu sees a row like any other.
;;; THE TWO CLOSURES ARE NAMED, so that a dump of the menu can say what a row
;; does instead of printing `#<procedure …>'.  `procedure-name' reports these,
;; and a caller writing the menu out as data uses them.

(define (value-reader w option)
  "The procedure a row calls to read W's OPTION."
  (define (read-option) (or (current-value w option) ""))
  read-option)

(define (value-writer w option)
  "The procedure a row calls to set W's OPTION, given the new value."
  (define (write-option new-value)
    (catch #t
      (lambda ()
        ;; A `choice' VALUE COMES BACK AS TEXT -- the menu shows strings, and its
        ;; editor passes back the string that was clicked.  The option's own value
        ;; may be a SYMBOL (`(mode static)'), and `widget-config-set!' checks
        ;; against the symbol, so the text is turned back here rather than
        ;; teaching the menu about types it does not have.
        (widget-config-set! (widget-name w) option (coerce-value w option new-value)))
      (lambda (key . args)
        (format (current-error-port)
                "scheme-desktop: settings: cannot set ~a to ~s: ~a ~s~%"
                option new-value key args)
        #f)))
  write-option)

(define (coerce-value w option value)
  "VALUE -- text from the menu -- as W's OPTION wants it."
  (if (not (string? value))
      value
      (let ((type (slot-type w option)))
        (case (and (pair? type) (car type))
          ((number) (or (string->number value) value))
          ((boolean) (string=? value "#t"))
          ((choice) (if (any (lambda (o) (string=? o value)) (map value-text (cdr type)))
                        (let ((match (find (lambda (o) (string=? (value-text o) value)) (cdr type))))
                          match)
                        value))
          (else value)))))

(define (value-text v) (if (string? v) v (symbol->string v)))

(define (slot-type w option)
  (let ((spec (widget-config-slot-spec w option)))
    (and spec (assoc-ref spec 'type))))

(define (slot-label spec)
  (or (assoc-ref spec 'label) (symbol->string (assoc-ref spec 'name))))

(define (option-entry w spec)
  "One option as a menu property list, or #f for a type the menu cannot edit."
  (let* ((option (assoc-ref spec 'name))
         (type (assoc-ref spec 'type))
         (kind (and (pair? type) (car type)))
         ;; THE LABEL IS THE OPTION'S NAME, and the value is the box at the right
         ;; of the row -- which is where a value belongs, and where the editor
         ;; already looks for it.  A row whose label carried the value too would
         ;; say it twice.
         ;; `key` FIRST, as a field NAME: a menu entry is a property list, and
         ;; without it the row is a list that begins with a STRING -- neither an
         ;; entry nor a list of entries, so the menu could not walk into it and
         ;; the Settings submenu came up empty.
         (base (list 'key (entry-key-for w option)
                     'label (slot-label spec)
                     'value (value-reader w option)
                     'action (value-writer w option))))
    (case kind
      ((boolean) (append base (list 'type ''boolean)))
      ;; `integer' IS ITS OWN DESCRIPTOR, with the same range shape as `number'
      ;; -- `(integer 16 96)' for a bar's height.  It fell through to #f and the
      ;; whole option vanished from the menu, which is why most widgets showed
      ;; nothing: their options are integers.
      ((number integer) (append base (list 'type ''number)))
      ((string) (append base (list 'type ''string)))
      ((choice) (append base (list 'type ''choice
                                   'options (map value-text (cdr type)))))
      (else #f))))

;;; ---------------------------------------------------------------------------
;;; One widget, and the whole shell
;;; ---------------------------------------------------------------------------

(define (widget-menu-entries w)
  "W's editable options, as rows, in the order W declares them."
  (filter-map (lambda (spec) (option-entry w spec)) (widget-config-slots w)))

(define (widget-submenu w)
  "W as a submenu row, or #f when W has no option the menu can edit."
  (let ((rows (widget-menu-entries w)))
    (and (pair? rows)
         (list 'key (format #f "settings.~a" (widget-short-name w))
               'label (format #f "~a" (widget-short-name w))
               'submenu rows))))

(define* (settings-menu-entries #:optional (widgets (desktop-widgets)))
  "Every widget's editable options, as the rows of one menu: a submenu per widget.

ONE ROW PER WIDGET, in the registry's order, so the list reads like the shell --
theme, bar, menu, workspaces, clock, and so on -- and holds still between runs."
  (filter-map (lambda (w)
                ;; THE ROOT IS NOT A SETTING: its `widgets' option is which
                ;; widgets are live, which is a different kind of decision, and
                ;; one bad click there empties the shell.
                (and (not (eq? (widget-name w) 'root))
                     (catch #t (lambda () (widget-submenu w)) (lambda args #f))))
              widgets))

(define (settings-menu)
  "The settings as a menu of their own -- for a shell that wants just this, and
for a test that does not want to touch the real menu."
  (list (list 'key 'settings 'label "Settings" 'submenu (settings-menu-entries))))

;;; ---------------------------------------------------------------------------
;;; Splicing it into the menu in use
;;; ---------------------------------------------------------------------------

(define* (settings-splice! #:key (after "system"))
  "Put the settings into the menu in use, after the top-level row AFTER, and
answer the location that was used.

TOP LEVEL FOR NOW, because that is where it is being tried out: `(menu-splice m
sub (list after))' is one key, which means: in the top-level list, after the row
called AFTER.  It will move into Setup later, which is the same call with a
longer path.

RETURNS #F, WITH A WORD, WHEN THERE IS NO SUCH ROW -- `menu-splice' answers #f
rather than splicing nothing silently, and a caller has to know that."
  ;; THE OLD SETTINGS GO FIRST.  Splicing twice used to append a second
  ;; Settings row and leave the first one empty -- `menu-splice' has no notion of
  ;; replacing, and the rows are generated fresh each time, so the stale one has
  ;; to be taken out.
  (let* ((without (menu-splice-drop (menu) 'settings))
         (location (list after))
         (spliced (menu-splice without (settings-menu) location)))
    (if spliced
        (begin (menu-set! spliced) location)
        (begin
          (format (current-error-port)
                  "scheme-desktop: settings: no top-level row called ~s to splice after~%"
                  after)
          #f))))

(define (menu-splice-drop menu key)
  "MENU with the top-level entry keyed KEY removed, or MENU unchanged.

Only the TOP LEVEL: the settings row is spliced there, and nothing else this
shell generates shares its key."
  (let ((inside (menu-children-or-#f menu)))
    (if (not inside)
        menu
        (menu-entry-with-children
         menu (remove (lambda (e) (eq? (entry-key e) key)) inside)))))
