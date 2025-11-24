import {
  to = google_project_service.compute
  id = "inat-359418/compute.googleapis.com"
}

import {
  to = google_project_service.artifactregistry
  id = "inat-359418/artifactregistry.googleapis.com"
}

import {
  to = google_project_service.run
  id = "inat-359418/run.googleapis.com"
}

import {
  to = google_project_service.secretmanager
  id = "inat-359418/secretmanager.googleapis.com"
}

import {
  to = google_artifact_registry_repository.cloud_run_source_deploy
  id = "projects/inat-359418/locations/us-central1/repositories/cloud-run-source-deploy"
}

import {
  to = google_sql_database_instance.pkp_ojs
  id = "projects/inat-359418/instances/pkp-ojs"
}

import {
  to = google_cloud_run_v2_service.icat_pkp_ojs_server
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

# import {
#   to = google_project_iam_member.pkp_ojs_cloudsql_client
#   id = "inat-359418 roles/cloudsql.client serviceAccount:pkp-ojs-sa@inat-359418.iam.gserviceaccount.com"
# }

# import {
#   to = google_storage_bucket_iam_member.pkp_ojs_config_viewer
#   id = "icat-pkp-ojs-config roles/storage.objectViewer serviceAccount:pkp-ojs-sa@inat-359418.iam.gserviceaccount.com"
# }

# import {
#   to = google_storage_bucket_iam_member.pkp_ojs_private_admin
#   id = "icat-pkp-ojs-private roles/storage.objectAdmin serviceAccount:pkp-ojs-sa@inat-359418.iam.gserviceaccount.com"
# }

# import {
#   to = google_storage_bucket_iam_member.pkp_ojs_logs_admin
#   id = "icat-pkp-ojs-logs roles/storage.objectAdmin serviceAccount:pkp-ojs-sa@inat-359418.iam.gserviceaccount.com"
# }

# import {
#   to = google_storage_bucket_iam_member.pkp_ojs_public_admin
#   id = "icat-pkp-ojs-public roles/storage.objectAdmin serviceAccount:pkp-ojs-sa@inat-359418.iam.gserviceaccount.com"
# }

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
