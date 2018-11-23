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
  (let [text
        #?(:clj (with-out-str (clojure.stacktrace/print-stack-trace e))
           :cljs (do (console/log e)
                     (str "SEE JS CONSOLE" "\n" e)))]
    (vim-call "scratch"
            (pr-str text))))

(defn Doc [s]
  (vim-call "scratch" (pr-str s)))

(defn Require [namespace- reload-level]
  (try
   (let [ret #?(:clj (with-out-str (clojure.core/require namespace- reload-level))
              :cljs "TODO: use figwheel or shadow-cljs, this should not be necessary")
         cmd (str "(plasmaplace/Require "
                  namespace-
                  " "
                  reload-level
                  ")\n")]
     (vim-call "scratch" (pr-str (str cmd ret))))
   (catch #?(:clj Exception :cljs :default) e
     (log-stack e))))

(vim-call "scratch" (pr-str "Clojure REPL loaded. Have fun!"))
