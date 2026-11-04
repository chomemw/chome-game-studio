-- CHOME USDT payout request foundation.
-- This migration records redemption requests only. It does not sign or broadcast blockchain transactions.
-- Keep payout signing keys outside Supabase and outside the public website.

create table if not exists private.player_payout_wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  network text not null default 'TRON-TRC20',
  address text not null,
  user_confirmed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint player_payout_wallets_network_check check (network = 'TRON-TRC20'),
  constraint player_payout_wallets_address_check check (address ~ '^T[1-9A-HJ-NP-Za-km-z]{33}$')
);
alter table private.player_payout_wallets enable row level security;
revoke all on table private.player_payout_wallets from anon, authenticated;
drop policy if exists "Deny direct client access to payout wallets" on private.player_payout_wallets;
create policy "Deny direct client access to payout wallets"
  on private.player_payout_wallets for all to anon, authenticated
  using (false) with check (false);

create table if not exists private.payout_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  points_amount bigint not null check (points_amount > 0),
  usd_amount numeric(18,2) not null check (usd_amount > 0),
  asset text not null default 'USDT' check (asset = 'USDT'),
  network text not null default 'TRON-TRC20' check (network = 'TRON-TRC20'),
  destination_address text not null check (destination_address ~ '^T[1-9A-HJ-NP-Za-km-z]{33}$'),
  status text not null default 'pending' check (status in ('pending','paid','rejected')),
  tx_hash text unique check (tx_hash is null or tx_hash ~ '^[A-Fa-f0-9]{64}$'),
  admin_note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  processed_at timestamptz,
  processed_by uuid references auth.users(id) on delete set null
);
create index if not exists payout_requests_user_created_idx
  on private.payout_requests (user_id, created_at desc);
create index if not exists payout_requests_pending_idx
  on private.payout_requests (created_at asc) where status = 'pending';
alter table private.payout_requests enable row level security;
revoke all on table private.payout_requests from anon, authenticated;
drop policy if exists "Deny direct client access to payout requests" on private.payout_requests;
create policy "Deny direct client access to payout requests"
  on private.payout_requests for all to anon, authenticated
  using (false) with check (false);

