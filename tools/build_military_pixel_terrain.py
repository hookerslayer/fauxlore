"""Build pixel-level land relief classes and the authoritative SQL raster."""
from __future__ import annotations

import base64
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
RELIEF = ROOT / "relief.png"
PROVINCES = ROOT / "map-data" / "province-ids.png"
REGION = ROOT / "map-data" / "view-region.json"
PNG = ROOT / "map-data" / "military-terrain.png"
BOUNDS_JSON = ROOT / "map-data" / "military-terrain-bounds.json"
MIGRATION = ROOT / "supabase" / "migrations" / "20261028151510_military_pixel_terrain.sql"


def build() -> tuple[np.ndarray, tuple[int, int, int, int]]:
    Image.MAX_IMAGE_PIXELS = None
    x_min, y_min, x_max, y_max = map(int, json.loads(REGION.read_text(encoding="utf-8"))["bounds"])
    with Image.open(RELIEF) as image:
        relief = np.asarray(image.crop((x_min, y_min, x_max, y_max)).convert("RGBA"))
    with Image.open(PROVINCES) as image:
        ids = np.asarray(image.crop((x_min, y_min, x_max, y_max)).convert("RGB"))
    land = (ids[:, :, 0] != 0) | (ids[:, :, 1] != 0) | (ids[:, :, 2] != 0)
    shade, alpha = relief[:, :, 0], relief[:, :, 3]
    classes = np.zeros(shade.shape, dtype=np.uint8)
    visible = land & (alpha > 0)
    # relief.png uses a neutral shade of 255. Its lighter 216 band is hills,
    # 165 is mountains, 102/108 are high ridges, and 74/0 are highest peaks.
    classes[visible & (shade == 216)] = 1
    classes[visible & (shade == 165)] = 2
    classes[visible & (shade <= 110)] = 3
    rgba = np.zeros((*classes.shape, 4), dtype=np.uint8)
    rgba[:, :, 0] = classes
    rgba[:, :, 3] = 255
    Image.fromarray(rgba, "RGBA").save(PNG, optimize=True)
    BOUNDS_JSON.write_text(json.dumps({"origin": [x_min, y_min], "size": [x_max - x_min, y_max - y_min]}), encoding="utf-8")
    return classes, (x_min, y_min, x_max, y_max)


