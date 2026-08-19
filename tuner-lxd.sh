#!/bin/bash
# =============================================================
# KonomiTV LXD セットアップスクリプト (ホスト側)
# GitHub 版: コンテナ作成・マウント・IDマッピング・Tailscale・
# USB チューナーパススルー・スナップショットまで実施し、
# インストールスクリプトは GitHub から取得してコンテナ内で実行する
#
# 利用方法:
#   bash tuner-lxd.sh
# または GitHub から直接:
#   bash <(curl -fsSL https://raw.githubusercontent.com/hirogura/mirakc-edcb-konomitv/main/tuner-lxd.sh)
# =============================================================
set -euo pipefail

MOUNT_PATH="/opt/lxd-data"
# チューナードライバ(.deb) のダウンロードキャッシュ先 (ローカル保持のみ・push しない)
DRIVER_DIR="/opt/lxd-data/konomitv-backup"

# GitHub リポジトリ (環境変数で上書き可能)
REPO_OWNER="${REPO_OWNER:-hirogura}"
REPO_NAME="${REPO_NAME:-mirakc-edcb-konomitv}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
INSTALL_SCRIPT_URL="${REPO_RAW}/install-mirakc-edcb-konomitv.sh"

# ============================================================
# ユーティリティ
# ============================================================
ask_yn() {
    local prompt="$1"
    local default="${2:-Y}"
    local hint
    if [ "$default" = "Y" ]; then
        hint="Y/n"
    else
        hint="y/N"
    fi
    while true; do
        read -rp "${prompt} [${hint}]: " ans
        ans="${ans:-$default}"
        case "${ans,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo "  y または n で答えてください。" ;;
        esac
    done
}

# ============================================================
# 0. snap linger チェック (Ubuntu Server 対策)
# ============================================================
if command -v snap &>/dev/null; then
    if ! snap list &>/dev/null; then
        echo "snap アプリケーションが実行できない状態です。"
        echo "  loginctl enable-linger を実行します..."
        sudo loginctl enable-linger "$USER"
        echo "  linger を有効にしました。"
    fi
fi

# ============================================================
# 1. チューナードライバのインストール
# ============================================================

