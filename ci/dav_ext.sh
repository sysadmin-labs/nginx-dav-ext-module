#!/bin/sh
#
# Drive the dav_ext module against a running nginx with a real HTTP client:
# the WebDAV methods it adds on top of the standard dav module, end to end.
#
# t/ exercises the same paths through Test::Nginx and HTTP::DAV, but HTTP::DAV
# 0.50 cannot drive UNLOCK (its unlock() sends no request), so the lock, unlock
# and relock cycle is asserted here with curl, which sends the Lock-Token the
# server hands back.  This is also what the FreeBSD job, the sanitizer job and
# the valgrind job run.
#
# usage: ci/dav_ext.sh <nginx binary>
#
# Set DAV_EXT_LOAD_MODULE to the path of ngx_http_dav_ext_module.so to test a
# loadable build.  Set DAV_EXT_VALGRIND=1 to run one foreground nginx under
# valgrind and fail on any memory finding.

set -eu

NGINX=${1:?path to the nginx binary missing}
SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}/dav_ext
PORT=${DAV_EXT_PORT:-18660}

command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }

VG=${DAV_EXT_VALGRIND:-}
vglog="$WORK/logs/valgrind.log"
maxtime=10
daemon_mode=on
master_mode=on
if [ -n "$VG" ]; then
	command -v valgrind > /dev/null || { echo "valgrind(1) is needed" >&2; exit 2; }
	daemon_mode=off
	master_mode=off
	maxtime=60
fi

rm -rf "$WORK"
mkdir -p "$WORK/conf" "$WORK/logs" "$WORK/root"

fail=0
note() { echo "  $1" >&2; fail=1; }

# A known payload so a PUT and the GET that reads it back can be compared
# byte for byte.
payload="$WORK/payload.bin"
head -c 200000 /dev/urandom > "$payload"

load=
[ -n "${DAV_EXT_LOAD_MODULE:-}" ] && load="load_module $DAV_EXT_LOAD_MODULE;"

# Run as a normal user and nginx workers inherit that identity; run as root
# (the FreeBSD job does) and they drop to "nobody", which cannot write the
# dav root, so pin the workers to root there.
ngx_user=
if [ "$(id -u)" = 0 ]; then
	ngx_user="user root $(id -gn);"
fi

cat > "$WORK/conf/nginx.conf" <<CONF
$load
$ngx_user
daemon $daemon_mode;
master_process $master_mode;
worker_processes 1;
pid $WORK/logs/nginx.pid;
error_log $WORK/logs/error.log info;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $WORK/tmp;
    client_max_body_size 10m;

    dav_ext_lock_zone zone=z:10m timeout=30s;

    server {
        listen 127.0.0.1:$PORT;

        location / {
            root $WORK/root;
            client_body_temp_path $WORK/tmp;
            dav_methods PUT DELETE MKCOL COPY MOVE;
            dav_ext_methods PROPFIND OPTIONS LOCK UNLOCK;
            dav_ext_lock zone=z;
            create_full_put_path on;
            autoindex on;
        }
    }
}
CONF

"$NGINX" -p "$WORK" -c "$WORK/conf/nginx.conf" -t 2> "$WORK/logs/t.log" ||
	{ cat "$WORK/logs/t.log" >&2; echo "ci/dav_ext.sh: config rejected" >&2; exit 1; }

ngxpid=
if [ -n "$VG" ]; then
	valgrind --leak-check=full --show-leak-kinds=definite,indirect \
		--errors-for-leak-kinds=definite,indirect --error-exitcode=99 \
		--log-file="$vglog" --suppressions="$SRC/valgrind.suppress" \
		--trace-children=no \
		"$NGINX" -p "$WORK" -c "$WORK/conf/nginx.conf" &
	ngxpid=$!
	up=0; i=0
	while [ $i -lt 80 ]; do
		if curl -s -o /dev/null --max-time 5 -X OPTIONS "http://127.0.0.1:$PORT/"; then
			up=1; break
		fi
		sleep 0.5; i=$((i + 1))
	done
	[ "$up" = 1 ] || { echo "ci/dav_ext.sh: nginx did not come up under valgrind" >&2; kill "$ngxpid" 2>/dev/null; exit 1; }
else
	"$NGINX" -p "$WORK" -c "$WORK/conf/nginx.conf"
	sleep 1
fi

stop() {
	if [ -n "$ngxpid" ]; then
		kill -QUIT "$ngxpid" 2>/dev/null
		wait "$ngxpid" 2>/dev/null
	elif [ -s "$WORK/logs/nginx.pid" ]; then
		kill -QUIT "$(cat "$WORK/logs/nginx.pid")" 2>/dev/null
	fi
	return 0
}
trap stop EXIT INT TERM

base="http://127.0.0.1:$PORT"
lockbody='<?xml version="1.0"?><D:lockinfo xmlns:D="DAV:"><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockinfo>'

