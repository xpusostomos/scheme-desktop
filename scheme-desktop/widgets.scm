;;; (scheme-desktop widgets) -- the shell's root widget
;;;
;;; WHAT USED TO BE HERE: an import of every widget module, so that one module
;;; could see every widget class, and `default-widget-names', the list a fresh
;;; install started with.  Both are gone, and both for the plugin system:
;;;
;;;   WHICH WIDGETS EXIST is the manifests' -- `widgets.scm' at the top of this
;;;   tree and of every plugin, each entry naming the MODULE a class is in, so a
;;;   class is loaded from its own module and nothing has to import them all.
;;;
;;;   WHICH ARE LIVE is config.scm's, and a first run WRITES that file by letting
;;;   each built-in widget enable itself (see (scheme-desktop manifest)).  There
;;;   is no second default list to keep in step with the first.
;;;
;;; WHAT IS LEFT is the root's class.  The shell makes it with the list it read
;;; from config.scm, so it has its widgets before the rest of the file -- their
;;; options -- is applied to them.

(define-module (scheme-desktop widgets)
  #:use-module (scheme-toolkit app)
  #:use-module (oop goops)
  #:export (<desktop-root-widget>))

;; THE SHELL'S ROOT.  A subclass of the toolkit's root rather than the toolkit's
;; class itself, so this shell has a class of its own to hang shell-level
;; behaviour on when it needs some; today it adds nothing.
(define-class <desktop-root-widget> (<root-desktop-widget>))
