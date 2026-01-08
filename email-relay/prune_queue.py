import logging
import datetime
from sqlalchemy import delete
import database

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def prune_queue():
    engine = database.get_engine()
    Session = database.get_session(engine)
    session = Session()

    try:
        # Calculate thresholds using Python datetime for cross-db compatibility
        now = datetime.datetime.now()
        thirty_days_ago = now - datetime.timedelta(days=30)
        seven_days_ago = now - datetime.timedelta(days=7)

        # Prune sent emails older than 30 days
        stmt_sent = (
            delete(database.email_queue)
            .where(database.email_queue.c.status == 'sent')
            .where(database.email_queue.c.created_at < thirty_days_ago)
        )
        result_sent = session.execute(stmt_sent)
        logger.info(f"Pruned {result_sent.rowcount} sent emails older than 30 days.")

        # Prune failed emails older than 7 days
        stmt_failed = (
            delete(database.email_queue)
            .where(database.email_queue.c.status == 'failed')
            .where(database.email_queue.c.created_at < seven_days_ago)
        )
        result_failed = session.execute(stmt_failed)
        logger.info(f"Pruned {result_failed.rowcount} failed emails older than 7 days.")

        session.commit()

    except Exception as e:
        logger.error(f"Error pruning email queue: {e}")
        session.rollback()
    finally:
        session.close()

if __name__ == "__main__":
    prune_queue()
