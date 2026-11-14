(ns examples.dev
  "A development entry point that works on every OS, macOS included: start
  an nREPL server, then run the app on the main thread (where macOS requires
  the UI to be). Connect your editor to the port, edit, re-evaluate.

    jolt run -m examples.dev            # port 7888, writes .nrepl-port

  Copy this into your project as your dev entry; ship -main as usual."
  (:require [jolt.nrepl :as nrepl]
            [skald.core :as sk]
            [examples.counter :as counter]))

(defn -main [& _]
  (let [port (or (some-> (System/getenv "SKALD_NREPL_PORT") parse-long) 7888)
        stop (nrepl/start port)]
    (println (str "nREPL on port " (:port (meta stop)) " — connect your editor"))
    (try
      (let [final (sk/run counter/app)]
        (println :final-state (pr-str final))
        final)
      (finally
        (stop)
        (shutdown-agents)))))
