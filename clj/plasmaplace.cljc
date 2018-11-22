(ns plasmaplace
  (:require [clojure.stacktrace]))

(def ^:const escape-prefix
  "The escape prefix: `<Esc> ] 5 1 ;`"
  "\u001b]51;")

(def ^:const escape-suffix
  "The escape suffix `<07>`"
  "\u0007")

(defn vim-call [fn-name json]
  (let [s (str escape-prefix
               "[\"call\",\"Tapi_plasmaplace_" fn-name
               "\","
               json
               "]"
               escape-suffix)]
   (.write *out* s)))

(defmacro capture-stack [form]
  `(try
    ~form
    (catch Exception e#
      (vim-call "scratch"
                (pr-str
                 (with-out-str
                  (clojure.stacktrace/print-stack-trace e#)))))))

(defmacro Doc [sym]
  `(capture-stack
    (let [s# (with-out-str (clojure.repl/doc ~sym))]
      (vim-call "scratch" (pr-str s#)))))

(defn Require [namespace- reload-level]
  (capture-stack
   (let [s (with-out-str (clojure.core/require namespace- reload-level))
         cmd (str "(plasmaplace/Require "
                  namespace-
                  " "
                  reload-level
                  ")\n")]
     (vim-call "scratch" (pr-str (str cmd s))))))

(vim-call "scratch" (pr-str "Clojure REPL loaded. Have fun!"))
