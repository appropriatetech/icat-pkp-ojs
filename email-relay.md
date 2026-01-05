# Throttling Email Relay on Google Cloud Run

## Issue

Using GMail's relay directly will only allow us to send a limited number of emails per minute (burst limit). This limit is undocumented but causing "421 4.7.0" temporary rejection errors. In order to send bulk emails reliably, we need to throttle our sending.

## Solution

We will implement a custom "store-and-forward" mechanism. OJS will hand off emails to a local script (storage), and a scheduled background job will send them slowly in batches (forward).

## Design

*   **Enqueue Script (Sendmail Replacement):** A simple Python script that mimics the `sendmail` interface. OJS will be configured to use this script. It will read the email from `stdin`, parse it, and insert it into the MySQL database queue. **Note:** The script MUST accept `-bs` or `-t` flags (even if ignored) to satisfy Symfony Mailer validation requirements.
*   **Background Job (Sender):** A Cloud Run Job that pulls a batch of emails (limit 50) from the MySQL queue and sends them using the Gmail SMTP relay. It will handle retries, success marking, and logging.
*   **Background Job (Pruner):** A Cloud Run Job or function to prune old/completed entries from the queue.
*   **Scheduler:** Cloud Scheduler triggers the Sender job every 5 minutes and the Pruner every hour.

## Implementation

*   **Language:** Python 3 using `SQLAlchemy` for database abstraction.
*   **Location:** `inat-pkp-ojs/email-relay/`
*   **Components:**
    *   `enqueue.py`: The sendmail-compatible script.
    *   `send_batch.py`: The batch worker.
    *   `prune_queue.py`: The queue pruner (deletes old jobs).
    *   `database.py`: Shared database connection logic.
    *   `schema.sql`: MySQL table definition.
*   **Queue Platform:** MySQL table `email_queue` in the existing OJS database.
    *   Columns: `id`, `created_at`, `status` (pending, sent, failed), `attempt_count`, `last_attempt_at`, `error_message`, `sender`, `recipients`, `body` (blob).
*   **Logging:** All components log to Google Cloud Logging.
*   **Secrets:** SMTP credentials accessed via Google Secret Manager.

## Testing

*   **Framework:** `pytest` for automated unit and integration tests.
*   **Storage:** `SQLite` (in-memory) used for tests to avoid external dependencies.
*   **Validation:** Tests will cover:
    *   Enqueuing parsing and insertion.
    *   Batch selection logic (limits, retry counts).
    *   Pruning logic (date thresholds).
    *   SMTP sending (mocked).

## Configuration
*   **Batch Size:** 50 emails per run.
*   **Schedule:** Every 5 minutes.
*   **OJS Config:** Update `config.inc.php` to set `sendmail_path` to the path of our new script.

## Deployment

Use OpenTofu to manage the infrastructure (Cloud Run Jobs, Scheduler, Permissions).
*   Bundle the scripts into the existing OJS container image.
