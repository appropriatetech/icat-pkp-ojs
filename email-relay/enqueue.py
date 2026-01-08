import sys
import email
import argparse
from email.policy import default
import database

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
        print("No recipients found in arguments or headers.", file=sys.stderr)
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
    except Exception as e:
        session.rollback()
        print(f"Error enqueuing email: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        session.close()

if __name__ == "__main__":
    # Robust manual argument parsing to mimic sendmail quirkiness
    # We care about: -f (sender), -t (scan headers), and positional args (recipients)
    # We ignore others like -i, -oi, -o..., -v etc.

    args_sender = None
    args_recipients = []

    idx = 1
    files_to_read = []

    while idx < len(sys.argv):
        arg = sys.argv[idx]

        if arg.startswith('-'):
            # It's a flag
            if arg == '-f':
                if idx + 1 < len(sys.argv):
                    args_sender = sys.argv[idx+1]
                    idx += 2
                else:
                    # Trailing -f? Ignore.
                    idx += 1
                continue
            elif arg.startswith('-f'):
                # -fSender
                args_sender = arg[2:]
            elif arg == '--':
                # End of flags
                idx += 1
                while idx < len(sys.argv):
                    args_recipients.append(sys.argv[idx])
                    idx += 1
                break
            else:
                # Ignore other flags (-t, -i, -oi, etc.)
                pass
        else:
            # Positional argument = recipient
            args_recipients.append(arg)

        idx += 1

    try:
        raw_content = sys.stdin.buffer.read()
        if raw_content:
            enqueue_email(raw_content, args_sender, args_recipients)
    except Exception as e:
        print(f"Critical error reading input: {e}", file=sys.stderr)
        sys.exit(1)
