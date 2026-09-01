-- ============================================================================
-- DEPLOY: update_diamond_order — self-contained migration
-- Run this in Supabase SQL Editor to fix "credit type u do not exit" error
-- ============================================================================

-- 1. Ensure helper functions exist
CREATE OR REPLACE FUNCTION public.json_ok(extra jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE sql IMMUTABLE SECURITY DEFINER
AS $$ SELECT jsonb_build_object('ok', true) || coalesce(extra, '{}'::jsonb); $$;

CREATE OR REPLACE FUNCTION public.json_err(reason text)
RETURNS jsonb
LANGUAGE sql IMMUTABLE SECURITY DEFINER
AS $$ SELECT jsonb_build_object('ok', false, 'error', reason); $$;

-- 2. Ensure orders table has required columns
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'orders' AND column_name = 'admin_note') THEN
    ALTER TABLE public.orders ADD COLUMN admin_note text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'orders' AND column_name = 'updated_at') THEN
    ALTER TABLE public.orders ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'orders' AND column_name = 'asset_type') THEN
    ALTER TABLE public.orders ADD COLUMN asset_type text NOT NULL DEFAULT 'diamond';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'orders' AND column_name = 'ocr_name') THEN
    ALTER TABLE public.orders ADD COLUMN ocr_name text;
  END IF;
END $$;

-- 3. Ensure profiles table has required columns
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'profiles' AND column_name = 'gold') THEN
    ALTER TABLE public.profiles ADD COLUMN gold integer NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'profiles' AND column_name = 'tickets') THEN
    ALTER TABLE public.profiles ADD COLUMN tickets integer NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'profiles' AND column_name = 'diamonds') THEN
    ALTER TABLE public.profiles ADD COLUMN diamonds integer NOT NULL DEFAULT 0;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'profiles' AND column_name = 'updated_at') THEN
    ALTER TABLE public.profiles ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
  END IF;
END $$;

-- 4. Ensure transaction tables exist
CREATE TABLE IF NOT EXISTS public.transactions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  kind          text not null,
  amount        integer not null,
  currency      text not null default 'diamond',
  reason        text,
  balance_after integer not null,
  created_at    timestamptz not null default now()
);
CREATE INDEX IF NOT EXISTS transactions_user_idx ON public.transactions (user_id, created_at desc);

CREATE TABLE IF NOT EXISTS public.gold_transactions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  kind          text not null,
  amount        integer not null,
  reason        text,
  balance_after integer not null,
  created_at    timestamptz not null default now()
);
CREATE INDEX IF NOT EXISTS gold_tx_user_idx ON public.gold_transactions (user_id, created_at desc);

CREATE TABLE IF NOT EXISTS public.ticket_transactions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  kind          text not null,
  amount        integer not null,
  reason        text,
  balance_after integer not null,
  created_at    timestamptz not null default now()
);
CREATE INDEX IF NOT EXISTS ticket_tx_user_idx ON public.ticket_transactions (user_id, created_at desc);

-- 5. Ensure notifications table exists
CREATE TABLE IF NOT EXISTS public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  title       text not null,
  body        text,
  kind        text default 'info',
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
CREATE INDEX IF NOT EXISTS notifications_user_idx ON public.notifications (user_id, created_at desc);

