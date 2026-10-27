alter table fauxlore.estate_fiscal_events drop constraint estate_fiscal_events_war_id_fkey;
alter table fauxlore.estate_fiscal_events add constraint estate_fiscal_events_war_id_fkey
  foreign key(war_id) references fauxlore.military_wars(id) on delete cascade;
