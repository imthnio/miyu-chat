// 密语前端：所有加密、解密、签名都在浏览器里完成，服务器只见到密文。
// 名词：
//   私钥（seed）：32 字节随机数，用 64 位十六进制表示，是你唯一的登录凭证。
//   ID：由私钥算出的 Ed25519 签名公钥，发给朋友用来加好友。
//   加密公钥：由私钥派生的 X25519 公钥，用于和好友协商加密密钥；它被你的签名公钥签过名，服务器无法偷换。
//   本地密码：勾选“记住密钥”时设置。浏览器用它把私钥加密后再存起来（PBKDF2 把密码慢慢算成钥匙，
//            再用 AES-GCM 加密），别人拿到浏览器存储也只看到密文。密码不会发给服务器。
//   安全上下文：浏览器只在 https:// 网页（或本机 localhost）里提供加密功能，所以“记住密钥”需要 HTTPS。
(() => {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const enc = new TextEncoder(), dec = new TextDecoder();
  const toHex = (u8) => Array.from(u8, (b) => b.toString(16).padStart(2, "0")).join("");
  const fromHex = (s) => {
    if (!/^[0-9a-fA-F]*$/.test(s) || s.length % 2) throw new Error("bad hex");
    const u = new Uint8Array(s.length / 2);
    for (let i = 0; i < u.length; i++) u[i] = parseInt(s.substr(i * 2, 2), 16);
    return u;
  };
  const toB64 = (u8) => { let s = ""; u8.forEach((b) => (s += String.fromCharCode(b))); return btoa(s); };
  const fromB64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const KEY_STORE = "miyu.key";        // 旧版：明文保存的私钥（已不安全，读到就删除）
  const KEY_STORE_V2 = "miyu.key.v2";  // 新版：用本地密码加密后的私钥 {v:2,salt,iv,ct,iter}
  const PBKDF2_ITER = 600000;          // 密码算钥匙的轮数：越大越难被暴力猜，解锁时大约要等半秒
  const canRemember = !!(window.isSecureContext && window.crypto && crypto.subtle);
  let pendingSave = null;              // 登录成功后要用来加密保存私钥的本地密码（存完立刻清掉）

  // ---------- 状态 ----------
  let keys = null;        // {seed, sign, box, id}
  let ws = null, wsOk = false, retry = 0;
  let stopped = false;    // 遇到“重连也没用”的错误（比如密钥校验失败）时设为 true，不再自动重连
  let sessionNonce = null, seq = 0; // 这次连接的随机数和指令序号，用来给每条指令签名
  let me = null;
  const friends = new Map();   // id -> {id,name,box,boxsig,online,verified,shared,unread}
  const requests = new Map();  // id -> user
  const chats = new Map();     // id -> {msgs: Map(id->msg), loaded, more, oldest}
  // 只接受“我自己同意过”的新好友：服务器推来的 friend_added 必须是我申请过的或我点了通过的 ID，
  // 防止服务器（或中间人）偷偷塞一个陌生人进好友列表。
  const pendingOut = new Set(); // 我发出过申请的 ID（自己输入的 + 登录时服务器列出的“已发出的申请”）
  const accepted = new Set();   // 我点了“通过”的 ID
  let active = null;

  // ---------- 小工具 ----------
  function toast(text) {
    const t = $("toast"); t.textContent = text; t.classList.remove("hidden");
    clearTimeout(toast.timer); toast.timer = setTimeout(() => t.classList.add("hidden"), 2600);
  }
  async function copy(text) {
    try { await navigator.clipboard.writeText(text); toast("已复制"); }
    catch { toast("复制失败，请手动选中复制"); }
  }
  function shortId(id) { return id.slice(0, 8) + "…" + id.slice(-6); }
  function displayName(u) { return (u && u.name) || shortId(u.id); }
  function colorOf(id) { return "hsl(" + (parseInt(id.slice(0, 4), 16) % 360) + ",45%,42%)"; }
  function fmtTime(ts) {
    const d = new Date(ts), n = new Date();
    const hm = d.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
    return d.toDateString() === n.toDateString() ? hm : (d.getMonth() + 1) + "/" + d.getDate() + " " + hm;
  }

  // ---------- 密钥 ----------
  // 由私钥派生签名密钥对和加密密钥对。加密私钥 = SHA-512("miyu-box" + seed) 的前 32 字节。
  function deriveKeys(seed) {
    const sign = nacl.sign.keyPair.fromSeed(seed);
    const tag = enc.encode("miyu-box");
    const buf = new Uint8Array(tag.length + seed.length); buf.set(tag); buf.set(seed, tag.length);
    const box = nacl.box.keyPair.fromSecretKey(nacl.hash(buf).slice(0, 32));
    return { seed, sign, box, id: toHex(sign.publicKey) };
  }
  function parseSeed(text) {
    const s = text.trim().replace(/\s+/g, "").toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(s)) return null;
    return fromHex(s);
  }
  // 验证好友的加密公钥确实由他的 ID 签过名，防止服务器调包
  function prepFriend(u) {
    const f = Object.assign(friends.get(u.id) || { unread: 0 }, u);
    try {
      f.verified = nacl.sign.detached.verify(enc.encode("miyu-box:" + u.box), fromHex(u.boxsig), fromHex(u.id));
    } catch { f.verified = false; }
    f.shared = f.verified ? nacl.box.before(fromHex(u.box), keys.box.secretKey) : null;
    friends.set(u.id, f);
    return f;
  }

  // ---------- 本地加密保存私钥 ----------
  // 本地密码 → PBKDF2-SHA256（随机盐）→ AES-GCM 256 位钥匙
  async function pwKey(pwd, salt, iter) {
    const base = await crypto.subtle.importKey("raw", enc.encode(pwd), "PBKDF2", false, ["deriveKey"]);
    return crypto.subtle.deriveKey({ name: "PBKDF2", hash: "SHA-256", salt, iterations: iter },
      base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  }
  // 加密私钥后存进浏览器：每次都用新的随机盐（16 字节）和随机 iv（12 字节）
  async function saveSeed(seed, pwd) {
    const salt = crypto.getRandomValues(new Uint8Array(16));
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const key = await pwKey(pwd, salt, PBKDF2_ITER);
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, seed));
    localStorage.setItem(KEY_STORE_V2, JSON.stringify({ v: 2, salt: toB64(salt), iv: toB64(iv), ct: toB64(ct), iter: PBKDF2_ITER }));
  }
  // 用密码解开保存的私钥。密码不对时浏览器会抛出 OperationError
  async function loadSeed(pwd) {
    let o;
    try { o = JSON.parse(localStorage.getItem(KEY_STORE_V2)); } catch { o = null; }
    if (!o || o.v !== 2 || !Number.isSafeInteger(o.iter) || o.iter < 100000 || o.iter > 10000000) throw new Error("bad store");
    const key = await pwKey(pwd, fromB64(o.salt), o.iter);
    const pt = new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromB64(o.iv) }, key, fromB64(o.ct)));
    if (pt.length !== 32) throw new Error("bad store");
    return pt;
  }
  function forgetKey() { localStorage.removeItem(KEY_STORE_V2); localStorage.removeItem(KEY_STORE); }

  // ---------- 登录页 ----------
  // 勾选“记住密钥”才显示本地密码输入框
  $("remember").onchange = () => $("rememberPwd").classList.toggle("hidden", !$("remember").checked);
  $("rememberPwd").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); $("loginBtn").click(); } });
  $("genBtn").onclick = () => {
    const seed = nacl.randomBytes(32);
    const hex = toHex(seed);
    $("newKey").textContent = hex;
    $("newKeyBox").classList.remove("hidden");
    $("keyInput").value = hex;
  };
  $("copyNewKey").onclick = () => copy($("newKey").textContent);
  $("loginBtn").onclick = () => {
    const seed = parseSeed($("keyInput").value);
    if (!seed) { $("loginErr").textContent = "密钥格式不对：应该是 64 位的 0-9 和 a-f 组合。"; return; }
    pendingSave = null;
    if ($("remember").checked && canRemember) {
      const pwd = $("rememberPwd").value;
      if (pwd.length < 6) { $("loginErr").textContent = "要记住密钥，请先设置至少 6 位的本地密码（只用来在这个浏览器上解锁，不会发给服务器）。"; $("rememberPwd").focus(); return; }
      pendingSave = pwd; // 等登录成功后再加密保存，免得存下一把登录不了的密钥
    } else {
      forgetKey();
    }
    $("rememberPwd").value = "";
    start(seed);
  };

  // ---------- 解锁页 ----------
  $("unlockBtn").onclick = async () => {
    const pwd = $("unlockPwd").value;
    if (!pwd) { $("unlockErr").textContent = "请输入本地密码。"; return; }
    if (!canRemember) { $("unlockErr").textContent = "现在不是 https:// 网页，浏览器不允许解密。请用 https:// 地址打开，或者点“换一个密钥登录”。"; return; }
    $("unlockBtn").disabled = true; $("unlockErr").textContent = "正在解锁…";
    let seed;
    try {
      seed = await loadSeed(pwd);
    } catch (e) {
      $("unlockErr").textContent = e && e.name === "OperationError"
        ? "密码不对，请再试一次。忘了密码就点“换一个密钥登录”，用你抄下来的私钥重新登录。"
        : "保存的密钥数据损坏了，请点“换一个密钥登录”重新输入私钥。";
      return;
    } finally { $("unlockBtn").disabled = false; }
    $("unlockPwd").value = ""; $("unlockErr").textContent = "";
    $("remember").checked = true;
    start(seed);
  };
  $("unlockPwd").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); $("unlockBtn").click(); } });
  $("forgetBtn").onclick = () => {
    if (!confirm("将删除这个浏览器里保存的密钥，之后需要重新输入私钥登录。确定？")) return;
    forgetKey();
    $("unlock").classList.add("hidden"); $("login").classList.remove("hidden");
  };
  $("keyInput").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); $("loginBtn").click(); } });

  function start(seed) {
    keys = deriveKeys(seed);
    stopped = false; retry = 0;
    $("loginErr").textContent = "";
    $("login").classList.add("hidden"); $("unlock").classList.add("hidden");
    $("app").classList.remove("hidden");
    $("myId").textContent = keys.id;
    connect();
  }
  $("logoutBtn").onclick = () => {
    if (!confirm("退出后需要重新输入私钥才能登录。确定退出？")) return;
    forgetKey(); pendingSave = null;
    location.reload();
  };

  // ---------- 连接 ----------
  function setConn(ok, text) {
    wsOk = ok;
    $("connState").className = "dot " + (ok ? "on" : "off");
    $("connText").textContent = text;
  }
  // 登录后的每条指令都签名：body 是指令（带递增的序号 seq）的 JSON 文本，
  // 签名内容 = "miyu-cmd:v2:" + 这次连接的随机数 + ":" + body。
  // 这样中间人既改不了指令内容，也没法把旧指令再发一遍。
  function send(obj) {
    if (!ws || ws.readyState !== 1 || !sessionNonce) { toast("还没连上服务器，请稍等"); return; }
    const body = JSON.stringify(Object.assign({}, obj, { seq: ++seq }));
    const sig = nacl.sign.detached(enc.encode("miyu-cmd:v2:" + sessionNonce + ":" + body), keys.sign.secretKey);
    ws.send(JSON.stringify({ t: "cmd", body, sig: toHex(sig) }));
  }

  function connect() {
    setConn(false, "连接中…");
    const proto = location.protocol === "https:" ? "wss://" : "ws://";
    sessionNonce = null; seq = 0;
    ws = new WebSocket(proto + location.host + "/ws");
    ws.onmessage = (ev) => { let m; try { m = JSON.parse(ev.data); } catch { return; } handle(m); };
    ws.onclose = () => {
      if (stopped) return;
      setConn(false, "已断开，正在重连…");
      const wait = Math.min(15000, 1000 * 2 ** retry++);
      setTimeout(connect, wait);
    };
  }

  function handle(m) {
    switch (m.t) {
      case "challenge": {
        // 随机数必须是 64 位十六进制，奇怪的格式直接不理
        if (typeof m.nonce !== "string" || !/^[0-9a-f]{64}$/.test(m.nonce)) break;
        sessionNonce = m.nonce; seq = 0;

        // 用私钥对服务器给的随机数签名，证明我拥有这个 ID。
        // 签名里带上地址栏里的网址（location.host），这样别的网站就算转发了这串随机数，
        // 签出来的也是那个网站的网址，拿到真正的服务器上验证不通过，没法冒充我登录。
        const sig = nacl.sign.detached(enc.encode("miyu-login:v2:" + location.host + ":" + m.nonce), keys.sign.secretKey);

        const boxHex = toHex(keys.box.publicKey);
        const boxsig = nacl.sign.detached(enc.encode("miyu-box:" + boxHex), keys.sign.secretKey);
        ws.send(JSON.stringify({ t: "auth", pub: keys.id, box: boxHex, boxsig: toHex(boxsig), sig: toHex(sig) }));
        break;
      }
      case "ready":
        retry = 0; setConn(true, "已连接 · 端到端加密");
        // 第一次登录成功并勾了“记住密钥”：现在才加密保存
        if (pendingSave) {
          const pwd = pendingSave; pendingSave = null;
          saveSeed(keys.seed, pwd).then(() => toast("密钥已用本地密码加密保存，下次输入密码即可登录"),
            () => toast("保存密钥失败，下次需要重新输入私钥"));
        }
        me = m.me; $("myName").value = me.name || "";
        friends.clear(); requests.clear();
        m.friends.forEach(prepFriend);
        m.requests.forEach((u) => requests.set(u.id, u));
        (m.sent || []).forEach((id) => { if (typeof id === "string") pendingOut.add(id.toLowerCase()); });
        // 重连后清掉缓存重新拉，保证离线期间被双删的消息不会残留
        chats.clear();
        renderSide();
        if (active && friends.has(active)) openChat(active); else if (active) closeChat();
        break;
      case "me": me = m.me; toast("昵称已保存"); break;
      case "error":
        // 登录类错误重连也没用：回到登录页把原因写清楚，等用户处理后再点登录
        if (FATAL_CODES.has(m.code)) { backToLogin(m.msg, m.code); break; }
        toast(m.msg); break;
      case "req_sent": toast("好友申请已发送，等对方通过"); $("addInput").value = ""; break;
      case "request": requests.set(m.user.id, m.user); renderSide(); toast("收到新的好友申请"); break;
      case "request_gone": requests.delete(m.id); renderSide(); break;
      case "friend_added": {
        // 核对：这个 ID 必须是我申请过或我通过的，否则不认（登录时的好友列表另算，以服务器为准）
        const id = m.user && typeof m.user.id === "string" ? m.user.id : "";
        if (!/^[0-9a-f]{64}$/.test(id) || (!pendingOut.has(id) && !accepted.has(id))) {
          console.warn("已忽略一个不是你申请或通过的好友：", id);
          break;
        }
        pendingOut.delete(id); accepted.delete(id);
        requests.delete(id); prepFriend(m.user); renderSide();
        toast("已添加好友 " + displayName(m.user)); $("addInput").value = "";
        break;
      }
      case "friend_update": if (friends.has(m.user.id)) { prepFriend(m.user); renderSide(); if (active === m.user.id) renderHead(); } break;
      case "presence": { const f = friends.get(m.id); if (f) { f.online = m.online; renderSide(); } break; }
      case "unfriended":
        friends.delete(m.id); chats.delete(m.id);
        if (active === m.id) closeChat();
        renderSide(); break;
      case "history": onHistory(m); break;
      case "msg": onMsg(m.msg); break;
      case "deleted": {
        // id 一定当数字处理，避免拼进选择器时出错
        const id = Number(m.id); if (!Number.isSafeInteger(id)) break;
        for (const c of chats.values()) c.msgs.delete(id);
        const el = document.querySelector('[data-mid="' + id + '"]'); if (el) el.remove();
        break;
      }
      case "cleared": {
        const c = chats.get(m.with); if (c) { c.msgs.clear(); c.more = false; }
        if (active === m.with) renderMsgs();
        toast(m.by === keys.id ? "已双删全部聊天记录" : "对方已双删全部聊天记录");
        break;
      }
    }
  }

  // 这些错误码表示“登录不了”，自动重连只会一直失败，所以停下来回到登录页
  const FATAL_CODES = new Set(["bad_auth"]);
  function backToLogin(msg, code) {
    stopped = true; pendingSave = null;
    if (ws) ws.close();
    setConn(false, "未登录");
    $("app").classList.add("hidden");
    $("login").classList.remove("hidden");
    $("loginErr").textContent = msg || "登录失败，请重试";
  }

  // ---------- 侧边栏 ----------

  $("saveName").onclick = () => send({ t: "setname", name: $("myName").value });
  $("copyId").onclick = () => copy(keys.id);
  $("addBtn").onclick = () => {
    const id = $("addInput").value.trim().toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(id)) { toast("好友 ID 应该是 64 位十六进制"); return; }
    pendingOut.add(id); // 记下来：之后只认这个 ID 成为好友
    send({ t: "friend_req", to: id });
  };
  $("addInput").addEventListener("keydown", (e) => { if (e.key === "Enter") $("addBtn").click(); });

  function avatar(u) {
    const a = document.createElement("div"); a.className = "avatar"; a.style.background = colorOf(u.id);
    a.textContent = displayName(u).slice(0, 1).toUpperCase();
    return a;
  }

  function renderSide() {
    const rq = $("requests"); rq.textContent = "";
    for (const u of requests.values()) {
      const d = document.createElement("div"); d.className = "req";
      const t = document.createElement("div"); t.textContent = "好友申请：" + displayName(u);
      const idl = document.createElement("code"); idl.className = "muted small"; idl.textContent = u.id;
      const row = document.createElement("div"); row.className = "row";
      const ok = document.createElement("button"); ok.className = "small primary"; ok.textContent = "通过";
      ok.onclick = () => { accepted.add(u.id); send({ t: "friend_accept", from: u.id }); };

      const no = document.createElement("button"); no.className = "small"; no.textContent = "拒绝";
      no.onclick = () => send({ t: "friend_reject", from: u.id });
      row.append(ok, no); d.append(t, idl, row); rq.append(d);
    }
    const ul = $("friends"); ul.textContent = "";
    if (!friends.size) {
      const li = document.createElement("li"); li.className = "muted small"; li.style.cursor = "default";
      li.textContent = "还没有好友。复制上面的 ID 发给朋友，或输入对方的 ID 添加。"; ul.append(li);
    }
    for (const f of friends.values()) {
      const li = document.createElement("li"); if (f.id === active) li.className = "active";
      const av = avatar(f); const dot = document.createElement("span"); dot.className = "dot " + (f.online ? "on" : ""); av.append(dot);
      const n = document.createElement("div"); n.className = "fname"; n.textContent = displayName(f) + (f.verified ? "" : " ⚠️");
      li.append(av, n);
      if (f.unread) { const b = document.createElement("span"); b.className = "badge"; b.textContent = f.unread; li.append(b); }
      li.onclick = () => openChat(f.id);
      ul.append(li);
    }
  }

  // ---------- 聊天 ----------
  function chatOf(id) { if (!chats.has(id)) chats.set(id, { msgs: new Map(), loaded: false, more: false }); return chats.get(id); }

  function openChat(id) {
    active = id;
    const f = friends.get(id); if (f) f.unread = 0;
    $("app").classList.add("in-chat");
    $("composer").classList.remove("hidden"); $("chatActions").classList.remove("hidden");
    renderHead(); renderSide();
    const c = chatOf(id);
    if (!c.loaded) { renderMsgs(); send({ t: "history", with: id }); } else renderMsgs();
    $("text").focus();
  }
  function closeChat() {
    active = null; $("app").classList.remove("in-chat");
    $("composer").classList.add("hidden"); $("chatActions").classList.add("hidden");
    $("peerName").textContent = "选择一个好友开始聊天"; $("peerId").textContent = "";
    renderMsgs(); renderSide();
  }
  $("backBtn").onclick = closeChat;

  function renderHead() {
    const f = friends.get(active); if (!f) return;
    $("peerName").textContent = displayName(f) + (f.online ? " · 在线" : "");
    $("peerId").textContent = f.verified ? f.id : "⚠️ 对方加密公钥校验失败，已禁止发送：" + f.id;
  }

  function decrypt(m) {
    const peer = m.from === keys.id ? m.to : m.from;
    const f = friends.get(peer);
    if (!f || !f.shared) return null;
    try {
      const pt = nacl.box.open.after(fromB64(m.ct), fromB64(m.nonce), f.shared);
      if (!pt) return null;
      return JSON.parse(dec.decode(pt));
    } catch { return null; }
  }

  function msgEl(m) {
    const d = document.createElement("div");
    d.className = "msg" + (m.from === keys.id ? " mine" : "");
    d.dataset.mid = m.id;
    const body = decrypt(m);
    const txt = document.createElement("div");
    if (body && typeof body.text === "string") txt.textContent = body.text;
    else { txt.textContent = "[无法解密的消息]"; d.classList.add("bad"); }
    const meta = document.createElement("div"); meta.className = "meta";
    const del = document.createElement("button"); del.className = "del"; del.textContent = "双删";
    del.title = "从双方的聊天记录里彻底删除这条消息";
    del.onclick = () => { if (confirm("从双方记录里彻底删除这条消息？")) send({ t: "del", id: m.id }); };
    const tm = document.createElement("span"); tm.textContent = fmtTime(m.ts);
    meta.append(del, tm); d.append(txt, meta);
    return d;
  }

  function renderMsgs() {
    const box = $("msgs"); const more = $("moreBtn");
    box.textContent = ""; box.append(more);
    if (!active) { more.classList.add("hidden"); return; }
    const c = chatOf(active);
    more.classList.toggle("hidden", !c.more);
    if (c.loaded && !c.msgs.size) {
      const s = document.createElement("div"); s.className = "sys";
      s.textContent = "消息经过端到端加密，服务器无法读取。任意一方都可以双删。"; box.append(s);
    }
    [...c.msgs.values()].sort((a, b) => a.id - b.id).forEach((m) => box.append(msgEl(m)));
    box.scrollTop = box.scrollHeight;
  }

  $("moreBtn").onclick = () => {
    const c = chatOf(active); const ids = [...c.msgs.keys()];
    send({ t: "history", with: active, before: ids.length ? Math.min(...ids) : 0 });
  };

  function onHistory(m) {
    const c = chatOf(m.with);
    m.msgs.forEach((x) => c.msgs.set(x.id, x));
    c.loaded = true; c.more = m.more;
    if (active === m.with) {
      const box = $("msgs"); const prev = box.scrollHeight - box.scrollTop;
      renderMsgs();
      if (m.before) box.scrollTop = box.scrollHeight - prev;
    }
  }

  function onMsg(m) {
    const peer = m.from === keys.id ? m.to : m.from;
    const c = chatOf(peer);
    if (c.loaded) c.msgs.set(m.id, m);
    if (active === peer) {
      const box = $("msgs");
      const sys = box.querySelector(".sys"); if (sys) sys.remove();
      box.append(msgEl(m)); box.scrollTop = box.scrollHeight;
    } else if (m.from !== keys.id) {
      const f = friends.get(peer); if (f) { f.unread = (f.unread || 0) + 1; renderSide(); }
    }
  }

  function sendText() {
    const t = $("text").value;
    if (!t.trim() || !active) return;
    const f = friends.get(active);
    if (!f || !f.shared) { toast("对方的加密公钥校验失败，为了安全不能发送"); return; }
    const pt = enc.encode(JSON.stringify({ text: t }));
    if (pt.length > 60000) { toast("消息太长了"); return; }
    const nonce = nacl.randomBytes(nacl.box.nonceLength);
    const ct = nacl.box.after(pt, nonce, f.shared);
    send({ t: "send", to: active, nonce: toB64(nonce), ct: toB64(ct), cid: toHex(nacl.randomBytes(8)) });
    $("text").value = ""; autoGrow();
  }
  $("sendBtn").onclick = sendText;
  $("text").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendText(); }
  });
  function autoGrow() { const t = $("text"); t.style.height = "auto"; t.style.height = Math.min(140, t.scrollHeight) + "px"; }
  $("text").addEventListener("input", autoGrow);

  $("clearBtn").onclick = () => {
    if (!active) return;
    if (confirm("确定双删和 " + displayName(friends.get(active)) + " 的全部聊天记录？双方都会被清空，无法恢复。")) send({ t: "clear", with: active });
  };
  $("unfriendBtn").onclick = () => {
    if (!active) return;
    if (confirm("删除好友，同时双删全部聊天记录？")) send({ t: "unfriend", with: active });
  };

  // ---------- 打开网页时 ----------
  // 旧版把私钥明文存在浏览器里：立刻删除。私钥帮用户填进输入框，提醒设置本地密码重新保存。
  const old = localStorage.getItem(KEY_STORE);
  if (old !== null) {
    localStorage.removeItem(KEY_STORE);
    const s = parseSeed(old);
    if (s && !localStorage.getItem(KEY_STORE_V2)) {
      $("keyInput").value = toHex(s);
      $("loginNote").textContent = "旧版把私钥明文存在了浏览器里，已经删除。私钥已帮你填好：想继续记住，请勾选“记住密钥”并设置本地密码后登录。";
      $("loginNote").classList.remove("hidden");
    }
  }
  // http 网页（不是本机）没有加密功能：禁用“记住密钥”并说明原因
  if (!canRemember) {
    $("remember").checked = false; $("remember").disabled = true;
    $("rememberHint").textContent = "当前是 http:// 网页，浏览器不提供加密功能，无法安全地记住密钥。用 https:// 地址（例如接上 Cloudflare）打开就能用。";
    $("rememberHint").classList.remove("hidden");
  }
  $("remember").onchange(); // 浏览器刷新后可能还记着勾选状态，同步一下密码框显示

  // 保存过加密的私钥：显示解锁页
  if (localStorage.getItem(KEY_STORE_V2)) {
    $("login").classList.add("hidden"); $("unlock").classList.remove("hidden");
    if (!canRemember) $("unlockErr").textContent = "现在不是 https:// 网页，浏览器不允许解密。请用 https:// 地址打开，或者点“换一个密钥登录”。";
    else $("unlockPwd").focus();
  }

})();
