;; Pure check of skald.core/select-rows — no window needed.
;;   cd examples && jolt run ../test/select_rows_test.clj
(require '[skald.core :as sk])

;; rows are shown in reverse key order (as if sorted descending)
(def keys-shown [50 40 30 20 10])
(def key-of (fn [i] (keys-shown i)))
(def index-of (fn [k] (first (keep-indexed #(when (= %2 k) %1) keys-shown))))
(defn sel [s row & mods] (sk/select-rows s {:row row :mods (set mods)} key-of index-of))

(def s1 (sel nil 1))
(assert (= s1 {:selected #{40} :anchor 40 :focus 40}) "plain click selects one")
(def s2 (sel s1 3 :shift))
(assert (= (:selected s2) #{40 30 20}) "shift selects range from anchor")
(assert (= (:anchor s2) 40) "shift keeps the anchor")
(assert (= (:focus s2) 20) "shift moves focus")
(assert (= (:selected (sel s2 0 :shift)) #{50 40}) "shift range works upward and replaces")
(def s3 (sel s2 4 :ctrl))
(assert (= (:selected s3) #{40 30 20 10}) "ctrl adds")
(assert (= (:selected (sel s3 2 :super)) #{40 20 10}) "cmd (super) toggles off")
(assert (= (:selected (sel s3 0 :ctrl :shift)) #{50 40 30 20 10}) "ctrl+shift adds range from anchor 10")
(assert (= (:selected (sel {:selected #{99} :anchor 99} 2 :shift)) #{30})
        "shift with a vanished anchor acts as a plain click")
(println "select-rows: all assertions passed")
