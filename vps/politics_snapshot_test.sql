-- Isolated preview only. The legacy getter initializes rows, so roll its writes back.
BEGIN;
DO $$ BEGIN
  IF current_database() <> 'fauxlore_restore_filtered' THEN
    RAISE EXCEPTION 'Refusing to modify any database except the isolated preview';
  END IF;
END $$;
CREATE OR REPLACE FUNCTION fauxlore_vps_preview.politics_snapshot(target_state integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb; account fauxlore.accounts; prefix text;
BEGIN
  account := fauxlore.current_account();
  IF account.id IS NULL OR target_state IS NULL OR target_state < 1 THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;
  IF account.role = 'admin' THEN prefix := 'admin';
  ELSIF EXISTS (SELECT 1 FROM fauxlore.account_states s WHERE s.account_id=account.id
                AND s.layer='states' AND s.state_id=target_state) THEN prefix := 'my';
  ELSE RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;
  BEGIN
    result := fauxlore.succession_api(prefix || '/states/' || target_state || '/politics', 'GET', '{}'::jsonb, NULL);
    RAISE EXCEPTION 'Rollback preview initialization' USING ERRCODE = 'P0099';
  EXCEPTION WHEN SQLSTATE 'P0099' THEN NULL;
  END;
  RETURN result;
END $$;
CREATE OR REPLACE FUNCTION fauxlore_vps_preview.finance_inputs(target_state integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE account fauxlore.accounts; prefix text;
BEGIN
  account := fauxlore.current_account();
  IF account.id IS NULL OR target_state IS NULL OR target_state < 1 THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;
  IF account.role = 'admin' THEN prefix := 'admin';
  ELSIF EXISTS (SELECT 1 FROM fauxlore.account_states s WHERE s.account_id=account.id
                AND s.layer='states' AND s.state_id=target_state) THEN prefix := 'my';
  ELSE RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM fauxlore.state_profiles WHERE state_id=target_state) THEN
    RAISE EXCEPTION 'Государство не найдено' USING ERRCODE = 'P0002';
  END IF;
  RETURN jsonb_build_object(
    'tax_rates', (SELECT jsonb_build_object('prestige',s.prestige,'buckets',
      coalesce((SELECT jsonb_object_agg(t.estate,t.balance) FROM fauxlore.state_treasuries t WHERE t.state_id=s.state_id),'{}'::jsonb))
      FROM fauxlore.state_profiles s WHERE s.state_id=target_state),
    'agreements', fauxlore.trade_api('my/trade-agreements', 'GET', '{}'::jsonb, NULL),
    'colonization', fauxlore.colonization_api('snapshot', target_state, '{}'::jsonb),
    'military', public.military_api('upkeep_snapshot', target_state, '{}'::jsonb)
  );
END $$;
CREATE OR REPLACE FUNCTION fauxlore_vps_preview.game_snapshot(target_state integer, kind text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE account fauxlore.accounts;
BEGIN
  account := fauxlore.current_account();
  IF account.id IS NULL OR target_state IS NULL OR target_state < 1 OR
     (account.role <> 'admin' AND NOT EXISTS (SELECT 1 FROM fauxlore.account_states s
      WHERE s.account_id=account.id AND s.layer='states' AND s.state_id=target_state)) THEN
    RAISE EXCEPTION 'Access denied' USING ERRCODE = '42501';
  END IF;
  CASE kind
    WHEN 'military' THEN RETURN public.military_api('snapshot', target_state, '{}'::jsonb);
    WHEN 'garrison' THEN RETURN public.garrison_api('snapshot', target_state, NULL, '{}'::jsonb);
    WHEN 'colonization' THEN RETURN fauxlore.colonization_api('snapshot', target_state, '{}'::jsonb);
    ELSE RAISE EXCEPTION 'Invalid snapshot' USING ERRCODE = '22023';
  END CASE;
END $$;
REVOKE ALL ON FUNCTION fauxlore_vps_preview.politics_snapshot(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fauxlore_vps_preview.finance_inputs(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION fauxlore_vps_preview.game_snapshot(integer,text) FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA fauxlore_vps_preview TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.politics_snapshot(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.finance_inputs(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore_vps_preview.game_snapshot(integer,text) TO authenticated;
-- The loopback server may obtain the private source only after it has checked
-- the caller's state. The authenticated database role cannot call it.
GRANT USAGE ON SCHEMA public TO fauxlore_rpc;
GRANT EXECUTE ON FUNCTION public.projection_source_api() TO fauxlore_rpc;
GRANT EXECUTE ON FUNCTION fauxlore.trade_overview_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.state_trade_duty_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.estate_tax_rates_api(text,text,jsonb,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION fauxlore.state_tax_rates_api(text,text,jsonb,uuid) TO authenticated;
COMMIT;
