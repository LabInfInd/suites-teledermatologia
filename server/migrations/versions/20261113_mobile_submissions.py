"""Separate persistent mobile queue; existing cases/reviews remain intact."""
from alembic import op
import sqlalchemy as sa
revision='20261113_mobile'
down_revision='de0293a5f46d'
branch_labels=None
depends_on=None

def upgrade():
    op.create_table('mobile_submissions',
        sa.Column('id',sa.String(36),primary_key=True),
        sa.Column('owner_id',sa.String(36),sa.ForeignKey('users.id'),nullable=False),
        sa.Column('mode',sa.String(16),nullable=False),sa.Column('model_id',sa.String(100),nullable=False),
        sa.Column('case_code',sa.String(40),nullable=False),sa.Column('source',sa.String(16),nullable=False),
        sa.Column('explain',sa.Boolean,nullable=False),sa.Column('request_sha256',sa.String(64),nullable=False),
        sa.Column('storage_key',sa.String(100),nullable=False,unique=True),sa.Column('image_sha256',sa.String(64),nullable=False),
        sa.Column('width',sa.Integer,nullable=False),sa.Column('height',sa.Integer,nullable=False),
        sa.Column('state',sa.String(24),nullable=False),sa.Column('created_at',sa.DateTime,nullable=False),
        sa.Column('finished_at',sa.DateTime,nullable=True),sa.Column('result',sa.JSON,nullable=True),
        sa.Column('failure_code',sa.String(40),nullable=True),
        sa.CheckConstraint("mode IN ('clinical','dermoscopic')",name='mobile_mode'),
        sa.CheckConstraint("state IN ('queued','running','completed','failed')",name='mobile_state'))
    op.create_index('ix_mobile_submissions_owner_id','mobile_submissions',['owner_id'])
    op.create_index('ix_mobile_submissions_state','mobile_submissions',['state'])
    op.create_index('ix_mobile_queue','mobile_submissions',['state','created_at'])

def downgrade():
    op.drop_table('mobile_submissions')
