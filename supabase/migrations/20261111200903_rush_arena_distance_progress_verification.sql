alter table private.rush_arena_sessions
  add column if not exists furthest_distance numeric(7,2) not null default 0,
  add column if not exists last_progress_at timestamptz not null default now();

create or replace function public.service_rush_arena_checkpoint(p_user_id uuid,p_session_id uuid,p_distance numeric)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_session private.rush_arena_sessions%rowtype; v_delta_seconds numeric; v_max_distance numeric;
begin
 if coalesce(auth.jwt()->>'role','') <> 'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
 if p_user_id is null or p_session_id is null or p_distance is null or p_distance<0 or p_distance>665 then
  return jsonb_build_object('ok',false,'error','Invalid Rush Arena progress checkpoint.');
 end if;
 select * into v_session from private.rush_arena_sessions where id=p_session_id and user_id=p_user_id for update;
 if not found or v_session.status<>'started' then return jsonb_build_object('ok',false,'error','Rush Arena session is not active.'); end if;
 v_delta_seconds:=greatest(0.25,extract(epoch from(now()-v_session.last_progress_at)));
 v_max_distance:=v_session.furthest_distance+(v_delta_seconds*8.5)+8;
 if p_distance>v_max_distance then
  return jsonb_build_object('ok',false,'error','Progress speed exceeded the course limit.','furthest_distance',v_session.furthest_distance);
 end if;
 update private.rush_arena_sessions set furthest_distance=greatest(furthest_distance,p_distance),last_progress_at=now() where id=p_session_id;
 return jsonb_build_object('ok',true,'furthest_distance',greatest(v_session.furthest_distance,p_distance));
end;
$$;
revoke all on function public.service_rush_arena_checkpoint(uuid,uuid,numeric) from public,anon,authenticated;
grant execute on function public.service_rush_arena_checkpoint(uuid,uuid,numeric) to service_role;
