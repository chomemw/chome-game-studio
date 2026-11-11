-- Rush Arena level progression and one-time CHOX completion rewards
create table if not exists private.rush_arena_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  level integer not null check (level between 1 and 250),
  status text not null default 'started' check (status in ('started','completed','expired','rejected')),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  elapsed_seconds integer,
  obstacles_passed integer,
  final_score integer,
  chox_awarded bigint not null default 0,
  points_awarded bigint not null default 0
);
create index if not exists rush_arena_sessions_user_started_idx on private.rush_arena_sessions(user_id, started_at desc);
create table if not exists private.rush_arena_level_progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  level integer not null check (level between 1 and 250),
  first_completed_at timestamptz not null default now(),
  best_score integer not null default 0 check (best_score between 0 and 4200),
  best_time_seconds integer check (best_time_seconds between 1 and 3600),
  times_completed integer not null default 1 check (times_completed >= 1),
  chox_awarded bigint not null default 0 check (chox_awarded between 0 and 210),
  updated_at timestamptz not null default now(),
  primary key(user_id, level)
);
alter table private.rush_arena_sessions enable row level security;
alter table private.rush_arena_level_progress enable row level security;
revoke all on private.rush_arena_sessions from public, anon, authenticated;
revoke all on private.rush_arena_level_progress from public, anon, authenticated;

create or replace function public.service_rush_arena_start(p_user_id uuid, p_level integer)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_unlocked integer; v_session private.rush_arena_sessions%rowtype; v_recent integer;
begin
 if coalesce(auth.jwt()->>'role','') <> 'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
 perform private.assert_player_not_restricted(p_user_id);
 if p_user_id is null or p_level is null or p_level not between 1 and 250 then return jsonb_build_object('ok',false,'error','Invalid Rush Arena level.'); end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text,91));
 select greatest(1,least(250,coalesce(max(level),0)+1)) into v_unlocked from private.rush_arena_level_progress where user_id=p_user_id;
 if p_level>v_unlocked then return jsonb_build_object('ok',false,'error','This level is locked. Complete the previous level first.','highest_unlocked',v_unlocked); end if;
 select count(*) into v_recent from private.rush_arena_sessions where user_id=p_user_id and started_at>=now()-interval '1 hour';
 if v_recent>=20 then return jsonb_build_object('ok',false,'error','Too many Rush Arena starts. Try again later.'); end if;
 update private.rush_arena_sessions set status='expired' where user_id=p_user_id and status='started' and started_at<now()-interval '1 hour';
 insert into private.rush_arena_sessions(user_id,level) values(p_user_id,p_level) returning * into v_session;
 return jsonb_build_object('ok',true,'session_id',v_session.id,'level',p_level,'started_at',v_session.started_at);
end;
$$;

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
 if extract(epoch from(now()-v_session.started_at))<85 or extract(epoch from(now()-v_session.started_at))>3600 then
  return jsonb_build_object('ok',false,'error','The recorded play time does not match a completed course.'); end if;

 insert into private.rush_arena_level_progress(user_id,level,best_score,best_time_seconds,times_completed,chox_awarded)
 values(p_user_id,v_session.level,p_score,p_elapsed_seconds,1,0) on conflict(user_id,level) do nothing;
 select * into v_progress from private.rush_arena_level_progress where user_id=p_user_id and level=v_session.level for update;
 v_first := v_progress.times_completed=1 and v_progress.first_completed_at>=v_session.started_at-interval '2 seconds';

 v_points:=p_score;
 v_points_result:=public.service_credit_game_points(p_user_id,v_points,'rush-arena-level-completion',p_session_id::text,
  'Rush Arena Level '||v_session.level||' completion',
  jsonb_build_object('game_id','rush-arena','level',v_session.level,'replay',not v_first,'obstacles_passed',p_obstacles_passed));
 if coalesce((v_points_result->>'credited')::boolean,false) then
  update private.rush_arena_level_progress set
   times_completed=times_completed+case when not v_first then 1 else 0 end,
   best_score=greatest(best_score,p_score),
   best_time_seconds=case when best_time_seconds is null then p_elapsed_seconds else least(best_time_seconds,p_elapsed_seconds) end,
   updated_at=now()
  where user_id=p_user_id and level=v_session.level;
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
  points_awarded=case when coalesce((v_points_result->>'credited')::boolean,false) then v_points else 0 end
  where id=p_session_id;
 insert into private.game_score_events(user_id,game_id,level,score) values(p_user_id,'rush-arena',v_session.level,p_score);
 return jsonb_build_object('ok',true,'level',v_session.level,'first_completion',v_first,'chox_credited',v_chox,
  'points_credited',case when coalesce((v_points_result->>'credited')::boolean,false) then v_points else 0 end,
  'highest_unlocked',least(250,(select coalesce(max(level),0)+1 from private.rush_arena_level_progress where user_id=p_user_id)));
end;
$$;

create or replace function public.service_rush_arena_progress(p_user_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_levels integer[];
begin
 if coalesce(auth.jwt()->>'role','') <> 'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
 select coalesce(array_agg(level order by level),array[]::integer[]) into v_levels from private.rush_arena_level_progress where user_id=p_user_id;
 return jsonb_build_object('completed_levels',to_jsonb(v_levels),
  'highest_unlocked',least(250,greatest(1,coalesce((select max(level)+1 from private.rush_arena_level_progress where user_id=p_user_id),1))),
  'total_levels',250);
end;
$$;
revoke all on function public.service_rush_arena_start(uuid,integer) from public,anon,authenticated;
revoke all on function public.service_rush_arena_finish(uuid,uuid,integer,integer,integer) from public,anon,authenticated;
revoke all on function public.service_rush_arena_progress(uuid) from public,anon,authenticated;
grant execute on function public.service_rush_arena_start(uuid,integer) to service_role;
grant execute on function public.service_rush_arena_finish(uuid,uuid,integer,integer,integer) to service_role;
grant execute on function public.service_rush_arena_progress(uuid) to service_role;
