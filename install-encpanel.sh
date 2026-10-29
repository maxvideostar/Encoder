#!/bin/bash
# =====================================================================
#  EncPanel - panou web HTTPS pentru encoderele ffmpeg (S3 netstreaming)
#  Instalare / actualizare:   bash install-encpanel.sh
#  Neinteractiv:  DOMAIN=s3.netstreaming.eu PORT=8443 PANEL_USER=admin PANEL_PASS='...' bash install-encpanel.sh
# =====================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Rulează ca root (sudo bash $0)"; exit 1; }

APP=/opt/encpanel; ETC=/etc/encpanel; CONF=$ETC/config.json
G='\e[32m'; Y='\e[33m'; R='\e[31m'; B='\e[1m'; N='\e[0m'
say(){ echo -e "${G}==>${N} $*"; }; warn(){ echo -e "${Y}[!]${N} $*"; }; die(){ echo -e "${R}[X]${N} $*"; exit 1; }
ask(){ local v; if [ -r /dev/tty ]; then read -rp "$1" v </dev/tty || true; else v=""; fi; echo "$v"; }
asks(){ local v; if [ -r /dev/tty ]; then read -rsp "$1" v </dev/tty || true; echo >&2; else v=""; fi; echo "$v"; }

# ---------- python
command -v python3 >/dev/null || { apt-get update -qq; apt-get install -y -qq python3; }
python3 -c 'import sys; sys.exit(0 if sys.version_info>=(3,6) else 1)' || die "Necesită Python >= 3.6 (Ubuntu 18.04+)"

# ---------- config existent?
OLD=0; [ -s "$CONF" ] && OLD=1
cfg(){ python3 -c "import json;print(json.load(open('$CONF')).get('$1',''))" 2>/dev/null || true; }

DEF_DOMAIN=$( [ $OLD = 1 ] && cfg domain || true )
if [ -z "$DEF_DOMAIN" ]; then DEF_DOMAIN=$(hostname -f 2>/dev/null || hostname); [[ "$DEF_DOMAIN" == *.*.* ]] || DEF_DOMAIN=s3.netstreaming.eu; fi
DEF_PORT=$( [ $OLD = 1 ] && cfg port || true ); DEF_PORT=${DEF_PORT:-8443}

echo -e "${B}EncPanel — panou encodere${N}"
[ -n "${DOMAIN:-}" ] || DOMAIN=$(ask "Domeniu pentru panou [$DEF_DOMAIN]: "); DOMAIN=${DOMAIN:-$DEF_DOMAIN}
[ -n "${PORT:-}" ]   || PORT=$(ask "Port HTTPS (8443 merge și prin Cloudflare) [$DEF_PORT]: "); PORT=${PORT:-$DEF_PORT}
[[ "$PORT" =~ ^[0-9]+$ ]] || die "Port invalid"

KEEP=0
if [ $OLD = 1 ] && [ -z "${PANEL_USER:-}" ]; then
  PANEL_USER=$(ask "Utilizator (Enter = păstrez contul actual '$(cfg user)'): ")
  [ -z "$PANEL_USER" ] && KEEP=1