create or replace function public.save_my_usdt_payout_address(p_address text)
returns table(network text, address text, user_confirmed_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_address text := btrim(p_address);
begin
  if v_user_id is null then
    raise exception 'Sign in before saving a payout address.' using errcode = '42501';
  end if;
  if v_address is null or v_address !~ '^T[1-9A-HJ-NP-Za-km-z]{33}$' then
    raise exception 'Enter a valid TRON Base58 address for USDT TRC20.';
  end if;
  insert into private.player_payout_wallets (user_id, network, address, user_confirmed_at, updated_at)
  values (v_user_id, 'TRON-TRC20', v_address, now(), now())
  on conflict (user_id) do update
    set network = excluded.network, address = excluded.address,
        user_confirmed_at = now(), updated_at = now();
  return query select w.network, w.address, w.user_confirmed_at
    from private.player_payout_wallets w where w.user_id = v_user_id;
end;
$function$;

create or replace function public.get_my_usdt_payout_address()
returns table(network text, address text, user_confirmed_at timestamptz)
language sql stable security definer set search_path = ''
as $function$
  select w.network, w.address, w.user_confirmed_at
  from private.player_payout_wallets w where w.user_id = (select auth.uid());
$function$;

create or replace function public.get_my_usdt_payout_requests()
returns table(
  id uuid, points_amount bigint, usd_amount numeric, asset text, network text,
  destination_address text, status text, tx_hash text, admin_note text,
  created_at timestamptz, processed_at timestamptz
)
language sql stable security definer set search_path = ''
as $function$
  select r.id, r.points_amount, r.usd_amount, r.asset, r.network,
         r.destination_address, r.status, r.tx_hash, r.admin_note,
         r.created_at, r.processed_at
  from private.payout_requests r
  where r.user_id = (select auth.uid())
  order by r.created_at desc limit 50;
$function$;

create or replace function public.request_usdt_payout(p_points bigint)
returns table(request_id uuid, points_amount bigint, usd_amount numeric, status text)
language plpgsql security definer set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_balance bigint;
  v_points_per_usd numeric;
  v_minimum bigint;
  v_address text;
  v_usd numeric(18,2);
  v_request_id uuid := gen_random_uuid();
begin
  if v_user_id is null then
    raise exception 'Sign in before requesting a payout.' using errcode = '42501';
  end if;
  if p_points is null or p_points <= 0 then raise exception 'Enter a valid CHOX amount.'; end if;
  select s.points_per_usd, s.minimum_redemption_points
    into v_points_per_usd, v_minimum
  from private.reward_settings s where s.setting_key = 'default';
  if v_points_per_usd is null or v_points_per_usd <= 0 then
    raise exception 'The CHOX conversion rate is not configured.';
  end if;
  if p_points < coalesce(v_minimum, 0) then
    raise exception 'This request is below the current minimum redemption amount.';
  end if;
  select w.address into v_address
  from private.player_payout_wallets w where w.user_id = v_user_id;
  if v_address is null then
    raise exception 'Save your USDT TRC20 receiving address before requesting a payout.';
  end if;
  select w.points_balance into v_balance
  from private.reward_wallets w where w.user_id = v_user_id for update;
  if v_balance is null or v_balance < p_points then
    raise exception 'Your available CHOX balance is insufficient.';
  end if;
  v_usd := round(p_points::numeric / v_points_per_usd, 2);
  if v_usd < 0.01 then
    raise exception 'The requested CHOX amount is below the smallest supported USDT payout.';
  end if;
  insert into private.payout_requests (
    id, user_id, points_amount, usd_amount, asset, network,
    destination_address, status, created_at, updated_at
  ) values (
    v_request_id, v_user_id, p_points, v_usd, 'USDT', 'TRON-TRC20',
    v_address, 'pending', now(), now()
  );
  update private.reward_wallets
  set points_balance = points_balance - p_points,
      lifetime_redeemed = lifetime_redeemed + p_points, updated_at = now()
  where user_id = v_user_id;
  insert into private.reward_ledger (
    user_id, entry_type, points_delta, source, source_ref, description, metadata
  ) values (
    v_user_id, 'redeem', -p_points, 'usdt-payout-request', v_request_id::text,
    'CHOX reserved for USDT TRC20 payout request',
    jsonb_build_object('payout_request_id', v_request_id, 'usd_amount', v_usd,
                       'network', 'TRON-TRC20', 'destination_address', v_address)
  );
  return query select v_request_id, p_points, v_usd, 'pending'::text;
end;
$function$;

create or replace function private.admin_mark_usdt_payout_paid(
  p_request_id uuid, p_tx_hash text, p_admin_note text default ''
)
returns void language plpgsql security definer set search_path = ''
as $function$
begin
  if p_tx_hash is null or p_tx_hash !~ '^[A-Fa-f0-9]{64}$' then
    raise exception 'A valid 64-character TRON transaction hash is required.';
  end if;
  update private.payout_requests
  set status = 'paid', tx_hash = lower(p_tx_hash),
      admin_note = left(coalesce(p_admin_note, ''), 500),
      processed_at = now(), updated_at = now()
  where id = p_request_id and status = 'pending' and tx_hash is null;
  if not found then raise exception 'Payout request not found or no longer pending.'; end if;
end;
$function$;

create or replace function private.admin_reject_usdt_payout(p_request_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = ''
as $function$
declare v_request private.payout_requests%rowtype;
begin
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'Provide a clear rejection reason.';
  end if;
  select * into v_request from private.payout_requests
  where id = p_request_id and status = 'pending' for update;
  if not found then raise exception 'Payout request not found or no longer pending.'; end if;
  update private.reward_wallets
  set points_balance = points_balance + v_request.points_amount,
      lifetime_redeemed = greatest(0, lifetime_redeemed - v_request.points_amount),
      updated_at = now()
  where user_id = v_request.user_id;
  insert into private.reward_ledger (
    user_id, entry_type, points_delta, source, source_ref, description, metadata
  ) values (
    v_request.user_id, 'reversal', v_request.points_amount,
    'usdt-payout-reversal', v_request.id::text,
    'CHOX returned after payout request rejection',
    jsonb_build_object('payout_request_id', v_request.id, 'reason', left(btrim(p_reason), 500))
  );
  update private.payout_requests
  set status = 'rejected', admin_note = left(btrim(p_reason), 500),
      processed_at = now(), updated_at = now()
  where id = v_request.id;
end;
$function$;

revoke all on function public.save_my_usdt_payout_address(text) from public, anon;
revoke all on function public.get_my_usdt_payout_address() from public, anon;
revoke all on function public.get_my_usdt_payout_requests() from public, anon;
revoke all on function public.request_usdt_payout(bigint) from public, anon;
grant execute on function public.save_my_usdt_payout_address(text) to authenticated;
grant execute on function public.get_my_usdt_payout_address() to authenticated;
grant execute on function public.get_my_usdt_payout_requests() to authenticated;
grant execute on function public.request_usdt_payout(bigint) to authenticated;

revoke all on function private.admin_mark_usdt_payout_paid(uuid,text,text) from public, anon, authenticated;
revoke all on function private.admin_reject_usdt_payout(uuid,text) from public, anon, authenticated;
grant execute on function private.admin_mark_usdt_payout_paid(uuid,text,text) to service_role;
grant execute on function private.admin_reject_usdt_payout(uuid,text) to service_role;
