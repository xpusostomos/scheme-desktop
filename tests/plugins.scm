;;; tests/plugins.scm -- this shell's launcher plugins
;;;
;;; Every assertion here is about a failure that LOOKS LIKE SUCCESS.  A plugin
;;; whose search function is misspelt returns no results, which is
;;; indistinguishable from a query that legitimately matched nothing -- so the
;;; tests assert on inputs whose answer is known, not merely on "did not throw".

(use-modules (scheme-toolkit gi))
(use-modules (scheme-toolkit launcher))
(use-modules (scheme-toolkit reactive))
(use-modules (scheme-desktop plugins))
(use-modules (srfi srfi-1))
(use-modules (srfi srfi-13))
(use-modules (srfi srfi-64))

(install-default-plugins!)

(test-begin "plugins")

(test-group "every plugin this shell ships is registered"
  (let ((names (map plugin-name (plugins))))
    (for-each
     (lambda (expected)
       (test-assert (format #f "~a is registered" expected)
         (member expected names)))
     '("Applications" "Web Search" "Run Command" "Clipboard"))))

(test-group "the prefixed plugins claim their prefix"
  (test-equal "web search owns ?" "?" (plugin-prefix (find (lambda (p)
                                                             (equal? "Web Search"
                                                                     (plugin-name p)))
                                                           (plugins))))
  (test-equal "clipboard owns >" ">" (plugin-prefix (find (lambda (p)
                                                            (equal? "Clipboard"
                                                                    (plugin-name p)))
                                                          (plugins)))))

(test-group "applications are found by a real query"
  ;; The assertion that catches a misspelt search function.  "firefox" is
  ;; installed on this machine; if the plugin returns nothing for it, the plugin
  ;; is broken rather than the query being unlucky.
  (let ((titles (map result-title (route "firefox"))))
    (test-assert "a known application is found" (pair? titles))
    (test-assert "and it is the one asked for"
      (any (lambda (t) (string-contains-ci t "firefox")) titles))))

(test-group "a query that matches nothing is empty, not an error"
  ;; AstalApps' fuzzy_query answers #f -- not '() -- when nothing matches, and a
  ;; for-each over #f raises.  That was a real bug here.
  (let ((titles (route "zzzznothingmatchesthis")))
    (test-assert "an empty list" (list? titles))
    (test-equal "with no results" '() titles)))

(test-group "the prefix is stripped before the plugin sees it"
  ;; `?linux' must search the web for "linux", not for "?linux".
  (let ((titles (map result-title (route "?linux"))))
    (test-assert "the query is the search term" (member "linux" titles))
    (test-assert "not the raw input"
      (not (any (lambda (t) (string-contains t "?")) titles)))))

(test-group "running a command offers the command"
  (let ((titles (map result-title (route "!echo hi"))))
    (test-equal "the command is the row" '("echo hi") titles)))

(test-group "clipboard history survives being empty or absent"
  ;; take on an empty list is an error in srfi-1, and an empty history is the
  ;; normal state on a machine without cliphist.
  (let ((titles (route ">zzzznothingmatchesthis")))
    (test-assert "an empty list, not an error" (list? titles))))

(test-group "url encoding keeps a query intact"
  ;; A query with a space or an ampersand must reach the search engine whole;
  ;; unencoded, "rock & roll" truncates at the ampersand.
  (let ((encoded (url-encode "rock & roll")))
    (test-assert "an ampersand is escaped"
      (and encoded (not (string-contains encoded "&"))))
    (test-assert "a space is escaped"
      (and encoded (not (string-contains encoded " "))))
    (test-assert "and the letters survive" (string-contains encoded "rock"))))

(test-end "plugins")
