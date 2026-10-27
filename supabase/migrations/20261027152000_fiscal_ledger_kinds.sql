alter table fauxlore.state_budget_ledger drop constraint state_budget_ledger_kind_check;
alter table fauxlore.state_budget_ledger add constraint state_budget_ledger_kind_check
  check (kind in ('army_upkeep','debt_repayment','estate_loyalty_investment','estate_military_tax'));
