"""Create/revoke one short-lived test session without printing its token."""
import os
import sys
from pathlib import Path
import psycopg
from session_store import SessionStore

PATH = Path('/run/fauxlore-browser-preview/session')
DSN = 'dbname=fauxlore_restore_filtered port=5433'

with psycopg.connect(DSN) as db:
    assert db.execute('SELECT current_database()').fetchone()[0] == 'fauxlore_restore_filtered'
    if sys.argv[1] == 'create':
        user = db.execute("""SELECT a.auth_user_id FROM fauxlore.accounts a JOIN fauxlore.account_states s
          ON s.account_id=a.id WHERE a.role='player' AND s.layer='states' AND a.auth_user_id IS NOT NULL LIMIT 1""").fetchone()[0]
        db.execute('SET ROLE fauxlore_auth')
        token = SessionStore(db, ttl_seconds=600).create(user)
        fd = os.open(PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
        with os.fdopen(fd, 'w', encoding='ascii') as file: file.write(token)
        db.commit()
    elif sys.argv[1] == 'revoke':
        token = PATH.read_text(encoding='ascii').strip()
        db.execute('SET ROLE fauxlore_auth')
        SessionStore(db).revoke(token)
        db.commit()
        PATH.unlink()
    else: raise ValueError('Unknown command')
