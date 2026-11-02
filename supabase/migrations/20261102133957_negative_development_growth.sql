do $migration$
declare fn text;
begin
 fn:=pg_get_functiondef('fauxlore.apply_permanent_development_on_turn()'::regprocedure);
 if position('if growth_value<=0 then continue; end if;' in fn)=0 then raise exception 'development growth guard missing';end if;
 fn:=replace(fn,'if growth_value<=0 then continue; end if;','if growth_value=0 or p.development is null then continue; end if;');
 if position('accumulated:=p.development_fraction+growth_value;' in fn)=0 then raise exception 'development accumulation missing';end if;
 fn:=replace(fn,'accumulated:=p.development_fraction+growth_value;','accumulated:=greatest(-p.development,least(1000000-p.development,p.development_fraction+growth_value));');execute fn;
end $migration$;
