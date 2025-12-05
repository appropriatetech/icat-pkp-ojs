# ============================================================================
# Local Variables
# ============================================================================

locals {
  project_id = "inat-359418"
  region     = "us-central1"

  pkp_ojs_container_repo = "https://github.com/appropriatetech/pkp-containers.git"
  pkp_ojs_container_local_path = "${path.module}/../../../containers/"

  # Non-sensitive environment variables for PKP OJS
  # Refer to https://hub.docker.com/r/pkpofficial/ojs#environment-variables
  pkp_ojs_env_safe_values = {

    PKP_TOOL    = "ojs" # Tool to run or build. Options: ojs, omp, ops
    PKP_VERSION = "3_5_0-2"
    WEB_SERVER  = "php:8.2-apache"

    ### Journal / Project Settings --------------------------------------------------
    COMPOSE_PROJECT_NAME = "ojs"
    PROJECT_DOMAIN       = "conference-submissions.appropriatetech.net"
    SERVERNAME           = "conference-submissions.appropriatetech.net"
    BASE_URL             = "https://conference-submissions.appropriatetech.net/"

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
    "pkp-ojs-api-key" = random_password.pkp_api_key.result
    "pkp-app-key"     = "base64:${random_id.pkp_app_key.b64_std}"
    "pkp-smtp-user"   = var.pkp_smtp_user
    "pkp-smtp-pass"   = var.pkp_smtp_pass
  }

  # Map of environment variable names to secret IDs
  # This decouples env var names from secret IDs for flexibility
  pkp_ojs_env_secrets = {
    PKP_DB_USER       = "pkp-db-user"
    PKP_DB_PASSWORD   = "pkp-db-password"
    PKP_SALT          = "pkp-ojs-salt"
    PKP_API_KEY       = "pkp-ojs-api-key"
    PKP_APP_KEY       = "pkp-app-key"
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

resource "google_project_service" "cloudscheduler" {
  project = local.project_id
  service = "cloudscheduler.googleapis.com"
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

# Build and push PKP OJS container image to Artifact Registry
resource "null_resource" "pkp_ojs_container_build" {
  # Trigger a new build whenever the container source changes
  triggers = {
    container_source = sha256(join("", [
      for file in fileset(local.pkp_ojs_container_local_path, "**") :
      filesha256("${local.pkp_ojs_container_local_path}/${file}")
    ]))
    timestamp = replace(timestamp(), ":", "")
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/submit_build.py --registry-uri ${google_artifact_registry_repository.cloud_run_source_deploy.registry_uri} --tag ${self.triggers.timestamp} --env-vars '${replace(jsonencode(local.pkp_ojs_env_all_values), "'", "'\\''")}' --source-path ${local.pkp_ojs_container_local_path} --project-id ${local.project_id} --region ${local.region}"
  }

  depends_on = [
    google_project_service.artifactregistry,
  ]
}

# ============================================================================
# Cloud SQL (Database)
# ============================================================================

resource "google_sql_database" "icat" {
  instance = google_sql_database_instance.pkp_ojs.name
  name     = "icat"
  project  = local.project_id
}

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
      private_network = "projects/${local.project_id}/global/networks/default"
    }
    location_preference {
      zone = "${local.region}-a"
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

# Random API key for PKP OJS
resource "random_password" "pkp_api_key" {
  length  = 32
  special = false
}

# Random App Key for PKP OJS (Laravel)
resource "random_id" "pkp_app_key" {
  byte_length = 32
}

resource "google_cloud_run_v2_service" "icat_pkp_ojs_server" {
  # Wait for IAM permissions, config files, and container image to be ready
  depends_on = [
    google_storage_bucket_object.apache_htaccess,
    google_storage_bucket_object.pkp_config_inc_php,
    google_project_iam_member.pkp_ojs_cloudsql_client,
    google_storage_bucket_iam_member.pkp_ojs_config_viewer,
    google_storage_bucket_iam_member.pkp_ojs_private_admin,
    google_storage_bucket_iam_member.pkp_ojs_logs_admin,
    google_storage_bucket_iam_member.pkp_ojs_public_admin,
    google_secret_manager_secret_iam_member.pkp_ojs_secret_access,
    null_resource.pkp_ojs_container_build,
  ]

  client         = "gcloud"
  client_version = "531.0.0"
  ingress        = "INGRESS_TRAFFIC_ALL"
  launch_stage   = "GA"
  location       = local.region
  name           = "icat-pkp-ojs"
  project        = local.project_id

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

      # Use the timestamped image from the build
      image = "${google_artifact_registry_repository.cloud_run_source_deploy.registry_uri}/icat-pkp-ojs:${null_resource.pkp_ojs_container_build.triggers.timestamp}"
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
        instances = ["${local.project_id}:${local.region}:pkp-ojs"]
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

# Cloud Run job for scheduled tasks (runs pkp-run-scheduled script)
resource "google_cloud_run_v2_job" "icat_pkp_ojs_scheduled" {
  name     = "icat-pkp-ojs-scheduled"
  location = local.region
  project  = local.project_id

  depends_on = [
    null_resource.pkp_ojs_container_build,
  ]

  template {
    template {
      containers {
        # Use the timestamped image from the build
        image = "${google_artifact_registry_repository.cloud_run_source_deploy.registry_uri}/icat-pkp-ojs:${null_resource.pkp_ojs_container_build.triggers.timestamp}"
        
        # Run the scheduled tasks script
        command = ["pkp-run-scheduled"]

        # Environment variables - same as the service
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

        resources {
          limits = {
            cpu    = "1000m"
            memory = "2Gi"
          }
        }

        # Mount the same volumes as the server
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

      max_retries     = 0
      service_account = google_service_account.pkp_ojs_sa.email
      timeout         = "3600s"

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
          instances = ["${local.project_id}:${local.region}:pkp-ojs"]
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
  }
}

# Cloud Run job for manual upgrades (runs pkp-upgrade script)
resource "google_cloud_run_v2_job" "icat_pkp_ojs_upgrade" {
  name     = "icat-pkp-ojs-upgrade"
  location = local.region
  project  = local.project_id

  depends_on = [
    null_resource.pkp_ojs_container_build,
  ]

  template {
    template {
      containers {
        # Use the timestamped image from the build
        image = "${google_artifact_registry_repository.cloud_run_source_deploy.registry_uri}/icat-pkp-ojs:${null_resource.pkp_ojs_container_build.triggers.timestamp}"
        
        # Run the upgrade script
        command = ["pkp-upgrade"]

        # Environment variables - same as the service
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

        resources {
          limits = {
            cpu    = "1000m"
            memory = "2Gi"
          }
        }

        # Mount the same volumes as the server
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

      max_retries     = 0
      service_account = google_service_account.pkp_ojs_sa.email
      timeout         = "3600s"

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
          instances = ["${local.project_id}:${local.region}:pkp-ojs"]
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
  }
}

# Cloud Scheduler job to trigger the scheduled tasks hourly
resource "google_cloud_scheduler_job" "icat_pkp_ojs_scheduled_trigger" {
  name             = "icat-pkp-ojs-scheduled-trigger"
  description      = "Triggers PKP OJS scheduled tasks every hour"
  schedule         = "0 * * * *"  # Run at the start of every hour
  attempt_deadline = "320s"
  region           = local.region
  project          = local.project_id

  retry_config {
    retry_count = 1
  }

  http_target {
    http_method = "POST"
    uri         = "https://${local.region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${local.project_id}/jobs/${google_cloud_run_v2_job.icat_pkp_ojs_scheduled.name}:run"

    oauth_token {
      service_account_email = google_service_account.pkp_ojs_sa.email
    }
  }
}

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

# Grant Cloud SQL client access for database connectivity
resource "google_project_iam_member" "pkp_ojs_cloudsql_client" {
  project = local.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.pkp_ojs_sa.email}"
}

# Grant permission to invoke Cloud Run jobs (for scheduler to trigger scheduled tasks)
resource "google_project_iam_member" "pkp_ojs_run_invoker" {
  project = local.project_id
  role    = "roles/run.invoker"
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
