"""winvm 增量 seed：只跑本次改动涉及的三类种子，避免全量 seed 副作用。"""
import os

os.environ.setdefault("POSTGRES_USER", "root")
os.environ.setdefault("POSTGRES_PASSWORD", "Wv2026Pg")
os.environ.setdefault("POSTGRES_DB", "quant_zc")

from app.core.database import _get_session_factory
from app.db.seeders.mock.seeders.home import (
    seed_home_blocks,
    seed_home_feed_widgets,
)
from app.db.seeders.mock.seeders.reference import seed_app_configs
from app.db.seeders.resources_demo import seed_resources_demo

db = _get_session_factory()()
try:
    seed_app_configs(db)
    seed_home_blocks(db)
    seed_home_feed_widgets(db)
    seed_resources_demo(db)
    db.commit()
    print("SEED_OK")
finally:
    db.close()
