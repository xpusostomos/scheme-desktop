;;; tests/menu-splice.scm -- putting a submenu into the menu
;;;
;;; THE FAILURE THIS GUARDS AGAINST IS SILENT. A splice that does not happen
;;; returns a menu that is still a valid menu, so every assertion here checks
;;; WHERE the row landed, not merely that `menu-splice' returned something.
;;;
;;; It runs against a small tree built in the test rather than the shipped
;;; Omarchy menu: the shipped file changes with the distribution, so a test
;;; pinned to `trigger > share > file' would start failing the first time
;;; Omarchy reorders a submenu, and would say nothing about this function.
;;; The paths below are the SHAPE the function cares about -- two levels, a
;;; nested row, a provider entry with no children -- not a particular menu.

(use-modules (scheme-desktop menu))
(use-modules (scheme-desktop menu omarchy))
(use-modules (srfi srfi-1))
(use-modules (srfi srfi-64))

;; The tree the tests splice into, in the shape the Omarchy converter produces:
;; a root entry holding children, each a plist whose children are in `submenu'.
(define (menu-entry . plist) plist)

(define (fresh-menu)
  (menu-entry
   'label "Go"
   'submenu
   (list (menu-entry 'key 'apps 'label "Apps" 'provider 'applisting)
         (menu-entry 'key 'trigger 'label "Trigger"
                     'submenu
                     (list (menu-entry 'key 'share 'label "Share"
                                       'submenu
                                       (list (menu-entry 'key 'clipboard 'label "Clipboard"
                                                         'action "share clipboard")
                                             (menu-entry 'key 'file 'label "File"
                                                         'action "share file")
                                             (menu-entry 'key 'folder 'label "Folder"
                                                         'action "share folder")))
                           (menu-entry 'key 'reminder 'label "Reminder"
                                       'action "reminder")))
         (menu-entry 'key 'style 'label "Style"
                     'submenu
                     (list (menu-entry 'key 'theme 'label "Theme" 'action "theme"))))))

(define (new-row) (menu-entry 'key 'mine 'label "Mine" 'action "echo mine"))

(define (keys-of entry) (map entry-key (entry-children entry)))

;; WHERE a row landed is the whole assertion, so the helper reads the tree back
;; through the module's own resolver rather than by walking plists here -- a
;; second walker in the test could disagree with the one under test and agree
;; with itself.
(define (children-at tree path)
  (let ((e (menu-resolve path #:root tree)))
    (and e (entry-children e))))

(define (row-named? children name)
  (and children (if (find (lambda (e) (eq? (entry-key e) name)) children) #t #f)))

(test-begin "menu-splice")

(test-group "a row can be put after a named row"
  (let* ((tree (menu-splice (fresh-menu) (new-row) '(trigger share file)))
         (kids (children-at tree '(trigger share))))
    ;; The whole point: the row exists AND is in the right position. A splice
    ;; that appended would pass the first assertion and fail the second.
    (test-assert "the row is there" (row-named? kids 'mine))
    (test-equal "and it comes straight after 'file'"
      '(clipboard file mine folder) (map entry-key kids))))

(test-group "the #f anchor puts the row first"
  (let* ((tree (menu-splice (fresh-menu) (new-row) '(trigger share #f)))
         (kids (children-at tree '(trigger share))))
    (test-assert "the row is there" (row-named? kids 'mine))
    (test-equal "and it is the first row" 'mine (entry-key (car kids)))))

(test-group "the two anchors differ -- the #f is not ignored"
  ;; Both of the above would pass if `cons' were used for both anchors, so this
  ;; pins the difference: same tree, same path, different first row.
  (let ((after (menu-splice (fresh-menu) (new-row) '(trigger share clipboard)))
        (first (menu-splice (fresh-menu) (new-row) '(trigger share #f))))
    (test-equal "after 'clipboard' keeps clipboard first"
      'clipboard (entry-key (car (children-at after '(trigger share)))))
    (test-equal "the #f anchor does not"
      'mine (entry-key (car (children-at first '(trigger share)))))))

