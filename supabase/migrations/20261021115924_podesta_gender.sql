-- «Подеста» is masculine despite its ending.
create or replace function fauxlore.government_form(chosen jsonb) returns text
language plpgsql immutable set search_path='' as $$
declare raw_name text; army text; economic text;
begin
  raw_name:=fauxlore.government_form_raw(chosen);
  if chosen->>'authority'='Магистрат' and chosen->>'structure'='Командорство' then
    army:=split_part(raw_name,' ',1);
    economic:=split_part(raw_name,' ',2);
    army:=regexp_replace(regexp_replace(army,'ская$','ский'),'ая$','ый');
    economic:=regexp_replace(regexp_replace(economic,'ская$','ский'),'ая$','ый');
    return army||' '||lower(economic)||' подеста';
  end if;
  return split_part(raw_name,' ',1)||' '||lower(substr(raw_name,length(split_part(raw_name,' ',1))+2));
end $$;
revoke all on function fauxlore.government_form(jsonb) from public,anon,authenticated;
