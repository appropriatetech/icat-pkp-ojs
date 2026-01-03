# Throttling Email Relay on Google Cloud Run

## Issue

Using GMail's relay directly will only allow us to send a limited number of emails per minute. This limit is undocumented in any public documentation, but seems to be affecting more than just us (e.g. <https://www.reddit.com/r/webhosting/comments/ndnolx/gsuite_smtp_limits_60_emails_per_minute_how_do_i/>). In order to send bulk emails, we need to use a different relay.

## Solution

We can set up a Cloud Run job that will send emails using the GMail relay, and then schedule it to run at regular intervals, sending emails slowly, in batches.

## Design

* **Web Service:** Will act as an SMTP server receiving emails to send and replying with a success message. Then the endpoint will enqueue the email(s) to be sent. _Thoughts: Maybe use the `from smtpd import SMTPServer` to create a custom SMTP server and override the `process_message` method to enqueue the email(s) to be sent._
* **Background Job:** Will pull a small batch of emails from the queue and send them using the GMail relay. It will attempt to process emails that are newer than some time threshold, haven't yet been processed, haven't yet succeeded, and haven't been tried some maximum number of times._Thoughts: Use `smtplib` to send the emails. Ensure that response codes are assiduously logged using the Python logging library, and that we configure the logs to be sent to GCP Cloud Logging._
* **Background Job:** Will clear emails from the queue that have been processed successfully, have been queued for longer than some time threshold, or have failed some maximum number of times.
* **Scheduler:** The scheduler that will run the jobs at regular intervals.

## Implementation

* **Language:** Python; rely on the standard library to the greatest extent possible, maybe with the exception of psycopg and a web server for the service
* **Web Server Platform:** Cloud Run Service (services/enqueue-email)
* **Background Job Platform:** Cloud Run Job (jobs/send-email-batch, jobs/prune-email-queue)
* **Scheduler Platform:** Cloud Scheduler
* **Queue Platform:** A database table with an auto-incrementing primary key, an enqueued timestamp, a processing timestamp, a count of how many times the email has tried to be processed, a success flag, an error message, and the email content.
* **Connectivity:** The web service should be accessible via a private IP or internal host name; there should be no need to expose it to the public internet.
* **Logging:** The web service and jobs should all log to Cloud Logging using Python's `logging` library.

## Deployment

Use OpenTofu to manage the infrastructure. Use same environment as tf/prod.
