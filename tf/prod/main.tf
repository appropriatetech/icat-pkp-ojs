locals {
  project_id = "inat-359418"
  region     = "us-central1"
}

resource "google_artifact_registry_repository" "cloud_run_source_deploy" {
  description = "Cloud Run Source Deployments"
  format      = "DOCKER"
  labels = {
    managed-by-cnrm = "true"
  }
  location      = local.region
  mode          = "STANDARD_REPOSITORY"
  project       = local.project_id
  repository_id = "cloud-run-source-deploy"
}
# terraform import google_artifact_registry_repository.cloud_run_source_deploy projects/inat-359418/locations/us-central1/repositories/cloud-run-source-deploy

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
    connector_enforcement       = "NOT_REQUIRED"
    deletion_protection_enabled = true
    disk_autoresize             = true
    disk_autoresize_limit       = 0
    disk_size                   = 10
    disk_type                   = "PD_SSD"
    edition                     = "ENTERPRISE"
    insights_config {
      query_string_length = 0
    }
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
    pricing_plan = "PER_USE"
    tier         = "db-g1-small"
    user_labels = {
      managed-by-cnrm = "true"
    }
  }
}
# terraform import google_sql_database_instance.pkp_ojs projects/inat-359418/instances/pkp-ojs

resource "google_cloud_run_v2_service" "icat_pkp_ojs" {
  client         = "gcloud"
  client_version = "531.0.0"
  ingress        = "INGRESS_TRAFFIC_ALL"
  labels = {
    managed-by-cnrm = "true"
  }
  launch_stage = "GA"
  location     = local.region
  name         = "icat-pkp-ojs"
  project      = local.project_id
  template {
    containers {
      env {
        name  = "PKP_TOOL"
        value = "ojs"
      }
      env {
        name  = "PKP_VERSION"
        value = "3_3_0-21"
      }
      env {
        name  = "WEB_SERVER"
        value = "php:8.2-apache"
      }
      env {
        name  = "COMPOSE_PROJECT_NAME"
        value = "ojs"
      }
      env {
        name  = "PROJECT_DOMAIN"
        value = "conference-submissions.appropriatetech.net"
      }
      env {
        name  = "SERVERNAME"
        value = "conference-submissions.appropriatetech.net"
      }
      env {
        name  = "WEB_USER"
        value = "www-data"
      }
      env {
        name  = "WEB_PATH"
        value = "/var/www/html"
      }
      env {
        name  = "PKP_CLI_INSTALL"
        value = "0"
      }
      env {
        name  = "PKP_DB_HOST"
        # value = "10.79.192.3"
        value = google_sql_database_instance.pkp_ojs.private_ip_address
      }
      env {
        name  = "PKP_DB_NAME"
        # value = "icat"
        value = google_sql_database_instance.pkp_ojs.name
      }
      env {
        name  = "PKP_DB_USER"
        value = "icat"
      }
      env {
        name  = "PKP_DB_PASSWORD"
        value = "xxx"
      }
      env {
        name  = "PKP_WEB_CONF"
        value = "/etc/apache2/conf-enabled/pkp.conf"
      }
      env {
        name  = "PKP_CONF"
        value = "/var/www/html/config.inc.php"
      }
      env {
        name  = "BUILD_PKP_APP_OS"
        value = "alpine:3.22"
      }
      env {
        name  = "BUILD_PKP_APP_PATH"
        value = "/app"
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
    service_account = "809701600064-compute@developer.gserviceaccount.com"
    timeout         = "300s"
    volumes {
      name = "public-files"
    }
    volumes {
      name = "private-files"
    }
    volumes {
      name = "log-files"
    }
    volumes {
      name = "config-files"
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

resource "google_storage_bucket" "icat_pkp_ojs_config" {
  force_destroy = false
  labels = {
    managed-by-cnrm = "true"
  }
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

resource "google_storage_bucket" "icat_pkp_ojs_private" {
  force_destroy = false
  labels = {
    managed-by-cnrm = "true"
  }
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

resource "google_service_account" "pkp_ojs_sa" {
  account_id   = "pkp-ojs-sa"
  description  = "Service account for PKP OJS"
  display_name = "PKP OJS Service Account"
  project      = local.project_id
}
# terraform import google_service_account.pkp_ojs_sa projects/inat-359418/serviceAccounts/pkp-ojs-sa@inat-359418.iam.gserviceaccount.com

resource "google_storage_bucket" "icat_pkp_ojs_logs" {
  force_destroy = false
  labels = {
    managed-by-cnrm = "true"
  }
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

resource "google_storage_bucket" "icat_pkp_ojs_public" {
  force_destroy = false
  labels = {
    managed-by-cnrm = "true"
  }
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
