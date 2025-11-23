# ============================================================================
# Local Variables
# ============================================================================

locals {
  project_id = "inat-359418"
  region     = "us-central1"

  # Non-sensitive environment variables for PKP OJS
  # Refer to https://hub.docker.com/r/pkpofficial/ojs#environment-variables
  pkp_ojs_env_safe_values = {

    PKP_TOOL    = "ojs" # Tool to run or build. Options: ojs, omp, ops
    PKP_VERSION = "3_3_0-21"
    WEB_SERVER  = "php:8.2-apache"

    ### Journal / Project Settings --------------------------------------------------
    COMPOSE_PROJECT_NAME = "ojs"
    PROJECT_DOMAIN       = "conference-submissions.appropriatetech.net"
    SERVERNAME           = "conference-submissions.appropriatetech.net"

    ### Web Server Settings --------------------------------------------------------
    WEB_USER = "www-data"
    WEB_PATH = "/var/www/html"

    ### PKP Tool Variables ---------------------------------------------------------
    PKP_CLI_INSTALL = "0"
    PKP_DB_HOST     = google_sql_database_instance.pkp_ojs.private_ip_address
    PKP_DB_NAME     = google_sql_database.icat.name
    PKP_SMTP_HOST   = "smtp-relay.gmail.com"
    PKP_SMTP_PORT   = "587"
    PKP_WEB_CONF    = "/etc/apache2/conf-enabled/pkp.conf"
    PKP_CONF        = "/var/www/html/config.inc.php"

    ### Build Variables (experts only) ---------------------------------------------
    BUILD_PKP_APP_OS   = "alpine:3.22"
    BUILD_PKP_APP_PATH = "/app"
  }

  # Map of secret IDs to their values
  # These will be stored in Google Secret Manager
  pkp_ojs_secrets = {
    "pkp-db-user"     = google_sql_user.icat.name
    "pkp-db-password" = random_password.pkp_db_password.result
    "pkp-ojs-salt"    = random_string.pkp_salt.result
    "pkp-smtp-user"   = var.pkp_smtp_user
    "pkp-smtp-pass"   = var.pkp_smtp_pass
  }

  # Map of environment variable names to secret IDs
  # This decouples env var names from secret IDs for flexibility
  pkp_ojs_env_secrets = {
    PKP_DB_USER       = "pkp-db-user"
    PKP_DB_PASSWORD   = "pkp-db-password"
    PKP_SALT          = "pkp-ojs-salt"
    PKP_SMTP_USER     = "pkp-smtp-user"
    PKP_SMTP_PASSWORD = "pkp-smtp-pass"
  }

  # Derived map for Cloud Run - references secrets by their Secret Manager IDs
  pkp_ojs_env_secret_ids = {
    for env_var, secret_name in local.pkp_ojs_env_secrets :
    env_var => google_secret_manager_secret.pkp_ojs_secret[secret_name].secret_id
  }

  # Derived map for build config - gets actual secret values
  pkp_ojs_env_secret_values = {
    for env_var, secret_name in local.pkp_ojs_env_secrets :
    env_var => google_secret_manager_secret_version.pkp_ojs_secret_version[secret_name].secret_data
  }

  # Combined map of all environment variables (safe + secret values)
  # Used for build-time configuration
  pkp_ojs_env_all_values = merge(
    local.pkp_ojs_env_safe_values,
    local.pkp_ojs_env_secret_values,
  )
}

# ============================================================================
# Google Cloud APIs
# ============================================================================

resource "google_project_service" "compute" {
  project = local.project_id
  service = "compute.googleapis.com"
}

resource "google_project_service" "artifactregistry" {
  project = local.project_id
  service = "artifactregistry.googleapis.com"
}

resource "google_project_service" "run" {
  project = local.project_id
  service = "run.googleapis.com"
}

resource "google_project_service" "secretmanager" {
  project = local.project_id
  service = "secretmanager.googleapis.com"
}

# ============================================================================
# Artifact Registry
# ============================================================================

