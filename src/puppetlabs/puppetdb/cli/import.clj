(ns puppetlabs.puppetdb.cli.import
  "Import utility

   This is a command-line tool for importing data into PuppetDB. It expects
   as input a tarball generated by the PuppetDB `export` command-line tool."
  (:import  [puppetlabs.puppetdb.archive TarGzReader]
            [org.apache.commons.compress.archivers.tar TarArchiveEntry])
  (:require [me.raynes.fs :as fs]
            [puppetlabs.puppetdb.client :as client]
            [clj-http.client :as http-client]
            [clojure.tools.logging :as log]
            [puppetlabs.puppetdb.archive :as archive]
            [puppetlabs.puppetdb.cheshire :as json]
            [clojure.java.io :as io]
            [slingshot.slingshot :refer [try+]]
            [puppetlabs.puppetdb.schema :refer [defn-validated]]
            [puppetlabs.puppetdb.utils :as utils
             :refer [base-url-schema export-root-dir]]
            [puppetlabs.kitchensink.core :as kitchensink]
            [puppetlabs.puppetdb.cli.export :as export]
            [clj-time.core :refer [now]]
            [schema.core :as s]
            [slingshot.slingshot :refer [try+ throw+]]))

(def cli-description "Import PuppetDB catalog data from a backup file")

(def metadata-path
  (.getPath (io/file export-root-dir export/export-metadata-file-name)))

(defn parse-metadata
  "Parses the export metadata file to determine, e.g., what versions of the
  commands should be used during import."
  [tarball]
  {:post [(map? %)
          (:command_versions %)]}
  (with-open [tar-reader (archive/tarball-reader tarball)]
    (when-not (archive/find-entry tar-reader metadata-path)
      (throw (IllegalStateException.
              (format "Unable to find export metadata file '%s' in archive '%s'"
                      metadata-path
                      tarball))))
    (-> tar-reader
        archive/read-entry-content
        (json/parse-string true))))

(defn file-pattern
  [entity]
  (re-pattern (str "^" (.getPath (io/file export-root-dir entity ".*\\.json")) "$")))

(defn-validated process-tar-entry
  "Determine the type of an entry from the exported archive, and process it
  accordingly."
  [command-fn
   tar-reader :- TarGzReader
   tar-entry :- TarArchiveEntry
   command-versions]
  (let [path (.getName tar-entry)]
    (condp re-find path
      (file-pattern "catalogs")
      (do (log/infof "Importing catalog from archive entry '%s'" path)
          ;; NOTE: these submissions are async and we have no guarantee that they
          ;;   will succeed. We might want to add something at the end of the import
          ;;   that polls puppetdb until the command queue is empty, then does a
          ;;   query to the /nodes endpoint and shows the set difference between
          ;;   the list of nodes that we submitted and the output of that query
          (command-fn :replace-catalog
                      (:replace_catalog command-versions)
                      (json/parse-string (archive/read-entry-content tar-reader))))
      (file-pattern "reports")
      (do (log/infof "Importing report from archive entry '%s'" path)
          (command-fn :store-report
                      (:store_report command-versions)
                      (-> (archive/read-entry-content tar-reader)
                          (json/parse-string true)
                          puppetlabs.puppetdb.reports/sanitize-report)))
      (file-pattern "facts")
      (do (log/infof "Importing facts from archive entry '%s'" path)
          (command-fn :replace-facts
                      (:replace_facts command-versions)
                      (json/parse-string (archive/read-entry-content tar-reader))))
      nil)))

(defn- validate-cli!
  [args]
  (let [specs [["-i" "--infile INFILE" "Path to backup file (required)"]
               ["-H" "--host HOST" "Hostname of PuppetDB server"
                :default "127.0.0.1"]
               ["-p" "--port PORT" "Port to connect to PuppetDB server (HTTP protocol only)"
                :default 8080
                :parse-fn #(Integer/parseInt %)]]
        required [:infile]
        validate-file-exists! (fn [{:keys [infile] :as options}]
                             (when-not (fs/exists? infile)
                               (throw+ {:type ::cli-help
                                        :message (format "Import from %s failed. File not found." infile)}))
                             options)
        construct-base-url (fn [{:keys [host port] :as options}]
                             (-> options
                                 (assoc :base-url (utils/pdb-admin-base-url host port export/admin-api-version))
                                 (dissoc :host :port)))]
    (utils/try+-process-cli!
     (fn []
       (-> args
           (kitchensink/cli! specs required)
           first
           validate-file-exists!
           construct-base-url
           utils/validate-cli-base-url!)))))

(defn import!
  [infile command-versions command-fn]
  (with-open [tar-reader (archive/tarball-reader infile)]
    (doseq [tar-entry (archive/all-entries tar-reader)]
      (process-tar-entry command-fn tar-reader tar-entry command-versions))))

(defn -main
  [& args]
  (let [{:keys [infile base-url]} (validate-cli! args)
        import-archive (fs/normalized-path infile)
        command-versions (:command_versions (parse-metadata import-archive))]
    (try
      (println " Importing " infile " to PuppetDB...")
      (http-client/post (str (utils/base-url->str base-url) "/archive")
                        {:multipart [{:name "Content/type" :content "application/octet-stream"}
                                     {:name "archive" :content import-archive}
                                     {:name "command_versions" :content (json/generate-pretty-string command-versions)}]})
      (println " Finished importing " infile " to PuppetDB.")
      (catch Throwable e
        (println e "Error importing " infile)))))
