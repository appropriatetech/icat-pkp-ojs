"""
Shared logging configuration for email relay scripts.

When running as a Cloud Run job (Python is PID 1), logs go to stderr
normally and Cloud Run captures them.

When running as a subprocess inside the OJS service container (e.g.,
invoked by Symfony's proc_open via sendmail_path), stderr is piped
back to PHP and discarded. In that case, we write to /proc/1/fd/2
(the container entrypoint's stderr) so logs reach Cloud Logging.
"""

import logging
import os

LOG_FORMAT = '%(asctime)s - %(levelname)s - %(message)s'


def setup_logging(level: int = logging.INFO) -> None:
    """Configure the root logger to write to Cloud Logging."""
    handler = _get_handler()
    logging.basicConfig(level=level, format=LOG_FORMAT, handlers=[handler])


def get_logger(name: str) -> logging.Logger:
    """Get a logger configured for the email relay."""
    return logging.getLogger(name)


def _get_handler() -> logging.Handler:
    """
    Return a logging handler that writes to the container's stderr.

    If we're a subprocess (PID != 1) and /proc/1/fd/2 exists, write
    there so logs bypass Symfony's pipes and reach Cloud Logging.
    Otherwise, fall back to normal stderr.
    """
    if os.getpid() != 1 and os.path.exists('/proc/1/fd/2'):
        return logging.FileHandler('/proc/1/fd/2')
    else:
        return logging.StreamHandler()
