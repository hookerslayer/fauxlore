"""Apply the manual sea-province merges to the local PostgreSQL database."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server"))
from database import connect  # noqa: E402
from psycopg.types.json import Jsonb  # noqa: E402

MAPPING = {
    1315: 1301,
    463: 392,
    280: 175,
    4094: 4030,
    2470: 2260,
    3179: 3059,
    3040: 3059,
    3698: 3779,
}
LOSERS = set(MAPPING) - set(MAPPING.values())


def main():
    metadata = {
        item["id"]: item
        for item in json.loads((ROOT / "map-data/provinces.json").read_text(encoding="utf-8")).values()
    }
    db = connect()
    try:
        with db.transaction():
            rows = db.execute(
                "SELECT id, kind FROM provinces WHERE id = ANY(%s) FOR UPDATE",
                (list(set(MAPPING) | set(MAPPING.values())),),
            ).fetchall()
            actual = {row["id"]: row["kind"] for row in rows}
            for province_id in set(MAPPING) | set(MAPPING.values()):
                expected = "sea"
                if province_id not in actual or actual[province_id] != expected:
                    raise RuntimeError(f"Unexpected database province {province_id}: {actual.get(province_id)}")

            # Refuse to delete any province that still has rows in another table.
            references = db.execute("""
                SELECT c.conrelid::regclass::text AS table_name,
                       a.attname AS column_name
                FROM pg_constraint c
                JOIN unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
                JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum
                WHERE c.contype='f' AND c.confrelid='provinces'::regclass
                ORDER BY 1,2
            """).fetchall()
            for ref in references:
                table = ref["table_name"]
                column = ref["column_name"]
                found = db.execute(
                    f'SELECT "{column}" FROM {table} WHERE "{column}" = ANY(%s) LIMIT 1',
                    (list(LOSERS),),
                ).fetchone()
                if found:
                    raise RuntimeError(f"Province references remain in {table}.{column}; refusing deletion")

            for target_id in sorted(set(MAPPING.values())):
                item = metadata[target_id]
                db.execute("""
                    UPDATE provinces SET kind=%s, center=%s, bbox=%s, area=%s, seed_area=%s
                    WHERE id=%s
                """, (item["kind"], Jsonb(item["center"]), Jsonb(item["bbox"]),
                      item["area"], item["seed_area"], target_id))
            db.execute("DELETE FROM provinces WHERE id = ANY(%s)", (list(LOSERS),))
        print(json.dumps({"merged": MAPPING, "deleted": len(LOSERS)}, ensure_ascii=True))
    finally:
        db.close()


if __name__ == "__main__":
    main()
