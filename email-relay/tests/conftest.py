import sys
import os
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, scoped_session

# Add parent dir to sys.path to import modules
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from database import metadata, get_session

@pytest.fixture(scope='session')
def engine():
    return create_engine('sqlite:///:memory:')

@pytest.fixture(scope='session')
def tables(engine):
    metadata.create_all(engine)
    yield
    metadata.drop_all(engine)

@pytest.fixture
def session(engine, tables):
    """Returns an sqlalchemy session, and after the test tears down everything properly."""
    connection = engine.connect()
    # begin the nested transaction
    transaction = connection.begin()

    # use the connection with the already started transaction
    Session = sessionmaker(bind=connection)
    session = Session()

    yield session

    session.close()
    # roll back the broader transaction
    transaction.rollback()
    connection.close()

# Mock get_engine/get_session in the modules to use our test engine/session
@pytest.fixture(autouse=True)
def mock_db_connection(monkeypatch, engine, session):
    import database
    monkeypatch.setattr(database, 'get_engine', lambda db_url=None: engine)

    # We need to monkeypatch get_session to return a factory that gives our scoped session
    # OR simpler: check how scripts use it.
    # Scripts do: Session = get_session(engine); session = Session()
    # We want Session() to return our fixture session.

    FakeSession = lambda: session
    monkeypatch.setattr(database, 'get_session', lambda e: FakeSession)
