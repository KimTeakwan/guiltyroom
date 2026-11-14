/* 배포 전에 아래 두 값을 본인 Supabase 프로젝트 것으로 바꾼다.
 * Supabase 대시보드 > Project Settings > API 에서 "Project URL" 과 "anon public" 키.
 * anon 키는 공개되어도 되는 키다(테이블은 RLS로 잠겨 있다). 절대 service_role 키를 넣지 마라. */
window.GR_CONFIG = {
  SUPABASE_URL: 'https://YOUR_PROJECT_ID.supabase.co',
  SUPABASE_ANON_KEY: 'YOUR_SUPABASE_ANON_KEY',
  SITE_URL: ''   // 정식 주소(예: https://gohae.pages.dev). 비워두면 현재 주소를 쓴다.
};
