(ns examples.todo
  "A todo list: text input, keyed rows, checkboxes, a filter, a slider,
  timed commands, messages from a background thread, and a confirm-on-close
  dialog."
  (:require [clojure.string :as str]
            [skald.core :as sk]))

(def filters ["All" "Active" "Done"])

(def init
  {:draft    ""
   :next-id  1
   :items    []
   :filter   0
   :priority 3.0
   :status   "Ready"
   :confirm? false})

(defn add-item [s]
  (let [text (str/trim (:draft s))]
    (if (str/blank? text)
      s
      (sk/fx (-> s
                 (update :items conj {:id (:next-id s) :text text :done false
                                      :priority (long (:priority s))})
                 (update :next-id inc)
                 (assoc :draft "" :status "Saving…"))
             (sk/after 0.3 [:status "Saved"])))))

(defn update-state [s msg]
  (let [[tag arg arg2] (if (vector? msg) msg [msg])]
    (case tag
      :draft       (assoc s :draft arg)
      :add         (add-item s)
      :toggle      (update s :items (partial mapv #(if (= (:id %) arg) (assoc % :done arg2) %)))
      :remove      (update s :items (partial filterv #(not= (:id %) arg)))
      :filter      (assoc s :filter arg)
      :priority    (assoc s :priority arg)
      :status      (assoc s :status arg)
      :ask-quit    (assoc s :confirm? true)
      :cancel-quit (assoc s :confirm? false)
      :really-quit (sk/fx (assoc s :confirm? false) (sk/quit))
      s)))

(defn visible [{:keys [items] which :filter}]
  (case (long which)
    0 items
    1 (remove :done items)
    2 (filter :done items)))

(defn item-row [{:keys [id text done priority]}]
  ;; :scope keys the row so its widgets keep their state when rows move.
  [:scope {:key id}
   [:row {:spacing :sm :cross-align :center}
    [:flex 1 [:checkbox {:checked done :on-change [:toggle id]} text]]
    [:badge {:tone (if (>= priority 7) :danger :neutral)} (str "P" priority)]
    [:button {:on-click [:remove id] :bg :surface :fg :fg-muted} "×"]]])

(defn view [s]
  [:col {:padding :lg :spacing :md :cross-align :stretch}
   [:text {:size :xl} "Todo"]
   [:row {:spacing :sm :cross-align :center}
    [:flex 1 [:text-input {:id "draft" :value (:draft s)
                           :placeholder "What needs doing?"
                           :on-change [:draft]}]]
    [:button {:on-click :add :disabled (str/blank? (:draft s))} "Add"]]
   [:row {:spacing :md :cross-align :center}
    [:text {:color :fg-muted} "Priority"]
    [:slider {:value (:priority s) :min 0 :max 10 :step 1 :width 200
              :on-change [:priority]}]
    [:text (str (long (:priority s)))]]
   [:segmented {:options filters :selected (:filter s) :on-change [:filter]}]
   [:divider]
   (let [items (visible s)]
     (if (seq items)
       (map item-row items)
       [:text {:color :fg-muted} "Nothing here."]))
   [:divider]
   [:text {:size :sm :color :fg-muted} (:status s)]
   [:dialog {:open (:confirm? s) :on-dismiss :cancel-quit}
    [:col {:spacing :sm}
     [:text {:size :lg} "Quit?"]
     [:text {:color :fg-muted} (str (count (remove :done (:items s))) " items still open.")]]
    [:row {:spacing :sm :main-align :end}
     [:button {:on-click :cancel-quit :bg :surface :fg :fg} "Cancel"]
     [:button {:on-click :really-quit :bg :danger} "Quit"]]]])

(defn -main [& _]
  ;; Messages may be dispatched from any thread, even before the window opens.
  (sk/dispatch! [:status "Queued before run"])
  (future (Thread/sleep 1500) (sk/dispatch! [:status "Hello from a background thread"]))
  (let [final (sk/run {:title            "Todo"
                       :size             [520 560]
                       :init             init
                       :update           #'update-state
                       :view             #'view
                       :on-close-request :ask-quit
                       :trace?           (some? (System/getenv "SKALD_TRACE"))})]
    ;; As on the JVM, the future pool keeps the process alive until released.
    (shutdown-agents)
    (println :final-state (pr-str final))
    final))
