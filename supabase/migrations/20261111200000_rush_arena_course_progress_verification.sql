-- Add server-side distance checkpoints and require the full Rush Arena course before completion.
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

create or replace function public.service_rush_arena_finish(p_user_id uuid,p_session_id uuid,p_elapsed_seconds integer,p_obstacles_passed integer,p_score integer)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_session private.rush_arena_sessions%rowtype; v_progress private.rush_arena_level_progress%rowtype;
 v_first boolean; v_chox bigint:=0; v_points bigint:=0; v_chox_result jsonb; v_points_result jsonb;
begin
 if coalesce(auth.jwt()->>'role','') <> 'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
 perform private.assert_player_not_restricted(p_user_id);
 if p_user_id is null or p_session_id is null or p_elapsed_seconds is null or p_elapsed_seconds<85 or p_elapsed_seconds>3600
  or p_obstacles_passed is null or p_obstacles_passed<0 or p_obstacles_passed>42 or p_score is null or p_score<>p_obstacles_passed*100
 then return jsonb_build_object('ok',false,'error','Rush Arena completion data is invalid or the course was not completed in a valid time.'); end if;
 select * into v_session from private.rush_arena_sessions where id=p_session_id and user_id=p_user_id for update;
 if not found or v_session.status<>'started' then return jsonb_build_object('ok',false,'error','This Rush Arena session is invalid or has already been used.'); end if;
 if extract(epoch from(now()-v_session.started_at))<85 or extract(epoch from(now()-v_session.started_at))>3600 or v_session.furthest_distance<660 then
  return jsonb_build_object('ok',false,'error','The full Rush Arena course has not been verified as completed yet.'); end if;
 insert into private.rush_arena_level_progress(user_id,level,best_score,best_time_seconds,times_completed,chox_awarded)
 values(p_user_id,v_session.level,p_score,p_elapsed_seconds,1,0) on conflict(user_id,level) do nothing;
 select * into v_progress from private.rush_arena_level_progress where user_id=p_user_id and level=v_session.level for update;
 v_first:=v_progress.times_completed=1 and v_progress.first_completed_at>=v_session.started_at-interval '2 seconds';
 v_points:=p_score;
 v_points_result:=public.service_credit_game_points(p_user_id,v_points,'rush-arena-level-completion',p_session_id::text,
  'Rush Arena Level '||v_session.level||' completion',
  jsonb_build_object('game_id','rush-arena','level',v_session.level,'replay',not v_first,'obstacles_passed',p_obstacles_passed));
 if coalesce((v_points_result->>'credited')::boolean,false) then
  update private.rush_arena_level_progress set times_completed=times_completed+case when not v_first then 1 else 0 end,
   best_score=greatest(best_score,p_score),
   best_time_seconds=case when best_time_seconds is null then p_elapsed_seconds else least(best_time_seconds,p_elapsed_seconds) end,
   updated_at=now() where user_id=p_user_id and level=v_session.level;
 end if;
 if v_first and v_progress.chox_awarded=0 and p_obstacles_passed>0 then
  v_chox:=p_obstacles_passed*5;
  v_chox_result:=private.credit_chox(p_user_id,v_chox,'rush-arena-first-level-completion',
   'rush-arena-level-'||v_session.level||'-first-completion',
   'First completion reward — Rush Arena Level '||v_session.level,
   jsonb_build_object('game_id','rush-arena','level',v_session.level,'obstacles_passed',p_obstacles_passed));
  if coalesce((v_chox_result->>'credited')::boolean,false) then
   update private.rush_arena_level_progress set chox_awarded=v_chox,updated_at=now() where user_id=p_user_id and level=v_session.level;
  else v_chox:=0; end if;
 end if;
 update private.rush_arena_level_progress set best_score=greatest(best_score,p_score),
  best_time_seconds=case when best_time_seconds is null then p_elapsed_seconds else least(best_time_seconds,p_elapsed_seconds) end,
  updated_at=now() where user_id=p_user_id and level=v_session.level;
 update private.rush_arena_sessions set status='completed',completed_at=now(),elapsed_seconds=p_elapsed_seconds,
  obstacles_passed=p_obstacles_passed,final_score=p_score,chox_awarded=v_chox,
  points_awarded=case when coalesce((v_points_result->>'credited')::boolean,false) then v_points else 0 end where id=p_session_id;
 insert into private.game_score_events(user_id,game_id,level,score) values(p_user_id,'rush-arena',v_session.level,p_score);
 return jsonb_build_object('ok',true,'level',v_session.level,'first_completion',v_first,'chox_credited',v_chox,
  'points_credited',case when coalesce((v_points_result->>'credited')::boolean,false) then v_points else 0 end,
  'highest_unlocked',least(250,(select coalesce(max(level),0)+1 from private.rush_arena_level_progress where user_id=p_user_id)));
end;
$$;
