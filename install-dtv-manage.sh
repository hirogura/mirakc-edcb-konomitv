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
sudo mkdir -p /opt/lxd-data/konomitv-backup
# LXD コンテナの UID マッピングでホスト側 root (UID 0) が nobody にマッピングされ、
# コンテナ内 root からバックアップ先に書き込めなくなることがあるため 777 に緩和
sudo chmod 777 /opt/lxd-data/konomitv-backup 2>/dev/null || true

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

# バックアップ先ディレクトリの確認・作成
# (server.py から呼ばれた場合、親ディレクトリが未作成で Permission denied になることがある)
if ! mkdir -p "$BACKUP_BASE" 2>/dev/null; then
    echo "エラー: バックアップ先 $BACKUP_BASE を作成/アクセスできません。"
    echo "  以下のコマンドを手動で実行してから再試行してください:"
    echo "    sudo mkdir -p $BACKUP_BASE && sudo chmod 777 $BACKUP_BASE"
    exit 1
fi
# LXD コンテナの UID マッピングにより、ホスト側 root (UID 0) が nobody にマッピングされ
# コンテナ内 root でも書き込めなくなることがある。事前に権限を緩和する。
chmod 777 "$BACKUP_BASE" 2>/dev/null || true

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

# dtv-rescan.sh
# (Web UI の「チャンネルスキャン再実行」ボタンから server.py が
#  バックグラウンド実行するスクリプト本体。
#  ISDBScanner でスキャンし、結果を mirakc / EDCB の設定へ反映する。
#  実行中はチューナーを占有するため視聴・録画は中断される。
#  常に root [LXDコンテナ内] で実行される前提のため sudo は使用しない)
sudo tee "$INSTALL_DIR/dtv-rescan.sh" > /dev/null << 'RESCANEOF'
#!/bin/bash
# =============================================================
# dtv-rescan.sh - ISDBScanner チャンネルスキャン再実行 + mirakc/EDCB 反映
# dtv-manage の Web UI (server.py) からバックグラウンド実行される。
# 標準出力への出力は server.py がログファイルに書き出す。
# =============================================================
set -u

export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"

RUNNING_FILE="/tmp/dtv-manage-rescan.running"
EXIT_FILE="/tmp/dtv-manage-rescan.exit"

DTV_DIR="/root/dtv"
SCANNED_DIR="$DTV_DIR/scanned"
MIRAKC_ETC="/etc/mirakc"
EDCB_SETTING="/var/local/edcb/Setting"
SCANNER_BIN="/usr/local/bin/isdb-scanner"
SCANNER_URL="https://github.com/tsukumijima/ISDBScanner/releases/download/v1.3.3/isdb-scanner"
SCANNER_TIMEOUT=600    # isdb-scanner 本体のタイムアウト (秒)
SERVICE_SCAN_MAX=450   # mirakc サービススキャンの最大待機時間 (秒)

# 完了・異常終了のいずれでもマーカーを必ず片付ける。
# サーバー側はこのマーカーの有無で「実行中」判定を行うため、
# 後始末漏れがあると二度とスキャンできなくなる。
# (server.py 再起動の影響も受けないよう、削除はサーバーではなくここで行う)
cleanup() {
    rc=$?
    rm -f "$RUNNING_FILE"
    echo "$rc" > "$EXIT_FILE"
    exit $rc
}
trap cleanup EXIT

rm -f "$EXIT_FILE"

say()  { echo "  $*"; }
step() { echo ""; echo "=== $* ==="; }

fail_exit() {
    echo ""
    echo "ERROR: $*"
    exit 1
}

