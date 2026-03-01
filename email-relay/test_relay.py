"""
Integration test for the email relay pipeline.

Exercises the full flow: enqueue → send_batch → verify → prune → verify.
Designed to run as a Cloud Run Job with detailed logging for verification.

Required environment variables:
  TEST_SENDER     - email address to use as the sender
  TEST_RECIPIENT  - email address to use as the recipient
  DB_HOST, DB_NAME, DB_USER, DB_PASSWORD - database connection
  SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD - SMTP connection
"""

import contextlib
import datetime
import logging
import os
import subprocess
import sys

from sqlalchemy import select, delete

import database

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
)
logger = logging.getLogger(__name__)


def times_within(t1, t2, threshold_seconds=30):
    """Check whether two datetimes are within a threshold of each other."""
    # Handle naive vs aware datetimes by comparing without tzinfo
    if t1.tzinfo is not None:
        t1 = t1.replace(tzinfo=None)
    if t2.tzinfo is not None:
        t2 = t2.replace(tzinfo=None)
    return abs((t1 - t2).total_seconds()) <= threshold_seconds


def log_queue_state(session, label):
    """Log the current state of the email_queue table."""
    result = session.execute(
        select(
            database.email_queue.c.id,
            database.email_queue.c.status,
            database.email_queue.c.attempt_count,
            database.email_queue.c.sender,
            database.email_queue.c.recipients,
            database.email_queue.c.error_message,
            database.email_queue.c.created_at,
        )
        .order_by(database.email_queue.c.id)
    )
    rows = result.fetchall()
    logger.info(f"=== {label}: {len(rows)} row(s) in email_queue ===")
    for row in rows:
        logger.info(
            f"  id={row.id} status={row.status} attempts={row.attempt_count} "
            f"sender={row.sender} recipients={row.recipients} "
            f"error={row.error_message!r} created_at={row.created_at}"
        )
    if not rows:
        logger.info("  (empty)")
    return rows


def make_test_email(subject, sender, recipient):
    """Generate a raw RFC 822 test email."""
    return (
        f"From: {sender}\r\n"
        f"To: {recipient}\r\n"
        f"Subject: {subject}\r\n"
        f"Content-Type: text/plain\r\n"
        f"\r\n"
        f"This is an automated integration test email.\r\n"
        f"Generated at {datetime.datetime.now().isoformat()}\r\n"
    ).encode('utf-8')


def run_script(script_name, stdin_data=None, extra_args=None):
    """Run one of the relay scripts via subprocess, like production does."""
    cmd = [sys.executable, os.path.join(SCRIPT_DIR, script_name)]
    if extra_args:
        cmd.extend(extra_args)

    logger.info(f"  Running: {' '.join(cmd)}")
    result = subprocess.run(
        cmd,
        input=stdin_data,
        capture_output=True,
        timeout=60,
    )

    if result.stdout:
        for line in result.stdout.decode('utf-8', errors='replace').strip().splitlines():
            logger.info(f"  [stdout] {line}")
    if result.stderr:
        for line in result.stderr.decode('utf-8', errors='replace').strip().splitlines():
            logger.info(f"  [stderr] {line}")

    if result.returncode != 0:
        logger.error(f"  Script {script_name} exited with code {result.returncode}")
    return result


