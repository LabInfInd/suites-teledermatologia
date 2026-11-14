from alembic import context

from app.db import Base, get_engine
from app.config import get_settings
from app import models  # noqa: F401


def run_migrations():
    if context.is_offline_mode():
        context.configure(url=get_settings().database_url, target_metadata=Base.metadata,
                          literal_binds=True, dialect_opts={"paramstyle": "named"})
        with context.begin_transaction():
            context.run_migrations()
        return
    with get_engine().connect() as connection:
        context.configure(connection=connection, target_metadata=Base.metadata, compare_type=True)
        with context.begin_transaction():
            context.run_migrations()


run_migrations()