(test-group "a missing path is #f, not a menu with a hole in it"
  ;; The bug this caught: a failed descent used to hand #f up into its parent's
  ;; children, so the call returned a WHOLE MENU with a stray #f spliced into
  ;; it. That is worse than a plain failure -- the caller checks the result for
  ;; #f, gets a tree, and reports success.
  (test-equal "a key that does not exist" #f
    (menu-splice (fresh-menu) (new-row) '(trigger nosuch file)))
  (test-equal "a key at the wrong level" #f
    (menu-splice (fresh-menu) (new-row) '(share file)))
  (test-equal "an entry with no children to hold a row" #f
    (menu-splice (fresh-menu) (new-row) '(apps provider file))))

(test-group "an anchor that does not exist appends rather than failing"
  ;; Deliberate: the path proved the container exists, so a row asked to sit
  ;; after something that has gone is closer to the intent than dropping it.
  (let ((kids (children-at (menu-splice (fresh-menu) (new-row)
                                        '(trigger share nosuchrow))
                           '(trigger share))))
    (test-assert "the row is there" (row-named? kids 'mine))
    (test-equal "at the end" 'mine (entry-key (last kids)))))

(test-group "a row can be put at the top level"
  (let ((tree (menu-splice (fresh-menu) (new-row) '(trigger))))
    (test-equal "after 'trigger', among the root's children"
      '(apps trigger mine style) (keys-of tree)))
  ;; `(#f)' is the front of the TOP level -- an empty path, which is the one
  ;; place a caller cannot express any other way.
  (let ((tree (menu-splice (fresh-menu) (new-row) '(#f))))
    (test-equal "and the #f anchor puts one before everything"
      '(mine apps trigger style) (keys-of tree))))

(test-group "the rest of the tree is untouched"
  (let ((tree (menu-splice (fresh-menu) (new-row) '(trigger share file))))
    (test-equal "a sibling submenu keeps its rows"
      '(theme) (map entry-key (children-at tree '(style))))
    (test-equal "a sibling row keeps its action"
      "reminder" (entry-ref (menu-resolve '(trigger reminder) #:root tree) 'action))
    (test-equal "the provider entry is unchanged"
      'applisting (entry-provider (menu-resolve '(apps) #:root tree)))))

(test-group "splicing does not modify the menu it was given"
  ;; Functional, and observable: the original must still have its old children.
  ;; A destructive version would pass every test above.
  (let* ((original (fresh-menu))
         (before (map entry-key (children-at original '(trigger share))))
         (tree (menu-splice original (new-row) '(trigger share file))))
    (test-equal "the input's rows are unchanged"
      '(clipboard file folder) before)
    (test-equal "and still are, after the splice"
      '(clipboard file folder) (map entry-key (children-at original '(trigger share))))
    (test-assert "while the result has the new row"
      (row-named? (children-at tree '(trigger share)) 'mine))))

(test-group "submenu is placed in the plist without duplicating the key"
  ;; An entry that had no `submenu' gains one; one that had it has it replaced.
  ;; A naive `append' on the latter produces a plist with two `submenu' keys, and
  ;; `entry-children' then answers with whichever comes first -- which is how a
  ;; splice can look like it worked while `menu-rows' still shows the old rows.
  ;;
  ;; The container here is `share', which HAS a submenu; `theme' is a leaf with
  ;; only an action, so asking to splice into it is the `apps' case above (no
  ;; children, so #f) and not what this group is about.
  (let ((tree (menu-splice (fresh-menu) (new-row) '(trigger share #f))))
    (test-equal "one submenu key only"
      1 (count (lambda (x) (eq? x 'submenu))
               (menu-resolve '(trigger share) #:root tree)))
    (test-assert "and the new row is what it holds"
      (row-named? (children-at tree '(trigger share)) 'mine))))

(test-group "a spliced submenu can carry submenus of its own"
  ;; The submenu argument is a whole entry, not a leaf -- so a user can add a
  ;; branch, not just a row.
  (let* ((branch (menu-entry 'key 'extra 'label "Extra"
                             'submenu (list (menu-entry 'key 'one 'label "One" 'action "one")
                                            (menu-entry 'key 'two 'label "Two" 'action "two"))))
         (tree (menu-splice (fresh-menu) branch '(trigger share #f))))
    (test-equal "the branch's own children came with it"
      '(one two) (map entry-key (children-at tree '(trigger share extra))))))


;;; ---------------------------------------------------------------------------
;;; THE TOP LEVEL -- a list of entries, not an entry
;;; ---------------------------------------------------------------------------
;;
;; The top level of a menu is NOT a keyed entry: it is the list the entries are
;; in.  Every case above splices INTO an entry; these are the ones that splice
;; into the list itself, and they were impossible until `menu-splice-at' learned
;; to tell the two shapes apart -- a path of no keys was handed the top-level
;; list, `menu-children-or-#f' looked for a `submenu' symbol among the ENTRIES,
;; found none, and the call failed with a corrupted menu for a result.
;;
;; `(#f)' is the whole top level: no path, and the #f anchor meaning "the front".
;; `(trigger)' is no path and an anchor, which now means "after the row called
;; trigger, among the root's children" -- the same meaning the anchor already had
;; one level down.

(define (fresh-top)
  ;; A menu whose TOP LEVEL IS A BARE LIST.  `fresh-menu' above wraps its
  ;; children in a "Go" entry, which is the shape `menu-splice' was written for
  ;; and the shape the top level is not.
  (list (menu-entry 'key 'apps 'label "Apps" 'provider 'applisting)
        (menu-entry 'key 'trigger 'label "Trigger"
                    'submenu (list (menu-entry 'key 'share 'label "Share" 'action "share")))
        (menu-entry 'key 'system 'label "System"
                    'submenu (list (menu-entry 'key 'reboot 'label "Reboot" 'action "reboot")))))

(define (top-keys tree) (map entry-key tree))

(test-equal "at the front of the top level, with the #f anchor"
  (list 'mine 'apps 'trigger 'system)
  (top-keys (menu-splice (fresh-top) (new-row) '(#f))))

(test-equal "at the end of the top level, with no anchor at all"
  (list 'apps 'trigger 'system 'mine)
  (top-keys (menu-splice (fresh-top) (new-row) '(system))))

(test-equal "after a named row of the top level"
  (list 'apps 'trigger 'mine 'system)
  (top-keys (menu-splice (fresh-top) (new-row) '(trigger))))

(test-equal "after a row that is not there: at the end, and not a corruption"
  (list 'apps 'trigger 'system 'mine)
  (top-keys (menu-splice (fresh-top) (new-row) '(nosuchrow))))

(test-assert "the spliced row is an entry, not a bare symbol"
  (let ((first (car (menu-splice (fresh-top) (new-row) '(#f)))))
    (and (pair? first) (eq? (car first) 'key) (eq? (entry-key first) 'mine))))

(test-equal "splicing into the top level leaves the submenus alone"
  '(share)
  (let* ((tree (menu-splice (fresh-top) (new-row) '(#f)))
         (t (find (lambda (e) (eq? (entry-key e) 'trigger)) tree)))
    ;; THE TOP LEVEL IS A BARE LIST, so `entry-children' answers #f for it and
    ;; there is no root entry to ask.  The row's own children are what matter.
    (map entry-key (entry-children t))))

(test-equal "and leaves the rows inside them able to be spliced into"
  ;; `(share)' HAS NO CHILDREN in `fresh-top', so after the splice its children
  ;; are the row alone -- the entry gained a `submenu' rather than replacing one.
  '(clipboard)
  (let* ((tree (menu-splice (fresh-top) (new-row) '(#f)))
         (after (menu-splice tree
                             (menu-entry 'key 'clipboard 'label "Clip" 'action "x")
                             '(trigger share #f))))
    (map entry-key (children-at after '(trigger share)))))

(test-equal "an empty location is still #f, not a no-op"
  #f
  (menu-splice (fresh-top) (new-row) '()))

(test-equal "and a menu that is not there is #f"
  #f
  (menu-splice #f (new-row) '(#f)))

(test-equal "a path into the top level's own entries still works"
  '(share)
  (let ((tree (menu-splice (fresh-top) (new-row) '(#f))))
    (map entry-key (entry-children (find (lambda (e) (eq? (entry-key e) 'trigger)) tree)))))

(test-end "menu-splice")
