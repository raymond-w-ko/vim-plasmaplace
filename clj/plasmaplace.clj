(ns plasmaplace)

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

(defmacro doc [sym]
  `(let [s# (with-out-str (clojure.repl/doc ~sym))]
    (vim-call "scratch" (pr-str s#))))

(vim-call "scratch" (pr-str "Clojure REPL loaded. Have fun!"))
