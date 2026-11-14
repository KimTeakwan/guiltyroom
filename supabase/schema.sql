-- 고해실 Supabase 스키마
-- 사용법: Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 Run. 여러 번 실행해도 되게 작성했다.
-- 원칙: 브라우저는 테이블을 직접 읽거나 쓰지 못한다. 모든 읽기/쓰기는 아래 함수(RPC)만 통과하고,
--       검사(자기 글 투표 금지, 도배 제한, 길이, 개인정보, 자해 표현)는 전부 여기서 서버가 강제한다.

create extension if not exists pgcrypto;

-- ───────── 테이블 ─────────
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table if not exists public.posts (
  id      text primary key check (id ~ '^[a-z0-9]{6,24}$'),
  user_id uuid not null references auth.users(id) on delete cascade,
  text    text not null check (char_length(text) between 2 and 200),
  cat     text not null check (cat in ('work','food','money','lazy','love','etc')),
  nick    text not null check (char_length(nick) <= 40),
  by_tag  text check (char_length(by_tag) <= 20),
  level   text check (char_length(level) <= 20),
  weight  numeric check (weight between 0 and 100),
  verdict text check (char_length(verdict) <= 420),
  ts      bigint not null
);
create index if not exists posts_ts_idx on public.posts (ts desc);
create index if not exists posts_user_idx on public.posts (user_id, ts desc);

create table if not exists public.votes (
  post_id text not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  ts      bigint not null,
  primary key (post_id, user_id)
);
create index if not exists votes_user_idx on public.votes (user_id, ts desc);

create table if not exists public.pardons (
  post_id text not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  ts      bigint not null,
  primary key (post_id, user_id)
);
create index if not exists pardons_user_idx on public.pardons (user_id, ts desc);

create table if not exists public.comments (
  id      text primary key check (id ~ '^[a-z0-9]{6,24}$'),
  post_id text not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  text    text not null check (char_length(text) between 1 and 200),
  nick    text not null check (char_length(nick) <= 40),
  by_tag  text check (char_length(by_tag) <= 20),
  ts      bigint not null
);
create index if not exists comments_post_idx on public.comments (post_id, ts);
create index if not exists comments_user_idx on public.comments (user_id, ts desc);

create table if not exists public.reports (
  post_id text not null references public.posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  ts      bigint not null,
  primary key (post_id, user_id)
);

create table if not exists public.feedback (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  items      jsonb not null default '[]'::jsonb,
  updated_ms bigint not null default 0
);

-- ───────── 직접 접근 전면 차단 (RLS 켜고 정책은 만들지 않는다) ─────────
alter table public.admins   enable row level security;
alter table public.posts    enable row level security;
alter table public.votes    enable row level security;
alter table public.pardons  enable row level security;
alter table public.comments enable row level security;
alter table public.reports  enable row level security;
alter table public.feedback enable row level security;

revoke all on public.admins, public.posts, public.votes, public.pardons,
              public.comments, public.reports, public.feedback from anon, authenticated;

-- ───────── 내부 도우미 ─────────
create or replace function public._now_ms() returns bigint
language sql stable as $$ select (extract(epoch from clock_timestamp()) * 1000)::bigint $$;

create or replace function public._uid() returns uuid
language plpgsql stable as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'auth'; end if;
  return u;
end $$;

create or replace function public._check_text(t text) returns void
language plpgsql immutable as $$
begin
  if t ~ '(자살|죽고\s?싶|죽을래|자해|스스로\s?목숨)' then raise exception 'care'; end if;
  if t ~ '(\d{2,3}[-.\s]?\d{3,4}[-.\s]?\d{4})|([A-Za-z0-9._+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.]+)|(\d{6}[-\s]?[1-4]\d{6})' then
    raise exception 'pii';
  end if;
end $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

