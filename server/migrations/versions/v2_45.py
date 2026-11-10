"""Add explicit bindings to DevKit project identities."""

import sqlalchemy as sa
from alembic import op

revision = "v2_45"
down_revision = "v2_44"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # An unversioned database may already have the table from metadata.create_all().
    if sa.inspect(op.get_bind()).has_table("devkit_auth_bindings"):
        return
    op.create_table(
        "devkit_auth_bindings",
        sa.Column("scope", sa.Text(), nullable=False),
        sa.Column("subject", sa.Text(), nullable=False),
        sa.Column("user_id", sa.Text(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.PrimaryKeyConstraint("scope", "subject"),
        sa.UniqueConstraint("scope", "user_id"),
    )


def downgrade() -> None:
    op.drop_table("devkit_auth_bindings")