echo "== OPTIONS advertises WebDAV"
hdr=$(curl -s -D - -o /dev/null --max-time "$maxtime" -X OPTIONS "$base/")
echo "$hdr" | grep -qiE '^HTTP/[0-9.]+ 200' || note "OPTIONS not 200"
if echo "$hdr" | grep -qi '^DAV:'; then
	echo "  Dav: $(echo "$hdr" | awk 'tolower($1)=="dav:"{print $2}' | tr -d "\r")"
else
	note "no DAV header on OPTIONS"
fi

echo "== PUT stores a body and GET reads it back byte for byte"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$maxtime" -T "$payload" "$base/test.bin")
echo "  PUT $code"; [ "$code" = 201 ] || note "PUT not 201 ($code)"
curl -s -o "$WORK/got.bin" --max-time "$maxtime" "$base/test.bin"
if cmp -s "$WORK/got.bin" "$payload"; then echo "  GET byte-exact ($(wc -c < "$WORK/got.bin" | tr -d ' ') bytes)"; else note "GET body does not match PUT"; fi

echo "== PROPFIND lists the collection"
pf=$(curl -s -w '\n%{http_code}' --max-time "$maxtime" -X PROPFIND -H 'Depth: 1' "$base/")
code=$(printf '%s' "$pf" | tail -1)
echo "  PROPFIND $code"; [ "$code" = 207 ] || note "PROPFIND not 207 ($code)"
printf '%s' "$pf" | grep -q 'test.bin' || note "PROPFIND did not list test.bin"
printf '%s' "$pf" | grep -qi 'multistatus' || note "PROPFIND body is not a multistatus"

echo "== MKCOL creates a collection"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$maxtime" -X MKCOL "$base/sub/")
echo "  MKCOL $code"; [ "$code" = 201 ] || note "MKCOL not 201 ($code)"

echo "== LOCK, double LOCK, UNLOCK, relock"
h=$(curl -s -D - -o /dev/null --max-time "$maxtime" -X LOCK -H 'Timeout: Second-60' --data "$lockbody" "$base/test.bin")
echo "$h" | grep -qiE '^HTTP/[0-9.]+ 200' || note "LOCK not 200"
tok=$(printf '%s' "$h" | awk 'tolower($1)=="lock-token:"{print $2}' | tr -d "\r")
[ -n "$tok" ] || note "LOCK returned no Lock-Token"
echo "  locked, token $tok"
dbl=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$maxtime" -X LOCK -H 'Timeout: Second-60' --data "$lockbody" "$base/test.bin")
echo "  double LOCK $dbl"; [ "$dbl" = 423 ] || note "a second LOCK should be 423 ($dbl)"
unl=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$maxtime" -X UNLOCK -H "Lock-Token: $tok" "$base/test.bin")
echo "  UNLOCK $unl"; [ "$unl" = 204 ] || note "UNLOCK not 204 ($unl)"
h=$(curl -s -D - -o /dev/null --max-time "$maxtime" -X LOCK -H 'Timeout: Second-60' --data "$lockbody" "$base/test.bin")
rel=$(printf '%s' "$h" | awk 'NR==1{print $2}')
echo "  relock $rel"; [ "$rel" = 200 ] || note "relock not 200 ($rel)"
tok2=$(printf '%s' "$h" | awk 'tolower($1)=="lock-token:"{print $2}' | tr -d "\r")
curl -s -o /dev/null -X UNLOCK -H "Lock-Token: $tok2" "$base/test.bin"

echo "== DELETE removes the resource"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$maxtime" -X DELETE "$base/test.bin")
echo "  DELETE $code"; [ "$code" = 204 ] || note "DELETE not 204 ($code)"

echo "== error log"
if grep -qE '\[(alert|emerg|crit)\]' "$WORK/logs/error.log"; then
	note "alert/emerg/crit in the error log"
	grep -E '\[(alert|emerg|crit)\]' "$WORK/logs/error.log" | head -3 >&2
else
	echo "  clean"
fi

if [ -n "$VG" ]; then
	echo "== valgrind"
	stop
	ngxpid=
	trap - EXIT INT TERM
	errs=$(sed -n 's/.*ERROR SUMMARY: \([0-9][0-9]*\) errors.*/\1/p' "$vglog" | tail -1)
	defl=$(sed -n 's/.*definitely lost: \([0-9,]*\) bytes.*/\1/p' "$vglog" | tr -d , | tail -1)
	indl=$(sed -n 's/.*indirectly lost: \([0-9,]*\) bytes.*/\1/p' "$vglog" | tr -d , | tail -1)
	if [ "${errs:-0}" != 0 ] || [ "${defl:-0}" != 0 ] || [ "${indl:-0}" != 0 ]; then
		note "valgrind: ${errs:-?} errors, definitely lost ${defl:-?}, indirectly lost ${indl:-?}"
		grep -niE "Invalid read|Invalid write|uninitialised|Mismatched free" "$vglog" >&2
	else
		echo "  clean (errors $errs, suppressed shown in log)"
	fi
fi

[ "$fail" -eq 0 ] || { echo "ci/dav_ext.sh: failed" >&2; exit 1; }
echo "ci/dav_ext.sh: ok"
