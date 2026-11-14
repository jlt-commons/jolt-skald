(ns examples.counter
  "The Skald README's counter, in Jolt."
  (:require [skald.core :as sk]))

(defn update-state [s msg]
  (case msg
    :inc (update s :count inc)
    :dec (update s :count dec)
    s))

(defn view [s]
  [:col {:padding :xl :main-align :center :cross-align :center}
   [:text {:size :display} (str "Count: " (:count s))]
   [:spacer :xl]
   [:row {:spacing :md}
    [:button {:on-click :dec :width 64} "−"]
    [:button {:on-click :inc :width 64 :bg :primary :fg :on-primary} "+"]]])

(def app
  "The app's options — shared by -main, examples.dev and (sk/start! c/app)."
  {:title  "Hello"
   :size   [640 400]
   :theme  :dark
   :init   {:count 0}
   :update #'update-state
   :view   #'view})

(defn -main [& _]
  (let [final (sk/run app)]
    (println :final-state (pr-str final))
    final))
