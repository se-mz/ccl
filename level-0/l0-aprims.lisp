;;;-*- Mode: Lisp; Package: CCL -*-
;;;
;;; Copyright 1994-2009 Clozure Associates
;;;
;;; Licensed under the Apache License, Version 2.0 (the "License");
;;; you may not use this file except in compliance with the License.
;;; You may obtain a copy of the License at
;;;
;;;     http://www.apache.org/licenses/LICENSE-2.0
;;;
;;; Unless required by applicable law or agreed to in writing, software
;;; distributed under the License is distributed on an "AS IS" BASIS,
;;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;;; See the License for the specific language governing permissions and
;;; limitations under the License.


(in-package "CCL")

; l0-aprims.lisp

;;; This weak list is used to track semaphores as well as locks.
(defvar %system-locks% nil)


(defun record-system-lock (l)
  (atomic-push-uvector-cell %system-locks% population.data l)
  l)

;;; This has to run very early in the initial thread.
(defun %revive-system-locks ()
  (dolist (s (population-data %system-locks%))
    (%revive-macptr s)
    (%setf-macptr s
                  (case (uvref s target::xmacptr.flags-cell)
                    (#.$flags_DisposeRecursiveLock
                     (ff-call
                      (%kernel-import target::kernel-import-new-recursive-lock)
                      :address))
                    (#.$flags_DisposeRwlock
                     (ff-call
                      (%kernel-import target::kernel-import-rwlock-new)
                      :address))
		    (#.$flags_DisposeSemaphore
		     (ff-call
		      (%kernel-import target::kernel-import-new-semaphore)
		      :signed-fullword 0
		      :address))))
    (set-%gcable-macptrs% s)))

(dolist (p %all-packages%)
  (setf (pkg.lock p) (make-read-write-lock)))

(defparameter %all-packages-lock% nil)



