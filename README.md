# PKP OJS Deployment on Google Cloud Run

This repository contains the infrastructure-as-code (IaC) for deploying PKP Open Journal Systems (OJS) to Google Cloud Run using OpenTofu/Terraform. The deployment is fully automated and includes:

- **Cloud Run Service**: Runs the OJS web application
- **Cloud Run Jobs**: Scheduled tasks and upgrade operations
- **Cloud SQL**: MySQL 8.4 database
- **Cloud Storage**: Persistent file storage with GCS FUSE mounts
- **Secret Manager**: Secure storage for sensitive configuration
- **Cloud Build**: Automated container image builds
- **Cloud Scheduler**: Hourly execution of scheduled tasks

## Prerequisites

- [OpenTofu](https://opentofu.org/) or [Terraform](https://www.terraform.io/) installed
- [Google Cloud CLI (`gcloud`)](https://cloud.google.com/sdk/docs/install) installed and authenticated
- The [pkp-containers](https://github.com/appropriatetech/pkp-containers) repository cloned to `../containers/` (relative to this directory)

## Quick Start

### Initial Setup

1. **Set required variables** (create `tf/prod/.auto.tfvars`):

   ```hcl
   pkp_smtp_user = "your-smtp-user"
   pkp_smtp_pass = "your-smtp-password"
   ```

2. **Initialize Terraform**:

   ```bash
   cd tf/prod
   tofu init
   ```

3. **Generate the random APP_KEY** (required for OJS 3.5+):

   ```bash
   tofu apply -target=random_id.pkp_app_key
   ```

   > NOTE: This is done in a separate apply step because the random ID must exist before uploading the configuration file that uses it, due to the way that the `random_id` provider defers value generation until apply time. See the note on the `random_id.pkp_app_key` resource in `main.tf` for more details.

4. **Deploy the infrastructure**:

   ```bash
   tofu apply
   ```

This will:

- Create all cloud resources (database, storage buckets, service account, etc.)
- Build and deploy the container image
- Configure environment variables and secrets
- Upload configuration files to Cloud Storage
- Deploy the Cloud Run service and jobs
- Set up Cloud Scheduler for hourly tasks

### Updating the Deployment

Configuration is managed in `tf/prod/main.tf`:

- **Environment variables**: Edit `locals.pkp_ojs_env_safe_values`
- **OJS version**: Change `PKP_VERSION` (e.g., `"3_5_0-2"`)
- **Domain settings**: Update `BASE_URL` and `SERVERNAME`
- **Config files**: Edit files in `tf/prod/config/` (copy from the template config.inc.php in the new version, and merge your settings)

Additional changes _may_ be needed in the Dockerfile or other scripts in the `pkp-containers` repo if there are breaking changes in OJS. Please read the OJS release notes closely for any special upgrade instructions.

After making changes, deploy with:

```bash
tofu apply
```

The deployment will automatically:

- Build a new container image with updated environment variables
- Update configuration files in Cloud Storage
- Deploy the new revision to Cloud Run

## Configuration Files

Configuration files are stored as templates in `tf/prod/config/`:

- **`pkp.config.inc.php`**: Main OJS configuration (templated with environment variables)
- **`apache.htaccess`**: Apache URL rewriting rules

These files are rendered with environment variables and uploaded to the `icat-pkp-ojs-config` Cloud Storage bucket, then mounted read-only into the containers at `/var/www/config/`.

## Secrets Management

Secrets are automatically generated and stored in Google Cloud Secret Manager:

- `pkp-db-user` / `pkp-db-password`: Database credentials
- `pkp-ojs-salt`: Encryption salt
- `pkp-ojs-api-key`: API key
- `pkp-app-key`: Laravel application key (OJS 3.5+)
- `pkp-smtp-user` / `pkp-smtp-pass`: SMTP credentials (from tfvars)

Secrets are injected as environment variables into the Cloud Run service and jobs.

## Storage Buckets

Four Cloud Storage buckets provide persistent storage:

- **`icat-pkp-ojs-config`**: Configuration files (read-only)
- **`icat-pkp-ojs-private`**: Private files, uploads, usage stats
- **`icat-pkp-ojs-public`**: Public files accessible via web
- **`icat-pkp-ojs-logs`**: Apache error logs

All buckets use GCS FUSE for mounting into containers with UID/GID 33 (`www-data`).

## Jobs

### Scheduled Tasks Job

Runs hourly via Cloud Scheduler:

```bash
gcloud run jobs execute icat-pkp-ojs-scheduled --region=us-central1
```

### Upgrade Job

Run manually when upgrading OJS versions:

```bash
gcloud run jobs execute icat-pkp-ojs-upgrade --region=us-central1 --wait
```

### Automate Transition Job

This one-off job transitions submissions from copyediting (Stage 4) back to a new external review round (Stage 3, Round 2). It was created to support a bulk workflow correction and **suppresses all email notifications**.

See [`containers/tools/README.md`](../containers/tools/README.md) for details on what the script does and how it works.

```bash
# Dry run - show what would be done without making changes
gcloud run jobs execute icat-pkp-ojs-automate-transition --region=us-central1 --args="--dry-run" --wait

# Execute for real
gcloud run jobs execute icat-pkp-ojs-automate-transition --region=us-central1 --wait
```

### Automate Request Revisions Job

This one-off job sets the decision to "Request Revisions" for submissions in **External Review Round 2**, ensuring revisions are not subject to a new peer review round, and **suppresses all email notifications**.

See [`containers/tools/README.md`](../containers/tools/README.md) for details.

```bash
# Dry run
gcloud run jobs execute icat-pkp-ojs-automate-revisions --region=us-central1 --args="--dry-run" --wait

# Execute for real
gcloud run jobs execute icat-pkp-ojs-automate-revisions --region=us-central1 --wait
```


## Upgrading OJS

The currently used version of OJS is specified in `tf/prod/main.tf` under the `PKP_VERSION` variable.

> **NOTE Version 3.5.0-2 has a bug in the reviewer search -- see <https://github.com/pkp/pkp-lib/issues/12100#issuecomment-3614365262>; this we have patched this bug in our custom container image. If updating from version 3.5.0-2, check whether this patch is necessary any longer.**

To upgrade OJS (e.g., from 3.3 to 3.5):

1. **Backup the database**:

   ```bash
   gcloud sql export sql pkp-ojs gs://icat-pkp-ojs-manualbackup/backup-$(date +%Y%m%d-%H%M%S).sql \
     --database=icat
   ```

2. **Backup private files** (if needed):

   ```bash
   gcloud storage rsync -r gs://icat-pkp-ojs-private gs://backup-bucket/private-backup-$(date +%Y%m%d)
   ```

3. **Update the version** in `tf/prod/main.tf`:

   ```hcl
   PKP_VERSION = "3_5_0-2"
   ```

4. **Apply the changes**:

   ```bash
   tofu apply
   ```

5. **Run the upgrade job**:

   ```bash
   gcloud run jobs execute icat-pkp-ojs-upgrade --region=us-central1 --wait
   ```

6. **Verify** the site is working:

   ```bash
   curl -I https://conference-submissions.appropriatetech.net
   ```

For an example of detailed rollback instructions, see `ROLLBACK_3.5_3.3.md`.

## Troubleshooting

### Check Service Logs

```bash
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=icat-pkp-ojs" \
  --limit=50 --format="table(timestamp, textPayload)"
```

### Check Apache Error Logs

```bash
gcloud storage cat gs://icat-pkp-ojs-logs/error.log | tail -20
```

### Access Database Directly

```bash
gcloud sql connect pkp-ojs --user=icat --database=icat
```

### Connect to a Shell in the Image (e.g. to inspect the filesystem structure)

```bash
# For docker:
gcloud auth configure-docker us-central1-docker.pkg.dev
docker run -it --entrypoint /bin/bash us-central1-docker.pkg.dev/inat-359418/cloud-run-source-deploy/icat-pkp-ojs:latest

# For podman:
gcloud auth print-access-token | podman login -u oauth2accesstoken --password-stdin us-central1-docker.pkg.dev
podman run -it --entrypoint /bin/bash us-central1-docker.pkg.dev/inat-359418/cloud-run-source-deploy/icat-pkp-ojs:latest
```

### Force Service Restart

```bash
gcloud run services update icat-pkp-ojs --region=us-central1 \
  --update-env-vars="FORCE_RELOAD=$(date +%s)"
```

### 404 Errors on Pretty URLs

If you see 404 errors on routes like `/index/install`, verify the `.htaccess` file is correctly mounted. The `apache.htaccess` file from the config bucket should be symlinked to `/var/www/html/.htaccess` by the container entrypoint script. You can check this by deploying the service and then using the Cloud Run console to open a terminal session in the running container. From there, you can check if the file exists:

```bash
ls -la /var/www/html/.htaccess
```

### Database Connection Issues

Ensure the Cloud Run service has the correct Cloud SQL instance connection configured and the service account has the `roles/cloudsql.client` permission.

## Infrastructure Components

The Terraform configuration in `tf/prod/main.tf` manages:

- **Service Account** (`pkp-ojs-sa`): With minimal required permissions
- **Cloud SQL Instance** (`pkp-ojs`): MySQL 8.4 with automated backups
- **Artifact Registry** (`cloud-run-source-deploy`): Container image repository
- **Cloud Run Service** (`icat-pkp-ojs`): The web application
- **Cloud Run Jobs**: For scheduled tasks and upgrades
- **Secret Manager Secrets**: All sensitive configuration
- **Cloud Scheduler Job**: Triggers scheduled tasks hourly

All resources are created in the `us-central1` region.
