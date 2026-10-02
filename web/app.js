// 密语前端：所有加密、解密、签名都在浏览器里完成，服务器只见到密文。
// 名词：
//   私钥（seed）：32 字节随机数，用 64 位十六进制表示，是你唯一的登录凭证。
//   ID：由私钥算出的 Ed25519 签名公钥，发给朋友用来加好友。
//   加密公钥：由私钥派生的 X25519 公钥，用于和好友协商加密密钥；它被你的签名公钥签过名，服务器无法偷换。
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
  const KEY_STORE = "miyu.key";

  // ---------- 状态 ----------
  let keys = null;        // {seed, sign, box, id}
  let ws = null, wsOk = false, retry = 0;
  let me = null;
  const friends = new Map();   // id -> {id,name,box,boxsig,online,verified,shared,unread}
  const requests = new Map();  // id -> user
  const chats = new Map();     // id -> {msgs: Map(id->msg), loaded, more, oldest}
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

  // ---------- 登录页 ----------
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
    if ($("remember").checked) localStorage.setItem(KEY_STORE, toHex(seed)); else localStorage.removeItem(KEY_STORE);
    start(seed);
  };
  $("keyInput").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); $("loginBtn").click(); } });

  function start(seed) {
    keys = deriveKeys(seed);
    $("loginErr").textContent = "";
    $("login").classList.add("hidden");
    $("app").classList.remove("hidden");
    $("myId").textContent = keys.id;
    connect();
  }
  $("logoutBtn").onclick = () => {
    if (!confirm("退出后需要重新输入私钥才能登录。确定退出？")) return;
    localStorage.removeItem(KEY_STORE);
    location.reload();
  };

  // ---------- 连接 ----------
  function setConn(ok, text) {
    wsOk = ok;
    $("connState").className = "dot " + (ok ? "on" : "off");
    $("connText").textContent = text;
  }
  function send(obj) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); else toast("还没连上服务器，请稍等"); }

  function connect() {
    setConn(false, "连接中…");
    const proto = location.protocol === "https:" ? "wss://" : "ws://";
    ws = new WebSocket(proto + location.host + "/ws");
    ws.onmessage = (ev) => { let m; try { m = JSON.parse(ev.data); } catch { return; } handle(m); };
    ws.onclose = () => {
      setConn(false, "已断开，正在重连…");
      const wait = Math.min(15000, 1000 * 2 ** retry++);
      setTimeout(connect, wait);
    };
  }

  function handle(m) {
    switch (m.t) {
      case "challenge": {
        // 用私钥对服务器给的随机数签名，证明我拥有这个 ID
        const sig = nacl.sign.detached(enc.encode("miyu-login:" + m.nonce), keys.sign.secretKey);
        const boxHex = toHex(keys.box.publicKey);
        const boxsig = nacl.sign.detached(enc.encode("miyu-box:" + boxHex), keys.sign.secretKey);
        ws.send(JSON.stringify({ t: "auth", pub: keys.id, box: boxHex, boxsig: toHex(boxsig), sig: toHex(sig) }));
        break;
      }
      case "ready":
        retry = 0; setConn(true, "已连接 · 端到端加密");
        me = m.me; $("myName").value = me.name || "";
        friends.clear(); requests.clear();
        m.friends.forEach(prepFriend);
        m.requests.forEach((u) => requests.set(u.id, u));
        // 重连后清掉缓存重新拉，保证离线期间被双删的消息不会残留
        chats.clear();
        renderSide();
        if (active && friends.has(active)) openChat(active); else if (active) closeChat();
        break;
      case "me": me = m.me; toast("昵称已保存"); break;
      case "error": toast(m.msg); break;
      case "req_sent": toast("好友申请已发送，等对方通过"); $("addInput").value = ""; break;
      case "request": requests.set(m.user.id, m.user); renderSide(); toast("收到新的好友申请"); break;
      case "request_gone": requests.delete(m.id); renderSide(); break;
      case "friend_added":
        requests.delete(m.user.id); prepFriend(m.user); renderSide();
        toast("已添加好友 " + displayName(m.user)); $("addInput").value = "";
        break;
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

  // ---------- 侧边栏 ----------
  $("saveName").onclick = () => send({ t: "setname", name: $("myName").value });
  $("copyId").onclick = () => copy(keys.id);
  $("addBtn").onclick = () => {
    const id = $("addInput").value.trim().toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(id)) { toast("好友 ID 应该是 64 位十六进制"); return; }
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
      ok.onclick = () => send({ t: "friend_accept", from: u.id });
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

  // 记住了密钥就自动登录
  const saved = localStorage.getItem(KEY_STORE);
  if (saved) { const s = parseSeed(saved); if (s) { $("remember").checked = true; start(s); } }
})();
