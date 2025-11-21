import {
  to = google_artifact_registry_repository.cloud_run_source_deploy
  id = "projects/inat-359418/locations/us-central1/repositories/cloud-run-source-deploy"
}

import {
  to = google_sql_database_instance.pkp_ojs
  id = "projects/inat-359418/instances/pkp-ojs"
}

import {
  to = google_cloud_run_v2_service.icat_pkp_ojs
  id = "projects/inat-359418/locations/us-central1/services/icat-pkp-ojs"
}

import {
  to = google_storage_bucket.icat_pkp_ojs_config
  id = "icat-pkp-ojs-config"
}

import {
  to = google_storage_bucket.icat_pkp_ojs_private
  id = "icat-pkp-ojs-private"
}

import {
  to = google_service_account.pkp_ojs_sa
  id = "projects/inat-359418/serviceAccounts/pkp-ojs-sa@inat-359418.iam.gserviceaccount.com"
}

import {
  to = google_storage_bucket.icat_pkp_ojs_logs
  id = "icat-pkp-ojs-logs"
}

import {
  to = google_storage_bucket.icat_pkp_ojs_public
  id = "icat-pkp-ojs-public"
}

import {
  to = google_sql_user.icat
  id = "inat-359418/pkp-ojs/icat"
}

import {
  to = google_sql_database.icat
  id = "inat-359418/pkp-ojs/icat"
}
