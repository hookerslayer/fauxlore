"""Explicit operator commands; never grant admin to the first registrant."""
import argparse
import getpass
from .database import connect, initialize, import_geometry
from .app import hasher, email_value


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('command',choices=['init','import-map','create-admin','promote-admin'])
    parser.add_argument('--email')
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
    else:
        print('Database initialized')


if __name__=='__main__':
    main()
