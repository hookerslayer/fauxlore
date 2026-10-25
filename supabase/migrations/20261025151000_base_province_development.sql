-- Development 100 is the neutral 100% multiplier for all land provinces.
alter table fauxlore.provinces alter column development set default 100;
update fauxlore.provinces set development=100 where kind='land' and development is null;
