/* 고해실 백엔드 연결 (Supabase)
 * 화면 코드는 예전에 쓰던 db/user 인터페이스(doc().set(), collection().onSnapshot() 등)를 그대로 쓴다.
 * 이 파일이 그 호출을 Supabase RPC 호출로 바꿔 준다. 실제 검사(자기 글 투표 금지, 도배 제한 등)는 서버(schema.sql)가 한다.
 * window.GR.use('db' | 'user' | 'downloads') 를 제공하고, sample/tts 는 이 사이트에서 쓰지 않는다(null). */
(function () {
  'use strict';
  var cfg = window.GR_CONFIG || {};
  var POLL_MS = 7000;
  var sb = null, session = null, admin = false, initP = null;
  var cache = {}, lastJson = {}, listeners = {}, timer = null, busy = false, firstDone = false;

  var MSG = {
    cooldown: '너무 빨리 한다. 잠깐 쉬어라', daily: '오늘은 여기까지다. 내일 또 와라', rate: '투표가 너무 빠르다. 숨 좀 쉬어라',
    self: '자기 글에는 못 누른다. 남이 판단해 줘야지', care: '그런 말은 올릴 수 없다. 힘들면 109에 연락해라',
    pii: '전화번호·이메일 같은 개인정보는 못 올린다', length: '글자 수가 맞지 않는다', nopost: '이미 사라진 글이다',
    forbidden: '권한이 없다', auth: '로그인 상태를 확인하지 못했다'
  };
  function say(m) { setTimeout(function () { try { if (window.__app && window.__app.toast) window.__app.toast(m); } catch (e) {} }, 60); }
  function fail(error) {
    var code = String((error && (error.message || error.code)) || 'error').trim();
    if (MSG[code]) say(MSG[code]);
    var e = new Error(code); e.code = code; return e;
  }

  function configured() {
    return !!(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY && !/YOUR_|example/i.test(cfg.SUPABASE_URL + cfg.SUPABASE_ANON_KEY) &&
              window.supabase && window.supabase.createClient);
  }

  function init() {
    if (initP) return initP;
    initP = (async function () {
      if (!configured()) { var e0 = new Error('not_configured'); e0.code = 'not_configured'; throw e0; }
      sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
        auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
      });
      var r = await sb.auth.getSession();
      session = r && r.data && r.data.session;
      if (!session) {
        var a = await sb.auth.signInAnonymously();
        if (a.error || !a.data || !a.data.session) { var e1 = new Error('auth'); e1.code = 'auth'; throw e1; }
        session = a.data.session;
      }
      sb.auth.onAuthStateChange(function (_ev, s) { if (s) session = s; });
      try { var ia = await sb.rpc('is_admin'); admin = ia.data === true; } catch (e) { admin = false; }
      return true;
    })();
    initP.catch(function () { initP = null; });
    return initP;
  }

  async function rpc(name, args) {
    await init();
    var r = await sb.rpc(name, args || {});
    if (r.error) throw fail(r.error);
    return r.data;
  }

  /* ---------- 읽기: 주기적으로 가져와서 구독자에게 나눠준다 ---------- */
  var BOARD = ['posts', 'votes', 'pardons', 'comments', 'reports'];
  function snapOf(rows, isFb) {
    return { docs: rows.map(function (r) { return { id: String(r.id), data: function () { return r; } }; }) };
  }
  function emit(name, rows, force) {
    var j = JSON.stringify(rows);
    if (!force && lastJson[name] === j) return;
    lastJson[name] = j; cache[name] = rows;
    (listeners[name] || []).slice().forEach(function (l) { try { l.cb(snapOf(rows)); } catch (e) {} });
  }
  function wanted(group) {
    return (group === 'board' ? BOARD : ['feedback']).some(function (n) { return (listeners[n] || []).length; });
  }
  function errAll(group) {
    (group === 'board' ? BOARD : ['feedback']).forEach(function (n) {
      (listeners[n] || []).forEach(function (l) { if (l.err && !l.errored) { l.errored = true; try { l.err(); } catch (e) {} } });
    });
  }
  async function pull() {
    if (busy) return; busy = true;
    try {
      await init();
      if (wanted('board')) {
        var r = await sb.rpc('get_board');
        if (r.error) errAll('board');
        else { var b = r.data || {}; BOARD.forEach(function (n) { emit(n, Array.isArray(b[n]) ? b[n] : [], !firstDone && !(n in lastJson)); }); }
      }
      if (wanted('feedback')) {
        var f = await sb.rpc('get_feedback');
        if (f.error) errAll('feedback'); else emit('feedback', Array.isArray(f.data) ? f.data : [], !('feedback' in lastJson));
      }
      firstDone = true;
    } catch (e) { errAll('board'); errAll('feedback'); }
    finally { busy = false; }
  }
  function startTimer() {
    if (timer) return;
    timer = setInterval(function () { if (document.visibilityState === 'visible') pull(); }, POLL_MS);
    document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible') pull(); });
  }
  var pullSoon = (function () { var t = null; return function () { clearTimeout(t); t = setTimeout(pull, 250); }; })();

  function Query(name) { this.name = name; }
  Query.prototype.orderBy = function () { return this; };
  Query.prototype.limit = function () { return this; };
  Query.prototype.onSnapshot = function (cb, err) {
    var name = this.name, l = { cb: cb, err: err, errored: false };
    (listeners[name] = listeners[name] || []).push(l);
    if (name in cache) { try { cb(snapOf(cache[name])); } catch (e) {} }
    startTimer(); pull();
    return function () { listeners[name] = (listeners[name] || []).filter(function (x) { return x !== l; }); };
  };

  /* ---------- 쓰기 ---------- */
  function Doc(path) { var p = String(path).split('/'); this.col = p[0]; this.id = p.slice(1).join('/'); }
  Doc.prototype.set = function (d) {
    var col = this.col, id = this.id; d = d || {};
    var job;
    if (col === 'posts') job = rpc('create_post', { p_id: id, p_text: d.text, p_cat: d.cat, p_nick: d.nick, p_by: d.by == null ? '' : String(d.by),
      p_level: d.level || null, p_weight: d.weight == null ? null : Number(d.weight), p_verdict: d.verdict || null });
    else if (col === 'votes') job = rpc('cast_vote', { p_post: d.post, p_kind: 'trash' });
    else if (col === 'pardons') job = rpc('cast_vote', { p_post: d.post, p_kind: 'pardon' });
    else if (col === 'comments') job = rpc('add_comment', { p_id: id, p_post: d.post, p_text: d.text, p_nick: d.nick, p_by: d.by == null ? '' : String(d.by) });
    else if (col === 'reports') job = rpc('report_post', { p_post: d.post });
    else if (col === 'feedback') job = rpc('feedback_save', { p_items: d.items || [] });
    else job = Promise.reject(new Error('unknown'));
    return job.then(function (x) { pullSoon(); return x; });
  };
  Doc.prototype['delete'] = function () {
    var col = this.col, id = this.id, job;
    if (col === 'votes') job = rpc('remove_vote', { p_post: id.split('_')[0], p_kind: 'trash' });
    else if (col === 'pardons') job = rpc('remove_vote', { p_post: id.split('_')[0], p_kind: 'pardon' });
    else if (col === 'posts') job = rpc('admin_delete', { p_kind: 'post', p_id: id });
    else if (col === 'comments') job = rpc('admin_delete', { p_kind: 'comment', p_id: id });
    else job = Promise.reject(new Error('unknown'));
    return job.then(function (x) { pullSoon(); return x; });
  };
  var dbApi = { collection: function (n) { return new Query(n); }, doc: function (p) { return new Doc(p); } };

  var userApi = {
    id: async function () { await init(); return session.user.id; },
    isOwner: function () { return admin; },
    can: function () { return true; }
  };

  var dlApi = {
    save: function (o) {
      return new Promise(function (resolve, reject) {
        try {
          var blob = o.data instanceof Blob ? o.data : new Blob([o.data]);
          var url = URL.createObjectURL(blob), a = document.createElement('a');
          a.href = url; a.download = o.filename || 'download'; a.rel = 'noopener';
          document.body.appendChild(a); a.click(); document.body.removeChild(a);
          setTimeout(function () { URL.revokeObjectURL(url); }, 4000); resolve();
        } catch (e) { reject(e); }
      });
    }
  };

  window.GR = {
    use: async function (name) {
      if (name === 'db') { await init(); return dbApi; }
      if (name === 'user') { await init(); return userApi; }
      if (name === 'downloads') return dlApi;
      var e = new Error('unavailable'); e.code = 'unavailable'; throw e;   // sample, tts: 이 사이트에서는 쓰지 않는다
    },
    isConfigured: configured,
    adminLogin: async function (email, password) {
      await init();
      var r = await sb.auth.signInWithPassword({ email: email, password: password });
      if (r.error) throw r.error;
      return true;
    },
    adminLogout: async function () { await init(); await sb.auth.signOut(); },
    isAdmin: function () { return admin; },
    deleteMyData: async function () {
      await rpc('delete_my_data');
      try { await sb.auth.signOut(); } catch (e) {}
      try { localStorage.clear(); } catch (e) {}
    }
  };
})();
