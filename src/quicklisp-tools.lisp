;;; src/quicklisp-tools.lisp
;;; ABOUTME: Read-only Quicklisp introspection: dry-run, system info, search

(in-package #:cl-mcp-server.quicklisp-tools)

;;; ==========================================================================
;;; Rationale
;;;
;;; The server already had QUICKLOAD (loads, downloads, mutates) and a search
;;; that returned bare system names. That is the wrong balance: the mutating
;;; tool is easy to call and the informational tools are too thin to answer
;;; the questions you actually have before calling it --
;;;
;;;   "what will this pull in?"   "is it already installed?"
;;;   "which of these 8 matches is the real entry point?"
;;;   "is anything else using this library?"
;;;
;;; Everything here is READ-ONLY and OFFLINE: it queries the local dist index
;;; that Quicklisp already has on disk. Nothing downloads, nothing installs.
;;; That matters for more than safety -- a tool that might fetch 40MB does not
;;; get called speculatively, and a tool that is not called speculatively does
;;; not help you avoid guessing.
;;;
;;; Deliberately NOT exposed: update-dist, update-client, uninstall. Those are
;;; slow, network-bound and occasionally destructive; an agent should not
;;; upgrade someone's whole dist mid-task. DIST-STATUS reports that an update
;;; is available and leaves the decision to a human.
;;; ==========================================================================

;;; ==========================================================================
;;; Quicklisp access
;;;
;;; Symbols are resolved at RUNTIME rather than read time so this file
;;; compiles in an image without Quicklisp (matching the convention already
;;; used in asdf-tools.lisp). Reading ql-dist:foo at compile time in such an
;;; image is a package error, not a graceful degradation.
;;; ==========================================================================

(define-condition quicklisp-unavailable (error)
  ((detail :initarg :detail :initform nil :reader quicklisp-unavailable-detail))
  (:report (lambda (c s)
             (format s "Quicklisp is not available in this image~@[: ~A~]"
                     (quicklisp-unavailable-detail c)))))

(defun quicklisp-available-p ()
  "True when the Quicklisp client packages are present."
  (and (find-package :ql) (find-package :ql-dist) t))

(defun %fn (package name)
  "Resolve PACKAGE:NAME to a function object, or signal QUICKLISP-UNAVAILABLE."
  (let* ((pkg (find-package package))
         (sym (and pkg (find-symbol (string name) pkg))))
    (unless (and sym (fboundp sym))
      (error 'quicklisp-unavailable
             :detail (format nil "~A:~A is missing" package name)))
    (fdefinition sym)))

(defun %call (package name &rest args)
  "Call PACKAGE:NAME with ARGS."
  (apply (%fn package name) args))

(defun %safe (thunk &optional default)
  "Run THUNK, returning DEFAULT if it signals.
Dist metadata is inconsistent across Quicklisp versions -- a missing slot on
one release should degrade one field, not fail the whole query."
  (handler-case (funcall thunk) (error () default)))

;;; Thin named wrappers, so the rest of the file reads like ordinary Lisp.

(defun ql-find-system (name)   (%safe (lambda () (%call :ql-dist "FIND-SYSTEM" name))))
(defun ql-find-dist (name)     (%safe (lambda () (%call :ql-dist "FIND-DIST" name))))
(defun ql-name (object)        (%safe (lambda () (%call :ql-dist "NAME" object))))
(defun ql-release (system)     (%safe (lambda () (%call :ql-dist "RELEASE" system))))
(defun ql-required (system)    (%safe (lambda () (%call :ql-dist "REQUIRED-SYSTEMS" system)) nil))
(defun ql-installedp (release) (%safe (lambda () (and (%call :ql-dist "INSTALLEDP" release) t))))
(defun ql-project-name (rel)   (%safe (lambda () (%call :ql-dist "PROJECT-NAME" rel))))
(defun ql-archive-url (rel)    (%safe (lambda () (%call :ql-dist "ARCHIVE-URL" rel))))
(defun ql-archive-size (rel)   (%safe (lambda () (%call :ql-dist "ARCHIVE-SIZE" rel))))
(defun ql-provided (rel)       (%safe (lambda () (%call :ql-dist "PROVIDED-SYSTEMS" rel)) nil))
(defun ql-system-file (system) (%safe (lambda () (%call :ql-dist "SYSTEM-FILE-NAME" system))))
(defun ql-dist-version (dist)  (%safe (lambda () (%call :ql-dist "VERSION" dist))))
(defun ql-enabled-dists ()     (%safe (lambda () (%call :ql-dist "ENABLED-DISTS")) nil))
(defun ql-installed-releases (dist)
  (%safe (lambda () (%call :ql-dist "INSTALLED-RELEASES" dist)) nil))
(defun ql-dist-provided-systems (dist)
  (%safe (lambda () (%call :ql-dist "PROVIDED-SYSTEMS" dist)) nil))
(defun ql-available-update (dist)
  (%safe (lambda () (%call :ql-dist "AVAILABLE-UPDATE" dist))))
(defun ql-apropos-list (term)
  (%safe (lambda () (%call :ql-dist "SYSTEM-APROPOS-LIST" term)) nil))

;;; ==========================================================================
;;; Formatting helpers
;;; ==========================================================================

(defun human-bytes (n)
  "Render N bytes in a readable unit."
  (cond ((null n) "unknown")
        ((< n 1024) (format nil "~D B" n))
        ((< n (* 1024 1024)) (format nil "~,1F KB" (/ n 1024.0)))
        (t (format nil "~,1F MB" (/ n (* 1024.0 1024.0))))))

(defun system-installed-p (name)
  "Is the system NAME provided by an already-installed release?"
  (let* ((sys (ql-find-system name))
         (rel (and sys (ql-release sys))))
    (and rel (ql-installedp rel))))

;;; ==========================================================================
;;; Dependency walking
;;; ==========================================================================

(defun collect-dependencies (name)
  "Transitively collect every dist system reachable from NAME.

Returns (values ordered-names unknown-names). UNKNOWN-NAMES are requirements
that Quicklisp cannot resolve to a dist system -- typically implementation
built-ins such as SB-BSD-SOCKETS, or systems supplied from local-projects.
They are reported rather than silently dropped, because a name appearing
there is the usual explanation for a dependency that 'should' be present."
  (let ((seen (make-hash-table :test #'equal))
        (order nil)
        (unknown nil))
    (labels ((walk (n)
               (let ((key (string-downcase n)))
                 (unless (gethash key seen)
                   (setf (gethash key seen) t)
                   (let ((sys (ql-find-system n)))
                     (cond
                       ((null sys) (push n unknown))
                       (t (push (ql-name sys) order)
                          (dolist (dep (ql-required sys)) (walk dep)))))))))
      (walk name))
    (values (nreverse order) (nreverse unknown))))

(defun ql-dry-run (name)
  "Compute what QUICKLOAD of NAME would do, WITHOUT downloading anything.

Returns a plist:
  :found-p        does NAME resolve to a dist system
  :total          systems in the transitive closure
  :missing        systems whose release is not yet installed
  :present        count already installed
  :unknown        requirements not resolvable in the dist
  :releases       distinct releases that would be fetched
  :download-bytes summed archive size of those releases (NIL if unknown)"
  (let ((root (ql-find-system name)))
    (if (null root)
        (list :found-p nil :name name)
        (multiple-value-bind (names unknown) (collect-dependencies name)
          (let ((missing nil) (present 0)
                (releases (make-hash-table :test #'equal))
                (bytes 0) (bytes-known t))
            (dolist (n names)
              (let* ((sys (ql-find-system n))
                     (rel (and sys (ql-release sys))))
                (cond
                  ((and rel (ql-installedp rel)) (incf present))
                  (rel
                   (push n missing)
                   ;; Releases are shared by many systems; count each once.
                   (let ((rname (or (ql-name rel) (ql-project-name rel))))
                     (unless (gethash rname releases)
                       (setf (gethash rname releases) t)
                       (let ((size (ql-archive-size rel)))
                         (if (numberp size) (incf bytes size)
                             (setf bytes-known nil)))))))))
            (list :found-p t
                  :name (ql-name root)
                  :total (length names)
                  :missing (sort missing #'string<)
                  :present present
                  :unknown unknown
                  :releases (let (r) (maphash (lambda (k v) (declare (ignore v))
                                                (push k r))
                                              releases)
                              (sort r #'string<))
                  :download-bytes (and bytes-known bytes)))))))

(defun format-ql-dry-run (info)
  "Render DRY-RUN output. Returns (values text error-p)."
  (if (not (getf info :found-p))
      (values (format nil "No Quicklisp system named ~A.~%~%~
Try quicklisp-search to find the right name."
                      (getf info :name))
              t)
      (values
       (with-output-to-string (s)
         (let ((missing (getf info :missing)))
           (format s "quickload ~A~%~%" (getf info :name))
           (format s "  ~D system~:P in the dependency tree~%" (getf info :total))
           (format s "  ~D already installed~%" (getf info :present))
           (if (null missing)
               (format s "~%Nothing to download - everything is already installed.~%")
               (progn
                 (format s "  ~D would be downloaded (~D release~:P, ~A)~%~%"
                         (length missing)
                         (length (getf info :releases))
                         (human-bytes (getf info :download-bytes)))
                 (format s "Would download:~%")
                 (dolist (m missing) (format s "  ~A~%" m))))
           (let ((unknown (getf info :unknown)))
             (when unknown
               (format s "~%Not resolvable in the dist (built-in, or from ~
local-projects):~%")
               (dolist (u unknown) (format s "  ~A~%" u))))))
       nil)))

;;; ==========================================================================
;;; System info
;;; ==========================================================================

(defun ql-system-info (name)
  "Everything the dist knows about system NAME."
  (let ((sys (ql-find-system name)))
    (if (null sys)
        (list :found-p nil :name name)
        (let ((rel (ql-release sys)))
          (list :found-p t
                :name (ql-name sys)
                :installed-p (and rel (ql-installedp rel))
                :requires (sort (copy-list (ql-required sys)) #'string<)
                :system-file (ql-system-file sys)
                :release (and rel (ql-name rel))
                :project (and rel (ql-project-name rel))
                :archive-url (and rel (ql-archive-url rel))
                :archive-size (and rel (ql-archive-size rel))
                :siblings (when rel
                            (sort (remove (ql-name sys)
                                          (mapcar #'ql-name (ql-provided rel))
                                          :test #'equal)
                                  #'string<))
                :location (%safe (lambda ()
                                   (let ((p (%call :ql "WHERE-IS-SYSTEM" name)))
                                     (and p (namestring p))))))))))

(defun format-ql-system-info (info)
  "Render SYSTEM-INFO. Returns (values text error-p)."
  (if (not (getf info :found-p))
      (values (format nil "No Quicklisp system named ~A.~%~%~
Try quicklisp-search to find the right name." (getf info :name))
              t)
      (values
       (with-output-to-string (s)
         (format s "~A  [~:[available~;installed~]]~%~%"
                 (getf info :name) (getf info :installed-p))
         (when (getf info :release)
           (format s "  Release:    ~A~%" (getf info :release)))
         (when (and (getf info :project)
                    (not (equal (getf info :project) (getf info :name))))
           (format s "  Project:    ~A~%" (getf info :project)))
         (when (getf info :system-file)
           (format s "  ASD file:   ~A.asd~%" (getf info :system-file)))
         (when (getf info :location)
           (format s "  Installed:  ~A~%" (getf info :location)))
         (when (getf info :archive-size)
           (format s "  Archive:    ~A~@[  ~A~]~%"
                   (human-bytes (getf info :archive-size))
                   (getf info :archive-url)))
         (let ((req (getf info :requires)))
           (format s "~%  Requires (~D):~%" (length req))
           (if req
               (dolist (r req)
                 (format s "    ~A~@[  [installed]~*~]~%" r (system-installed-p r)))
               (format s "    (none)~%")))
         (let ((sib (getf info :siblings)))
           (when sib
             (format s "~%  Same release also provides:~%")
             (dolist (x sib) (format s "    ~A~%" x))))
         (format s "~%  Use quicklisp-dry-run to see what loading this would fetch.~%"))
       nil)))

;;; ==========================================================================
;;; Search
;;; ==========================================================================

(defun ql-search-systems (term &key (limit 40))
  "Search the dist for TERM, returning structured entries.

Uses SYSTEM-APROPOS-LIST, which returns SYSTEM objects rather than strings,
so install state and release come along for free. Exact and prefix matches
are ordered first: a search for 'telegram' should not bury the actual entry
point under its own -tests and -docs subsystems."
  (let* ((down (string-downcase term))
         (systems (ql-apropos-list term))
         (entries
           (mapcar (lambda (sys)
                     (let* ((n (ql-name sys))
                            (rel (ql-release sys)))
                       (list :name n
                             :installed-p (and rel (ql-installedp rel))
                             :release (and rel (ql-name rel))
                             :subsystem-p (and n (or (find #\/ n)
                                                     (search "-test" (string-downcase n))
                                                     (search "-doc" (string-downcase n)))
                                               t))))
                   systems)))
    (flet ((rank (e)
             (let ((n (string-downcase (or (getf e :name) ""))))
               (cond ((string= n down) 0)
                     ((getf e :subsystem-p) 3)
                     ((and (>= (length n) (length down))
                           (string= down (subseq n 0 (length down)))) 1)
                     (t 2)))))
      (let ((sorted (stable-sort (copy-list entries) #'< :key #'rank)))
        (list :term term
              :total (length sorted)
              :entries (subseq sorted 0 (min limit (length sorted))))))))

(defun format-ql-search-results (result)
  "Render SEARCH-SYSTEMS. Returns (values text error-p)."
  (let ((entries (getf result :entries)))
    (if (null entries)
        (values (format nil "No Quicklisp systems match ~A." (getf result :term)) t)
        (values
         (with-output-to-string (s)
           (format s "~D system~:P matching ~A~@[ (showing ~D)~]:~%~%"
                   (getf result :total) (getf result :term)
                   (when (< (length entries) (getf result :total))
                     (length entries)))
           (dolist (e entries)
             (format s "  ~24A ~11A~@[ ~A~]~%"
                     (getf e :name)
                     (if (getf e :installed-p) "[installed]" "[available]")
                     (getf e :release)))
           (format s "~%Use quicklisp-system-info for details, ~
quicklisp-dry-run to see download cost.~%"))
         nil))))

;;; ==========================================================================
;;; Reverse dependencies
;;; ==========================================================================

(defun ql-who-depends-on (name &key (limit 60))
  "Systems in the dist that directly require NAME."
  (let ((users (%safe (lambda () (%call :ql "WHO-DEPENDS-ON" name)) nil)))
    (list :name name
          :total (length users)
          :users (subseq (sort (copy-list users) #'string<)
                         0 (min limit (length users))))))

(defun format-ql-who-depends-on (info)
  "Render WHO-DEPENDS-ON. Returns (values text error-p)."
  (let ((users (getf info :users)))
    (if (null users)
        (values (format nil "Nothing in the dist depends on ~A.~%~%~
Either it is a leaf library, or the name is wrong - check quicklisp-search."
                        (getf info :name))
                nil)
        (values
         (with-output-to-string (s)
           (format s "~D system~:P depend~:[s~;~] on ~A~@[ (showing ~D)~]:~%~%"
                   (getf info :total) (/= 1 (getf info :total)) (getf info :name)
                   (when (< (length users) (getf info :total)) (length users)))
           (dolist (u users) (format s "  ~A~%" u)))
         nil))))

;;; ==========================================================================
;;; Dist status
;;; ==========================================================================

(defun ql-dist-status ()
  "Health and freshness of the local Quicklisp installation."
  (let ((dists
          (mapcar
           (lambda (d)
             (let ((update (ql-available-update d)))
               (list :name (ql-name d)
                     :version (ql-dist-version d)
                     :installed-releases (length (ql-installed-releases d))
                     :provided-systems (length (ql-dist-provided-systems d))
                     :update-available (and update (ql-dist-version update)))))
           (ql-enabled-dists))))
    (list :client-version (%safe (lambda () (%call :ql "CLIENT-VERSION")))
          :quicklisp-home (%safe (lambda ()
                                   (let ((h (symbol-value
                                             (find-symbol "*QUICKLISP-HOME*" :ql-setup))))
                                     (and h (namestring h)))))
          :dists dists)))

(defun format-ql-dist-status (info)
  "Render DIST-STATUS. Returns (values text error-p)."
  (values
   (with-output-to-string (s)
     (format s "Quicklisp~%")
     (format s "  Client version: ~A~%" (or (getf info :client-version) "unknown"))
     (when (getf info :quicklisp-home)
       (format s "  Home:           ~A~%" (getf info :quicklisp-home)))
     (dolist (d (getf info :dists))
       (format s "~%  dist ~A~%" (getf d :name))
       (format s "    version:            ~A~%" (getf d :version))
       (format s "    systems available:  ~D~%" (getf d :provided-systems))
       (format s "    releases installed: ~D~%" (getf d :installed-releases))
       (if (getf d :update-available)
           (format s "    UPDATE AVAILABLE:   ~A  (run (ql:update-dist \"~A\") yourself)~%"
                   (getf d :update-available) (getf d :name))
           (format s "    up to date~%"))))
   nil))
