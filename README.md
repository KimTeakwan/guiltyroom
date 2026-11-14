# 고해실

말 못 한 개짓을 익명으로 불고(고해실), 누가 더 쓰레기인지 겨루는(랭킹) 장난 사이트.
정적 파일 + Supabase(DB·익명 로그인) 구조. 서버 코드는 없고, 규칙은 전부 `supabase/schema.sql` 안의 DB 함수가 강제한다.

```
index.html          화면 전체 (고해실, 랭킹, 문의, 홈 화면 추가 안내)
backend.js          화면 ↔ Supabase 연결 (익명 로그인, 목록 가져오기, 쓰기 호출)
config.js           ← 배포 전에 본인 Supabase 주소/키로 바꿀 파일
manifest.webmanifest, sw.js, icon-*.png, apple-touch-icon.png   홈 화면 설치(PWA)
privacy.html        개인정보 처리방침 (운영자 이메일 칸 채울 것)
_headers            Cloudflare Pages 보안 헤더
supabase/schema.sql 테이블·잠금(RLS)·서버 규칙 함수
supabase/tests/     로컬 Postgres로 규칙을 검증한 SQL
```

## 배포 순서 (한 번만)

### 1. Supabase 프로젝트
1. supabase.com 에서 새 프로젝트를 만든다. 리전은 Northeast Asia (Seoul).
2. **SQL Editor → New query** 에 `supabase/schema.sql` 전체를 붙여넣고 Run. (여러 번 실행해도 된다.)
3. **Authentication → Sign In / Providers** 에서 **Anonymous sign-ins** 를 켠다. (이게 꺼져 있으면 사이트가 서버에 연결하지 못한다.)
4. **Project Settings → API** 에서 `Project URL` 과 `anon public` 키를 복사한다. `service_role` 키는 절대 쓰지 않는다.

### 2. 관리자 계정 (글·댓글 삭제, 문의함 보기)
1. **Authentication → Users → Add user** 로 이메일과 비밀번호를 만든다. (Auto Confirm User 체크)
2. SQL Editor 에서 실행: 
   `insert into public.admins (user_id) select id from auth.users where email = '내이메일';`
3. 배포 후 사이트 맨 아래 **관리자** 를 눌러 로그인한다.

### 3. 키 넣기
`config.js` 의 `SUPABASE_URL`, `SUPABASE_ANON_KEY` 를 바꾸고 커밋한다. anon 키는 공개돼도 된다(테이블이 잠겨 있고 함수만 열려 있다).

### 4. Cloudflare Pages
1. Cloudflare → Workers & Pages → Create → Pages → **Connect to Git** → 이 저장소 선택.
2. Framework preset: None, Build command: 비움, Build output directory: `/` (루트).
3. 배포되면 `https://○○.pages.dev` 주소가 나온다. 원하면 Custom domains 에서 도메인을 붙인다.
4. `config.js` 의 `SITE_URL` 에 그 주소를 넣으면 공유/복사 링크가 그 주소가 된다. 비워도 현재 주소를 쓴다.

### 5. 열기 전 점검
- [ ] `privacy.html` 맨 아래 `[운영자 이메일을 여기에 적으세요]` 를 실제 연락처로 바꿨다.
- [ ] 두 개의 브라우저(또는 시크릿 창)로 접속해 글 올리기, 다른 계정으로 투표하기, 내 글 투표 막힘을 확인했다.
- [ ] 관리자로 로그인해서 글 삭제가 되는지 확인했다.

## 알고 있어야 할 것
- **새로고침 주기**: 7초마다 서버에서 가져온다(실시간 푸시는 아님). 내가 쓴 건 바로 반영된다.
- **익명성**: 다른 사용자에게는 별명과 투표 수만 보인다. 운영자는 관리 화면에서 글과 익명 계정 번호를 연결해서 볼 수 있다. "완전 익명"이라고 홍보하지 말 것.
- **계정 = 브라우저**: 브라우저 데이터를 지우면 새 익명 계정이 된다. 그러면 예전 글은 "내 글"이 아니고 투표도 다시 할 수 있다. 계정 여러 개로 도배하는 건 IP당 익명 가입 제한(Supabase Authentication → Rate Limits)과 계정별 제한으로 일부 막는다. 심해지면 캡차(Turnstile)를 붙여야 하고 그건 코드 수정이 필요하다.
- **빠진 것**: Claude 맞춤 판결과 독설 목소리는 서버 쪽 키 보관이 필요해서 이번에 뺐다. 나중에 Supabase Edge Function으로 붙인다.
- **외부 스크립트**: `supabase-js` 를 jsDelivr 에서 가져온다(`@2`). 안정성을 높이려면 파일을 저장소에 넣고 `index.html` 의 `<script>` 주소를 바꾼다.

## 서버 규칙 (schema.sql)
브라우저는 테이블을 직접 읽고 쓸 수 없다(RLS 켜고 정책 없음). 함수만 호출할 수 있고, 거기서 이렇게 강제한다.
- 글 2~200자, 댓글 1~200자, 분류는 6개 중 하나
- 전화번호·이메일·주민번호 형태와 자해 관련 표현 차단
- 글 20초에 1개·하루 30개, 댓글 5초에 1개·하루 100개, 투표 분당 90개, 문의 30초에 1번
- 자기 글에는 투표 불가, 신고는 글당 계정당 1번
- 응답에서 남의 계정 번호는 가려서 내보낸다
- `delete_my_data()` 로 내 계정과 그에 딸린 모든 데이터 삭제

규칙 검증: `supabase/tests/` 의 SQL을 로컬 Postgres에서 돌렸다(가짜 `auth` 스키마 포함). 실제 Supabase 프로젝트에서는 아직 돌려보지 않았다.
