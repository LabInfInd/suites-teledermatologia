"""Explicit acquisition and model provenance; doctor-approved Grad-CAM publication.

Existing acquisition modes remain NULL: no dermoscopic assumption/backfill.
The migration is additive and preserves all clinical records and publications.
"""
from alembic import op
import sqlalchemy as sa

revision = "20261114_case_explanations"
down_revision = "20261113_mobile"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column("cases", sa.Column("mode", sa.String(16), nullable=True))
    op.add_column("analysis_runs", sa.Column("mode", sa.String(16), nullable=True))
    op.add_column("analysis_runs", sa.Column("model_id", sa.String(100), nullable=True))
    op.add_column("analysis_runs", sa.Column("explanation_target", sa.String(160), nullable=True))
    op.add_column("medical_reviews", sa.Column("share_explanation", sa.Boolean(), server_default=sa.false(), nullable=False))


def downgrade():
    op.drop_column("medical_reviews", "share_explanation")
    op.drop_column("analysis_runs", "explanation_target")
    op.drop_column("analysis_runs", "model_id")
    op.drop_column("analysis_runs", "mode")
    op.drop_column("cases", "mode")
