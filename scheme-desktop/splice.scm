;;; (scheme-desktop splice) -- how a widget puts itself into scheme-desktop's config
;;;
;;; A widget ENABLES ITSELF: given the config list (as config.scm holds it), it
;;; splices its name in wherever it wants to be and returns the new list.  That
;;; gives every widget -- this shell's own and every plugin's -- full say over
;;; where it goes: which section of the bar, next to what, or not in the bar at
;;; all.  `widget-disable!' takes it out of all of those places again.
;;;
;;;   (widget-enable! w config)    -> config with W in it
;;;   (widget-disable! w config)   -> config with W gone from every place
;;;
;;; THE DEFAULTS, which a widget overrides when they are not what it wants:
;;;
;;;   any widget       the root's list of live widgets, and its own options form
;;;   a bar item       that, and the END of the bar's RIGHT section
;;;
;;; THE TWO HELPERS a method writes with:
;;;
;;;   (config-splice-add-widget config w)                 root list + own form
;;;   (config-splice-into-bar config w 'left 'end)        a bar section
;;;
;;; A WIDGET HERE MAY BE A PROTOTYPE.  `enable!' is called to write a config,
;;; often before the shell has made any widgets -- on a first run, or by
;;; `scheme-desktop enable' with the shell stopped -- so the object it is called
;;; on is `allocate-instance'd and given its qualified name, and NOTHING ELSE:
;;; its other slots are unset and its `initialize' never ran.  A method reads
;;; `widget-name' and nothing more.

(define-module (scheme-desktop splice)
  #:use-module (scheme-toolkit app)
  #:use-module (scheme-toolkit config-splice)
  #:use-module (oop goops)
  #:use-module (srfi srfi-1)
  #:export (widget-enable! widget-disable! widget-prototype
            config-splice-add-widget config-splice-remove-widget
            config-splice-into-bar config-splice-out-of-bar
            root-widgets-path bar-name bar-section-path bar-sections))

;;; ---------------------------------------------------------------------------
;;; Where things are
;;; ---------------------------------------------------------------------------

(define root-widgets-path '(() root widgets ()))

;; THE BAR BY ITS QUALIFIED NAME, which is its key in the config like any
;; widget's.  Written here once so that no plugin spells it.
(define bar-name '(scheme-desktop widgets bar <bar-desktop-widget>))

(define bar-sections '(left center right))

(define (bar-section-path section)
  (list '() bar-name 'layout '() section '()))

;;; ---------------------------------------------------------------------------
;;; The helpers
;;; ---------------------------------------------------------------------------

(define (config-splice-add-widget config w)
  "CONFIG with W live: its name at the end of the root's list, and its own
options form at the top level -- empty, for the shell to fill with W's defaults
the first time it saves."
  (config-splice (config-splice config root-widgets-path (widget-name w) 'end)
                 '(()) (list (widget-name w)) 'end #:key form-head))

(define (config-splice-remove-widget config w)
  "CONFIG with W gone from the root's list, and its options form with it."
  (config-splice-delete (config-splice-delete config root-widgets-path (widget-name w))
                        '(()) (widget-name w) #:key form-head))

;; An options form is (NAME option ...): it is the same entry as another with the
;; same NAME, whatever options either holds.
(define (form-head e) (and (pair? e) (car e)))

(define* (config-splice-into-bar config w section #:optional (position 'end))
  "CONFIG with W in SECTION of the bar -- 'left, 'center or 'right -- at POSITION:
'end, 'beginning, (after NAME) or (before NAME)."
  (unless (memq section bar-sections)
    (error "config-splice-into-bar: no such bar section" section))
  (config-splice config (bar-section-path section) (widget-name w) position))

(define (config-splice-out-of-bar config w)
  "CONFIG with W in no section of the bar.

EVERY SECTION, not the one it was put in: a user may have moved it, and a
disabled widget left in the bar is one the bar then cannot find."
  (fold (lambda (section cfg)
          (if (null? (config-ref cfg (bar-section-path section)))
              cfg
              (config-splice-delete cfg (bar-section-path section) (widget-name w))))
        config
        bar-sections))

;;; ---------------------------------------------------------------------------
;;; The generics, and their defaults
;;; ---------------------------------------------------------------------------

(define-generic widget-enable!)
(define-generic widget-disable!)

(define-method (widget-enable! (w <desktop-widget>) config)
  (config-splice-add-widget config w))

;; A BAR ITEM GOES IN THE BAR -- at the end of the right section, where most of
;; them are.  One that wants to be elsewhere, or out of the bar, says so.
(define-method (widget-enable! (w <bar-item-widget>) config)
  (config-splice-into-bar (config-splice-add-widget config w) w 'right 'end))

;; DISABLING UNDOES EVERY DEFAULT, so a widget that overrode `enable!' to choose
;; a section still disables correctly without overriding this.
(define-method (widget-disable! (w <desktop-widget>) config)
  (config-splice-out-of-bar (config-splice-remove-widget config w) w))

(define (widget-prototype name)
  "An object of the widget class NAME denotes, carrying its qualified name and
nothing else -- what `widget-enable!' and `widget-disable!' are called on.

`allocate-instance', not `make': making a widget attaches its option watchers,
which is real work for an object that only has to choose where it goes."
  (let ((p (allocate-instance (widget-class-named name) '())))
    (slot-set! p 'qualified-name name)
    p))
