;;; tools/plugin-cli.scm -- `scheme-desktop install / remove / enable / disable'
;;;
;;;   scheme-desktop install URL     clone a plugin, then enable all its widgets
;;;   scheme-desktop remove NAME     disable it, then delete it
;;;   scheme-desktop enable NAME     add all its widgets to the config
;;;   scheme-desktop disable NAME    take them out; it stays installed
;;;   scheme-desktop update NAME     pull its latest commits; options are kept
;;;   scheme-desktop plugins         what is installed
;;;
;;; WHETHER THE SHELL IS RUNNING DECIDES WHERE A CHANGE GOES.  A running shell
;;; REWRITES config.scm from what it holds in memory, so an edit made to the file
;;; underneath it is overwritten the next time it saves.  So when it is running,
;;; the change is sent to it -- evaluated in the shell, which applies it to itself
;;; and saves -- and only when it is not is the file edited here.
;;;
;;; THE CLONE AND THE DELETE ARE ALWAYS DONE HERE, never in the shell: they are
;;; slow, and the shell's main loop must not wait on `git'.

(use-modules (scheme-desktop manifest)
             (scheme-toolkit repl-client)
             (ice-9 format))

(define instance "scheme-desktop")

(define (shell-running?)
  "Whether a scheme-desktop shell answers on its back door."
  (catch #t
    (lambda () (client-connect instance) #t)
    (lambda args #f)))

(define (in-shell! expression)
  "Evaluate EXPRESSION in the running shell; fail with the shell's own words."
  (call-with-values (lambda () (run-shell-expression instance expression))
    (lambda (text failed)
      (when failed
        (format (current-error-port) "scheme-desktop: the shell said:~%~a~%" text)
        (exit 1))
      #t)))

(define (enable-or-disable! verb name)
  "Run (plugin-enable! NAME) or (plugin-disable! NAME) where the config lives."
  (if (shell-running?)
      (in-shell! (format #f "((@ (scheme-desktop manifest) plugin-~a!) ~s)" verb name))
      ((if (string=? verb "enable") plugin-enable! plugin-disable!) name))
  (format #t "~ad ~a~a~%" verb name (if (shell-running?) "" " (config.scm; the shell is not running)")))

(define (usage)
  (format #t "scheme-desktop install URL | remove NAME | enable NAME | disable NAME | update NAME | plugins~%")
  2)

(define (main args)
  (catch #t
    (lambda ()
      (cond
       ((and (= (length args) 2) (string=? (car args) "install"))
        (let ((name (plugin-clone! (cadr args))))
          (format #t "installed ~a in ~a~%" name (plugins-directory))
          (enable-or-disable! "enable" name))
        0)
       ((and (= (length args) 2) (string=? (car args) "remove"))
        (enable-or-disable! "disable" (cadr args))
        (plugin-delete! (cadr args))
        (format #t "removed ~a~%" (cadr args))
        0)
       ((and (= (length args) 2) (member (car args) '("enable" "disable")))
        (enable-or-disable! (car args) (cadr args))
        0)
       ((and (= (length args) 2) (string=? (car args) "update"))
        (plugin-update! (cadr args))
        (format #t "updated ~a~a~%" (cadr args)
                (if (shell-running?) "; restart the shell to run the new code" ""))
        0)
       ((and (= (length args) 1) (string=? (car args) "plugins"))
        (for-each (lambda (n) (format #t "~a~%" n)) (plugin-names))
        0)
       (else (usage))))
    (lambda (key . rest)
      (format (current-error-port) "scheme-desktop: ~a~%"
              (if (and (pair? rest) (pair? (cdr rest)) (string? (cadr rest)))
                  (apply format #f (cadr rest) (if (pair? (cddr rest)) (caddr rest) '()))
                  (cons key rest)))
      1)))

(exit (main (cdr (command-line))))
