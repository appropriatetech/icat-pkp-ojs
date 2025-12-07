# Rollback Playbook: OJS 3.5 to 3.3

If the deployment fails or the application is broken, follow these steps in order.

## 1. Immediate Site Restoration (Fastest)

If the site is down, the quickest way to recover is to point Cloud Run back to the previous healthy revision, bypassing Terraform temporarily.

1. **List revisions** to find the one before your deployment (look for the timestamp):

    ```bash
    gcloud run services list-revisions icat-pkp-ojs --region us-central1 --sort-by=~createTime
    ```

2. **Rollback traffic** to that revision (replace `REVISION_NAME` with the actual name, e.g., `icat-pkp-ojs-00012-xyz`):

    ```bash
    gcloud run services update-traffic icat-pkp-ojs --to-revisions=REVISION_NAME=100 --region us-central1
    ```

## 2. Infrastructure Code Rollback

To ensure your Terraform state matches the running environment (and to undo the configuration changes like the new `app_key` or `update` job):

1. **Revert the Git repository**:

    ```bash
    git checkout c7d4fe21b77176f7e814b0e58421df4cc3cc3a9f
    ```

2. **Apply the old infrastructure**:

    ```bash
    cd inat-pkp-ojs/tf/prod
    tofu init
    tofu apply
    ```

    *Note: If the previous Terraform code pointed to the `:latest` image tag, and your failed deployment overwrote `:latest`, you may need to manually find the previous image digest in Artifact Registry and update the `main.tf` to point to it before applying.*

## 3. Data Rollback (If Data was Corrupted)

Only perform these steps if the application update corrupted the database or deleted files.

**Database Restore:**

1. Go to the [Google Cloud Console > SQL > Instances](https://console.cloud.google.com/sql/instances/pkp-ojs/backups).
2. Select the **pkp-ojs** instance.
3. Go to the **Backups** tab.
4. Find the backup you created prior to deployment.
5. Click **Restore** and confirm the instance ID.

**File Restore:**

Restore the private files from your local backup to the GCS bucket.
*(Replace `$TS` with the timestamp folder name you created)*

```bash
# dry-run first to be safe
gcloud storage cp -r "icat-pkp-ojs-manualfilesbackup/$TS/*" gs://icat-pkp-ojs-private/ --dry-run

# execute restore (overwriting remote files)
gcloud storage cp -r "icat-pkp-ojs-manualfilesbackup/$TS/*" gs://icat-pkp-ojs-private/
```
