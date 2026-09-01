-- ============================================================================
-- prediit  full schema, RLS, RPCs, storage, realtime publication
-- *** FIXED VERSION ***
-- Run this once in the Supabase SQL editor (or via `supabase db reset`).
--
-- SAFE TO RE-RUN: every CREATE uses IF NOT EXISTS, every CREATE OR REPLACE.
--
-- FIXES APPLIED:
--  1. Added storage policies for payment-proofs & screenshot-proofs buckets
--  2. Fixed check_admin_session grant (was only authenticated, needs anon)
--  3. Fixed get_app_secrets / update_app_secrets to validate passcode
--  4. Added transactions + ticket_transactions to realtime publication
--  5. Added storage download policies so admin can view uploaded proofs
-- ============================================================================

create extension if not exists "pgcrypto";

-- 
-- 0. DROP EVERY RPC we want to (re)create.
-- CREATE OR REPLACE cannot change parameter defaults, so we drop first.
-- Safe to re-run: each is IF EXISTS.
-- 
drop function if exists public.json_ok(jsonb);
drop function if exists public.json_err(text);

drop function if exists public.submit_prediction(uuid, jsonb, integer);
drop function if exists public.reveal_spin_signal();
drop function if exists public.request_booking_code();
drop function if exists public.submit_gold_order(text, integer, numeric, text, text, text, text, text, text);
-- Drop EVERY overload of grant_currencies regardless of signature.
do $$
declare
  r record;
begin
  for r in
    select p.oid
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where p.proname = 'grant_currencies' and n.nspname = 'public'
  loop
    execute 'drop function if exists ' || r.oid::regprocedure || ' cascade';
  end loop;
end $$;
drop function if exists public.update_payment_proof(uuid, text, text);
drop function if exists public.update_diamond_order(uuid, text, text);
drop function if exists public.admin_update_member_status(uuid, text);
drop function if exists public.admin_approve_booking_code(uuid, text, text, timestamptz);
drop function if exists public.admin_delete_record(text, uuid);
drop function if exists public.admin_insert_prediction(uuid, jsonb);
drop function if exists public.admin_get_payment_proof_url(uuid);
drop function if exists public.admin_get_order_proof_url(uuid);
drop function if exists public.admin_get_all_data();
drop function if exists public.admin_update_settings(jsonb);
drop function if exists public.get_gemini_key();
drop function if exists public.get_app_secrets(text);
drop function if exists public.update_app_secrets(text, text);
drop function if exists public.verify_admin_code(text);
drop function if exists public.check_admin_session();
drop function if exists public.change_admin_access_code(text);
drop function if exists public.log_admin_action(text);
drop function if exists public.handle_new_user() cascade;
drop function if exists public.get_packages();
drop function if exists public.admin_update_packages(text, jsonb);

-- 
-- 1. TABLES
-- 

-- Profiles: one row per member (linked to auth.users.id)
create table if not exists public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  full_name       text,
  email           text,
  phone           text,
  country         text,                          -- 'ghana' | 'nigeria'
  referral_code   text unique,
  referred_by     text,
  status          text not null default 'pending',  -- 'pending' | 'active' | 'suspended'
  diamonds        integer not null default 0,
  gold            integer not null default 0,
  tickets         integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists profiles_email_idx      on public.profiles (email);
create index if not exists profiles_status_idx    on public.profiles (status);
create index if not exists profiles_referral_idx  on public.profiles (referral_code);

-- Registration payments (the GHS 50 / NGN 10000 signup proof)
create table if not exists public.payments (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references auth.users(id) on delete set null,
  email           text not null,
  country         text,
  method          text,                          -- 'Mobile Money' | 'Bank Transfer'
  amount          numeric(12,2) not null,
  currency        text not null default 'GHS',
  sender_name     text,
  sender_number   text,
  txn_id          text,
  screenshot_path text,
  status          text not null default 'pending',  -- 'pending' | 'approved' | 'rejected'
  admin_note      text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists payments_user_idx   on public.payments (user_id);
create index if not exists payments_status_idx on public.payments (status);

-- Orders: diamond & gold purchases
create table if not exists public.orders (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references auth.users(id) on delete set null,
  email           text not null,
  package_name    text not null,                 -- 'Pro Diamond' | 'Pro Gold' ...
  diamonds        integer not null default 0,   -- diamond OR gold coin count
  amount          numeric(12,2) not null,
  currency        text not null default 'GHS',
  method          text,
  txn_id          text,
  sender_name     text,
  sender_number   text,
  screenshot_path text,
  status          text not null default 'pending',
  admin_note      text,
  asset_type      text not null default 'diamond',   -- 'diamond' | 'gold' | 'ticket'
  ocr_name        text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists orders_asset_idx on public.orders (asset_type);
create index if not exists orders_user_idx   on public.orders (user_id);
create index if not exists orders_status_idx on public.orders (status);

-- Generic notifications feed shown on the wallet bell
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  title       text not null,
  body        text,
  kind        text default 'info',              -- 'success' | 'info' | 'warning' | 'error'
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);

-- Generic transaction ledger (diamonds)
create table if not exists public.transactions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  kind          text not null,                  -- 'credit' | 'debit'
  amount        integer not null,
  currency      text not null default 'diamond',
  reason        text,
  balance_after integer not null,
  created_at    timestamptz not null default now()
);
create index if not exists transactions_user_idx on public.transactions (user_id, created_at desc);

