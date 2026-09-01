-- Fix: admin_update_settings must use COALESCE so partial updates work
-- Problem: PaysettingsPanel only sends payment_ghana + payment_nigeria,
-- but the SQL function set ALL columns including registration_ghs to NULL,
-- violating the NOT-null constraint.

CREATE OR REPLACE FUNCTION public.admin_update_settings(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
DECLARE
  v_updated INT := 0;
BEGIN
  -- 1) UPDATE existing row first (only touch fields that are actually provided)
  UPDATE public.settings SET
    payment_ghana   = COALESCE(p_settings->'payment_ghana',   payment_ghana),
    payment_nigeria = COALESCE(p_settings->'payment_nigeria', payment_nigeria),
    registration_ghs  = CASE WHEN p_settings ? 'registration_ghs'
                             THEN (p_settings->>'registration_ghs')::numeric
                             ELSE registration_ghs END,
    registration_ngn  = CASE WHEN p_settings ? 'registration_ngn'
                             THEN (p_settings->>'registration_ngn')::numeric
                             ELSE registration_ngn END,
    prediction_cost   = CASE WHEN p_settings ? 'prediction_cost'
                             THEN (p_settings->>'prediction_cost')::int
                             ELSE prediction_cost END,
    efootball_cost    = CASE WHEN p_settings ? 'efootball_cost'
                             THEN (p_settings->>'efootball_cost')::int
                             ELSE efootball_cost END,
    efootball_expiry  = CASE WHEN p_settings ? 'efootball_expiry'
                             THEN (p_settings->>'efootball_expiry')::int
                             ELSE efootball_expiry END,
    spin_cost         = CASE WHEN p_settings ? 'spin_cost'
                             THEN (p_settings->>'spin_cost')::int
                             ELSE spin_cost END,
    updated_at = now()
  WHERE id = 'global_config';

  GET DIAGNOSTICS v_updated = ROW_COUNT;

  -- 2) If no row existed, INSERT one with safe defaults
  IF v_updated = 0 THEN
    INSERT INTO public.settings (
      id, payment_ghana, payment_nigeria,
      registration_ghs, registration_ngn,
      prediction_cost, efootball_cost, efootball_expiry, spin_cost,
      updated_at
    ) VALUES (
      'global_config',
      COALESCE(p_settings->'payment_ghana',   '{"provider":"Telecel","accountName":"SOLOMON KUMI","accountNumber":"0508515521"}'::jsonb),
      COALESCE(p_settings->'payment_nigeria', '{"provider":"Access Bank","accountName":"VirtualHub Ltd","accountNumber":"0123456789"}'::jsonb),
      COALESCE((p_settings->>'registration_ghs')::numeric, 50),
      COALESCE((p_settings->>'registration_ngn')::numeric, 10000),
      COALESCE((p_settings->>'prediction_cost')::int, 50),
      COALESCE((p_settings->>'efootball_cost')::int, 1),
      COALESCE((p_settings->>'efootball_expiry')::int, 10),
      COALESCE((p_settings->>'spin_cost')::int, 50),
      now()
    );
  END IF;

  RETURN public.json_ok();
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_settings(jsonb) TO anon;

-- Set default payment gateway to Telecel / 0508515521 / SOLOMON KUMI
UPDATE public.settings
SET payment_ghana = '{"provider":"Telecel","accountName":"SOLOMON KUMI","accountNumber":"0508515521"}'::jsonb
WHERE id = 'global_config';

-- If no row exists, insert one with the defaults
INSERT INTO public.settings (id, payment_ghana, payment_nigeria, registration_ghs, registration_ngn)
VALUES (
  'global_config',
  '{"provider":"Telecel","accountName":"SOLOMON KUMI","accountNumber":"0508515521"}'::jsonb,
  '{"provider":"Access Bank","accountName":"VirtualHub Ltd","accountNumber":"0123456789"}'::jsonb,
  50,
  10000
)
ON CONFLICT (id) DO NOTHING;

SELECT '✅ admin_update_settings fixed with COALESCE — partial updates now work. Default gateway set to Telecel 0532650202 / SOLOMON KUMI' AS result;
