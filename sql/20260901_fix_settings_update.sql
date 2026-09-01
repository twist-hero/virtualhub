-- Fix: admin_update_settings must use COALESCE so partial updates work
-- Problem: PaysettingsPanel only sends payment_ghana + payment_nigeria,
-- but the SQL function set ALL columns including registration_ghs to NULL,
-- violating the NOT-null constraint.

CREATE OR REPLACE FUNCTION public.admin_update_settings(p_settings jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public AS $$
BEGIN
  -- Upsert with COALESCE so only provided fields are updated
  INSERT INTO public.settings (
    id, payment_ghana, payment_nigeria, registration_ghs, registration_ngn,
    prediction_cost, efootball_cost, efootball_expiry, spin_cost, updated_at
  )
  VALUES (
    'global_config',
    p_settings->'payment_ghana',
    p_settings->'payment_nigeria',
    (p_settings->>'registration_ghs')::numeric,
    (p_settings->>'registration_ngn')::numeric,
    (p_settings->>'prediction_cost')::int,
    (p_settings->>'efootball_cost')::int,
    (p_settings->>'efootball_expiry')::int,
    (p_settings->>'spin_cost')::int,
    now()
  )
  ON CONFLICT (id) DO UPDATE SET
    payment_ghana     = COALESCE(excluded.payment_ghana,    public.settings.payment_ghana),
    payment_nigeria   = COALESCE(excluded.payment_nigeria,  public.settings.payment_nigeria),
    registration_ghs  = COALESCE(excluded.registration_ghs, public.settings.registration_ghs),
    registration_ngn  = COALESCE(excluded.registration_ngn, public.settings.registration_ngn),
    prediction_cost   = COALESCE(excluded.prediction_cost,  public.settings.prediction_cost),
    efootball_cost    = COALESCE(excluded.efootball_cost,   public.settings.efootball_cost),
    efootball_expiry  = COALESCE(excluded.efootball_expiry, public.settings.efootball_expiry),
    spin_cost         = COALESCE(excluded.spin_cost,        public.settings.spin_cost),
    updated_at        = now();
  RETURN public.json_ok();
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_settings(jsonb) TO anon;

-- Set default payment gateway to Telecel / 0532650202 / SOLOMON KUMI
UPDATE public.settings
SET payment_ghana = '{"provider":"Telecel","accountName":"SOLOMON KUMI","accountNumber":"0532650202"}'::jsonb
WHERE id = 'global_config';

-- If no row exists, insert one with the defaults
INSERT INTO public.settings (id, payment_ghana, payment_nigeria, registration_ghs, registration_ngn)
VALUES (
  'global_config',
  '{"provider":"Telecel","accountName":"SOLOMON KUMI","accountNumber":"0532650202"}'::jsonb,
  '{"provider":"Access Bank","accountName":"VirtualHub Ltd","accountNumber":"0123456789"}'::jsonb,
  50,
  10000
)
ON CONFLICT (id) DO NOTHING;

SELECT '✅ admin_update_settings fixed with COALESCE — partial updates now work. Default gateway set to Telecel 0532650202 / SOLOMON KUMI' AS result;
