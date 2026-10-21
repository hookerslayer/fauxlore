alter table fauxlore.provinces
  drop constraint provinces_province_type_check;

update fauxlore.provinces
set province_type = 'Территория'
where province_type = 'Колония';

alter table fauxlore.provinces
  add constraint provinces_province_type_check
  check (province_type in ('Столица','Город','Регион','Территория','Нейтральная'));