-- Gold coin ledger
create table if not exists public.gold_transactions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  kind          text not null,
  amount        integer not null,
  reason        text,
  balance_after integer not null,
  created_at    timestamptz not null default now()
);
create index if not exists gold_tx_user_idx on public.gold_transactions (user_id, created_at desc);

-- eFootball ticket ledger
create table if not exists public.ticket_transactions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  kind          text not null,
  amount        integer not null,
  reason        text,
  balance_after integer not null,
  created_at    timestamptz not null default now()
);
create index if not exists ticket_tx_user_idx on public.ticket_transactions (user_id, created_at desc);

-- AI predictions
create table if not exists public.predictions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  result      jsonb not null,                   -- { matches: [...], source: 'gemini'|'model' }
  created_at  timestamptz not null default now()
);
create index if not exists predictions_user_idx on public.predictions (user_id, created_at desc);

-- Spin-Da-Bottle signals
create table if not exists public.spin_signals (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  direction   text,
  confidence  integer,
  result      jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists spin_signals_user_idx on public.spin_signals (user_id, created_at desc);

-- eFootball booking code requests
create table if not exists public.booking_code_requests (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  email        text,
  market       text,
  stake_time   timestamptz,
  code         text,
  status       text not null default 'pending',  -- 'pending' | 'approved' | 'rejected'
  admin_note   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists booking_req_user_idx   on public.booking_code_requests (user_id, created_at desc);
create index if not exists booking_req_status_idx on public.booking_code_requests (status);

-- Single-row settings table
create table if not exists public.settings (
  id                  text primary key default 'global_config',
  payment_ghana       jsonb,
  payment_nigeria     jsonb,
  registration_ghs    numeric(12,2) default 50,
  registration_ngn    numeric(12,2) default 10000,
  prediction_cost     integer default 50,
  efootball_cost      integer default 1,
  efootball_expiry    integer default 10,
  spin_cost           integer default 50,
  diamond_packages    jsonb,
  gold_packages       jsonb,
  updated_by          uuid references public.profiles(id) on delete set null,
  updated_at          timestamptz not null default now()
);
insert into public.settings (id) values ('global_config') on conflict (id) do nothing;

alter table public.settings
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;
alter table public.settings
  add column if not exists diamond_packages jsonb;
alter table public.settings
  add column if not exists gold_packages jsonb;

-- App secrets (admin passcode + Gemini API key)
create table if not exists public.app_secrets (
  id               text primary key default 'global',
  admin_passcode   text,
  gemini_api_key   text,
  updated_by       uuid references public.profiles(id) on delete set null,
  updated_at       timestamptz not null default now()
);
insert into public.app_secrets (id, admin_passcode) values ('global', '54321') on conflict do nothing;

alter table public.app_secrets
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;

-- 
-- 2. REALTIME PUBLICATION
-- Every table the dashboard / admin realtime scripts subscribe to must be
-- added here, otherwise postgres_changes events never fire.
-- 
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

-- FIX: Added transactions + ticket_transactions to the publication list
-- so that future wallet/activity realtime features work.
do $$
declare
  t text;
  tables text[] := array[
    'profiles',
    'payments',
    'orders',
    'notifications',
    'booking_code_requests',
    'gold_transactions',
    'spin_signals',
    'predictions',
    'transactions',
    'ticket_transactions'
  ];
begin
  foreach t in array tables loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- 
-- 3. AUTO-CREATE PROFILE ROW ON AUTH SIGNUP
-- 
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, referral_code, referred_by)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    'VE-' || upper(substr(replace(new.id::text, '-', ''), 1, 8)),
    new.raw_user_meta_data->>'referral_code'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- 
-- 4. STORAGE BUCKETS
-- 
insert into storage.buckets (id, name, public) values ('payment-proofs',     'payment-proofs',     false)
  on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('screenshot-proofs',  'screenshot-proofs',  false)
  on conflict (id) do nothing;

-- 
-- 5. ROW-LEVEL SECURITY
-- 
alter table public.profiles              enable row level security;
alter table public.payments              enable row level security;
alter table public.orders                enable row level security;
alter table public.notifications         enable row level security;
alter table public.transactions          enable row level security;
alter table public.gold_transactions     enable row level security;
alter table public.ticket_transactions   enable row level security;
alter table public.predictions           enable row level security;
alter table public.spin_signals          enable row level security;
alter table public.booking_code_requests enable row level security;
alter table public.settings              enable row level security;
alter table public.app_secrets            enable row level security;

-- Drop & recreate policies idempotently
drop policy if exists "profile self read"   on public.profiles;
drop policy if exists "profile self update" on public.profiles;
drop policy if exists "payment self read"   on public.payments;
drop policy if exists "payment self insert" on public.payments;
drop policy if exists "order self read"     on public.orders;
drop policy if exists "order self insert"   on public.orders;
drop policy if exists "notif self read"     on public.notifications;
drop policy if exists "notif self update"   on public.notifications;
drop policy if exists "notif self delete"   on public.notifications;
drop policy if exists "tx self read"        on public.transactions;
drop policy if exists "gold tx self read"   on public.gold_transactions;
drop policy if exists "ticket tx self read" on public.ticket_transactions;
drop policy if exists "pred self read"      on public.predictions;
drop policy if exists "pred self delete"    on public.predictions;
drop policy if exists "spin self read"      on public.spin_signals;
drop policy if exists "booking self read"   on public.booking_code_requests;
drop policy if exists "settings public read" on public.settings;
drop policy if exists "app_secrets deny all"  on public.app_secrets;

create policy "profile self read"   on public.profiles for select using (auth.uid() = id);
create policy "profile self update" on public.profiles for update using (auth.uid() = id);

create policy "payment self read"   on public.payments for select using (auth.uid() = user_id);
create policy "payment self insert" on public.payments for insert with check (auth.uid() = user_id);

create policy "order self read"     on public.orders for select using (auth.uid() = user_id);
create policy "order self insert"   on public.orders for insert with check (auth.uid() = user_id);

create policy "notif self read"   on public.notifications for select using (auth.uid() = user_id);
create policy "notif self update" on public.notifications for update using (auth.uid() = user_id);
create policy "notif self delete" on public.notifications for delete using (auth.uid() = user_id);

create policy "tx self read"        on public.transactions        for select using (auth.uid() = user_id);
create policy "gold tx self read"   on public.gold_transactions   for select using (auth.uid() = user_id);
create policy "ticket tx self read" on public.ticket_transactions for select using (auth.uid() = user_id);

create policy "pred self read"   on public.predictions for select using (auth.uid() = user_id);
create policy "pred self delete" on public.predictions for delete using (auth.uid() = user_id);

create policy "spin self read"    on public.spin_signals for select using (auth.uid() = user_id);

create policy "booking self read" on public.booking_code_requests
  for select using (auth.uid() = user_id);

create policy "settings public read" on public.settings for select using (true);

create policy "app_secrets deny all" on public.app_secrets
  for all using (false) with check (false);

-- ============================================================================
-- FIX #1: STORAGE POLICIES
-- Without these, ALL file uploads (payment proofs, screenshot proofs) fail
-- with a silent RLS permission error. This is the #1 cause of broken signup.
-- ============================================================================

-- payment-proofs bucket policies
-- Allow authenticated users to upload their own payment proof
drop policy if exists "payment-proofs insert" on storage.objects;
create policy "payment-proofs insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'payment-proofs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Allow authenticated users to read their own payment proofs
drop policy if exists "payment-proofs select own" on storage.objects;
create policy "payment-proofs select own"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'payment-proofs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Allow anon role (admin panel uses anon key) to read ALL payment proofs
-- so admin can view screenshot proofs for approval
drop policy if exists "payment-proofs admin read" on storage.objects;
create policy "payment-proofs admin read"
  on storage.objects for select
  to anon
  using (
    bucket_id = 'payment-proofs'
  );

-- Allow anon role (admin panel) to delete payment proofs
drop policy if exists "payment-proofs admin delete" on storage.objects;
create policy "payment-proofs admin delete"
  on storage.objects for delete
  to anon
  using (
    bucket_id = 'payment-proofs'
  );

-- screenshot-proofs bucket policies
-- Allow authenticated users to upload their own screenshot proofs
drop policy if exists "screenshot-proofs insert" on storage.objects;
create policy "screenshot-proofs insert"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'screenshot-proofs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Allow authenticated users to read their own screenshot proofs
drop policy if exists "screenshot-proofs select own" on storage.objects;
create policy "screenshot-proofs select own"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'screenshot-proofs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Allow anon role (admin panel) to read ALL screenshot proofs
drop policy if exists "screenshot-proofs admin read" on storage.objects;
create policy "screenshot-proofs admin read"
  on storage.objects for select
  to anon
  using (
    bucket_id = 'screenshot-proofs'
  );

-- Allow anon role (admin panel) to delete screenshot proofs
drop policy if exists "screenshot-proofs admin delete" on storage.objects;
create policy "screenshot-proofs admin delete"
  on storage.objects for delete
  to anon
  using (
    bucket_id = 'screenshot-proofs'
  );

-- 
-- 6. RPCs
-- 

-- 6.1 Generic JSON-returning helper
create or replace function public.json_ok(extra jsonb default '{}'::jsonb)
returns jsonb language sql immutable as $$ select jsonb_build_object('ok', true) || extra; $$;

create or replace function public.json_err(reason text)
returns jsonb language sql immutable as $$ select jsonb_build_object('ok', false, 'reason', reason); $$;

-- 6.2 submit_prediction (used by predict.functions  get-prediction)
-- Atomic: deduct diamonds, log transaction, insert prediction row.
create or replace function public.submit_prediction(
  p_user_id uuid,
  p_result  jsonb,
  p_cost    integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance integer;
  v_pred_id uuid;
begin
  select diamonds into v_balance from public.profiles where id = p_user_id for update;
  if v_balance is null then return public.json_err('profile_missing'); end if;
  if v_balance < p_cost then return public.json_err('insufficient_diamonds'); end if;

  update public.profiles
     set diamonds = diamonds - p_cost, updated_at = now()
   where id = p_user_id;

  if p_cost > 0 then
    insert into public.transactions (user_id, kind, amount, currency, reason, balance_after)
     values (p_user_id, 'debit', p_cost, 'diamond', 'AI prediction', v_balance - p_cost);
  end if;

  insert into public.predictions (user_id, result) values (p_user_id, p_result)
   returning id into v_pred_id;

  return public.json_ok(jsonb_build_object('prediction_id', v_pred_id, 'balance', v_balance - p_cost));
end;
$$;
grant execute on function public.submit_prediction(uuid, jsonb, integer) to authenticated;

-- 6.3 reveal_spin_signal (used by spin.functions)
create or replace function public.reveal_spin_signal()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_cost    integer;
  v_balance integer;
  v_signal  jsonb;
  v_dir     text;
  v_conf    integer;
begin
  if v_user_id is null then return public.json_err('unauthorized'); end if;

  select coalesce(spin_cost, 50) into v_cost from public.settings where id = 'global_config';
  select gold into v_balance from public.profiles where id = v_user_id for update;
  if v_balance is null then return public.json_err('profile_missing'); end if;
  if v_balance < v_cost  then return public.json_err('insufficient_gold'); end if;

  update public.profiles set gold = gold - v_cost, updated_at = now() where id = v_user_id;

  insert into public.gold_transactions (user_id, kind, amount, reason, balance_after)
       values (v_user_id, 'debit', v_cost, 'Spin reveal', v_balance - v_cost);

  v_dir  := (array['Left','Right','Center'])[1 + floor(random()*3)::int];
  v_conf := 60 + floor(random()*35)::int;
  v_signal := jsonb_build_object('direction', v_dir, 'confidence', v_conf);

  insert into public.spin_signals (user_id, direction, confidence, result)
       values (v_user_id, v_dir, v_conf, v_signal);

  return public.json_ok(jsonb_build_object('signal', v_signal, 'balance', v_balance - v_cost));
end;
$$;
grant execute on function public.reveal_spin_signal() to authenticated;

-- 6.4 request_booking_code (used by efootball.functions)
create or replace function public.request_booking_code()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_cost    integer;
  v_balance integer;
  v_req_id  uuid;
begin
  if v_user_id is null then return public.json_err('unauthorized'); end if;

  select coalesce(efootball_cost, 1) into v_cost from public.settings where id = 'global_config';
  select tickets into v_balance from public.profiles where id = v_user_id for update;
  if v_balance is null then return public.json_err('profile_missing'); end if;
  if v_balance < v_cost  then return public.json_err('insufficient_tickets'); end if;

  update public.profiles set tickets = tickets - v_cost, updated_at = now() where id = v_user_id;

  insert into public.ticket_transactions (user_id, kind, amount, reason, balance_after)
       values (v_user_id, 'debit', v_cost, 'Booking code request', v_balance - v_cost);

  insert into public.booking_code_requests (user_id, email, status)
       values (v_user_id, (select email from public.profiles where id = v_user_id), 'pending')
       returning id into v_req_id;

  return public.json_ok(jsonb_build_object('request_id', v_req_id, 'balance', v_balance - v_cost));
end;
$$;
grant execute on function public.request_booking_code() to authenticated;

-- 6.5 submit_gold_order
create or replace function public.submit_gold_order(
  p_package_name    text,
  p_gold            integer,
  p_amount          numeric,
  p_currency        text,
  p_method          text,
  p_txn_id          text,
  p_sender_name     text,
  p_sender_number   text,
  p_screenshot_path text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_email   text;
  v_order   public.orders%rowtype;
begin
  if v_user_id is null then return public.json_err('unauthorized'); end if;
  select email into v_email from public.profiles where id = v_user_id;

  insert into public.orders
       (user_id, email, package_name, diamonds, amount, currency, method,
        txn_id, sender_name, sender_number, screenshot_path, status)
  values
       (v_user_id, coalesce(v_email, ''), p_package_name, p_gold, p_amount, p_currency, p_method,
        p_txn_id, p_sender_name, p_sender_number, p_screenshot_path, 'pending')
  returning * into v_order;

  return public.json_ok(jsonb_build_object('order', to_jsonb(v_order)));
end;
$$;
grant execute on function public.submit_gold_order(text, integer, numeric, text, text, text, text, text, text)
  to authenticated;

-- 6.6 grant_currencies (admin only — VIP grant UI)
create or replace function public.grant_currencies(
  p_user_id  uuid,
  p_diamonds bigint default 0,
  p_gold     bigint default 0,
  p_tickets  bigint default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_add_d int := p_diamonds::int;
  v_add_g int := p_gold::int;
  v_add_t int := p_tickets::int;
  v_bal_d int; v_bal_g int; v_bal_t int;
begin
  select diamonds, gold, tickets into v_bal_d, v_bal_g, v_bal_t
    from public.profiles where id = p_user_id for update;
  if v_bal_d is null then return public.json_err('profile_missing'); end if;

  update public.profiles
     set diamonds = diamonds + v_add_d,
         gold     = gold     + v_add_g,
         tickets  = tickets  + v_add_t,
         updated_at = now()
   where id = p_user_id;

  if v_add_d > 0 then
    insert into public.transactions (user_id, kind, amount, currency, reason, balance_after)
         values (p_user_id, 'credit', v_add_d, 'diamond', 'Admin grant', v_bal_d + v_add_d);
  end if;
  if v_add_g > 0 then
    insert into public.gold_transactions (user_id, kind, amount, reason, balance_after)
         values (p_user_id, 'credit', v_add_g, 'Admin grant', v_bal_g + v_add_g);
  end if;
  if v_add_t > 0 then
    insert into public.ticket_transactions (user_id, kind, amount, reason, balance_after)
         values (p_user_id, 'credit', v_add_t, 'Admin grant', v_bal_t + v_add_t);
  end if;

  insert into public.notifications (user_id, title, body, kind)
       values (
         p_user_id,
         case
           when v_add_d > 0 and v_add_g = 0 and v_add_t = 0 then '💎 Diamonds credited'
           when v_add_g > 0 and v_add_d = 0 and v_add_t = 0 then '🪙 Gold credited'
           when v_add_t > 0 and v_add_d = 0 and v_add_g = 0 then '🎫 Tickets credited'
           else '✨ Assets credited'
         end,
         format('%s diamonds, %s gold, %s tickets added to your account.',
                v_add_d, v_add_g, v_add_t),
         'success'
       );

  return public.json_ok();
end;
$$;
grant execute on function public.grant_currencies(uuid, bigint, bigint, bigint) to authenticated;
grant execute on function public.grant_currencies(uuid, bigint, bigint, bigint) to anon;

-- 6.7 update_payment_proof (admin approves/rejects registration)
create or replace function public.update_payment_proof(
  p_payment_id uuid, p_status text, p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay public.payments%rowtype;
begin
  select * into v_pay from public.payments where id = p_payment_id for update;
  if v_pay.id is null then return public.json_err('payment_not_found'); end if;

  update public.payments set status = p_status, admin_note = p_note, updated_at = now()
   where id = p_payment_id;

  if p_status = 'approved' and v_pay.user_id is not null then
    update public.profiles set status = 'active', updated_at = now() where id = v_pay.user_id;
    insert into public.notifications (user_id, title, body, kind)
         values (v_pay.user_id, '🎉 Account activated',
                 'Your registration payment was approved. Welcome to prediit!', 'success');
  elsif p_status = 'rejected' and v_pay.user_id is not null then
    insert into public.notifications (user_id, title, body, kind)
         values (v_pay.user_id, '❌ Payment declined', coalesce(p_note, 'Please resubmit.'), 'error');
  end if;

  return public.json_ok();
end;
$$;

grant execute on function public.update_payment_proof(uuid, text, text) to anon;

-- 6.8 update_diamond_order (admin approves/rejects orders)
create or replace function public.update_diamond_order(
  p_order_id uuid, p_status text, p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ord public.orders%rowtype;
  v_asset text;
  v_bal integer;
  v_emoji text;
  v_label text;
begin
  select * into v_ord from public.orders where id = p_order_id for update;
  if v_ord.id is null then return public.json_err('order_not_found'); end if;

  -- Determine asset type: prefer asset_type column, fall back to package_name heuristic
  v_asset := lower(coalesce(v_ord.asset_type, ''));
  if v_asset = '' or v_asset is null then
    if v_ord.package_name ilike '%gold%' then v_asset := 'gold';
    elsif v_ord.package_name ilike '%ticket%' then v_asset := 'ticket';
    else v_asset := 'diamond';
    end if;
  end if;

  -- Pick emoji / label for notifications
  if v_asset = 'gold' then
    v_emoji := '🪙'; v_label := 'Gold coins';
  elsif v_asset = 'ticket' then
    v_emoji := '🎟'; v_label := 'Tickets';
  else
    v_emoji := '💎'; v_label := 'Diamonds';
  end if;

  update public.orders set status = p_status, admin_note = p_note, updated_at = now()
   where id = p_order_id;

  if p_status = 'approved' and v_ord.user_id is not null then
    if v_asset = 'gold' then
      select gold into v_bal from public.profiles where id = v_ord.user_id for update;
      update public.profiles set gold = gold + v_ord.diamonds, updated_at = now()
         where id = v_ord.user_id;
      insert into public.gold_transactions (user_id, kind, amount, reason, balance_after)
           values (v_ord.user_id, 'credit', v_ord.diamonds, v_ord.package_name, v_bal + v_ord.diamonds);
    elsif v_asset = 'ticket' then
      select tickets into v_bal from public.profiles where id = v_ord.user_id for update;
      update public.profiles set tickets = tickets + v_ord.diamonds, updated_at = now()
         where id = v_ord.user_id;
      insert into public.ticket_transactions (user_id, kind, amount, reason, balance_after)
           values (v_ord.user_id, 'credit', v_ord.diamonds, v_ord.package_name, v_bal + v_ord.diamonds);
    else
      select diamonds into v_bal from public.profiles where id = v_ord.user_id for update;
      update public.profiles set diamonds = diamonds + v_ord.diamonds, updated_at = now()
         where id = v_ord.user_id;
      insert into public.transactions (user_id, kind, amount, currency, reason, balance_after)
           values (v_ord.user_id, 'credit', v_ord.diamonds, 'diamond', v_ord.package_name, v_bal + v_ord.diamonds);
    end if;
    insert into public.notifications (user_id, title, body, kind)
         values (v_ord.user_id, v_emoji || ' Order approved',
                 format('%s %s added to your account!', v_ord.diamonds, v_label), 'success');
  elsif p_status = 'rejected' and v_ord.user_id is not null then
    insert into public.notifications (user_id, title, body, kind)
         values (v_ord.user_id, '❌' || ' Order declined', coalesce(p_note, 'Please resubmit.'), 'error');
  end if;

  return public.json_ok();
end;
$$;

grant execute on function public.update_diamond_order(uuid, text, text) to anon;

-- 6.9 admin_update_member_status
create or replace function public.admin_update_member_status(p_user_id uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set status = p_status, updated_at = now() where id = p_user_id;
  if not found then return public.json_err('user_not_found'); end if;
  insert into public.notifications (user_id, title, body, kind)
       values (p_user_id,
               case when p_status = 'active'   then '🎉 Account activated'
                    when p_status = 'suspended' then '⚠️ Account suspended'
                    else 'ℹ️ Status changed' end,
               case when p_status = 'active'   then 'Welcome back! Full access restored.'
                    when p_status = 'suspended' then 'Your account has been suspended. Contact support.'
                    else 'Your account status has been updated.' end,
               case when p_status = 'active' then 'success'
                    when p_status = 'suspended' then 'error'
                    else 'info' end);
  return public.json_ok();
end; $$;

grant execute on function public.admin_update_member_status(uuid, text) to anon;

-- 6.10 admin_approve_booking_code
create or replace function public.admin_approve_booking_code(
  p_request_id uuid, p_code text, p_market text, p_stake_time timestamptz
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_req public.booking_code_requests%rowtype;
begin
  select * into v_req from public.booking_code_requests where id = p_request_id for update;
  if v_req.id is null then return public.json_err('request_not_found'); end if;
  update public.booking_code_requests
     set code = p_code, market = p_market, stake_time = p_stake_time,
         status = 'approved', updated_at = now()
   where id = p_request_id;
  insert into public.notifications (user_id, title, body, kind)
       values (v_req.user_id, '⚽ Booking code ready',
               'Your eFootball code: ' || p_code, 'success');
  return public.json_ok();
end; $$;

grant execute on function public.admin_approve_booking_code(uuid, text, text, timestamptz) to anon;

-- 6.11 admin_delete_record
create or replace function public.admin_delete_record(p_table text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_affected int;
begin
  if p_table not in ('profiles','payments','orders','predictions','booking_code_requests','spin_signals') then
    return public.json_err('invalid_table');
  end if;
  execute format('delete from public.%I where id = $1', p_table) using p_id;
  get diagnostics v_affected = row_count;
  return public.json_ok(jsonb_build_object('deleted', v_affected));
end; $$;

grant execute on function public.admin_delete_record(text, uuid) to anon;

-- 6.12 admin_insert_prediction (admin demo predictions)
create or replace function public.admin_insert_prediction(p_user_id uuid, p_result jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.predictions (user_id, result) values (p_user_id, p_result) returning id into v_id;
  return public.json_ok(jsonb_build_object('prediction_id', v_id));
end; $$;

grant execute on function public.admin_insert_prediction(uuid, jsonb) to anon;

-- 6.13 admin_get_payment_proof_url / admin_get_order_proof_url
create or replace function public.admin_get_payment_proof_url(p_payment_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_path text;
begin
  select screenshot_path into v_path from public.payments where id = p_payment_id;
  return jsonb_build_object('path', v_path);
end; $$;
create or replace function public.admin_get_order_proof_url(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_path text;
begin
  select screenshot_path into v_path from public.orders where id = p_order_id;
  return jsonb_build_object('path', v_path);
end; $$;

grant execute on function public.admin_get_payment_proof_url(uuid) to anon;
grant execute on function public.admin_get_order_proof_url(uuid)   to anon;

-- 6.14 admin_get_all_data (single big admin RPC, bypasses RLS)
create or replace function public.admin_get_all_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
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
begin
  select coalesce(jsonb_agg(p order by p.created_at desc), '[]'::jsonb)
    into v_members
    from public.profiles p;

  select coalesce(jsonb_agg(p order by p.created_at desc), '[]'::jsonb)
    into v_payments
    from public.payments p;

  select coalesce(jsonb_agg(o order by o.created_at desc), '[]'::jsonb)
    into v_orders
    from public.orders o;

  select coalesce(jsonb_agg(pr order by pr.created_at desc), '[]'::jsonb)
    into v_predictions
    from public.predictions pr;

  select coalesce(jsonb_agg(b order by b.created_at desc), '[]'::jsonb)
    into v_efootball
    from public.booking_code_requests b;

  select coalesce(jsonb_agg(t order by t.created_at desc), '[]'::jsonb)
    into v_ticket_tx
    from public.ticket_transactions t;

  select coalesce(jsonb_agg(s order by s.created_at desc), '[]'::jsonb)
    into v_spin_signals
    from public.spin_signals s;

  select to_jsonb(s.*) into v_pricing from public.settings s where id = 'global_config';
  v_pricing := coalesce(v_pricing, '{}'::jsonb);

  v_payment_set := jsonb_build_object(
    'payment_ghana',   v_pricing->'payment_ghana',
    'payment_nigeria', v_pricing->'payment_nigeria'
  );

  v_earnings := jsonb_build_object(
    'totalGHS', coalesce((select sum(amount) from public.payments where status='approved' and currency='GHS'), 0)
               + coalesce((select sum(amount) from public.orders where status='approved' and currency='GHS'), 0),
    'totalNGN', coalesce((select sum(amount) from public.payments where status='approved' and currency='NGN'), 0)
               + coalesce((select sum(amount) from public.orders where status='approved' and currency='NGN'), 0)
  );

  v_stats := jsonb_build_object(
    'revenue', jsonb_build_object(
      'GHS', coalesce((select sum(amount) from public.payments where status='approved' and currency='GHS'), 0),
      'NGN', coalesce((select sum(amount) from public.payments where status='approved' and currency='NGN'), 0)
    ),
    'pending', (
      (select count(*) from public.payments where status='pending') +
      (select count(*) from public.orders   where status='pending') +
      (select count(*) from public.booking_code_requests where status='pending')
    ),
    'members', (select count(*) from public.profiles)
  );

  return jsonb_build_object(
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
end; $$;

grant execute on function public.admin_get_all_data() to anon;

-- 6.15 admin_update_settings (single jsonb payload)
create or replace function public.admin_update_settings(p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
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

grant execute on function public.admin_update_settings(jsonb) to anon;

-- Seed default packages
update public.settings
   set diamond_packages = '[
    {"id":"starter","name":"Starter","diamonds":2,"ghs":350,"ngn":35000,
     "features":["3 match predictions","Standard accuracy","Email support"],
     "example":"Man City vs Liverpool → Home Win 2-1 (82%)",
     "popular":false,"tone":"emerald"},
    {"id":"pro","name":"Pro","diamonds":3,"ghs":500,"ngn":50000,
     "features":["10 match predictions","Gemini AI analysis","Priority processing","Score + goals tips"],
     "example":"Arsenal vs Chelsea → Home Win 3-1 (89%) + Over 2.5 goals",
     "popular":true,"tone":"gold"},
    {"id":"standard","name":"Standard","diamonds":5,"ghs":850,"ngn":85000,
     "features":["20 match predictions","Gemini AI analysis","Priority processing","Score + goals tips","Detailed stats"],
     "example":"Barcelona vs PSG → Home Win 2-1 (91%) + BTTS Yes",
     "popular":false,"tone":"emerald"},
    {"id":"premium","name":"Premium","diamonds":7,"ghs":1000,"ngn":100000,
     "features":["Unlimited predictions","Gemini AI + screenshot OCR","Instant processing","Full analysis + notes","VIP support"],
     "example":"Real Madrid vs Barcelona → Draw 2-2 (94%) + BTTS Yes",
     "popular":false,"tone":"ice"},
    {"id":"elite","name":"Elite","diamonds":10,"ghs":1500,"ngn":150000,
     "features":["Unlimited predictions","Gemini AI + screenshot OCR","Instant processing","Full analysis + notes","VIP support","Priority support"],
     "example":"Man City vs Liverpool → Home Win 3-1 (96%) + Over 2.5 goals",
     "popular":false,"tone":"gold"}
  ]'::jsonb,
       gold_packages = '[
    {"id":"gold-basic","name":"Basic","coins":2,"ghs":350,"ngn":35000,
     "features":["3 spin reveals","Standard signals","Email support"],
     "example":"Tomorrow 14:00 → Man City Win (78%)",
     "popular":false,"tone":"emerald"},
    {"id":"gold-pro","name":"Pro","coins":3,"ghs":500,"ngn":50000,
     "features":["10 spin reveals","AI-powered signals","Priority processing","Score predictions"],
     "example":"Tomorrow 16:30 → Arsenal Win 2-1 (85%) + BTTS",
     "popular":true,"tone":"gold"},
    {"id":"gold-standard","name":"Standard","coins":5,"ghs":850,"ngn":85000,
     "features":["20 spin reveals","AI-powered signals","Priority processing","Score predictions","Detailed stats"],
     "example":"Liverpool vs Arsenal → Draw 1-1 (88%) + Under 2.5",
     "popular":false,"tone":"emerald"},
    {"id":"gold-premium","name":"Premium","coins":7,"ghs":1000,"ngn":100000,
     "features":["Unlimited reveals","Full AI analysis","Instant processing","Detailed match notes","VIP support"],
     "example":"Liverpool vs Chelsea → Draw 2-2 (91%) + Over 2.5",
     "popular":false,"tone":"ice"},
    {"id":"gold-elite","name":"Elite","coins":10,"ghs":1500,"ngn":150000,
     "features":["Unlimited reveals","Full AI analysis","Instant processing","Detailed match notes","VIP support","Priority support"],
     "example":"Man City vs Arsenal → Home Win 2-1 (93%) + BTTS Yes",
     "popular":false,"tone":"gold"}
  ]'::jsonb
 where id = 'global_config';

-- RPC: read current packages for the client
create or replace function public.get_packages()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'diamonds', diamond_packages,
    'gold',     gold_packages
  )
    from public.settings where id = 'global_config';
$$;
grant execute on function public.get_packages() to authenticated;

-- RPC: admin updates packages
create or replace function public.admin_update_packages(
  p_kind      text,
  p_packages  jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_col text;
begin
  if p_kind not in ('diamonds','gold') then
    return public.json_err('invalid_kind');
  end if;
  v_col := case when p_kind = 'diamonds' then 'diamond_packages' else 'gold_packages' end;

  execute format('update public.settings set %I = $1, updated_at = now() where id = ''global_config''', v_col)
    using p_packages;

  insert into public.app_secrets (id) values ('global') on conflict do nothing;
  update public.app_secrets set updated_at = now() where id = 'global';

  return public.json_ok(jsonb_build_object('kind', p_kind, 'packages', p_packages));
end; $$;

grant execute on function public.admin_update_packages(text, jsonb) to anon;

-- 6.16 get_gemini_key
create or replace function public.get_gemini_key()
returns table (gemini_api_key text) language sql security definer set search_path = public as $$
  select gemini_api_key from public.app_secrets where id = 'global';
$$;
grant execute on function public.get_gemini_key() to authenticated;

-- ============================================================================
-- FIX #3: get_app_secrets now VALIDATES the admin passcode before returning
-- secrets. Previously it accepted any passcode and returned everything.
-- ============================================================================
create or replace function public.get_app_secrets(p_passcode text)
returns table (gemini_api_key text, admin_passcode text)
language plpgsql security definer set search_path = public as $$
declare v_stored text;
begin
  select admin_passcode into v_stored from public.app_secrets where id = 'global';
  if v_stored is null then
    raise exception 'app_secrets not configured';
  end if;
  if p_passcode is null or p_passcode != v_stored then
    raise exception 'invalid passcode';
  end if;
  return query select s.gemini_api_key, s.admin_passcode from public.app_secrets s where s.id = 'global';
end;
$$;

grant execute on function public.get_app_secrets(text) to anon;

-- ============================================================================
-- FIX #4: update_app_secrets now VALIDATES the admin passcode before allowing
-- updates. Previously anyone could overwrite the Gemini API key.
-- ============================================================================
create or replace function public.update_app_secrets(p_passcode text, p_gemini_api_key text)
returns void language plpgsql security definer set search_path = public as $$
declare v_stored text;
begin
  select admin_passcode into v_stored from public.app_secrets where id = 'global';
  if v_stored is null then
    raise exception 'app_secrets not configured';
  end if;
  if p_passcode is null or p_passcode != v_stored then
    raise exception 'invalid passcode';
  end if;
  update public.app_secrets
     set gemini_api_key = coalesce(p_gemini_api_key, gemini_api_key),
         updated_at = now()
   where id = 'global';
end;
$$;

grant execute on function public.update_app_secrets(text, text) to anon;

-- 6.17 Admin passcode & session

create or replace function public.verify_admin_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_stored text;
begin
  select admin_passcode into v_stored from public.app_secrets where id = 'global';
  if v_stored is null then return public.json_err('not_configured'); end if;
  if p_code = v_stored then return public.json_ok(); end if;
  return public.json_err('invalid_code');
end; $$;

grant execute on function public.verify_admin_code(text) to anon;

-- ============================================================================
-- FIX #2: check_admin_session was only granted to authenticated.
-- The admin panel uses the ANON (publishable) key, not a logged-in user session.
-- Without the anon grant, the admin panel's initial session check always fails.
-- ============================================================================
create or replace function public.check_admin_session()
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('unlocked', false);
$$;
grant execute on function public.check_admin_session() to anon;
grant execute on function public.check_admin_session() to authenticated;

create or replace function public.change_admin_access_code(p_new_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if length(p_new_code) < 4 then return public.json_err('too_short'); end if;
  update public.app_secrets set admin_passcode = p_new_code, updated_at = now() where id = 'global';
  return public.json_ok();
end; $$;

grant execute on function public.change_admin_access_code(text) to anon;

create or replace function public.log_admin_action(p_action text)
returns void language sql security definer set search_path = public as $$ select null; $$;

grant execute on function public.log_admin_action(text) to anon;

-- 
-- 7. DONE — all tables, RLS, RPCs, storage policies, and realtime
--    publication are in place.
-- 