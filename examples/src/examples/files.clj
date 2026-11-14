(ns examples.files
  "File dialogs: Open (with filters), Save as, and Pick folder. Each result
  arrives as a message: the chosen path, or nil when cancelled."
  (:require [skald.core :as sk]))

(def init {:opened nil :saved nil :folder nil :log []})

(defn update-state [s msg]
  (let [s (update s :log #(vec (take-last 30 (conj % msg))))
        [tag v] (if (vector? msg) msg [msg])]
    (case tag
      :open   (sk/fx s (sk/open-file {:filters [["Text" "txt;md;clj"] ["Images" "png;jpg"] ["All files" "*"]]
                                      :on-result [:opened]}))
      :save   (sk/fx s (sk/save-file {:filters [["Text" "txt"]] :on-result [:saved]}))
      :pick   (sk/fx s (sk/open-folder {:on-result [:folder]}))
      :opened (assoc s :opened v)
      :saved  (do (when v (spit v "saved by examples.files\n"))   ; nil = cancelled
                  (assoc s :saved v))
      :folder (assoc s :folder v)
      :quit   (sk/fx s (sk/quit))
      s)))

(defn- result [label v]
  [:row {:spacing :sm}
   [:text {:width 90 :color :fg-muted} label]
   [:text (if (some? v) v "—")]])

(defn view [s]
  [:col {:padding :lg :spacing :md}
   [:text {:size :lg} "File dialogs"]
   [:row {:spacing :sm}
    [:button {:on-click :open} "Open…"]
    [:button {:on-click :save} "Save as…"]
    [:button {:on-click :pick} "Pick folder…"]]
   (result "Opened" (:opened s))
   (result "Saved" (:saved s))
   (result "Folder" (:folder s))
   [:text {:color :fg-muted :size :sm} "Cancelling a dialog delivers nil."]])

(defn -main [& _]
  (let [final (sk/run {:title "Files" :size [640 300]
                       :init init :update #'update-state :view #'view
                       :trace? (some? (System/getenv "SKALD_TRACE"))})]
    (println :final-state (pr-str (dissoc final :log)))
    (println :log (pr-str (:log final)))
    final))
