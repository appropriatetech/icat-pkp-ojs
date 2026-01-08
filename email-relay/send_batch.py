import os
import smtplib
import logging
from sqlalchemy import select, update, func, case
import database

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

BATCH_SIZE = 10
MAX_ATTEMPTS = 3

def send_batch():
    engine = database.get_engine()
    Session = database.get_session(engine)
    session = Session()

    # Get SMTP credentials
    smtp_host = os.environ.get('SMTP_HOST', 'smtp-relay.gmail.com')
    smtp_port = int(os.environ.get('SMTP_PORT', 587))
    smtp_user = os.environ.get('SMTP_USER')
    smtp_pass = os.environ.get('SMTP_PASSWORD')

    try:
        # Construct Select Statement
        stmt = (
            select(database.email_queue.c.id, database.email_queue.c.body, database.email_queue.c.sender, database.email_queue.c.recipients, database.email_queue.c.attempt_count)
            .where(database.email_queue.c.status == 'pending')
            .where(database.email_queue.c.attempt_count < MAX_ATTEMPTS)
            .order_by(database.email_queue.c.created_at.asc())
            .limit(BATCH_SIZE)
        )

        # Add SKIP LOCKED only for MySQL to support concurrent workers safely.
        # Check dialect name from engine.
        if engine.dialect.name == 'mysql':
            stmt = stmt.with_for_update(skip_locked=True)

        result = session.execute(stmt)
        emails = result.fetchall()

        if not emails:
            logger.info("No pending emails to process.")
            session.commit()
            return

        logger.info(f"Processing batch of {len(emails)} emails.")

        # Connect to SMTP server
        try:
            with smtplib.SMTP(smtp_host, smtp_port) as server:
                server.starttls()
                if smtp_user and smtp_pass:
                    server.login(smtp_user, smtp_pass)

                for email_row in emails:
                    try:
                        # Send email
                        to_addrs = [r.strip() for r in email_row.recipients.split(',') if r.strip()]

                        server.sendmail(email_row.sender, to_addrs, email_row.body)

                        # Mark as sent
                        upd = (
                            update(database.email_queue)
                            .where(database.email_queue.c.id == email_row.id)
                            .values(status='sent', last_attempt_at=func.now())
                        )
                        session.execute(upd)
                        logger.info(f"Sent email ID {email_row.id}")

                    except Exception as e:
                        logger.error(f"Failed to send email ID {email_row.id}: {e}")
                        # Mark attempt and failure
                        error_msg = str(e)[:65000]

                        # Calculate status: if attempt_count + 1 >= MAX_ATTEMPTS -> 'failed' else 'pending'
                        new_attempt_count = email_row.attempt_count + 1
                        new_status = 'failed' if new_attempt_count >= MAX_ATTEMPTS else 'pending'

                        upd = (
                            update(database.email_queue)
                            .where(database.email_queue.c.id == email_row.id)
                            .values(
                                attempt_count=database.email_queue.c.attempt_count + 1,
                                last_attempt_at=func.now(),
                                error_message=error_msg,
                                status=new_status
                            )
                        )
                        session.execute(upd)
        except Exception as e:
             logger.error(f"Failed to connect to SMTP server: {e}")
             raise e

        session.commit()

    except Exception as e:
        logger.critical(f"Critical error in batch processing: {e}")
        session.rollback()
    finally:
        session.close()

if __name__ == "__main__":
    send_batch()