-- 6. Create/update the update_diamond_order function
CREATE OR REPLACE FUNCTION public.update_diamond_order(
  p_order_id uuid,
  p_status text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ord public.orders%ROWTYPE;
  v_asset text;
  v_bal integer;
  v_emoji text;
  v_label text;
BEGIN
  SELECT * INTO v_ord FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_ord IS NULL OR v_ord.id IS NULL THEN
    RETURN public.json_err('order_not_found');
  END IF;

  -- Determine asset type
  v_asset := lower(coalesce(v_ord.asset_type, ''));
  IF v_asset = '' OR v_asset IS NULL THEN
    IF v_ord.package_name ILIKE '%gold%' THEN v_asset := 'gold';
    ELSIF v_ord.package_name ILIKE '%ticket%' THEN v_asset := 'ticket';
    ELSE v_asset := 'diamond';
    END IF;
  END IF;

  -- Pick emoji / label
  IF v_asset = 'gold' THEN
    v_emoji := '🪙'; v_label := 'Gold coins';
  ELSIF v_asset = 'ticket' THEN
    v_emoji := '🎟️'; v_label := 'Tickets';
  ELSE
    v_emoji := '💎'; v_label := 'Diamonds';
  END IF;

  -- Update order status
  UPDATE public.orders
     SET status = p_status, admin_note = p_note, updated_at = now()
   WHERE id = p_order_id;

  -- If approved, credit the user's balance
  IF p_status = 'approved' AND v_ord.user_id IS NOT NULL THEN
    IF v_asset = 'gold' THEN
      SELECT gold INTO v_bal FROM public.profiles WHERE id = v_ord.user_id FOR UPDATE;
      UPDATE public.profiles SET gold = gold + v_ord.diamonds, updated_at = now()
       WHERE id = v_ord.user_id;
      INSERT INTO public.gold_transactions (user_id, kind, amount, reason, balance_after)
           VALUES (v_ord.user_id, 'credit', v_ord.diamonds, v_ord.package_name, v_bal + v_ord.diamonds);
    ELSIF v_asset = 'ticket' THEN
      SELECT tickets INTO v_bal FROM public.profiles WHERE id = v_ord.user_id FOR UPDATE;
      UPDATE public.profiles SET tickets = tickets + v_ord.diamonds, updated_at = now()
       WHERE id = v_ord.user_id;
      INSERT INTO public.ticket_transactions (user_id, kind, amount, reason, balance_after)
           VALUES (v_ord.user_id, 'credit', v_ord.diamonds, v_ord.package_name, v_bal + v_ord.diamonds);
    ELSE
      SELECT diamonds INTO v_bal FROM public.profiles WHERE id = v_ord.user_id FOR UPDATE;
      UPDATE public.profiles SET diamonds = diamonds + v_ord.diamonds, updated_at = now()
       WHERE id = v_ord.user_id;
      INSERT INTO public.transactions (user_id, kind, amount, currency, reason, balance_after)
           VALUES (v_ord.user_id, 'credit', v_ord.diamonds, 'diamond', v_ord.package_name, v_bal + v_ord.diamonds);
    END IF;

    INSERT INTO public.notifications (user_id, title, body, kind)
         VALUES (v_ord.user_id, v_emoji || ' Order approved',
                 format('%s %s added to your account!', v_ord.diamonds, v_label), 'success');

  ELSIF p_status = 'rejected' AND v_ord.user_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, title, body, kind)
         VALUES (v_ord.user_id, '❌ Order declined', coalesce(p_note, 'Please resubmit.'), 'error');
  END IF;

  RETURN public.json_ok();
END;
$$;

-- 7. Grant permissions
GRANT EXECUTE ON FUNCTION public.update_diamond_order(uuid, text, text) TO anon;
GRANT EXECUTE ON FUNCTION public.json_ok(jsonb) TO anon;
GRANT EXECUTE ON FUNCTION public.json_err(text) TO anon;

-- 8. Also ensure the payment and member update functions exist
CREATE OR REPLACE FUNCTION public.update_payment_proof(
  p_payment_id uuid,
  p_status text,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pay public.payments%ROWTYPE;
BEGIN
  SELECT * INTO v_pay FROM public.payments WHERE id = p_payment_id FOR UPDATE;
  IF v_pay IS NULL OR v_pay.id IS NULL THEN
    RETURN public.json_err('payment_not_found');
  END IF;

  UPDATE public.payments SET status = p_status, admin_note = p_note, updated_at = now()
   WHERE id = p_payment_id;

  IF p_status = 'approved' AND v_pay.user_id IS NOT NULL THEN
    UPDATE public.profiles SET status = 'active', updated_at = now() WHERE id = v_pay.user_id;
    INSERT INTO public.notifications (user_id, title, body, kind)
         VALUES (v_pay.user_id, '🎉 Account activated',
                 'Your registration payment was approved. Welcome!', 'success');
  ELSIF p_status = 'rejected' AND v_pay.user_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, title, body, kind)
         VALUES (v_pay.user_id, '❌ Payment declined', coalesce(p_note, 'Please resubmit.'), 'error');
  END IF;

  RETURN public.json_ok();
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_payment_proof(uuid, text, text) TO anon;

-- 9. Proof URL functions (for View Proof button)
CREATE OR REPLACE FUNCTION public.admin_get_order_proof_url(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_path text;
BEGIN
  SELECT screenshot_path INTO v_path FROM public.orders WHERE id = p_order_id;
  RETURN jsonb_build_object('path', v_path);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_order_proof_url(uuid) TO anon;

CREATE OR REPLACE FUNCTION public.admin_get_payment_proof_url(p_payment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_path text;
BEGIN
  SELECT screenshot_path INTO v_path FROM public.payments WHERE id = p_payment_id;
  RETURN jsonb_build_object('path', v_path);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_payment_proof_url(uuid) TO anon;

SELECT '✅ All functions deployed successfully — credit/reject/view-proof should now work' AS result;

-- Note: admin_get_all_data is already in prediit_full_schema_fixed.sql
