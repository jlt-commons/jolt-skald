(ns examples.keys
  "Keyboard: arrow keys move the square, Escape puts it back (`:on-key`);
  Ctrl+K toggles a panel from anywhere, no menu bar needed (`[:shortcut]`).
  Typing in the text field doesn't move the square: `:on-key` is quiet while
  a text field has focus."
  (:require [skald.core :as sk]))

(def size 320)
(def step 20)
(def start [150 150])

(def init {:pos start :panel? false :last nil :note "" :log []})

(def moves {:left [(- step) 0] :right [step 0] :up [0 (- step)] :down [0 step]})

(defn- clamp-pos [[x y]] [(max 0 (min (- size 20) x)) (max 0 (min (- size 20) y))])

(defn update-state [s msg]
  (let [s (update s :log #(vec (take-last 100 (conj % msg))))
        [tag v] (if (vector? msg) msg [msg])]
    (case tag
      :key   (let [s (assoc s :last v)]
               (cond
                 (not (:pressed? v))      s
                 (= :escape (:key v))     (assoc s :pos start)
                 (moves (:key v))         (update s :pos #(clamp-pos (mapv + % (moves (:key v)))))
                 :else                    s))
      :panel (update s :panel? not)
      :note  (assoc s :note v)
      :quit  (sk/fx s (sk/quit))
      s)))

(defn view [s]
  (let [[x y] (:pos s)]
    [:col {:padding :lg :spacing :md}
     [:shortcut {:keys "Ctrl+K" :on-press :panel}]
     [:text {:size :lg} "Arrow keys move, Escape resets, Ctrl+K toggles the panel"]
     [:row {:spacing :lg :cross-align :start}
      [:canvas {:size [size size]
                :draw [[:rect 0 0 size size {:color :surface :radius 8}]
                       [:rect x y 20 20 {:color :primary :radius 4}]]}]
      [:col {:spacing :sm :width 260}
       [:text-input {:id "note" :value (:note s) :placeholder "Type here — the square stays put"
                     :on-change [:note]}]
       [:text {:color :fg-muted}
        (str "Last key: " (if-let [k (:last s)] (pr-str k) "none"))]
       [:text {:color :fg-muted} (str "Position: " (pr-str (:pos s)))]
       (when (:panel? s)
         [:col {:padding :md :bg :elevated :radius :md}
          [:text "Panel (Ctrl+K to hide)"]])]]]))

(defn -main [& _]
  (let [final (sk/run {:title "Keys" :size [700 460]
                       :init init :update #'update-state :view #'view
                       :on-key [:key]
                       :trace? (some? (System/getenv "SKALD_TRACE"))})]
    (println :final-state (pr-str (dissoc final :log)))
    (println :log (pr-str (:log final)))
    final))
