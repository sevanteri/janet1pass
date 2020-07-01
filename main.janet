(import secret)
(import json)
(import process)
(import argparse :prefix "")
(import json-utils :prefix "")

(def- schema
  "libsecret schema to save the 1pw cli session token"
  {:name "jopass.sessiontoken"
   :attributes {"shorthand" :string
                :app :jopass}})

(def home-path ((os/environ) "HOME"))

(def config-path
  (string (get (os/environ) "XDG_CONFIG_HOME"
               (string home-path "/.config"))
          "/jopass"))

(def pw-file-path
  (string config-path "/pass.gpg"))

(def last-use-path
  (string config-path "/last_used"))

(def op-config-path
  (string home-path "/.op/config"))
(def opconfig (json/decode (slurp op-config-path)))
(def latest-signin (opconfig "latest_signin"))
(def shorthands (map (partial get-json-path "shorthand") (opconfig "accounts")))


(defn last-use-duration []
  (let [last-use (os/stat last-use-path :changed)]
    (if (not (nil? last-use))
      (- (os/time) last-use))))


(defn _save-token [shorthand token]
  (if (secret/save-password
        schema
        @{"shorthand" shorthand
          :app :jopass}
        :session
        (string "jopass " shorthand)
        token)
    token))

(defn _get-token [shorthand]
  (secret/lookup-password
     schema
     @{"shorthand" shorthand
       :app :jopass}))

(defn _remove-token [shorthand]
  (secret/remove-password
     schema
     @{"shorthand" shorthand
       :app :jopass}))


(defn token-err? [str]
  (truthy? (or (string/find "session expired" str)
               (string/find "Invalid session token" str))))

## 1PW commands
(defn signin
  `Sign in with 1password cli. Password is decrypted from a GPG file.
  Returns a new session token`
  [&opt shorthand]
  (default shorthand latest-signin)
  # TODO: change to process/run
  (if-with [f (file/popen
                (string "gpg -qd "
                        pw-file-path
                        " | op signin " shorthand
                        " --raw")
                :r)]
    (string/trim (file/read f :line))))

(defn token-valid?
  "Checks if the token is still valid. Returns a boolean."
  [token shorthand]
  (cond
    (nil? token) false
    (if (< (last-use-duration) 1800) # 30min
      true
      (do
        (_remove-token shorthand)
        false))))


(defn get-new-token-and-save [&opt shorthand]
  (default shorthand latest-signin)
  (let [token (signin shorthand)]
    (_save-token shorthand token)
    (os/touch last-use-path)
    token))

(defn maybe-renew-token [token &opt shorthand]
  (default shorthand latest-signin)
  (if (token-valid? token shorthand)
    token
    (get-new-token-and-save shorthand)))

(defn get-token [&opt shorthand]
  (default shorthand latest-signin)
  (maybe-renew-token (_get-token shorthand) shorthand))

(defn op [token shorthand & args]
  (def out @"")
  (def err @"")
  (if (zero? (process/run ["op" "--session" token
                           "--account" shorthand
                           ;args]
                          :redirects [[stderr err] [stdout out]]))
    (do
      (os/touch last-use-path)
      (json/decode out))
    (if (token-err? err)
      (op (get-new-token-and-save shorthand)
          shorthand
          ;args))))


(defn list-items [token shorthand]
 (op token shorthand :list :items))

(defn get-item [token shorthand name]
  (op token shorthand :get :item name))

(defn get-totp [token shorthand name]
  (op token shorthand :get :totp name))

(defn get-password [token shorthand name]
  (-?>> (get-item token shorthand name)
       (get-fields)
       (filter-jsonarray-by-path "designation" "password")
       (first)
       (get-json-path "value")))

(defn get-username [token shorthand name]
  (-?>> (get-item token shorthand name)
       (get-fields)
       (filter-jsonarray-by-path "designation" "username")
       (first)
       (get-json-path "value")))

(defn get-titles [token shorthand]
  (sorted (map get-title (list-items token shorthand))))

(defn- check-shorthand [shorthand]
  (if (nil? (find (partial = shorthand) shorthands))
    (do (print (string "Account shorthand '" shorthand "' not found."))
      (os/exit 1))))

(defn get-passwords [token &opt shorthand]
    (-?>> (list-items token shorthand)
          (only-passwords)
          (map get-title)
          (sorted)
          (map print)))

(defn copy [pw]
  (process/run ["xclip" "-selection" "clipboard"]
    :redirects [[stdin pw]]))

(defn type-it [pw]
  (process/run ["xdotool" "type" "--clearmodifiers" "--file" "-"]
    :redirects [[stdin (string/trim pw)]]))

(defn initialize
  "Create config dir if not present. Guide first steps."
  []
  (os/mkdir config-path)
  (if (nil? (os/stat pw-file-path))
    (do
      (print "Encrypt your 1Password with GPG to " pw-file-path)
      (os/exit 1)))
  (if (nil? (os/stat last-use-path))
    (spit last-use-path "")))

(def- argparse-args
  ["Desc"
   :default {:kind :option}
   "account" {:kind :option
              :short "a"
              :help "Account shorthand"}
   "totp" {:kind :flag
           :short "t"
           :help "Get TOTP code"}
   "username" {:kind :flag
               :short "u"
               :help "Get username"}
   "copy" {:kind :flag
           :short "c"
           :help "Copy to clipboard"}
   "type" {:kind :flag
           :short "T"
           :help "Type it"}])

(defn main [&]
  (initialize)
  (let [args (argparse ;argparse-args)
        shorthand (or (args "account") latest-signin)
        query (args :default)
        totp (args "totp")
        username (args "username")
        _copy (args "copy")
        _type-it (args "type")]
    (check-shorthand shorthand)
    (let [token (get-token shorthand)
          fun (cond
                _copy copy
                _type-it type-it
                print)]
      (cond
        (and totp query) (fun (get-totp token shorthand query))
        (and username query) (fun (get-username token shorthand query))
        query (fun (get-password token shorthand query))
        (get-passwords token shorthand)))))