resource "google_artifact_registry_repository" "cloud_run_source_deploy" {
  description   = "Cloud Run Source Deployments"
  format        = "DOCKER"
  location      = local.region
  mode          = "STANDARD_REPOSITORY"
  project       = local.project_id
  repository_id = "cloud-run-source-deploy"
}
# terraform import google_artifact_registry_repository.cloud_run_source_deploy projects/inat-359418/locations/us-central1/repositories/cloud-run-source-deploy

# ============================================================================
# Cloud SQL (Database)
# ============================================================================

resource "google_sql_database" "icat" {
  instance = google_sql_database_instance.pkp_ojs.name
  name     = "icat"
  project  = local.project_id
}
# terraform import google_sql_database.icat inat-359418/pkp-ojs/icat

resource "google_sql_database_instance" "pkp_ojs" {
  database_version    = "MYSQL_8_4"
  instance_type       = "CLOUD_SQL_INSTANCE"
  maintenance_version = "MYSQL_8_4_6.R20251004.01_07"
  name                = "pkp-ojs"
  project             = local.project_id
  region              = local.region
  settings {
    activation_policy = "ALWAYS"
    availability_type = "ZONAL"
    backup_configuration {
      backup_retention_settings {
        retained_backups = 7
        retention_unit   = "COUNT"
      }
      binary_log_enabled             = true
      enabled                        = true
      location                       = "us"
      start_time                     = "06:00"
      transaction_log_retention_days = 7
    }
    final_backup_config {
      enabled        = true
      retention_days = 30
    }
    connector_enforcement       = "NOT_REQUIRED"
    deletion_protection_enabled = true
    disk_autoresize             = true
    disk_autoresize_limit       = 0
    disk_size                   = 10
    disk_type                   = "PD_SSD"
    edition                     = "ENTERPRISE"

    ip_configuration {
      ipv4_enabled    = false
      private_network = "projects/inat-359418/global/networks/default"
    }
    location_preference {
      zone = "us-central1-a"
    }
    maintenance_window {
      update_track = "canary"
    }
    password_validation_policy {
      complexity                  = "COMPLEXITY_DEFAULT"
      disallow_username_substring = true
      enable_password_policy      = true
      min_length                  = 8
    }
    pricing_plan             = "PER_USE"
    tier                     = "db-g1-small"
    retain_backups_on_delete = true
  }
}
# terraform import google_sql_database_instance.pkp_ojs projects/inat-359418/instances/pkp-ojs

# Database user
resource "google_sql_user" "icat" {
  instance = google_sql_database_instance.pkp_ojs.name
  name     = "icat"
  password = random_password.pkp_db_password.result
  project  = local.project_id
}

# Random password for database user
resource "random_password" "pkp_db_password" {
  length  = 32
  special = true
}

# ============================================================================
# Cloud Run Service
# ============================================================================

# Random salt for PKP OJS encryption
resource "random_string" "pkp_salt" {
  length = 32
}