wait_mirakc() {
    for _ in $(seq 1 30); do
        if curl -s http://127.0.0.1:40772/api/tuners >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# ---- 1/7 チューナー確認 ----
step "1/7 チューナーの確認"
TUNER_DEVICE="$(ls /dev/isdb2056video* 2>/dev/null | head -1 || true)"
if [ -z "$TUNER_DEVICE" ]; then
    TUNER_DEVICE="$(ls /dev/px4video* 2>/dev/null | head -1 || true)"
fi
[ -n "$TUNER_DEVICE" ] || fail_exit "チューナーデバイス (/dev/isdb2056video* または /dev/px4video*) が検出できません"
say "チューナー検出: $TUNER_DEVICE"

# ---- 2/7 サービス停止 (チューナー解放) ----
# 稼働中の mirakc/EDCB がチューナーを掴んでいると、ISDBScanner が
# チューナーを開けずサイレントに 0 件スキャンになることがある
step "2/7 mirakc / EDCB を一時停止 (チューナーを解放)"
systemctl stop mirakc 2>/dev/null || true
systemctl stop edcb 2>/dev/null || true
sleep 2
say "停止しました"

# ---- 3/7 ISDBScanner 準備 ----
step "3/7 ISDBScanner の準備"
if [ ! -x "$SCANNER_BIN" ]; then
    say "isdb-scanner が見つからないためダウンロードします..."
    wget -q "$SCANNER_URL" -O "$SCANNER_BIN" || fail_exit "ISDBScanner のダウンロードに失敗しました"
    chmod +x "$SCANNER_BIN"
fi
say "isdb-scanner を確認しました"

# ---- 4/7 スキャン実行 ----
step "4/7 チャンネルスキャンを実行中 (最長 ${SCANNER_TIMEOUT}秒)"
rm -rf "$SCANNED_DIR"
mkdir -p "$SCANNED_DIR"
timeout "$SCANNER_TIMEOUT" "$SCANNER_BIN" "$SCANNED_DIR/"
SCAN_RC=$?
[ "$SCAN_RC" -eq 0 ] || fail_exit "isdb-scanner が異常終了しました (終了コード: $SCAN_RC)"

MIRAKC_CONFIG_SRC="$SCANNED_DIR/mirakc/config.yml"
[ -f "$MIRAKC_CONFIG_SRC" ] || {
    find "$SCANNED_DIR" -type f 2>/dev/null || true
    fail_exit "$MIRAKC_CONFIG_SRC が生成されませんでした"
}
CH_COUNT="$(grep -c '^[[:space:]]*- name:' "$MIRAKC_CONFIG_SRC" 2>/dev/null || true)"
CH_COUNT="${CH_COUNT:-0}"
[ "$CH_COUNT" -gt 0 ] || fail_exit "スキャン結果のチャンネルが 0 件です。アンテナ線・B-CASキーを確認してください"
say "${CH_COUNT} チャンネルを検出しました"

# ---- 5/7 mirakc 反映 ----
step "5/7 mirakc へ反映"
mkdir -p "$MIRAKC_ETC"
cp "$MIRAKC_CONFIG_SRC" "$MIRAKC_ETC/config.yml"

# scan-services 等の定期ジョブを無効化する。
# インストーラと同じく Python でパースして上書きする
# (sed だと YAML 内に重複キーが残る不具合があるため)
python3 << 'PYEOF'
import re

path = "/etc/mirakc/config.yml"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

if re.search(r"^jobs:\s*$", content, re.MULTILINE):
    for job in ("scan-services", "sync-clocks", "update-schedules"):
        pattern = re.compile(
            r"(^\s*" + re.escape(job) + r":\s*\n(?:\s+\S.*\n)*?\s*disabled:\s*)(true|false)",
            re.MULTILINE,
        )
        if pattern.search(content):
            content = pattern.sub(lambda m: m.group(1) + "true", content)
        else:
            job_pattern = re.compile(r"(^\s*" + re.escape(job) + r":\s*\n)", re.MULTILINE)
            if job_pattern.search(content):
                content = job_pattern.sub(lambda m: m.group(1) + "    disabled: true\n", content)
            else:
                content += f"\n  {job}:\n    disabled: true\n"
else:
    content += (
        "\njobs:\n"
        "  scan-services:\n    disabled: true\n"
        "  sync-clocks:\n    disabled: true\n"
        "  update-schedules:\n    disabled: true\n"
    )

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("  jobs.* を無効化しました")
PYEOF

[ -f "$MIRAKC_ETC/strings.yml" ] || say "WARNING: strings.yml が存在しません。mirakc が起動しない場合は手動で配置してください"

systemctl restart mirakc
say "mirakc 再起動、応答を待機中..."
wait_mirakc || fail_exit "mirakc が応答しません (journalctl -u mirakc -n 50 で確認してください)"
say "mirakc 起動確認"

# ---- 6/7 mirakc サービススキャン ----
# 新しい channels 設定から services.json を作り直すため、
# scan-services を一時的に有効化して mirakc を再起動する
step "6/7 mirakc サービススキャン (最長 ${SERVICE_SCAN_MAX}秒)"
sed -i '/scan-services:/,/disabled:/ s/disabled: true/disabled: false/' "$MIRAKC_ETC/config.yml"
systemctl restart mirakc
wait_mirakc || true

SERVICE_COUNT=0
SCAN_OK=false
for i in $(seq 1 $((SERVICE_SCAN_MAX / 5))); do
    SERVICE_COUNT="$(curl -s http://127.0.0.1:40772/api/services 2>/dev/null | grep -o '"id"' | wc -l || true)"
    SERVICE_COUNT="${SERVICE_COUNT:-0}"
    if [ "$SERVICE_COUNT" -gt 0 ]; then
        SCAN_OK=true
        break
    fi
    sleep 5
    echo "  スキャン中... ($((i * 5))秒経過)"
done
if [ "$SCAN_OK" = true ]; then
    say "${SERVICE_COUNT} 件のサービスを検出しました"
else
    say "WARNING: サービススキャンがタイムアウトしました (services 0 件)。mirakc ログを確認してください"
fi

# 起動のたびにチューナーを占有しないよう無効化に戻す
sed -i '/scan-services:/,/disabled:/ s/disabled: false/disabled: true/' "$MIRAKC_ETC/config.yml"
systemctl restart mirakc
wait_mirakc || true
say "mirakc 再起動完了 (scan-services を無効化)"

# ---- 7/7 EDCB 反映 + 各サービス再起動 ----
step "7/7 EDCB へ反映・各サービス再起動"
if [ -f "$SCANNED_DIR/EDCB-Wine/ChSet5.txt" ]; then
    mkdir -p "$EDCB_SETTING"
    cp "$SCANNED_DIR/EDCB-Wine/ChSet5.txt" "$EDCB_SETTING/ChSet5.txt"
    say "ChSet5.txt を更新しました"
else
    say "WARNING: $SCANNED_DIR/EDCB-Wine/ChSet5.txt がないため EDCB の ChSet5 は変更していません"
fi
if [ -f "$SCANNED_DIR/EDCB-Wine/BonDriver_mirakc(BonDriver_mirakc).ChSet4.txt" ]; then
    mkdir -p "$EDCB_SETTING"
    cp "$SCANNED_DIR/EDCB-Wine/BonDriver_mirakc(BonDriver_mirakc).ChSet4.txt" \
       "$EDCB_SETTING/BonDriver_LinuxMirakc(LinuxMirakc).ChSet4.txt"
    say "BonDriver_LinuxMirakc(LinuxMirakc).ChSet4.txt を更新しました"
fi

if [ -f /etc/systemd/system/edcb.service ]; then
    systemctl restart edcb
    say "edcb を再起動しました"
fi

PM2_BIN="$(command -v pm2 2>/dev/null || true)"
[ -z "$PM2_BIN" ] && PM2_BIN="/usr/local/lib/node_modules/pm2/bin/pm2"
if [ -x "$PM2_BIN" ]; then
    if "$PM2_BIN" restart KonomiTV >/dev/null 2>&1; then
        say "KonomiTV を再起動しました (チャンネル一覧を再取得)"
    else
        say "WARNING: KonomiTV の再起動に失敗しました"
    fi
else
    say "pm2 が見つからないため KonomiTV の再起動をスキップします"
fi

echo ""
echo "EPG データは mirakc / EDCB の定期受信で自動更新されます"
echo ""
echo "=== チャンネルスキャン再実行 完了 (${CH_COUNT} チャンネル) ==="
RESCANEOF

sudo chmod +x "$INSTALL_DIR/dtv-rescan.sh"

# konomitv-update.sh
# (Web UI の「KonomiTV アップデート」ボタンから server.py が PTY 上で
#  起動するスクリプト本体。出力はブラウザのターミナルに表示され、
#  インストーラーの質問にはブラウザから入力して対話する)
sudo tee "$INSTALL_DIR/konomitv-update.sh" > /dev/null << 'KONOMIEOF'
#!/bin/bash
# =============================================================
# konomitv-update.sh - KonomiTV アップデート用ラッパー
# dtv-manage の Web UI (server.py) が PTY 上で起動し、対話操作を
# ブラウザのターミナルに中継する。常に root 前提。
# =============================================================
set -u

export PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"

DTV_DIR="/root/dtv"
mkdir -p "$DTV_DIR"

echo "=== KonomiTV アップデート ==="
echo ""

# ------------------------------------------------------------
# pm2 のパス対策
#
# nvm 経由で Node.js をインストールした環境では pm2 の実体が
#   /root/.nvm/versions/node/<バージョン>/bin/pm2
# に置かれる。LXD コンテナ内の非インタラクティブシェルでは nvm の
# PATH が通らないため、KonomiTV インストーラーが内部で呼ぶ PM2 操作が
# 「PM2 を呼ぼうとして失敗」する。
# 対策: 実際に存在する pm2 へのシンボリックリンクを /usr/local/bin/pm2
# に張ってからインストーラーを起動する (バージョン番号はハードコードしない)。
# ------------------------------------------------------------
PM2_REAL=""
for c in "$(command -v pm2 2>/dev/null)" \
         /root/.nvm/versions/node/*/bin/pm2 \
         "${HOME:-/root}/.nvm/versions/node/"*/bin/pm2 \
         /usr/local/lib/node_modules/pm2/bin/pm2; do
    if [ -n "$c" ] && [ -e "$c" ]; then
        PM2_REAL="$c"
        break
    fi
done

if [ -z "$PM2_REAL" ]; then
    echo "WARNING: pm2 が見つかりません。アップデート完了後の自動起動に失敗する可能性があります"
else
    PM2_REAL="$(readlink -f "$PM2_REAL")"
    PM2_BINDIR="$(dirname "$PM2_REAL")"
    # nvm 配下の pm2 だった場合は node も必要になるため bin ディレクトリを PATH に追加
    case "$PM2_BINDIR" in
        */.nvm/versions/node/*/bin) export PATH="$PM2_BINDIR:$PATH" ;;
    esac

    CURRENT_TARGET="$(readlink -f /usr/local/bin/pm2 2>/dev/null || true)"
    if [ "$CURRENT_TARGET" != "$PM2_REAL" ]; then
        ln -sf "$PM2_REAL" /usr/local/bin/pm2
        echo "pm2 のシンボリックリンクを作成/更新しました:"
        echo "  /usr/local/bin/pm2 -> $PM2_REAL"
    else
        echo "pm2 のシンボリックリンクは最新です: /usr/local/bin/pm2 -> $PM2_REAL"
    fi
    echo "pm2 バージョン: $(pm2 --version 2>/dev/null || echo '確認できず')"
fi
echo ""

# ------------------------------------------------------------
# 最新インストーラーのダウンロードと起動
# KonomiTV のアップデートは「インストーラーを再実行するだけ」なので、
# 毎回最新版を取り直してから対話モードで起動する。
# ------------------------------------------------------------
echo "[1/2] 最新の KonomiTV インストーラーをダウンロード中..."
cd "$DTV_DIR" || exit 1
rm -f KonomiTV-Installer.elf.new
curl -fL --retry 3 --retry-delay 2 -o KonomiTV-Installer.elf.new \
    https://github.com/tsukumijima/KonomiTV/releases/latest/download/KonomiTV-Installer.elf || {
    echo "ERROR: インストーラーのダウンロードに失敗しました (ネットワークを確認してください)"
    exit 1
}
mv KonomiTV-Installer.elf.new KonomiTV-Installer.elf
chmod +x KonomiTV-Installer.elf
echo "      ダウンロード完了"
echo ""

echo "[2/2] インストーラーを起動します"
echo ""
echo "============================================================"
echo " これより KonomiTV インストーラーが対話モードで起動します。"
echo " 既存環境がある場合はアップデートとして動作しますので、"
echo " 画面の指示に従い、Web UI 下部の入力欄から回答してください。"
echo "============================================================"
sleep 1

exec ./KonomiTV-Installer.elf
KONOMIEOF

sudo chmod +x "$INSTALL_DIR/konomitv-update.sh"

# server.py
sudo tee "$INSTALL_DIR/server.py" > /dev/null << 'PYEOF'
#!/usr/bin/env python3
import http.server
import json
import os
import pty
import socketserver
import struct
import subprocess
import termios
import fcntl
import threading
import urllib.parse
from datetime import datetime

PORT = 80
BASE = "/opt/dtv-manage"
SERVICE_NAME = "dtv-manage"
APP_VERSION = "1.2.3"

# アップデート処理の状態管理用ファイル (/tmp に置くため再起動で自然にクリアされる)
UPDATE_RUNNING_FILE = "/tmp/dtv-manage-update.running"
UPDATE_EXIT_FILE = "/tmp/dtv-manage-update.exit"
UPDATE_LOG_FILE = "/tmp/dtv-manage-update.log"

# チャンネルスキャン再実行 (ISDBScanner) の状態管理用ファイル。
# 実行中マーカーの削除は dtv-rescan.sh 側の trap EXIT が行うため、
# サーバーを再起動してもスキャン処理の状態を見失わない
RESCAN_RUNNING_FILE = "/tmp/dtv-manage-rescan.running"
RESCAN_EXIT_FILE = "/tmp/dtv-manage-rescan.exit"
RESCAN_LOG_FILE = "/tmp/dtv-manage-rescan.log"
RESCAN_SCRIPT = os.path.join(BASE, "dtv-rescan.sh")
SCANNED_CONFIG = "/root/dtv/scanned/mirakc/config.yml"

# KonomiTV アップデート (対話式ターミナル)
KONOMI_UPDATE_SCRIPT = os.path.join(BASE, "konomitv-update.sh")
KONOMI_DTV_DIR = "/root/dtv"

# GitHub から最新のインストーラを取得して実行するコマンド
# (install-dtv-manage.sh 自体が最後に dtv-manage サービスを再起動するため、
#  実行はバックグラウンドで行い、API は即座に応答を返す)
UPDATE_COMMAND = (
    "set -o pipefail; "
    "curl -fsSL "
    "https://raw.githubusercontent.com/hirogura/mirakc-edcb-konomitv/main/install-dtv-manage.sh"
    " | bash >> " + UPDATE_LOG_FILE + " 2>&1; "
    "echo $? > " + UPDATE_EXIT_FILE + "; "
    "rm -f " + UPDATE_RUNNING_FILE
)

# 非対話シェルでも各種コマンドが見つかるよう PATH を明示的に拡張
# (/usr/local/bin/pm2 が壊れている/存在しない場合に備え、pm2 の代表的な実体パスも含める)
ENV = dict(os.environ)
ENV["PATH"] = (
    "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:"
    "/usr/local/lib/node_modules/pm2/bin:"
    + ENV.get("PATH", "")
)

class KonomiSession:
    """KonomiTV インストーラーを PTY 上で動かし、対話を HTTP 経由に中継する。

    - start()   : konomitv-update.sh を pty.fork() で起動し、読み取りスレッド開始
    - write()   : ブラウザからの入力 (1行 + \r や Ctrl+C の \x03) を PTY へ書き込む
    - snapshot(): offset 以降の出力差分と稼働状態を返す (ブラウザはポーリング)
    出力は全量メモリ保持だが、インストーラーの出力は高々数百KB程度のため
    トリミングは行わない (offset 指定の単純さを優先)。
    サーバー再起動時は子プロセスが SIGHUP で終了するためセッションも消滅する。
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.buffer = ""
        self.master_fd = None
        self.pid = None
        self.running = False
        self.exit_code = None

    def start(self, script_path):
        argv = ["bash", script_path]
        with self.lock:
            if self.running:
                return False, "アップデートが既に実行中です"
            if not os.path.exists(script_path):
                return False, f"スクリプトが見つかりません: {script_path}"
            try:
                pid, fd = pty.fork()
            except OSError as e:
                return False, f"PTY の作成に失敗しました: {e}"
            if pid == 0:
                # 子プロセス: 疑似端末上でインストーラーを実行
                # (作業ディレクトリはラッパースクリプト側で作成・移動するため、
                #  ここでの chdir 失敗は致命的ではない)
                try:
                    os.environ["TERM"] = "dumb"
                    try:
                        os.chdir(KONOMI_DTV_DIR)
                    except OSError:
                        pass
                    os.execvp(argv[0], argv)
                except Exception:
                    os._exit(127)
            self.pid = pid
            self.master_fd = fd
            self.buffer = ""
            self.exit_code = None
            self.running = True
            # 端末サイズを設定しておく (TERM=dumb でも参照する実装があるため)
            try:
                fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
            except OSError:
                pass
        threading.Thread(target=self._reader, daemon=True).start()
        return True, ""

    def _reader(self):
        fd = self.master_fd
        while True:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            with self.lock:
                self.buffer += data.decode("utf-8", errors="replace")
        # EOF 到達 = 子プロセス終了。終了コードを回収してから状態を更新する
        exit_code = None
        try:
            _, status = os.waitpid(self.pid, 0)
            exit_code = os.waitstatus_to_exitcode(status)
        except (ChildProcessError, AttributeError, OSError):
            pass
        try:
            os.close(fd)
        except OSError:
            pass
        with self.lock:
            self.running = False
            self.exit_code = exit_code
            self.master_fd = None

    def write(self, data):
        with self.lock:
            if not self.running or self.master_fd is None:
                return False
            try:
                os.write(self.master_fd, data.encode("utf-8"))
                return True
            except OSError:
                return False

    def snapshot(self, offset=0):
        with self.lock:
            total = len(self.buffer)
            output = ""
            if 0 <= offset < total:
                output = self.buffer[offset:]
            return {
                "running": self.running,
                "exit": self.exit_code,
                "total": total,
                "output": output,
            }

    def status(self):
        with self.lock:
            return {"running": self.running, "exit": self.exit_code, "total": len(self.buffer)}

KONOMI_SESSION = KonomiSession()

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
        try:
            self.route_get()
        except (BrokenPipeError, ConnectionResetError):
            raise
        except Exception as e:
            # 未捕捉例外でも接続を切らず JSON エラーとして返す
            # (接続切断だとブラウザ側は原因不明の「失敗」しか表示できないため)
            try:
                self.send_error_json(f"サーバー内部エラー: {e}")
            except Exception:
                pass

    def route_get(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/" or path == "/index.html":
            self.serve_file("index.html", "text/html")
        elif path == "/api/info":
            self.handle_info()
        elif path == "/api/epg-status":
            self.handle_epg_status()
        elif path == "/api/bcas-keys":
            self.handle_get_bcas()
        elif path == "/api/update/status":
            self.handle_update_status()
        elif path == "/api/rescan/status":
            self.handle_rescan_status()
        elif path == "/api/konomitv-update/status":
            self.send_json(KONOMI_SESSION.status())
        elif path == "/api/konomitv-update/output":
            self.handle_konomi_output()
        else:
            self.send_error(404, "Not Found")

    def do_POST(self):
        try:
            self.route_post()
        except (BrokenPipeError, ConnectionResetError):
            raise
        except Exception as e:
            try:
                self.send_error_json(f"サーバー内部エラー: {e}")
            except Exception:
                pass

    def route_post(self):
        path = urllib.parse.urlparse(self.path).path
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""

        if path == "/api/restart/edcb":
            self.handle_restart(["systemctl", "restart", "edcb"])
        elif path == "/api/restart/konomitv":
            self.handle_restart(["pm2", "restart", "KonomiTV"])
        elif path == "/api/restart/mirakc":
            self.handle_restart(["systemctl", "restart", "mirakc"])
        elif path == "/api/restart/self":
            self.handle_restart(["systemctl", "restart", SERVICE_NAME])
        elif path == "/api/update":
            self.handle_update()
        elif path == "/api/backup":
            self.handle_backup()
        elif path == "/api/rescan":
            self.handle_rescan()
        elif path == "/api/konomitv-update/start":
            self.handle_konomi_start()
        elif path == "/api/konomitv-update/input":
            self.handle_konomi_input(body)
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
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self.send_error(404, "Not Found")

    def handle_info(self):
        container = get_container_name()
        self.send_json({
            "container_name": container,
            "version": APP_VERSION,
            "edcb_url": f"http://{container}:5510/",
            "edcb_links": [
                {"label": "EDCB WebUI", "url": f"http://{container}:5510/"},
                {"label": "legacy", "url": f"http://{container}:5510/legacy/"},
                {"label": "番組表", "url": f"http://{container}:5510/E3/#epg"}
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
        backup_base = "/opt/lxd-data/konomitv-backup"
        try:
            os.makedirs(backup_base, exist_ok=True)
        except OSError as e:
            self.send_error_json(
                f"バックアップ先ディレクトリ {backup_base} を作成できません: {e}"
            )
            return
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

    def get_scan_info(self):
        info = {"scan_exists": False, "channel_count": None, "scanned_at": None}
        try:
            if os.path.isfile(SCANNED_CONFIG):
                info["scan_exists"] = True
                result = subprocess.run(
                    ["grep", "-c", "^[[:space:]]*- name:", SCANNED_CONFIG],
                    capture_output=True, text=True, timeout=5
                )
                try:
                    info["channel_count"] = int(result.stdout.strip())
                except ValueError:
                    info["channel_count"] = 0
                info["scanned_at"] = datetime.fromtimestamp(
                    os.path.getmtime(SCANNED_CONFIG)
                ).strftime("%Y-%m-%d %H:%M")
        except Exception:
            pass
        return info

    def handle_rescan(self):
        # 同時実行防止 (マーカーは dtv-rescan.sh の trap EXIT が削除する)
        if os.path.exists(RESCAN_RUNNING_FILE):
            self.send_error_json("チャンネルスキャンが既に実行中です")
            return
        if not os.path.exists(RESCAN_SCRIPT):
            self.send_error_json(f"スクリプトが見つかりません: {RESCAN_SCRIPT}")
            return
        try:
            with open(RESCAN_RUNNING_FILE, "w") as f:
                f.write(str(os.getpid()))
            if os.path.exists(RESCAN_EXIT_FILE):
                os.remove(RESCAN_EXIT_FILE)
            with open(RESCAN_LOG_FILE, "w") as log_f:
                subprocess.Popen(
                    ["bash", RESCAN_SCRIPT],
                    stdin=subprocess.DEVNULL,
                    stdout=log_f,
                    stderr=subprocess.STDOUT,
                    env=ENV,
                    start_new_session=True
                )
            self.send_json({"success": True})
        except Exception as e:
            try:
                os.remove(RESCAN_RUNNING_FILE)
            except OSError:
                pass
            self.send_error_json(str(e))

    def handle_rescan_status(self):
        running = os.path.exists(RESCAN_RUNNING_FILE)
        log_tail = ""
        try:
            with open(RESCAN_LOG_FILE, "r", errors="replace") as f:
                log_tail = f.read()[-4000:]
        except FileNotFoundError:
            pass
        exit_code = None
        try:
            with open(RESCAN_EXIT_FILE) as f:
                exit_code = int(f.read().strip())
        except (FileNotFoundError, ValueError):
            pass
        data = {"running": running, "exit": exit_code, "log": log_tail}
        data.update(self.get_scan_info())
        self.send_json(data)

    def handle_konomi_output(self):
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        try:
            offset = int(params.get("offset", ["0"])[0])
        except ValueError:
            offset = 0
        self.send_json(KONOMI_SESSION.snapshot(offset))

    def handle_konomi_start(self):
        ok, err = KONOMI_SESSION.start(KONOMI_UPDATE_SCRIPT)
        if ok:
            self.send_json({"success": True})
        else:
            self.send_error_json(err)

    def handle_konomi_input(self, body):
        try:
            data = str(json.loads(body or b"{}").get("data", ""))[:512]
        except Exception:
            data = ""
        if not data:
            self.send_error_json("入力データが空です")
            return
        if not KONOMI_SESSION.write(data):
            self.send_error_json("実行中のアップデートセッションがありません")
            return
        self.send_json({"success": True})

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

    def handle_update(self):
        # 同時実行防止
        if os.path.exists(UPDATE_RUNNING_FILE):
            self.send_error_json("アップデートが既に実行中です")
            return
        try:
            # マーカーファイルはサーバー側で先に作成し、
            # バックグラウンド処理の終了時に削除される
            with open(UPDATE_RUNNING_FILE, "w") as f:
                f.write(str(os.getpid()))
            if os.path.exists(UPDATE_EXIT_FILE):
                os.remove(UPDATE_EXIT_FILE)
            subprocess.Popen(
                ["bash", "-c", UPDATE_COMMAND],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=ENV,
                start_new_session=True
            )
            self.send_json({"success": True})
        except Exception as e:
            try:
                os.remove(UPDATE_RUNNING_FILE)
            except OSError:
                pass
            self.send_error_json(str(e))

    def handle_update_status(self):
        running = os.path.exists(UPDATE_RUNNING_FILE)
        log_tail = ""
        try:
            with open(UPDATE_LOG_FILE, "r", errors="replace") as f:
                log_tail = f.read()[-2000:]
        except FileNotFoundError:
            pass
        exit_code = None
        try:
            with open(UPDATE_EXIT_FILE) as f:
                exit_code = int(f.read().strip())
        except (FileNotFoundError, ValueError):
            pass
        self.send_json({"running": running, "log": log_tail, "exit": exit_code})

class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == "__main__":
    # 前回のアップデート処理が残した状態ファイルを掃除
    # (アップデート完了時のサービス再起動でバックグラウンド処理が
    #  強制終了され、マーカーが削除されないまま残ることがあるため)
    for stale in (UPDATE_RUNNING_FILE, UPDATE_EXIT_FILE):
        try:
            os.remove(stale)
        except OSError:
            pass
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
h1{display:flex;align-items:center;justify-content:center;flex-wrap:wrap;gap:10px;font-size:1.5rem;padding:16px 12px;color:#38bdf8;border-bottom:1px solid #1e293b;margin-bottom:20px}
.version{font-size:0.7rem;color:#94a3b8;background:#1e293b;border:1px solid #334155;border-radius:999px;padding:2px 8px;font-weight:600;letter-spacing:.03em}
.header-actions{display:inline-flex;gap:8px}
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
.btn-sm{padding:4px 10px;font-size:0.75rem}
.btn-restart{background:#2563eb;color:#fff}
.btn-restart:hover{background:#1d4ed8}
.btn-success{background:#16a34a;color:#fff}
.btn-success:hover{background:#15803d}
.btn-secondary{background:#475569;color:#fff}
.btn-secondary:hover{background:#374151}
.btn:disabled{opacity:0.5;cursor:not-allowed}
.btn-group{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}
.output-box{background:#0f172a;border:1px solid #334155;border-radius:6px;padding:10px;margin-top:10px;font-family:monospace;font-size:0.8rem;white-space:pre-wrap;max-height:200px;overflow-y:auto;display:none;color:#a5f3fc}
.update-log{max-width:1000px;margin:0 auto 16px}
textarea.bcas-editor{width:100%;height:180px;background:#0f172a;border:1px solid #334155;border-radius:6px;padding:10px;font-family:monospace;font-size:0.8rem;color:#e2e8f0;resize:vertical;margin-top:8px}
textarea.bcas-editor:focus{outline:none;border-color:#38bdf8}
.toast{position:fixed;top:20px;right:20px;padding:12px 20px;border-radius:8px;color:#fff;font-size:0.85rem;z-index:1000;opacity:0;transition:opacity .3s;pointer-events:none}
.toast.show{opacity:1}
.toast.success{background:#16a34a}
.toast.error{background:#dc2626}
.toast.info{background:#2563eb}
.terminal{background:#0a1628;border:1px solid #334155;border-radius:6px;padding:10px;margin-top:10px;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:0.75rem;line-height:1.4;color:#d7e5ff;white-space:pre-wrap;word-break:break-all;height:300px;overflow-y:auto;display:none}
.terminal-input-row{display:none;gap:6px;margin-top:6px}
.terminal-input-row input{flex:1;background:#0f172a;border:1px solid #334155;border-radius:6px;padding:8px;color:#e2e8f0;font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:0.85rem}
.terminal-input-row input:focus{outline:none;border-color:#38bdf8}
</style>
</head>
<body>
<h1>DTV Management Dashboard<span class="version" id="app-version">v...</span><span class="header-actions"><button class="btn btn-success btn-sm" id="update-btn" onclick="runUpdate()">アップデート</button><button class="btn btn-secondary btn-sm" id="restart-self-btn" onclick="restartSelf()">再起動</button></span></h1>
<div class="output-box update-log" id="update-output"></div>
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
    <h2><span class="icon">&#128225;</span> ISDBScanner</h2>
    <div class="info-row">
      <span class="info-label">前回スキャン結果</span>
      <span class="info-value" id="rescan-info">Loading...</span>
    </div>
    <div class="btn-group">
      <button class="btn btn-success" id="rescan-btn" onclick="runRescan()">チャンネルスキャン再実行</button>
    </div>
    <div class="output-box" id="rescan-output"></div>
  </div>
  <div class="card">
    <h2><span class="icon">&#128230;</span> KonomiTV アップデート</h2>
    <div class="info-row">
      <span class="info-label">状態</span>
      <span class="info-value" id="konomi-status">待機中</span>
    </div>
    <div class="btn-group">
      <button class="btn btn-success" id="konomi-update-btn" onclick="startKonomiUpdate()">KonomiTV アップデート</button>
      <button class="btn btn-secondary" id="konomi-ctrlc-btn" style="display:none" onclick="sendKonomiCtrlC()">Ctrl+C (中断)</button>
    </div>
    <div class="terminal" id="konomi-terminal"></div>
    <div class="terminal-input-row" id="konomi-input-row">
      <input type="text" id="konomi-input" placeholder="インストーラーへの回答を入力して Enter..." autocomplete="off">
      <button class="btn btn-restart btn-sm" onclick="sendKonomiInput()">送信</button>
    </div>
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

function sleep(ms) {
  return new Promise(function(r) { setTimeout(r, ms); });
}

async function loadInfo() {
  try {
    const info = await api('GET', '/api/info');
    document.getElementById('container-name').textContent = info.container_name;
    document.getElementById('app-version').textContent = 'v.' + info.version;

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

async function restartSelf() {
  if (!confirm('DTV Management Dashboard を再起動しますか？')) return;
  const btn = document.getElementById('restart-self-btn');
  btn.disabled = true;
  showToast('再起動中...', 'info');
  try {
    await api('POST', '/api/restart/self');
  } catch (e) {
    // 再起動に伴う切断は想定内なので無視する
  }
  for (let i = 0; i < 30; i++) {
    await sleep(1000);
    try {
      await api('GET', '/api/info');
      showToast('再起動完了', 'success');
      setTimeout(function() { location.reload(); }, 800);
      return;
    } catch (e) {}
  }
  showToast('サーバー応答がありません。ページを手動で再読み込みしてください。', 'error');
  btn.disabled = false;
}

async function runUpdate() {
  if (!confirm('GitHubから最新版を取得してアップデートしますか？\n(完了後、ダッシュボードが自動的に再起動・再読み込みされます)')) return;
  const btn = document.getElementById('update-btn');
  btn.disabled = true;
  showOutput('update-output', 'アップデートを開始しています...');
  try {
    await api('POST', '/api/update');
  } catch (e) {
    showOutput('update-output', 'エラー: ' + e.message);
    showToast('アップデートを開始できませんでした', 'error');
    btn.disabled = false;
    return;
  }
  showToast('アップデートを実行中です...', 'info');
  pollUpdate(0);
}

async function pollUpdate(elapsed) {
  const btn = document.getElementById('update-btn');
  await sleep(3000);
  elapsed += 3;
  let st;
  try {
    st = await api('GET', '/api/update/status');
  } catch (e) {
    // インストーラー最後のサービス再起動による切断は正常な流れ
    if (elapsed < 300) { pollUpdate(elapsed); }
    else { updateTimeout(btn); }
    return;
  }
  if (st.running) {
    showOutput('update-output', 'アップデート実行中... (' + elapsed + '秒経過)\n\n' + (st.log || ''));
    if (elapsed < 300) { pollUpdate(elapsed); }
    else { updateTimeout(btn); }
    return;
  }
  // 実行終了: exit コードを確認
  // (exit ファイルなし = サービス再起動時にプロセスが停止された = 成功)
  if (st.exit !== null && st.exit !== undefined && st.exit !== 0) {
    showOutput('update-output', 'アップデートに失敗しました (exit=' + st.exit + ')\n\n' + (st.log || ''));
    showToast('アップデートに失敗しました', 'error');
    btn.disabled = false;
    return;
  }
  showOutput('update-output', (st.log || '') + '\n=== アップデート完了 ===');
  showToast('アップデート完了。再読み込みします...', 'success');
  setTimeout(function() { location.reload(); }, 2000);
}

function updateTimeout(btn) {
  showToast('アップデートがタイムアウトしました。ログをご確認ください。', 'error');
  btn.disabled = false;
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

function formatScanInfo(data) {
  if (!data || !data.scan_exists) return '(スキャン結果なし)';
  let txt = (data.channel_count !== null && data.channel_count !== undefined)
    ? data.channel_count + ' チャンネル' : 'スキャン済み';
  if (data.scanned_at) txt += ' / ' + data.scanned_at;
  return txt;
}

async function refreshScanInfo() {
  try {
    const st = await api('GET', '/api/rescan/status');
    document.getElementById('rescan-info').textContent = formatScanInfo(st);
    return st;
  } catch (e) {
    document.getElementById('rescan-info').textContent = '-';
    return null;
  }
}

async function runRescan() {
  if (!confirm('ISDBScanner でチャンネルスキャンを再実行しますか？\n\n・実行中はチューナーを占有するため視聴中の番組が中断されます\n・録画中の場合は録画に失敗するので注意してください\n・スキャンと mirakc/EDCB への反映まで数分〜十数分かかります')) return;
  const btn = document.getElementById('rescan-btn');
  btn.disabled = true;
  try {
    const resp = await api('POST', '/api/rescan');
    if (resp && resp.error) {
      showToast(resp.error, 'error');
      btn.disabled = false;
      return;
    }
  } catch (e) {
    showToast('スキャンを開始できませんでした', 'error');
    btn.disabled = false;
    return;
  }
  showToast('チャンネルスキャンを実行中です...', 'info');
  showOutput('rescan-output', 'チャンネルスキャンを実行中...');
  pollRescan(0, btn);
}

async function pollRescan(elapsed, btn) {
  await sleep(3000);
  elapsed += 3;
  let st;
  try {
    st = await api('GET', '/api/rescan/status');
  } catch (e) {
    if (elapsed < 1800) { pollRescan(elapsed, btn); } else { rescanGiveUp(btn); }
    return;
  }
  if (st.running) {
    showOutput('rescan-output',
      'スキャン実行中... (' + Math.floor(elapsed / 60) + '分' + (elapsed % 60) + '秒経過)\n\n' + (st.log || ''));
    const out = document.getElementById('rescan-output');
    out.scrollTop = out.scrollHeight;
    if (elapsed < 1800) { pollRescan(elapsed, btn); } else { rescanGiveUp(btn); }
    return;
  }
  // 終了: exit コードを確認
  // (exit ファイルなし = サーバー再起動等で記録を取りこぼした場合なので成功扱い)
  const ok = (st.exit === null || st.exit === undefined || st.exit === 0);
  showOutput('rescan-output',
    (st.log || '') + '\n' + (ok ? '=== チャンネルスキャン完了 ===' : '=== チャンネルスキャン失敗 (exit=' + st.exit + ') ==='));
  showToast(ok ? 'スキャン完了: ' + formatScanInfo(st) : 'チャンネルスキャンに失敗しました', ok ? 'success' : 'error');
  document.getElementById('rescan-info').textContent = formatScanInfo(st);
  btn.disabled = false;
}

function rescanGiveUp(btn) {
  showToast('状態取得を中断しました。処理はバックグラウンドで継続している場合があります', 'error');
  btn.disabled = false;
}

async function initScanCard() {
  const st = await refreshScanInfo();
  // ページ読み込み時にスキャン中だった場合はポーリングを再開する
  if (st && st.running) {
    const btn = document.getElementById('rescan-btn');
    btn.disabled = true;
    showOutput('rescan-output', 'スキャン実行中...\n\n' + (st.log || ''));
    pollRescan(0, btn);
  }
}

let konomiActive = false;
let konomiOffset = 0;
let konomiErrorCount = 0;

function stripAnsi(s) {
  return s
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, '')
    .replace(/\x1b\].*?(\x07|\x1b\\)/g, '')
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '')
    .replace(/\r\n/g, '\n')
    .replace(/\r/g, '');
}

function termWrite(text) {
  const el = document.getElementById('konomi-terminal');
  el.textContent += stripAnsi(text);
  el.scrollTop = el.scrollHeight;
}

function setKonomiUI(running) {
  document.getElementById('konomi-update-btn').disabled = running;
  document.getElementById('konomi-ctrlc-btn').style.display = running ? 'inline-flex' : 'none';
  document.getElementById('konomi-input-row').style.display = running ? 'flex' : 'none';
  document.getElementById('konomi-status').textContent = running ? '実行中...' : '待機中';
}

function openKonomiTerminal() {
  const el = document.getElementById('konomi-terminal');
  el.textContent = '';
  el.style.display = 'block';
}

function finishKonomi(st) {
  konomiActive = false;
  setKonomiUI(false);
  termWrite('\n=== 終了 (exit=' + st.exit + ') ===\n');
  showToast(st.exit === 0 ? 'KonomiTV アップデート完了' : 'アップデートが終了しました (exit=' + st.exit + ')',
    st.exit === 0 ? 'success' : 'error');
}

function pollKonomi() {
  api('GET', '/api/konomitv-update/output?offset=' + konomiOffset).then(function(st) {
    konomiErrorCount = 0;
    if (!konomiActive) return;
    if (st.output) termWrite(st.output);
    konomiOffset = st.total;
    if (st.running) {
      setTimeout(pollKonomi, 600);
    } else {
      finishKonomi(st);
    }
  }).catch(function() {
    // サーバー側の一時的なエラー (再起動直後など) には数回は耐える
    if (konomiActive && ++konomiErrorCount < 10) {
      setTimeout(pollKonomi, 1500);
    } else {
      konomiActive = false;
      setKonomiUI(false);
    }
  });
}

function beginKonomiPolling() {
  konomiActive = true;
  konomiOffset = 0;
  konomiErrorCount = 0;
  openKonomiTerminal();
  setKonomiUI(true);
  pollKonomi();
}

async function startKonomiUpdate() {
  try {
    const st = await api('GET', '/api/konomitv-update/status');
    if (st.running) { beginKonomiPolling(); return; }
  } catch (e) {}
  if (!confirm('KonomiTV のアップデート (インストーラー再実行) を開始しますか？\n\n・最新インストーラーをダウンロードして対話モードで起動します\n・処理の完了後、KonomiTV が再起動され視聴中の番組は中断されます\n・インストーラーの質問には下のターミナル入力欄から回答してください')) return;
  try {
    const resp = await api('POST', '/api/konomitv-update/start');
    if (resp && resp.error) {
      showToast(resp.error, 'error');
      return;
    }
  } catch (e) {
    showToast('アップデートを開始できませんでした' + (e && e.message ? ' (' + e.message + ')' : ''), 'error');
    return;
  }
  showToast('インストーラーを起動しました。ターミナルで対話してください', 'info');
  beginKonomiPolling();
}

async function sendKonomiInput() {
  const inp = document.getElementById('konomi-input');
  const value = inp.value;
  inp.value = '';
  inp.focus();
  try {
    const resp = await api('POST', '/api/konomitv-update/input', { data: value + '\r' });
    if (resp && resp.error) showToast(resp.error, 'error');
  } catch (e) {}
}

async function sendKonomiCtrlC() {
  try {
    await api('POST', '/api/konomitv-update/input', { data: '\x03' });
    showToast('Ctrl+C を送信しました', 'info');
  } catch (e) {}
}

async function initKonomiCard() {
  document.getElementById('konomi-input').addEventListener('keydown', function(ev) {
    if (ev.key === 'Enter') { ev.preventDefault(); sendKonomiInput(); }
  });
  // ページ読み込み時に実行中だった場合はターミナルを復元してポーリング再開
  try {
    const st = await api('GET', '/api/konomitv-update/status');
    if (st.running) beginKonomiPolling();
  } catch (e) {}
}

loadInfo();
initScanCard();
initKonomiCard();
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
# HOME が無いと set -u のスクリプトや pm2 (~/.pm2 参照) が落ちるため明示する
Environment=HOME=/root
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
echo " 機能: 再起動 / BCASキー / EPG状況 / チャンネルスキャン再実行 (ISDBScanner) / KonomiTV アップデート (対話ターミナル) / バックアップ / アップデート"
echo " pm2: シンボリックリンクの作成/変更は行いません (既存の /usr/local/bin/pm2 をそのまま使用)"
echo ""
echo " アクセス:"
echo "   http://$(hostname)/"
ip -4 addr show | awk '/inet / && !/127.0.0.1/ {split($2,a,"/"); printf "   http://%s/\n", a[1]}'
