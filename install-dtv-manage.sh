#!/bin/bash
set -euo pipefail

# ============================================================
# DTV Management Dashboard セットアップスクリプト
# LXDコンテナ内で実行してください
# ポート80でHTTPサーバーを立ち上げます
# ============================================================

INSTALL_DIR="/opt/dtv-manage"
SERVICE_NAME="dtv-manage"

echo "=== DTV Management Dashboard セットアップ開始 ==="

# 依存チェック
if ! command -v python3 &> /dev/null; then
    echo "python3 をインストール中..."
    sudo apt update && sudo apt install -y python3
fi

# 注意: pm2 のシンボリックリンク (/usr/local/bin/pm2) はここでは作成・変更しない。
# 既存のリンクが壊れる事故を避けるため、PATH拡張のみで対応する (server.py 内の ENV["PATH"] を参照)。

# ディレクトリ作成
sudo mkdir -p "$INSTALL_DIR"

# konomitv-backup.sh
# (Web UI の「DTV関連バックアップ」ボタンから server.py が実行するスクリプト本体。
#  LXDコンテナ内は常に root 実行前提のため sudo は使わずシンプルにしている)
sudo tee "$INSTALL_DIR/konomitv-backup.sh" > /dev/null << 'BACKUPEOF'
#!/bin/bash
# =============================================================
# mirakc + EDCB + KonomiTV (Docker不使用版) バックアップスクリプト
# 再インストール時に必要なファイルを /opt/lxd-data/konomitv-backup/ に保存する
# 実行方法: bash konomitv-backup.sh
# (本スクリプトは dtv-manage の Web UI からも実行される。
#  常に root [LXDコンテナ内] で実行される前提のため sudo は使用しない)
# =============================================================
set -e

# rootでない場合は自動的にsudo経由で再実行する
if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

BACKUP_BASE="/opt/lxd-data/konomitv-backup"

# ------------------------------------------------------------
# DTV_DIR について:
# 以前は SUDO_USER / logname / id -un から動的に算出していたが、
# LXD コンテナ (lxc shell) では `logname` がエラーメッセージを
# 出力しつつ終了コード0で空文字を返すことがあり、
#   REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
# の `||` フォールバックが発動しないまま REAL_USER="" となって
# DTV_DIR="/dtv" という存在しないパスを見てしまう不具合があった。
# このスクリプトは常に root (lxc shell) で実行する運用のため、
# 動的判定はやめて固定する。
# ------------------------------------------------------------
DTV_DIR="/root/dtv"

if [ ! -d "$DTV_DIR" ]; then
    echo "エラー: $DTV_DIR が見つかりません。"
    echo "  KonomiTV のインストール先がこのパスと異なる場合は、"
    echo "  このスクリプトの DTV_DIR を実際のパスに書き換えてください。"
    exit 1
fi

MIRAKC_ETC="/etc/mirakc"
MIRAKC_DATA="/var/lib/mirakc/epg"

# バックアップ中に欠けていた項目を最後にまとめて表示するための配列
# (今回のように、途中の警告1行だけだと見落としてしまうため)
WARNINGS=()
warn() {
    echo "  警告: $1"
    WARNINGS+=("$1")
}

echo "=== バックアップ開始 ==="
echo "バックアップ元 (DTV_DIR): $DTV_DIR"
echo "バックアップ先: $BACKUP_BASE"

# ------------------------------------------------------------
# 1. B-CAS キー
# ------------------------------------------------------------
echo "[1/8] B-CAS キーをバックアップ中..."
mkdir -p "$BACKUP_BASE/key"
if [ -f /usr/local/etc/bcas_keys ]; then
    cp /usr/local/etc/bcas_keys "$BACKUP_BASE/key/bcas_keys"
    echo "  -> $BACKUP_BASE/key/bcas_keys"
else
    warn "/usr/local/etc/bcas_keys が見つかりません"
fi

# ------------------------------------------------------------
# 2. 復号ライブラリ (libyakisoba / libsobacas) ※ビルド成果物
# ------------------------------------------------------------
echo "[2/8] 復号ライブラリをバックアップ中..."
mkdir -p "$BACKUP_BASE/lib"

