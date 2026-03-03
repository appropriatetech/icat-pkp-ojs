import sys
import click
import database
import email
from email.policy import default
import subprocess_logging as log
import send_batch

log.setup_logging()
logger = log.get_logger(__name__)

def enqueue_email(raw_email, args_sender=None, args_recipients=None):
    # Parse the email
    msg = email.message_from_bytes(raw_email, policy=default)

    # Determine sender: value from -f flag takes precedence, otherwise From header
    sender = args_sender if args_sender else msg.get('From', '')

    # Determine recipients: arguments take precedence, otherwise To/Cc/Bcc headers
    if args_recipients:
        recipients = ', '.join(args_recipients)
    else:
        tos = msg.get_all('To', [])
        ccs = msg.get_all('Cc', [])
        bccs = msg.get_all('Bcc', [])
        recipients = ', '.join(tos + ccs + bccs)

    # Validation: if no recipients found, we can't send
    if not recipients:
        logger.warning("No recipients found in arguments or headers.")
        # Sendmail might exit 0 or error here, but for our relay we should probably accept it or warn.
        # But if we insert with empty recipients, send_batch might fail.
        # Let's insert anyway, send_batch will just skip or fail.
        pass

    engine = database.get_engine()
    Session = database.get_session(engine)
    session = Session()

    try:
        stmt = database.email_queue.insert().values(
            sender=sender[:255],
            recipients=recipients,
            body=raw_email,
            status='pending'
            # created_at handled by server_default
        )
        session.execute(stmt)
        session.commit()
    except Exception:
        session.rollback()
        logger.exception("Error enqueuing email")
        sys.exit(1)
    finally:
        session.close()

    # Immediately attempt to send the batch
    try:
        send_batch.send_batch()
    except Exception:
        logger.exception("Error during immediate send_batch trigger")


@click.command(context_settings={"ignore_unknown_options": True})
@click.option('-f', 'args_sender', default=None, help="Sender override")
@click.argument('args', nargs=-1, type=click.UNPROCESSED)
def main(args_sender, args):
    """Enqueue an email from standard input, simulating sendmail interface."""
    # Mimic the CLI interface of sendmail
    # We care about: -f (sender), and positional args (recipients)
    # We ignore others like -t -i, -oi, -o..., -v etc.
    args_recipients = [arg for arg in args if not arg.startswith('-')]

    try:
        raw_content = sys.stdin.buffer.read()
        if raw_content:
            enqueue_email(raw_content, args_sender, args_recipients)
    except Exception:
        logger.exception("Critical error reading input")
        sys.exit(1)

if __name__ == "__main__":
    main()
