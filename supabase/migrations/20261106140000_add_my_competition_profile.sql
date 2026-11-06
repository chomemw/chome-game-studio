create or replace function public.get_my_competition_profile()
returns jsonb language sql stable security definer set search_path = ''
as $$
with
daily_specs(challenge_key,game_id,metric) as (
 values ('all_high_score','all','score'),('all_levels','all','levels'),
 ('candy_high_score','candy-trail','score'),('candy_levels','candy-trail','levels'),
 ('fruit_high_score','fruit-fancy','score'),('fruit_levels','fruit-fancy','levels'),
 ('blocks_high_score','chome-blocks','score'),('blocks_levels','chome-blocks','levels')
),
day_bounds as (
 select d::date as day
 from generate_series(
  coalesce((select min(created_at)::date from private.game_score_events),(now() at time zone 'Africa/Blantyre')::date),
  (now() at time zone 'Africa/Blantyre')::date - 1, interval '1 day'
 ) d
),
daily_metrics as (
 select b.day,s.challenge_key,e.user_id,
  case when s.metric='levels' then count(*)::bigint else max(e.score)::bigint end as points_metric
 from day_bounds b
 join private.game_score_events e
  on e.created_at >= (b.day::timestamp at time zone 'Africa/Blantyre')
 and e.created_at < ((b.day+1)::timestamp at time zone 'Africa/Blantyre')
 join daily_specs s on s.game_id='all' or s.game_id=e.game_id
 group by b.day,s.challenge_key,s.metric,e.user_id
),
daily_ranked as (
 select d.*,row_number() over(partition by d.day,d.challenge_key order by d.points_metric desc,d.user_id) as pos
 from daily_metrics d
),
weekly_stats as (
 select c.id as tournament_id,e.user_id,count(*)::bigint as levels_completed,
  sum(e.score)::bigint as total_score,max(e.score)::bigint as best_score
 from private.chome_competitions c
 join private.game_score_events e on e.game_id=c.game_id and e.created_at>=c.starts_at and e.created_at<c.ends_at
 where c.competition_type='weekly_tournament' and c.status not in ('draft','cancelled')
  and c.starts_at is not null and c.ends_at is not null and c.ends_at<=now()
 group by c.id,e.user_id
),
weekly_qualified as (
 select w.tournament_id,w.user_id,w.total_score,
  row_number() over(partition by w.tournament_id order by w.total_score desc,w.levels_completed desc,w.best_score desc,w.user_id) as pos
 from weekly_stats w join private.chome_competitions c on c.id=w.tournament_id
 where w.levels_completed>=c.qualification_min_levels and w.best_score>=c.qualification_min_score
),
entries as (
 select user_id,points_metric as competition_points,pos from daily_ranked
 union all
 select user_id,total_score as competition_points,pos from weekly_qualified
),
totals as (
 select user_id,count(*)::bigint as competitions_entered,
  count(*) filter(where pos=1)::bigint as wins,
  count(*) filter(where pos<=3)::bigint as top_three,
  coalesce(sum(competition_points),0)::numeric as total_competition_points
 from entries group by user_id
),
ranked_totals as (
 select t.*,row_number() over(order by t.total_competition_points desc,t.wins desc,t.user_id) as overall_rank
 from totals t
),
personal_bests as (
 select e.user_id,
  max(e.score) filter(where e.game_id='candy-trail')::bigint as candy_trail_best,
  max(e.score) filter(where e.game_id='fruit-fancy')::bigint as fruit_fancy_best,
  max(e.score) filter(where e.game_id='chome-blocks')::bigint as chome_blocks_best
 from private.game_score_events e group by e.user_id
)
select jsonb_build_object(
 'competition_rank',(select overall_rank from ranked_totals where user_id=auth.uid()),
 'competitions_entered',coalesce((select competitions_entered from ranked_totals where user_id=auth.uid()),0),
 'wins',coalesce((select wins from ranked_totals where user_id=auth.uid()),0),
 'top_three_finishes',coalesce((select top_three from ranked_totals where user_id=auth.uid()),0),
 'total_competition_points',coalesce((select total_competition_points from ranked_totals where user_id=auth.uid()),0),
 'personal_bests',jsonb_build_object(
  'candy_trail',coalesce((select candy_trail_best from personal_bests where user_id=auth.uid()),0),
  'fruit_fancy',coalesce((select fruit_fancy_best from personal_bests where user_id=auth.uid()),0),
  'chome_blocks',coalesce((select chome_blocks_best from personal_bests where user_id=auth.uid()),0)
 )
);
$$;
revoke all on function public.get_my_competition_profile() from public,anon;
grant execute on function public.get_my_competition_profile() to authenticated;
