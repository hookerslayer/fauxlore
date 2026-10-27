"""Generate the server-side military route mask migration from the source ID raster."""
from __future__ import annotations

import base64
import json
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
RASTER = ROOT / "map-data" / "province-ids.png"
REGION = ROOT / "map-data" / "view-region.json"
OUTPUT = ROOT / "supabase" / "migrations" / "20261027230000_military_route_mask_validation.sql"


def migration_sql() -> str:
    Image.MAX_IMAGE_PIXELS = None
    bounds = json.loads(REGION.read_text(encoding="utf-8"))["bounds"]
    x_min, y_min, x_max, y_max = map(int, bounds)
    with Image.open(RASTER) as source:
        rgb = np.asarray(source.convert("RGB"), dtype=np.uint8)
    if x_min < 0 or y_min < 0 or x_max > rgb.shape[1] or y_max > rgb.shape[0]:
        raise ValueError("Playable region falls outside province ID raster")

    crop = rgb[y_min:y_max, x_min:x_max]
    province_metadata = json.loads((ROOT / "map-data" / "provinces.json").read_text(encoding="utf-8"))
    color_to_id = {int(color[1:], 16): int(value["id"]) for color, value in province_metadata.items()}
    raster_ids = np.unique((crop[:, :, 0].astype(np.uint32) << 16)
                           | (crop[:, :, 1].astype(np.uint32) << 8)
                           | crop[:, :, 2].astype(np.uint32))
    invalid_ids = [int(value) for value in raster_ids if value and color_to_id.get(int(value)) != int(value)]
    if invalid_ids:
        raise ValueError(f"Province raster colors do not directly encode province IDs: {invalid_ids[:8]}")
    sql = [f"""-- Exact route-point and raster-path checks, using the canonical province ID mask.
create table fauxlore.military_province_mask_rows(
  y integer primary key check(y >= {y_min} and y < {y_max}),
  runs bytea not null
);
revoke all on fauxlore.military_province_mask_rows from public,anon,authenticated;
insert into fauxlore.military_province_mask_rows(y,runs) values
"""]

    rows: list[str] = []
    for offset_y, row in enumerate(crop):
        packed_ids = (row[:, 0].astype(np.uint32) << 16) | (row[:, 1].astype(np.uint32) << 8) | row[:, 2].astype(np.uint32)
        cuts = np.flatnonzero(packed_ids[1:] != packed_ids[:-1]) + 1
        edges = np.concatenate(([0], cuts, [packed_ids.size]))
        packed = bytearray()
        for start, end in zip(edges[:-1], edges[1:]):
            run_length = int(end - start)
            province_id = int(packed_ids[start])
            if run_length > 65535 or province_id > 65535:
                raise ValueError(f"Raster run cannot be represented at row {offset_y}")
            packed.extend((run_length >> 8, run_length & 255, province_id >> 8, province_id & 255))
        encoded = base64.b64encode(packed).decode("ascii")
        rows.append(f"  ({y_min + offset_y},decode('{encoded}','base64'))")
    sql.append(",\n".join(rows) + ";\n")
    sql.append(f"""
create or replace function fauxlore.military_province_mask_id(x_value double precision,y_value double precision)
returns integer language plpgsql stable security definer set search_path='' as $function$
declare row_data bytea; offset_value integer:=0; cursor_x integer:=0; target_x integer;
  run_length integer; province_id integer;
begin
  if x_value < {x_min} or x_value >= {x_max} or y_value < {y_min} or y_value >= {y_max} then return null; end if;
  target_x:=floor(x_value)::integer-{x_min};
  select runs into row_data from fauxlore.military_province_mask_rows where y=floor(y_value)::integer;
  if row_data is null then return null; end if;
  while offset_value+3<octet_length(row_data) loop
    run_length:=get_byte(row_data,offset_value)*256+get_byte(row_data,offset_value+1);
    province_id:=get_byte(row_data,offset_value+2)*256+get_byte(row_data,offset_value+3);
    if target_x<cursor_x+run_length then return province_id; end if;
    cursor_x:=cursor_x+run_length; offset_value:=offset_value+4;
  end loop;
  return null;
end
$function$;
revoke all on function fauxlore.military_province_mask_id(double precision,double precision) from public,anon,authenticated;

-- Patch the existing authenticated movement API without replacing its other safeguards.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.military_movement_api(text,bigint,jsonb)'::regprocedure),chr(13),'');
  old_fragment:='route_point jsonb; province_row fauxlore.provinces; previous_province integer;';
  new_fragment:=old_fragment||' previous_x numeric; previous_y numeric; sample_x numeric; sample_y numeric; sample_id integer; sample_steps integer; sample_index integer;';
  if position(old_fragment in fn)=0 then raise exception 'Could not add province mask variables to movement API'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='    if i=0 then'||chr(10)||'      if province_row.id<>formation_row.province_id';
  new_fragment:='    sample_id:=fauxlore.military_province_mask_id(x_value::double precision,y_value::double precision);'||chr(10)||
    '    if sample_id is distinct from province_row.id then raise sqlstate ''22023'' using message=''Точка маршрута не принадлежит указанной провинции''; end if;'||chr(10)||
    '    if i>0 then'||chr(10)||
    '      sample_steps:=greatest(1,ceil(sqrt((x_value-previous_x)^2+(y_value-previous_y)^2))::integer);'||chr(10)||
    '      for sample_index in 1..sample_steps loop'||chr(10)||
    '        sample_x:=previous_x+(x_value-previous_x)*sample_index/sample_steps;'||chr(10)||
    '        sample_y:=previous_y+(y_value-previous_y)*sample_index/sample_steps;'||chr(10)||
    '        sample_id:=fauxlore.military_province_mask_id(sample_x::double precision,sample_y::double precision);'||chr(10)||
    '        if sample_id is distinct from previous_province and sample_id is distinct from province_row.id then'||chr(10)||
    '          raise sqlstate ''22023'' using message=''Маршрут пересекает провинцию, не указанную в маршруте'';'||chr(10)||
    '        end if;'||chr(10)||
    '      end loop;'||chr(10)||
    '    end if;'||chr(10)||
    old_fragment;
  if position(old_fragment in fn)=0 then raise exception 'Could not add exact raster route validation'; end if;
  fn:=replace(fn,old_fragment,new_fragment);

  old_fragment:='previous_province:=province_row.id;'||chr(10)||'  end loop;';
  new_fragment:='previous_province:=province_row.id; previous_x:=x_value; previous_y:=y_value;'||chr(10)||'  end loop;';
  if position(old_fragment in fn)=0 then raise exception 'Could not retain prior route coordinates for raster validation'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;
select pg_notify('pgrst','reload schema');
""")
    return "\n".join(sql)


if __name__ == "__main__":
    OUTPUT.write_text(migration_sql(), encoding="utf-8", newline="\n")
    print(f"Wrote {OUTPUT} ({OUTPUT.stat().st_size:,} bytes)")
