import logging
import database

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def migrate():
    logger.info("Starting database migration for email relay...")
    engine = database.get_engine()

    # Create tables if they don't exist
    try:
        # metadata.create_all checks for existence before creating
        database.metadata.create_all(engine)
        logger.info("Successfully ensured 'email_queue' table exists.")
    except Exception as e:
        logger.critical(f"Failed to run migrations: {e}")
        raise e

if __name__ == "__main__":
    migrate()
