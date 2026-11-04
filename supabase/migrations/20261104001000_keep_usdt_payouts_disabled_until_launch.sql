-- Keep cash payouts disabled until CHOX scoring, compliance, treasury funding and payout testing are ready.
alter table private.reward_settings
  add column if not exists payouts_enabled boolean not null default false;

update private.reward_settings
set payouts_enabled = false
where setting_key = 'default';

create or replace function public.get_my_usdt_payout_config()
returns table(payouts_enabled boolean, points_per_usd numeric, minimum_redemption_points bigint)
language sql stable security definer set search_path = ''
as $function$
  select s.payouts_enabled, s.points_per_usd, s.minimum_redemption_points
  from private.reward_settings s where s.setting_key = 'default';
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
  v_payouts_enabled boolean;
  v_address text;
  v_usd numeric(18,2);
  v_request_id uuid := gen_random_uuid();
begin
  if v_user_id is null then
    raise exception 'Sign in before requesting a payout.' using errcode = '42501';
  end if;
  select s.points_per_usd, s.minimum_redemption_points, s.payouts_enabled
    into v_points_per_usd, v_minimum, v_payouts_enabled
  from private.reward_settings s where s.setting_key = 'default';
  if v_payouts_enabled is distinct from true then
    raise exception 'USDT payouts are not open yet. Your CHOX remains in your rewards wallet.';
  end if;
  if p_points is null or p_points <= 0 then raise exception 'Enter a valid CHOX amount.'; end if;
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

revoke all on function public.get_my_usdt_payout_config() from public, anon;
grant execute on function public.get_my_usdt_payout_config() to authenticated;
