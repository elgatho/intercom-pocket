"""VoIP push relay: iOS apps register their PushKit token; Home Assistant / Node-RED calls /ring before a call.

Env: APNS_KEY_FILE (.p8), APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC (<bundle id>.voip), APNS_SANDBOX=1 for dev builds,
     RELAY_SECRET (shared bearer secret), RELAY_DB (default tokens.json).
Deps: pip install "httpx[http2]" "pyjwt[crypto]"
"""
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import httpx, jwt

DB = os.environ.get("RELAY_DB", "tokens.json")
SECRET = os.environ["RELAY_SECRET"]
HOST = "api.sandbox.push.apple.com" if os.environ.get("APNS_SANDBOX") == "1" else "api.push.apple.com"
_jwt = (0, "")
client = httpx.Client(http2=True, timeout=10)


def load():
    try:
        return json.load(open(DB))
    except OSError:
        return {}


def provider_token():
    global _jwt
    if time.time() - _jwt[0] > 3000:  # APNs wants a refresh between 20 and 60 minutes
        key = open(os.environ["APNS_KEY_FILE"]).read()
        t = jwt.encode({"iss": os.environ["APNS_TEAM_ID"], "iat": int(time.time())}, key,
                       algorithm="ES256", headers={"kid": os.environ["APNS_KEY_ID"]})
        _jwt = (time.time(), t)
    return _jwt[1]


def ring(dev, payload):
    r = client.post(f"https://{HOST}/3/device/{dev['token']}", json=payload, headers={
        "authorization": f"bearer {provider_token()}", "apns-topic": os.environ["APNS_TOPIC"],
        "apns-push-type": "voip", "apns-priority": "10", "apns-expiration": "0"})
    return r.status_code, r.text


class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        if self.headers.get("Authorization") != f"Bearer {SECRET}":
            return self._send(401, {"error": "unauthorized"})
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        db = load()
        if self.path == "/register":          # {id, token, name}
            db[body["id"]] = {"token": body["token"], "name": body.get("name", body["id"])}
            json.dump(db, open(DB, "w"))
            return self._send(200, {"ok": True})
        if self.path == "/ring":              # {id, from_id, from_name, host, port}
            dev = db.get(body.get("id"))
            if not dev:
                return self._send(404, {"error": "unknown device"})
            code, text = ring(dev, {"id": body.get("from_id", "?"), "name": body.get("from_name", "Intercom"),
                                    "host": body.get("host", ""), "port": body.get("port", 2324)})
            if code == 410:                   # token no longer valid
                db.pop(body["id"], None); json.dump(db, open(DB, "w"))
            return self._send(200 if code == 200 else 502, {"apns": code, "detail": text})
        self._send(404, {"error": "not found"})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", 8787))), H).serve_forever()
