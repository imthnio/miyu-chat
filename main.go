// miyu-chat（密语）：轻量的端到端加密网页聊天服务端。
//
// 名词小词典（写给第一次接触的人）：
//
//	端到端加密：消息在你的浏览器里加密，只有聊天对方的浏览器能解开。服务器只负责转发和保存“看不懂的密文”。
//	密钥登录：没有账号密码。每个人有一把私钥，服务器发一串随机数，浏览器用私钥签名，签名对了就算登录成功。
//	域名绑定：登录签名里带上浏览器地址栏里的网址（域名[:端口]）。别的服务器就算把我们的随机数转给你签名，
//	          签出来的也是“它自己的网址”，拿到我们这里验证不通过，没法冒充你登录。
//	ID / 公钥：由私钥算出来，可以公开，发给朋友加好友用。
//	双删：任意一方删除消息，服务器会把密文彻底删掉，并通知双方浏览器立刻清掉这条消息。
//	WebSocket：浏览器和服务器之间一直保持的连接，新消息能马上推过来，不用一直刷新页面。
//	SQLite：一个单文件数据库，所有数据都在 -db 指定的那个文件里（安装脚本默认放 /var/lib/miyu-chat/miyu.db）。
//
// 整个程序是一个文件，网页也打包在里面，内存占用十几 MB，适合 256MB 的小鸡。
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"flag"
	"io/fs"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/gorilla/websocket"
	_ "modernc.org/sqlite"
)

//go:embed web
var webFS embed.FS

const (
	maxCipherLen = 96 * 1024 // base64 密文上限
	historyPage  = 50
	// 防止被人开一大堆连接把小鸡拖垮：全站最多同时这么多条连接，同一个身份最多开这么多个页面
	maxConns      = 2000
	maxConnsPerID = 20
	authTimeout   = 15 * time.Second // 连上后这么久还没登录就断开
	idleTimeout   = 90 * time.Second // 登录后这么久没任何动静就断开
)

var connCount atomic.Int64

// allowedHosts 是 -host / MIYU_HOST 设置的“允许的网址”列表（小写，可以有多个）。
// 为空时就用这次请求里的 Host（也就是浏览器访问的网址）。
var allowedHosts []string

var db *sql.DB

// version 由编译时 -ldflags "-X main.version=v1.0.0" 写入，方便安装脚本判断版本
var version = "dev"

// ---------- 数据库 ----------