-- ───────── 읽기: 한 번에 게시판 전체 ─────────
-- 다른 사람의 user_id는 절대 내보내지 않는다. 투표/신고 id는 본인 것만 실제 uid, 남의 것은 해시.
create or replace function public.get_board() returns jsonb
language sql stable security definer set search_path = public as $$
  with p as (select * from public.posts order by ts desc limit 200),
  c as (select cm.* from public.comments cm join p on p.id = cm.post_id order by cm.ts desc limit 2000)
  select jsonb_build_object(
    'posts', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'text', text, 'cat', cat, 'ts', ts, 'nick', nick, 'by', by_tag,
        'level', level, 'weight', weight, 'verdict', verdict) order by ts desc) from p), '[]'::jsonb),
    'votes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', v.post_id || '_' || case when v.user_id = auth.uid() then v.user_id::text
                                      else substr(md5(v.user_id::text || v.post_id), 1, 12) end,
        'post', v.post_id, 'ts', v.ts)) from public.votes v join p on p.id = v.post_id), '[]'::jsonb),
    'pardons', coalesce((select jsonb_agg(jsonb_build_object(
        'id', v.post_id || '_' || case when v.user_id = auth.uid() then v.user_id::text
                                      else substr(md5(v.user_id::text || v.post_id), 1, 12) end,
        'post', v.post_id, 'ts', v.ts)) from public.pardons v join p on p.id = v.post_id), '[]'::jsonb),
    'comments', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'post', post_id, 'text', text, 'nick', nick, 'by', by_tag, 'ts', ts) order by ts) from c), '[]'::jsonb),
    'reports', coalesce((select jsonb_agg(jsonb_build_object(
        'id', r.post_id || '_' || case when r.user_id = auth.uid() then r.user_id::text
                                      else substr(md5(r.user_id::text || r.post_id), 1, 12) end,
        'post', r.post_id, 'ts', r.ts)) from public.reports r join p on p.id = r.post_id), '[]'::jsonb)
  )
$$;

-- 문의: 일반 사용자는 자기 것만, 관리자는 전체
create or replace function public.get_feedback() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', case when f.user_id = auth.uid() then f.user_id::text else substr(md5(f.user_id::text), 1, 12) end,
      'items', f.items)), '[]'::jsonb)
  from public.feedback f
  where f.user_id = auth.uid() or public.is_admin()
$$;

-- ───────── 쓰기 ─────────
create or replace function public.create_post(
  p_id text, p_text text, p_cat text, p_nick text, p_by text,
  p_level text default null, p_weight numeric default null, p_verdict text default null
) returns void language plpgsql security definer set search_path = public as $$
declare u uuid := public._uid(); now_ms bigint := public._now_ms(); t text := btrim(coalesce(p_text, ''));
begin
  if char_length(t) < 2 or char_length(t) > 200 then raise exception 'length'; end if;
  perform public._check_text(t);
  if p_verdict is not null then perform public._check_text(p_verdict); end if;
  if exists (select 1 from public.posts where user_id = u and ts > now_ms - 20000) then raise exception 'cooldown'; end if;
  if (select count(*) from public.posts where user_id = u and ts > now_ms - 86400000) >= 30 then raise exception 'daily'; end if;
  insert into public.posts (id, user_id, text, cat, nick, by_tag, level, weight, verdict, ts)
  values (p_id, u, t, p_cat, left(coalesce(p_nick, '익명'), 40), left(p_by, 20),
          left(p_level, 20), p_weight, left(p_verdict, 420), now_ms);
end $$;