resource "google_cloud_run_v2_service" "icat_pkp_ojs" {
  # Wait for IAM permissions and config files to be ready
  depends_on = [
    google_storage_bucket_object.apache_htaccess,
    google_storage_bucket_object.pkp_config_inc_php,
    google_project_iam_member.pkp_ojs_cloudsql_client,
    google_storage_bucket_iam_member.pkp_ojs_config_viewer,
    google_storage_bucket_iam_member.pkp_ojs_private_admin,
    google_storage_bucket_iam_member.pkp_ojs_logs_admin,
    google_storage_bucket_iam_member.pkp_ojs_public_admin,
    google_secret_manager_secret_iam_member.pkp_ojs_secret_access,
  ]

  client         = "gcloud"
  client_version = "531.0.0"
  ingress        = "INGRESS_TRAFFIC_ALL"
  launch_stage   = "GA"
  location       = local.region
  name           = "icat-pkp-ojs"
  project        = local.project_id
  build_config {
    enable_automatic_updates = false
    environment_variables = {
      for k, v in local.pkp_ojs_env_all_values :
      k => v
    }
    image_uri       = "us-central1-docker.pkg.dev/inat-359418/cloud-run-source-deploy/icat-pkp-ojs"
    service_account = google_service_account.pkp_ojs_sa.id
    source_location = "gs://run-sources-inat-359418-us-central1/services/icat-pkp-ojs/1757956567.426021-a003ea97231f4cd2afd2f9513c6a6b79.zip#1757956567585535"
  }
  template {
    containers {
      dynamic "env" {
        for_each = local.pkp_ojs_env_safe_values
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.pkp_ojs_env_secret_ids
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      image = "us-central1-docker.pkg.dev/inat-359418/cloud-run-source-deploy/icat-pkp-ojs:latest"
      name  = "icat-pkp-ojs-1"
      ports {
        container_port = 8080
        name           = "http1"
      }
      resources {
        cpu_idle = true
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
        startup_cpu_boost = true
      }
      startup_probe {
        failure_threshold     = 1
        initial_delay_seconds = 0
        period_seconds        = 240
        tcp_socket {
          port = 8080
        }
        timeout_seconds = 240
      }
      volume_mounts {
        mount_path = "/var/www/html/public"
        name       = "public-files"
      }
      volume_mounts {
        mount_path = "/var/www/files"
        name       = "private-files"
      }
      volume_mounts {
        mount_path = "/var/log/apache2"
        name       = "log-files"
      }
      volume_mounts {
        mount_path = "/var/www/config"
        name       = "config-files"
      }
      volume_mounts {
        mount_path = "/cloudsql"
        name       = "cloudsql"
      }
    }
    max_instance_request_concurrency = 80
    scaling {
      max_instance_count = 10
    }
    service_account = google_service_account.pkp_ojs_sa.email
    timeout         = "300s"
    volumes {
      name = "public-files"
      gcs {
        bucket = google_storage_bucket.icat_pkp_ojs_public.name
        mount_options = [
          "uid=33",
          "gid=33",
        ]
        read_only = false
      }
    }
    volumes {
      name = "private-files"
      gcs {
        bucket = google_storage_bucket.icat_pkp_ojs_private.name
        mount_options = [
          "uid=33",
          "gid=33",
        ]
        read_only = false
      }
    }
    volumes {
      name = "log-files"
      gcs {
        bucket = google_storage_bucket.icat_pkp_ojs_logs.name
        mount_options = [
          "uid=33",
          "gid=33",
        ]
        read_only = false
      }
    }
    volumes {
      name = "config-files"
      gcs {
        bucket = google_storage_bucket.icat_pkp_ojs_config.name
        mount_options = [
          "uid=33",
          "gid=33",
        ]
        read_only = true
      }
    }
    volumes {
      cloud_sql_instance {
        instances = ["inat-359418:us-central1:pkp-ojs"]
      }
      name = "cloudsql"
    }
    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network = "default"
      }
    }
  }
  traffic {
    percent = 100
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
  }
}
# terraform import google_cloud_run_v2_service.icat_pkp_ojs projects/inat-359418/locations/us-central1/services/icat-pkp-ojs

# ============================================================================
# Cloud Storage Buckets
# ============================================================================

# Config bucket - stores read-only config files
resource "google_storage_bucket" "icat_pkp_ojs_config" {
  force_destroy            = false
  location                 = local.region
  name                     = "icat-pkp-ojs-config"
  project                  = local.project_id
  public_access_prevention = "inherited"
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  storage_class = "STANDARD"
}
# terraform import google_storage_bucket.icat_pkp_ojs_config icat-pkp-ojs-config

# Private files bucket - stores user uploads and private files
resource "google_storage_bucket" "icat_pkp_ojs_private" {
  force_destroy            = false
  location                 = local.region
  name                     = "icat-pkp-ojs-private"
  project                  = local.project_id
  public_access_prevention = "inherited"
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  storage_class = "STANDARD"
}
# terraform import google_storage_bucket.icat_pkp_ojs_private icat-pkp-ojs-private

