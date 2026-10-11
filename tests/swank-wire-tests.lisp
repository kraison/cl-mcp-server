;;; tests/swank-wire-tests.lisp
;;; ABOUTME: Round trips against a real SWANK server started in this image

(in-package #:cl-mcp-server-tests)

(def-suite swank-wire-tests
  :description "The client against real SWANK, not a model of it"
  :in cl-mcp-server-tests)

(in-suite swank-wire-tests)

;;; A fixture written from our reading of the protocol would share our
;;; misreading of it: GH #11 was exactly that. So the server is SWANK.

(defmacro with-swank-target ((name) &body body)
  "Run BODY with NAME registered, in :read mode, at a fresh SWANK server
on an ephemeral port. The connection and the server go afterwards."
  (let ((port (gensym "PORT")))
    `(let ((,port (swank:create-server :port 0 :dont-close t)))
       (unwind-protect
            (progn
              (cl-mcp-server.remote:register-target ,name "127.0.0.1" ,port
                                                    :mode :read)
              ,@body)
         (cl-mcp-server.remote:close-connection ,name)
         (swank:stop-server ,port)))))

(defun %drop-from-the-far-end (name)
  "Make SWANK close NAME's cached socket, as a restart would: it closes
on a frame it cannot read. Returns the state the socket reached."
  (let ((conn (gethash name cl-mcp-server.remote::*connections*)))
    (cl-mcp-server.swank-protocol::%send conn "(:emacs-rex unreadable")
    (%await-state conn :peer-closed)))

(test a-non-ascii-form-round-trips
  "The form hung for 30s and killed the connection"
  (with-swank-target ("wire-form")
    (let ((r (cl-mcp-server.remote:remote-eval
              "wire-form" (format nil "(length ~S)" (%cyrillic-pri)))))
      (is-true (getf r :ok) "~A" (getf r :error))
      (is (equal "3" (getf r :result))))
    (is (equal "3" (getf (cl-mcp-server.remote:remote-eval
                          "wire-form" "(+ 1 2)")
                         :result))
        "the connection must still work after it")))

(test a-non-ascii-value-round-trips
  "An ASCII form whose value is not ASCII: the reply was read as too few
octets, and the next header was parsed from mid-payload"
  (with-swank-target ("wire-value")
    (let ((r (cl-mcp-server.remote:remote-eval
              "wire-value" "(coerce (list (code-char #x41F)
                                          (code-char #x440) #\\i)
                                    'string)")))
      (is-true (getf r :ok) "~A" (getf r :error))
      (is (search (%cyrillic-pri) (getf r :result))))
    (is (equal "3" (getf (cl-mcp-server.remote:remote-eval
                          "wire-value" "(+ 1 2)")
                         :result)))))

(test a-non-ascii-debugger-reply-leaves-the-connection-usable
  "The debugger's reply carries the condition text; it desynchronised the
stream as a value would"
  (with-swank-target ("wire-debug")
    (let ((r (cl-mcp-server.remote:remote-eval
              "wire-debug" (format nil "(error ~S)" (%cyrillic-pri)))))
      (is-false (getf r :ok))
      (is (search (%cyrillic-pri) (getf r :error))))
    (is (equal "3" (getf (cl-mcp-server.remote:remote-eval
                          "wire-debug" "(+ 1 2)")
                         :result)))))

(test remote-eval-reconnects-when-the-service-dropped-the-socket
  "Nothing was sent on the dead socket, so opening a new one is safe; the
caller is told, since a restart takes the image's state with it"
  (with-swank-target ("wire-drop")
    (is-true (getf (cl-mcp-server.remote:remote-eval "wire-drop" "1") :ok))
    (is (eq :peer-closed (%drop-from-the-far-end "wire-drop")))
    (multiple-value-bind (server session) (make-test-server)
      (declare (ignore session))
      (let ((text (call-test-tool server "remote-eval"
                                  '(("target" . "wire-drop")
                                    ("code" . "(+ 2 3)")))))
        (is (search "=> 5" text) "~A" text)
        (is (search "closed the previous connection" text))))))

(test remote-connect-replaces-a-socket-the-service-dropped
  "Reconnecting a registered name failed on its dead socket until a
remote-disconnect"
  (with-swank-target ("wire-reconnect")
    (multiple-value-bind (server session) (make-test-server)
      (declare (ignore session))
      (flet ((connect-tool ()
               (call-test-tool
                server "remote-connect"
                `(("name" . "wire-reconnect")
                  ("port" . ,(cl-mcp-server.remote:target-port
                              (cl-mcp-server.remote::find-target
                               "wire-reconnect")))))))
        (is (search "Reachable" (connect-tool)))
        (is (eq :peer-closed (%drop-from-the-far-end "wire-reconnect")))
        (let ((text (connect-tool)))
          (is (search "Reachable" text) "~A" text))))))
