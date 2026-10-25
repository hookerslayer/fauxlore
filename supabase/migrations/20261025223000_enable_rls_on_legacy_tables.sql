-- Keep legacy and estate tax tables inaccessible to direct client queries.
-- Application access is mediated by SECURITY DEFINER API functions.
revoke all on table fauxlore.retired_ephemeral_principles,
  fauxlore.state_estate_tax_rates,
  fauxlore.retired_crown_politics,
  fauxlore.retired_province_belonging,
  fauxlore.retired_state_tax_rates
from public, anon, authenticated;

alter table fauxlore.retired_ephemeral_principles enable row level security;
alter table fauxlore.state_estate_tax_rates enable row level security;
alter table fauxlore.retired_crown_politics enable row level security;
alter table fauxlore.retired_province_belonging enable row level security;
alter table fauxlore.retired_state_tax_rates enable row level security;
