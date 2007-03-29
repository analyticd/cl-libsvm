(in-package :cl-libsvm)

(defparameter *libsvm-dir*
  (make-pathname :name nil :type nil
                 :defaults (asdf:component-pathname
                            (asdf:find-system :cl-libsvm))))

(defparameter *libsvm-lib-dir*
  (merge-pathnames (make-pathname :directory '(:relative "lib")
                                  :name "libsvm" :type "so")
                   *libsvm-dir*))

#+(and :linux :x86)
(load-foreign-library
 (merge-pathnames (make-pathname :directory '(:relative "linux-x86"))
                  *libsvm-lib-dir*))

#-(and :linux :x86)
(progn

  (define-foreign-library libsvm
    (:unix (:or "libsvm.so.2" "libsvm.so"))
    (:windows (:or "libsvm.dll" "svmc.dll"))
    (t (:default "libsvm")))

  (use-foreign-library libsvm))

(define-condition libsvm-error () ())

;;; Wrapped pointers

(defvar *wrappers*
  #+sbcl
  (make-hash-table :weakness :value)
  #+allegro
  (make-hash-table :values :weak)
  #+clisp
  (make-hash-table :weak :value)
  "An address to wrapper map.")

(defclass wrapper ()
  ((pointer :initarg :pointer :reader pointer
            :documentation "A foreign pointer that is destroyed when
its wrapper is garbage collected.")
   (ctype :initarg :ctype :reader ctype
          :documentation "The foreign type of POINTER.")
   (references :initarg :references :reader references
               :documentation "A list of pointer/ctype conses of
foreign objects reachable from POINTER.")
   (extra-references :initform '() :accessor extra-references
                     :documentation "A list of pointer/ctype conses
reachable from POINTER. As opposed to REFERENCES this may be set. Use
this to to store references to foreign objects whose parts are
used reachable from this pointer.")))

(defgeneric reachable-pointers (pointer ctype)
  (:method (pointer ctype)
    (declare (ignore pointer ctype))
    '())
  (:documentation "Return a list of conses of pointer and ctype
representing the pointers reachable from POINTER of CTYPE."))

(defgeneric ctype->wrapper-class (ctype)
  (:method (ctype)
    (declare (ignore ctype))
    'wrapper)
  (:documentation "Return the designator of the class that is to be
instantiated when a pointer of CTYPE is being wrapped."))

(defgeneric wrap (pointer ctype)
  (:method (pointer ctype)
    ;; FIXME: lock
    (or (gethash (pointer-address pointer) *wrappers*)
        (setf (gethash (pointer-address pointer) *wrappers*)
              (make-instance (ctype->wrapper-class ctype)
                             :pointer pointer :ctype ctype
                             :references
                             (mapcar (lambda (pointer ctype)
                                       (wrap pointer ctype))
                                     (reachable-pointers pointer ctype)))))))

(defgeneric destroy-wrapped-pointer (pointer ctype)
  (:method (pointer ctype)
    (declare (ignore ctype))
    (foreign-free pointer))
  (:documentation "Free foreign resources associated with POINTER of CTYPE."))

(defmethod initialize-instance :after ((wrapper wrapper) &key &allow-other-keys)
  (let ((pointer (pointer wrapper))
        (ctype (ctype wrapper)))
    (finalize wrapper
              (lambda ()
                (remhash (pointer-address pointer) *wrappers*)
                (destroy-wrapped-pointer pointer ctype)))))

(defmacro define-wrapped-pointer (ctype &key (class ctype))
  `(progn
     (defmethod ctype->wrapper-class ((ctype (eql ',ctype)))
       ',class)
     (defmethod translate-from-foreign (pointer (name (eql ',ctype)))
       (wrap pointer ',ctype))
     (defmethod translate-to-foreign ((wrapper ,class) (name (eql ',ctype)))
       (pointer wrapper))))

;;; Utilities

(defun foreign-slot-value* (object pointer-ctype ctype slot-name)
  "A type safe variant of FOREIGN-SLOT-VALUE that first convert the
lisp OBJECT to POINTER-CTYPE and than returns the value of its slot."
  (foreign-slot-value (convert-to-foreign object pointer-ctype)
                      ctype slot-name))

(defctype boolean :int
  :documentation "Convert between lisp generalized booleans and zero
non-zero of C.")

(defmethod translate-from-foreign (value (name (eql 'boolean)))
  (not (zerop value)))

(defmethod translate-to-foreign (value (name (eql 'boolean)))
  (if value 1 0))

(defctype auto-double :double)

(defmethod translate-to-foreign (value (name (eql 'auto-double)))
  (coerce value 'double-float))

(defcstruct node
  (index :int)
  (value auto-double))

(defctype double-vector :pointer)

(defctype sparse-vector :pointer)

(defctype temporary-sparse-vector sparse-vector)

(defctype sparse-vector-vector :pointer)

(defun mapper-length (mapper)
  (let ((n 0))
    (funcall mapper (lambda (&rest args)
                      (declare (ignore args))
                      (incf n)))
    n))

(defgeneric convert-vector (object ctype)
  (:method ((vector vector) ctype)
    (let* ((n (length vector))
           (v (foreign-alloc ctype :count n)))
      (dotimes (i n)
        (setf (mem-aref v ctype i) (aref vector i)))
      (values v n)))
  (:method ((mapper function) ctype)
    (let* ((n (mapper-length mapper))
           (v (foreign-alloc ctype :count n))
           (i 0))
      (funcall mapper
               (lambda (value)
                 (setf (mem-aref v ctype i) value)
                 (incf i)))
      (values v n)))
  (:method ((symbol symbol) ctype)
    (convert-vector (symbol-function symbol) ctype)))

(defmethod translate-to-foreign ((v vector) (name (eql 'double-vector)))
  (convert-vector v 'auto-double))

(defmethod translate-to-foreign ((v function) (name (eql 'double-vector)))
  (convert-vector v 'auto-double))

(defmethod translate-to-foreign ((v symbol) (name (eql 'double-vector)))
  (convert-vector v 'auto-double))

(define-condition sparse-index-error (libsvm-error)
  ((index :initarg :index :reader index)
   (max-index :initarg :max-index :reader max-index))
  (:report (lambda (condition stream)
             (format stream "Invalid sparse index ~S is less than ~S"
                     (index condition) (max-index condition)))))

(defmethod translate-to-foreign ((vector vector) (name (eql 'sparse-vector)))
  (let* ((n (length vector))
         (v (foreign-alloc 'node :count (1+ n)))
         (max-index 0))
    (dotimes (i n)
      (destructuring-bind (index . value) (aref vector i)
        (when (<= index max-index)
          (error 'sparse-index-error :index index :max-index max-index))
        (setf max-index index)
        (setf (foreign-slot-value (mem-aref v 'node i) 'node 'index) index)
        (setf (foreign-slot-value (mem-aref v 'node i) 'node 'value) value)))
    (setf (foreign-slot-value (mem-aref v 'node n) 'node 'index) -1)
    (setf (foreign-slot-value (mem-aref v 'node n) 'node 'value) 0.0d0)
    v))

(defmethod translate-to-foreign ((mapper function) (name (eql 'sparse-vector)))
  (let* ((n (mapper-length mapper))
         (v (foreign-alloc 'node :count (1+ n)))
         (i 0)
         (max-index 0))
    (funcall mapper
             (lambda (index value)
               (when (<= index max-index)
                 (error 'sparse-index-error :index index :max-index max-index))
               (setf max-index index)
               (setf (foreign-slot-value (mem-aref v 'node i) 'node 'index)
                     index)
               (setf (foreign-slot-value (mem-aref v 'node i) 'node 'value)
                     value)
               (incf i)))
    (setf (foreign-slot-value (mem-aref v 'node n) 'node 'index) -1)
    (setf (foreign-slot-value (mem-aref v 'node n) 'node 'value) 0.0d0)
    v))

(defmethod translate-to-foreign ((symbol symbol) (name (eql 'sparse-vector)))
  (translate-to-foreign symbol name))

(defmethod translate-to-foreign ((v vector) (name (eql 'sparse-vector-vector)))
  (convert-vector v 'sparse-vector))

(defmethod translate-to-foreign ((v function)
                                 (name (eql 'sparse-vector-vector)))
  (convert-vector v 'sparse-vector))

(defmethod translate-to-foreign ((v symbol) (name (eql 'sparse-vector-vector)))
  (convert-vector v 'sparse-vector))

(defmethod free-translated-object (value (name (eql 'temporary-sparse-vector))
                                   param)
  (declare (ignore param))
  (foreign-free value))

;;; Problem

(defcstruct problem-struct
  (l :int)
  (y double-vector)
  (x sparse-vector-vector))

(defctype problem :pointer)

(defclass problem (wrapper) ()
  (:documentation "A problem consists of a number of sparse input
vectors and their respective targets. The target is the label of the
class for classification or value for regression."))

(defmethod print-object ((problem problem) stream)
  (print-unreadable-object (problem stream :type t :identity t)
    (format stream ":SIZE ~A" (problem-size problem)))
  problem)

(define-wrapped-pointer problem)

(defmethod destroy-wrapped-pointer (problem (ctype (eql 'problem)))
  (foreign-free (foreign-slot-value problem 'problem-struct 'y))
  (let ((x (foreign-slot-value problem 'problem-struct 'x)))
    (dotimes (i (foreign-slot-value problem 'problem-struct 'l))
      (foreign-free (mem-aref x :pointer i))))
  (foreign-free (foreign-slot-value problem 'problem-struct 'x)))

(defun make-problem (targets inputs)
  "Create a problem from TARGET that is a vector of real numbers and
INPUT that is a vector of sparse vectors. A sparse vector has
index/value conses as elements, alternatively it may be given as a
mapper function that maps to index and value."
  (multiple-value-bind (targets n-targets)
      (convert-vector targets 'auto-double)
    (multiple-value-bind (inputs n-inputs)
        (convert-vector inputs 'sparse-vector)
      (assert (= n-targets n-inputs))
      (let ((p (foreign-alloc 'problem)))
        (setf (foreign-slot-value p 'problem-struct 'l) n-targets
              (foreign-slot-value p 'problem-struct 'y) targets
              (foreign-slot-value p 'problem-struct 'x) inputs)
        (wrap p 'problem)))))

(defun problem-size (problem)
  "Return the number of targets in PROBLEM."
  (foreign-slot-value* problem 'problem 'problem-struct 'l))

(defun problem-target (problem i)
  "Return the Ith target."
  (assert (and (<= 0 i) (< i (problem-size problem))))
  (mem-aref (foreign-slot-value* problem 'problem 'problem-struct 'y)
            'auto-double i))

(defun map-sparse-vector (function vector)
  (loop for i upfrom 0
        for element = (mem-aref vector 'node i)
        for index = (foreign-slot-value element 'node 'index)
        for value = (foreign-slot-value element 'node 'value)
        while (<= 0 index) do
        (funcall function index value)))

(defun map-problem-input (function problem i)
  "Map FUNCTION over the indices and values of the Ith input vector of
PROBLEM."
  (assert (and (<= 0 i) (< i (problem-size problem))))
  (map-sparse-vector function
                     (mem-aref
                      (foreign-slot-value* problem 'problem 'problem-struct 'x)
                      'sparse-vector i)))

(defun save-problem (problem filename)
  "Save PROBLEM to FILENAME in the LIBSVM/SVMLight format."
  (with-open-file (s filename :direction :output :if-does-not-exist :create
                   :if-exists :supersede :element-type 'base-char
                   :external-format :ascii)
    (let ((*print-pretty* nil))
      (dotimes (i (problem-size problem))
        (let ((target (problem-target problem i)))
          (prin1 (if (= target (round target))
                     (round target)
                     (float target 0.0))
                 s)
          (map-problem-input (lambda (index value)
                               (princ #\Space s)
                               (prin1 index s)
                               (princ #\: s)
                               (prin1 (float value 0.0) s))
                             problem i)
          (terpri s))))))

(defun load-problem (filename)
  "Read a problem from FILENAME in the LIBSVM/SVMLight format."
  (with-standard-io-syntax
    (let ((*read-eval* nil))
      (labels
          ((map-file (fn)
             (with-open-file (s filename :element-type 'base-char
                              :external-format :ascii)
               (loop for line = (read-line s nil nil)
                     while line
                     do (funcall fn line))))
           (map-targets (fn)
             (map-file (lambda (line)
                         (funcall fn (read-from-string line)))))
           (map-input (fn line)
             (loop with p = (nth-value 1 (read-from-string line))
                   do
                   (multiple-value-bind (index position)
                       (parse-integer line :start p :junk-allowed t)
                     (setf p position)
                     (unless index
                       (return))
                     (multiple-value-bind (value position)
                         (read-from-string line t nil :start (1+ position))
                       (funcall fn index value)
                       (setf p position)))))
           (map-inputs (fn)
             (map-file (lambda (line)
                         (funcall fn (lambda (fn)
                                       (map-input fn line)))))))
        (make-problem #'map-targets #'map-inputs)))))

;;; Parameter

(defcenum svm-type :c-svc :nu-svc :one-class :epsilon-svr :nu-svr)

(defcenum kernel-type :linear :poly :rbf :sigmoid :precomputed)

(defcstruct parameter-struct
  (svm-type svm-type)
  (kernel-type kernel-type)
  ;; for poly
  (degree :int)
  ;; for poly/rbf/sigmoid
  (gamma auto-double)
  ;; for poly/sigmoid
  (coef0 auto-double)
  ;; these are for training only
  (cache-size-MiB auto-double)
  ;; stopping criteria
  (eps auto-double)
  ;; for C-SVC, EPSILON-SVR and NU-SVR
  (c auto-double)
  ;; for C-SVC, unsupported by this wrapper
  (nr-weight :int)
  ;; for C-SVC
  (weight-label :pointer)
  ;; for C-SVC
  (weight :pointer)
  ;; for NU-SVC, ONE-CLASS, and NU-SVR
  (nu auto-double)
  ;; for EPSILON-SVR
  (p auto-double)
  ;; use the shrinking heuristics
  (shrinking boolean)
  ;; do probability estimates
  (probability boolean))

(defctype parameter :pointer)

(defclass parameter (wrapper) ()
  (:documentation "A parameter object encapsulates the different kinds
of parameters of SVM. Some of the parameters are specific to a
particular kernel."))

(defmacro define-slot-reader (name (&key pointer-ctype
                                         (class-name pointer-ctype)
                                         ctype
                                         (slot-name name))
                              &optional documentation)
  `(defun ,name (,class-name)
     ,@(when documentation (list documentation))
     (foreign-slot-value* ,class-name ',pointer-ctype ',ctype ',slot-name)))

(define-slot-reader svm-type
    (:pointer-ctype parameter :ctype parameter-struct)
  "Return the value of the SVM-TYPE slot of PARAMETER.")

(define-slot-reader kernel-type
    (:pointer-ctype parameter :ctype parameter-struct)
  "Return the value of the KERNEL-TYPE slot of PARAMETER.")

;;; FIXME: missing readers for parameters

(defmethod print-object ((parameter parameter) stream)
  (print-unreadable-object (parameter stream :type t :identity t)
    (format stream "~A/~A" (svm-type parameter) (kernel-type parameter)))
  parameter)

(define-wrapped-pointer parameter)

(defun make-parameter (&key (svm-type :c-svc) (kernel-type :rbf)
                       (degree 3) (gamma 0) (coef0 0) (nu 0.5)
                       (cache-size-MiB 100) (c 1) (eps 0.001) (p 0.1)
                       (shrinking t) probability)
  (let* ((parameter (foreign-alloc 'parameter-struct)))
    (macrolet ((set-slots (&rest names)
                 (list* 'progn
                        (loop for name in names collect
                              `(setf (foreign-slot-value parameter
                                      'parameter-struct
                                      ',name)
                                ,name)))))
      ;; These three parameters are unsupported by this wrapper for
      ;; the time being.
      (let ((nr-weight 0)
            (weight-label (null-pointer))
            (weight (null-pointer)))
        (set-slots svm-type kernel-type degree gamma coef0 nu
                   cache-size-MiB c eps p shrinking probability
                   nr-weight weight-label weight))
      (wrap parameter 'parameter))))

(defcfun ("svm_check_parameter" %check-parameter) :string
  (problem problem)
  (parameter parameter))

(define-condition parameter-error (libsvm-error)
  ((parameter :initarg :parameter :reader parameter)
   (problem :initarg :problem :reader problem)
   (explanation :initarg :explanation :reader explanation))
  (:report (lambda (condition stream)
             (format stream "Bad parameter ~S for ~S: ~S"
                     (parameter condition) (problem condition)
                     (explanation condition)))))

(defun parameter-error (problem parameter explanation)
  (error 'parameter-error :problem problem :parameter parameter
         :explanation explanation))

(defun check-parameter (problem parameter &key errorp)
  "See if PARAMETER is suitable for PROBLEM. Return T if it is, and
NIL and a string explaining why if it is not. If ERRORP and the check
fails signal BAD-PARAMETER condition."
  (let ((r (%check-parameter problem parameter)))
    (if r
        (if errorp
            (parameter-error problem parameter r)
            (values nil r))
        t)))


;;; Model

(defctype model :pointer)

(defclass model (wrapper) ()
  (:documentation "A model is what falls out of training and can be
used later to make predictions."))

(define-wrapped-pointer model)

(defcfun ("svm_destroy_model" %destroy-model) :void
  (model model))

(defmethod destroy-wrapped-pointer (model (ctype (eql 'model)))
  (%destroy-model model))

(defctype error-code :int)

(defmethod translate-from-foreign (error-code (name (eql 'error-code)))
  (unless (zerop error-code)
    (error "Error code: ~S" error-code))
  (values))

(defcfun ("svm_save_model" %save-model) error-code
  (filename :string)
  (model model))

(defun save-model (model filename)
  "Save MODEL to FILENAME."
  (%save-model filename model))

(defcfun ("svm_load_model" load-model) model
  (filename :string))

(setf (documentation #'load-model 'function)
      "Load a model from a file.")

(defcfun ("svm_train" %train) model
  (problem problem)
  (parameter parameter))

(defun model-parameter (model)
  (assert (typep model 'model))
  ;; The model struct starts with the parameter struct
  ;; FIXME: wrapping doesn't work right here
  (convert-from-foreign (pointer model) 'parameter))

(defun train (problem parameter)
  "Train and return a model object on PROBLEM according PARAMETER.
Signal a PARAMETER-ERROR if PARAMETER is incorrect."
  (check-parameter problem parameter :errorp t)
  (let ((model (%train problem parameter)))
    ;; The models created by svm_train keep references into the
    ;; problem so it must be kept around.
    (setf (extra-references model)
          (list (cons (pointer problem) 'problem)))
    model))

(defcfun ("svm_predict" predict) :double
  (model model)
  (input temporary-sparse-vector))

(setf (documentation #'predict 'function)
      "Return the prediction (a double float) for the sparse vector
INPUT according to MODEL.")

;;; FIXME: cross validation, predict-values, probability stuff is missing

(defun map-it (function sequence-or-mapper)
  (if (typep sequence-or-mapper 'sequence)
      (map nil function sequence-or-mapper)
      (funcall sequence-or-mapper function)))

(defclass normalizer ()
  ((lower :initarg :lower :reader lower)
   (upper :initarg :upper :reader upper)
   (min-maxes :initarg :min-maxes :reader min-maxes))
  (:documentation "Normalizers offer basically the same functionality
as svm-scale."))

(defun make-normalizer (inputs &key (lower -1) (upper 1))
  "Create a normalizer that will translate inputs to the [LOWER,UPPER]
range."
  (let ((min-maxes (make-array 0 :adjustable t)))
    (labels ((one-feature (feature)
               (destructuring-bind (index . value) feature
                 (unless (< index (length min-maxes))
                   (adjust-array min-maxes (1+ index) :initial-element nil))
                 (if (null (aref min-maxes index))
                     (setf (aref min-maxes index) (cons value value))
                     (destructuring-bind (min . max) (aref min-maxes index)
                       (when (or (null min) (< value min))
                         (setf (car (aref min-maxes index)) value))
                       (when (or (null max) (< max value))
                         (setf (cdr (aref min-maxes index)) value))))))
             (one-input (input)
               (map-it #'one-feature input)))
      (map-it #'one-input inputs))
    (make-instance 'normalizer :lower lower :upper upper
                   :min-maxes min-maxes)))

(defun map-normalized-input (normalizer input function)
  "Map function over the features in INPUT normalized by NORMALIZER."
  (let ((lower (lower normalizer))
        (upper (upper normalizer))
        (min-maxes (min-maxes normalizer)))
    (flet ((norm (value min max)
             (if (eql min max)
                 ;; either not encountered or singular
                 value
                 (+ lower
                    (* (/ (- upper lower)
                          (- max min))
                       (- value min))))))
      (map-it (lambda (feature)
                (destructuring-bind (index . value) feature
                  (destructuring-bind (min . max)
                      (if (< 0 index (length min-maxes))
                          (aref min-maxes index)
                          (cons nil nil))
                    (funcall function
                             (cons index (norm value min max))))))
              input))))

(defun save-normalizer (normalizer filename)
  "Save NORMALIZER to FILENAME in the format used by svm-scale."
  (with-open-file (s filename :direction :output :if-does-not-exist :create
                   :if-exists :supersede :element-type 'base-char
                   :external-format :ascii)
    (let ((*print-pretty* nil)
          (min-maxes (min-maxes normalizer)))
      (format s "x~%~S ~S~%" (lower normalizer) (upper normalizer))
      (loop for i below (length min-maxes) do
            (when (aref min-maxes i)
              (destructuring-bind (min . max) (aref min-maxes i)
                (format s "~D ~S ~S~%" i (float min 0.0) (float max 0.0))))))))

(defun load-normalizer (filename)
  "Load normalizer from FILENAME that is in the format used by svm-scale."
  (with-open-file (s filename :element-type 'base-char :external-format :ascii)
    (unless (string= "x" (read-line s))
      (error "File format not supported."))
    (let ((lower (read s))
          (upper (read s))
          (min-maxes (make-array 0 :adjustable t)))
      (loop for line = (read-line s nil nil)
            while line
            do
            (with-input-from-string (s line)
              (let ((index (read s))
                    (min (read s))
                    (max (read s)))
                (unless (< index (length min-maxes))
                  (adjust-array min-maxes (1+ index) :initial-element nil))
                (setf (aref min-maxes index) (cons min max)))))
      (make-instance 'normalizer :lower lower :upper upper
                     :min-maxes min-maxes))))

(defun test-problem ()
  (let* ((targets (vector 0 1 1 0))
         (inputs (vector (vector (cons 1 0) (cons 2 0))
                         ;; Pass a mapper function
                         (lambda (fn)
                           (map nil (lambda (c)
                                      (funcall fn (car c) (cdr c)))
                                (vector (cons 1 0) (cons 2 1))))
                         (vector (cons 1 1) (cons 2 0))
                         (vector (cons 1 1) (cons 2 1))))
         (problem (make-problem targets inputs)))
    (assert (= (length targets) (problem-size problem)))
    (loop for i below (length targets) do
          (assert (= (aref targets i) (problem-target problem i))))
    (flet ((input->vector (problem i)
             (let ((v (make-array 0 :adjustable t :fill-pointer 0)))
               (map-problem-input (lambda (index value)
                                    (vector-push-extend (cons index value) v))
                                  problem i)
               v)))
      (loop for i below (length inputs) do
            (unless (= i 1)
              (assert (every (lambda (x y)
                               (and (= (car x) (car y))
                                    (= (cdr x) (cdr y))))
                             (coerce (aref inputs i) 'list)
                             (coerce (input->vector problem i) 'list))))))
    (assert (not (check-parameter problem (make-parameter :degree -1))))
    (let ((parameter (make-parameter :gamma 8 )))
      (assert (check-parameter problem parameter))
      (flet ((test-model (model)
               (loop for i below (length inputs) do
                     (assert (= (aref targets i)
                                (predict model (aref inputs i)))))))
        (let ((model (train problem parameter)))
          (test-model model)
          (save-model model "/tmp/cl-libsvm-test-model"))
        (test-model (load-model "/tmp/cl-libsvm-test-model"))))))

(defun test-normalizer ()
  (let* ((data (vector (vector (cons 1 4.0) (cons 3 -5.0))
                       (vector (cons 1 -2.0) (cons 3 3.0))
                       (vector (cons 1 1.0) (cons 4 6.0))))
         (normalizer (make-normalizer data)))
    (map-normalized-input normalizer (aref data 0)
                          (lambda (feature)
                            (destructuring-bind (index . value) feature
                              (assert (= value (ecase index
                                                 ((1) 1)
                                                 ((3) -1)))))))
    (save-normalizer normalizer "/tmp/nnn")
    (let ((normalizer2 (load-normalizer "/tmp/nnn")))
      (assert (= (lower normalizer) (lower normalizer2)))
      (assert (= (upper normalizer) (upper normalizer2)))
      (assert (string= (prin1-to-string (min-maxes normalizer))
                       (prin1-to-string (min-maxes normalizer2)))))))


(defun test ()
  (test-problem)
  (test-normalizer))

#|

(test)

|#
