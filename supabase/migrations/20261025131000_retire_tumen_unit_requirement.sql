-- Horse archers stay in the catalog after the Tumen doctrine is removed.
update fauxlore.military_unit_catalog set prerequisite='none' where prerequisite='tumens';
