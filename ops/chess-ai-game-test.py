#!/usr/bin/env python3
# chess-ai-game-test.py — end-to-end "Play with the computer" test for chesspuertoricocoffee.com.
#
# Plays a real anonymous game against the computer exactly as a browser does:
#   POST /setup/ai (level 1, human = Black, unlimited)  -> lila creates the game
#   WebSocket /play/<gameId><playerId>/v6 via nginx -> caddy -> lila_ws
#   the AI (White) must move: lila -> redis fishnet-out -> lila_fishnet -> fishnet_play (Stockfish)
#     -> redis fishnet-in -> lila -> redis r-out -> lila_ws -> this socket
#   then a command is sent BACK over the socket (abort, or moves + resign): socket -> lila_ws -> r-in -> lila
#
# Default: wait for the AI's first move, then ABORT (status 25). Aborted games are not counted by the homepage
# news feed (chess-auto-feed.sh counts s >= 30), so the default run leaves no trace in site statistics.
# --moves N: also play N moves as Black (each must get an AI reply), then RESIGN — that game IS counted (s=31).
# --abort GAMEID+PLAYERID (12 chars): only abort that existing game over its socket (cleanup of a broken run).
#
# Exit 0 = PASS, 1 = FAIL. Last line is always "AI-GAME-TEST: PASS ..." or "AI-GAME-TEST: FAIL ...".
# Standard library only (Ubuntu's python3-websockets 9.1 is broken on Python 3.10). Connects to the public IP
# with SNI, never by name, like the other health checks on this host (/etc/hosts maps some host names locally).
# Added 2026-10-08 after lila_ws lost its boot race with redis (see chess-boot-heal.sh).
import argparse, base64, http.client, json, os, random, select, socket, ssl, string, struct, sys, time

HOST = "chesspuertoricocoffee.com"
IP = "82.165.212.204"
ORIGIN = "https://" + HOST
UA = "chesspuertoricocoffee.com-selftest/1.0 (ai-game-test)"
PING_EVERY = 2.0  # lila's client pings ("null" -> "0") every ~2.5 s; lila_ws drops silent sockets


def fail(msg):
    print(f"AI-GAME-TEST: FAIL {msg}", flush=True)
    sys.exit(1)


def tls_socket(ctx, timeout):
    raw = socket.create_connection((IP, 443), timeout)
    return ctx.wrap_socket(raw, server_hostname=HOST)


class PinnedHTTPS(http.client.HTTPSConnection):
    def connect(self):
        self.sock = tls_socket(self._context, self.timeout)


def create_game(ctx):
    body = "variant=1&timeMode=0&time=5&increment=3&days=2&level=1&color=black&fen="
    conn = PinnedHTTPS(HOST, 443, timeout=20, context=ctx)
    conn.request("POST", "/setup/ai", body=body, headers={
        "Host": HOST, "Origin": ORIGIN, "Referer": ORIGIN + "/", "User-Agent": UA,
        "Accept": "text/html", "Content-Type": "application/x-www-form-urlencoded"})
    r = conn.getresponse()
    r.read()
    loc = r.getheader("Location") or ""
    cookies = r.msg.get_all("Set-Cookie") or []
    conn.close()
    if r.status not in (301, 302, 303):
        fail(f"POST /setup/ai returned {r.status} (expected a redirect)")
    game_id = loc.strip("/").split("/")[0]
    player_id = next((c.split(";")[0].split("=", 1)[1] for c in cookies if c.startswith("rk2=")), "")
    if len(game_id) != 8 or len(player_id) != 4:
        fail(f"could not parse game/player id (Location={loc!r}, rk2={player_id!r})")
    return game_id, player_id


