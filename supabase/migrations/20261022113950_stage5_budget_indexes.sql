-- Cover foreign keys used by admin attribution and per-type budget history.
create index if not exists army_unit_types_updated_by_idx on fauxlore.army_unit_types(updated_by);
create index if not exists state_army_units_unit_type_idx on fauxlore.state_army_units(unit_type_id);
create index if not exists state_budget_ledger_unit_type_idx on fauxlore.state_budget_ledger(unit_type_id);
