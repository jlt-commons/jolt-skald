(ns skald.native
  "Raw bindings to libskald_jolt, the C-ABI shim over Skald.

  One `defcfn` per exported `sk_*` symbol, no logic. Application code wants
  `skald.core`; this namespace is for building alternative front-ends.

  Everything here except `post` must be called on the UI thread, from inside
  the update/view callbacks that `run` installs."
  (:require [jolt.ffi :as ffi]))

;; --- introspection --------------------------------------------------------
(ffi/defcfn abi-version  "sk_abi_version" [] :int)
(ffi/defcfn enum-count   "sk_enum_count"  [:int] :int)
(ffi/defcfn enum-name    "sk_enum_name"   [:int :int] :string)
(ffi/defcfn prop-kind    "sk_prop_kind"   [:int] :int)

;; --- property register ----------------------------------------------------
(ffi/defcfn pf           "sk_pf"          [:int :double] :void)
(ffi/defcfn pi           "sk_pi"          [:int :int64] :void)
(ffi/defcfn pc           "sk_pc"          [:int :double :double :double :double] :void) ; sRGB
(ffi/defcfn pc-linear    "sk_pc_linear"   [:int :double :double :double :double] :void)
(ffi/defcfn ps           "sk_ps"          [:int :string] :void)
(ffi/defcfn pc-role      "sk_pc_role"     [:int :int] :void)
(ffi/defcfn pf-token     "sk_pf_token"    [:int :int :int] :void)
(ffi/defcfn pid-str      "sk_pid_str"     [:string] :void)
(ffi/defcfn opt          "sk_opt"         [:string] :void)
(ffi/defcfn pv           "sk_pv"          [:int :double :double :double :double] :void) ; dates, times
(ffi/defcfn val          "sk_val"         [:double] :void)  ; one chart value

;; --- frame queries --------------------------------------------------------
(ffi/defcfn theme-color* "sk_theme_color" [:int :pointer] :void)
(ffi/defcfn breakpoint   "sk_breakpoint"  [] :int)

;; --- structure ------------------------------------------------------------
(ffi/defcfn begin          "sk_begin"          [] :void)
(ffi/defcfn reset          "sk_reset"          [] :void)
(ffi/defcfn scope-push     "sk_scope_push"     [:int64] :void)
(ffi/defcfn scope-push-str "sk_scope_push_str" [:string] :void)
(ffi/defcfn scope-pop      "sk_scope_pop"      [] :void)

;; --- builders (consume the property register) -----------------------------
(ffi/defcfn col            "sk_col"            [] :void)
(ffi/defcfn row            "sk_row"            [] :void)
(ffi/defcfn wrap-row       "sk_wrap_row"       [] :void)
(ffi/defcfn flex           "sk_flex"           [] :void)
(ffi/defcfn clip           "sk_clip"           [] :void)
(ffi/defcfn opacity        "sk_opacity"        [] :void)
(ffi/defcfn spacer         "sk_spacer"         [] :void)
(ffi/defcfn rect           "sk_rect"           [] :void)
(ffi/defcfn text           "sk_text"           [] :void)
(ffi/defcfn divider        "sk_divider"        [] :void)
(ffi/defcfn button         "sk_button"         [] :void)
(ffi/defcfn link           "sk_link"           [] :void)
(ffi/defcfn text-input     "sk_text_input"     [] :void)
(ffi/defcfn checkbox       "sk_checkbox"       [] :void)
(ffi/defcfn toggle         "sk_toggle"         [] :void)
(ffi/defcfn radio          "sk_radio"          [] :void)
(ffi/defcfn slider         "sk_slider"         [] :void)
(ffi/defcfn number-input   "sk_number_input"   [] :void)
(ffi/defcfn select         "sk_select"         [] :void)
(ffi/defcfn segmented      "sk_segmented"      [] :void)
(ffi/defcfn tabs           "sk_tabs"           [] :void)
(ffi/defcfn progress       "sk_progress"       [] :void)
(ffi/defcfn spinner        "sk_spinner"        [] :void)
(ffi/defcfn badge          "sk_badge"          [] :void)
(ffi/defcfn alert          "sk_alert"          [] :void)
(ffi/defcfn kbd            "sk_kbd"            [] :void)
(ffi/defcfn section-header "sk_section_header" [] :void)
(ffi/defcfn empty-state    "sk_empty_state"    [] :void)
(ffi/defcfn scroll         "sk_scroll"         [] :void)
(ffi/defcfn tooltip        "sk_tooltip"        [] :void)
(ffi/defcfn collapsible    "sk_collapsible"    [] :void)
(ffi/defcfn dialog         "sk_dialog"         [] :void)
(ffi/defcfn combobox       "sk_combobox"       [] :void)
(ffi/defcfn date-picker    "sk_date_picker"    [] :void)
(ffi/defcfn time-picker    "sk_time_picker"    [] :void)
(ffi/defcfn color-picker   "sk_color_picker"   [] :void)
(ffi/defcfn rating         "sk_rating"         [] :void)
(ffi/defcfn radio-group    "sk_radio_group"    [] :void)
(ffi/defcfn search-field   "sk_search_field"   [] :void)
(ffi/defcfn chip           "sk_chip"           [] :void)
(ffi/defcfn breadcrumb     "sk_breadcrumb"     [] :void)
(ffi/defcfn menu-entry     "sk_menu_entry"     [] :void)
(ffi/defcfn menu-item      "sk_menu_item"      [] :void)
(ffi/defcfn menu-separator "sk_menu_separator" [] :void)
(ffi/defcfn menu-bar       "sk_menu_bar"       [] :void)
(ffi/defcfn menu           "sk_menu"           [] :void)
(ffi/defcfn context-menu   "sk_context_menu"   [] :void)
(ffi/defcfn tree-row       "sk_tree_row"       [] :void)
(ffi/defcfn tree           "sk_tree"           [] :void)
(ffi/defcfn accordion      "sk_accordion"      [] :void)
(ffi/defcfn toast          "sk_toast"          [] :void)
(ffi/defcfn image          "sk_image"          [] :void)
(ffi/defcfn avatar         "sk_avatar"         [] :void)
(ffi/defcfn stepper        "sk_stepper"        [] :void)
(ffi/defcfn gauge          "sk_gauge"          [] :void)
(ffi/defcfn sparkline      "sk_sparkline"      [] :void)
(ffi/defcfn bar-chart      "sk_bar_chart"      [] :void)
(ffi/defcfn virtual-list   "sk_virtual_list"   [] :void)
(ffi/defcfn table-column   "sk_table_column"   [] :void)
(ffi/defcfn table          "sk_table"          [] :void)
(ffi/defcfn span           "sk_span"           [] :void)
(ffi/defcfn rich-text      "sk_rich_text"      [] :void)
(ffi/defcfn cv-point       "sk_cv_point"       [:double :double] :void)
(ffi/defcfn cv             "sk_cv"             [:int :double :double :double :double :double :double :double :double :double
                                                :double :double :double :double] :void)
