-- The admin editor reads constants through its authenticated RPC only.
revoke all on function fauxlore.economy_config_payload() from public, anon, authenticated;