def sql_migration(classes: np.ndarray, bounds: tuple[int, int, int, int]) -> str:
    x_min, y_min, x_max, y_max = bounds
    parts = [f"""-- Pixel relief class: 0 plain, 1 hills, 2 mountains, 3 high mountains.
create table fauxlore.military_terrain_mask_rows(
  y integer primary key check(y >= {y_min} and y < {y_max}), runs bytea not null
);
alter table fauxlore.military_terrain_mask_rows enable row level security;
revoke all on fauxlore.military_terrain_mask_rows from public,anon,authenticated;
insert into fauxlore.military_terrain_mask_rows(y,runs) values
"""]
    rows = []
    for offset_y, row in enumerate(classes):
        cuts = np.flatnonzero(row[1:] != row[:-1]) + 1
        edges = np.concatenate(([0], cuts, [row.size]))
        data = bytearray()
        for left, right in zip(edges[:-1], edges[1:]):
            length = int(right - left)
            if length > 65535:
                raise ValueError(f"Terrain run too long at y={y_min + offset_y}")
            data.extend((length >> 8, length & 255, int(row[left])))
        rows.append(f"  ({y_min + offset_y},decode('{base64.b64encode(data).decode('ascii')}','base64'))")
    parts.append(",\n".join(rows) + ";\n")
    parts.append(f"""
create or replace function fauxlore.military_terrain_at(x_value double precision,y_value double precision)
returns integer language plpgsql stable security definer set search_path='' as $function$
declare row_data bytea; offset_value integer:=0; cursor_x integer:=0; target_x integer; run_length integer;
begin
  if x_value < {x_min} or x_value >= {x_max} or y_value < {y_min} or y_value >= {y_max} then return 0; end if;
  target_x:=floor(x_value)::integer-{x_min};
  select runs into row_data from fauxlore.military_terrain_mask_rows where y=floor(y_value)::integer;
  if row_data is null then return 0; end if;
  while offset_value+2<octet_length(row_data) loop
    run_length:=get_byte(row_data,offset_value)*256+get_byte(row_data,offset_value+1);
    if target_x<cursor_x+run_length then return get_byte(row_data,offset_value+2); end if;
    cursor_x:=cursor_x+run_length; offset_value:=offset_value+3;
  end loop;
  return 0;
end
$function$;
revoke all on function fauxlore.military_terrain_at(double precision,double precision) from public,anon,authenticated;

create or replace function fauxlore.military_terrain_segment_factor(x1 double precision,y1 double precision,x2 double precision,y2 double precision)
returns numeric language plpgsql stable security definer set search_path='' as $function$
declare steps integer; i integer; terrain_class integer; total numeric:=0;
begin
  steps:=greatest(1,ceil(sqrt((x2-x1)^2+(y2-y1)^2))::integer);
  for i in 1..steps loop
    terrain_class:=fauxlore.military_terrain_at(x1+(x2-x1)*(i-.5)/steps,y1+(y2-y1)*(i-.5)/steps);
    total:=total+case terrain_class when 1 then 1.5 when 2 then 2.5 when 3 then 4 else 1 end;
  end loop;
  return total/steps;
end
$function$;
revoke all on function fauxlore.military_terrain_segment_factor(double precision,double precision,double precision,double precision) from public,anon,authenticated;

create or replace function fauxlore.military_terrain_segment_blocked(x1 double precision,y1 double precision,x2 double precision,y2 double precision)
returns boolean language plpgsql stable security definer set search_path='' as $function$
declare steps integer; i integer;
begin
  steps:=greatest(1,ceil(sqrt((x2-x1)^2+(y2-y1)^2))::integer);
  for i in 1..steps loop
    if fauxlore.military_terrain_at(x1+(x2-x1)*(i-.5)/steps,y1+(y2-y1)*(i-.5)/steps)=3 then return true; end if;
  end loop;
  return false;
end
$function$;
revoke all on function fauxlore.military_terrain_segment_blocked(double precision,double precision,double precision,double precision) from public,anon,authenticated;
grant execute on function fauxlore.military_terrain_at(double precision,double precision) to authenticated;

-- Apply relief pixels to movement; retain province-wide forest and marsh effects.
do $migration$
declare fn text; old_fragment text; new_fragment text;
begin
  fn:=replace(pg_get_functiondef('fauxlore.resolve_military_movement(integer,integer)'::regprocedure),chr(13),'');
  old_fragment:='terrain_factor:=case province_row.terrain_type when ''forest'' then 1.25 when ''hills'' then 1.5 when ''marsh'' then 2 when ''mountains'' then 2.5 when ''high_mountains'' then 4 else 1 end;';
  new_fragment:='terrain_factor:=(case province_row.terrain_type when ''forest'' then 1.25 when ''marsh'' then 2 else 1 end)*fauxlore.military_terrain_segment_factor(start_x::double precision,start_y::double precision,end_x::double precision,end_y::double precision);';
  if position(old_fragment in fn)=0 then raise exception 'Could not patch province terrain movement factor'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  execute fn;
  -- The route API was already patched with raster sampling; add a per-pixel peak check to those samples.
  fn:=replace(pg_get_functiondef('fauxlore.military_movement_api(text,bigint,jsonb)'::regprocedure),chr(13),'');
  old_fragment:='        sample_y:=previous_y+(y_value-previous_y)*sample_index/sample_steps;'||chr(10)||'        sample_id:=fauxlore.military_province_mask_id(sample_x::double precision,sample_y::double precision);';
  new_fragment:='        sample_y:=previous_y+(y_value-previous_y)*sample_index/sample_steps;'||chr(10)||
    '        sample_id:=fauxlore.military_province_mask_id(sample_x::double precision,sample_y::double precision);'||chr(10)||
    '        if formation_row.domain=''land'' and fauxlore.military_terrain_at(sample_x::double precision,sample_y::double precision)=3'||chr(10)||
    '           and fauxlore.military_road_factor(sample_x::double precision,sample_y::double precision)>=1 then'||chr(10)||
    '          raise sqlstate ''22023'' using message=''Маршрут пересекает непроходимые высокие горы без перевала'';'||chr(10)||
    '        end if;';
  if position(old_fragment in fn)=0 then raise exception 'Could not add pixel high-mountain route validation'; end if;
  fn:=replace(fn,old_fragment,new_fragment);
  old_fragment:='if province_row.terrain_type=''high_mountains'' and road_value>=1 then raise sqlstate ''22023'' using message=''Маршрут пересекает непроходимые высокие горы без перевала''; end if;';
  new_fragment:='if fauxlore.military_terrain_at(x_value::double precision,y_value::double precision)=3 and road_value>=1 then raise sqlstate ''22023'' using message=''Маршрут пересекает непроходимые высокие горы без перевала''; end if;';
  if position(old_fragment in fn)=0 then raise exception 'Could not replace province-wide high mountain route restriction'; end if;
  execute replace(fn,old_fragment,new_fragment);
  fn:=replace(pg_get_functiondef('fauxlore.resolve_military_movement(integer,integer)'::regprocedure),chr(13),'');
  old_fragment:='if formation_row.domain=''land'' and province_row.terrain_type=''high_mountains'' and road_factor>=1 then';
  new_fragment:='if formation_row.domain=''land'' and road_factor>=1 and fauxlore.military_terrain_segment_blocked(start_x::double precision,start_y::double precision,end_x::double precision,end_y::double precision) then';
  if position(old_fragment in fn)=0 then raise exception 'Could not patch high mountain movement restriction'; end if;
  execute replace(fn,old_fragment,new_fragment);
end
$migration$;
select pg_notify('pgrst','reload schema');
""")
    return "\n".join(parts)


if __name__ == "__main__":
    raster, raster_bounds = build()
    MIGRATION.write_text(sql_migration(raster, raster_bounds), encoding="utf-8")
    print(f"Wrote terrain mask ({PNG.stat().st_size:,} bytes) and migration ({MIGRATION.stat().st_size:,} bytes)")