(ffi/defcfn cv-text        "sk_cv_text"        [:double :double :double :string :double :double :double :double] :void)
(ffi/defcfn canvas         "sk_canvas"         [] :void)
(ffi/defcfn drag-source    "sk_drag_source"    [] :void)
(ffi/defcfn drop-target    "sk_drop_target"    [] :void)
(ffi/defcfn drop-zone      "sk_drop_zone"      [] :void)
(ffi/defcfn dragging       "sk_dragging"       [] :int64)
(ffi/defcfn drag-over      "sk_drag_over"      [:string :string] :int)
(ffi/defcfn split          "sk_split"          [] :void)
(ffi/defcfn shortcut       "sk_shortcut"       [] :void)
(ffi/defcfn grid           "sk_grid"           [] :void)
(ffi/defcfn virtual-list-variable "sk_virtual_list_variable" [] :void)
(ffi/defcfn theme-begin    "sk_theme_begin"    [:int] :void)
(ffi/defcfn theme-set-color "sk_theme_set_color" [:string :double :double :double :double] :int)
(ffi/defcfn theme-set-num  "sk_theme_set_num"  [:string :string :double] :int)

;; --- commands (inside update only) ----------------------------------------
(ffi/defcfn cmd-now        "sk_cmd_now"        [:int64] :void)
(ffi/defcfn cmd-delay      "sk_cmd_delay"      [:double :int64] :void)
(ffi/defcfn cmd-quit       "sk_cmd_quit"       [] :void)
(ffi/defcfn cmd-set-theme  "sk_cmd_set_theme"  [:int] :void)
(ffi/defcfn cmd-open-window  "sk_cmd_open_window"  [:string :int :int :int64 :int64] :void)
(ffi/defcfn cmd-close-window "sk_cmd_close_window" [:int64] :void)
(ffi/defcfn dialog-filter  "sk_dialog_filter"  [:string :string] :void)
(ffi/defcfn cmd-file-dialog "sk_cmd_file_dialog" [:int :string :int64] :void)

;; --- any thread -----------------------------------------------------------
(ffi/defcfn post           "sk_post"           [:int64] :void)

;; --- before run -------------------------------------------------------------
(ffi/defcfn on-key         "sk_on_key"         [:int64] :void)

;; --- run loop -------------------------------------------------------------
;; :blocking — the call parks in Skald's event loop for the app's lifetime,
;; so it must not pin the collector for other Jolt threads. The callbacks
;; handed to it are therefore built :collect-safe (see skald.core/run).
;; The title is a :pointer, not :string: a blocking call may not take a
;; GC-managed string (the collector could move it while C reads it).
;; args: title, w, h, theme, update-cb, view-cb, list-cb, close-tag, flags
(ffi/defcfn run "sk_run"
  [:pointer :int :int :int :pointer :pointer :pointer :int64 :int] :int :blocking)
