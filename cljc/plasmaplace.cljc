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
   (print s)))

(defn log-stack [e]
  (vim-call "scratch"
            (pr-str
             (with-out-str
              (clojure.stacktrace/print-stack-trace e)))))

(comment
 defmacro capture-stack [form]
  `(try
    ~form
    (catch Exception e#
      )))

(defn Doc [s]
  (vim-call "scratch" (pr-str s)))

(defn Require [namespace- reload-level]
  (try
   (let [s (with-out-str #?(:clj (clojure.core/require namespace- reload-level)
                            :cljs "TODO"))
         cmd (str "(plasmaplace/Require "
                  namespace-
                  " "
                  reload-level
                  ")\n")]
     (vim-call "scratch" (pr-str (str cmd s))))
   (catch #?(:clj Exception :cljs js/Error) e
     (log-stack e))))

(vim-call "scratch" (pr-str "Clojure REPL loaded. Have fun!"))
