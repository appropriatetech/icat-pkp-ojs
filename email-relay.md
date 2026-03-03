# Throttling Email Relay on Google Cloud Run

## Issue

Using GMail's relay directly will only allow us to send a limited number of emails per minute (burst limit). This limit is undocumented but causing "421 4.7.0" temporary rejection errors. In order to send bulk emails reliably, we need to throttle our sending.

## Solution

We will implement a custom "store-and-forward" mechanism. OJS will hand off emails to a local script (storage), and a scheduled background job will send them slowly in batches (forward).

## Design

*   **Enqueue Script (Sendmail Replacement):** A Python script that mimics the `sendmail` interface. OJS is configured to use this script via `sendmail_path`. It reads the email from `stdin`, parses it, inserts it into the MySQL database queue, and **immediately calls `send_batch()`** to attempt delivery without waiting for the scheduled job. **Note:** The script accepts `-t` and `-oi` flags to satisfy Symfony Mailer validation requirements.
*   **Background Job (Sender):** A Cloud Run Job that pulls a batch of emails (limit 10) from the MySQL queue and sends them using the Gmail SMTP relay. It will handle retries, success marking, and logging. This also runs as a safety net for any emails not sent inline by enqueue.
*   **Background Job (Pruner):** A Cloud Run Job to prune old/completed entries from the queue.
*   **Scheduler:** Cloud Scheduler triggers the Sender job every 5 minutes and the Pruner every hour.

## Implementation

*   **Language:** Python 3 using `SQLAlchemy` for database abstraction.
*   **Location:** `inat-pkp-ojs/email-relay/`
*   **Components:**
    *   `enqueue.py`: The sendmail-compatible script. Enqueues and immediately sends.
    *   `send_batch.py`: The batch worker.
    *   `prune_queue.py`: The queue pruner (deletes old jobs).
    *   `database.py`: Shared database connection logic.
    *   `subprocess_logging.py`: Shared logging configuration that routes logs to Cloud Logging even when invoked as a subprocess inside the Apache/OJS container.
    *   `schema.sql`: MySQL table definition.
*   **Queue Platform:** MySQL table `email_queue` in a separate `email_relay` database on the same Cloud SQL instance.
    *   Columns: `id`, `created_at`, `status` (pending, sent, failed), `attempt_count`, `last_attempt_at`, `error_message`, `sender`, `recipients`, `body` (blob).
*   **Logging:** All components log to Google Cloud Logging via `subprocess_logging.py`. When running as a subprocess (inside Apache), logs are routed to `/proc/1/fd/2` to bypass Symfony's pipe capture.
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
*   **Batch Size:** 10 emails per run.
*   **Schedule:** Every 5 minutes (send), hourly (prune).
*   **OJS Config:** `config.inc.php` sets `default = sendmail` and `sendmail_path = "python3 /opt/email-relay/enqueue.py -t -oi"`.

## Deployment

Use OpenTofu to manage the infrastructure (Cloud Run Jobs, Scheduler, Permissions).
*   Bundle the scripts into the existing OJS container image.
