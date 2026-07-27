#!/usr/bin/env bash
set -euo pipefail

umask 077

e2e_executable=${1:?usage: check-sync-e2e.sh E2E_EXECUTABLE TURSODB}
sync_server=${2:?usage: check-sync-e2e.sh E2E_EXECUTABLE TURSODB}
[[ -x "$e2e_executable" ]] || { echo "sync e2e executable is not runnable: $e2e_executable" >&2; exit 64; }
[[ -x "$sync_server" ]] || { echo "tursodb is not runnable: $sync_server" >&2; exit 64; }
e2e_executable=$(realpath "$e2e_executable")
sync_server=$(realpath "$sync_server")
command -v python3 >/dev/null 2>&1 || { echo "python3 is required to allocate a loopback port" >&2; exit 69; }

work_root=$(mktemp -d "${TMPDIR:-/tmp}/turso-zig-sync-e2e.XXXXXXXX")
server_log="$work_root/tursodb.log"
server_pid=
cleanup() {
    status=$?
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if (( status != 0 )) && [[ -s "$server_log" ]]; then
        echo "----- tursodb sync-server log -----" >&2
        sed -n '1,240p' "$server_log" >&2
    fi
    rm -rf -- "$work_root"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

port=$(python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
)
"$sync_server" --sync-server "127.0.0.1:$port" >"$server_log" 2>&1 &
server_pid=$!

ready=false
for _ in $(seq 1 200); do
    if ! kill -0 "$server_pid" 2>/dev/null; then break; fi
    if python3 - "$port" <<'PY'
import socket
import sys
try:
    with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.1) as connection:
        connection.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        connection.recv(1)
except OSError:
    raise SystemExit(1)
PY
    then
        ready=true
        break
    fi
    sleep 0.05
done
[[ "$ready" == true ]] || { echo "tursodb sync server did not become ready" >&2; exit 1; }

(
    cd "$work_root"
    "$e2e_executable" "http://127.0.0.1:$port"
)
