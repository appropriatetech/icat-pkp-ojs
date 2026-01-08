import os
from sqlalchemy import create_engine, MetaData, Table, Column, Integer, String, Text, LargeBinary, TIMESTAMP, Enum, func
from sqlalchemy.orm import sessionmaker, scoped_session

metadata = MetaData()

email_queue = Table('email_queue', metadata,
    Column('id', Integer, primary_key=True, autoincrement=True),
    Column('created_at', TIMESTAMP, server_default=func.now()),
    Column('status', Enum('pending', 'sent', 'failed'), server_default='pending'),
    Column('attempt_count', Integer, server_default='0'),
    Column('last_attempt_at', TIMESTAMP),
    Column('error_message', Text),
    Column('sender', String(255), nullable=False),
    Column('recipients', Text, nullable=False),
    Column('body', LargeBinary, nullable=False)
)

def get_engine(db_url=None):
    if db_url is None:
        # Construct DB URL from environment variables for MySQL
        # Format: mysql+mysqlconnector://user:password@host:port/database
        user = os.environ.get('DB_USER', 'ojs')
        password = os.environ.get('DB_PASSWORD', 'ojs')
        host = os.environ.get('DB_HOST', 'localhost')
        port = os.environ.get('DB_PORT', '3306')
        name = os.environ.get('DB_NAME', 'ojs')
        db_url = f"mysql+mysqlconnector://{user}:{password}@{host}:{port}/{name}"

    return create_engine(db_url, pool_recycle=3600)

def get_session(engine):
    session_factory = sessionmaker(bind=engine)
    return scoped_session(session_factory)
