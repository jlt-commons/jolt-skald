(ns examples.data
  "Virtualized data: a 10,000-row table (sortable, resizable columns,
  multi-select with Shift / Ctrl / Cmd, double-click / Enter to open) and a 100,000-row virtual list
  whose rows contain buttons. Only visible rows are ever built."
  (:require [skald.core :as sk]))

(def files
  (vec (for [i (range 10000)]
         {:id i
          :name (str "file-" (format "%05d" i) ".txt")
          :size (mod (* (inc i) 7919) 100000)
          :kind (["text" "image" "audio" "video"] (mod i 4))})))

(def sort-keys [:name :size :kind])

(def sorted-rows
  ;; sorting 10k rows on every repaint would be wasteful; cache per order
  (memoize (fn [col asc?]
             (let [v (vec (sort-by (sort-keys col) files))]
               (if asc? v (vec (rseq v)))))))

(def id->index
  (memoize (fn [col asc?]
             (into {} (map-indexed (fn [i r] [(:id r) i]) (sorted-rows col asc?))))))

(def init {:sort-col 0 :asc? true :sel nil :opened nil
           :widths {0 220 1 120} :picked nil :log []})

(defn rows [s] (sorted-rows (:sort-col s) (:asc? s)))

(defn update-state [s msg]
  (let [s (update s :log #(vec (take-last 30 (conj % msg))))
        [tag v] (if (vector? msg) msg [msg])]
    (case tag
      :sort   (assoc s :sort-col (:column v) :asc? (:ascending v))
      :select (let [rs (rows s)]
                (update s :sel sk/select-rows v #(:id (nth rs %))
                        (id->index (:sort-col s) (:asc? s))))
      :open   (assoc s :opened (:name (nth (rows s) v)))
      :resize (assoc-in s [:widths (:column v)] (:width v))
      :pick   (assoc s :picked v)
      :quit   (sk/fx s (sk/quit))
      s)))

(defn view [s]
  (let [rs (rows s)]
    [:row {:padding :lg :spacing :lg :cross-align :start}
     [:col {:spacing :sm}
      [:text {:size :lg} "10,000 files"]
      [:table {:columns [{:label "Name" :width (get-in s [:widths 0]) :sortable true :resizable true}
                         {:label "Size" :width (get-in s [:widths 1]) :sortable true :resizable true :align :end}
                         {:label "Kind" :weight 1 :sortable true}]
               :count (count rs) :row-height 28 :size [560 420]
               :row (fn [i] (let [r (nth rs i)]
                              [[:text (:name r)] [:text (str (:size r))] [:text {:color :fg-muted} (:kind r)]]))
               :key (fn [i] (:id (nth rs i)))
               :selected? (fn [i] (contains? (get-in s [:sel :selected]) (:id (nth rs i))))
               :sort-column (:sort-col s) :ascending (:asc? s)
               ;; the keyboard (Up/Down/Home/End) moves from the focus row
               :focus-row (get (id->index (:sort-col s) (:asc? s)) (get-in s [:sel :focus]) -1)
               :on-row-select [:select] :on-row-activate [:open]
               :on-sort [:sort] :on-resize [:resize]}]
      [:text {:color :fg-muted :size :sm}
       (str "Selected ids: " (pr-str (sort (get-in s [:sel :selected]))) "   Opened: " (pr-str (:opened s)))]]
     [:col {:spacing :sm}
      [:text {:size :lg} "100,000 items"]
      [:virtual-list {:count 100000 :row-height 32 :size [300 420]
                      :key identity
                      :row (fn [i] [:row {:spacing :sm :cross-align :center :padding 2}
                                    [:col {:width 160} [:text (str "Item " i)]]
                                    [:button {:on-click [:pick i]} "Pick"]])}]
      [:text {:color :fg-muted :size :sm} (str "Picked: " (pr-str (:picked s)))]]]))

(defn -main [& _]
  (let [final (sk/run {:title "Data" :size [960 560]
                       :init init :update #'update-state :view #'view
                       :trace? (some? (System/getenv "SKALD_TRACE"))})]
    (println :final-state (pr-str (dissoc final :log)))
    (println :log (pr-str (:log final)))
    final))
