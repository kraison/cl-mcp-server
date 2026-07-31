;;; src/error-format.lisp
;;; ABOUTME: Condition formatting for MCP error responses

(in-package #:cl-mcp-server.error-format)

;;; Configuration

(defparameter *max-backtrace-depth* 20
  "Maximum number of backtrace frames to include")

(defparameter *print-backtrace-p* t
  "Whether to include backtrace in error output")

(defparameter *backtrace-noise-markers*
  '("TRIVIAL-BACKTRACE" "CL-MCP" "SB-INT:SIMPLE-EVAL-IN-LEXENV"
    "SB-IMPL::%SIMPLE-EVAL" "SB-C::%COMPILE-IN-LEXENV"
    "SB-C:EVAL-WITH-COMPILE-IN-LEXENV" "SB-FASL::" "SB-IMPL::PROCESS-EVAL"
    "SB-IMPL::TOPLEVEL-INIT" "SB-IMPL::%START-LISP" "SB-IMPL::START-LISP"
    "SB-IMPL::PROCESS-SCRIPT" "SB-IMPL::LOAD-SCRIPT" "SB-DEBUG::"
    "EVAL-TLF" "SB-INT:LOAD-AS-SOURCE" "SB-UNIX::"
    "top level form" "SB-C::%DO-FORMS-FROM-INFO" "SB-KERNEL:FORM"
    "WITHOUT-INTERRUPTS-BODY" "LOAD-STREAM" "CALL-WITH-LOAD-BINDINGS")
  "Substrings identifying frames that belong to the MCP server or the
evaluator/loader plumbing rather than to user code. Matching is by
SUBSTRING, not prefix: SBCL wraps plumbing in (LABELS ...) and (FLET ...)
forms, so the telltale package marker is often not at the start of the
frame. These dominate every backtrace and bury the one or two frames that
actually matter, so they are filtered by default.")

(defparameter *filter-backtrace-noise-p* t
  "When true, drop frames matching *backtrace-noise-markers*.")

(defun %noise-frame-p (line)
  "Return T if backtrace LINE is server/evaluator plumbing, not user code."
  (some (lambda (marker) (search marker line :test #'char-equal))
        *backtrace-noise-markers*))

;;; Condition type extraction

(defun condition-type-name (condition)
  "Get the type name of a condition as a string"
  (string-upcase (symbol-name (type-of condition))))

;;; Message extraction

(defun condition-message (condition)
  "Extract the message from a condition"
  (handler-case
      (princ-to-string condition)
    (error ()
      (format nil "~a" (type-of condition)))))

;;; Backtrace formatting

(defun format-backtrace ()
  "Capture and format the current backtrace.
   Returns a string with numbered frames."
  (with-output-to-string (s)
    (trivial-backtrace:print-backtrace-to-stream s)))

(defun truncate-backtrace (backtrace-string)
  "Truncate backtrace to *max-backtrace-depth* frames.
When *filter-backtrace-noise-p* is true, frames belonging to the MCP server
and the eval plumbing are dropped first, so the user sees their own code.
If filtering would remove everything, the unfiltered trace is kept."
  (with-input-from-string (in backtrace-string)
    (let* ((all (loop for line = (read-line in nil nil)
                      while line collect line))
           (kept (if *filter-backtrace-noise-p*
                     (remove-if #'%noise-frame-p all)
                     all))
           (kept (or kept all))
           (dropped (- (length all) (length kept))))
      (with-output-to-string (out)
        ;; The "hidden frames" note is an annotation, not a frame, so it must
        ;; not eat into the *max-backtrace-depth* budget: callers (and tests)
        ;; reasonably expect at most depth+1 lines of actual trace.
        (let ((shown 0))
          (loop for line in kept
                while (< shown *max-backtrace-depth*)
                do (write-line line out) (incf shown))
          (when (> (length kept) *max-backtrace-depth*)
            (write-line "..." out))
          (when (and (plusp dropped) (< shown *max-backtrace-depth*))
            (format out "; (~D internal frame~:P hidden)~%" dropped)))))))

;;; Main formatting functions

(defun format-error (condition)
  "Format an error condition for MCP response.
Includes the available restarts, which are the single most useful piece of
information Lisp offers about a live condition and were previously computed
but never shown on this path."
  (with-output-to-string (s)
    (format s "[ERROR] ~a~%" (condition-type-name condition))
    (format s "~a~%" (condition-message condition))
    (let ((restarts (ignore-errors (capture-restarts condition))))
      (when restarts
        (format s "~%[Restarts]~%")
        (loop for r in restarts
              for i from 0
              do (format s "  ~D: [~A] ~A~%"
                         i (or (getf r :name) "unnamed") (getf r :description)))))
    (when *print-backtrace-p*
      (format s "~%[Backtrace]~%")
      (write-string (truncate-backtrace (format-backtrace)) s))))

(defun format-warning (condition)
  "Format a warning condition."
  (format nil "~a: ~a"
          (condition-type-name condition)
          (condition-message condition)))

(defun format-condition (condition)
  "Format any condition appropriately"
  (if (typep condition 'warning)
      (format-warning condition)
      (format-error condition)))

;;; Error capture macro

(defmacro with-error-capture (&body body)
  "Execute BODY, capturing any errors and warnings.
Returns three values:
  1. List of return values from BODY (or NIL on error)
  2. Formatted error string (or NIL on success)
  3. List of formatted warning strings"
  (let ((warnings (gensym "WARNINGS"))
        (error-string (gensym "ERROR-STRING"))
        (results (gensym "RESULTS")))
    `(let ((,warnings nil)
           (,error-string nil)
           (,results nil))
       (handler-bind
           ((warning (lambda (c)
                       (push (format-warning c) ,warnings)
                       (muffle-warning c))))
         (handler-case
             (setf ,results (multiple-value-list (progn ,@body)))
           (error (c)
             (setf ,error-string (format-error c)))))
       (values ,results ,error-string (nreverse ,warnings)))))

;;; ==========================================================================
;;; Phase C: Structured Error Capture
;;; ==========================================================================

(defun capture-restarts (condition)
  "Capture available restarts for CONDITION as structured data."
  (loop for restart in (compute-restarts condition)
        collect (list :name (let ((name (restart-name restart)))
                              (when name (string name)))
                      :description (princ-to-string restart))))

(defun parse-backtrace-string (bt-string &optional (max-frames *max-backtrace-depth*))
  "Parse a backtrace string into structured frames.
Returns list of plists with :number, :function.
When *filter-backtrace-noise-p* is true, MCP-server and eval-plumbing frames
are dropped so that user code is what remains. If filtering would remove
every frame, the unfiltered list is kept rather than showing nothing."
  (with-input-from-string (s bt-string)
    ;; Skip header line (Backtrace for: ...)
    (read-line s nil nil)
    (let* ((all (loop for line = (read-line s nil nil)
                      while line
                      for parsed = (parse-backtrace-line line)
                      when parsed collect parsed))
           (kept (if *filter-backtrace-noise-p*
                     (remove-if (lambda (frame)
                                  (%noise-frame-p (or (getf frame :function) "")))
                                all)
                     all))
           (kept (or kept all)))
      (subseq kept 0 (min (length kept) max-frames)))))

(defun parse-backtrace-line (line)
  "Parse a single backtrace line like '0: (FUNCTION ARG1 ARG2)'.
Returns plist with :number and :function, or NIL if unparseable."
  (let ((colon-pos (position #\: line)))
    (when (and colon-pos (> colon-pos 0))
      (let ((num-str (string-trim " " (subseq line 0 colon-pos)))
            (rest (string-trim " " (subseq line (1+ colon-pos)))))
        (handler-case
            (list :number (parse-integer num-str)
                  :function rest)
          (error () nil))))))

(defun capture-structured-error (condition)
  "Capture comprehensive structured info about CONDITION.
Called at the point of error before unwinding.
Returns a plist with:
  :type - condition type name (string)
  :message - formatted condition message
  :condition-class - full class name
  :backtrace-string - raw backtrace as string
  :backtrace - parsed backtrace as list of frame plists
  :restarts - list of available restarts
  :timestamp - when the error occurred"
  (let ((bt-string (format-backtrace)))
    (list :type (condition-type-name condition)
          :message (condition-message condition)
          :condition-class (class-name (class-of condition))
          :backtrace-string bt-string
          :backtrace (parse-backtrace-string bt-string)
          :restarts (capture-restarts condition)
          :timestamp (get-universal-time))))

(defun format-structured-error (error-info)
  "Format structured error info for human-readable display."
  (with-output-to-string (s)
    (format s "[ERROR] ~A~%" (getf error-info :type))
    (format s "~A~%~%" (getf error-info :message))
    ;; Restarts section
    (let ((restarts (getf error-info :restarts)))
      (when restarts
        (format s "[Restarts]~%")
        (loop for r in restarts
              for i from 0
              do (format s "  ~D: [~A] ~A~%"
                         i
                         (or (getf r :name) "unnamed")
                         (getf r :description)))
        (terpri s)))
    ;; Backtrace section (structured). Honour *print-backtrace-p* so callers
    ;; that suppress backtraces in the immediate response (see
    ;; *include-backtrace-in-evaluate-response*) get that on this path too;
    ;; the frames remain available via describe-last-error and get-backtrace,
    ;; which read the stored structured error directly.
    (let ((bt (and *print-backtrace-p* (getf error-info :backtrace))))
      (when bt
        (format s "[Backtrace]~%")
        (dolist (frame bt)
          (format s "~D: ~A~%"
                  (getf frame :number)
                  (getf frame :function)))))))

(defun format-backtrace-detail (error-info &key (max-frames *max-backtrace-depth*))
  "Format detailed backtrace from stored error info."
  (with-output-to-string (s)
    (let ((bt (getf error-info :backtrace)))
      (if bt
          (progn
            (format s "Backtrace (~D frame~:P):~%~%" (min (length bt) max-frames))
            (loop for frame in bt
                  for count from 0 below max-frames
                  do (format s "Frame ~D:~%  ~A~%~%"
                             (getf frame :number)
                             (getf frame :function))))
          (format s "No backtrace available.~%")))))
