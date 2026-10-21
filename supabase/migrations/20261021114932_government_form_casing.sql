-- Preserve the checked combination logic and normalize display casing.
alter function fauxlore.government_form(jsonb) rename to government_form_raw;
create function fauxlore.government_form(chosen jsonb) returns text
language plpgsql immutable set search_path='' as $$
declare raw_name text;
begin
  raw_name:=fauxlore.government_form_raw(chosen);
  return split_part(raw_name,' ',1)||' '||lower(substr(raw_name,length(split_part(raw_name,' ',1))+2));
end $$;
revoke all on function fauxlore.government_form(jsonb) from public,anon,authenticated;