fi
if [ $KEEP = 0 ]; then
  [ -n "${PANEL_USER:-}" ] || PANEL_USER=$(ask "Utilizator [admin]: "); PANEL_USER=${PANEL_USER:-admin}
  while [ -z "${PANEL_PASS:-}" ]; do
    P1=$(asks "Parolă (min 8 caractere): "); P2=$(asks "Repetă parola: ")
    if [ "$P1" != "$P2" ]; then warn "Nu coincid."; elif [ ${#P1} -lt 8 ]; then warn "Prea scurtă."; else PANEL_PASS=$P1; fi
  done
fi

# ---------- port liber?
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT$" && ! systemctl is-active --quiet encpanel 2>/dev/null; then
  die "Portul $PORT e ocupat de alt program. Rulează din nou cu alt port: PORT=9443 bash $0"
fi

# ---------- dependențe
say "Instalez dependențele..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq openssl ca-certificates curl >/dev/null || true
pyok(){ python3 -c 'import flask, werkzeug, gunicorn.app.wsgiapp' 2>/dev/null; }
pyok || apt-get install -y -qq python3-flask >/dev/null 2>&1 || true
pyok || apt-get install -y -qq python3-gunicorn >/dev/null 2>&1 || apt-get install -y -qq gunicorn3 >/dev/null 2>&1 || apt-get install -y -qq gunicorn >/dev/null 2>&1 || true
if ! pyok; then
  apt-get install -y -qq python3-pip >/dev/null 2>&1 || true
  pip3 install -q flask gunicorn 2>/dev/null || pip3 install -q --break-system-packages flask gunicorn
fi
pyok || die "Nu am putut instala flask/gunicorn pentru python3"

mkdir -p $APP $ETC /var/lib/encpanel/backups /var/log/encpanel
chmod 700 $ETC /var/lib/encpanel

# ---------- certificat HTTPS
CERT=""; KEY=""
LE=/etc/letsencrypt/live/$DOMAIN
NGX=$(command -v nginx || ls /usr/local/nginx/sbin/nginx 2>/dev/null || true)
get_le(){ command -v certbot >/dev/null || apt-get install -y -qq certbot >/dev/null 2>&1 || return 1; certbot certonly --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring "$@" -d "$DOMAIN"; }

PUBIP=$(curl -4 -s --max-time 5 https://api.ipify.org || true)
DNSIP=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)
[ -n "$DNSIP" ] || warn "$DOMAIN nu se rezolvă încă în DNS. Creează în Cloudflare un record A: $DOMAIN -> ${PUBIP:-IP-ul serverului}"
[ -n "$DNSIP" ] && [ -n "$PUBIP" ] && [ "$DNSIP" != "$PUBIP" ] && warn "$DOMAIN -> $DNSIP (serverul are $PUBIP). E normal doar dacă e proxied prin Cloudflare."

if [ -s "$LE/fullchain.pem" ]; then
  say "Folosesc certificatul Let's Encrypt existent pentru $DOMAIN"
else
  P80=$(ss -ltnp 2>/dev/null | awk '$4 ~ /[:.]80$/' || true)
  if [ -z "$P80" ]; then
    say "Port 80 liber → cer certificat Let's Encrypt (standalone)"
    command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active && ufw allow 80/tcp >/dev/null || true
    get_le --standalone || warn "Let's Encrypt a eșuat (DNS / port 80 închis?)"
  elif echo "$P80" | grep -q nginx && [ -n "$NGX" ]; then
    INC=$($NGX -T 2>/dev/null | grep -oE '^\s*include\s+[^;]*(conf\.d|sites-enabled|vhosts?)[^;]*\*[^;]*;' | head -1 | sed -E 's/^\s*include\s+//; s/;$//' || true)
    if [ -n "$INC" ] && ! $NGX -T 2>/dev/null | grep -qE "server_name[^;]*[[:space:]]$DOMAIN[ ;]"; then
      INCDIR=$(dirname "$INC"); EXT=$(basename "$INC" | sed 's/^\*//')
      ANS=$(ask "nginx ocupă portul 80. Adaug un mic server block pentru validare și fac UN reload nginx? [Y/n]: ")
      if [[ ! "$ANS" =~ ^[nN] ]]; then
        mkdir -p /var/www/encpanel-acme
        printf 'server {\n  listen 80;\n  server_name %s;\n  location ^~ /.well-known/acme-challenge/ { root /var/www/encpanel-acme; }\n  location / { return 404; }\n}\n' "$DOMAIN" > "$INCDIR/encpanel-acme$EXT"
        if $NGX -t >/dev/null 2>&1; then
          $NGX -s reload; sleep 2
          get_le --webroot -w /var/www/encpanel-acme || warn "Let's Encrypt (webroot) a eșuat"
        else
          rm -f "$INCDIR/encpanel-acme$EXT"; warn "nginx -t a eșuat cu blocul nou, l-am scos"
        fi
      fi
    else
      warn "Nu pot valida prin nginx automat (fără include conf.d/sites-enabled sau domeniul e deja definit)."
    fi
  else
    warn "Portul 80 e ocupat de alt program: $(echo "$P80" | awk '{print $NF}' | head -1)"
  fi
fi

if [ -s "$LE/fullchain.pem" ]; then
  CERT=$LE/fullchain.pem; KEY=$LE/privkey.pem
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  printf '#!/bin/sh\nsystemctl restart encpanel 2>/dev/null || true\n' > /etc/letsencrypt/renewal-hooks/deploy/encpanel.sh
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/encpanel.sh
  CTYPE="Let's Encrypt (reînnoire automată)"
else
  CERT=$ETC/selfsigned.crt; KEY=$ETC/selfsigned.key
  if [ ! -s "$CERT" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" \
      -keyout "$KEY" -out "$CERT" >/dev/null 2>&1 || \
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$DOMAIN" -keyout "$KEY" -out "$CERT" >/dev/null 2>&1
    chmod 600 "$KEY"
  fi
  CTYPE="self-signed (browserul va avertiza; cu Cloudflare proxy + SSL 'Full' dispare avertismentul)"
fi

# ---------- config
say "Scriu configurarea..."
export CONF DOMAIN PORT CERT KEY KEEP PANEL_USER PANEL_PASS="${PANEL_PASS:-}"
python3 - <<'PYEOF'
import json, os, secrets
from werkzeug.security import generate_password_hash
p = os.environ['CONF']
c = {}
if os.path.exists(p):
    try: c = json.load(open(p))
    except Exception: c = {}
c.update(domain=os.environ['DOMAIN'], port=int(os.environ['PORT']), cert=os.environ['CERT'], key=os.environ['KEY'])
c.setdefault('secret', secrets.token_hex(32))
c.setdefault('pwv', 1)
if os.environ['KEEP'] != '1' or 'hash' not in c:
    c['user'] = os.environ['PANEL_USER']
    c['hash'] = generate_password_hash(os.environ['PANEL_PASS'], method='pbkdf2:sha256')
    c['pwv'] = c.get('pwv', 1) + 1
json.dump(c, open(p + '.tmp', 'w'), indent=2)
os.chmod(p + '.tmp', 0o600); os.replace(p + '.tmp', p)
PYEOF

# ---------- aplicația
say "Instalez aplicația în $APP"
cat > $APP/run.py <<'PYEOF'
import json, sys
c = json.load(open('/etc/encpanel/config.json'))
sys.argv = ['gunicorn', '--chdir', '/opt/encpanel', '-w', '1', '--threads', '8', '--timeout', '90',
            '-b', '0.0.0.0:%d' % c['port'], '--certfile', c['cert'], '--keyfile', c['key'], 'app:app']
from gunicorn.app.wsgiapp import run
run()
PYEOF
cat > $APP/app.py <<'PYEOF_ENCPANEL_APP'
#!/usr/bin/env python3
# EncPanel - panou web pentru encoderele ffmpeg (netstreaming.eu / S3)
import os, re, json, time, signal, subprocess, secrets, threading, ipaddress, datetime, socket, shutil
from flask import Flask, request, session, redirect, jsonify, Response
from werkzeug.security import check_password_hash, generate_password_hash

CONF = os.environ.get('ENCPANEL_CONF', '/etc/encpanel/config.json')
DATA = os.environ.get('ENCPANEL_DATA', '/var/lib/encpanel')
LOGD = os.environ.get('ENCPANEL_LOGS', '/var/log/encpanel')
for _d in (DATA, LOGD, DATA + '/backups'):
    os.makedirs(_d, exist_ok=True)

DEF_DIRS = ['/root', '/opt', '/usr/local/bin', '/home', '/srv', '/etc/encoders', '/etc/ffmpeg']
CLK = os.sysconf('SC_CLK_TCK')
PAGE = os.sysconf('SC_PAGE_SIZE')
HOST = socket.gethostname()
SELF_UNIT = 'encpanel.service'


def _btime():
    with open('/proc/stat') as f:
        for l in f:
            if l.startswith('btime'):
                return int(l.split()[1])
    return 0


BOOT = _btime()
CLOCK = threading.Lock()


def load_conf():
    with open(CONF) as f:
        c = json.load(f)
    c.setdefault('script_dirs', DEF_DIRS)
    c.setdefault('include_units', [])
    c.setdefault('exclude_units', [])
    c.setdefault('exclude_scripts', [])
    c.setdefault('pwv', 1)
    return c


def save_conf(c):
    tmp = CONF + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(c, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONF)


CFG = load_conf()
app = Flask(__name__)
app.secret_key = CFG['secret']
app.config.update(SESSION_COOKIE_SECURE=True, SESSION_COOKIE_HTTPONLY=True,
                  SESSION_COOKIE_SAMESITE='Strict', SESSION_COOKIE_NAME='encpanel',
                  PERMANENT_SESSION_LIFETIME=datetime.timedelta(hours=12),
                  MAX_CONTENT_LENGTH=2 * 1024 * 1024)


def sh(cmd, timeout=20):
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=timeout)
        return r.returncode, r.stdout
    except Exception as e:
        return 1, str(e)


# ---------------------------------------------------------------- securitate
CF_NETS = [ipaddress.ip_network(n) for n in (
    '173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 '
    '190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 '
    '104.24.0.0/14 172.64.0.0/13 131.0.72.0/22 2400:cb00::/32 2606:4700::/32 2803:f800::/32 '
    '2405:b500::/32 2405:8100::/32 2a06:98c0::/29 2c0f:f248::/32').split()]


def client_ip():
    ra = request.remote_addr or '?'
    try:
        a = ipaddress.ip_address(ra)
        if any(a in n for n in CF_NETS):
            return request.headers.get('CF-Connecting-IP', ra)
    except ValueError:
        pass
    return ra


FAILS = {}  # ip -> [count, first_ts, locked_until]
MAXFAIL, WINDOW, LOCKT = 5, 900, 900


def audit(msg):
    u = session.get('u', '-')
    line = '%s %s %s %s\n' % (datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'), u, client_ip(), msg)
    try:
        with open(LOGD + '/audit.log', 'a') as f:
            f.write(line)
    except OSError:
        pass


def logged_in():
    return session.get('u') == CFG['user'] and session.get('pwv') == CFG['pwv']


@app.after_request
def sec_headers(r):
    r.headers['Strict-Transport-Security'] = 'max-age=31536000'
    r.headers['X-Frame-Options'] = 'DENY'
    r.headers['X-Content-Type-Options'] = 'nosniff'
    r.headers['Referrer-Policy'] = 'no-referrer'
    r.headers['Content-Security-Policy'] = "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:"
    r.headers['Cache-Control'] = 'no-store'
    return r


@app.before_request
def guard():
    p = request.path
    if p in ('/login', '/favicon.ico'):
        return
    if not logged_in():
        session.clear()
        if p.startswith('/api/'):
            return jsonify(error='auth'), 401
        return redirect('/login')
    session.permanent = True
    if request.method == 'POST' and request.headers.get('X-CSRF') != session.get('csrf'):
        return jsonify(error='csrf'), 403


@app.route('/login', methods=['GET', 'POST'])
def login():
    err = ''
    ip = client_ip()
    now = time.time()
    st = FAILS.get(ip)
    if request.method == 'POST':
        if st and st[2] > now:
            err = 'Prea multe încercări. Reîncearcă în %d min.' % (int(st[2] - now) // 60 + 1)
        elif request.form.get('csrf') != session.get('lcsrf'):
            err = 'Sesiune expirată, reîncearcă.'
        else:
            u = request.form.get('u', '')
            p = request.form.get('p', '')
            if secrets.compare_digest(u, CFG['user']) and check_password_hash(CFG['hash'], p):
                FAILS.pop(ip, None)
                session.clear()
                session.update(u=u, pwv=CFG['pwv'], csrf=secrets.token_hex(16))
                session.permanent = True
                audit('login ok')
                return redirect('/')
            time.sleep(1)
            if not st or now - st[1] > WINDOW:
                st = [0, now, 0]
            st[0] += 1
            if st[0] >= MAXFAIL:
                st[2] = now + LOCKT
            FAILS[ip] = st
            audit('login FAIL user=%r' % u[:40])
            err = 'Utilizator sau parolă greșită.'
    session['lcsrf'] = secrets.token_hex(16)
    html = LOGIN_HTML.replace('__CSRF__', session['lcsrf']).replace('__ERR__', err).replace('__HOST__', HOST)
    return Response(html, mimetype='text/html')


@app.route('/logout', methods=['POST'])
def logout():
    audit('logout')
    session.clear()
    return jsonify(ok=True)


# ---------------------------------------------------------------- procese
def read_procs():
    res = {}
    for p in os.listdir('/proc'):
        if not p.isdigit():
            continue
        try:
            with open('/proc/%s/stat' % p) as f:
                st = f.read()
            rp = st.rfind(')')
            comm = st[st.find('(') + 1:rp]
            fl = st[rp + 2:].split()
            with open('/proc/%s/cmdline' % p, 'rb') as f:
                argv = [a.decode('utf-8', 'replace') for a in f.read().split(b'\0') if a]
            res[int(p)] = dict(pid=int(p), ppid=int(fl[1]), comm=comm, argv=argv,
                               ticks=int(fl[11]) + int(fl[12]),
                               start=BOOT + int(fl[19]) / CLK, rss=int(fl[21]) * PAGE)
        except (OSError, IndexError, ValueError):
            continue
    return res


def proc_unit(pid):
    try:
        with open('/proc/%d/cgroup' % pid) as f:
            m = re.findall(r'/([^/\n]+\.service)', f.read())
            return m[-1] if m else None
    except OSError:
        return None


def is_ffmpeg(p):
    return p['comm'] == 'ffmpeg' or (p['argv'] and os.path.basename(p['argv'][0]).startswith('ffmpeg'))


def ff_summary(p):
    a = p['argv']
    ins = [a[i + 1] for i, x in enumerate(a[:-1]) if x == '-i']
    out = ''
    for x in reversed(a[1:]):
        if not x.startswith('-'):
            out = x
            break
    vc = ''
    for k in ('-c:v', '-vcodec', '-codec:v'):
        if k in a[:-1]:
            vc = a[a.index(k) + 1]
    return ins, out, vc


SAMPLE = {'cpu': {}, 'sys': {}, 'ts': 0}


def _cpu_total():
    with open('/proc/stat') as f:
        v = [int(x) for x in f.readline().split()[1:]]
    return sum(v), v[3] + (v[4] if len(v) > 4 else 0)


def _net():
    rx = tx = 0
    try:
        with open('/proc/net/dev') as f:
            for l in f.readlines()[2:]:
                n, d = l.split(':', 1)
                n = n.strip()
                if n == 'lo' or n.startswith(('docker', 'veth', 'br-', 'virbr')):
                    continue
                d = d.split()
                rx += int(d[0])
                tx += int(d[8])
    except OSError:
        pass
    return rx, tx


def _gpu():
    if not shutil.which('nvidia-smi'):
        return None
    rc, o = sh(['nvidia-smi', '--query-gpu=name,utilization.gpu,utilization.encoder,memory.used,memory.total,temperature.gpu',
                '--format=csv,noheader,nounits'], 5)
    if rc:
        return None
    g = []
    for l in o.strip().splitlines():
        x = [s.strip() for s in l.split(',')]
        if len(x) >= 6:
            g.append(dict(name=x[0], util=x[1], enc=x[2], mem=x[3], memt=x[4], temp=x[5]))
    return g


def sampler():
    prev_p, prev_t, prev_cpu, prev_net = {}, time.time(), _cpu_total(), _net()
    n = 0
    while True:
        time.sleep(3)
        try:
            now = time.time()
            dt = max(now - prev_t, 0.1)
            procs = read_procs()
            cpu = {}
            for pid, p in procs.items():
                if pid in prev_p and prev_p[pid][1] == p['start']:
                    cpu[pid] = round((p['ticks'] - prev_p[pid][0]) / CLK / dt * 100, 1)
            prev_p = {pid: (p['ticks'], p['start']) for pid, p in procs.items()}
            tot, idle = _cpu_total()
            dtot, didle = tot - prev_cpu[0], idle - prev_cpu[1]
            prev_cpu = (tot, idle)
            rx, tx = _net()
            nr, nt = (rx - prev_net[0]) / dt * 8, (tx - prev_net[1]) / dt * 8
            prev_net = (rx, tx)
            mem = {}
            with open('/proc/meminfo') as f:
                for l in f:
                    k, v = l.split(':')
                    mem[k] = int(v.split()[0]) * 1024
            du = shutil.disk_usage('/')
            temp = None
            for z in sorted(os.listdir('/sys/class/thermal')) if os.path.isdir('/sys/class/thermal') else []:
                try:
                    with open('/sys/class/thermal/%s/temp' % z) as f:
                        t = int(f.read()) / 1000
                    temp = max(temp or 0, t)
                except (OSError, ValueError):
                    pass
            if n % 3 == 0:
                SAMPLE['gpu'] = _gpu()
            n += 1
            with open('/proc/uptime') as f:
                upt = float(f.read().split()[0])
            SAMPLE['cpu'] = cpu
            SAMPLE['sys'] = dict(
                cpu=round(100 * (1 - didle / dtot), 1) if dtot else 0, ncpu=os.cpu_count(),
                load=os.getloadavg(), mem=mem.get('MemTotal', 0) - mem.get('MemAvailable', 0),
                memt=mem.get('MemTotal', 0), disk=du.used, diskt=du.total, rx=nr, tx=nt,
                temp=temp, uptime=upt, host=HOST, gpu=SAMPLE.get('gpu'))
            SAMPLE['ts'] = now
        except Exception:
            pass
        prev_t = time.time()


threading.Thread(target=sampler, daemon=True).start()

# ---------------------------------------------------------------- descoperire
SKIP_DIRS = {'proc', 'sys', 'dev', 'node_modules', '.git', '.cache', 'venv', '.venv', 'snap', '__pycache__',
             'site-packages', 'dist-packages', 'encpanel', '.npm', '.local', 'go', '.cargo', '.rustup'}
NOT_ENC = re.compile(r'\b(pgrep|pkill|killall|pidof|grep|echo|printf|ps|which|command|apt|apt-get|systemctl|journalctl)\b')
FF_TOK = re.compile(r'(?<![\w.-])ffmpeg(?![\w.-])')


def is_encoder_text(txt):
    if '\0' in txt[:2000] or '-i' not in txt:
        return False
    for l in txt.splitlines():
        l = l.split('#', 1)[0] if not l.lstrip().startswith('#!') else ''
        if FF_TOK.search(l) and not NOT_ENC.search(l):
            return True
    return False


def read_text(path, limit=512 * 1024):
    try:
        if os.path.getsize(path) > limit:
            return None
        with open(path, 'r', errors='replace') as f:
            return f.read()
    except OSError:
        return None


def parse_show(out):
    blocks, cur = [], {}
    for l in out.split('\n'):
        if not l.strip():
            if cur:
                blocks.append(cur)
                cur = {}
            continue
        k, _, v = l.partition('=')
        cur[k] = cur.get(k, '') + ((' ;; ' + v) if k in cur else v)
    if cur:
        blocks.append(cur)
    return blocks


SHOW_PROPS = ['Id', 'Description', 'ExecStart', 'FragmentPath', 'EnvironmentFiles', 'ActiveState', 'SubState',
              'UnitFileState', 'MainPID', 'ActiveEnterTimestampMonotonic', 'NRestarts', 'WorkingDirectory', 'LoadState']

DISC = {'ts': 0, 'units': [], 'scripts': []}
DLOCK = threading.Lock()


def script_shell(path):
    try:
        with open(path, 'rb') as f:
            first = f.readline(200).decode('utf-8', 'replace')
    except OSError:
        return ['/bin/bash', path]
    if first.startswith('#!') and not re.search(r'\b(ba|da|z)?sh\b', first) and os.access(path, os.X_OK):
        return [path]
    return ['/bin/bash', path]


def discover(force=False):
    with DLOCK:
        if not force and time.time() - DISC['ts'] < 30:
            return DISC
        cfg = CFG
        names = set()
        if shutil.which('systemctl'):
            _, o = sh(['systemctl', 'list-units', '--type=service', '--all', '--no-legend', '--plain'])
            for l in o.splitlines():
                t = l.split()
                if t and t[0].endswith('.service'):
                    names.add(t[0])
            _, o = sh(['systemctl', 'list-unit-files', '--type=service', '--no-legend'])
            for l in o.splitlines():
                t = l.split()
                if t and t[0].endswith('.service') and '@.' not in t[0]:
                    names.add(t[0])
        names.update(u if u.endswith('.service') else u + '.service' for u in cfg['include_units'])
        names.discard(SELF_UNIT)
        units, used_scripts = [], set()
        names = sorted(names)
        for i in range(0, len(names), 150):
            chunk = names[i:i + 150]
            _, o = sh(['systemctl', 'show', '-p', ','.join(SHOW_PROPS)] + chunk, 30)
            for b in parse_show(o):
                uid = b.get('Id', '')
                if not uid or b.get('LoadState') == 'not-found':
                    continue
                short = uid[:-8]
                if uid in cfg['exclude_units'] or short in cfg['exclude_units']:
                    continue
                execs = re.findall(r'argv\[\]=(.*?) ; ignore_errors', b.get('ExecStart', ''))
                exec_s = ' && '.join(execs)
                wd = b.get('WorkingDirectory', '') or '/'
                forced = uid in cfg['include_units'] or short in cfg['include_units']
                hit = bool(FF_TOK.search(exec_s)) and not NOT_ENC.search(exec_s)
                script = None
                for tok in exec_s.split():
                    tok = tok.strip('\'"')
                    if not tok or tok.startswith('-') or '=' in tok:
                        continue
                    pth = tok if tok.startswith('/') else os.path.join(wd if wd.startswith('/') else '/', tok)
                    if os.path.isfile(pth) and not pth.startswith(('/usr/bin/', '/bin/', '/usr/sbin/', '/sbin/')):
                        txt = read_text(pth)
                        if txt and is_encoder_text(txt):
                            script, hit = os.path.realpath(pth), True
                            break
                if not (hit or forced):
                    continue
                envs = [e.split(' (')[0] for e in re.findall(r'(/[^ ;]+ \(ignore_errors=\w+\))', b.get('EnvironmentFiles', ''))]
                if script:
                    used_scripts.add(script)
                frag = b.get('FragmentPath', '')
                mono = int(b.get('ActiveEnterTimestampMonotonic', '0') or 0)
                units.append(dict(kind='unit', id=uid, name=short, desc=b.get('Description', ''),
                                  active=b.get('ActiveState', ''), sub=b.get('SubState', ''),
                                  enabled=b.get('UnitFileState', ''), mainpid=int(b.get('MainPID', '0') or 0),
                                  since_mono=mono, restarts=b.get('NRestarts', ''), exec=exec_s[:600],
                                  script=script, envs=envs, unitfile=frag))
        scripts = []
        seen = 0
        for root in cfg['script_dirs']:
            if not os.path.isdir(root):
                continue
            base_depth = root.rstrip('/').count('/')
            for dp, dns, fns in os.walk(root):
                dns[:] = [d for d in dns if d not in SKIP_DIRS and not d.startswith('.')] if dp.count('/') - base_depth < 3 else []
                for fn in fns:
                    seen += 1
                    if seen > 20000:
                        break
                    pth = os.path.join(dp, fn)
                    if not (fn.endswith('.sh') or '.' not in fn) or os.path.islink(pth):
                        continue
                    rp = os.path.realpath(pth)
                    if rp in used_scripts or rp in cfg['exclude_scripts'] or any(s['path'] == rp for s in scripts):
                        continue
                    txt = read_text(rp, 256 * 1024)
                    if not txt or (not fn.endswith('.sh') and not txt.startswith('#!')):
                        continue
                    if is_encoder_text(txt):
                        scripts.append(dict(kind='script', id=rp, path=rp, name=fn))
        DISC.update(ts=time.time(), units=units, scripts=scripts)
        return DISC


def script_pids(path, procs):
    out = []
    for pid, p in procs.items():
        a = p['argv']
        if not a or p['comm'] == 'ffmpeg':
            continue
        try:
            cwd = os.readlink('/proc/%d/cwd' % pid)
        except OSError:
            cwd = '/'
        for tok in a[:3]:
            if tok.startswith('-'):
                continue
            full = tok if tok.startswith('/') else os.path.join(cwd, tok)
            if os.path.realpath(full) == path:
                out.append(pid)
                break
    s = set(out)
    return [p for p in out if procs[p]['ppid'] not in s]


def descendants(root, procs):
    kids = {}
    for pid, p in procs.items():
        kids.setdefault(p['ppid'], []).append(pid)
    res, st = [], [root]
    while st:
        x = st.pop()
        for k in kids.get(x, []):
            res.append(k)
            st.append(k)
    return res


def mono_now():
    return time.clock_gettime(time.CLOCK_MONOTONIC) if hasattr(time, 'clock_gettime') else 0


def ff_item(p, cpu):
    ins, out, vc = ff_summary(p)
    return dict(pid=p['pid'], cpu=cpu.get(p['pid'], 0), rss=p['rss'], up=int(time.time() - p['start']),
                inp=ins, out=out, vc=vc, cmd=' '.join(p['argv'])[:2000])


def build_state():
    d = discover()
    procs = read_procs()
    cpu = SAMPLE['cpu']
    ffs = {pid: p for pid, p in procs.items() if is_ffmpeg(p)}
    unit_of = {pid: proc_unit(pid) for pid in ffs}
    claimed = set()
    items = []
    mn = mono_now()
    for u in d['units']:
        it = dict(u)
        it['ff'] = [ff_item(ffs[pid], cpu) for pid in ffs if unit_of[pid] == u['id']]
        claimed.update(f['pid'] for f in it['ff'])
        it['up'] = int(mn - u['since_mono'] / 1e6) if u['active'] == 'active' and u['since_mono'] else 0
        it['state'] = {'active': 'running', 'activating': 'starting', 'deactivating': 'stopping',
                       'failed': 'failed'}.get(u['active'], 'stopped')
        it['files'] = editable_files(u)
        items.append(it)
    for s in d['scripts']:
        it = dict(s)
        roots = script_pids(s['path'], procs)
        tree = set(roots)
        for r in roots:
            tree.update(descendants(r, procs))
        it['pids'] = roots
        it['ff'] = [ff_item(ffs[pid], cpu) for pid in ffs if pid in tree]
        claimed.update(f['pid'] for f in it['ff'])
        it['state'] = 'running' if roots else 'stopped'
        it['up'] = int(time.time() - min(procs[r]['start'] for r in roots)) if roots else 0
        it['files'] = editable_files(s)
        it['log'] = os.path.isfile(script_log(s['path']))
        items.append(it)
    for it in items:
        it['cpu'] = round(sum(f['cpu'] for f in it['ff']), 1)
        it['rss'] = sum(f['rss'] for f in it['ff'])
    orphans = [dict(ff_item(p, cpu), unit=unit_of[pid]) for pid, p in ffs.items() if pid not in claimed]
    return dict(items=items, orphans=orphans, sys=SAMPLE['sys'], disc_age=int(time.time() - d['ts']))


def editable_files(it):
    f = []
    if it['kind'] == 'script':
        f.append(dict(path=it['path'], label='Script', rw=True))
    else:
        if it.get('script'):
            f.append(dict(path=it['script'], label='Script', rw=True))
        for e in it.get('envs', []):
            f.append(dict(path=e, label='Env: ' + os.path.basename(e), rw=True))
        uf = it.get('unitfile') or ''
        if uf:
            f.append(dict(path=uf, label='Unit systemd', rw=uf.startswith('/etc/systemd/')))
    return f


def allowed_file(path):
    d = discover()
    for it in d['units'] + d['scripts']:
        for f in editable_files(it):
            if f['path'] == path:
                return f
    return None


def script_log(path):
    return os.path.join(LOGD, re.sub(r'[^A-Za-z0-9._-]', '_', path.strip('/')) + '.log')


def find_item(kind, iid):
    d = discover()
    for it in (d['units'] if kind == 'unit' else d['scripts']):
        if it['id'] == iid:
            return it
    return None


def kill_tree(roots, wait=6):
    procs = read_procs()
    allp = []
    for r in roots:
        allp += [r] + descendants(r, procs)
    for p in allp:
        try:
            os.kill(p, signal.SIGTERM)
        except OSError:
            pass
    t = time.time()
    while time.time() - t < wait:
        if not any(os.path.exists('/proc/%d' % p) for p in allp):
            return
        time.sleep(0.3)
    for p in allp:
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass


def start_script(path):
    lg = open(script_log(path), 'a')
    lg.write('\n===== %s pornit din panou =====\n' % datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'))
    lg.flush()
    subprocess.Popen(script_shell(path), cwd=os.path.dirname(path), stdout=lg, stderr=subprocess.STDOUT,
                     stdin=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    lg.close()


# ---------------------------------------------------------------- API
@app.route('/api/state')
def api_state():
    if request.args.get('refresh'):
        discover(True)
    return jsonify(build_state())


@app.route('/api/action', methods=['POST'])
def api_action():
    j = request.get_json(force=True, silent=True) or {}
    kind, iid, op = j.get('kind'), str(j.get('id', '')), j.get('op')
    audit('action %s %s %s' % (kind, iid, op))
    if kind == 'pid':
        try:
            pid = int(iid)
        except ValueError:
            return jsonify(error='pid invalid'), 400
        procs = read_procs()
        if pid not in procs or not is_ffmpeg(procs[pid]):
            return jsonify(error='Procesul nu mai există sau nu e ffmpeg'), 404
        threading.Thread(target=kill_tree, args=([pid],), daemon=True).start()
        return jsonify(ok=True, msg='Proces %d oprit' % pid)
    it = find_item(kind, iid)
    if not it:
        return jsonify(error='Element necunoscut'), 404
    if kind == 'unit':
        if op not in ('start', 'stop', 'restart', 'enable', 'disable'):
            return jsonify(error='op invalid'), 400
        rc, o = sh(['systemctl', op, it['id']], 60)
        discover(True)
        return (jsonify(ok=True, msg='%s: %s OK' % (it['name'], op)) if rc == 0
                else (jsonify(error=o.strip()[-600:] or 'eroare'), 500))
    # script
    path = it['path']
    procs = read_procs()
    pids = script_pids(path, procs)
    if op == 'start':
        if pids:
            return jsonify(error='Scriptul rulează deja'), 409
        start_script(path)
        return jsonify(ok=True, msg='%s pornit' % it['name'])
    if op == 'stop':
        if not pids:
            return jsonify(error='Scriptul nu rulează'), 409
        kill_tree(pids)
        return jsonify(ok=True, msg='%s oprit' % it['name'])
    if op == 'restart':
        if pids:
            kill_tree(pids)
        start_script(path)
        return jsonify(ok=True, msg='%s repornit' % it['name'])
    if op == 'mkservice':
        slug = re.sub(r'[^A-Za-z0-9_-]', '-', os.path.basename(path).rsplit('.sh', 1)[0]).strip('-') or 'encoder'
        uname = 'enc-%s.service' % slug
        upath = '/etc/systemd/system/' + uname
        if os.path.exists(upath):
            return jsonify(error='Există deja ' + uname), 409
        unit = ('[Unit]\nDescription=Encoder %s (creat din EncPanel)\nAfter=network-online.target\nWants=network-online.target\n\n'
                '[Service]\nType=simple\nWorkingDirectory=%s\nExecStart=%s\nRestart=always\nRestartSec=5\n'
                'KillMode=control-group\nTimeoutStopSec=15\n\n[Install]\nWantedBy=multi-user.target\n') % (
            slug, os.path.dirname(path), ' '.join(script_shell(path)))
        if pids:
            kill_tree(pids)
        with open(upath, 'w') as f:
            f.write(unit)
        sh(['systemctl', 'daemon-reload'])
        rc, o = sh(['systemctl', 'enable', '--now', uname], 60)
        discover(True)
        if rc:
            return jsonify(error=o[-600:]), 500
        return jsonify(ok=True, msg='Creat și pornit %s (pornește automat la boot)' % uname)
    return jsonify(error='op invalid'), 400


FRAME_RE = re.compile(r'frame=\s*(\d+).*?fps=\s*([\d.]+).*?time=\s*([\d:.-]+).*?bitrate=\s*([\w./]+).*?speed=\s*([\d.e+]+x|N/A)')


@app.route('/api/log')
def api_log():
    kind, iid = request.args.get('kind'), request.args.get('id', '')
    n = min(int(request.args.get('n', 300)), 3000)
    it = find_item(kind, iid)
    if not it:
        return jsonify(error='Element necunoscut'), 404
    if kind == 'unit':
        _, txt = sh(['journalctl', '-u', it['id'], '-n', str(n), '--no-pager', '-o', 'short-iso'], 30)
    else:
        p = script_log(it['path'])
        txt = ''
        if os.path.isfile(p):
            with open(p, 'rb') as f:
                f.seek(0, 2)
                sz = f.tell()
                f.seek(max(0, sz - 256 * 1024))
                txt = f.read().decode('utf-8', 'replace')
        else:
            txt = '(Niciun log încă. Logul apare după ce pornești scriptul din panou.)'
    txt = txt.replace('\r\n', '\n')
    stats = None
    for m in FRAME_RE.finditer(txt):
        stats = dict(frame=m.group(1), fps=m.group(2), time=m.group(3), bitrate=m.group(4), speed=m.group(5))
    lines = []
    for l in txt.split('\n'):
        if '\r' in l:
            l = l.split('\r')[-1] or l.split('\r')[-2]
        lines.append(l)
    return jsonify(log='\n'.join(lines[-n:]), stats=stats)


@app.route('/api/file')
def api_file_get():
    path = request.args.get('path', '')
    f = allowed_file(path)
    if not f:
        return jsonify(error='Fișier nepermis'), 403
    txt = read_text(path, 1024 * 1024)
    return jsonify(path=path, content=txt if txt is not None else '', rw=f['rw'], exists=os.path.exists(path))


@app.route('/api/file', methods=['POST'])
def api_file_save():
    j = request.get_json(force=True, silent=True) or {}
    path, content = j.get('path', ''), j.get('content', '')
    f = allowed_file(path)
    if not f or not f['rw']:
        return jsonify(error='Fișier nepermis / doar citire'), 403
    content = content.replace('\r\n', '\n')
    tmp = path + '.encpanel.tmp'
    with open(tmp, 'w') as fh:
        fh.write(content)
    if f['label'] == 'Script' and 'bash' in ' '.join(script_shell(path)):
        rc, o = sh(['bash', '-n', tmp])
        if rc:
            os.unlink(tmp)
            return jsonify(error='Eroare de sintaxă bash, nu am salvat:\n' + o.replace(tmp, path)), 400
    if os.path.exists(path):
        st = os.stat(path)
        bk = os.path.join(DATA, 'backups', re.sub(r'[^A-Za-z0-9._-]', '_', path.strip('/')) + '.' + time.strftime('%Y%m%d-%H%M%S'))
        shutil.copy2(path, bk)
        os.chmod(tmp, st.st_mode & 0o7777)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except OSError:
            pass
    os.replace(tmp, path)
    msg = 'Salvat (backup în %s/backups)' % DATA
    if f['label'] == 'Unit systemd':
        sh(['systemctl', 'daemon-reload'])
        msg += ', daemon-reload făcut'
    audit('edit %s' % path)
    discover(True)
    return jsonify(ok=True, msg=msg)


@app.route('/api/settings')
def api_settings():
    return jsonify(user=CFG['user'], script_dirs=CFG['script_dirs'], include_units=CFG['include_units'],
                   exclude_units=CFG['exclude_units'], exclude_scripts=CFG['exclude_scripts'])


@app.route('/api/settings', methods=['POST'])
def api_settings_save():
    j = request.get_json(force=True, silent=True) or {}
    clean = lambda v: [x.strip() for x in (v if isinstance(v, list) else str(v).split('\n')) if x.strip()]
    with CLOCK:
        for k in ('script_dirs', 'include_units', 'exclude_units', 'exclude_scripts'):
            if k in j:
                CFG[k] = clean(j[k])
        save_conf(CFG)
    audit('settings')
    discover(True)
    return jsonify(ok=True, msg='Setări salvate')


@app.route('/api/hide', methods=['POST'])
def api_hide():
    j = request.get_json(force=True, silent=True) or {}
    with CLOCK:
        key = 'exclude_units' if j.get('kind') == 'unit' else 'exclude_scripts'
        if j.get('id') and j['id'] not in CFG[key]:
            CFG[key].append(j['id'])
        save_conf(CFG)
    discover(True)
    return jsonify(ok=True, msg='Ascuns (poți readuce din Setări)')


@app.route('/api/password', methods=['POST'])
def api_password():
    j = request.get_json(force=True, silent=True) or {}
    if not check_password_hash(CFG['hash'], j.get('old', '')):
        return jsonify(error='Parola actuală e greșită'), 400
    new = j.get('new', '')
    if len(new) < 8:
        return jsonify(error='Parola nouă trebuie să aibă minim 8 caractere'), 400
    with CLOCK:
        CFG['hash'] = generate_password_hash(new, method='pbkdf2:sha256')
        if j.get('user', '').strip():
            CFG['user'] = j['user'].strip()
        CFG['pwv'] += 1
        save_conf(CFG)
    session['pwv'] = CFG['pwv']
    session['u'] = CFG['user']
    audit('password changed')
    return jsonify(ok=True, msg='Parola schimbată. Alte sesiuni au fost deconectate.')


@app.route('/')
def index():
    return Response(INDEX_HTML.replace('__CSRF__', session['csrf']).replace('__HOST__', HOST), mimetype='text/html')


@app.route('/favicon.ico')
def favicon():
    return Response(status=204)


# ---------------------------------------------------------------- HTML
CSS = r'''
:root{--bg:#0b0f14;--pn:#121821;--pn2:#18202b;--bd:#243041;--tx:#e6edf3;--mu:#8b98a8;--ac:#3b82f6;--ok:#22c55e;--wa:#f59e0b;--er:#ef4444}
*{box-sizing:border-box}html,body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
button,input,select,textarea{font:inherit;color:inherit}
.btn{background:var(--pn2);border:1px solid var(--bd);border-radius:8px;padding:6px 11px;cursor:pointer;white-space:nowrap}
.btn:hover{border-color:var(--ac)}.btn.p{background:var(--ac);border-color:var(--ac);color:#fff}.btn.r{color:#fca5a5}.btn.g{color:#86efac}
.btn:disabled{opacity:.5;cursor:wait}
input,textarea,select{background:#0d131a;border:1px solid var(--bd);border-radius:8px;padding:8px 10px;width:100%}
.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px}
'''

LOGIN_HTML = r'''<!doctype html><html lang="ro"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>EncPanel · __HOST__</title><style>''' + CSS + r'''
.box{max-width:360px;margin:12vh auto;background:var(--pn);border:1px solid var(--bd);border-radius:14px;padding:26px}
h1{font-size:20px;margin:0 0 4px}.mu{color:var(--mu);margin:0 0 18px}label{display:block;margin:12px 0 5px;color:var(--mu)}
.err{background:#3b1316;border:1px solid #7f1d1d;color:#fecaca;padding:8px 10px;border-radius:8px;margin-top:12px}.err:empty{display:none}
.btn{width:100%;margin-top:18px;padding:10px}</style></head><body>
<form class="box" method="post"><h1>🎬 Encodere</h1><p class="mu">__HOST__</p>
<input type="hidden" name="csrf" value="__CSRF__">
<label>Utilizator</label><input name="u" autocomplete="username" required autofocus>
<label>Parolă</label><input name="p" type="password" autocomplete="current-password" required>
<div class="err">__ERR__</div><button class="btn p">Intră</button></form></body></html>'''

INDEX_HTML = r'''<!doctype html><html lang="ro"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="csrf" content="__CSRF__"><title>EncPanel · __HOST__</title><style>''' + CSS + r'''
header{position:sticky;top:0;z-index:5;background:rgba(11,15,20,.92);backdrop-filter:blur(8px);border-bottom:1px solid var(--bd)}
.hw{max-width:1300px;margin:auto;padding:10px 16px;display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.hw h1{font-size:17px;margin:0 8px 0 0}.hw .sp{flex:1}
.chips{display:flex;gap:6px;flex-wrap:wrap}.chip{background:var(--pn);border:1px solid var(--bd);border-radius:20px;padding:3px 10px;font-size:12.5px;color:var(--mu)}
.chip b{color:var(--tx);font-weight:600}
main{max-width:1300px;margin:auto;padding:14px 16px 60px}
.bar{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px;align-items:center}.bar input{max-width:260px}
.seg{display:flex;border:1px solid var(--bd);border-radius:8px;overflow:hidden}.seg button{background:var(--pn);border:0;padding:6px 12px;cursor:pointer;color:var(--mu)}
.seg button.on{background:var(--ac);color:#fff}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(380px,1fr));gap:12px}
@media(max-width:440px){.grid{grid-template-columns:1fr}.bar input{max-width:none}}
.card{background:var(--pn);border:1px solid var(--bd);border-radius:12px;padding:12px 14px;display:flex;flex-direction:column;gap:8px}
.card.running{border-left:3px solid var(--ok)}.card.failed{border-left:3px solid var(--er)}.card.stopped{border-left:3px solid #475569}.card.starting,.card.stopping{border-left:3px solid var(--wa)}
.top{display:flex;align-items:center;gap:8px}.dot{width:10px;height:10px;border-radius:50%;flex:none;background:#475569}
.running .dot{background:var(--ok);box-shadow:0 0 8px var(--ok)}.failed .dot{background:var(--er)}.starting .dot,.stopping .dot{background:var(--wa)}
.nm{font-weight:600;font-size:15px;word-break:break-all}.tag{font-size:11px;padding:1px 7px;border-radius:10px;background:var(--pn2);color:var(--mu);border:1px solid var(--bd)}
.mu{color:var(--mu)}.meta{font-size:12.5px;color:var(--mu);display:flex;gap:12px;flex-wrap:wrap}.meta b{color:var(--tx);font-weight:500}
.ff{background:#0d131a;border:1px solid var(--bd);border-radius:8px;padding:6px 8px;font-size:12px}
.ff .io{word-break:break-all;color:#cbd5e1}.ff .io span{color:var(--mu)}
.acts{display:flex;gap:6px;flex-wrap:wrap;margin-top:2px}.acts .btn{padding:5px 10px;font-size:13px}
h2{font-size:15px;margin:26px 0 10px;color:var(--mu);font-weight:600}
.empty{color:var(--mu);padding:30px;text-align:center;border:1px dashed var(--bd);border-radius:12px}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center;z-index:20;padding:12px}
.modal.on{display:flex}.mb{background:var(--pn);border:1px solid var(--bd);border-radius:14px;width:min(1000px,100%);max-height:92vh;display:flex;flex-direction:column}
.mh{display:flex;gap:8px;align-items:center;padding:12px 14px;border-bottom:1px solid var(--bd);flex-wrap:wrap}.mh h3{margin:0;font-size:15px;flex:1;word-break:break-all}
.mc{padding:12px 14px;overflow:auto;flex:1}.mf{padding:10px 14px;border-top:1px solid var(--bd);display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap}
pre.log{margin:0;white-space:pre-wrap;word-break:break-all;font-size:12px;min-height:300px}
textarea.ed{min-height:55vh;resize:vertical;white-space:pre;tab-size:4}
.stats{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:8px}
#toast{position:fixed;bottom:16px;left:50%;transform:translateX(-50%);z-index:30;display:flex;flex-direction:column;gap:6px;align-items:center}
.t{background:#1e293b;border:1px solid var(--bd);padding:9px 14px;border-radius:10px;max-width:90vw;white-space:pre-wrap}.t.e{background:#3b1316;border-color:#7f1d1d}
label.l{display:block;margin:12px 0 5px;color:var(--mu)}.row{display:grid;grid-template-columns:1fr 1fr;gap:10px}@media(max-width:600px){.row{grid-template-columns:1fr}}
</style></head><body>
<header><div class="hw"><h1>🎬 Encodere · __HOST__</h1><div class="chips" id="sys"></div><div class="sp"></div>
<button class="btn" onclick="openSettings()">⚙ Setări</button><button class="btn" onclick="logout()">Ieșire</button></div></header>
<main>
<div class="bar"><input id="q" placeholder="Caută…" oninput="render()">
<div class="seg" id="flt"><button data-f="all" class="on">Toate</button><button data-f="running">Rulează</button><button data-f="down">Oprite / erori</button></div>
<div style="flex:1"></div><span class="mu" id="sum"></span><button class="btn" onclick="load(1)">↻ Rescanează</button></div>
<div class="grid" id="grid"></div>
<div id="orph"></div>
</main>
<div class="modal" id="mLog"><div class="mb"><div class="mh"><h3 id="lgT"></h3>
<label class="mu"><input type="checkbox" id="lgAuto" style="width:auto" checked> auto</label>
<select id="lgN" style="width:auto" onchange="loadLog()"><option>200</option><option selected>500</option><option>2000</option></select>
<button class="btn" onclick="loadLog()">↻</button><button class="btn" onclick="closeM('mLog')">✕</button></div>
<div class="mc"><div class="stats" id="lgS"></div><pre class="log mono" id="lgB"></pre></div></div></div>
<div class="modal" id="mEd"><div class="mb"><div class="mh"><h3 id="edT"></h3><select id="edF" style="width:auto;max-width:100%" onchange="loadFile()"></select>
<button class="btn" onclick="closeM('mEd')">✕</button></div>
<div class="mc"><div class="mu" id="edI" style="margin-bottom:6px"></div><textarea class="ed mono" id="edB" spellcheck="false"></textarea></div>
<div class="mf"><button class="btn" onclick="closeM('mEd')">Renunță</button><button class="btn" id="edS" onclick="saveFile(0)">💾 Salvează</button>
<button class="btn p" id="edR" onclick="saveFile(1)">💾 Salvează + Restart</button></div></div></div>
<div class="modal" id="mSet"><div class="mb" style="width:min(720px,100%)"><div class="mh"><h3>Setări</h3><button class="btn" onclick="closeM('mSet')">✕</button></div>
<div class="mc"><b>Cont</b>
<div class="row"><div><label class="l">Utilizator</label><input id="sU"></div><div><label class="l">Parola actuală</label><input id="sO" type="password" autocomplete="current-password"></div></div>
<div class="row"><div><label class="l">Parolă nouă (min 8)</label><input id="sN" type="password" autocomplete="new-password"></div><div><label class="l">Repetă parola nouă</label><input id="sN2" type="password" autocomplete="new-password"></div></div>
<div style="margin-top:10px"><button class="btn p" onclick="savePw()">Schimbă parola</button></div>
<hr style="border-color:var(--bd);margin:20px 0"><b>Detectare encodere</b>
<p class="mu" style="margin:6px 0 0">Panoul găsește automat serviciile systemd și scripturile care pornesc ffmpeg. Aici poți forța sau ascunde elemente (câte unul pe linie).</p>
<label class="l">Foldere scanate pentru scripturi</label><textarea id="sD" rows="4" class="mono"></textarea>
<label class="l">Servicii incluse forțat (ex: encoder-m9tv sau relay@astv)</label><textarea id="sI" rows="3" class="mono"></textarea>
<label class="l">Servicii ascunse</label><textarea id="sX" rows="3" class="mono"></textarea>
<label class="l">Scripturi ascunse (cale completă)</label><textarea id="sXS" rows="3" class="mono"></textarea></div>
<div class="mf"><button class="btn p" onclick="saveSet()">Salvează detectarea</button></div></div></div>
<div id="toast"></div>
<script>
const CSRF=document.querySelector('meta[name=csrf]').content;let S=null,F='all',LG=null,ED=null,lgTimer=null;
const $=id=>document.getElementById(id);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function toast(m,e){const d=document.createElement('div');d.className='t'+(e?' e':'');d.textContent=m;$('toast').appendChild(d);setTimeout(()=>d.remove(),e?8000:3500)}
async function api(u,b){const o=b===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json','X-CSRF':CSRF},body:JSON.stringify(b)};
 const r=await fetch(u,o);if(r.status===401){location.href='/login';throw 0}let j={};try{j=await r.json()}catch(e){}
 if(!r.ok||j.error){throw new Error(j.error||('HTTP '+r.status))}return j}
const hb=b=>{b=+b||0;const u=['B','KB','MB','GB','TB'];let i=0;while(b>=1024&&i<4){b/=1024;i++}return b.toFixed(i?1:0)+' '+u[i]};
const hbit=b=>{b=+b||0;return b>=1e9?(b/1e9).toFixed(2)+' Gb/s':b>=1e6?(b/1e6).toFixed(1)+' Mb/s':(b/1e3).toFixed(0)+' Kb/s'};
const hup=s=>{if(!s)return '-';const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return d?d+'z '+h+'h':h?h+'h '+m+'m':m?m+'m':s+'s'};
document.querySelectorAll('#flt button').forEach(b=>b.onclick=()=>{F=b.dataset.f;document.querySelectorAll('#flt button').forEach(x=>x.classList.toggle('on',x===b));render()});
async function load(force){try{S=await api('/api/state'+(force?'?refresh=1':''));render();if(force)toast('Rescanat')}catch(e){if(e)toast(e.message,1)}}
function sysChips(s){if(!s||!s.host)return '';let h=`<span class="chip">CPU <b>${s.cpu}%</b> /${s.ncpu}</span><span class="chip">Load <b>${s.load.map(x=>x.toFixed(2)).join(' ')}</b></span>
<span class="chip">RAM <b>${hb(s.mem)}</b>/${hb(s.memt)}</span><span class="chip">Disc <b>${Math.round(100*s.disk/s.diskt)}%</b></span>
<span class="chip">↓ <b>${hbit(s.rx)}</b> ↑ <b>${hbit(s.tx)}</b></span>`;if(s.temp)h+=`<span class="chip">🌡 <b>${s.temp.toFixed(0)}°C</b></span>`;
 (s.gpu||[]).forEach(g=>h+=`<span class="chip">GPU <b>${g.util}%</b> NVENC <b>${g.enc}%</b> ${g.mem}/${g.memt}MB ${g.temp}°C</span>`);return h}
const ST={running:'rulează',failed:'eroare',stopped:'oprit',starting:'pornește',stopping:'se oprește'};
function card(it,i){const run=it.state==='running'||it.state==='starting';const isU=it.kind==='unit';
 let m=`<span>${ST[it.state]||it.state}${it.up?' de <b>'+hup(it.up)+'</b>':''}</span>`;
 if(it.ff.length)m+=`<span>CPU <b>${it.cpu}%</b></span><span>RAM <b>${hb(it.rss)}</b></span><span>ffmpeg <b>${it.ff.length}</b></span>`;
 if(isU){m+=`<span>${it.enabled==='enabled'?'✔ boot':'✖ boot'}</span>`;if(+it.restarts)m+=`<span>restarturi <b>${it.restarts}</b></span>`}
 let ff=it.ff.map(f=>`<div class="ff mono"><div class="io"><span>in:</span> ${esc(f.inp.join(' | ')||'-')}</div><div class="io"><span>out:</span> ${esc(f.out)}</div>
 <div class="mu">pid ${f.pid} · ${f.cpu}% CPU · ${hb(f.rss)}${f.vc?' · '+esc(f.vc):''} · ${hup(f.up)}</div></div>`).join('');
 if(!ff&&run&&!isU)ff='';
 let a=`<button class="btn g" onclick="act(${i},'start')" ${run?'disabled':''}>▶ Start</button><button class="btn r" onclick="act(${i},'stop')" ${run?'':'disabled'}>■ Stop</button>
 <button class="btn" onclick="act(${i},'restart')">↻ Restart</button><button class="btn" onclick="openLog(${i})">📄 Log</button>`;
 if(it.files.length)a+=`<button class="btn" onclick="openEd(${i})">✎ Editează</button>`;
 if(isU)a+=it.enabled==='enabled'?`<button class="btn" onclick="act(${i},'disable')">Fără boot</button>`:(it.enabled==='disabled'?`<button class="btn" onclick="act(${i},'enable')">Pornire la boot</button>`:'');
 else a+=`<button class="btn" onclick="act(${i},'mkservice')" title="Creează serviciu systemd cu restart automat">⚙ Fă serviciu</button>`;
 a+=`<button class="btn" onclick="hide(${i})" title="Ascunde din panou">👁</button>`;
 const sub=isU?(it.desc&&it.desc!==it.id?esc(it.desc):''):esc(it.path);
 return `<div class="card ${it.state}"><div class="top"><span class="dot"></span><span class="nm">${esc(it.name)}</span><span class="tag">${isU?'serviciu':'script'}</span></div>
 ${sub?`<div class="mu mono" style="font-size:12px;word-break:break-all">${sub}</div>`:''}<div class="meta">${m}</div>${ff}<div class="acts">${a}</div></div>`}
function render(){if(!S)return;$('sys').innerHTML=sysChips(S.sys);const q=$('q').value.toLowerCase();
 const list=S.items.map((it,i)=>[it,i]).filter(([it])=>(F==='all'||(F==='running'?it.state==='running':it.state!=='running'))&&
  (!q||(it.name+' '+(it.desc||'')+' '+(it.path||'')+' '+it.ff.map(f=>f.inp.join(' ')+' '+f.out).join(' ')).toLowerCase().includes(q)));
 list.sort((a,b)=>a[0].name.localeCompare(b[0].name,undefined,{numeric:true}));
 const nr=S.items.filter(x=>x.state==='running').length;$('sum').textContent=`${nr} pornite / ${S.items.length} total`;
 $('grid').innerHTML=list.length?list.map(([it,i])=>card(it,i)).join(''):`<div class="empty">Niciun encoder găsit${q||F!=='all'?' pentru filtrul ales':'. Verifică Setări → foldere scanate / servicii incluse.'}</div>`;
 $('orph').innerHTML=S.orphans.length?`<h2>Alte procese ffmpeg (${S.orphans.length})</h2><div class="grid">`+S.orphans.map(f=>`<div class="card running"><div class="top"><span class="dot"></span><span class="nm">ffmpeg pid ${f.pid}</span>${f.unit?`<span class="tag">${esc(f.unit)}</span>`:''}</div>
 <div class="ff mono"><div class="io"><span>in:</span> ${esc(f.inp.join(' | '))}</div><div class="io"><span>out:</span> ${esc(f.out)}</div><div class="mu">${f.cpu}% CPU · ${hb(f.rss)} · ${hup(f.up)}</div></div>
 <details><summary class="mu">comandă completă</summary><div class="mono" style="word-break:break-all;font-size:12px">${esc(f.cmd)}</div></details>
 <div class="acts"><button class="btn r" onclick="killPid(${f.pid})">■ Oprește procesul</button></div></div>`).join('')+'</div>':''}
async function act(i,op){const it=S.items[i];
 const lbl={stop:'Opresc',restart:'Repornesc',mkservice:'Creez serviciu systemd (cu restart automat și pornire la boot) pentru',disable:'Scot de la pornirea la boot'}[op];
 if(lbl&&!confirm(`${lbl} „${it.name}”?`))return;
 document.querySelectorAll('.acts .btn').forEach(b=>b.disabled=true);
 try{const r=await api('/api/action',{kind:it.kind,id:it.id,op});toast(r.msg||'OK')}catch(e){if(e)toast(e.message,1)}
 setTimeout(()=>load(1),1200)}
async function killPid(pid){if(!confirm('Opresc procesul ffmpeg '+pid+'?'))return;try{const r=await api('/api/action',{kind:'pid',id:pid,op:'kill'});toast(r.msg)}catch(e){toast(e.message,1)}setTimeout(load,2500)}
async function hide(i){const it=S.items[i];if(!confirm(`Ascund „${it.name}” din panou?`))return;try{const r=await api('/api/hide',{kind:it.kind,id:it.id});toast(r.msg);load(1)}catch(e){toast(e.message,1)}}
function openLog(i){LG=S.items[i];$('lgT').textContent='Log · '+LG.name;$('lgB').textContent='Se încarcă…';$('lgS').innerHTML='';$('mLog').classList.add('on');loadLog(1);
 clearInterval(lgTimer);lgTimer=setInterval(()=>{if($('lgAuto').checked&&$('mLog').classList.contains('on'))loadLog()},3000)}
async function loadLog(first){if(!LG)return;const pre=$('lgB');const atBot=first||pre.parentElement.scrollTop+pre.parentElement.clientHeight>=pre.parentElement.scrollHeight-40;
 try{const r=await api(`/api/log?kind=${LG.kind}&id=${encodeURIComponent(LG.id)}&n=${$('lgN').value}`);pre.textContent=r.log||'(gol)';
  $('lgS').innerHTML=r.stats?['fps','bitrate','speed','time','frame'].map(k=>`<span class="chip">${k} <b>${esc(r.stats[k])}</b></span>`).join(''):'';
  if(atBot)pre.parentElement.scrollTop=pre.parentElement.scrollHeight}catch(e){if(e)pre.textContent=e.message}}
function closeM(id){$(id).classList.remove('on');if(id==='mLog')clearInterval(lgTimer)}
document.addEventListener('keydown',e=>{if(e.key==='Escape')['mLog','mEd','mSet'].forEach(closeM)});
function openEd(i){ED=S.items[i];$('edT').textContent='Editează · '+ED.name;$('edF').innerHTML=ED.files.map((f,k)=>`<option value="${k}">${esc(f.label)} — ${esc(f.path)}</option>`).join('');
 $('mEd').classList.add('on');loadFile()}
async function loadFile(){const f=ED.files[+$('edF').value];$('edB').value='Se încarcă…';
 try{const r=await api('/api/file?path='+encodeURIComponent(f.path));$('edB').value=r.content;$('edB').readOnly=!r.rw;
  $('edS').disabled=$('edR').disabled=!r.rw;$('edI').textContent=r.rw?(r.exists?f.path:f.path+' (nu există, va fi creat)'):'Doar citire (unit de sistem în /lib). Copiază-l în /etc/systemd/system pentru a-l edita.'}catch(e){$('edB').value=e.message}}
async function saveFile(rst){const f=ED.files[+$('edF').value];if(!confirm('Salvez '+f.path+(rst?' și repornesc encoderul':'')+'?'))return;
 try{const r=await api('/api/file',{path:f.path,content:$('edB').value});toast(r.msg);
  if(rst){const x=await api('/api/action',{kind:ED.kind,id:ED.id,op:'restart'});toast(x.msg)}closeM('mEd');setTimeout(()=>load(1),1000)}catch(e){if(e)toast(e.message,1)}}
$('edB').addEventListener('keydown',e=>{if(e.key==='Tab'){e.preventDefault();const t=e.target,s=t.selectionStart;t.setRangeText('    ',s,t.selectionEnd,'end')}
 if((e.ctrlKey||e.metaKey)&&e.key==='s'){e.preventDefault();saveFile(0)}});
async function openSettings(){try{const r=await api('/api/settings');$('sU').value=r.user;$('sD').value=r.script_dirs.join('\n');$('sI').value=r.include_units.join('\n');
 $('sX').value=r.exclude_units.join('\n');$('sXS').value=r.exclude_scripts.join('\n');['sO','sN','sN2'].forEach(x=>$(x).value='');$('mSet').classList.add('on')}catch(e){if(e)toast(e.message,1)}}
async function savePw(){if($('sN').value!==$('sN2').value)return toast('Parolele noi nu coincid',1);
 try{const r=await api('/api/password',{user:$('sU').value,old:$('sO').value,new:$('sN').value});toast(r.msg);closeM('mSet')}catch(e){if(e)toast(e.message,1)}}
async function saveSet(){try{const r=await api('/api/settings',{script_dirs:$('sD').value,include_units:$('sI').value,exclude_units:$('sX').value,exclude_scripts:$('sXS').value});
 toast(r.msg);closeM('mSet');load(1)}catch(e){if(e)toast(e.message,1)}}
async function logout(){try{await api('/logout',{})}catch(e){}location.href='/login'}
load();setInterval(()=>{if(!document.hidden)load()},5000);
</script></body></html>'''
PYEOF_ENCPANEL_APP
python3 -m py_compile $APP/app.py || die "app.py nu compilează"

cat > /etc/systemd/system/encpanel.service <<EOF
[Unit]
Description=EncPanel - panou web encodere ffmpeg
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v python3) $APP/run.py
Restart=always
RestartSec=3
# rămâne doar panoul la oprire, NU encoderele pornite din el
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# ---------- CLI
cat > /usr/local/bin/encpanel <<'EOF'
#!/bin/bash
CONF=/etc/encpanel/config.json
case "${1:-}" in
  passwd)
    read -rp "Utilizator nou (Enter = același): " U
    read -rsp "Parolă nouă: " P; echo
    [ ${#P} -ge 8 ] || { echo "Minim 8 caractere"; exit 1; }
    U="$U" P="$P" python3 - <<'PY'
import json, os
from werkzeug.security import generate_password_hash
p='/etc/encpanel/config.json'; c=json.load(open(p))
if os.environ['U'].strip(): c['user']=os.environ['U'].strip()
c['hash']=generate_password_hash(os.environ['P'], method='pbkdf2:sha256'); c['pwv']=c.get('pwv',1)+1
json.dump(c,open(p,'w'),indent=2); os.chmod(p,0o600)
print('OK, utilizator:', c['user'])
PY
    systemctl restart encpanel ;;
  status)  systemctl status encpanel --no-pager ;;
  log)     journalctl -u encpanel -f ;;
  audit)   tail -n 50 /var/log/encpanel/audit.log ;;
  url)     python3 -c "import json;c=json.load(open('$CONF'));print('https://%s:%s/'%(c['domain'],c['port']))" ;;
  restart) systemctl restart encpanel ;;
  uninstall)
    systemctl disable --now encpanel 2>/dev/null; rm -f /etc/systemd/system/encpanel.service /usr/local/bin/encpanel
    rm -rf /opt/encpanel; systemctl daemon-reload; echo "Dezinstalat (config păstrat în /etc/encpanel, backup-uri în /var/lib/encpanel)" ;;
  *) echo "encpanel passwd | status | log | audit | url | restart | uninstall" ;;
esac
EOF
chmod +x /usr/local/bin/encpanel

# ---------- firewall
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT"/tcp >/dev/null && say "ufw: deschis portul $PORT"
fi

systemctl daemon-reload
systemctl enable encpanel >/dev/null 2>&1
systemctl restart encpanel
sleep 3
if systemctl is-active --quiet encpanel && curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORT/login" | grep -q 200; then
  echo
  echo -e "${G}${B}✔ EncPanel rulează${N}"
  echo -e "   Adresă:     ${B}https://$DOMAIN:$PORT/${N}"
  echo -e "   Certificat: $CTYPE"
  echo -e "   Comenzi:    encpanel passwd | status | log | audit | url"
  echo -e "   Dacă ai firewall la provider, deschide TCP $PORT."
else
  journalctl -u encpanel -n 30 --no-pager
  die "Panoul nu a pornit, vezi logul de mai sus"
fi
