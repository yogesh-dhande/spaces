#!/usr/bin/env bash

# Points a pairing link at an endpoint the running client can reach -- the SSH-configured address of
# a remote daemon, or a local SSH forward standing in for it -- by rewriting the `host` and `port`
# parameter values and nothing else.
#
# Every other parameter keeps the daemon's exact bytes. Decoding and re-encoding the query would
# re-spell escapes that the client then reads back differently, and the link version, wire-protocol
# version, app version, nonce, code, fingerprint, and name are all the daemon's to state: a harness
# that rebuilt them would pin a copy of a format it does not own, and would start failing pairing the
# next time that format moves. A link may advertise several candidate hosts, and the extras are the
# daemon's other addresses this machine cannot route, so they collapse into the single reachable one.
rewrite_pairing_link_endpoint() {
  local link="$1"
  local host="$2"
  local port="$3"
  python3 - "$link" "$host" "$port" <<'PY'
import sys
from urllib.parse import quote, urlsplit, urlunsplit

link, host, port = sys.argv[1:4]
parts = urlsplit(link)
substituted = []
seen_host = False
seen_port = False
for parameter in parts.query.split("&"):
    name = parameter.split("=", 1)[0]
    if name == "host":
        if seen_host:
            continue
        seen_host = True
        substituted.append("host=" + quote(host, safe=""))
    elif name == "port":
        seen_port = True
        substituted.append("port=" + quote(port, safe=""))
    else:
        substituted.append(parameter)
if not seen_host or not seen_port:
    raise SystemExit(f"pairing link carries no host or port parameter: {link}")
print(urlunsplit((parts.scheme, parts.netloc, parts.path, "&".join(substituted), parts.fragment)))
PY
}
