"""create email_queue table

Revision ID: 001
Revises:
Create Date: 2026-02-26

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '001'
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'email_queue',
        sa.Column('id', sa.Integer, primary_key=True, autoincrement=True),
        sa.Column('created_at', sa.TIMESTAMP, server_default=sa.func.now()),
        sa.Column('status', sa.Enum('pending', 'sent', 'failed'), server_default='pending'),
        sa.Column('attempt_count', sa.Integer, server_default='0'),
        sa.Column('last_attempt_at', sa.TIMESTAMP),
        sa.Column('error_message', sa.Text),
        sa.Column('sender', sa.String(255), nullable=False),
        sa.Column('recipients', sa.Text, nullable=False),
        sa.Column('body', sa.LargeBinary, nullable=False),
    )
    op.create_index(
        'idx_email_queue_status_created',
        'email_queue',
        ['status', 'created_at'],
    )


def downgrade() -> None:
    op.drop_index('idx_email_queue_status_created', 'email_queue')
    op.drop_table('email_queue')
