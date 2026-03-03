# Email Relay

A store-and-forward email relay for OJS. Instead of sending emails directly via SMTP (which frequently fails due to Gmail rate limiting), OJS hands emails to an **enqueue** script that stores them in a MySQL database. The enqueue script immediately attempts to send via `send_batch()`. A separate scheduled **send_batch** job acts as a safety net for any emails not sent inline. A **prune_queue** job cleans up old entries.

## Architecture

```
┌─────────┐    sendmail_path     ┌────────────┐      MySQL       ┌──────────────┐
│   OJS   │ ──────────────────── │ enqueue.py │ ───────────────► │ email_queue  │
│ (PHP)   │                      └─────┬──────┘                  │   table      │
└─────────┘                            │                         └──────┬───────┘
                                       │ calls send_batch()             │
                                       │ immediately                    │
                                       ▼                                │
                     ┌──────────────────┐     SMTP                      │
                     │ smtp-relay.      │ ◄──────────── ┌───────────────┤
                     │ gmail.com:587    │               │ send_batch.py │ (also Cloud Run Job, every 5 min)
                     └──────────────────┘               └───────────────┘
                                                                        │
                                                        ┌───────────────┤
                                                        │ prune_queue.py│ (Cloud Run Job, hourly)
                                                        └───────────────┘
```

## Components

### `enqueue.py`

Called by OJS as a `sendmail` replacement. Reads a raw RFC 822 email message from stdin, extracts the sender and recipients from the headers, inserts a row into the `email_queue` table with status `pending`, and **immediately calls `send_batch()`** to attempt delivery without waiting for the scheduled job.

**Usage in OJS `config.inc.php`:**

```ini
[email]
default = sendmail
sendmail_path = "python3 /opt/email-relay/enqueue.py -t -oi"
```

**Environment variables:**

| Variable | Default | Description |
|---|---|---|
| `EMAIL_RELAY_DB_USER` | `ojs` | MySQL username |
| `EMAIL_RELAY_DB_PASSWORD` | `ojs` | MySQL password |
| `EMAIL_RELAY_DB_HOST` | `localhost` | MySQL host or Unix socket path (e.g., `/cloudsql/project:region:instance`) |
| `EMAIL_RELAY_DB_PORT` | `3306` | MySQL port (ignored when `EMAIL_RELAY_DB_HOST` is a socket) |
| `EMAIL_RELAY_DB_NAME` | `email_relay` | MySQL database name |

### `send_batch.py`

Fetches up to `BATCH_SIZE` (default 10) pending emails from the queue, connects to the SMTP server, and sends them one at a time. Updates each row's status to `sent` on success, or increments `attempt_count` on failure. After `MAX_ATTEMPTS` (default 3) failures, the status is set to `failed`.

This runs both inline (called by `enqueue.py` immediately after queuing) and as a scheduled Cloud Run Job every 5 minutes as a safety net.

**Environment variables** (in addition to `EMAIL_RELAY_DB_*` above):

| Variable | Default | Description |
|---|---|---|
| `EMAIL_RELAY_SMTP_HOST` | `smtp-relay.gmail.com` | SMTP server hostname |
| `EMAIL_RELAY_SMTP_PORT` | `587` | SMTP server port |
| `EMAIL_RELAY_SMTP_USER` | *(none)* | SMTP username |
| `EMAIL_RELAY_SMTP_PASSWORD` | *(none)* | SMTP password |
| `BATCH_SIZE` | `10` | Max emails per batch |
| `MAX_ATTEMPTS` | `3` | Max retry attempts before marking as `failed` |
| `EMAIL_RELAY_SMTP_LOCAL_HOSTNAME` | *(auto)* | EHLO hostname override |

### `prune_queue.py`

Removes old entries from the queue:
- **Sent** emails older than 30 days
- **Failed** emails older than 7 days

### `database.py`

Shared module providing the SQLAlchemy `MetaData`, `email_queue` table definition, and connection helpers (`get_engine()`, `get_session()`).

Supports both TCP connections (`EMAIL_RELAY_DB_HOST=hostname`) and Cloud SQL Unix sockets (`EMAIL_RELAY_DB_HOST=/cloudsql/project:region:instance`).

### `subprocess_logging.py`

Shared logging configuration. When running as a Cloud Run job (Python is PID 1), logs go to stderr normally. When running as a subprocess inside the OJS container (invoked by Symfony's `proc_open`), logs are routed to `/proc/1/fd/2` (the container entrypoint's stderr) to reach Cloud Logging.

## Database

The relay uses a separate MySQL database named `email_relay` on the same Cloud SQL instance as OJS. The schema is a single `email_queue` table:

| Column | Type | Description |
|---|---|---|
| `id` | `INT AUTO_INCREMENT` | Primary key |
| `created_at` | `TIMESTAMP` | Row creation time |
| `status` | `ENUM('pending','sent','failed')` | Current delivery status |
| `attempt_count` | `INT` | Number of send attempts |
| `last_attempt_at` | `TIMESTAMP` | Time of last send attempt |
| `error_message` | `TEXT` | Last error message (if any) |
| `sender` | `VARCHAR(255)` | Envelope sender |
| `recipients` | `TEXT` | Comma-separated recipient addresses |
| `body` | `LONGBLOB` | Raw RFC 822 email content |

An index on `(status, created_at)` optimizes the `send_batch` query.

## Migrations

Managed with [Alembic](https://alembic.sqlalchemy.org/). Migration files live in `alembic/versions/`.

### Running against production

The Cloud SQL instance is on a private VPC, so migrations are run via a Cloud Run Job that has VPC access:

```bash
# Apply any OpenTofu changes first (if the job definition changed)
cd tf/prod && tofu apply

# Run migrations
gcloud run jobs execute icat-pkp-ojs-email-relay-migrate \
  --region=us-central1 \
  --project=inat-359418 \
  --wait
```

The job runs `alembic upgrade head` inside the container at `/opt/email-relay/`.

### Common commands

```bash
# Run all pending migrations
alembic upgrade head

# Create a new migration (auto-detect changes from database.py metadata)
alembic revision --autogenerate -m "description"

# Show current migration status
alembic current
```

## Deployment

The relay runs on Google Cloud Run as two scheduled jobs:

| Job | Schedule | Purpose |
|---|---|---|
| `icat-pkp-ojs-email-send` | Every 5 minutes | Send pending emails (safety net) |
| `icat-pkp-ojs-email-prune` | Hourly | Clean up old queue entries |

Both jobs are defined in Terraform (`tf/prod/main.tf`) and triggered by Cloud Scheduler.

## Testing

```bash
cd email-relay
python3 -m venv .venv
.venv/bin/pip install pytest sqlalchemy click
.venv/bin/pytest tests/ -v
```

Tests use SQLite in-memory and mock SMTP to test enqueue, send (success/failure/retry), and prune logic.
