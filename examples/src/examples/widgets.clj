(ns examples.widgets
  "The second batch of widgets: pickers, menus, tree, accordion, toast,
  images and charts. Every message is logged in :log, so a test can see
  exactly what each interaction delivered."
  (:require [skald.core :as sk]))

(def init
  {:fruit "Apple" :date {:year 2026 :month 11 :day 6} :time {:hour 9 :minute 30 :second 0}
   :color "#3b82f6" :stars 3 :size 1 :query "" :searched nil
   :tags ["jolt" "odin" "skald"] :crumb 2 :step 1
   :tree-open #{0} :tree-sel nil :section 0 :toast? false :log []})

(def tree-data
  [{:depth 0 :label "src" :expandable true :icon "📁"}
   {:depth 1 :label "core.clj" :parent 0 :icon "📄"}
   {:depth 1 :label "native.clj" :parent 0 :icon "📄"}
   {:depth 0 :label "README.md" :icon "📄"}])

(defn tree-rows [{:keys [tree-open tree-sel]}]
  (vec (for [[i r] (map-indexed vector tree-data)
             :when (or (nil? (:parent r)) (tree-open (:parent r)))]
         (assoc (dissoc r :parent) :expanded (contains? tree-open i) :selected (= i tree-sel) ::idx i))))

(defn update-state [s msg]
  (let [s (update s :log #(vec (take-last 100 (conj % msg))))
        [tag v] (if (vector? msg) msg [msg])]
    (case tag
      :fruit   (assoc s :fruit v)
      :date    (assoc s :date v)
      :time    (assoc s :time v)
      :color   (assoc s :color v)
      :stars   (assoc s :stars v)
      :size    (assoc s :size v)
      :query   (assoc s :query v)
      :search  (assoc s :searched (:query s))
      :untag   (update s :tags (fn [ts] (vec (remove #{v} ts))))
      :crumb   (assoc s :crumb v)
      :next    (update s :step #(min 3 (inc %)))
      :tree-toggle (let [i (::idx (nth (tree-rows s) v))]
                     (update s :tree-open #(if (% i) (disj % i) (conj % i))))
      :tree-select (assoc s :tree-sel (::idx (nth (tree-rows s) v)))
      :section (assoc s :section (if (= v (:section s)) -1 v))
      :new     (assoc s :toast? true)
      :toast-closed (assoc s :toast? false)
      :ctx     s
      :quit    (sk/fx s (sk/quit))
      s)))

(defn card [title & body]
  (into [:col {:spacing :sm :padding :md :bg :surface :radius :md :width 330}
         [:section-header {:font-size :sm} title]]
        body))

(defn view [s]
  [:col {:spacing :md}
   [:menu-bar
    [:menu "File"
     [:menu-item {:on-click :new :shortcut "Ctrl+N"} "New"]
     [:menu-item {:on-click :open :shortcut "Ctrl+O"} "Open…"]
     [:menu-separator]
     [:menu-item {:on-click :quit :shortcut "Ctrl+Q"} "Quit"]]
    [:menu "View"
     [:menu-item {:on-click :zoom :checked true} "Zoom"]]]
   [:row {:spacing :md :cross-align :start}
    [:col {:padding :md :spacing :md}
     (card "Pickers"
           [:combobox {:value (:fruit s) :options ["Apple" "Banana" "Cherry" "Durian"]
                       :free-form true :width 200 :on-change [:fruit]}]
           [:date-picker {:value (:date s) :width 200 :week-start :monday :on-change [:date]}]
           [:time-picker {:value (:time s) :width 200 :on-change [:time]}]
           [:color-picker {:value (:color s) :width 200 :on-change [:color]}]
           [:rating {:value (:stars s) :on-change [:stars]}])
     (card "Search"
           [:search-field {:value (:query s) :placeholder "Search…" :width 300
                           :on-change [:query] :on-submit :search}]
           [:text {:color :fg-muted :size :sm} (str "Searched: " (pr-str (:searched s)))])]
    [:col {:padding :md :spacing :md}
     (card "Choices"
           [:radio-group {:options ["Small" "Medium" "Large"] :selected (:size s)
                          :direction :row :on-change [:size]}]
           [:wrap-row {:spacing :xs}
            (for [t (:tags s)] [:chip {:on-close [:untag]} t])]
           [:breadcrumb {:segments ["Home" "Projects" "jolt-skald"] :on-select [:crumb]}]
           [:stepper {:labels ["Cart" "Address" "Pay" "Done"] :active (:step s)}]
           [:button {:on-click :next} "Next step"])
     (card "Tree"
           [:tree {:rows (tree-rows s) :width 300 :on-toggle [:tree-toggle] :on-select [:tree-select]}])]
    [:col {:padding :md :spacing :md}
     (card "Display"
           [:accordion {:titles ["Image" "Avatars"] :active (:section s) :on-toggle [:section]}
            [:image {:src "resources/sample.png" :size [240 140] :radius :md :fit :cover}]
            [:row {:spacing :sm} [:avatar "AL"] [:avatar {:bg :success} "JS"] [:avatar {:size 40 :bg :warning} "OD"]]]
           [:row {:spacing :md :cross-align :center}
            [:gauge {:value 0.72 :size 56}]
            [:sparkline {:values [3 5 4 8 6 9 7 11 10 12] :size [180 40] :fill 0.2}]]
           [:bar-chart {:values [4 7 3 9 5 8 6] :size [240 60] :gap 4}]
           [:context-menu {:items ["Copy" "Paste" "Delete"] :on-select [:ctx]}
            [:col {:padding :md :bg :elevated :radius :sm :width 240}
             [:text {:color :fg-muted :size :sm} "Right-click me"]]])]]
   [:toast {:visible (:toast? s) :kind :success :anchor :top-right
            :dismiss-after 1.5 :on-close :toast-closed} "New document created"]])

(defn -main [& _]
  (let [final (sk/run {:title "Widgets" :size [1100 720]
                       :init init :update #'update-state :view #'view
                       :trace? (some? (System/getenv "SKALD_TRACE"))})]
    (println :final-state (pr-str final))
    final))
