-- Fail closed on all browser-reported Fruit Fancy CHOX claims.
-- The current browser generates its own board and score, so the database cannot
-- independently verify a claimed result. Keep rewards paused until session replay
-- validation is deployed.

create or replace function private.claim_fruit_fancy_chox(
  p_level integer,
  p_stage text,
  p_extra_time_used integer,
  p_score integer
)
returns table(awarded bigint, level_total bigint)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_current bigint := 0;
begin
  if v_user_id is null then
    raise exception 'Sign in to view CHOX reward status.' using errcode = '42501';
  end if;

  if p_level is null or p_level not between 1 and 5 then
    raise exception 'Invalid Fruit Fancy level.';
  end if;

  select coalesce(p.reward_total, 0)
    into v_current
  from private.reward_game_level_progress p
  where p.user_id = v_user_id
    and p.game_id = 'fruit-fancy'
    and p.level = p_level;

  -- Intentionally award zero: client-supplied score/stage/time are untrusted.
  return query select 0::bigint, coalesce(v_current, 0)::bigint;
end;
$function$;

comment on function private.claim_fruit_fancy_chox(integer,text,integer,integer)
is 'Fail-closed: CHOX credit is paused until server-authoritative Fruit Fancy sessions and move replay verification are deployed. Client-reported score parameters are never trusted.';

revoke all on function private.claim_fruit_fancy_chox(integer,text,integer,integer) from public, anon;
grant execute on function private.claim_fruit_fancy_chox(integer,text,integer,integer) to authenticated;