(defun %cstr-pointer (string pointer &optional (nul-terminated t))
  (if (typep string 'simple-base-string)
    (locally (declare (simple-base-string string)
                      (optimize (speed 3) (safety 0)))
      (let* ((n (length string)))
        (declare (fixnum n))
        (dotimes (i n)
          (setf (%get-unsigned-byte pointer i)
                (let* ((code (%scharcode string i)))
                  (declare (type (mod #x110000) code))
                  (if (< code 256)
                    code
                    (char-code #\Sub)))))
        (when nul-terminated
          (setf (%get-byte pointer n) 0)))
      nil)
    (%cstr-segment-pointer string pointer 0 (length string) nul-terminated)))

(defun %cstr-segment-pointer (string pointer start end &optional (nul-terminated t))
  (declare (fixnum start end))
  (let* ((n (- end start)))
    (multiple-value-bind (s o) (dereference-base-string string)
      (declare (fixnum o))
      (do* ((i 0 (1+ i))
            (o (the fixnum (+ o start)) (1+ o)))
           ((= i n))
        (declare (fixnum i o))
        (setf (%get-unsigned-byte pointer i)
              (let* ((code (char-code (schar s o))))
                (declare (type (mod #x110000) code))
                (if (< code 256)
                  code
                  (char-code #\Sub))))))
    (when nul-terminated
      (setf (%get-byte pointer n) 0))
    nil))

(defun string (thing)
  "Coerces X into a string. If X is a string, X is returned. If X is a
   symbol, X's pname is returned. If X is a character then a one element
   string containing that character is returned. If X cannot be coerced
   into a string, an error occurs."
  (etypecase thing
    (string thing)
    (symbol (symbol-name thing))
    (character
     (let* ((s (make-string 1)))
       (setf (schar s 0) thing)
       s))))


(defun dereference-base-string (s)
  (multiple-value-bind (vector offset) (array-data-and-offset s)
    (unless (typep vector 'simple-base-string) (report-bad-arg s 'base-string))
    (values vector offset (length s))))

(defun make-gcable-macptr (flags)
  (let ((v (%alloc-misc target::xmacptr.element-count target::subtag-macptr)))
    (setf (uvref v target::xmacptr.address-cell) 0) ; ?? yup.
    (setf (uvref v target::xmacptr.flags-cell) flags)
    (set-%gcable-macptrs% v)
    v))

(defun %make-recursive-lock-ptr ()
  (record-system-lock
   (%setf-macptr
    (make-gcable-macptr $flags_DisposeRecursiveLock)
    (ff-call (%kernel-import target::kernel-import-new-recursive-lock)
             :address))))

(defun %make-rwlock-ptr ()
  (record-system-lock
   (%setf-macptr
    (make-gcable-macptr $flags_DisposeRwLock)
    (ff-call (%kernel-import target::kernel-import-rwlock-new)
             :address))))
  
(defun make-recursive-lock ()
  (make-lock nil))

(defun %make-lock (pointer name)
  (gvector :lock pointer 'recursive-lock 0 name nil nil))

(defun make-lock (&optional name)
  "Create and return a lock object, which can be used for synchronization
between threads."
  (%make-lock (%make-recursive-lock-ptr) name))

(defun lock-name (lock)
  (uvref (require-type lock 'lock) target::lock.name-cell))

(defun recursive-lock-ptr (r)
  (if (and (eq target::subtag-lock (typecode r))
           (eq (%svref r target::lock.kind-cell) 'recursive-lock))
    (%svref r target::lock._value-cell)
    (report-bad-arg r 'recursive-lock)))

(defun recursive-lock-whostate (r)
  (if (and (eq target::subtag-lock (typecode r))
           (eq (%svref r target::lock.kind-cell) 'recursive-lock))
    (or (%svref r target::lock.whostate-cell)
        (setf (%svref r target::lock.whostate-cell)
              (%lock-whostate-string "Lock wait" r)))
    (if (typep r 'string)
      r
      (report-bad-arg r 'recursive-lock))))


(defun read-write-lock-ptr (rw)
  (if (and (eq target::subtag-lock (typecode rw))
           (eq (%svref rw target::lock.kind-cell) 'read-write-lock))
    (%svref rw target::lock._value-cell)
    (report-bad-arg rw 'read-write-lock)))

(defun make-read-write-lock ()
  "Create and return a read-write lock, which can be used for
synchronization between threads."
  (gvector :lock (%make-rwlock-ptr) 'read-write-lock 0 nil nil nil))

(defun rwlock-read-whostate (rw)
  (if (and (eq target::subtag-lock (typecode rw))
           (eq (%svref rw target::lock.kind-cell) 'read-write-lock))
    (or (%svref rw target::lock.whostate-cell)
        (setf (%svref rw target::lock.whostate-cell)
              (%lock-whostate-string "Read lock wait" rw)))
    (report-bad-arg rw 'read-write-lock)))

(defun rwlock-write-whostate (rw)
  (if (and (eq target::subtag-lock (typecode rw))
           (eq (%svref rw target::lock.kind-cell) 'read-write-lock))
    (or (%svref rw target::lock.whostate-2-cell)
        (setf (%svref rw target::lock.whostate-2-cell)
              (%lock-whostate-string "Write lock wait" rw)))
    (report-bad-arg rw 'read-write-lock)))
  

(defun %make-semaphore-ptr (&key (count 0))
  (let* ((p (ff-call (%kernel-import target::kernel-import-new-semaphore)
	     :signed-fullword count
	     :address)))
    (if (%null-ptr-p p)
      (error "Can't create semaphore.")
      (record-system-lock
       (%setf-macptr
	(make-gcable-macptr $flags_DisposeSemaphore)
	p)))))

(defun make-semaphore (&key (count 0))
  "Create and return a semaphore, which can be used for synchronization
between threads."
  (%istruct 'semaphore (%make-semaphore-ptr :count count)))

(defun semaphorep (x)
  (istruct-typep x 'semaphore))

(setf (type-predicate 'semaphore) 'semaphorep)

(defun make-list (size &key initial-element)
  "Constructs a list with size elements each set to value"
  (unless (and (typep size 'fixnum)
               (>= (the fixnum size) 0))
    (report-bad-arg size '(and fixnum unsigned-byte)))
  (locally (declare (fixnum size))
    (if (>= size (ash 1 16))
      (values (%allocate-list initial-element size))
      (do* ((result '() (cons initial-element result)))
           ((zerop size) result)
        (decf size)))))

; end
