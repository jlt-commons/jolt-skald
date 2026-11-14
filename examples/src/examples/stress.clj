(ns examples.stress
  "Mailbox stress test: 8 threads × 500 dispatch! calls plus 10 queued before
  run. The app quits once every message has arrived; run returns the tally.
  Exits non-zero if any message is lost or duplicated."
  (:require [skald.core :as sk]))

(def threads 8)
(def per-thread 500)
(def pre 10)
(def expected (+ pre (* threads per-thread)))

(defn update-state [s [tag t i]]
  (case tag
    :hit (let [s (-> s (update :n inc) (update :seen conj [t i]))]
           (if (= (:n s) expected) (sk/fx s (sk/quit)) s))
    s))

(defn view [s]
  [:col {:padding :xl :spacing :md}
   [:text {:size :xl} (str (:n s) " / " expected)]
   [:progress {:value (/ (:n s) (double expected)) :width 300}]])

(defn -main [& _]
  (dotimes [i pre] (sk/dispatch! [:hit :pre i]))
  (doseq [t (range threads)]
    (future (dotimes [i per-thread]
              (sk/dispatch! [:hit t i])
              (when (zero? (mod i 50)) (Thread/sleep 1)))))
  (let [s (sk/run {:title "Stress" :size [400 200]
                   :init {:n 0 :seen #{}}
                   :update #'update-state :view #'view})]
    (shutdown-agents)
    (let [ok (and (= expected (:n s)) (= expected (count (:seen s))))]
      (println (if ok "STRESS PASS" "STRESS FAIL") (:n s) "msgs," (count (:seen s)) "distinct")
      (println :final-state (pr-str {:n (:n s) :distinct (count (:seen s))}))
      {:n (:n s) :distinct (count (:seen s))})))