class WS:
    """Minimal RFC 6455 client: text frames, client masking, ping/pong/close. No extensions."""

    def __init__(self, ctx, path, cookie):
        self.sock = tls_socket(ctx, 15)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {path} HTTP/1.1\r\nHost: {HOST}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nOrigin: {ORIGIN}\r\n"
               f"User-Agent: {UA}\r\nCookie: {cookie}\r\n\r\n")
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                fail("socket closed during the WebSocket handshake")
            buf += chunk
        head, self.buf = buf.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if " 101 " not in status + " ":
            fail(f"WebSocket upgrade refused: {status!r} (lila_ws down? nginx/caddy routing?)")
        self.last_ping = 0.0

    def send_text(self, text):
        data, mask = text.encode(), os.urandom(4)
        n = len(data)
        hdr = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack("!H", n))
        self.sock.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _send_ctrl(self, opcode, payload=b""):
        mask = os.urandom(4)
        self.sock.sendall(bytes([0x80 | opcode, 0x80 | len(payload)]) + mask +
                          bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _frame(self):
        """Pop one complete frame from the buffer, or None."""
        b = self.buf
        if len(b) < 2:
            return None
        opcode, n, i = b[0] & 0x0F, b[1] & 0x7F, 2
        if n == 126:
            if len(b) < 4:
                return None
            n, i = struct.unpack("!H", b[2:4])[0], 4
        elif n == 127:
            if len(b) < 10:
                return None
            n, i = struct.unpack("!Q", b[2:10])[0], 10
        if b[1] & 0x80:  # servers must not mask, but handle it
            if len(b) < i + 4 + n:
                return None
            m = b[i:i + 4]
            payload = bytes(x ^ m[k % 4] for k, x in enumerate(b[i + 4:i + 4 + n]))
            self.buf = b[i + 4 + n:]
        else:
            if len(b) < i + n:
                return None
            payload, self.buf = b[i:i + n], b[i + n:]
        return b[0] & 0x80, opcode, payload

    def recv_text(self, deadline):
        """Next text message (str), keeping lila's ping going; None on deadline."""
        frag = b""
        while True:
            fr = self._frame()
            if fr:
                fin, op, payload = fr
                if op == 0x9:
                    self._send_ctrl(0xA, payload)
                elif op == 0x8:
                    fail("server closed the WebSocket")
                elif op in (0x1, 0x0):
                    frag += payload
                    if fin:
                        return frag.decode()
                continue
            now = time.monotonic()
            if now >= deadline:
                return None
            if now - self.last_ping >= PING_EVERY:
                self.send_text("null")
                self.last_ping = now
            wait = min(deadline - now, PING_EVERY - (now - self.last_ping))
            if self.sock.pending() or select.select([self.sock], [], [], max(wait, 0.01))[0]:
                chunk = self.sock.recv(65536)
                if not chunk:
                    fail("WebSocket connection dropped")
                self.buf += chunk

    def close(self):
        try:
            self._send_ctrl(0x8, struct.pack("!H", 1000))
            self.sock.close()
        except OSError:
            pass


def wait_for(ws, pred, timeout, what, game_id):
    deadline = time.monotonic() + timeout
    while True:
        raw = ws.recv_text(deadline)
        if raw is None:
            fail(f"timed out after {timeout}s waiting for {what} (game {game_id})")
        if raw == "0":
            continue
        try:
            msgs = json.loads(raw)
        except ValueError:
            continue
        for m in (msgs if isinstance(msgs, list) else [msgs]):
            if isinstance(m, dict):
                if m.get("t") == "resync":
                    fail(f"server asked for resync while waiting for {what} (game {game_id})")
                if pred(m):
                    return m


def move_at(ply):
    return lambda m: m.get("t") == "move" and isinstance(m.get("d"), dict) and m["d"].get("ply") == ply


def end_game(ws, game_id, cmd, want):
    ws.send_text(json.dumps({"t": cmd}))
    end = wait_for(ws, lambda m: m.get("t") == "endData", 15, f"the game to end after '{cmd}'", game_id)
    status = (end.get("d") or {}).get("status") or {}
    if status.get("id") != want:
        fail(f"after '{cmd}' the game status is {status} (expected {want}) (game {game_id})")
    print(f"  sent '{cmd}' over the socket -> game status {status.get('id')} ({status.get('name')})", flush=True)


def open_socket(ctx, game_id, player_id):
    sri = "".join(random.choices(string.ascii_letters + string.digits, k=12))
    ws = WS(ctx, f"/play/{game_id}{player_id}/v6?sri={sri}&v=0", f"rk2={player_id}")
    print(f"  socket open ({HOST}/play/{game_id}…)", flush=True)
    return ws


def play(ctx, game_id, player_id, moves, ai_timeout):
    t0 = time.monotonic()
    ws = open_socket(ctx, game_id, player_id)
    try:
        # v=0 makes lila_ws replay any versioned event we missed, so an AI move made before the socket opened
        # still arrives here.
        d = wait_for(ws, move_at(1), ai_timeout, "the AI's first move", game_id)["d"]
        print(f"  AI move 1: {d.get('san')} ({d.get('uci')}) after {time.monotonic() - t0:.1f}s", flush=True)
        ply = 1
        for i in range(moves):
            dests = d.get("dests") or {}
            if not isinstance(dests, dict) or not dests:
                fail(f"no legal-move list (dests) in the AI's move event (game {game_id})")
            orig = random.choice(sorted(dests))
            dest = random.choice([dests[orig][j:j + 2] for j in range(0, len(dests[orig]), 2)])
            uci = orig + dest  # first few moves: no promotion possible
            ws.send_text(json.dumps({"t": "move", "d": {"u": uci, "a": i + 1}}))
            wait_for(ws, move_at(ply + 1), 15, f"the server to accept our move {uci}", game_id)
            t1 = time.monotonic()
            d = wait_for(ws, move_at(ply + 2), ai_timeout, f"the AI's reply to {uci}", game_id)["d"]
            ply += 2
            print(f"  we played {uci}; AI replied {d.get('san')} ({d.get('uci')}) after {time.monotonic() - t1:.1f}s",
                  flush=True)
        if moves:
            end_game(ws, game_id, "resign", 31)
        else:
            end_game(ws, game_id, "abort", 25)
    finally:
        ws.close()
    return ply


def main():
    ap = argparse.ArgumentParser(description="End-to-end test of 'Play with the computer'.")
    ap.add_argument("--moves", type=int, default=0, help="moves to play as Black before resigning (default 0 = abort)")
    ap.add_argument("--ai-timeout", type=int, default=60, help="seconds to wait for each AI move (default 60)")
    ap.add_argument("--abort", metavar="FULLID", help="only abort this existing game (12-char game+player id)")
    a = ap.parse_args()
    ctx = ssl.create_default_context()
    if a.abort:
        if len(a.abort) != 12:
            fail("--abort needs the 12-character full id (8-char game id + 4-char player id)")
        ws = open_socket(ctx, a.abort[:8], a.abort[8:])
        try:
            end_game(ws, a.abort[:8], "abort", 25)
        finally:
            ws.close()
        print(f"AI-GAME-TEST: PASS aborted game {a.abort[:8]}", flush=True)
        return
    game_id, player_id = create_game(ctx)
    print(f"  created game {game_id} (human = Black, AI level 1)", flush=True)
    ply = play(ctx, game_id, player_id, a.moves, a.ai_timeout)
    print(f"AI-GAME-TEST: PASS game {game_id}: the computer made {(ply + 1) // 2} move(s) over the live WebSocket",
          flush=True)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # any network/protocol error is a FAIL with its reason
        fail(f"{type(e).__name__}: {e}")
