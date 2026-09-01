-- ============================================================================
-- MIGRATION: Add asset_type + ocr_name to orders, fix ticket crediting
-- Date: 2026-09-01
-- Safe to run multiple times (idempotent)
-- Run in: Supabase SQL Editor
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Add columns to orders table (skip if already present)
-- ────────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'orders' AND column_name = 'asset_type'
  ) THEN
    ALTER TABLE public.orders ADD COLUMN asset_type text NOT NULL DEFAULT 'diamond';
    RAISE NOTICE 'Added asset_type column to orders';
  ELSE
    RAISE NOTICE 'asset_type column already exists — skipping';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'orders' AND column_name = 'ocr_name'
  ) THEN
    ALTER TABLE public.orders ADD COLUMN ocr_name text;
    RAISE NOTICE 'Added ocr_name column to orders';
  ELSE
    RAISE NOTICE 'ocr_name column already exists — skipping';
  END IF;
END
$$;

-- Index for fast filtering by asset type in admin panel
CREATE INDEX IF NOT EXISTS orders_asset_idx ON public.orders (asset_type);

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Backfill asset_type for existing rows (best-effort from package_name)
-- ────────────────────────────────────────────────────────────────────────────
UPDATE public.orders
   SET asset_type = 'gold'
 WHERE asset_type = 'diamond'
   AND package_name ILIKE '%gold%';

UPDATE public.orders
   SET asset_type = 'ticket'
 WHERE asset_type = 'diamond'
   AND package_name ILIKE '%ticket%';

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Replace update_diamond_order — now handles diamond / gold / ticket
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.update_diamond_order(
  p_order_id uuid, p_status text, p_note text default null
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ord public.orders%rowtype;
  v_asset text;
  v_bal integer;
  v_emoji text;
  v_label text;
BEGIN
  SELECT * INTO v_ord FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF v_ord.id IS NULL THEN RETURN public.json_err('order_not_found'); END IF;

  -- Determine asset type: prefer asset_type column, fall back to package_name heuristic
  v_asset := lower(coalesce(v_ord.asset_type, ''));
  IF v_asset = '' OR v_asset IS NULL THEN
    IF v_ord.package_name ILIKE '%gold%' THEN v_asset := 'gold';
    ELSIF v_ord.package_name ILIKE '%ticket%' THEN v_asset := 'ticket';
    ELSE v_asset := 'diamond';
    END IF;
  END IF;

  -- Pick emoji / label for notifications
  IF v_asset = 'gold' THEN
    v_emoji := '🪙'; v_label := 'Gold coins';
  ELSIF v_asset = 'ticket' THEN
    v_emoji := '🎟️'; v_label := 'Tickets';
  ELSE
    v_emoji := '💎'; v_label := 'Diamonds';
  END IF;

  UPDATE public.orders SET status = p_status, admin_note = p_note, updated_at = now()
   WHERE id = p_order_id;

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

GRANT EXECUTE ON FUNCTION public.update_diamond_order(uuid, text, text) TO anon;

-- ────────────────────────────────────────────────────────────────────────────
-- 4. Replace admin_get_all_data — earnings + revenue now include orders
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_all_data()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_members      jsonb;
  v_payments     jsonb;
  v_orders       jsonb;
  v_predictions  jsonb;
  v_efootball    jsonb;
  v_ticket_tx    jsonb;
  v_spin_signals jsonb;
  v_pricing      jsonb;
  v_payment_set  jsonb;
  v_earnings     jsonb;
  v_stats        jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(p ORDER BY p.created_at DESC), '[]'::jsonb)
    INTO v_members
    FROM public.profiles p;

  SELECT coalesce(jsonb_agg(p ORDER BY p.created_at DESC), '[]'::jsonb)
    INTO v_payments
    FROM public.payments p;

  SELECT coalesce(jsonb_agg(o ORDER BY o.created_at DESC), '[]'::jsonb)
    INTO v_orders
    FROM public.orders o;

  SELECT coalesce(jsonb_agg(pr ORDER BY pr.created_at DESC), '[]'::jsonb)
    INTO v_predictions
    FROM public.predictions pr;

  SELECT coalesce(jsonb_agg(b ORDER BY b.created_at DESC), '[]'::jsonb)
    INTO v_efootball
    FROM public.booking_code_requests b;

  SELECT coalesce(jsonb_agg(t ORDER BY t.created_at DESC), '[]'::jsonb)
    INTO v_ticket_tx
    FROM public.ticket_transactions t;

  SELECT coalesce(jsonb_agg(s ORDER BY s.created_at DESC), '[]'::jsonb)
    INTO v_spin_signals
    FROM public.spin_signals s;

  SELECT to_jsonb(s.*) INTO v_pricing FROM public.settings s WHERE id = 'global_config';
  v_pricing := coalesce(v_pricing, '{}'::jsonb);

  v_payment_set := jsonb_build_object(
    'payment_ghana',   v_pricing->'payment_ghana',
    'payment_nigeria', v_pricing->'payment_nigeria'
  );

  -- Earnings: sum BOTH registration payments AND asset package orders
  v_earnings := jsonb_build_object(
    'totalGHS', coalesce((SELECT sum(amount) FROM public.payments WHERE status = 'approved' AND currency = 'GHS'), 0)
               + coalesce((SELECT sum(amount) FROM public.orders  WHERE status = 'approved' AND currency = 'GHS'), 0),
    'totalNGN', coalesce((SELECT sum(amount) FROM public.payments WHERE status = 'approved' AND currency = 'NGN'), 0)
               + coalesce((SELECT sum(amount) FROM public.orders  WHERE status = 'approved' AND currency = 'NGN'), 0)
  );

  -- Stats revenue: also includes asset order revenue
  v_stats := jsonb_build_object(
    'revenue', jsonb_build_object(
      'GHS', coalesce((SELECT sum(amount) FROM public.payments WHERE status = 'approved' AND currency = 'GHS'), 0)
            + coalesce((SELECT sum(amount) FROM public.orders  WHERE status = 'approved' AND currency = 'GHS'), 0),
      'NGN', coalesce((SELECT sum(amount) FROM public.payments WHERE status = 'approved' AND currency = 'NGN'), 0)
            + coalesce((SELECT sum(amount) FROM public.orders  WHERE status = 'approved' AND currency = 'NGN'), 0)
    ),
    'pending', (
      (SELECT count(*) FROM public.payments WHERE status = 'pending') +
      (SELECT count(*) FROM public.orders   WHERE status = 'pending') +
      (SELECT count(*) FROM public.booking_code_requests WHERE status = 'pending')
    ),
    'members', (SELECT count(*) FROM public.profiles)
  );

  RETURN jsonb_build_object(
    'members',          v_members,
    'payments',         v_payments,
    'diamondOrders',    v_orders,
    'predictions',      v_predictions,
    'efootball',        v_efootball,
    'ticketTransactions', v_ticket_tx,
    'spinSignals',      v_spin_signals,
    'pricing',          v_pricing,
    'paymentSettings',  v_payment_set,
    'earnings',         v_earnings,
    'stats',            v_stats
  );
END; $$;

GRANT EXECUTE ON FUNCTION public.admin_get_all_data() TO anon;

-- ============================================================================
-- Done. Run SELECT '✅ Migration complete' AS result; to verify.
-- ============================================================================
SELECT '✅ Migration 20260901_add_asset_type_columns applied successfully' AS result;
