import io
import sys
from sqlalchemy import select
import pytest
from database import email_queue
from enqueue import enqueue_email

def test_enqueue_success_headers_only(session, monkeypatch):
    import send_batch
    called = False
    def mock_send_batch():
        nonlocal called
        called = True
    monkeypatch.setattr(send_batch, 'send_batch', mock_send_batch)

    # Test default behavior: no args, parse from headers
    raw_email = b"From: header@example.com\r\nTo: header@example.com\r\nSubject: Test\r\n\r\nBody content"

    enqueue_email(raw_email, args_sender=None, args_recipients=None)

    stmt = select(email_queue)
    result = session.execute(stmt).fetchone()

    assert result is not None
    assert result.sender == 'header@example.com'
    assert result.recipients == 'header@example.com'
    assert result.body == raw_email
    assert result.status == 'pending'
    assert called

def test_enqueue_with_args_override(session, monkeypatch):
    import send_batch
    called = False
    def mock_send_batch():
        nonlocal called
        called = True
    monkeypatch.setattr(send_batch, 'send_batch', mock_send_batch)

    # Test args overriding headers

    raw_email = b"From: header@example.com\r\nTo: header@example.com\r\nSubject: Test\r\n\r\nBody content"

    args_sender = "flag@example.com"
    args_recipients = ["arg1@example.com", "arg2@example.com"]

    enqueue_email(raw_email, args_sender=args_sender, args_recipients=args_recipients)

    stmt = select(email_queue)
    result = session.execute(stmt).fetchone()

    assert result.sender == 'flag@example.com'
    assert "arg1@example.com" in result.recipients
    assert "arg2@example.com" in result.recipients
    assert "header@example.com" not in result.recipients
    assert called

def test_enqueue_multiple_recipients_headers(session, monkeypatch):
    import send_batch
    called = False
    def mock_send_batch():
        nonlocal called
        called = True
    monkeypatch.setattr(send_batch, 'send_batch', mock_send_batch)

    raw_email = b"From: me@ex.com\r\nTo: a@ex.com\r\nCc: b@ex.com, c@ex.com\r\n\r\nContent"

    enqueue_email(raw_email)

    stmt = select(email_queue)
    result = session.execute(stmt).fetchone()

    assert "a@ex.com" in result.recipients
    assert "b@ex.com" in result.recipients
    assert "c@ex.com" in result.recipients
    assert called
