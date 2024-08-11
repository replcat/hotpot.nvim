(import-macros {: expect : dprint} :hotpot.macros)

(local M {})
(local fmt string.format)
(local LOCAL_CONFIG_FILE ".hotpot.lua")

(fn lazy-traceback []
  ;; loading the traceback is potentially heavy if it has to require fennel, so
  ;; we don't get it until we need it.
  ;; TODO: deprecated
  (let [{: traceback} (require :hotpot.traceback)]
    (values traceback)))

(fn lookup-local-config [file]
  ;; When requiring modules, we can often know where we expect the .hotpot.lua to be
  ;; and so we can skip the recursive upsearch by checking the path directly.
  (let [{: file-exists?} (require :hotpot.fs)]
    (if (string.match file "%.hotpot%.lua$")
      (if (file-exists? file) (vim.fs.normalize file))
      (case (vim.fs.find LOCAL_CONFIG_FILE {:path file :upward true :kind :file})
        [path] (-> path
                   ;; Note that fs_realpath will convert a normalised path
                   ;; *back* to "windows style", so it must be called first.
                   (vim.loop.fs_realpath)
                   (vim.fs.normalize))
        [nil] nil))))

(fn loadfile-local-config [path]
  ;; Unify error return shape for loadfile and running the config
  (case-try
    (loadfile path) loader ;; loader | nil err
    (pcall loader) (true config) ;; true config | false err
    (vim.tbl_deep_extend :keep config {:context path} (M.default-config))
    (catch
      (false e) (values nil e)
      (nil e) (values nil e))))

(local windows?
  (not= nil (-> (vim.loop.os_uname)
                (. :sysname)
                (string.lower)
                (string.find :windows))))
(fn M.windows? [] windows?)

;; For windows compatiblity, we must call uv.fs_realpath on stdpath(:cache) to
;; convert short-name (users/RUNNER~1) paths to long-names (users/runneradmin).
;; uv.fs_realpath returns nil if the path does not exist, so we have to ensure
;; the cache "root" exists (eg temp/nvim) immediately before we ever try
;; constructing what will be our path strings inside the neovim cache dir.
(when (not (vim.loop.fs_realpath (vim.fn.stdpath :cache)))
  (vim.fn.mkdir (vim.fn.stdpath :cache) :p))
(local NVIM_CACHE_DIR (-> (vim.fn.stdpath :cache)
                          ;; this must be ordered fs_realpath -> normalize
                          (vim.loop.fs_realpath) ;; windows RUNNER~1 -> runneradmin
                          (vim.fs.normalize))) ;; windows \\ -> /
(fn M.cache-root-path []
  (let [{: join-path} (require :hotpot.fs)]
    (join-path NVIM_CACHE_DIR :hotpot)))

(fn M.default-config []
  "Return a new hotpot configuration table with default options."
  {:compiler {:modules {}
              :macros {:env :_COMPILER}
              :preprocessor (fn [src] src)
              :traceback :hotpot}
   :enable_hotpot_diagnostics true})

(var user-config (M.default-config))
(fn M.user-config [] user-config)

(fn M.set-user-config [given-config]
  (let [new-config (M.default-config)]
    (each [_ k (ipairs [:preprocessor :modules :macros :traceback])]
      (match (?. given-config :compiler k)
        val (tset new-config :compiler k val)))
    (match (?. given-config :enable_hotpot_diagnostics)
      val (tset new-config :enable_hotpot_diagnostics val))
    ;; better to hard fail this now, than fail it when something else fails
    (match new-config.compiler.traceback
        :hotpot true
        :fennel true
        _ (error "invalid config.compiler.traceback value, must be 'hotpot' or 'fennel'"))
    (set user-config new-config)
    (values user-config)))

;; TODO rename this and config-for-context
(fn M.lookup-local-config [file]
  (lookup-local-config file))

(fn M.loadfile-local-config [config-path]
  (case (loadfile-local-config config-path)
    config config
    (nil err) (do
                (vim.notify (fmt (.. "Hotpot could not load local config due to lua error.\n"
                                     "Path: %s\n"
                                     "Error: %s") config-path err)
                            vim.log.levels.WARN)
                (values nil))
    nil (do
          ;; An empty config file will return nil and could be intentional,
          ;; but an error omitting the return keyword will also return nil
          ;; and could be pretty frustrating.
          ;; So we'll opt to error on nil and users can use `return {}` if
          ;; they *really* want a blank config file.
          (vim.notify (fmt (.. "Hotpot found local config but it return nil. "
                               "Please update it to return a table instead of nil.\n"
                               "Path: %s\n") config-path)
                      vim.log.levels.WARN)
          (values nil))))

(fn M.config-for-context [file]
  "Lookup the config for given file.

  If file is nil, or there is no .hotpot.lua for the given file the user-config
  is returned.

  If the file does have a .hotpot.lua config, but it fails to load, the
  default-config is returned and an warning is issued.

  Otherwise the .hotpot.lua config is returned."
  (if (= nil file)
    (M.user-config)
    (case (M.lookup-local-config file)
      nil (M.user-config)
      config-path (case (M.loadfile-local-config config-path)
                    config config
                    nil (do
                          (vim.notify "Using safe defaults" vim.log.levels.WARN)
                          (M.default-config))))))


(M.set-user-config (M.default-config))

;; TODO: smell
(set M.proxied-keys "traceback")
(setmetatable M {:__index #(match $2 :traceback (lazy-traceback))})
