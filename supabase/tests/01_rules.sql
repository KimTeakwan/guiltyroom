\set ON_ERROR_STOP off
insert into auth.users(id,email) values ('11111111-1111-1111-1111-111111111111','a@x'),('22222222-2222-2222-2222-222222222222','b@x'),('33333333-3333-3333-3333-333333333333','admin@x');
insert into public.admins values ('33333333-3333-3333-3333-333333333333');

-- A: 글 작성
set role authenticated; set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';
\echo '--- A 글쓰기 (성공 기대)'
select public.create_post('aaaa1111bb','회식에서 치킨을 혼자 다 먹었다','food','졸린 수달 #12','123','꽤 나쁜 짓',55,'판결문');
\echo '--- A 20초 내 재작성 (cooldown 기대)'
select public.create_post('aaaa2222bb','또 올린다 두번째','food','n','1');
\echo '--- 자해 표현 (care) / 전화번호 (pii) / 짧은글 (length) -- 쿨다운이 먼저 걸리므로 B로 확인'
reset role; set role authenticated; set request.jwt.claim.sub='22222222-2222-2222-2222-222222222222';
select public.create_post('bbbb0001bb','죽고 싶다 진짜','etc','n','2');
select public.create_post('bbbb0002bb','내 번호는 010-1234-5678 이다','etc','n','2');
select public.create_post('bbbb0003bb','a','etc','n','2');
select public.create_post('BAD ID!','정상 글인데 아이디 이상','etc','n','2');
select public.create_post('bbbb0004bb','남의 글: 몰래 디저트 두 개 먹음','food','졸린 곰 #31','2');

\echo '--- B가 A 글에 쓰레기 투표 (성공)'
select public.cast_vote('aaaa1111bb','trash');
\echo '--- B가 같은 글 봐준다로 변경 (trash->pardon)'
select public.cast_vote('aaaa1111bb','pardon');
\echo '--- B 본인 글에 투표 (self 기대)'
select public.cast_vote('bbbb0004bb','trash');
\echo '--- 없는 글 (nopost)'
select public.cast_vote('nope','trash');
\echo '--- 댓글 / 5초 내 두번째 댓글 (cooldown)'
select public.add_comment('cmt00001a','aaaa1111bb','치킨은 죄가 아니다','졸린 곰 #31','2');
select public.add_comment('cmt00002a','aaaa1111bb','연속 댓글','n','2');
select public.report_post('aaaa1111bb');

\echo '--- 직접 테이블 접근 (권한 없음 기대)'
select count(*) from public.posts;
insert into public.posts(id,user_id,text,cat,nick,ts) values ('hack00001a','22222222-2222-2222-2222-222222222222','직접 삽입','etc','n',1);
select count(*) from public.votes;
select public._now_ms();

\echo '--- 문의 저장 / 30초 내 재저장'
select public.feedback_save('[{"id":"f1","kind":"bug","text":"버그 있음","ts":1}]');
select public.feedback_save('[{"id":"f1","kind":"bug","text":"버그 있음","ts":1}]');

\echo '--- A 시점 get_board: 남의 uid가 새지 않는지'
reset role; set role authenticated; set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';
select jsonb_pretty(public.get_board());
\echo '--- A get_feedback (비어 있어야 함)'
select public.get_feedback();
\echo '--- 일반 사용자 admin_delete (forbidden)'
select public.admin_delete('post','bbbb0004bb');

\echo '--- 관리자'
reset role; set role authenticated; set request.jwt.claim.sub='33333333-3333-3333-3333-333333333333';
select public.is_admin();
select public.get_feedback();
select public.admin_delete('post','bbbb0004bb');
select id from public.posts order by id;  -- 직접 접근 불가 기대
\echo '--- anon 역할 호출 (거부 기대)'
reset role; set role anon; set request.jwt.claim.sub='';
select public.get_board();
\echo '--- 로그인 없는 authenticated (auth 기대)'
reset role; set role authenticated; set request.jwt.claim.sub='';
select public.create_post('zzzz0001bb','익명 글','etc','n','1');

\echo '--- delete_my_data (A)'
reset role; set role authenticated; set request.jwt.claim.sub='11111111-1111-1111-1111-111111111111';
select public.delete_my_data();
reset role;
select (select count(*) from public.posts) as posts, (select count(*) from public.votes) as votes, (select count(*) from public.comments) as comments, (select count(*) from auth.users) as users;
