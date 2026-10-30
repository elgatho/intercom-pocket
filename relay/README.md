# VoIP push relay

iOS suspends the intercom app, so a LAN `POST /call` cannot reach it. The relay wakes it via APNs VoIP push.

Flow: iOS app registers `{id, token}` at `POST /register` → before a call to an iPhone, HA/Node-RED calls
`POST /ring {id, from_id, from_name, host, port}` → wait ~2 s → the normal Intercom `POST /api/intercom/call` to the phone.
Both endpoints need `Authorization: Bearer $RELAY_SECRET`. Requires a paid Apple Developer account (APNs key `.p8`,
topic `<bundle id>.voip`). Run: `docker run -e ... -v $PWD/AuthKey.p8:/key.p8 -p 8787:8787 intercom-relay`.

Home Assistant:
```yaml
rest_command:
  intercom_ring_iphone:
    url: http://RELAY:8787/ring
    method: post
    headers: { Authorization: "Bearer SECRET" }
    content_type: application/json
    payload: '{"id":"{{ id }}","from_id":"{{ from_id }}","from_name":"{{ from_name }}","host":"{{ host }}"}'
```
