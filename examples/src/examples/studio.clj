(ns examples.studio
  "A small paint studio: canvas drawing, drag-and-drop swatches, rich text,
  split panes, a grid, a variable-height list, a second window and custom
  themes. Every message is logged in :log for the tests."
  (:require [skald.core :as sk]))

(def rose
  {:base :dark
   :color {:primary "#e11d48" :selection "#9f1239" :bg "#120a0e" :surface "#1d1217"}
   :radius {:sm 6 :md 12 :lg 16}
   :font {:size-md 14}})

(def mint
  {:base :light
   :color {:primary "#059669" :bg "#f0fdf4" :surface "#dcfce7"}
   :radius {:md 4}})

(def swatches ["#e11d48" "#f59e0b" "#10b981" "#3b82f6" "#8b5cf6" "#f8fafc"])

(def notes
  (vec (for [i (range 200)]
         {:id i :title (str "Note " i)
          ;; every third note is long, so rows really vary in height
          :body (if (zero? (mod i 3))
                  (apply str (repeat 4 "A longer note that wraps over several lines. "))
                  "Short note.")})))

(def init
  {:strokes [] :current nil :brush "#e11d48" :split 300 :theme :rose
   :inspector nil :link nil :files [] :picked nil :log []})

(defn log [s msg] (update s :log #(vec (take-last 200 (conj % msg)))))

(defn update-state [s msg]
  (let [s (log s msg)
        [tag v] (if (vector? msg) msg [msg])]
    (case tag
      :down    (assoc s :current {:color (:brush s) :points [[(:x v) (:y v)]]})
      :move    (if (:current s) (update-in s [:current :points] conj [(:x v) (:y v)]) s)
      :up      (if-let [c (:current s)]
                 (-> s (update :strokes conj c) (assoc :current nil))
                 s)
      :brush   (assoc s :brush (:color v))
      :split   (assoc s :split v)
      :link    (assoc s :link v)
      :files   (assoc s :files v)
      :pick    (assoc s :picked v)
      :clear   (assoc s :strokes [])
      :theme   (let [t (if (= :rose (:theme s)) :mint :rose)]
                 (sk/fx (assoc s :theme t) (sk/set-theme (if (= t :rose) rose mint))))
      :inspect (sk/fx s (sk/open-window {:title "Inspector" :size [320 200]
                                         :on-open [:opened] :on-close [:closed]}))
      :opened  (assoc s :inspector v)
      :close-inspector (sk/fx s (sk/close-window (:inspector s)))
      :closed  (assoc s :inspector nil)
      s)))

(defn canvas-view [s]
  (let [strokes (cond-> (:strokes s) (:current s) (conj (:current s)))]
    [:drop-target {:id "canvas" :accepts "swatch" :on-drop [:brush]}
     [:canvas {:size [520 360] :cursor :crosshair
               :on-press [:down] :on-drag [:move] :on-release [:up]
               :draw (concat
                      [[:rect 0 0 520 360 {:color (if (sk/drag-over? "canvas" "swatch") :selection :surface)
                                           :radius 12}]
                       [:rect-outline 0.5 0.5 519 359 {:color :border :radius 12}]
                       [:circle 460 60 24 {:color "#f59e0b"}]
                       [:ring 460 60 34 {:color "#f59e0b80" :width 3}]
                       [:arc 460 60 44 0 3.14159 {:color :primary :width 2}]
                       [:bezier [20 330] [140 240] [300 420] [500 320] {:color :fg-muted :width 2}]
                       [:polygon [[20 20] [70 20] [45 60]] {:color :primary}]
                       [:text 90 28 "Draw here — drop a swatch to change the brush" {:color :fg-muted :size 13}]]
                      (for [{:keys [color points]} strokes]
                        (if (= 1 (count points))
                          (let [[x y] (first points)] [:circle x y 2 {:color color}])
                          [:polyline points {:color color :width 3}])))}]]))

(defn sidebar [s]
  [:col {:spacing :md :padding :md}
   [:text {:size :lg} "Palette"]
   [:grid {:columns [40 40 40] :spacing 8}
    (for [c swatches]
      [:drag-source {:payload {:color c} :kind "swatch"}
       [:rect {:size [40 40] :color c :radius :sm}]
       [:rect {:size [28 28] :color c :radius :pill}]])]
   [:rich-text {:max-width 260 :on-link [:link]}
    "Drag a " [:b "swatch"] " onto the canvas, then " [:i "draw"] ". Built with "
    [:link {:href "https://github.com/BuLEEto/Skald"} "Skald"] " and "
    [:code "skald.core"] "."]
   [:text {:selectable true :color :fg-muted :size :sm :max-width 260}
    (str "Brush " (:brush s) " · " (count (:strokes s)) " strokes (selectable text)")]
   [:drop-zone {:on-drop [:files]}
    [:col {:padding :sm :bg :elevated :radius :sm :width 260}
     [:text {:color :fg-muted :size :sm}
      (if (seq (:files s)) (str (count (:files s)) " file(s) dropped") "Drop files here")]]]
   [:virtual-list {:variable-height true :estimated-height 40 :count (count notes)
                   :size [260 200] :key identity
                   :row (fn [i] (let [n (nth notes i)]
                                  [:col {:spacing 2 :padding 4}
                                   [:row {:spacing :sm :cross-align :center}
                                    [:text {:size :sm} (:title n)]
                                    [:button {:on-click [:pick i]} "Pick"]]
                                   [:text {:color :fg-muted :size :xs :max-width 240} (:body n)]]))}]])

(defn main-view [s]
  ;; a split fills the space it is given: stretch the column across the
  ;; window and give the split the remaining height
  [:col {:spacing :sm :cross-align :stretch :height 640}
   [:row {:spacing :sm :padding :sm}
    [:button {:on-click :inspect :disabled (some? (:inspector s))} "Open inspector"]
    [:button {:on-click :theme :bg :surface :fg :fg} "Switch theme"]
    [:button {:on-click :clear :bg :surface :fg :fg} "Clear"]]
   [:flex 1
    [:split {:first-size (:split s) :min-first 200 :min-second 300 :on-resize [:split]}
     (sidebar s)
     [:col {:padding :md} (canvas-view s)]]]])

(defn inspector-view [s]
  [:col {:padding :lg :spacing :md}
   [:text {:size :lg} "Inspector"]
   [:text (str (count (:strokes s)) " strokes, brush " (:brush s))]
   [:button {:on-click :close-inspector} "Close inspector"]])

(defn view [s]
  (if (sk/main-window?) (main-view s) (inspector-view s)))

(defn -main [& _]
  (let [final (sk/run {:title "Studio" :size [900 640] :theme rose
                       :init init :update #'update-state :view #'view
                       :trace? (some? (System/getenv "SKALD_TRACE"))})]
    (println :final-state (pr-str (-> final (dissoc :log)
                                      (update :strokes #(mapv (fn [st] (update st :points count)) %)))))
    (println :log (pr-str (remove #(and (vector? %) (= :move (first %))) (:log final))))
    final))
