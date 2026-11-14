(ns examples.gallery
  "Every widget skald.core binds, on one screen."
  (:require [skald.core :as sk]))

(def init
  {:tab 0 :toggle true :radio :b :choice "Medium" :qty 3.0
   :details? true :theme :dark :clicks 0})

(defn update-state [s msg]
  (let [[tag v] (if (vector? msg) msg [msg])]
    (case tag
      :tab      (assoc s :tab v)
      :toggle   (assoc s :toggle v)
      :radio    (assoc s :radio v)
      :choice   (assoc s :choice v)
      :qty      (assoc s :qty v)
      :details  (assoc s :details? v)
      :click    (update s :clicks inc)
      :theme    (let [t (if (= (:theme s) :dark) :light :dark)]
                  (sk/fx (assoc s :theme t) (sk/set-theme t)))
      s)))

(defn card [title & body]
  (into [:col {:spacing :sm :padding :md :bg :surface :radius :md :width 300}
         [:section-header {:font-size :sm} title]]
        body))

(defn inputs [s]
  (card "Inputs"
        [:toggle {:checked (:toggle s) :on-change [:toggle]} "Notifications"]
        [:row {:spacing :md}
         (for [k [:a :b :c]]
           [:radio {:selected (= k (:radio s)) :on-select [:radio k]} (name k)])]
        [:select {:value (:choice s) :options ["Small" "Medium" "Large"]
                  :width 160 :on-change [:choice]}]
        [:number-input {:value (:qty s) :min 0 :max 99 :on-change [:qty]}]))

(defn display [s]
  (card "Display"
        [:row {:spacing :sm}
         [:badge "Primary"] [:badge {:tone :success} "OK"]
         [:badge {:tone :warning} "Slow"] [:badge {:tone :danger} "Down"]]
        [:row {:spacing :sm :cross-align :center}
         [:text {:color :fg-muted} "Save with"] [:kbd "Ctrl"] [:kbd "S"]]
        [:progress {:value 0.65 :width 260}]
        [:row {:spacing :md :cross-align :center}
         [:spinner {:size 20}] [:text {:color :fg-muted} "Loading…"]]
        [:alert {:tone :warning :description "Disk is 91% full."} "Heads up"]))

(defn layout [s]
  (card "Layout"
        [:wrap-row {:spacing :xs :line-spacing :xs :width 270}
         (for [c ["#ef4444" "#f59e0b" "#10b981" "#3b82f6" "#8b5cf6" "#ec4899"
                  "#14b8a6" "#f97316" "#64748b"]]
           [:rect {:size [36 20] :color c :radius :sm}])]
        [:collapsible {:title "Details" :open (:details? s) :on-toggle [:details]}
         [:text {:color :fg-muted :max-width 240}
          "Collapsible bodies, wrapped text and tooltips all come from Skald."]]
        [:tooltip {:text (str "Clicked " (:clicks s) " times")}
         [:link {:on-click :click} "Hover or click me"]]
        [:scroll {:size [270 60]}
         [:col (for [i (range 1 9)] [:text {:size :sm} (str "Scrollable row " i)])]]))

(defn view [s]
  [:col {:padding :lg :spacing :md}
   [:row {:spacing :md :cross-align :center}
    [:text {:size :xl} "Skald from Jolt"]
    [:button {:on-click :theme :bg :surface :fg :fg}
     (if (= :dark (:theme s)) "Light theme" "Dark theme")]]
   [:tabs {:labels ["Widgets" "About"] :active (:tab s) :on-change [:tab]}]
   (case (long (:tab s))
     0 [:row {:spacing :md} (inputs s) (display s) (layout s)]
     1 [:empty-state {:title "About" :description "Built with skald.core."}
        [:button {:on-click [:tab 0]} "Back to widgets"]])])

(defn -main [& _]
  (let [final (sk/run {:title "Gallery" :size [1000 560]
                       :init init :update #'update-state :view #'view})]
    (println :final-state (pr-str final))
    final))