# Logs bucket - stores Apache error logs
resource "google_storage_bucket" "icat_pkp_ojs_logs" {
  force_destroy            = false
  location                 = local.region
  name                     = "icat-pkp-ojs-logs"
  project                  = local.project_id
  public_access_prevention = "inherited"
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  storage_class = "STANDARD"
}
# terraform import google_storage_bucket.icat_pkp_ojs_logs icat-pkp-ojs-logs

# Public files bucket - stores publicly accessible files
resource "google_storage_bucket" "icat_pkp_ojs_public" {
  force_destroy            = false
  location                 = local.region
  name                     = "icat-pkp-ojs-public"
  project                  = local.project_id
  public_access_prevention = "inherited"
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  storage_class = "STANDARD"
}
# terraform import google_storage_bucket.icat_pkp_ojs_public icat-pkp-ojs-public

# Config files uploaded to the config bucket
resource "google_storage_bucket_object" "apache_htaccess" {
  bucket  = google_storage_bucket.icat_pkp_ojs_config.name
  content = file("${path.module}/config/apache.htaccess")
  name    = "apache.htaccess"
}

resource "google_storage_bucket_object" "pkp_config_inc_php" {
  bucket  = google_storage_bucket.icat_pkp_ojs_config.name
  content = templatefile("${path.module}/config/pkp.config.inc.php", local.pkp_ojs_env_all_values)
  name    = "pkp.config.inc.php"
}

# ============================================================================
# Secrets Management
# ============================================================================

# Create secrets in Secret Manager (one for each key in pkp_ojs_secrets)
resource "google_secret_manager_secret" "pkp_ojs_secret" {
  for_each = local.pkp_ojs_secrets

  secret_id = each.key
  project   = local.project_id

  replication {
    auto {}
  }
}

# Store secret values in Secret Manager
resource "google_secret_manager_secret_version" "pkp_ojs_secret_version" {
  for_each = local.pkp_ojs_secrets

  secret      = google_secret_manager_secret.pkp_ojs_secret[each.key].id
  secret_data = each.value
}

# ============================================================================
# Service Account & IAM Permissions
# ============================================================================

resource "google_service_account" "pkp_ojs_sa" {
  account_id   = "pkp-ojs-sa"
  description  = "Service account for PKP OJS"
  display_name = "PKP OJS Service Account"
  project      = local.project_id
}
# terraform import google_service_account.pkp_ojs_sa projects/inat-359418/serviceAccounts/pkp-ojs-sa@inat-359418.iam.gserviceaccount.com

# Grant Cloud SQL client access for database connectivity
resource "google_project_iam_member" "pkp_ojs_cloudsql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.pkp_ojs_sa.email}"
}

# Grant read-only access to config bucket
resource "google_storage_bucket_iam_member" "pkp_ojs_config_viewer" {
  bucket = google_storage_bucket.icat_pkp_ojs_config.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.pkp_ojs_sa.email}"
}

# Grant read/write access to private files bucket
resource "google_storage_bucket_iam_member" "pkp_ojs_private_admin" {
  bucket = google_storage_bucket.icat_pkp_ojs_private.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.pkp_ojs_sa.email}"
}

# Grant read/write access to logs bucket
resource "google_storage_bucket_iam_member" "pkp_ojs_logs_admin" {
  bucket = google_storage_bucket.icat_pkp_ojs_logs.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.pkp_ojs_sa.email}"
}

# Grant read/write access to public files bucket
resource "google_storage_bucket_iam_member" "pkp_ojs_public_admin" {
  bucket = google_storage_bucket.icat_pkp_ojs_public.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.pkp_ojs_sa.email}"
}

# Grant service account access to read secrets
resource "google_secret_manager_secret_iam_member" "pkp_ojs_secret_access" {
  for_each = local.pkp_ojs_secrets

  secret_id = google_secret_manager_secret.pkp_ojs_secret[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.pkp_ojs_sa.email}"
}