if ask_yn "チューナードライバ (px4_drv) をインストールしますか？"; then
    echo ""
    echo "=== チューナードライバのインストール ==="
    mkdir -p "$DRIVER_DIR"

    echo "  最新バージョンを確認中..."
    DRIVER_VERSION=$(curl -s https://api.github.com/repos/tsukumijima/px4_drv/releases/latest | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    DRIVER_DEB="${DRIVER_DIR}/px4-drv-dkms_${DRIVER_VERSION}_all.deb"
    DRIVER_URL="https://github.com/tsukumijima/px4_drv/releases/download/v${DRIVER_VERSION}/px4-drv-dkms_${DRIVER_VERSION}_all.deb"
    echo "  ネット上の最新版: $(basename "$DRIVER_DEB")"

    EXISTING_DEB=$(ls "${DRIVER_DIR}"/px4-drv-dkms_*.deb 2>/dev/null | head -n1 || true)

    if [ -n "$EXISTING_DEB" ]; then
        echo "  ダウンロード済みのドライバが見つかりました: $(basename "$EXISTING_DEB")"
        if [ "$EXISTING_DEB" = "$DRIVER_DEB" ]; then
            echo "  → ローカルのファイルは最新バージョンと一致しています。"
            if ask_yn "ダウンロード済みの$(basename "$EXISTING_DEB")を使用しますか？"; then
                : # DRIVER_DEB は既に正しい値（ローカルと同じパス）なのでそのまま使用
            else
                echo "  再ダウンロードします..."
                curl -L -o "${DRIVER_DEB}" "${DRIVER_URL}"
                chmod 644 "${DRIVER_DEB}"
            fi
        else
            echo "  → ネット上に新しいバージョン ($(basename "$DRIVER_DEB")) が公開されています。"
            if ask_yn "新しいバージョンをネットから取得しますか？（いいえの場合は古いローカル版を使用）"; then
                curl -L -o "${DRIVER_DEB}" "${DRIVER_URL}"
                chmod 644 "${DRIVER_DEB}"
            else
                echo "  ローカルの旧バージョンを使用します: $(basename "$EXISTING_DEB")"
                DRIVER_DEB="$EXISTING_DEB"
            fi
        fi
    else
        echo "  ローカルにファイルが無いため、ネットから取得します。"
        curl -L -o "${DRIVER_DEB}" "${DRIVER_URL}"
        chmod 644 "${DRIVER_DEB}"
    fi

    # DRIVER_DEB は常にフルパスなので ./ を付けずにそのまま渡す
    sudo apt install -y "${DRIVER_DEB}"
    sudo modprobe -r px4_drv 2>/dev/null || true
    sudo modprobe px4_drv
    echo "  ドライバ インストール完了"
else
    echo "  ドライバインストールをスキップします"
fi
echo ""

# ============================================================
# 2. コンテナ名の入力
# ============================================================
read -rp "作成するLXDコンテナ名を入力してください [konomitv]: " CONTAINER
CONTAINER="${CONTAINER:-konomitv}"
echo "  コンテナ名: ${CONTAINER}"
echo ""

# ============================================================
# 3. Tailscale authkey の入力
# ============================================================
if ask_yn "Tailscale の authkey がありますか？"; then
    read -rsp "authkey を入力してください（tskeyから入力。入力は非表示）: " TS_AUTHKEY
    echo ""
    USE_TS_AUTHKEY=true
else
    USE_TS_AUTHKEY=false
fi
echo ""

# ============================================================
# 4. コンテナ作成・マウント・ID マッピング
# ============================================================
echo "=== コンテナ '${CONTAINER}' を作成 ==="
if lxc info "$CONTAINER" &>/dev/null; then
    echo "  コンテナは既に存在します"
else
    lxc launch ubuntu:26.04 "$CONTAINER"
fi

echo ""
echo "=== ${MOUNT_PATH} の確認・作成 ==="
if [ ! -d "$MOUNT_PATH" ]; then
    sudo mkdir -p "$MOUNT_PATH"
    echo "  ${MOUNT_PATH} を作成しました"
else
    echo "  ${MOUNT_PATH} は既に存在します"
fi

TV_DIR="${MOUNT_PATH}/tv"
if [ ! -d "$TV_DIR" ]; then
    sudo mkdir -p "$TV_DIR"
    echo "  ${TV_DIR} を作成しました"
else
    echo "  ${TV_DIR} は既に存在します"
fi
sudo chown 1000:1000 "$TV_DIR"
sudo chmod 755 "$TV_DIR"
echo "  録画フォルダ所有者: 1000:1000  パーミッション: 755"

echo ""
echo "=== ホストの ${MOUNT_PATH} をコンテナにマウント ==="
if lxc config device show "$CONTAINER" 2>/dev/null | grep -q "opt-lxd-data"; then
    echo "  opt-lxd-data は登録済み"
else
    lxc config device add "$CONTAINER" opt-lxd-data disk source="$MOUNT_PATH" path="$MOUNT_PATH"
fi

echo ""
echo "=== ID マッピング設定 ==="
lxc config set "$CONTAINER" raw.idmap "both 1000 1000"

echo ""
echo "=== コンテナを再起動 ==="
lxc restart "$CONTAINER"
sleep 3

# ============================================================
# 5. コンテナ内セットアップ (apt / sudo / Tailscale)
# ============================================================
echo ""
echo "=== コンテナ内セットアップ ==="
lxc exec "${CONTAINER}" -- bash -euo pipefail << 'INNER'
apt update
apt upgrade -y
apt install -y curl sudo
curl -fsSL https://tailscale.com/install.sh | sh
INNER

# ============================================================
# 6. Tailscale 起動
# ============================================================
echo ""
echo "=== Tailscale を起動 ==="
if [ "$USE_TS_AUTHKEY" = true ]; then
    lxc exec "${CONTAINER}" -- tailscale up --authkey="${TS_AUTHKEY}"
else
    echo "  authkeyがないため、手動認証を行ってください。"
    lxc exec "${CONTAINER}" -- tailscale up || true
fi
TS_IP=$(lxc exec "${CONTAINER}" -- tailscale ip -4 2>/dev/null || echo "取得中...")
echo "  Tailscale IP: ${TS_IP}"

# ============================================================
# 7. TailscaleOK スナップショット
# ============================================================
echo ""
if ask_yn "スナップショット 'TailscaleOK' を作成しますか？"; then
    echo "=== コンテナを停止中 ==="
    lxc stop "${CONTAINER}"
    echo "=== スナップショット 'TailscaleOK' を作成中 ==="
    lxc snapshot "${CONTAINER}" TailscaleOK
    echo "  スナップショット 'TailscaleOK' を作成しました"
    echo "=== コンテナを起動中 ==="
    lxc start "${CONTAINER}"
    sleep 3
fi

# ============================================================
# 8. USB チューナーパススルー
# ============================================================
DO_TUNER_PASS=false
if ask_yn "USB チューナーをコンテナにパススルーしますか？"; then
    DO_TUNER_PASS=true

    echo ""
    echo "=== USB チューナーを検出中 ==="
    LSUSB_LINE=$(lsusb | grep -i "ISDBT2056" || true)
    if [ -z "$LSUSB_LINE" ]; then
        echo "  警告: ISDBT2056 デバイスが見つかりません。パススルーをスキップします。"
        DO_TUNER_PASS=false
    else
        echo "  検出: $LSUSB_LINE"
        IDS=$(echo "$LSUSB_LINE" | grep -oP 'ID \K[0-9a-fA-F]{4}:[0-9a-fA-F]{4}')
        VENDOR_ID=$(echo "$IDS" | cut -d: -f1)
        PRODUCT_ID=$(echo "$IDS" | cut -d: -f2)
        echo "  vendorid : $VENDOR_ID"
        echo "  productid: $PRODUCT_ID"

        if lxc config device show "$CONTAINER" 2>/dev/null | grep -q "usb-tuner"; then
            echo "  usb-tuner は登録済みのため上書きします"
            lxc config device remove "$CONTAINER" usb-tuner
        fi
        lxc config device add "$CONTAINER" usb-tuner usb \
            vendorid="$VENDOR_ID" \
            productid="$PRODUCT_ID"
        echo "  usb-tuner を追加しました"

        echo ""
        echo "=== isdb2056video デバイスを検出中 ==="
        ISDB_DEVS=$(ls /dev/isdb2056video* 2>/dev/null || true)
        if [ -z "$ISDB_DEVS" ]; then
            echo "  警告: /dev/isdb2056video* が見つかりません。スキップします。"
        else
            IDX=0
            for DEV in $ISDB_DEVS; do
                NAME="isdb2056-${IDX}"
                echo "  追加: $DEV ($NAME)"
                if lxc config device show "$CONTAINER" 2>/dev/null | grep -q "^${NAME}:"; then
                    lxc config device remove "$CONTAINER" "$NAME"
                fi
                lxc config device add "$CONTAINER" "$NAME" unix-char \
                    source="$DEV" path="$DEV"
                IDX=$(( IDX + 1 ))
            done
        fi
    fi
fi

# ============================================================
# 9. コンテナ内チューナー確認
# ============================================================
if [ "$DO_TUNER_PASS" = true ]; then
    echo ""
    echo "=== コンテナ内チューナー確認 ==="
    lxc exec "${CONTAINER}" -- bash -c '
        ISDB_DEVS=$(ls /dev/isdb2056video* 2>/dev/null || true)
        if [ -z "$ISDB_DEVS" ]; then
            echo "  NG: /dev/isdb2056video* が見つかりません"
        else
            for DEV in $ISDB_DEVS; do
                chmod 666 "$DEV" 2>/dev/null
                echo "  OK: $DEV"
            done
        fi
    '
fi

# ============================================================
# 10. TunerOK スナップショット
# ============================================================
echo ""
if ask_yn "スナップショット 'TunerOK' を作成しますか？"; then
    echo "=== コンテナを停止中 ==="
    lxc stop "${CONTAINER}"
    echo "=== スナップショット 'TunerOK' を作成中 ==="
    lxc snapshot "${CONTAINER}" TunerOK
    echo "  スナップショット 'TunerOK' を作成しました"
    echo "=== コンテナを起動中 ==="
    lxc start "${CONTAINER}"
    sleep 3
fi

# ============================================================
# 11. インストールスクリプトを GitHub から取得して実行
# ============================================================
echo ""
echo "=== インストールスクリプトを GitHub から取得中 ==="
echo "  取得元: $INSTALL_SCRIPT_URL"
if ! lxc exec "${CONTAINER}" -- bash -s -- "$INSTALL_SCRIPT_URL" << 'FETCH'
set -e
URL="$1"
curl -fsSL -o /root/install-mirakc-edcb-konomitv.sh "$URL"
chmod +x /root/install-mirakc-edcb-konomitv.sh
echo "  取得完了: /root/install-mirakc-edcb-konomitv.sh"
FETCH
then
    echo "ERROR: インストールスクリプトの取得に失敗しました。"
    echo "  ネットワーク・GitHub への接続を確認してください。"
    echo "  手動で取得する場合:"
    echo "    lxc exec ${CONTAINER} -- curl -fsSL -o /root/install-mirakc-edcb-konomitv.sh $INSTALL_SCRIPT_URL"
    echo "    lxc exec ${CONTAINER} -- chmod +x /root/install-mirakc-edcb-konomitv.sh"
fi

echo ""
if ask_yn "取得したインストールスクリプトを今すぐ実行しますか？"; then
    echo "=== インストールスクリプトを実行中 ==="
    echo "  (B-CASキーの貼り付けなど、対話式の入力が必要です)"
    if lxc exec "${CONTAINER}" -- bash /root/install-mirakc-edcb-konomitv.sh; then
        echo ""
        echo "=== インストールスクリプトが正常に完了しました ==="
    else
        echo ""
        echo "WARNING: インストールスクリプトがエラーで終了しました。"
        echo "  コンテナ内で再実行できます:"
        echo "    lxc exec ${CONTAINER} -- bash /root/install-mirakc-edcb-konomitv.sh"
    fi
    echo ""
    echo "コンテナ内に入るには: lxc exec ${CONTAINER} bash"
else
    echo "コンテナ内でシェルを開始します。"
    echo "インストールスクリプトを実行してください:"
    echo "  bash ~/install-mirakc-edcb-konomitv.sh"
    echo ""
    exec lxc exec "${CONTAINER}" -- bash
fi
