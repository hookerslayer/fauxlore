-- The treasury bucket is not an estate and cannot receive an estate tax share.
CREATE OR REPLACE FUNCTION fauxlore.split_province_tax(gross numeric, belonging text, status text, cfg jsonb)
 RETURNS TABLE(crown numeric, estate numeric)
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare greed numeric;
begin
  if gross is null or gross<0 then raise sqlstate '22023' using message='Сумма налога не может быть отрицательной'; end if;
  if belonging not in ('Знать','Духовенство','Горожане','Крестьяне') or status not in ('Ключевое','Значимое','Бесправное') then
    raise sqlstate '22023' using message='Неизвестное сословие или его статус';
  end if;
  greed:=nullif(cfg#>>array['estateTaxGreed',status||'|'||belonging],'')::numeric;
  if greed is null or greed<0 or greed>1 then raise sqlstate '22023' using message='Не задан корректный коэффициент распределения налога'; end if;
  return query select round(gross*(1-greed),2),gross-round(gross*(1-greed),2);
end $function$
;
