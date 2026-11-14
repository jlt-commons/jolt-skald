(ns skald.core
  "Elm-architecture GUIs in Jolt, rendered by Skald.

    (require '[skald.core :as sk])

    (sk/run {:title  \"Counter\"
             :init   {:count 0}
             :update (fn [s msg]
                       (case msg
                         :inc (update s :count inc)
                         :dec (update s :count dec)))
             :view   (fn [s]
                       [:col {:padding :xl :spacing :md :cross-align :center}
                        [:text {:size :display} (str \"Count: \" (:count s))]
                        [:row {:spacing :md}
                         [:button {:on-click :dec} \"-\"]
                         [:button {:on-click :inc} \"+\"]]])})

  Views are hiccup. Messages are any value. A widget that reports a value
  (text input, slider, checkbox…) combines it with its message:

    fn       -> (f value)
    vector   -> (conj v value)        [:set-name] => [:set-name \"Ada\"]
    other    -> [msg value]           :set-name   => [:set-name \"Ada\"]

  `update` returns the new state, or `(fx state cmd...)` to also run
  commands (`now`, `after`, `quit`, `set-theme`, `open-file`, `save-file`,
  `open-folder`)."
  (:require [jolt.ffi :as ffi]
            [clojure.string :as str]
            [skald.native :as n]))

;; ===========================================================================
;; Keyword tables, built from the shim's own enums
;; ===========================================================================

(defn- kebab [s] (-> s str/lower-case (str/replace "_" "-")))

(defn- enum-table [kind]
  (into {} (for [i (range (n/enum-count kind))]
             [(keyword (kebab (n/enum-name kind i))) i])))

(def ^:private tables
  (delay
    (let [abi (n/abi-version)]
      (when-not (= 3 abi)
        (throw (ex-info "libskald_jolt ABI mismatch — rebuild it with `jolt native`"
                        {:expected 3 :got abi}))))
    (let [props (enum-table 0)]
      {:prop        props
       :prop-kind   (into {} (for [[k i] props] [k (n/prop-kind i)]))
       :color-role  (enum-table 1)
       :token       (enum-table 2)
       :main-align  (enum-table 3)
       :cross-align (enum-table 4)
       :overflow    (enum-table 5)
       :tone        (enum-table 6)
       :modifier    (enum-table 8)
       :key         (into {} (map (fn [[k i]] [i k])) (enum-table 9))})))

(defn- t [k] (get @tables k))

;; ===========================================================================
;; Message tables
;; ===========================================================================
;;
;; Tags >= 0 index the current frame's table, rebuilt by every view. The
;; shim guarantees every message a view emits reaches update before the
;; table is reset. Tags <= -16 are persistent (commands, dispatch!, the
;; close handler) and are released when delivered.

(def ^:private frame-msgs (volatile! []))

;; Row functions of the virtual lists / tables in the current frame. Skald
;; asks for rows during layout, after the view returned and before update,
;; so these live exactly as long as the frame's message table.
(def ^:private frame-lists (volatile! []))

(defn- list-handle! [spec]
  (let [v @frame-lists]
    (vreset! frame-lists (conj v spec))
    (count v)))

(defn- frame-tag! [msg]
  (let [v @frame-msgs]
    (vreset! frame-msgs (conj v msg))
    (count v)))

(def ^:private persistent (atom {:next -16 :msgs {} :sticky #{}}))

(defn- persistent-tag!
  ([msg] (persistent-tag! msg false))
  ([msg sticky?]
   (let [[old _] (swap-vals! persistent
                             (fn [{:keys [next] :as p}]
                               (-> p
                                   (assoc :next (dec next))
                                   (assoc-in [:msgs next] msg)
                                   (cond-> sticky? (update :sticky conj next)))))]
     (:next old))))

(defn- take-persistent! [tag]
  (let [[old _] (swap-vals! persistent
                            (fn [p] (if (contains? (:sticky p) tag)
                                      p
                                      (update p :msgs dissoc tag))))]
    (get-in old [:msgs tag])))

(defn- combine [tmpl value]
  (cond
    (nil? tmpl)    nil
    (= value ::none) (if (fn? tmpl) (tmpl) tmpl)
    (fn? tmpl)     (tmpl value)
    (vector? tmpl) (conj tmpl value)
    :else          [tmpl value]))

;; ===========================================================================
;; Colors and property marshalling
;; ===========================================================================

(defn- hex->rgba [s]
  (let [h (str/replace s "#" "")
        h (case (count h)
            3 (apply str (mapcat #(repeat 2 %) h))
            4 (apply str (mapcat #(repeat 2 %) h))
            h)
        byte-at (fn [i] (/ (Long/parseLong (subs h i (+ i 2)) 16) 255.0))]
    (when-not (#{6 8} (count h))
      (throw (ex-info (str "bad color " s) {:color s})))
    [(byte-at 0) (byte-at 2) (byte-at 4) (if (= 8 (count h)) (byte-at 6) 1.0)]))

(defn rgba
  "An sRGB color literal (the space hex codes and design tools use):
  (rgba 255 128 0) or (rgba 1.0 0.5 0.0 0.8). Channels above 1 are taken as
  0-255; alpha is always 0-1. Skald renders in linear space; the conversion
  happens in the shim."
  ([r g b] (rgba r g b 1.0))
  ([r g b a]
   (let [scale (if (some #(> % 1) [r g b]) 255.0 1.0)]
     [(/ r scale) (/ g scale) (/ b scale) (double a)])))

;; Drag payloads: any value. A drag spans frames, so ids must be stable:
;; the id is derived from the value and the map survives between frames.
(def ^:private drag-payloads (atom {}))

(defn- payload-id! [v]
  (let [id (bit-and (long (hash v)) 0x3fffffffffffffff)]
    (swap! drag-payloads (fn [m] (assoc (if (> (count m) 10000) {} m) id v)))
    id))

(declare theme-color)

(defn- color->rgba
  "Any color value -> sRGB [r g b a]. Theme roles need an active view."
  [v]
  (cond
    (keyword? v) (theme-color v)
    (string? v)  (hex->rgba v)
    (vector? v)  (apply rgba v)
    :else (throw (ex-info (str "bad color " (pr-str v)) {:color v}))))

(defn- set-color! [ki v]
  (cond
    (keyword? v)
    (if-let [role (get (t :color-role) v)]
      (n/pc-role ki role)
      (throw (ex-info (str "unknown theme color " v)
                      {:color v :known (sort (keys (t :color-role)))})))
    (string? v) (let [[r g b a] (hex->rgba v)] (n/pc ki r g b a))
    (vector? v) (let [[r g b a] (apply rgba v)] (n/pc ki r g b a))
    (nil? v)    nil
    :else (throw (ex-info (str "bad color " (pr-str v)) {:color v}))))

(defn- token-scale [k]
  (case k
    (:size :font-size) 2
    :radius 1
    0))

(defn- enum-value [k v]
  (let [table (case k
                :main-align  (t :main-align)
                (:cross-align :align) (t :cross-align)
                :overflow    (t :overflow)
                :tone        (t :tone)
                nil)]
    (or (get table v)
        (throw (ex-info (str "bad value " v " for " k)
                        {:prop k :value v :known (sort (keys table))})))))

(defn- set-vec! [ki v]
  (cond
    (contains? v :year)
    (n/pv ki (double (:year v 0)) (double (:month v 1)) (double (:day v 1)) 0.0)
    (contains? v :hour)
    (n/pv ki (double (:hour v 0)) (double (:minute v 0)) (double (:second v 0)) 0.0)
    :else (throw (ex-info (str "expected a date {:year :month :day} or time {:hour :minute :second}, got " (pr-str v))
                          {:value v}))))

(defn- set-prop!
  ([k v] (set-prop! k v (token-scale k)))
  ([k v scale]
   (if (and (= k :size) (vector? v))
     (let [[w h] v] (set-prop! :width w) (set-prop! :height h))
     (when-let [ki (get (t :prop) k)]
       (case (long (get (t :prop-kind) k))
         0 (cond
             (number? v)  (n/pf ki (double v))
             (keyword? v) (if-let [tok (get (t :token) v)]
                            (n/pf-token ki scale tok)
                            (throw (ex-info (str "unknown size token " v)
                                            {:prop k :known (sort (keys (t :token)))})))
             (string? v)  (n/ps ki v) ; `:value` of text widgets
             (map? v)     (set-vec! ki v) ; dates and times
             (nil? v)     nil
             :else (throw (ex-info (str "bad number for " k ": " (pr-str v)) {:prop k :value v})))
         1 (set-color! ki v)
         2 (when (some? v) (n/ps ki (if (keyword? v) (name v) (str v))))
         3 (cond
             (= k :id)   (if (integer? v) (n/pi ki v) (n/pid-str (if (keyword? v) (str v) (str v))))
             (boolean? v) (n/pi ki (if v 1 0))
             (integer? v) (n/pi ki v)
             (keyword? v) (n/pi ki (enum-value k v))
             (nil? v)     nil
             :else (throw (ex-info (str "bad value for " k ": " (pr-str v)) {:prop k :value v})))
         4 (when (some? v) (n/pi ki (frame-tag! v))))))))

;; ===========================================================================
;; The hiccup walker
;; ===========================================================================

(declare emit)

(defn- emit-kids [kids] (doseq [k kids] (emit k)))

(defn- opts! [xs]
  (doseq [x xs] (n/opt (if (keyword? x) (name x) (str x)))))

(def ^:private list-props #{:options :labels :items :titles :segments})

(defn- set-props! [props]
  (doseq [[k v] props
          :when (not (or (list-props k) (#{:key :values :rows} k)))]
    (set-prop! k v)))

(defn- lists! [props]
  (when-let [o (some props [:options :labels :items :titles :segments])] (opts! o))
  (doseq [x (:values props)] (n/val (double x))))

(defn- text-of [kids] (apply str (map #(if (keyword? %) (name %) (str %)) kids)))

;; tag -> [shape builder text-prop]
;;   :box   children are views, emitted inside begin/…/builder
;;   :leaf  string children become `text-prop`
(def ^:private elements
  {:col            [:box  n/col]
   :row            [:box  n/row]
   :wrap-row       [:box  n/wrap-row]
   :flex           [:box  n/flex]
   :clip           [:box  n/clip]
   :opacity        [:box  n/opacity]
   :scroll         [:box  n/scroll]
   :tooltip        [:box  n/tooltip]
   :collapsible    [:box  n/collapsible]
   :dialog         [:box  n/dialog]
   :empty-state    [:box  n/empty-state]
   :context-menu   [:box  n/context-menu]
   :accordion      [:box  n/accordion]
   :drop-target    [:box  n/drop-target]
   :drop-zone      [:box  n/drop-zone]
   :split          [:box  n/split]
   :shortcut       [:leaf n/shortcut]
   :text           [:leaf n/text           :text]
   :button         [:leaf n/button         :label]
   :link           [:leaf n/link           :label]
   :badge          [:leaf n/badge          :label]
   :kbd            [:leaf n/kbd            :label]
   :checkbox       [:leaf n/checkbox       :label]
   :toggle         [:leaf n/toggle         :label]
   :radio          [:leaf n/radio          :label]
   :section-header [:leaf n/section-header :title]
   :alert          [:leaf n/alert          :title]
   :spacer         [:leaf n/spacer         :size]
   :rect           [:leaf n/rect]
   :divider        [:leaf n/divider]
   :text-input     [:leaf n/text-input]
   :slider         [:leaf n/slider]
   :number-input   [:leaf n/number-input]
   :select         [:leaf n/select]
   :segmented      [:leaf n/segmented]
   :tabs           [:leaf n/tabs]
   :progress       [:leaf n/progress]
   :spinner        [:leaf n/spinner]
   :combobox       [:leaf n/combobox]
   :date-picker    [:leaf n/date-picker]
   :time-picker    [:leaf n/time-picker]
   :color-picker   [:leaf n/color-picker]
   :rating         [:leaf n/rating]
   :radio-group    [:leaf n/radio-group]
   :search-field   [:leaf n/search-field]
   :chip           [:leaf n/chip           :label]
   :breadcrumb     [:leaf n/breadcrumb]
   :menu           [:leaf n/menu]
   :toast          [:leaf n/toast          :text]
   :image          [:leaf n/image]
   :avatar         [:leaf n/avatar         :label]
   :stepper        [:leaf n/stepper]
   :gauge          [:leaf n/gauge]
   :sparkline      [:leaf n/sparkline]
   :bar-chart      [:leaf n/bar-chart]})

;; ---- rich text ------------------------------------------------------------

(def ^:private span-styles
  {:b {:bold true} :strong {:bold true} :i {:italic true} :em {:italic true}
   :u {:underline true} :s {:strike true} :code {:bg :elevated} :span {} :link {}})

(defn- emit-spans! [nodes style]
  (doseq [node nodes]
    (cond
      (nil? node) nil
      (string? node) (do (set-props! (assoc style :text node)) (n/span))
      (sequential? node)
      (if (keyword? (first node))
        (let [[tag & more] node
              [p ks] (if (map? (first more)) [(first more) (rest more)] [{} more])
              base (or (span-styles tag)
                       (throw (ex-info (str "unknown rich-text tag " tag)
                                       {:tag tag :known (sort (keys span-styles))})))
              st (cond-> (merge style base (dissoc p :href))
                   (:href p) (assoc :link (:href p)))]
          (emit-spans! ks st))
        (emit-spans! node style))
      :else (emit-spans! [(str node)] style))))

;; ---- canvas -----------------------------------------------------------------

(def ^:private cv-ops {:rect 0 :rect-outline 1 :line 2 :circle 3 :ring 4 :arc 5
                       :bezier 6 :polyline 7 :polygon 8})

(defn- cv! [op nums opts]
  (let [[r g b a] (color->rgba (:color opts :fg))
        [a0 a1 a2 a3 a4 a5 a6 a7 a8] (map double (take 9 (concat nums (repeat 0))))]
    (n/cv (cv-ops op) a0 a1 a2 a3 a4 a5 a6 a7 a8 r g b a)))

(defn- draw-cmd! [[op & args :as cmd]]
  (let [[args opts] (if (map? (last args)) [(butlast args) (last args)] [args {}])
        w (:width opts 1)]
    (case op
      :rect         (let [[x y wd h] args] (cv! op [x y wd h (:radius opts 0)] opts))
      :rect-outline (let [[x y wd h] args] (cv! op [x y wd h w (:radius opts 0)] opts))
      :line         (let [[x1 y1 x2 y2] args] (cv! op [x1 y1 x2 y2 w] opts))
      :circle       (let [[cx cy r] args] (cv! op [cx cy r] opts))
      :ring         (let [[cx cy r] args] (cv! op [cx cy r w] opts))
      :arc          (let [[cx cy r a0 a1] args] (cv! op [cx cy r a0 a1 w] opts))
      :bezier       (cv! op (concat (apply concat args) [w]) opts)
      (:polyline :polygon)
      (let [[pts] args]
        (doseq [[x y] pts] (n/cv-point (double x) (double y)))
        (cv! op [w] opts))
      :text (let [[x y s] args
                  [r g b a] (color->rgba (:color opts :fg))]
              (n/cv-text (double x) (double y) (double (:size opts 14)) (str s) r g b a))
      (throw (ex-info (str "unknown canvas command " op)
                      {:command cmd :known (sort (conj (keys cv-ops) :text))})))))

(defn- emit-element [tag props kids]
  (case tag
    (:<> :fragment) (emit-kids kids)

    ;; [:menu-bar [:menu "File" [:menu-item {:on-click :new :shortcut "Ctrl+N"} "New"]
    ;;                          [:menu-separator] …] …]
    :menu-bar
    (do (doseq [[mtag & mmore :as m] (remove nil? kids)]
          (when-not (= :menu mtag)
            (throw (ex-info "[:menu-bar] children must be [:menu \"Label\" & items]" {:child m})))
          (let [[label & items] mmore]
            (set-prop! :label (str label))
            (n/menu-entry)
            (doseq [it (remove nil? (mapcat #(if (seq? %) % [%]) items))]
              (let [[itag & imore] it
                    [iprops ikids] (if (map? (first imore)) [(first imore) (rest imore)] [{} imore])]
                (case itag
                  :menu-separator (n/menu-separator)
                  :menu-item (do (set-props! (assoc iprops :label (text-of ikids)))
                                 (n/menu-item))
                  (throw (ex-info "menu items are [:menu-item props label] or [:menu-separator]" {:item it})))))))
        (set-props! props)
        (n/menu-bar))

;; [:virtual-list {:count 100000 :row-height 28 :size [400 300]
    ;;                 :row (fn [i] hiccup) :key (fn [i] id)}]
    :virtual-list
    (let [h (list-handle! {:row (:row props) :key (:key props) :table? false})]
      (set-props! (-> props (dissoc :row :key :selected? :variable-height)
                      (assoc :handle h :has-key (some? (:key props)))))
      ;; :variable-height true — rows measure themselves (no :row-height)
      (if (:variable-height props) (n/virtual-list-variable) (n/virtual-list)))

    ;; [:table {:columns [{:label "Name" :width 200 :sortable true :resizable true} …]
    ;;          :count n :row (fn [i] [cell cell …]) :key (fn [i] id)
    ;;          :selected? (fn [i] bool) :sort-column 0 :ascending true
    ;;          :on-row-click [:select] :on-row-activate [:open] :on-sort [:sort] …}]
    ;; :on-row-select [:select] instead of :on-row-click delivers
    ;; {:row i :mods #{:shift :ctrl :alt :super}} for multi-select — see
    ;; `select-rows`.
    :table
    (let [h (list-handle! {:row (:row props) :key (:key props)
                           :selected? (:selected? props) :table? true})]
      (doseq [c (:columns props)]
        (set-props! (-> (select-keys c [:label :width :weight :align :sortable :resizable])
                        (update :label str)))
        (n/table-column))
      (set-props! (-> props (dissoc :row :key :selected? :columns
                                    :on-row-click :on-row-activate :on-row-context)
                      (assoc :handle h :has-key (some? (:key props))
                             :on-click (:on-row-click props)
                             :on-activate (:on-row-activate props)
                             :on-context (:on-row-context props))))
      (n/table))

;; [:rich-text {:size 15 :max-width 400 :on-link [:open]}
    ;;  "plain " [:b "bold"] [:i "italic"] [:code "x"] [:link {:href "url"} "here"]
    ;;  [:span {:color :primary :underline true} "custom"]]  — styles nest
    :rich-text
    (do (emit-spans! kids {})
        (set-props! props)
        (n/rich-text))

    ;; [:canvas {:size [w h] :draw [[:rect 0 0 10 10 {:color :primary}] …]
    ;;           :on-press [:down] :on-drag [:move] :on-release [:up]}]
    :canvas
    (do (doseq [c (:draw props)] (when c (draw-cmd! c)))
        (set-props! (dissoc props :draw))
        (n/canvas))

    ;; [:drag-source {:payload any-value :kind "card"} child optional-drag-visual]
    :drag-source
    (do (n/begin)
        (emit-kids kids)
        (set-props! (-> props (dissoc :payload)
                        (assoc :handle (payload-id! (:payload props)))
                        (update :kind #(when % (if (keyword? %) (name %) (str %))))))
        (n/drag-source))

    ;; [:grid {:columns [120 0 80] :spacing 8} cells…]  (0 = flex column)
    :grid
    (do (n/begin)
        (emit-kids kids)
        (doseq [w (:columns props)] (n/val (double w)))
        (set-props! (dissoc props :columns))
        (n/grid))

    ;; [:tree {:rows [{:depth 0 :label "src" :expandable true :expanded true} …]
    ;;         :on-toggle [:toggle] :on-select [:select]}]
    :tree
    (do (doseq [r (:rows props)]
          (set-props! (select-keys r [:depth :label :expandable :expanded :selected :icon]))
          (n/tree-row))
        (set-props! props)
        (n/tree))

    :scope
    (let [k (:key props)]
      (cond (integer? k) (n/scope-push k)
            (some? k)    (n/scope-push-str (str k))
            :else (throw (ex-info "[:scope] needs a :key" {:props props})))
      (try (emit-kids kids) (finally (n/scope-pop))))

    (let [[shape builder text-prop] (or (get elements tag)
                                        (throw (ex-info (str "unknown element " tag)
                                                        {:tag tag :known (sort (keys elements))})))]
      (case shape
        :box
        (let [;; [:flex 2 child] — a leading number is the flex weight
              [props kids] (if (and (= tag :flex) (number? (first kids)))
                             [(assoc props :weight (first kids)) (rest kids)]
                             [props kids])]
          (n/begin)
          (emit-kids kids)
          (lists! props) ; after the children, whose own lists come first
          (set-props! props)
          (builder))

        :leaf
        (let [props (cond
                      (empty? kids) props
                      (= text-prop :size) (assoc props :size (first kids)) ; [:spacer 12] / [:spacer :xl]
                      text-prop (assoc props text-prop (text-of kids))
                      :else (throw (ex-info (str tag " takes no children") {:tag tag :children kids})))]
          (lists! props)
          ;; a spacer's :size is a gap, so its tokens read spacing, not fonts
          (when (= tag :spacer) (set-prop! :size (:size props) 0))
          (set-props! (cond-> (if (contains? props :src) (-> props (dissoc :src) (assoc :path (:src props))) props)
                        (and (#{:text-input :search-field :combobox} tag) (nil? (:value props))) (assoc :value "")
                        (and (#{:select :combobox} tag) (keyword? (:value props))) (update :value name)
                        ;; a color picker's value is a color, whatever its format
                        (= tag :color-picker) (-> (dissoc :value) (assoc :color (:value props)))
                        (= tag :spacer) (dissoc :size)))
          (builder))))))

(defn- emit [node]
  (cond
    (nil? node)    nil
    (string? node) (do (n/ps (get (t :prop) :text) node) (n/text))
    (vector? node) (let [[tag & more] node
                         [props kids] (if (map? (first more))
                                        [(first more) (rest more)]
                                        [{} more])]
                     (cond
                       (keyword? tag) (emit-element tag props kids)
                       (fn? tag)      (emit (apply tag more))
                       (var? tag)     (emit (apply @tag more))
                       :else (throw (ex-info "hiccup tag must be a keyword or fn"
                                             {:node node}))))
    (sequential? node) (emit-kids node)
    :else (emit (str node))))

;; ===========================================================================
;; Commands
;; ===========================================================================

(defrecord Effects [state cmds])

;; ===========================================================================
;; Table multi-select
;; ===========================================================================

(defn select-rows
  "Next table selection after a `:on-row-select` event `{:row i :mods #{…}}`.
  `sel` is `{:selected #{key …} :anchor key :focus key}` (nil to start);
  `key-of` maps a row index to its stable key, `index-of` a key back to its
  current row index (nil if gone), so the selection survives re-sorting.

    plain click      select only this row
    Ctrl/Cmd click   toggle this row
    Shift click      select the range from the anchor (Ctrl+Shift adds it)

  Returns the new `sel`. Use `:focus` for the table's `:focus-row`."
  [sel {:keys [row mods]} key-of index-of]
  (let [{:keys [selected anchor] :or {selected #{}}} sel
        k       (key-of row)
        toggle? (or (contains? mods :ctrl) (contains? mods :super))
        a       (some-> anchor index-of)]
    (cond
      (and (contains? mods :shift) a)
      {:selected (into (if toggle? selected #{})
                       (map key-of) (range (min a row) (inc (max a row))))
       :anchor anchor :focus k}
      toggle? {:selected ((if (contains? selected k) disj conj) selected k)
               :anchor k :focus k}
      :else   {:selected #{k} :anchor k :focus k})))

(defn fx
  "Return from `update` to set a new state *and* run commands:
     (sk/fx (assoc s :saving true) (sk/after 2 :saved))"
  [state & cmds]
  (->Effects state cmds))

(defn now      "Deliver msg to update on the next pass."   [msg] {::cmd :now :msg msg})
(defn after    "Deliver msg after `seconds`."              [seconds msg] {::cmd :after :seconds seconds :msg msg})
(defn quit     "Close the app."                            [] {::cmd :quit})
(defn set-theme
  "Switch to :dark, :light, :system, or a custom theme map (see `run`)."
  [which] {::cmd :theme :theme which})

(defn open-window
  "Open another window: {:title :size [w h] :on-open msg :on-close msg}.
  :on-open gets the new window's id; the view renders it when
  `*window*` is that id. :on-close fires when it closes."
  [{:keys [title size on-open on-close] :or {title "Skald" size [480 360]}}]
  {::cmd :open-window :title title :size size :on-open on-open :on-close on-close})

(defn close-window "Close a window opened with `open-window`." [id]
  {::cmd :close-window :id id})

(defn- file-dialog [kind {:keys [filters dir on-result]}]
  (when (nil? on-result) (throw (ex-info "file dialogs need :on-result" {})))
  {::cmd :file-dialog :kind kind :filters filters :dir dir :on-result on-result})

(defn open-file
  "Show the OS Open dialog. :on-result gets the chosen path, or nil if the
  user cancelled.
    (sk/open-file {:filters [[\"Images\" \"png;jpg\"]] :dir \"/tmp\" :on-result [:opened]})
  :filters are [name \"ext;ext\"] pairs (\"*\" = any); :dir is where it starts
  (default: home)."
  [opts] (file-dialog 0 opts))

(defn save-file "Like `open-file`, but the OS Save dialog." [opts] (file-dialog 1 opts))

(defn open-folder "Like `open-file`, but picks a folder (no :filters)." [opts] (file-dialog 2 opts))

(def ^:private theme-ids {:dark 0 :light 1 :system 2})

(defn- stage-theme!
  "Stage a custom theme map in the shim; returns the id that selects it.
    {:base :dark                       ; or :light
     :color   {:primary \"#e11d48\" :bg \"#0b1020\" …}   ; any theme color role
     :spacing {:md 12} :radius {:md 10} :font {:size-md 15}}"
  [m]
  (n/theme-begin (get theme-ids (:base m :dark) 0))
  (doseq [[k v] (:color m)]
    (let [[r g b a] (if (keyword? v)
                      (throw (ex-info "theme colors must be hex strings or vectors" {:role k :value v}))
                      (color->rgba v))]
      (when (zero? (n/theme-set-color (name k) r g b a))
        (throw (ex-info (str "unknown theme color " k) {:role k})))))
  (doseq [group [:spacing :radius :font]
          [k v] (get m group)]
    (when (zero? (n/theme-set-num (name group) (name k) (double v)))
      (throw (ex-info (str "unknown theme " (name group) " field " k) {:group group :field k}))))
  3)

(defn- theme-id! [t]
  (if (map? t) (stage-theme! t) (get theme-ids t 0)))

(defn- run-cmd! [c]
  (cond
    (nil? c) nil
    (sequential? c) (doseq [x c] (run-cmd! x))
    :else
    (case (::cmd c)
      :now   (n/cmd-now (persistent-tag! (:msg c)))
      :after (n/cmd-delay (double (:seconds c)) (persistent-tag! (:msg c)))
      :quit  (n/cmd-quit)
      :theme (n/cmd-set-theme (theme-id! (:theme c)))
      :open-window (let [[w h] (:size c)]
                     (n/cmd-open-window (str (:title c)) (int w) (int h)
                                        (if (some? (:on-open c)) (persistent-tag! (:on-open c)) -1)
                                        (if (some? (:on-close c)) (persistent-tag! (:on-close c)) -1)))
      :close-window (n/cmd-close-window (long (:id c)))
      :file-dialog (do (doseq [[nm pat] (:filters c)] (n/dialog-filter (str nm) (str pat)))
                       (n/cmd-file-dialog (:kind c) (str (or (:dir c) ""))
                                          (persistent-tag! (:on-result c))))
      (throw (ex-info "not a command" {:value c})))))

;; ===========================================================================
;; Runtime
;; ===========================================================================

(defonce ^{:doc "The running app's state. Read it anywhere; change it only through update."}
  state (atom nil))

(def ^:private app (atom nil))

(def ^:private stderr
  ;; The process's own stderr. Not the caller's *err*: an app started from a
  ;; REPL would otherwise report into that eval's (possibly closed) stream.
  (try (.getRawRoot (var *err*)) (catch Throwable _ nil)))

(def ^:private last-err (atom nil))

(defn last-error
  "The last exception thrown by the app's view or update (or nil). The app
  keeps running after one; this is how to inspect it from a REPL."
  []
  @last-err)

(defn- report!
  "Record and print an exception. Never throws: it runs inside callbacks
  that Skald's C frame loop is waiting on."
  [where e]
  (reset! last-err e)
  (try
    (binding [*out* (or stderr *err*)]
      (println (str "skald: exception in " where ": " (ex-message e)))
      (when-let [d (ex-data e)] (println "  " (pr-str d)))
      (flush))
    (catch Throwable _ nil)))

(defn- step! [msg]
  (when (:trace? @app)
    (binding [*out* *err*] (println "skald msg:" (pr-str msg))))
  (cond
    ;; internal messages never reach the app's update
    (= msg ::refresh) nil ; delivering any message makes Skald repaint
    (and (vector? msg) (= (first msg) ::swap))
    (let [[_ f args] msg] (reset! state (apply f @state args)))
    (some? msg)
    (let [r ((:update @app) @state msg)]
      (if (instance? Effects r)
        (do (reset! state (:state r))
            (run-cmd! (:cmds r)))
        (reset! state r)))))

(defn- hex2 [x] (let [n (Math/round (* 255.0 (max 0.0 (min 1.0 (double x)))))
                       h (Long/toString n 16)]
                   (if (< n 16) (str "0" h) h)))

(defn- rgba->hex [r g b a]
  (str "#" (hex2 r) (hex2 g) (hex2 b) (when (< a 0.999) (hex2 a))))

(defn- mods-of [bits]
  (into #{} (keep (fn [[k b]] (when (bit-test (long bits) b) k))) (t :modifier)))

(defn- on-update [tag kind i f s v0 v1 v2 v3]
  (try
    (let [tmpl  (if (>= tag 0) (get @frame-msgs tag) (take-persistent! tag))
          value (case (long kind)
                  0 ::none
                  1 (= i 1)
                  2 i
                  3 f
                  4 (if (ffi/null? s) "" (ffi/ptr->string s))
                  5 {:year (long v0) :month (long v1) :day (long v2)}
                  6 {:hour (long v0) :minute (long v1) :second (long v2)}
                  7 (rgba->hex v0 v1 v2 v3)
                  8 {:column (long v0) :ascending (== 1.0 v1)}
                  9 {:column (long v0) :width v1}
                  10 {:x v0 :y v1}
                  11 (get @drag-payloads i)
                  12 (let [p (if (ffi/null? s) "" (ffi/ptr->string s))]
                       (if (= "" p) [] (vec (clojure.string/split p #"\n"))))
                  13 {:row i :mods (mods-of v0)}
                  14 {:key (get (t :key) i) :mods (mods-of v0) :pressed? (== 1.0 v1)}
                  15 (when (zero? i) (ffi/ptr->string s)))]
      (step! (combine tmpl value)))
    (catch Throwable e (report! "update" e))))

(defn- on-list
  "Skald asking for row `i` of list `h`: op 0 emits the row, 1 returns its
  key, 2 whether it is selected. Runs during layout; must never throw."
  [h i op]
  (try
    (let [{:keys [row key selected? table?]} (get @frame-lists h)]
      (case (long op)
        0 (do (try
                (let [r (row i)]
                  (if table? (emit-kids r) (emit r)))
                (catch Throwable e
                  (report! (str "row " i) e)
                  (emit [:text {:color :danger} (str "row error: " (ex-message e))])))
              0)
        1 (let [k (key i)] (if (integer? k) k (long (hash k))))
        2 (if (and selected? (selected? i)) 1 0)))
    (catch Throwable e (report! "list callback" e) 0)))

(def ^:dynamic *window*
  "Inside a view: the Skald window id being rendered." nil)

(def ^:private main-window-id (atom nil))

(defn main-window?
  "Inside a view: is this the app's first (main) window? Other windows are
  the ids delivered to `open-window`'s :on-open."
  []
  (= *window* @main-window-id))

(defn dragging
  "Inside a view: the payload of the drag in progress, or nil."
  []
  (let [id (n/dragging)] (when (>= id 0) (get @drag-payloads id))))

(defn drag-over?
  "Inside a view: is a drag (optionally of `kind`) over the drop target
  with this :id?"
  ([id] (drag-over? id nil))
  ([id kind] (= 1 (n/drag-over (str id) (if kind (name kind) "")))))

(def ^:private frames (atom 0))

(defn- on-view [window reset]
  (swap! frames inc)
  (when (nil? @main-window-id) (reset! main-window-id window))
  (when (= 1 reset) (vreset! frame-msgs []) (vreset! frame-lists []))
  (try
    (binding [*window* window]
      (emit ((:view @app) @state)))
    (catch Throwable e
      (report! "view" e)
      ;; nothing may escape into the C frame loop, not even from the
      ;; fallback screen
      (try
        (n/reset)
        (emit [:col {:padding :xl :spacing :sm}
               [:text {:color :danger :size :lg} "View error"]
               [:text {:color :fg-muted :max-width 600} (str (ex-message e))]
               [:text {:color :fg-muted :size :sm} "Fix the view and it redraws; (sk/last-error) has the exception."]])
        (catch Throwable _ (try (n/reset) (catch Throwable _ nil)))))))

(defn breakpoint
  "Inside a view: the window width band, :compact (<600) :regular or :wide."
  []
  (get [:compact :regular :wide] (n/breakpoint) :regular))

(defn theme-color
  "Inside a view: a theme role (:primary, :fg-muted…) as sRGB [r g b a],
  usable directly as a color value."
  [role]
  (ffi/with-alloc [p 16]
    (n/theme-color* (get (t :color-role) role 0) p)
    (mapv #(ffi/read p :float (* 4 %)) (range 4))))

(defn dispatch!
  "Send msg to update from anywhere — any thread, a future, a core.async go
  block. Wakes the UI if it is idle. Safe before `run` (queued)."
  [msg]
  (n/post (persistent-tag! msg))
  nil)

(defn refresh!
  "Repaint the running app. Skald only repaints when something changes, so
  call this after changing code a view depends on that `run` isn't watching.
  Any thread. Your update never sees it."
  []
  (dispatch! ::refresh))

(defn swap-state!
  "Apply (f state & args) to the running app's state, on the UI thread, and
  repaint — the REPL's way to poke at state. Any thread. Bypasses update, so
  no commands run."
  [f & args]
  (dispatch! [::swap f args]))

(defn running?
  "Is an app window open?"
  []
  (some? @app))

(defn stats
  "Counters for the running (or last) app: {:frames n} views rendered."
  []
  {:frames @frames})

(defn run
  "Open a window and run the app until it closes. Blocks; returns the final
  state.

    :title             window title
    :size              [w h] logical pixels (default [800 600])
    :theme             :dark (default), :light or :system (follows the OS)
    :init              initial state, or a 0-arg fn returning it
    :update            (fn [state msg] -> state | (fx state & cmds))
    :view              (fn [state] -> hiccup)
    :on-close-request  msg sent instead of closing when the window's close
                       button is clicked; update must eventually return (quit)
    :on-key            msg for every key press and release, with
                       {:key :escape :mods #{:ctrl} :pressed? true}; not sent
                       while a text field has focus. Held keys repeat.
    :always-redraw     render every frame (animation-driven apps)
    :trace?            print every message to stderr as it reaches update

  Pass vars (#'view, #'update-state) to redefine them live from a REPL:
  `run` watches every var you pass and repaints when one is redefined.

  Runs on the calling thread and blocks. From an editor's REPL use `start!`.
  On macOS the UI must own the main thread: start an nREPL server from -main
  and call `run` there (see README, \"REPL workflow\")."
  [{:keys [title size theme init on-close-request on-key always-redraw trace?]
    update-fn :update, view-fn :view                 ; don't shadow core/update
    :or   {title "Skald" size [800 600] theme :dark}}]
  (when-not (and update-fn view-fn)
    (throw (ex-info "run needs :update and :view" {})))
  @tables ; fail fast on a missing/mismatched library
  (when-not (compare-and-set! app nil {:update update-fn :view view-fn :trace? trace?})
    (throw (ex-info "a Skald app is already running in this process" {})))
  (reset! frames 0)
  (reset! main-window-id nil)
  (reset! state (if (fn? init) (init) init))
  (vreset! frame-msgs [])
  (let [[w h]     size
        close-tag (if (some? on-close-request) (persistent-tag! on-close-request true) -1)
        key-tag   (if (some? on-key) (persistent-tag! on-key true) -1)
        upd-cb    (ffi/foreign-callable on-update
                                        [:int64 :int :int64 :double :pointer :double :double :double :double]
                                        :void :collect-safe)
        view-cb   (ffi/foreign-callable on-view [:int64 :int] :void :collect-safe)
        list-cb   (ffi/foreign-callable on-list [:int64 :int64 :int] :int64 :collect-safe)
        watched   (filter var? [update-fn view-fn])]
    ;; redefining a watched var from the REPL repaints at once
    (doseq [v watched] (add-watch v ::live (fn [& _] (refresh!))))
    (try
      (n/on-key key-tag)
      (ffi/with-c-string [title-ptr (str title)]
        (n/run title-ptr (int w) (int h) (theme-id! theme)
               upd-cb view-cb list-cb close-tag (if always-redraw 1 0)))
      (finally
        (doseq [v watched] (remove-watch v ::live))
        (reset! app nil)
        (ffi/free-callable upd-cb)
        (ffi/free-callable view-cb)
        (ffi/free-callable list-cb)
        (swap! persistent (fn [p] (-> p (update :msgs dissoc close-tag key-tag)
                                        (update :sticky disj close-tag key-tag))))))
    @state))

(defn start!
  "Run the app on its own thread and return at once: the REPL workflow on
  Linux and Windows. Returns a promise of the final state (deref it, with a
  timeout if you like, to wait for the window to close).

  The UI thread is a plain Thread, deliberately not a future: a future
  would inherit the dynamic bindings of the REPL eval that started it
  (its output streams, nREPL session state), which outlive that eval.

  Not on macOS, where the UI must own the main thread (see README)."
  [opts]
  (when (running?) (throw (ex-info "a Skald app is already running in this process" {})))
  (let [result (promise)
        t      (Thread. (fn []
                          (deliver result
                                   (try (run opts)
                                        (catch Throwable e (report! "start!" e) nil)))))]
    (.start t)
    ;; return once the app is up (or failed), so (running?) is meaningful
    (loop [i 0]
      (when (and (< i 400) (not (running?)) (not (realized? result)))
        (Thread/sleep 25)
        (recur (inc i))))
    result))
