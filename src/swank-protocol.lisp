;;; src/swank-protocol.lisp
;;; ABOUTME: SWANK wire protocol client -- framing, event loop, debugger

(in-package #:cl-mcp-server.swank-protocol)

;;; Wire format: 6 hex digits of payload length, then an S-expression.
;;; Request:  (:emacs-rex FORM "PACKAGE" THREAD ID)
;;; Reply:    (:return (:ok VALUE) ID) | (:return (:abort REASON) ID)
;;; Async:    (:write-string ...) (:debug ...) (:ping THREAD TAG) ...
;;;
;;; The debugger is the trap: a form that signals does not return. SWANK
;;; pushes the thread into the debugger and waits. A client that reads one
;;; reply and stops will hang, and the remote thread stays wedged. See
;;; docs/reference/remote-swank.md.

(defparameter *connect-timeout* 10)
(defparameter *call-timeout* 30
  "Seconds to wait for a reply. A remote thread we cannot reach is worse
than a slow one, so this is deliberately short.")

(define-condition swank-error (error)
  ((detail :initarg :detail :reader swank-error-detail))
  (:report (lambda (c s) (format s "SWANK: ~A" (swank-error-detail c)))))

(define-condition swank-aborted (swank-error)
  ((condition-text :initarg :condition-text :initform nil
                   :reader swank-aborted-condition)
   (restarts :initarg :restarts :initform nil :reader swank-aborted-restarts))
  (:report (lambda (c s)
             (format s "remote error: ~A"
                     (or (swank-aborted-condition c)
                         (swank-error-detail c))))))

;;; ==========================================================================
;;; Connection
;;; ==========================================================================

(defstruct (swank-connection (:conc-name conn-))
  target-name host port socket stream
  (id-counter 0)
  (lock (bt:make-lock "swank-conn"))
  (output (make-string-output-stream)))

(defun connect (host port &key target-name)
  "Open a SWANK connection. Signals SWANK-ERROR when unreachable."
  (handler-case
      (let* ((socket (usocket:socket-connect
                      host port
                      :element-type 'character
                      :timeout *connect-timeout*))
             (stream (usocket:socket-stream socket)))
        (make-swank-connection :target-name target-name :host host :port port
                               :socket socket :stream stream))
    (error (e)
      (error 'swank-error
             :detail (format nil "cannot reach ~A:~D (~A)" host port
                             (type-of e))))))

(defun disconnect (conn)
  (ignore-errors (usocket:socket-close (conn-socket conn)))
  (setf (conn-socket conn) nil (conn-stream conn) nil)
  :disconnected)

(defun connected-p (conn)
  (and conn (conn-socket conn) (open-stream-p (conn-stream conn))))

;;; ==========================================================================
;;; Framing
;;; ==========================================================================

(defun %send (conn payload)
  (let ((stream (conn-stream conn)))
    (format stream "~6,'0X" (length payload))
    (write-string payload stream)
    (finish-output stream)))

(defun %read-message (conn &key (timeout *call-timeout*))
  "Read one framed message, or NIL on timeout."
  (let ((stream (conn-stream conn)))
    (unless (%wait-readable stream timeout)
      (return-from %read-message nil))
    (let ((header (make-string 6)))
      (unless (= 6 (read-sequence header stream))
        (error 'swank-error :detail "connection closed mid-header"))
      (let* ((len (parse-integer header :radix 16))
             (body (make-string len)))
        (unless (= len (read-sequence body stream))
          (error 'swank-error :detail "connection closed mid-body"))
        body))))

(defun %wait-readable (stream seconds)
  "Poll for input. LISTEN alone would spin; this sleeps between checks."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second))))
    (loop
      (when (listen stream) (return t))
      (when (> (get-internal-real-time) deadline) (return nil))
      (sleep 0.01))))

;;; ==========================================================================
;;; RPC
;;; ==========================================================================

(defun %next-id (conn)
  (bt:with-lock-held ((conn-lock conn)) (incf (conn-id-counter conn))))

(defun %lisp-string (text)
  "Render TEXT as a Lisp string literal for the wire."
  (with-output-to-string (s)
    (write-char #\" s)
    (loop for ch across text
          do (case ch
               (#\\ (write-string "\\\\" s))
               (#\" (write-string "\\\"" s))
               (t (write-char ch s))))
    (write-char #\" s)))

(defun rex (conn form-string &key (package "COMMON-LISP-USER")
                                  (timeout *call-timeout*))
  "Evaluate FORM-STRING on the remote image and pump until its reply arrives.

Returns (values result-string output-string). Signals SWANK-ABORTED when the
remote form signalled -- with the restarts it offered, which is the useful
part of the failure.

NB: the :emacs-rex slot holds a SWANK *RPC call*, not the user's form. The
form is passed as a string argument to swank:eval-and-grab-output, which
also hands back anything the form printed. Splicing the bare form in yields
\"illegal function call\"."
  (unless (connected-p conn)
    (error 'swank-error :detail "not connected"))
  (let ((id (%next-id conn))
        (pending-debug nil))
    (%send conn (format nil "(:emacs-rex (swank:eval-and-grab-output ~A) ~
~S t ~D)"
                        (%lisp-string form-string) package id))
    (loop
      (let ((raw (%read-message conn :timeout timeout)))
        (unless raw
          (error 'swank-error
                 :detail (format nil "no reply within ~Ds; the remote thread ~
may still be running the form" timeout)))
        (multiple-value-bind (kind payload reply-id)
            (%classify raw)
          (case kind
            (:return
             (when (eql reply-id id)
               (return (%finish payload pending-debug conn))))
            (:debug
             ;; Record the menu, then unwind. We never leave a remote thread
             ;; sitting in the debugger.
             (setf pending-debug payload))
            (:debug-activate
             (%send conn (format nil "(:emacs-rex (swank:throw-to-toplevel) ~
~S ~A ~D)" package (or (car payload) "t") (%next-id conn))))
            (:ping
             (%send conn (format nil "(:emacs-pong ~A ~A)"
                                 (first payload) (second payload))))
            (:write-string
             (write-string (or (first payload) "") (conn-output conn)))
            (t nil)))))))

(defun %finish (payload pending-debug conn)
  "Turn a (:return ...) payload into (values result output).

swank:eval-and-grab-output answers (\"printed output\" \"value\"), so the
result carries both halves and the :write-string channel is usually empty."
  (let ((async-output (get-output-stream-string (conn-output conn))))
    (if (eq (car payload) :ok)
        (multiple-value-bind (value printed) (%split-eval-result (cdr payload))
          (values value (concatenate 'string async-output (or printed ""))))
        (error 'swank-aborted
               :detail (or (cdr payload) "aborted")
               :condition-text (getf pending-debug :condition)
               :restarts (getf pending-debug :restarts)))))

(defun %split-eval-result (text)
  "Return (values value-string output-string) from ((\"out\" \"value\"))."
  (let ((first-start (position #\" text)))
    (if (null first-start)
        (values (string-trim "() " text) nil)
        (let* ((out (%first-string text))
               (after (position #\" text :start (1+ first-start)))
               (rest (if after (subseq text (1+ after)) ""))
               (value (%first-string rest)))
          (values (or value (string-trim "() " text)) out)))))

;;; ==========================================================================
;;; Message classification
;;;
;;; We deliberately do NOT build a general S-expression reader here. Remote
;;; payloads are untrusted input; READ on them would intern symbols and honour
;;; #. in this image. Everything is handled as text, and only the small number
;;; of shapes we act on are picked apart.
;;; ==========================================================================

(defun %classify (raw)
  "Return (values kind payload id) for a SWANK message."
  (cond
    ((%prefixp "(:return " raw) (%parse-return raw))
    ((%prefixp "(:debug-activate" raw)
     (values :debug-activate (list (%nth-token raw 1)) nil))
    ((%prefixp "(:debug " raw) (values :debug (%parse-debug raw) nil))
    ((%prefixp "(:ping " raw)
     (values :ping (list (%nth-token raw 1) (%nth-token raw 2)) nil))
    ((%prefixp "(:write-string " raw)
     (values :write-string (list (%first-string raw)) nil))
    (t (values :other nil nil))))

(defun %prefixp (prefix string)
  (and (>= (length string) (length prefix))
       (string= prefix string :end2 (length prefix))))

(defun %parse-return (raw)
  "(:return (:ok VALUE) ID) or (:return (:abort REASON) ID)."
  (let* ((id (%trailing-integer raw))
         (ok (search "(:ok " raw)))
    (if ok
        (values :return (cons :ok (%balanced-substring raw (+ ok 5))) id)
        (values :return (cons :abort (%first-string raw)) id))))

(defun %parse-debug (raw)
  "Pull the condition text and restart names out of a (:debug ...) message."
  (list :condition (%first-string raw)
        :restarts (%collect-restart-names raw)))

;;; -- small textual helpers ------------------------------------------------

(defun %trailing-integer (raw)
  (let ((end (position-if #'digit-char-p raw :from-end t)))
    (when end
      (let ((start end))
        (loop while (and (plusp start) (digit-char-p (char raw (1- start))))
              do (decf start))
        (parse-integer raw :start start :end (1+ end) :junk-allowed t)))))

(defun %first-string (raw)
  "Contents of the first double-quoted run, with escapes resolved."
  (let ((start (position #\" raw)))
    (when start
      (with-output-to-string (s)
        (loop with i = (1+ start)
              while (< i (length raw))
              for ch = (char raw i)
              do (cond ((char= ch #\\)
                        (when (< (1+ i) (length raw))
                          (write-char (char raw (1+ i)) s))
                        (incf i 2))
                       ((char= ch #\") (return))
                       (t (write-char ch s) (incf i))))))))

(defun %balanced-substring (raw start)
  "Text from START to the matching close paren, or to end of string."
  (let ((depth 0) (in-string nil))
    (loop for i from start below (length raw)
          for ch = (char raw i)
          do (cond (in-string
                    (cond ((char= ch #\\) (incf i))
                          ((char= ch #\") (setf in-string nil))))
                   ((char= ch #\") (setf in-string t))
                   ((char= ch #\() (incf depth))
                   ((char= ch #\))
                    (when (zerop depth)
                      (return-from %balanced-substring
                        (string-trim " " (subseq raw start i))))
                    (decf depth))))
    (string-trim " " (subseq raw start))))

(defun %nth-token (raw n)
  "Nth whitespace-delimited token, ignoring the leading paren."
  (let ((tokens (%tokenize raw)))
    (nth n tokens)))

(defun %tokenize (raw)
  (let ((clean (substitute #\Space #\( (substitute #\Space #\) raw))))
    (remove "" (%split clean #\Space) :test #'string=)))

(defun %split (string char)
  (loop with start = 0
        for pos = (position char string :start start)
        collect (subseq string start pos)
        while pos do (setf start (1+ pos))))

(defun %collect-restart-names (raw)
  "Restart names from a (:debug ...) message, in offer order."
  (let ((names nil) (start 0))
    (loop
      (let ((open (search "(\"" raw :start2 start)))
        (unless open (return))
        (let* ((name-start (+ open 2))
               (name-end (position #\" raw :start name-start)))
          (unless name-end (return))
          (push (subseq raw name-start name-end) names)
          (setf start (or name-end (1+ open))))))
    (nreverse names)))
