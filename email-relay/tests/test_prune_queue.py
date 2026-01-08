import datetime
from sqlalchemy import select
from database import email_queue
from prune_queue import prune_queue

def test_prune_queue(session):
    now = datetime.datetime.now()
    old_sent = now - datetime.timedelta(days=31)
    recent_sent = now - datetime.timedelta(days=1)
    old_failed = now - datetime.timedelta(days=8)
    recent_failed = now - datetime.timedelta(days=2)

    # Helper to insert with created_at (since default is now())
    def insert(status, dt):
        session.execute(email_queue.insert().values(
           sender='s', recipients='r', body=b'b', status=status, created_at=dt
        ))

    insert('sent', old_sent)    # Should be pruned
    insert('sent', recent_sent) # Should keep
    insert('failed', old_failed)# Should be pruned
    insert('failed', recent_failed) # Should keep
    session.commit()

    prune_queue()

    rows = session.execute(select(email_queue)).fetchall()
    assert len(rows) == 2
    statuses = [r.status for r in rows]
    assert 'sent' in statuses # recent_sent
    assert 'failed' in statuses # recent_failed