def run_test():
    test_sender = os.environ.get('TEST_SENDER')
    test_recipient = os.environ.get('TEST_RECIPIENT')

    if not test_sender or not test_recipient:
        logger.error(
            "TEST_SENDER and TEST_RECIPIENT environment variables are required. "
            f"Got TEST_SENDER={test_sender!r}, TEST_RECIPIENT={test_recipient!r}"
        )
        return 1

    failures = 0
    num_test_emails = 3

    logger.info("=" * 60)
    logger.info("EMAIL RELAY INTEGRATION TEST")
    logger.info(f"  sender:    {test_sender}")
    logger.info(f"  recipient: {test_recipient}")
    logger.info("=" * 60)

    engine = database.get_engine()
    Session = database.get_session(engine)

    @contextlib.contextmanager
    def fresh_session():
        """Create a fresh session to avoid stale reads from REPEATABLE READ."""
        session = Session()
        try:
            yield session
        except Exception:
            session.rollback()
            raise
        finally:
            session.close()

    try:
        # --- Step 0: Check initial state ---
        with fresh_session() as session:
            log_queue_state(session, "Initial state")

        # --- Step 1: Enqueue test emails ---
        logger.info("")
        logger.info("--- Step 1: Enqueuing test emails ---")

        enqueue_time = datetime.datetime.now()

        for i in range(num_test_emails):
            raw = make_test_email(
                subject=f"Relay integration test #{i+1}",
                sender=test_sender,
                recipient=test_recipient,
            )
            result = run_script(
                'enqueue.py',
                stdin_data=raw,
                extra_args=['-f', test_sender, test_recipient],
            )
            if result.returncode != 0:
                logger.error(f"  ✗ FAIL: enqueue.py returned non-zero for email #{i+1}")
                failures += 1
            else:
                logger.info(f"  Enqueued test email #{i+1}")

        # Fresh session to see subprocess commits
        with fresh_session() as session:
            rows = log_queue_state(session, "After enqueue")

            # Verify: should have at least num_test_emails pending rows from our sender
            test_rows = [r for r in rows if r.sender == test_sender and r.status == 'pending']
            if len(test_rows) >= num_test_emails:
                logger.info(f"  ✓ PASS: Found {len(test_rows)} pending emails from test sender")
            else:
                logger.error(f"  ✗ FAIL: Expected at least {num_test_emails} pending, got {len(test_rows)}")
                failures += 1

            # Verify: created_at times should be close to enqueue_time
            for row in test_rows:
                if times_within(row.created_at, enqueue_time, threshold_seconds=30):
                    logger.info(
                        f"  ✓ PASS: id={row.id} created_at={row.created_at} "
                        f"is within 30s of enqueue_time={enqueue_time}"
                    )
                else:
                    logger.error(
                        f"  ✗ FAIL: id={row.id} created_at={row.created_at} "
                        f"is NOT within 30s of enqueue_time={enqueue_time}"
                    )
                    failures += 1

        # --- Step 2: Run send_batch ---
        logger.info("")
        logger.info("--- Step 2: Running send_batch ---")

        run_script('send_batch.py')

        # Fresh session to see subprocess commits
        with fresh_session() as session:
            rows = log_queue_state(session, "After send_batch")

            # Verify: test rows should no longer be pending with 0 attempts
            still_untouched = [
                r for r in rows
                if r.sender == test_sender
                and r.status == 'pending'
                and r.attempt_count == 0
            ]
            if len(still_untouched) == 0:
                logger.info("  ✓ PASS: All test emails were processed (no untouched pending rows)")
            else:
                logger.error(f"  ✗ FAIL: {len(still_untouched)} test emails were not processed")
                failures += 1

            sent = [r for r in rows if r.status == 'sent' and r.sender == test_sender]
            not_sent = [r for r in rows if r.status != 'sent' and r.sender == test_sender]
            logger.info(f"  Results: {len(sent)} sent, {len(not_sent)} failed/retrying")

            if len(sent) == num_test_emails:
                logger.info(f"  ✓ PASS: All {num_test_emails} test emails were sent successfully")
            else:
                logger.warning(
                    f"  ⚠ WARNING: Only {len(sent)}/{num_test_emails} sent successfully. "
                    "Check SMTP configuration if this is unexpected."
                )

        # --- Step 3: Run prune_queue ---
        logger.info("")
        logger.info("--- Step 3: Running prune_queue ---")
        logger.info("  (Prune removes sent >30d and failed >7d; test emails are fresh,")
        logger.info("   so they should NOT be pruned)")

        run_script('prune_queue.py')

        # Fresh session to see subprocess commits
        with fresh_session() as session:
            rows = log_queue_state(session, "After prune_queue")

            test_rows = [r for r in rows if r.sender == test_sender]
            if len(test_rows) >= num_test_emails:
                logger.info(f"  ✓ PASS: Fresh test emails were correctly retained ({len(test_rows)} rows)")
            else:
                logger.error(f"  ✗ FAIL: Expected at least {num_test_emails} test rows retained, got {len(test_rows)}")
                failures += 1

        # --- Step 4: Clean up test data ---
        logger.info("")
        logger.info("--- Step 4: Cleaning up test data ---")
        with fresh_session() as session:
            cleanup = delete(database.email_queue).where(
                database.email_queue.c.sender == test_sender
            )
            result = session.execute(cleanup)
            session.commit()
            logger.info(f"  Deleted {result.rowcount} test rows")

            log_queue_state(session, "Final state (after cleanup)")

    except Exception as e:
        logger.critical(f"Test aborted with exception: {e}", exc_info=True)
        failures += 1

    # --- Summary ---
    logger.info("")
    logger.info("=" * 60)
    if failures == 0:
        logger.info("RESULT: ALL CHECKS PASSED ✓")
    else:
        logger.error(f"RESULT: {failures} CHECK(S) FAILED ✗")
    logger.info("=" * 60)

    return failures


if __name__ == "__main__":
    failures = run_test()
    sys.exit(1 if failures > 0 else 0)
