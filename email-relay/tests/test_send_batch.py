import datetime
from unittest.mock import MagicMock, patch
from sqlalchemy import select, func
from database import email_queue
from send_batch import send_batch

def test_send_batch_success(session):
    # Insert pending email
    session.execute(email_queue.insert().values(
        sender='s@ex.com', recipients='r@ex.com', body=b'test', status='pending'
    ))
    session.commit()

    with patch('smtplib.SMTP') as mock_smtp:
        mock_server = MagicMock()
        mock_smtp.return_value.__enter__.return_value = mock_server

        send_batch()

        # Verify SMTP interaction
        mock_server.sendmail.assert_called_once()
        args = mock_server.sendmail.call_args[0]
        assert args[0] == 's@ex.com'
        assert args[1] == ['r@ex.com']
        assert args[2] == b'test'

        # Verify DB status
        row = session.execute(select(email_queue)).fetchone()
        assert row.status == 'sent'
        assert row.last_attempt_at is not None

def test_send_batch_failure_retry(session):
    session.execute(email_queue.insert().values(
        sender='s@ex.com', recipients='r@ex.com', body=b'test', status='pending', attempt_count=0
    ))
    session.commit()

    with patch('smtplib.SMTP') as mock_smtp:
        mock_server = MagicMock()
        mock_smtp.return_value.__enter__.return_value = mock_server
        mock_server.sendmail.side_effect = Exception("SMTP Error")

        send_batch()

        row = session.execute(select(email_queue)).fetchone()
        assert row.status == 'pending' # Still pending retry
        assert row.attempt_count == 1
        assert "SMTP Error" in row.error_message

def test_send_batch_max_attempts(session):
    # attempt_count 2, max is 3. Fails again -> attempt 3 -> should fail
    session.execute(email_queue.insert().values(
        sender='s@ex.com', recipients='r@ex.com', body=b'test', status='pending', attempt_count=2
    ))
    session.commit()

    with patch('smtplib.SMTP') as mock_smtp:
        mock_server = MagicMock()
        mock_smtp.return_value.__enter__.return_value = mock_server
        mock_server.sendmail.side_effect = Exception("Final Error")

        send_batch()

        row = session.execute(select(email_queue)).fetchone()
        assert row.status == 'failed'
        assert row.attempt_count == 3