for lib in libyakisoba libsobacas; do
    for f in /usr/local/lib/${lib}.*; do
        [ -e "$f" ] && cp -a "$f" "$BACKUP_BASE/lib/" && echo "  -> $f"
    done
done

if [ -f /usr/local/lib/pkgconfig/libsobacas.pc ]; then
    mkdir -p "$BACKUP_BASE/lib/pkgconfig"
    cp /usr/local/lib/pkgconfig/libsobacas.pc "$BACKUP_BASE/lib/pkgconfig/"
    echo "  -> libsobacas.pc"
fi

mkdir -p "$BACKUP_BASE/lib/etc"
for f in /usr/local/etc/*yakisoba* /usr/local/etc/*sobacas*; do
    [ -e "$f" ] && cp -a "$f" "$BACKUP_BASE/lib/etc/" && echo "  -> $(basename "$f") (libyakisoba 設定)"
done

# ------------------------------------------------------------
# 3. recisdb ※ビルド成果物 (rustup + cargo build の代わりになる)
# ------------------------------------------------------------
echo "[3/8] recisdb をバックアップ中..."
mkdir -p "$BACKUP_BASE/recisdb"
if [ -f /usr/local/bin/recisdb ]; then
    cp /usr/local/bin/recisdb "$BACKUP_BASE/recisdb/"
    echo "  -> $BACKUP_BASE/recisdb/recisdb"
else
    warn "/usr/local/bin/recisdb が見つかりません"
fi

# ------------------------------------------------------------
# 4. mirakc バイナリ ※cargo build --release の代わりになる
# ------------------------------------------------------------
echo "[4/8] mirakc バイナリをバックアップ中..."
mkdir -p "$BACKUP_BASE/mirakc"
if [ -f /usr/local/bin/mirakc ]; then
    cp /usr/local/bin/mirakc "$BACKUP_BASE/mirakc/"
    echo "  -> $BACKUP_BASE/mirakc/mirakc"
else
    warn "/usr/local/bin/mirakc が見つかりません"
fi
# mirakc 4.x で必須の strings.yml も一緒に保存
# (mirakc-src を再クローンしなくても復元できるようにするため)
if [ -f "$MIRAKC_ETC/strings.yml" ]; then
    cp "$MIRAKC_ETC/strings.yml" "$BACKUP_BASE/mirakc/strings.yml"
    echo "  -> strings.yml"
else
    warn "$MIRAKC_ETC/strings.yml が見つかりません"
fi

# ------------------------------------------------------------
# 5. mirakc-arib バイナリ ※cmake/ninja vendor ビルドの代わりになる
#    (tsduck-arib 等の取得・ビルドを含むため、ここが最も時間のかかる
#     部分。バックアップ復元できれば最大の時間短縮になる)
# ------------------------------------------------------------
echo "[5/8] mirakc-arib バイナリをバックアップ中..."
mkdir -p "$BACKUP_BASE/mirakc-arib"
if [ -f /usr/local/bin/mirakc-arib ]; then
    cp /usr/local/bin/mirakc-arib "$BACKUP_BASE/mirakc-arib/"
    echo "  -> $BACKUP_BASE/mirakc-arib/mirakc-arib"
else
    warn "/usr/local/bin/mirakc-arib が見つかりません"
fi

# ------------------------------------------------------------
# 6. チャンネルスキャン結果 (ISDBScanner) ※チャンネルスキャンの代わりになる
# ------------------------------------------------------------
echo "[6/8] チャンネルスキャン結果をバックアップ中..."
if [ -d "$DTV_DIR/scanned" ] && [ -n "$(ls -A "$DTV_DIR/scanned" 2>/dev/null)" ]; then
    rm -rf "$BACKUP_BASE/scanned"
    cp -a "$DTV_DIR/scanned" "$BACKUP_BASE/scanned"
    echo "  -> scanned/ (mirakc/config.yml, EDCB-Wine/ 等)"
else
    warn "$DTV_DIR/scanned が見つからないか空です"
fi

# 念のため、EDCBが実際に使っている最新のチャンネル設定も別途保存
mkdir -p "$BACKUP_BASE/channel/edcb"
for f in ChSet5.txt "BonDriver_LinuxMirakc(LinuxMirakc).ChSet4.txt"; do
    if [ -f "/var/local/edcb/Setting/$f" ]; then
        cp "/var/local/edcb/Setting/$f" "$BACKUP_BASE/channel/edcb/"
        echo "  -> edcb/$f"
    else
        warn "/var/local/edcb/Setting/$f が見つかりません"
    fi
done

# ------------------------------------------------------------
# 7. mirakc EPG/サービスキャッシュ ※初回サービススキャンの代わりになる
#    (scan-services で取得した services 情報がここに永続化される)
# ------------------------------------------------------------
echo "[7/8] mirakc EPG/サービスキャッシュをバックアップ中..."
if [ -d "$MIRAKC_DATA" ] && [ -n "$(ls -A "$MIRAKC_DATA" 2>/dev/null)" ]; then
    rm -rf "$BACKUP_BASE/mirakc-epg"
    cp -a "$MIRAKC_DATA" "$BACKUP_BASE/mirakc-epg"
    echo "  -> mirakc-epg/ ($(ls "$BACKUP_BASE/mirakc-epg" | wc -l) ファイル)"
else
    warn "$MIRAKC_DATA が見つからないか空です"
fi

# ------------------------------------------------------------
# 8. EDCB EPG データ
# ------------------------------------------------------------
echo "[8/8] EDCB EPG データをバックアップ中..."
mkdir -p "$BACKUP_BASE/epg"
EPG_DIR="/var/local/edcb/Setting/EpgData"
if [ -d "$EPG_DIR" ] && [ -n "$(ls -A "$EPG_DIR" 2>/dev/null)" ]; then
    cp -a "$EPG_DIR"/* "$BACKUP_BASE/epg/"
    EPG_COUNT=$(ls "$BACKUP_BASE/epg/" | wc -l)
    echo "  -> $EPG_COUNT ファイル"
else
    warn "EPG データがまだ取得されていないか、ディレクトリが空です"
fi

# ------------------------------------------------------------
# 完了
# ------------------------------------------------------------
echo ""
echo "=== バックアップ完了 ==="
echo "内容:"
echo "  key/          : B-CAS キー"
echo "  lib/          : 復号ライブラリ (libyakisoba / libsobacas) ※ビルド省略用"
echo "  recisdb/      : recisdb バイナリ ※rustビルド省略用"
echo "  mirakc/       : mirakc バイナリ + strings.yml ※cargo build省略用"
echo "  mirakc-arib/  : mirakc-arib バイナリ ※cmake/ninja vendorビルド省略用(最重要)"
echo "  scanned/      : チャンネルスキャン結果 ※ISDBScanner省略用"
echo "  mirakc-epg/   : mirakc EPG/サービスキャッシュ ※初回サービススキャン省略用"
echo "  channel/edcb/ : EDCB チャンネル設定 (最新の状態)"
echo "  epg/          : EDCB EPG データ"
echo ""
du -sh "$BACKUP_BASE"/* 2>/dev/null

echo ""
if [ "${#WARNINGS[@]}" -gt 0 ]; then
    echo "============================================================"
    echo " ⚠ 以下の ${#WARNINGS[@]} 件はバックアップされませんでした:"
    for w in "${WARNINGS[@]}"; do
        echo "   - $w"
    done
    echo "============================================================"
    exit 1
else
    echo "全項目のバックアップに成功しました。"
fi
BACKUPEOF

sudo chmod +x "$INSTALL_DIR/konomitv-backup.sh"

# server.py
sudo tee "$INSTALL_DIR/server.py" > /dev/null << 'PYEOF'
#!/usr/bin/env python3
import http.server
import json
import os
import socketserver
import subprocess
import urllib.parse

PORT = 80
BASE = "/opt/dtv-manage"

# 非対話シェルでも各種コマンドが見つかるよう PATH を明示的に拡張
# (/usr/local/bin/pm2 が壊れている/存在しない場合に備え、pm2 の代表的な実体パスも含める)
ENV = dict(os.environ)
ENV["PATH"] = (
    "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:"
    "/usr/local/lib/node_modules/pm2/bin:"
    + ENV.get("PATH", "")
)

def get_container_name():
    try:
        result = subprocess.run(
            ["hostname"],
            capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip() or "localhost"
    except Exception:
        return "localhost"

def get_all_ips():
    ips = []
    try:
        result = subprocess.run(
            ["ip", "-4", "addr", "show"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            parts = line.split()
            for p in parts:
                if "/" in p and not p.startswith("127."):
                    ip = p.split("/")[0]
                    if ip:
                        ips.append(ip)
        return ips
    except Exception:
        return []

def get_konomi_urls():
    urls = []
    # localhost 向け (コンテナ内から直接アクセスする場合)
    urls.append({"label": "ローカルホスト", "url": "https://my.local.konomi.tv:7000/"})
    for ip in get_all_ips():
        ip_dashed = ip.replace(".", "-")
        if ip.startswith("100."):
            label = "Tailscale"
        else:
            label = "LAN"
        urls.append({
            "label": label,
            "url": f"https://{ip_dashed}.local.konomi.tv:7000/"
        })
    return urls

class Handler(http.server.BaseHTTPRequestHandler):
    # 1接続が詰まってもサーバー全体が固まらないよう短めのタイムアウトを設定
    timeout = 10
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            # クライアントが途中で切断/タイムアウトしただけなので無視する
            self.close_connection = True

    def send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, message, status=500):
        self.send_json({"error": message}, status)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/" or path == "/index.html":
            self.serve_file("index.html", "text/html")
        elif path == "/api/info":
            self.handle_info()
        elif path == "/api/epg-status":
            self.handle_epg_status()
        elif path == "/api/bcas-keys":
            self.handle_get_bcas()
        else:
            self.send_error(404, "Not Found")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""

        if path == "/api/restart/edcb":
            self.handle_restart(["systemctl", "restart", "edcb"])
        elif path == "/api/restart/konomitv":
            self.handle_restart(["pm2", "restart", "KonomiTV"])
        elif path == "/api/restart/mirakc":
            self.handle_restart(["systemctl", "restart", "mirakc"])
        elif path == "/api/backup":
            self.handle_backup()
        elif path == "/api/bcas-keys":
            self.handle_save_bcas(body)
        else:
            self.send_error(404, "Not Found")

    def serve_file(self, filename, content_type):
        filepath = os.path.join(BASE, filename)
        try:
            with open(filepath, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", f"{content_type}; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self.send_error(404, "Not Found")

    def handle_info(self):
        container = get_container_name()
        self.send_json({
            "container_name": container,
            "edcb_url": f"http://{container}:5510/",
            "edcb_links": [
                {"label": "EDCB WebUI", "url": f"http://{container}:5510/"},
                {"label": "legacy", "url": f"http://{container}:5510/legacy/"},
                {"label": "番組表", "url": f"http://{container}:5510/EMWUI/epg.html"}
            ],
            "konomi_urls": get_konomi_urls(),
        })

    def handle_epg_status(self):
        try:
            result = subprocess.run(
                ["ls", "-la", "/var/local/edcb/Setting/EpgData"],
                capture_output=True, text=True, timeout=10, env=ENV
            )
            output = result.stdout if result.stdout else result.stderr
            self.send_json({"output": output, "returncode": result.returncode})
        except Exception as e:
            self.send_error_json(str(e))

    def handle_backup(self):
        script_path = os.path.join(BASE, "konomitv-backup.sh")
        try:
            result = subprocess.run(
                ["bash", script_path],
                capture_output=True, text=True, timeout=300, env=ENV
            )
            self.send_json({
                "success": result.returncode == 0,
                "output": result.stdout + result.stderr,
                "returncode": result.returncode
            })
        except subprocess.TimeoutExpired:
            self.send_error_json("バックアップがタイムアウトしました (300秒)")
        except FileNotFoundError:
            self.send_error_json(f"スクリプトが見つかりません: {script_path}")
        except Exception as e:
            self.send_error_json(str(e))

    def handle_get_bcas(self):
        try:
            with open("/usr/local/etc/bcas_keys", "r") as f:
                content = f.read()
            self.send_json({"content": content})
        except FileNotFoundError:
            self.send_json({"content": "", "error": "bcas_keys ファイルが見つかりません"})
        except Exception as e:
            self.send_error_json(str(e))

    def handle_save_bcas(self, body):
        try:
            data = json.loads(body)
            content = data.get("content", "")
            with open("/usr/local/etc/bcas_keys", "w") as f:
                f.write(content)
            result = subprocess.run(
                ["systemctl", "restart", "mirakc"],
                capture_output=True, text=True, timeout=30, env=ENV
            )
            self.send_json({
                "success": result.returncode == 0,
                "output": result.stdout + result.stderr,
                "returncode": result.returncode
            })
        except Exception as e:
            self.send_error_json(str(e))

    def handle_restart(self, command):
        try:
            result = subprocess.run(
                command,
                capture_output=True, text=True, timeout=30, env=ENV
            )
            self.send_json({
                "success": result.returncode == 0,
                "output": result.stdout + result.stderr,
                "returncode": result.returncode
            })
        except FileNotFoundError:
            self.send_error_json(f"コマンドが見つかりません: {command[0]}")
        except Exception as e:
            self.send_error_json(str(e))

class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"DTV Management Dashboard running on port {PORT}")
    server.serve_forever()
PYEOF

# index.html
sudo tee "$INSTALL_DIR/index.html" > /dev/null << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>DTV Management Dashboard</title>
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect x='6' y='14' width='52' height='36' rx='5' fill='%231e3a5f' stroke='%2338bdf8' stroke-width='2'/%3E%3Crect x='10' y='18' width='44' height='28' rx='2' fill='%230a1628'/%3E%3Ccircle cx='32' cy='32' r='9' fill='none' stroke='%2338bdf8' stroke-width='2' opacity='.8'/%3E%3Cpolygon points='29%2C27 29%2C37 39%2C32' fill='%2338bdf8'/%3E%3Crect x='26' y='50' width='12' height='4' rx='1' fill='%232563eb'/%3E%3Crect x='20' y='54' width='24' height='3' rx='1.5' fill='%231e3a5f' stroke='%2338bdf8' stroke-width='1'/%3E%3Ccircle cx='50' cy='20' r='2' fill='%2338bdf8' opacity='.7'/%3E%3Ccircle cx='44' cy='20' r='2' fill='%2394a3b8' opacity='.5'/%3E%3C/svg%3E">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#0f172a;color:#e2e8f0;min-height:100vh;padding:20px}
h1{text-align:center;font-size:1.5rem;padding:16px 0;color:#38bdf8;border-bottom:1px solid #1e293b;margin-bottom:20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:16px;max-width:1000px;margin:0 auto}
.card{background:#1e293b;border-radius:10px;padding:20px;border:1px solid #334155}
.card h2{font-size:1rem;color:#94a3b8;margin-bottom:12px;display:flex;align-items:center;gap:8px}
.card h2 .icon{font-size:1.2rem}
.info-row{display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid #262f3d;font-size:0.85rem}
.info-row:last-child{border-bottom:none}
.info-label{color:#94a3b8}
.info-value{color:#e2e8f0;font-weight:500}
.info-value a{color:#38bdf8;text-decoration:none}
.info-value a:hover{text-decoration:underline}
.btn{display:inline-flex;align-items:center;gap:6px;padding:8px 16px;border:none;border-radius:6px;font-size:0.85rem;cursor:pointer;transition:all .15s;font-weight:500}
.btn-restart{background:#2563eb;color:#fff}
.btn-restart:hover{background:#1d4ed8}
.btn-success{background:#16a34a;color:#fff}
.btn-success:hover{background:#15803d}
.btn-secondary{background:#475569;color:#fff}
.btn-secondary:hover{background:#374151}
.btn:disabled{opacity:0.5;cursor:not-allowed}
.btn-group{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}
.output-box{background:#0f172a;border:1px solid #334155;border-radius:6px;padding:10px;margin-top:10px;font-family:monospace;font-size:0.8rem;white-space:pre-wrap;max-height:200px;overflow-y:auto;display:none;color:#a5f3fc}
textarea.bcas-editor{width:100%;height:180px;background:#0f172a;border:1px solid #334155;border-radius:6px;padding:10px;font-family:monospace;font-size:0.8rem;color:#e2e8f0;resize:vertical;margin-top:8px}
textarea.bcas-editor:focus{outline:none;border-color:#38bdf8}
.toast{position:fixed;top:20px;right:20px;padding:12px 20px;border-radius:8px;color:#fff;font-size:0.85rem;z-index:1000;opacity:0;transition:opacity .3s;pointer-events:none}
.toast.show{opacity:1}
.toast.success{background:#16a34a}
.toast.error{background:#dc2626}
.toast.info{background:#2563eb}
</style>
</head>
<body>
<h1>DTV Management Dashboard</h1>
<div class="grid">
  <div class="card">
    <h2><span class="icon">&#128250;</span> KonomiTV</h2>
    <div id="konomi-list"></div>
  </div>
  <div class="card">
    <h2><span class="icon">&#128187;</span> EDCB</h2>
    <div id="edcb-links"></div>
  </div>
  <div class="card">
    <h2><span class="icon">&#128203;</span> EPG取得状況</h2>
    <div class="btn-group">
      <button class="btn btn-success" onclick="checkEPG()">EPG取得状況チェック</button>
    </div>
    <div class="output-box" id="epg-output"></div>
  </div>
  <div class="card">
    <h2><span class="icon">&#128260;</span> サービス再起動</h2>
    <div class="btn-group">
      <button class="btn btn-restart" onclick="restartService('edcb')">EDCB 再起動</button>
      <button class="btn btn-restart" onclick="restartService('konomitv')">KonomiTV 再起動</button>
      <button class="btn btn-restart" onclick="restartService('mirakc')">mirakc 再起動</button>
    </div>
    <div class="output-box" id="restart-output"></div>
  </div>
  <div class="card">
    <h2><span class="icon">&#128273;</span> BCASキー設定</h2>
    <div class="btn-group">
      <button class="btn btn-secondary" onclick="loadBcasKeys()">読み込み</button>
      <button class="btn btn-success" onclick="saveBcasKeys()">更新 (保存 + mirakc再起動)</button>
    </div>
    <textarea class="bcas-editor" id="bcas-editor" placeholder="「読み込み」ボタンで現在のbcas_keysを表示します..."></textarea>
    <div class="output-box" id="bcas-output"></div>
  </div>
  <div class="card">
    <h2><span class="icon">&#128421;</span> コンテナ情報</h2>
    <div class="info-row">
      <span class="info-label">コンテナ名</span>
      <span class="info-value" id="container-name">Loading...</span>
    </div>
    <div class="btn-group">
      <button class="btn btn-success" id="backup-btn" onclick="runBackup()">DTV関連バックアップ</button>
    </div>
    <div class="output-box" id="backup-output"></div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
function showToast(msg, type) {
  type = type || 'info';
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'toast ' + type + ' show';
  setTimeout(function() { t.className = 'toast'; }, 3000);
}

function showOutput(id, text) {
  const el = document.getElementById(id);
  el.textContent = text;
  el.style.display = 'block';
}

async function api(method, path, body) {
  const opts = { method: method, headers: {'Content-Type': 'application/json'} };
  if (body) opts.body = JSON.stringify(body);
  const res = await fetch(path, opts);
  return res.json();
}

async function loadInfo() {
  try {
    const info = await api('GET', '/api/info');
    document.getElementById('container-name').textContent = info.container_name;

    const edcbEl = document.getElementById('edcb-links');
    edcbEl.innerHTML = '';
    for (let i = 0; i < info.edcb_links.length; i++) {
      const link = info.edcb_links[i];
      const row = document.createElement('div');
      row.className = 'info-row';
      const a = document.createElement('a');
      a.href = link.url;
      a.target = '_blank';
      a.textContent = link.url;
      row.innerHTML = '<span class="info-label">' + link.label + '</span>';
      const val = document.createElement('span');
      val.className = 'info-value';
      val.appendChild(a);
      row.appendChild(val);
      edcbEl.appendChild(row);
    }

    const kl = document.getElementById('konomi-list');
    kl.innerHTML = '';
    for (let j = 0; j < info.konomi_urls.length; j++) {
      const u = info.konomi_urls[j];
      const row = document.createElement('div');
      row.className = 'info-row';
      const a = document.createElement('a');
      a.href = u.url;
      a.target = '_blank';
      a.textContent = u.url;
      row.innerHTML = '<span class="info-label">' + u.label + '</span>';
      const val = document.createElement('span');
      val.className = 'info-value';
      val.appendChild(a);
      row.appendChild(val);
      kl.appendChild(row);
    }
  } catch (e) {
    showToast('情報の読み込みに失敗しました', 'error');
  }
}

async function checkEPG() {
  const out = document.getElementById('epg-output');
  out.textContent = '確認中...';
  out.style.display = 'block';
  try {
    const data = await api('GET', '/api/epg-status');
    showOutput('epg-output', data.output || '(結果なし)');
    showToast(data.returncode === 0 ? 'EPG状況チェック完了' : 'EPGデータなし', data.returncode === 0 ? 'success' : 'info');
  } catch (e) {
    showOutput('epg-output', 'エラー: ' + e.message);
    showToast('チェックに失敗しました', 'error');
  }
}

async function restartService(name) {
  if (!confirm(name + ' を再起動しますか？')) return;
  const out = document.getElementById('restart-output');
  out.textContent = name + ' を再起動中...';
  out.style.display = 'block';
  try {
    const data = await api('POST', '/api/restart/' + name);
    showOutput('restart-output', data.output || data.error || '(完了)');
    showToast(data.success ? name + ' 再起動完了' : name + ' 再起動失敗', data.success ? 'success' : 'error');
  } catch (e) {
    showOutput('restart-output', 'エラー: ' + e.message);
    showToast('再起動に失敗しました', 'error');
  }
}

async function runBackup() {
  if (!confirm('DTV関連のバックアップを実行しますか？(mirakc-aribバイナリ等を含むため数分かかる場合があります)')) return;
  const btn = document.getElementById('backup-btn');
  const out = document.getElementById('backup-output');
  btn.disabled = true;
  btn.textContent = 'バックアップ実行中...';
  out.textContent = 'バックアップ実行中... (完了まで数分かかる場合があります)';
  out.style.display = 'block';
  try {
    const data = await api('POST', '/api/backup');
    showOutput('backup-output', data.output || data.error || '(結果なし)');
    showToast(data.success ? 'バックアップ完了' : 'バックアップに一部失敗しました', data.success ? 'success' : 'error');
  } catch (e) {
    showOutput('backup-output', 'エラー: ' + e.message);
    showToast('バックアップに失敗しました', 'error');
  } finally {
    btn.disabled = false;
    btn.textContent = 'DTV関連バックアップ';
  }
}

async function loadBcasKeys() {
  try {
    const data = await api('GET', '/api/bcas-keys');
    document.getElementById('bcas-editor').value = data.content || '';
    showToast('bcas_keys を読み込みました', 'success');
  } catch (e) {
    showToast('読み込みに失敗しました', 'error');
  }
}

async function saveBcasKeys() {
  const content = document.getElementById('bcas-editor').value;
  if (!confirm('bcas_keys を保存し、mirakc を再起動しますか？')) return;
  const out = document.getElementById('bcas-output');
  out.textContent = '保存・再起動中...';
  out.style.display = 'block';
  try {
    const data = await api('POST', '/api/bcas-keys', { content: content });
    showOutput('bcas-output', data.output || '完了');
    showToast(data.success ? '保存・再起動完了' : '保存に失敗しました', data.success ? 'success' : 'error');
  } catch (e) {
    showOutput('bcas-output', 'エラー: ' + e.message);
    showToast('保存に失敗しました', 'error');
  }
}

loadInfo();
</script>
</body>
</html>
HTMLEOF

sudo chmod +x "$INSTALL_DIR/server.py"

# systemd サービス
sudo tee /etc/systemd/system/${SERVICE_NAME}.service > /dev/null << SVCEOF
[Unit]
Description=DTV Management Dashboard
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/server.py
WorkingDirectory=$INSTALL_DIR
Environment=PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/lib/node_modules/pm2/bin
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_NAME}
sudo systemctl restart ${SERVICE_NAME}

echo ""
echo "=== セットアップ完了 ==="
echo " ファイル: $INSTALL_DIR/"
echo " サービス: systemctl status ${SERVICE_NAME}"
echo " ポート: 80"
echo " pm2: シンボリックリンクの作成/変更は行いません (既存の /usr/local/bin/pm2 をそのまま使用)"
echo ""
echo " アクセス:"
echo "   http://$(hostname)/"
ip -4 addr show | awk '/inet / && !/127.0.0.1/ {split($2,a,"/"); printf "   http://%s/\n", a[1]}'
