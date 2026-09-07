-- Golden Dawn eFC core functional migration
-- Apply after the base schema.

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id,email,name,username,phone,efootball_id,status,role)
  values(new.id,coalesce(new.email,''),coalesce(new.raw_user_meta_data->>'full_name',''),coalesce(new.raw_user_meta_data->>'username',split_part(coalesce(new.email,''),'@',1)),coalesce(new.raw_user_meta_data->>'phone',''),coalesce(new.raw_user_meta_data->>'efootball_id',''),'pending','player')
  on conflict(id) do update set email=excluded.email;
  return new;
end; $$;
revoke all on function public.handle_new_user() from public;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.notify_profile_status() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.status is distinct from old.status then
    insert into public.notifications(user_id,title,body)
    values(new.id,case when new.status='approved' then 'Account approved' else 'Account status updated' end,case when new.status='approved' then 'Your Golden Dawn eFC account has been approved.' else 'Your account status is now '||new.status::text||'.' end);
  end if;
  return new;
end; $$;
revoke all on function public.notify_profile_status() from public;
drop trigger if exists profile_status_notification on public.profiles;
create trigger profile_status_notification after update of status on public.profiles for each row execute function public.notify_profile_status();

create or replace function public.notify_new_tournament() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.status='open' and (tg_op='INSERT' or old.status is distinct from new.status) then
    insert into public.notifications(user_id,title,body)
    select p.id,'New tournament open',new.title||' is now open for registration.' from public.profiles p where p.status='approved';
  end if;
  return new;
end; $$;
revoke all on function public.notify_new_tournament() from public;
drop trigger if exists tournament_open_notification on public.tournaments;
create trigger tournament_open_notification after insert or update of status on public.tournaments for each row execute function public.notify_new_tournament();

create or replace function public.join_tournament(p_tournament_id uuid) returns jsonb
language plpgsql security invoker set search_path=public as $$
declare uid uuid:=auth.uid(); t public.tournaments%rowtype; cnt int; countries jsonb:='[{"name":"Argentina","flag":"🇦🇷"},{"name":"Brazil","flag":"🇧🇷"},{"name":"France","flag":"🇫🇷"},{"name":"Germany","flag":"🇩🇪"},{"name":"Spain","flag":"🇪🇸"},{"name":"England","flag":"🏴"},{"name":"Portugal","flag":"🇵🇹"},{"name":"Italy","flag":"🇮🇹"},{"name":"Netherlands","flag":"🇳🇱"},{"name":"Croatia","flag":"🇭🇷"},{"name":"Belgium","flag":"🇧🇪"},{"name":"Uruguay","flag":"🇺🇾"},{"name":"Colombia","flag":"🇨🇴"},{"name":"Japan","flag":"🇯🇵"},{"name":"Morocco","flag":"🇲🇦"},{"name":"Mexico","flag":"🇲🇽"},{"name":"USA","flag":"🇺🇸"},{"name":"Senegal","flag":"🇸🇳"},{"name":"Denmark","flag":"🇩🇰"},{"name":"Switzerland","flag":"🇨🇭"},{"name":"Turkey","flag":"🇹🇷"},{"name":"South Korea","flag":"🇰🇷"},{"name":"Poland","flag":"🇵🇱"},{"name":"Sweden","flag":"🇸🇪"},{"name":"Norway","flag":"🇳🇴"},{"name":"Austria","flag":"🇦🇹"},{"name":"Nigeria","flag":"🇳🇬"},{"name":"Ghana","flag":"🇬🇭"},{"name":"Canada","flag":"🇨🇦"},{"name":"Ecuador","flag":"🇪🇨"},{"name":"Chile","flag":"🇨🇱"},{"name":"Australia","flag":"🇦🇺"}]'::jsonb; c jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status<>'open' then raise exception 'Tournament is not open'; end if;
  if exists(select 1 from public.tournament_players where tournament_id=p_tournament_id and player_id=uid) then return jsonb_build_object('joined',true,'message','Already registered'); end if;
  select count(*) into cnt from public.tournament_players where tournament_id=p_tournament_id;
  if t.max_players>0 and cnt>=t.max_players then raise exception 'Tournament is full'; end if;
  select x into c from jsonb_array_elements(countries) x order by random() limit 1;
  insert into public.tournament_players(tournament_id,player_id,country,flag,seed) values(p_tournament_id,uid,c->>'name',c->>'flag',cnt+1);
  return jsonb_build_object('joined',true,'country',c->>'name','flag',c->>'flag','seed',cnt+1);
end; $$;

create or replace function public.generate_bracket(p_tournament_id uuid) returns jsonb
language plpgsql security invoker set search_path=public as $$
declare t public.tournaments%rowtype; ids uuid[]; n int; size int; i int; p1 uuid; p2 uuid; stage text;
begin
  if not exists(select 1 from public.profiles where id=auth.uid() and status='approved' and role in('owner','admin','moderator')) then raise exception 'Staff only'; end if;
  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.mode<>'tree' then raise exception 'Tournament is not a tree tournament'; end if;
  select array_agg(player_id order by random()) into ids from public.tournament_players where tournament_id=p_tournament_id;
  n:=coalesce(array_length(ids,1),0); if n<2 then raise exception 'At least 2 players required'; end if;
  if n>t.max_players then raise exception 'Too many players'; end if;
  size:=1; while size<n loop size:=size*2; end loop; if size>32 then raise exception 'Maximum bracket size is 32'; end if;
  delete from public.tournament_matches where tournament_id=p_tournament_id;
  stage:=case when size=2 then 'final' when size=4 then 'semifinal' when size=8 then 'quarterfinal' else 'round_of_16' end;
  for i in 1..size/2 loop
    p1:=case when i*2-1<=n then ids[i*2-1] else null end; p2:=case when i*2<=n then ids[i*2] else null end;
    insert into public.tournament_matches(tournament_id,stage,round_no,match_no,player1_id,player2_id,status,winner_id) values(p_tournament_id,stage,1,i,p1,p2,case when p1 is null or p2 is null then 'completed' else 'upcoming' end,case when p1 is null then p2 when p2 is null then p1 else null end);
  end loop;
  update public.tournaments set status='ongoing' where id=p_tournament_id;
  return jsonb_build_object('created',size/2,'bracket_size',size);
