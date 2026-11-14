;; Fast, windowless checks of skald.core: hiccup -> shim calls, colors,
;; tokens, messages, commands. Needs the shim built (`jolt native`) for its
;; enum tables, but never opens a window or touches the GPU.
;;   cd examples && jolt run ../test/core_test.clj
(require '[skald.core :as sk] '[skald.native :as n])

;; ---------------------------------------------------------------------------
;; Recording shim: every n/* fn that would need a running frame logs
;; [name & args] instead. The enum introspection fns stay real.
;; ---------------------------------------------------------------------------

(def calls (atom []))
(def real #{'abi-version 'enum-count 'enum-name 'prop-kind})
(def fakes
  (into {} (for [[sym v] (ns-publics 'skald.native) :when (not (real sym))]
             [v (fn [& args] (swap! calls conj (into [(keyword sym)] args)) 0)])))

(def tables @@#'skald.core/tables)
(defn prop [k] (get (:prop tables) k))
(defn token [k] (get (:token tables) k))
(defn role [k] (get (:color-role tables) k))

(defn with-fakes* [f]
  (let [old-elements @#'skald.core/elements]
    (reset! calls [])
    (vreset! @#'skald.core/frame-msgs [])
    (vreset! @#'skald.core/frame-lists [])
    ;; `elements` holds the builder fns themselves, captured at load time
    (with-redefs-fn (assoc fakes #'skald.core/elements
                           (update-vals old-elements
                                        (fn [[shape b & more]]
                                          (into [shape (some (fn [[v fake]] (when (= @v b) fake)) fakes)] more))))
      f)))

(defn emit
  "Shim calls made by emitting `node`."
  [node]
  (with-fakes* #(#'skald.core/emit node))
  @calls)

(defn builders [cs] (filterv #(#{:begin :col :row :text :button :spacer :flex :scope-push :scope-push-str :scope-pop} (first %)) cs))

(def fails (atom 0))
(defmacro check [desc expr]
  `(let [ok# (try ~expr (catch Throwable e# (println "  threw:" (ex-message e#)) false))]
     (if ok# (println "ok  " ~desc) (do (swap! fails inc) (println "FAIL" ~desc)))))
(defmacro throws? [expr re]
  `(try ~expr false (catch Throwable e# (boolean (re-find ~re (str (ex-message e#)))))))
(defn approx= [a b] (< (abs (- (double a) (double b))) 1e-9))
(defn approx-all= [xs ys] (and (= (count xs) (count ys)) (every? true? (map approx= xs ys))))

;; ---------------------------------------------------------------------------
;; Tree walking
;; ---------------------------------------------------------------------------

(check "box: begin, children, then the builder"
  (= (builders (emit [:col [:text "a"] [:row [:text "b"]]]))
     [[:begin] [:text] [:begin] [:text] [:row] [:col]]))

(check "plain string is a text leaf"
  (= (emit "hi") [[:ps (prop :text) "hi"] [:text]]))

(check "nil renders nothing; seqs and for splice in"
  (= (builders (emit [:col nil (for [s ["a" "b"]] [:text s]) (when false [:text "x"]) (list [:text "c"])]))
     [[:begin] [:text] [:text] [:text] [:col]]))

(check ":<> groups children without a container"
  (= (builders (emit [:<> [:text "a"] [:text "b"]])) [[:text] [:text]]))

(defn item [label] [:text {:color :primary} label])
(check "fn in tag position is a component"
  (= (emit [item "x"]) (emit [:text {:color :primary} "x"])))
(check "var in tag position is a component"
  (= (emit [#'item "x"]) (emit [:text {:color :primary} "x"])))

(check "numbers and other values render as their string"
  (some #{[:ps (prop :text) "42"]} (emit [:col 42])))

(check "leaf text children join into the text prop"
  (some #{[:ps (prop :label) "Save 3 files"]} (emit [:button "Save " 3 " files"])))

(check "[:spacer :xl] reads the spacing scale"
  (some #{[:pf-token (prop :size) 0 (token :xl)]} (emit [:spacer :xl])))

(check "[:spacer {:size :xl}] reads spacing too; numbers pass through"
  (and (some #{[:pf-token (prop :size) 0 (token :xl)]} (emit [:spacer {:size :xl}]))
       (some #{[:pf (prop :size) 12.0]} (emit [:spacer 12]))))
(check "[:text {:size :xl}] still reads the font scale"
  (some #{[:pf-token (prop :size) 2 (token :xl)]} (emit [:text {:size :xl} "x"])))

(check "[:flex 2 child] takes a leading weight"
  (let [cs (emit [:flex 2 [:text "a"]])]
    (and (some #{[:pf (prop :weight) 2.0]} cs)
         (= (builders cs) [[:begin] [:text] [:flex]]))))

(check ":scope with int key pushes and pops"
  (= (builders (emit [:scope {:key 7} [:text "a"]])) [[:scope-push 7] [:text] [:scope-pop]]))
(check ":scope with other key pushes a string"
  (= (first (builders (emit [:scope {:key :row-1} "a"]))) [:scope-push-str ":row-1"]))
(check ":scope pops even when a child throws"
  (do (try (emit [:scope {:key 1} [:nope]]) (catch Throwable _))
      (= (last (builders @calls)) [:scope-pop])))
(check ":scope without :key throws"
  (throws? (emit [:scope "a"]) #"needs a :key"))

(check "unknown element throws and names it"
  (throws? (emit [:nope]) #"unknown element :nope"))
(check "children on a childless leaf throw"
  (throws? (emit [:slider "x"]) #"takes no children"))
(check "non-keyword, non-fn tag throws"
  (throws? (emit ["col"]) #"hiccup tag"))

;; ---------------------------------------------------------------------------
;; Sizes and colors
;; ---------------------------------------------------------------------------

(check "size tokens pick the scale from the prop"
  (let [cs (emit [:col {:padding :xl :radius :md} [:text {:size :display} "x"]])]
    (and (some #{[:pf-token (prop :padding) 0 (token :xl)]} cs)
         (some #{[:pf-token (prop :radius) 1 (token :md)]} cs)
         (some #{[:pf-token (prop :size) 2 (token :display)]} cs))))
(check "numbers pass through as doubles"
  (some #{[:pf (prop :padding) 12.0]} (emit [:col {:padding 12}])))
(check ":size [w h] splits into width and height"
  (let [cs (emit [:rect {:size [10 20]}])]
    (and (some #{[:pf (prop :width) 10.0]} cs) (some #{[:pf (prop :height) 20.0]} cs))))
(check "unknown size token throws"
  (throws? (emit [:col {:padding :huge}]) #"unknown size token :huge"))

(defn color-call [c] (first (filter #(#{:pc :pc-role} (first %)) (emit [:rect {:bg c}]))))
(check "theme role -> pc-role"
  (= (color-call :primary) [:pc-role (prop :bg) (role :primary)]))
(check "6-digit hex is sRGB 0..1, alpha 1"
  (let [[_ _ & rgba] (color-call "#3b82f6")] (approx-all= rgba [(/ 59 255.0) (/ 130 255.0) (/ 246 255.0) 1.0])))
(check "8-digit hex carries alpha"
  (approx= (last (color-call "#3b82f680")) (/ 128 255.0)))
(check "3-digit hex expands"
  (approx-all= (drop 2 (color-call "#fff")) [1.0 1.0 1.0 1.0]))
(check "0-255 vector scales; 0-1 vector passes through"
  (and (approx-all= (drop 2 (color-call [255 0 51])) [1.0 0.0 0.2 1.0])
       (approx-all= (drop 2 (color-call [0.2 0.5 0.9 0.5])) [0.2 0.5 0.9 0.5])))
(check "bad hex throws" (throws? (color-call "#12345") #"bad color"))
(check "unknown role throws" (throws? (color-call :sparkly) #"unknown theme color"))
(check "rgba with any channel > 1 treats all as 0-255"
  (approx-all= (sk/rgba 255 128 0) [1.0 (/ 128 255.0) 0.0 1.0]))
(check "rgba->hex round-trips hex"
  (= "#3b82f680" (apply #'skald.core/rgba->hex (#'skald.core/hex->rgba "#3b82f680"))))
(check "rgba->hex drops opaque alpha"
  (= "#ff0000" (#'skald.core/rgba->hex 1.0 0.0 0.0 1.0)))

;; ---------------------------------------------------------------------------
;; Widget-specific props
;; ---------------------------------------------------------------------------

(check "text-input with no :value sends empty string"
  (some #{[:ps (prop :value) ""]} (emit [:text-input {}])))
(check "select :value keyword is sent by name"
  (some #{[:ps (prop :value) "b"]} (emit [:select {:value :b :options [:a :b]}])))
(check "options go out as opt calls, in order"
  (= (filterv #(= :opt (first %)) (emit [:select {:options [:a "B" 3]}]))
     [[:opt "a"] [:opt "B"] [:opt "3"]]))
(check ":src becomes :path on image"
  (some #{[:ps (prop :path) "x.png"]} (emit [:image {:src "x.png"}])))
(check "date map goes out as a vector prop"
  (some #(= (first %) :pv) (emit [:date-picker {:value {:year 2026 :month 11 :day 14}}])))
(check "booleans are 0/1 ints"
  (some #{[:pi (prop :checked) 1]} (emit [:checkbox {:checked true} "x"])))
(check "enum props map keywords to ints"
  (some #{[:pi (prop :main-align) (get (:main-align tables) :center)]} (emit [:col {:main-align :center}])))
(check "bad enum value throws"
  (throws? (emit [:col {:main-align :sideways}]) #"bad value :sideways"))

(check "rich text: nested styles merge, href becomes link"
  (let [spans (->> (emit [:rich-text "a " [:b "bold " [:i "both"]] [:link {:href "u"} "l"]])
                   (partition-by #(= :span (first %)))
                   (partition 2)
                   (map (fn [[props _]] (into {} (map (fn [[_ k v]] [k v])) props))))]
    (and (= 4 (count spans))
         (= (get (nth spans 2) (prop :bold)) 1) (= (get (nth spans 2) (prop :italic)) 1)
         (= (get (nth spans 3) (prop :link)) "u"))))
(check "unknown rich-text tag throws"
  (throws? (emit [:rich-text [:blink "x"]]) #"unknown rich-text tag"))

(check "canvas rect: op 0, padded to 9 numbers, radius from opts"
  (let [cv (first (filter #(= :cv (first %)) (emit [:canvas {:draw [[:rect 1 2 3 4 {:radius 5 :color "#ff0000"}]]}])))]
    (and (= (nth cv 1) 0) (approx-all= (subvec cv 2 11) [1 2 3 4 5 0 0 0 0])
         (approx-all= (subvec cv 11) [1.0 0.0 0.0 1.0]))))
(check "canvas polyline sends its points first"
  (= (filterv #(= :cv-point (first %)) (emit [:canvas {:draw [[:polyline [[0 0] [1 2]]]]}]))
     [[:cv-point 0.0 0.0] [:cv-point 1.0 2.0]]))
(check "unknown canvas command throws"
  (throws? (emit [:canvas {:draw [[:blob 1]]}]) #"unknown canvas command"))

(check "menu-bar: entries, items, separators"
  (= (mapv first (filter #(#{:menu-entry :menu-item :menu-separator :menu-bar} (first %))
                         (emit [:menu-bar [:menu "File" [:menu-item {:on-click :new} "New"] [:menu-separator]]])))
     [:menu-entry :menu-item :menu-separator :menu-bar]))
(check "menu-bar rejects non-menu children"
  (throws? (emit [:menu-bar [:text "x"]]) #"children must be"))

;; ---------------------------------------------------------------------------
;; Messages: view -> tag -> on-update -> update
;; ---------------------------------------------------------------------------

(def combine #'skald.core/combine)
(check "combine: fn applies"           (= (combine inc 1) 2))
(check "combine: vector conjs"         (= (combine [:set :name] "Ada") [:set :name "Ada"]))
(check "combine: other pairs"          (= (combine :set-name "Ada") [:set-name "Ada"]))
(check "combine: no value -> as given" (= (combine :inc ::sk/none) :inc))
(check "combine: no value, fn -> called" (= (combine (fn [] :x) :skald.core/none) :x))
(check "combine: nil msg -> nil"       (nil? (combine nil 1)))

(defn run-update
  "Emit `view`, then deliver a widget event the way the shim would."
  [view init update-fn kind & [i f v0]]
  (reset! sk/state init)
  (reset! @#'skald.core/app {:update update-fn :view (constantly view)})
  (with-fakes*
    (fn []
      (#'skald.core/emit view)
      (let [tag (some (fn [[op k v]] (when (and (= op :pi) (#{(prop :on-click) (prop :on-change)} k)) v)) @calls)]
        (#'skald.core/on-update tag kind (or i 0) (or f 0.0) nil (or v0 0.0) 0.0 0.0 0.0))))
  (reset! @#'skald.core/app nil)
  @sk/state)

(defn counter [s msg] (case msg :inc (update s :n inc) s))
(check "button click reaches update"
  (= {:n 1} (run-update [:button {:on-click :inc} "+"] {:n 0} counter 0)))
(check "checkbox bool is combined with the message"
  (= {:on true} (run-update [:checkbox {:on-change [:set :on]} "x"] {}
                            (fn [s [_ k v]] (assoc s k v)) 1 1)))
(check "slider float reaches a fn message"
  (= {:v 0.25} (run-update [:slider {:on-change #(vector :v %)}] {}
                           (fn [s [k v]] (assoc s k v)) 3 0 0.25)))
(check "throwing update is reported, state kept"
  (let [s (binding [*err* (java.io.StringWriter.)]
            (run-update [:button {:on-click :boom} "x"] {:n 5} (fn [_ _] (throw (ex-info "boom" {}))) 0))]
    (and (= s {:n 5}) (= "boom" (ex-message (sk/last-error))))))

;; ---------------------------------------------------------------------------
;; Commands from update
;; ---------------------------------------------------------------------------

(defn cmds-of [r]
  (reset! sk/state {})
  (reset! @#'skald.core/app {:update (constantly r)})
  (with-fakes* #(#'skald.core/step! :go))
  (reset! @#'skald.core/app nil)
  @calls)

(check "plain return sets state, runs nothing"
  (and (= [] (cmds-of {:a 1})) (= {:a 1} @sk/state)))
(check "fx sets state and runs commands in order"
  (let [cs (cmds-of (sk/fx {:a 2} (sk/now :x) (sk/after 1.5 :y) (sk/quit)))]
    (and (= {:a 2} @sk/state)
         (= (mapv first cs) [:cmd-now :cmd-delay :cmd-quit])
         (= 1.5 (second (second cs))))))
(check "command tags are persistent and delivered once"
  (let [tag (second (first (cmds-of (sk/fx {} (sk/now :hello)))))]
    (and (neg? tag)
         (= :hello (#'skald.core/take-persistent! tag))
         (nil? (#'skald.core/take-persistent! tag)))))
(check "nested command seqs flatten; nil skipped"
  (= [:cmd-quit :cmd-quit] (mapv first (cmds-of (sk/fx {} [nil (sk/quit)] (list (sk/quit)))))))
(check "set-theme :light -> id 1"
  (= [[:cmd-set-theme 1]] (cmds-of (sk/fx {} (sk/set-theme :light)))))
(check "file dialog sends filters before the dialog"
  (= (mapv first (cmds-of (sk/fx {} (sk/open-file {:filters [["Img" "png"]] :on-result [:opened]}))))
     [:dialog-filter :cmd-file-dialog]))
(check "file dialog without :on-result throws"
  (throws? (sk/open-file {}) #"need :on-result"))
(check "non-command in fx throws"
  (throws? (with-fakes* #(#'skald.core/run-cmd! {:not :a-cmd})) #"not a command"))

(println)
(if (zero? @fails)
  (println "core_test: all checks passed")
  (do (println "core_test:" @fails "FAILED") (System/exit 1)))