create or replace function public.cast_vote(p_post text, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := public._uid(); now_ms bigint := public._now_ms(); owner uuid;
begin
  if p_kind not in ('trash', 'pardon') then raise exception 'kind'; end if;
  select user_id into owner from public.posts where id = p_post;
  if not found then raise exception 'nopost'; end if;
  if owner = u then raise exception 'self'; end if;
  if (select count(*) from public.votes   where user_id = u and ts > now_ms - 60000)
   + (select count(*) from public.pardons where user_id = u and ts > now_ms - 60000) >= 90 then
    raise exception 'rate';
  end if;
  if p_kind = 'trash' then
    delete from public.pardons where post_id = p_post and user_id = u;
    insert into public.votes (post_id, user_id, ts) values (p_post, u, now_ms) on conflict do nothing;
  else
    delete from public.votes where post_id = p_post and user_id = u;
    insert into public.pardons (post_id, user_id, ts) values (p_post, u, now_ms) on conflict do nothing;
  end if;
end $$;

create or replace function public.remove_vote(p_post text, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := public._uid();
begin
  if p_kind = 'trash' then delete from public.votes where post_id = p_post and user_id = u;
  elsif p_kind = 'pardon' then delete from public.pardons where post_id = p_post and user_id = u;
  else raise exception 'kind'; end if;
end $$;

create or replace function public.add_comment(p_id text, p_post text, p_text text, p_nick text, p_by text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := public._uid(); now_ms bigint := public._now_ms(); t text := btrim(coalesce(p_text, ''));
begin
  if char_length(t) < 1 or char_length(t) > 200 then raise exception 'length'; end if;
  perform public._check_text(t);
  if not exists (select 1 from public.posts where id = p_post) then raise exception 'nopost'; end if;
  if exists (select 1 from public.comments where user_id = u and ts > now_ms - 5000) then raise exception 'cooldown'; end if;
  if (select count(*) from public.comments where user_id = u and ts > now_ms - 86400000) >= 100 then raise exception 'daily'; end if;
  insert into public.comments (id, post_id, user_id, text, nick, by_tag, ts)
  values (p_id, p_post, u, t, left(coalesce(p_nick, '익명'), 40), left(p_by, 20), now_ms);
end $$;

create or replace function public.report_post(p_post text) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := public._uid();
begin
  if not exists (select 1 from public.posts where id = p_post) then raise exception 'nopost'; end if;
  insert into public.reports (post_id, user_id, ts) values (p_post, u, public._now_ms()) on conflict do nothing;
end $$;

create or replace function public.feedback_save(p_items jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare u uuid := public._uid(); now_ms bigint := public._now_ms(); it jsonb; last_ms bigint;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 20 then raise exception 'length'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(it) <> 'object' or char_length(coalesce(it->>'text', '')) not between 1 and 600 then
      raise exception 'length';
    end if;
  end loop;
  select updated_ms into last_ms from public.feedback where user_id = u;
  if last_ms is not null and last_ms > now_ms - 30000 then raise exception 'cooldown'; end if;
  insert into public.feedback (user_id, items, updated_ms) values (u, p_items, now_ms)
  on conflict (user_id) do update set items = excluded.items, updated_ms = excluded.updated_ms;
end $$;

-- 관리자: 글·댓글 삭제
create or replace function public.admin_delete(p_kind text, p_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_kind = 'post' then delete from public.posts where id = p_id;
  elsif p_kind = 'comment' then delete from public.comments where id = p_id;
  else raise exception 'kind'; end if;
end $$;

-- 내 데이터 전부 삭제 (글·댓글·투표·신고·문의). 계정(익명 uid) 자체도 지운다.
create or replace function public.delete_my_data() returns void
language plpgsql security definer set search_path = public, auth as $$
declare u uuid := public._uid();
begin
  delete from auth.users where id = u;  -- 위 테이블들은 on delete cascade 로 같이 지워진다
end $$;

-- ───────── 실행 권한: 로그인(익명 포함)한 사용자만 ─────────
revoke all on function public.get_board(), public.get_feedback(), public.is_admin(),
  public.create_post(text, text, text, text, text, text, numeric, text),
  public.cast_vote(text, text), public.remove_vote(text, text),
  public.add_comment(text, text, text, text, text), public.report_post(text),
  public.feedback_save(jsonb), public.admin_delete(text, text), public.delete_my_data()
  from public, anon;
grant execute on function public.get_board(), public.get_feedback(), public.is_admin(),
  public.create_post(text, text, text, text, text, text, numeric, text),
  public.cast_vote(text, text), public.remove_vote(text, text),
  public.add_comment(text, text, text, text, text), public.report_post(text),
  public.feedback_save(jsonb), public.admin_delete(text, text), public.delete_my_data()
  to authenticated;

-- 내부 도우미는 직접 호출 불가
revoke all on function public._now_ms(), public._uid(), public._check_text(text) from public, anon, authenticated;

-- ───────── 관리자 등록 (배포 후 한 번만) ─────────
-- 1) Authentication > Users 에서 이메일+비밀번호로 사용자를 하나 만든다.
-- 2) 아래 이메일을 바꿔서 실행:
-- insert into public.admins (user_id) select id from auth.users where email = '내이메일@example.com';