end; $$;

create or replace function public.submit_match_result(p_match_id uuid,p_score_for int,p_score_against int) returns jsonb
language plpgsql security invoker set search_path=public as $$
declare m public.tournament_matches%rowtype; uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'Authentication required'; end if; if p_score_for<0 or p_score_against<0 then raise exception 'Invalid score'; end if;
  select * into m from public.tournament_matches where id=p_match_id for update;
  if not found then raise exception 'Match not found'; end if; if uid<>m.player1_id and uid<>m.player2_id then raise exception 'You are not a participant'; end if; if m.status='completed' then raise exception 'Match already completed'; end if;
  insert into public.tournament_result_submissions(match_id,player_id,score_for,score_against) values(p_match_id,uid,p_score_for,p_score_against);
  update public.tournament_matches set status='pending_admin',submitted_at=now(),updated_at=now() where id=p_match_id;
  return jsonb_build_object('submitted',true);
end; $$;

create or replace function public.approve_match_result(p_match_id uuid,p_winner uuid,p_score1 int,p_score2 int) returns jsonb
language plpgsql security invoker set search_path=public as $$
declare uid uuid:=auth.uid(); m public.tournament_matches%rowtype;
begin
  if not exists(select 1 from public.profiles where id=uid and status='approved' and role in('owner','admin','moderator')) then raise exception 'Staff only'; end if;
  select * into m from public.tournament_matches where id=p_match_id for update; if not found then raise exception 'Match not found'; end if;
  if p_winner is not null and p_winner not in(m.player1_id,m.player2_id) then raise exception 'Winner must be a participant'; end if;
  update public.tournament_matches set score1=p_score1,score2=p_score2,winner_id=p_winner,status='completed',approved_at=now(),approved_by=uid,updated_at=now() where id=p_match_id;
  if p_winner is not null then insert into public.notifications(user_id,title,body) values(p_winner,'Match approved','Your match result has been approved.'); end if;
  return jsonb_build_object('approved',true);
end; $$;

create or replace function public.admin_set_member_status(p_user_id uuid,p_status member_status) returns jsonb
language plpgsql security invoker set search_path=public as $$
begin
  if not exists(select 1 from public.profiles where id=auth.uid() and status='approved' and role in('owner','admin','moderator')) then raise exception 'Staff only'; end if;
  update public.profiles set status=p_status where id=p_user_id; if not found then raise exception 'Member not found'; end if;
  return jsonb_build_object('updated',true,'status',p_status::text);
end; $$;

create or replace function public.admin_create_tournament(p_title text,p_description text,p_start_at timestamptz,p_max_players int,p_mode text) returns uuid
language plpgsql security invoker set search_path=public as $$
declare tid uuid;
begin
  if not exists(select 1 from public.profiles where id=auth.uid() and status='approved' and role in('owner','admin','moderator')) then raise exception 'Staff only'; end if;
  if p_mode not in('league','tree') then raise exception 'Invalid mode'; end if;
  if p_mode='tree' and (p_max_players<2 or p_max_players>32) then raise exception 'Tree capacity must be 2-32'; end if;
  insert into public.tournaments(title,description,start_at,max_players,mode,status,created_by) values(p_title,p_description,p_start_at,p_max_players,p_mode,'open',auth.uid()) returning id into tid;
  return tid;
end; $$;

create or replace function public.claim_first_owner() returns jsonb
language plpgsql security invoker set search_path=public as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if exists(select 1 from public.profiles where role in('owner','admin','moderator')) then raise exception 'Staff already exists'; end if;
  update public.profiles set role='owner',status='approved' where id=auth.uid(); if not found then raise exception 'Profile not found'; end if;
  return jsonb_build_object('owner',true);
end; $$;

grant execute on function public.join_tournament(uuid) to authenticated;
grant execute on function public.generate_bracket(uuid) to authenticated;
grant execute on function public.submit_match_result(uuid,int,int) to authenticated;
grant execute on function public.approve_match_result(uuid,uuid,int,int) to authenticated;
grant execute on function public.admin_set_member_status(uuid,member_status) to authenticated;
grant execute on function public.admin_create_tournament(text,text,timestamptz,int,text) to authenticated;
grant execute on function public.claim_first_owner() to authenticated;

drop policy if exists "staff delete tournament matches" on public.tournament_matches;
create policy "staff delete tournament matches" on public.tournament_matches for delete to authenticated using (is_staff());
drop policy if exists "staff insert notifications" on public.notifications;
create policy "staff insert notifications" on public.notifications for insert to authenticated with check (is_staff());
drop policy if exists "staff update notifications" on public.notifications;
create policy "staff update notifications" on public.notifications for update to authenticated using (is_staff()) with check (is_staff());

do $$ begin
  begin alter publication supabase_realtime add table public.messages; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.notifications; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.profiles; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.tournament_matches; exception when duplicate_object then null; end;
end $$;
