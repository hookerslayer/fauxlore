"""Explicit operator commands; never grant admin to the first registrant."""
import argparse
import getpass
from .database import connect, initialize, import_geometry
from .app import hasher, email_value


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('command',choices=['init','import-map','create-admin','promote-admin','assign-state'])
    parser.add_argument('--email')
    parser.add_argument('--state')
    args=parser.parse_args()
    initialize()
    if args.command=='import-map':
        with connect() as db:
            import_geometry(db)
        print('Geometry imported; existing names preserved. Retired IDs are not deleted automatically.')
    elif args.command=='create-admin':
        email=email_value(args.email or input('Email: '))
        password=getpass.getpass('Password (10+ characters): ')
        if len(password)<10:
            raise SystemExit('Password too short')
        with connect() as db:
            db.execute("INSERT INTO accounts(email,nickname,password_hash,role) VALUES(%s,%s,%s,'admin')",
                       (email,'Администратор',hasher.hash(password)))
        print('Admin created')
    elif args.command=='promote-admin':
        email=email_value(args.email or input('Email: '))
        with connect() as db:
            row=db.execute("UPDATE accounts SET role='admin' WHERE email=%s RETURNING id",(email,)).fetchone()
            if not row:
                raise SystemExit('Account not found')
        print('Admin role granted')
    elif args.command=='assign-state':
        if not args.state:raise SystemExit('--state is required')
        email=email_value(args.email or input('Email: '))
        with connect() as db:
            account=db.execute('SELECT id FROM accounts WHERE email=%s',(email,)).fetchone()
            state=db.execute("SELECT id FROM map_categories WHERE layer='states' AND lower(name)=lower(%s)",(args.state.strip(),)).fetchone()
            if not account:raise SystemExit('Account not found')
            if not state:raise SystemExit('State not found')
            db.execute('INSERT INTO account_states(account_id,state_id) VALUES(%s,%s) ON CONFLICT DO NOTHING',(account['id'],state['id']))
        print('State ownership assigned')
    else:
        print('Database initialized')


if __name__=='__main__':
    main()