func openDB(path string) {
	var err error
	db, err = sql.Open("sqlite", path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)")
	if err != nil {
		log.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS users(pub TEXT PRIMARY KEY, box TEXT NOT NULL, boxsig TEXT NOT NULL, name TEXT NOT NULL DEFAULT '', created INTEGER, seen INTEGER)`,
		`CREATE TABLE IF NOT EXISTS friends(a TEXT, b TEXT, ts INTEGER, PRIMARY KEY(a,b))`,
		`CREATE TABLE IF NOT EXISTS requests(from_pub TEXT, to_pub TEXT, ts INTEGER, PRIMARY KEY(from_pub,to_pub))`,
		`CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY AUTOINCREMENT, pa TEXT, pb TEXT, from_pub TEXT, to_pub TEXT, nonce TEXT, ct TEXT, ts INTEGER)`,
		`CREATE INDEX IF NOT EXISTS idx_msg_pair ON messages(pa,pb,id)`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			log.Fatal(err)
		}
	}
}

func pair(x, y string) (string, string) {
	if x < y {
		return x, y
	}
	return y, x
}

func now() int64 { return time.Now().UnixMilli() }

type userInfo struct {
	ID     string `json:"id"`
	Box    string `json:"box"`
	BoxSig string `json:"boxsig"`
	Name   string `json:"name"`
}

func getUser(pub string) (*userInfo, error) {
	u := &userInfo{ID: pub}
	err := db.QueryRow(`SELECT box, boxsig, name FROM users WHERE pub=?`, pub).Scan(&u.Box, &u.BoxSig, &u.Name)
	if err != nil {
		return nil, err
	}
	return u, nil
}

func isFriend(a, b string) bool {
	var n int
	db.QueryRow(`SELECT COUNT(*) FROM friends WHERE a=? AND b=?`, a, b).Scan(&n)
	return n > 0
}

func listUsers(q string, args ...any) []userInfo {
	out := []userInfo{}
	rows, err := db.Query(q, args...)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var u userInfo
		if rows.Scan(&u.ID, &u.Box, &u.BoxSig, &u.Name) == nil {
			out = append(out, u)
		}
	}
	return out
}

func friendsOf(pub string) []userInfo {
	return listUsers(`SELECT u.pub,u.box,u.boxsig,u.name FROM friends f JOIN users u ON u.pub=f.b WHERE f.a=? ORDER BY f.ts`, pub)
}

func requestsTo(pub string) []userInfo {
	return listUsers(`SELECT u.pub,u.box,u.boxsig,u.name FROM requests r JOIN users u ON u.pub=r.from_pub WHERE r.to_pub=? ORDER BY r.ts`, pub)
}

func requestsFrom(pub string) []string {
	out := []string{}
	rows, err := db.Query(`SELECT to_pub FROM requests WHERE from_pub=?`, pub)
	if err != nil {
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var s string
		if rows.Scan(&s) == nil {
			out = append(out, s)
		}
	}
	return out
}

type message struct {
	ID    int64  `json:"id"`
	From  string `json:"from"`
	To    string `json:"to"`
	Nonce string `json:"nonce"`
	CT    string `json:"ct"`
	TS    int64  `json:"ts"`
	CID   string `json:"cid,omitempty"`
}

// ---------- 连接管理 ----------

type client struct {
	conn *websocket.Conn
	send chan []byte
	pub  string
	// 简单限流
	tokens float64
	last   time.Time
}

type hub struct {
	mu    sync.Mutex
	conns map[string]map[*client]bool
}

var h = &hub{conns: map[string]map[*client]bool{}}

func (h *hub) add(c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.conns[c.pub] == nil {
		h.conns[c.pub] = map[*client]bool{}
	}
	h.conns[c.pub][c] = true
}

func (h *hub) remove(c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if m := h.conns[c.pub]; m != nil {
		delete(m, c)
		if len(m) == 0 {
			delete(h.conns, c.pub)
		}
	}
}

func (h *hub) count(pub string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.conns[pub])
}

func (h *hub) online(pub string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.conns[pub]) > 0
}

func (h *hub) push(pub string, v any) {
	b, _ := json.Marshal(v)
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.conns[pub] {
		c.enqueue(b)
	}
}

// enqueue 把要发给浏览器的数据放进发送队列。
// 队列满了说明对方网太慢或卡住了：直接断开这条连接，浏览器会自动重连并重新拉取，
// 这样不会悄悄丢消息（以前是直接丢弃，但连接不断，浏览器就不知道要重新拉取）。
func (c *client) enqueue(b []byte) {
	select {
	case c.send <- b:
	default:
		c.conn.Close()
	}
}

func (c *client) reply(v any) {
	b, _ := json.Marshal(v)
	c.enqueue(b)
}

func (c *client) fail(msg string) { c.reply(map[string]any{"t": "error", "msg": msg}) }

func (c *client) allow() bool {
	t := time.Now()
	c.tokens += t.Sub(c.last).Seconds() * 10
	if c.tokens > 30 {
		c.tokens = 30
	}
	c.last = t
	if c.tokens < 1 {
		return false
	}
	c.tokens--
	return true
}

// ---------- WebSocket ----------

var upgrader = websocket.Upgrader{ReadBufferSize: 4096, WriteBufferSize: 4096}

func validHex(s string, n int) bool {
	if len(s) != n*2 {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}

// validB64 检查是不是标准 base64，并且解出来的字节数在 [min, max] 范围内
func validB64(s string, min, max int) bool {
	b, err := base64.StdEncoding.DecodeString(s)
	return err == nil && len(b) >= min && len(b) <= max
}

// parseHosts 把 "chat.example.com, 1.2.3.4:8080" 这样逗号分隔的写法拆成小写列表，空的去掉
func parseHosts(s string) []string {
	out := []string{}
	for _, p := range strings.Split(s, ",") {
		if p = strings.ToLower(strings.TrimSpace(p)); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// loginHosts 返回这次登录允许出现在签名里的网址。
// 设置了 MIYU_HOST 就只认它（最安全）；没设置就认浏览器访问时带来的 Host。
func loginHosts(r *http.Request) []string {
	if len(allowedHosts) > 0 {
		return allowedHosts
	}
	return []string{strings.ToLower(r.Host)}
}

// verifyLogin 检查登录签名：签的内容必须是 "miyu-login:v2:" + 网址 + ":" + 随机数，网址必须是我们允许的。
// 旧版（v1）只签 "miyu-login:" + 随机数，这里不再接受，所以旧版网页需要刷新到新版才能登录。
func verifyLogin(pub, nonce, sig string, hosts []string) bool {
	for _, host := range hosts {
		if verify(pub, "miyu-login:v2:"+host+":"+nonce, sig) {
			return true
		}
	}
	return false
}

func verify(pubHex, msg, sigHex string) bool {
	pub, err1 := hex.DecodeString(pubHex)
	sig, err2 := hex.DecodeString(sigHex)
	if err1 != nil || err2 != nil || len(pub) != ed25519.PublicKeySize || len(sig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(pub, []byte(msg), sig)
}

type inMsg struct {
	T      string `json:"t"`
	Pub    string `json:"pub"`
	Box    string `json:"box"`
	BoxSig string `json:"boxsig"`
	Sig    string `json:"sig"`
	Name   string `json:"name"`
	To     string `json:"to"`
	From   string `json:"from"`
	With   string `json:"with"`
	ID     int64  `json:"id"`
	Before int64  `json:"before"`
	Nonce  string `json:"nonce"`
	CT     string `json:"ct"`
	CID    string `json:"cid"`
}

func serveWS(w http.ResponseWriter, r *http.Request) {
	if connCount.Add(1) > maxConns {
		connCount.Add(-1)
		http.Error(w, "服务器连接数已满，请稍后再试", http.StatusServiceUnavailable)
		return
	}
	defer connCount.Add(-1)
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	conn.SetReadLimit(256 * 1024)
	c := &client{conn: conn, send: make(chan []byte, 256), tokens: 30, last: time.Now()}

	// 写协程
	done := make(chan struct{})
	writerExit := make(chan struct{})
	go func() {
		ping := time.NewTicker(30 * time.Second)
		defer ping.Stop()
		defer close(writerExit)
		for {
			select {
			case b := <-c.send:
				conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				if conn.WriteMessage(websocket.TextMessage, b) != nil {
					conn.Close()
					return
				}
			case <-ping.C:
				conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
				if conn.WriteMessage(websocket.PingMessage, nil) != nil {
					conn.Close()
					return
				}
			case <-done:
				// 读协程要断开了：先把队列里剩下的消息（比如“密钥校验失败”）发完，浏览器才知道为什么被断开
				for {
					select {
					case b := <-c.send:
						conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
						if conn.WriteMessage(websocket.TextMessage, b) != nil {
							return
						}
					default:
						conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
						conn.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
						return
					}
				}
			}
		}
	}()
	defer func() {
		close(done)
		<-writerExit
		if c.pub != "" {
			h.remove(c)
			db.Exec(`UPDATE users SET seen=? WHERE pub=?`, now(), c.pub)
			// 这个身份的最后一个页面也断开了：告诉好友“已离线”，否则好友那边会一直显示在线
			if !h.online(c.pub) {
				for _, f := range friendsOf(c.pub) {
					h.push(f.ID, map[string]any{"t": "presence", "id": c.pub, "online": false})
				}
			}
		}
		conn.Close()
	}()

	// 没登录的连接只给 authTimeout 时间，登录后才按 idleTimeout 续期（心跳回应也只在登录后续期）
	conn.SetReadDeadline(time.Now().Add(authTimeout))
	conn.SetPongHandler(func(string) error {
		if c.pub != "" {
			conn.SetReadDeadline(time.Now().Add(idleTimeout))
		}
		return nil
	})

	// 登录挑战
	nb := make([]byte, 32)
	rand.Read(nb)
	nonce := hex.EncodeToString(nb)
	hosts := loginHosts(r)
	c.reply(map[string]any{"t": "challenge", "nonce": nonce})

	for {
		_, data, err := conn.ReadMessage()
		if err != nil {
			return
		}
		if c.pub != "" {
			conn.SetReadDeadline(time.Now().Add(idleTimeout))
		}
		// 先限流再解析：乱发的垃圾数据也要算次数，免得白白消耗 CPU
		if !c.allow() {
			c.fail("操作太频繁，请稍后再试")
			continue
		}
		var m inMsg
		if json.Unmarshal(data, &m) != nil {
			c.fail("数据格式错误")
			continue
		}
		if c.pub == "" {
			if m.T != "auth" {
				c.fail("请先登录")
				continue
			}
			m.Pub, m.Box = strings.ToLower(m.Pub), strings.ToLower(m.Box) // 统一小写，避免同一把钥匙变成两个用户
			if !validHex(m.Pub, 32) || !validHex(m.Box, 32) ||
				!verifyLogin(m.Pub, nonce, m.Sig, hosts) ||
				!verify(m.Pub, "miyu-box:"+m.Box, m.BoxSig) {
				c.reply(map[string]any{"t": "error", "code": "bad_auth",
					"msg": "密钥校验失败：请刷新网页换到最新版再登录；如果还不行，请让管理员确认 MIYU_HOST 和你访问的网址一致"})
				return
			}
			if h.count(m.Pub) >= maxConnsPerID {
				c.fail("同一个身份打开的页面太多了，请关掉一些再试")
				return
			}
			t := now()
			_, err := db.Exec(`INSERT INTO users(pub,box,boxsig,name,created,seen) VALUES(?,?,?,?,?,?)
				ON CONFLICT(pub) DO UPDATE SET box=excluded.box, boxsig=excluded.boxsig, seen=excluded.seen`,
				m.Pub, m.Box, m.BoxSig, "", t, t)
			if err != nil {
				c.fail("服务器错误")
				return
			}
			c.pub = m.Pub
			h.add(c)
			me, _ := getUser(c.pub)
			c.reply(map[string]any{"t": "ready", "me": me, "friends": c.friendList(), "requests": requestsTo(c.pub), "sent": requestsFrom(c.pub)})
			for _, f := range friendsOf(c.pub) {
				h.push(f.ID, map[string]any{"t": "presence", "id": c.pub, "online": true})
			}
			continue
		}
		c.handle(&m)
	}
}

type friendView struct {
	userInfo
	Online bool `json:"online"`
}

func (c *client) friendList() []friendView {
	out := []friendView{}
	for _, f := range friendsOf(c.pub) {
		out = append(out, friendView{f, h.online(f.ID)})
	}
	return out
}

func (c *client) handle(m *inMsg) {
	switch m.T {
	case "setname":
		// 去掉看不见的控制字符/方向控制符（比如 U+202E 能把文字倒过来显示，用来冒充别人）
		name := strings.TrimSpace(strings.Map(func(r rune) rune {
			if unicode.Is(unicode.Cc, r) || unicode.Is(unicode.Cf, r) {
				return -1
			}
			return r
		}, m.Name))
		if utf8.RuneCountInString(name) > 24 {
			c.fail("昵称最多 24 个字")
			return
		}
		db.Exec(`UPDATE users SET name=? WHERE pub=?`, name, c.pub)
		me, _ := getUser(c.pub)
		c.reply(map[string]any{"t": "me", "me": me})
		for _, f := range friendsOf(c.pub) {
			h.push(f.ID, map[string]any{"t": "friend_update", "user": me})
		}

	case "friend_req":
		to := strings.ToLower(strings.TrimSpace(m.To))
		if !validHex(to, 32) {
			c.fail("好友 ID 格式不对（应为 64 位十六进制）")
			return
		}
		if to == c.pub {
			c.fail("不能加自己为好友")
			return
		}
		target, err := getUser(to)
		if err != nil {
			c.fail("找不到这个用户（对方需要先登录过一次）")
			return
		}
		if isFriend(c.pub, to) {
			c.fail("你们已经是好友了")
			return
		}
		// 对方已经申请过我，直接成为好友
		var n int
		db.QueryRow(`SELECT COUNT(*) FROM requests WHERE from_pub=? AND to_pub=?`, to, c.pub).Scan(&n)
		if n > 0 {
			c.makeFriends(to)
			return
		}
		db.Exec(`INSERT OR IGNORE INTO requests(from_pub,to_pub,ts) VALUES(?,?,?)`, c.pub, to, now())
		me, _ := getUser(c.pub)
		h.push(to, map[string]any{"t": "request", "user": me})
		c.reply(map[string]any{"t": "req_sent", "id": to, "name": target.Name})

	case "friend_accept":
		var n int
		db.QueryRow(`SELECT COUNT(*) FROM requests WHERE from_pub=? AND to_pub=?`, m.From, c.pub).Scan(&n)
		if n == 0 {
			c.fail("好友申请不存在")
			return
		}
		c.makeFriends(m.From)

	case "friend_reject":
		db.Exec(`DELETE FROM requests WHERE from_pub=? AND to_pub=?`, m.From, c.pub)
		c.reply(map[string]any{"t": "request_gone", "id": m.From})

	case "unfriend":
		// 删除好友，并双删全部聊天记录
		was := isFriend(c.pub, m.With)
		a, b := pair(c.pub, m.With)
		db.Exec(`DELETE FROM messages WHERE pa=? AND pb=?`, a, b)
		db.Exec(`DELETE FROM friends WHERE (a=? AND b=?) OR (a=? AND b=?)`, c.pub, m.With, m.With, c.pub)
		db.Exec(`DELETE FROM requests WHERE (from_pub=? AND to_pub=?) OR (from_pub=? AND to_pub=?)`, c.pub, m.With, m.With, c.pub)
		h.push(c.pub, map[string]any{"t": "unfriended", "id": m.With})
		if was { // 只通知真正的好友，防止给任意 ID 乱推通知
			h.push(m.With, map[string]any{"t": "unfriended", "id": c.pub})
		}

	case "history":
		if !isFriend(c.pub, m.With) {
			c.fail("对方不是你的好友")
			return
		}
		a, b := pair(c.pub, m.With)
		before := m.Before
		if before <= 0 {
			before = 1 << 62
		}
		rows, err := db.Query(`SELECT id,from_pub,to_pub,nonce,ct,ts FROM messages WHERE pa=? AND pb=? AND id<? ORDER BY id DESC LIMIT ?`, a, b, before, historyPage)
		if err != nil {
			c.fail("服务器错误")
			return
		}
		msgs := []message{}
		for rows.Next() {
			var x message
			if rows.Scan(&x.ID, &x.From, &x.To, &x.Nonce, &x.CT, &x.TS) == nil {
				msgs = append(msgs, x)
			}
		}
		rows.Close()
		// 反转为时间正序
		for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
			msgs[i], msgs[j] = msgs[j], msgs[i]
		}
		c.reply(map[string]any{"t": "history", "with": m.With, "msgs": msgs, "more": len(msgs) == historyPage, "before": m.Before})

	case "send":
		if !isFriend(c.pub, m.To) {
			c.fail("对方不是你的好友")
			return
		}
		// 密文和 nonce 必须是合法 base64：nonce 正好 24 字节，密文至少 16 字节（加密自带的校验码）
		if len(m.CT) == 0 || len(m.CT) > maxCipherLen || !validB64(m.CT, 16, maxCipherLen) ||
			!validB64(m.Nonce, 24, 24) || len(m.CID) > 64 {
			c.fail("消息太长或格式错误")
			return
		}
		a, b := pair(c.pub, m.To)
		t := now()
		res, err := db.Exec(`INSERT INTO messages(pa,pb,from_pub,to_pub,nonce,ct,ts) VALUES(?,?,?,?,?,?,?)`, a, b, c.pub, m.To, m.Nonce, m.CT, t)
		if err != nil {
			c.fail("服务器错误")
			return
		}
		id, _ := res.LastInsertId()
		msg := message{ID: id, From: c.pub, To: m.To, Nonce: m.Nonce, CT: m.CT, TS: t, CID: m.CID}
		h.push(c.pub, map[string]any{"t": "msg", "msg": msg})
		msg.CID = ""
		h.push(m.To, map[string]any{"t": "msg", "msg": msg})

	case "del":
		// 双删单条：收发任意一方都可以
		var from, to string
		if db.QueryRow(`SELECT from_pub,to_pub FROM messages WHERE id=?`, m.ID).Scan(&from, &to) != nil {
			return
		}
		if from != c.pub && to != c.pub {
			c.fail("无权删除")
			return
		}
		db.Exec(`DELETE FROM messages WHERE id=?`, m.ID)
		ev := map[string]any{"t": "deleted", "id": m.ID}
		h.push(from, ev)
		h.push(to, ev)

	case "clear":
		// 双删整个会话（只能删自己和好友之间的；不是好友就不推通知，防止骚扰任意 ID）
		if !isFriend(c.pub, m.With) {
			c.fail("对方不是你的好友")
			return
		}
		a, b := pair(c.pub, m.With)
		db.Exec(`DELETE FROM messages WHERE pa=? AND pb=?`, a, b)
		h.push(c.pub, map[string]any{"t": "cleared", "with": m.With, "by": c.pub})
		h.push(m.With, map[string]any{"t": "cleared", "with": c.pub, "by": c.pub})
	}
}

func (c *client) makeFriends(other string) {
	t := now()
	db.Exec(`DELETE FROM requests WHERE (from_pub=? AND to_pub=?) OR (from_pub=? AND to_pub=?)`, c.pub, other, other, c.pub)
	db.Exec(`INSERT OR IGNORE INTO friends(a,b,ts) VALUES(?,?,?)`, c.pub, other, t)
	db.Exec(`INSERT OR IGNORE INTO friends(a,b,ts) VALUES(?,?,?)`, other, c.pub, t)
	me, _ := getUser(c.pub)
	them, _ := getUser(other)
	if me == nil || them == nil {
		return
	}
	h.push(c.pub, map[string]any{"t": "friend_added", "user": friendView{*them, h.online(other)}})
	h.push(other, map[string]any{"t": "friend_added", "user": friendView{*me, true}})
}

// ---------- 入口 ----------

func main() {
	addr := flag.String("listen", envOr("MIYU_LISTEN", ":8080"), "监听地址，例如 :8080")
	dbPath := flag.String("db", envOr("MIYU_DB", "miyu.db"), "SQLite 数据库文件")
	hostList := flag.String("host", envOr("MIYU_HOST", ""), "允许登录的网址（域名[:端口]），多个用逗号分隔，例如 chat.example.com；不填就用浏览器访问的网址")
	showVer := flag.Bool("version", false, "显示版本号后退出")
	flag.Parse()
	if *showVer {
		println("miyu-chat " + version)
		return
	}
	allowedHosts = parseHosts(*hostList)
	if len(allowedHosts) == 0 {
		log.Printf("提示：没有设置 MIYU_HOST，登录时以浏览器访问的网址为准。建议设置成你的聊天域名（例如 MIYU_HOST=chat.example.com），防止别的网站转发登录")
	} else {
		log.Printf("登录只认这些网址：%s", strings.Join(allowedHosts, ", "))
	}

	openDB(*dbPath)
	sub, _ := fs.Sub(webFS, "web")
	files := http.FileServer(http.FS(sub))

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", serveWS)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.Handle("/", securityHeaders(files))

	log.Printf("miyu-chat %s 启动，监听 %s，数据库 %s", version, *addr, *dbPath)
	srv := &http.Server{Addr: *addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'self'; connect-src 'self' ws: wss:; img-src 'self' data: blob:; style-src 'self'; script-src 'self'; frame-ancestors 'none'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-cache")
		next.ServeHTTP(w, r)
	})
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
