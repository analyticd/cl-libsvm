;;;; -*- mode: Lisp -*-

(cl:defpackage #:cl-libsvm.system
  (:use #:cl #:asdf))

(in-package #:cl-libsvm.system)

(defsystem #:cl-libsvm
  :name "CL-LIBSVM"
  :description "CFFI wrapper for LIBSVM"
  :long-description "CFFI wrapper for LIBSVM, the machine learning library"
  :author "Gabor Melis"
  :version "0.0.1"
  :licence "MIT"
  :components ((:file "package")
               (:file "libsvm"))
  :serial t
  :depends-on (cffi))

(defmethod perform ((o test-op) (c (eql (find-system 'cl-libsvm))))
  (funcall (intern (symbol-name '#:test)
                   (find-package '#:cl-libsvm))))

(defmethod operation-done-p ((o test-op) (c (eql (find-system 'cl-libsvm))))
  (values nil))
