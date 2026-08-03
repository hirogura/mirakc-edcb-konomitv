#!/bin/bash
set -euo pipefail

# ============================================================
# mirakc + EDCB + KonomiTV 環境構築スクリプト (Docker不使用版・GitHub版)
# このスクリプトは GitHub から取得してコンテナ内で実行する:
#   bash <(curl -fsSL https://raw.githubusercontent.com/hirogura/mirakc-edcb-konomitv/main/install-mirakc-edcb-konomitv.sh)
# 前提条件:
#   - Debian系Linux (Ubuntu/Debian)
#   - ネット接続
#   - TVチューナー (px4_drv対応デバイス) は接続済みで、ドライバは
#     ホスト側でインストール・ロード済みであること
#     (本スクリプトを実行するコンテナ/ホストにはデバイスノード
#      /dev/isdb2056video* または /dev/px4video* が見えている必要がある)
# ============================================================

# root で直接実行している場合 (LXD コンテナ内など) は sudo を省略する
if [ "$(id -u)" -eq 0 ]; then
    sudo() { "$@"; }
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
[ -z "$REAL_USER" ] && REAL_USER="$(id -un)"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
DTV_DIR="$REAL_HOME/dtv"
LOG_FILE="/var/log/mirakc-konomitv-install.log"

mkdir -p /var/log
if touch "$LOG_FILE" 2>/dev/null; then
    exec > >(tee -a "$LOG_FILE") 2>&1
fi
echo "=== インストール開始: $(date) ==="

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
# --rescan-only オプション: チャンネルスキャンのみ再実行したい場合
# (mirakc/EDCB/KonomiTV は既にインストール済みで、チャンネルが
#  表示されない問題だけを直したいときに使う)
# ============================================================
RESCAN_ONLY=false
if [ "${1:-}" = "--rescan-only" ]; then
    RESCAN_ONLY=true
    echo "=== --rescan-only モード: チャンネルスキャンと mirakc/EDCB 設定の再適用のみ実行します ==="
fi

# ============================================================
# 再実行コマンド (スクリプトを取得した方法によらず動作するようにする)
# ============================================================
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
else
    SCRIPT_PATH="$0"
fi
if [ "$(id -u)" -eq 0 ]; then
    RESCAN_CMD="bash ${SCRIPT_PATH} --rescan-only"
else
    RESCAN_CMD="sudo bash ${SCRIPT_PATH} --rescan-only"
fi

# ============================================================
# バックアップの確認 (--rescan-only の場合は対象外)
# バックアップはローカル (ホストのマウント) にのみ保持し、
# GitHub には push しない。B-CASキー・チャンネルスキャン結果・
# EPGデータなどの再インストール時の復元に使う。
# ============================================================
BACKUP_BASE=""
for _base in "/opt/lxd-data/konomitv-backup" "/opt/lxd-data/リネーム"; do
    if [ -f "$_base/key/bcas_keys" ] || [ -d "$_base/mirakc" ] || [ -d "$_base/scanned" ]; then
        BACKUP_BASE="$_base"
        break
    fi
done
if [ -z "$BACKUP_BASE" ] && [ -d "/opt/lxd-data/konomitv-backup" ]; then
    BACKUP_BASE="/opt/lxd-data/konomitv-backup"
fi

USE_BACKUP_KEY=false
USE_BACKUP_SOFTCAS_BUILD=false   # libyakisoba/libsobacas/recisdb
USE_BACKUP_MIRAKC_BUILD=false    # mirakc バイナリ (cargo build --release 省略)
USE_BACKUP_MIRAKC_ARIB_BUILD=false  # mirakc-arib バイナリ (cmake/ninja vendor 省略)
USE_BACKUP_SCAN=false            # ISDBScanner チャンネルスキャン結果
USE_BACKUP_MIRAKC_EPG=false      # mirakc EPG/サービスキャッシュ (初回サービススキャン省略)
USE_BACKUP_EPG=false             # EDCB EPG データ

if [ "$RESCAN_ONLY" = false ] && [ -n "$BACKUP_BASE" ]; then
    echo ""
    echo "=== バックアップデータが見つかりました ==="
    echo "パス: $BACKUP_BASE"
    echo ""
    echo "バックアップ内容:"
    [ -f "$BACKUP_BASE/key/bcas_keys" ] && echo "  [key]         B-CAS キー"
    ls "$BACKUP_BASE/lib/"*.so* 2>/dev/null | head -1 > /dev/null && echo "  [lib]         復号ライブラリ (SoftCAS)"
    [ -f "$BACKUP_BASE/recisdb/recisdb" ] && echo "  [recisdb]     recisdb バイナリ"
    [ -f "$BACKUP_BASE/mirakc/mirakc" ] && echo "  [mirakc]      mirakc バイナリ"
    [ -f "$BACKUP_BASE/mirakc-arib/mirakc-arib" ] && echo "  [mirakc-arib] mirakc-arib バイナリ"
    [ -f "$BACKUP_BASE/scanned/mirakc/config.yml" ] && echo "  [scanned]     チャンネルスキャン結果"
    [ -d "$BACKUP_BASE/mirakc-epg" ] && [ -n "$(ls -A "$BACKUP_BASE/mirakc-epg" 2>/dev/null)" ] && echo "  [mirakc-epg]  mirakc EPG/サービスキャッシュ"
    EPG_COUNT=$(ls "$BACKUP_BASE/epg/" 2>/dev/null | wc -l || echo 0)
    [ "$EPG_COUNT" -gt 0 ] && echo "  [epg]         EDCB EPG データ ($EPG_COUNT ファイル)"
    echo ""

    if [ -f "$BACKUP_BASE/key/bcas_keys" ]; then
        if ask_yn "バックアップしたB-CASキーを使用しますか？"; then
            USE_BACKUP_KEY=true
            echo "  -> バックアップキーを使用します"
        fi
    fi

    if [ -f "$BACKUP_BASE/lib/pkgconfig/libsobacas.pc" ] && [ -f "$BACKUP_BASE/recisdb/recisdb" ]; then
        if ask_yn "ビルド済みのSoftCASライブラリ/recisdbを使用しますか？(rustビルド等を省略)"; then
            USE_BACKUP_SOFTCAS_BUILD=true
            echo "  -> SoftCASライブラリ/recisdbのビルドを省略します"
        fi
    fi

    if [ -f "$BACKUP_BASE/mirakc/mirakc" ]; then
        if ask_yn "ビルド済みのmirakcバイナリを使用しますか？(cargo build --releaseを省略)"; then
            USE_BACKUP_MIRAKC_BUILD=true
            echo "  -> mirakcのビルドを省略します"
        fi
    fi

    if [ -f "$BACKUP_BASE/mirakc-arib/mirakc-arib" ]; then
        if ask_yn "ビルド済みのmirakc-aribバイナリを使用しますか？(cmake/ninja vendorビルドを省略・最も時間短縮効果が大きい項目です)"; then
            USE_BACKUP_MIRAKC_ARIB_BUILD=true
            echo "  -> mirakc-aribのビルドを省略します"
        fi
    fi

    if [ -f "$BACKUP_BASE/scanned/mirakc/config.yml" ]; then
        if ask_yn "バックアップしたチャンネルスキャン結果を使用しますか？(ISDBScannerの実行を省略)"; then
            USE_BACKUP_SCAN=true
            echo "  -> チャンネルスキャンを省略します"
        fi
    fi

    if [ -d "$BACKUP_BASE/mirakc-epg" ] && [ -n "$(ls -A "$BACKUP_BASE/mirakc-epg" 2>/dev/null)" ]; then
        if ask_yn "バックアップしたmirakcのEPG/サービスキャッシュを使用しますか？(初回サービススキャンを省略)"; then
            USE_BACKUP_MIRAKC_EPG=true
            echo "  -> 初回サービススキャンを省略します"
        fi
    fi

    if [ "$EPG_COUNT" -gt 0 ]; then
        if ask_yn "バックアップしたEDCBのEPGデータを使用しますか？"; then
            USE_BACKUP_EPG=true
            echo "  -> EDCBのEPGデータ受信を省略します"
        fi
    fi
fi

# ============================================================
# 0. ユーザー入力 (--rescan-only の場合はスキップ)
# ============================================================
BCAS_CONTENT=""
if [ "$RESCAN_ONLY" = false ]; then
    echo "=== 1/9: キー設定 ==="
    if [ "$USE_BACKUP_KEY" = true ]; then
        echo "バックアップのB-CASキーを使用するため、入力をスキップします"
    else
        echo "キーの内容を貼り付けてください（入力後、Enterキーを2回押すと確定します）:"
        BCAS_CONTENT=$(sed '/^$/q')
    fi
fi

# ============================================================
# 1. 依存パッケージ
# ============================================================
if [ "$RESCAN_ONLY" = false ]; then
echo "=== 2/9: 依存パッケージをインストール中 ==="
sudo apt update
sudo apt install -y \
    autoconf automake cmake libtool libpcsclite-dev git build-essential pkg-config \
    curl wget libclang-dev libdvbv5-dev libudev-dev \
    nodejs npm ffmpeg liblua5.2-dev liblua5.4-dev libz-dev \
    g++ make gcc ninja-build \
    libpcap-dev libpcre2-dev libcurl4-openssl-dev || {
    echo "WARNING: 一部パッケージのインストールに失敗しました。続行します..."
}
fi

# GCC 13 は利用しない (GCC 13 と 15 の混在でリンクエラーが発生するため)
# デフォルトコンパイラ (GCC 15) + -Wno-error で統一する

# ============================================================
# 2. TVチューナードライバについて
#
# ドライバのインストール・ロードはホスト側で完了していることを
# 前提とし、コンテナ側ではデバイスノード (/dev/isdb2056video*,
# /dev/px4video* 等) が見えているかどうかだけを確認する。
# ============================================================
mkdir -p "$DTV_DIR"

# ============================================================
# チューナーデバイスの検出 (この後の処理全体で使う)
# ============================================================
detect_tuner_device() {
    local isdb_dev px4_dev
    isdb_dev=$(ls /dev/isdb2056video* 2>/dev/null | head -1 || true)
    px4_dev=$(ls /dev/px4video* 2>/dev/null | head -1 || true)
    if [ -n "$isdb_dev" ]; then
        echo "$isdb_dev"
    elif [ -n "$px4_dev" ]; then
        echo "$px4_dev"
    else
        echo ""
    fi
}

TUNER_DEVICE="$(detect_tuner_device)"
if [ -z "$TUNER_DEVICE" ]; then
    echo "ERROR: チューナーデバイス (/dev/isdb2056video* または /dev/px4video*) が検出できません。"
    echo "  ドライバはホスト側でインストール・ロードされている前提です。以下をホストで確認してください:"
    echo "  - USB/PCIe チューナーが正しく接続されているか ('lsusb' または 'lspci')"
    echo "  - 'lsmod | grep px4_drv' でドライバがロードされているか"
    echo "  - LXD コンテナにデバイスが渡されているか ('lxc config device show <コンテナ名>')"
    echo "  コンテナ内では 'ls -la /dev/ | grep -E \"isdb|px4\"' でデバイスノードを確認してください。"
    echo ""
    echo "チューナーが認識されない状態でチャンネルスキャンを行うと、"
    echo "チャンネルが1件も検出されず空の番組表になります。"
    exit 1
fi
echo "チューナー検出: $TUNER_DEVICE"

# ============================================================
# 3. libyakisoba / libsobacas のビルド (バックアップがあれば復元のみ)
# ============================================================
if [ "$RESCAN_ONLY" = false ]; then
if [ "$USE_BACKUP_SOFTCAS_BUILD" = true ]; then
    echo "=== 3/9: 復号ライブラリの復元（ビルド省略）==="
    sudo cp -a "$BACKUP_BASE/lib/"*.so* /usr/local/lib/ 2>/dev/null || true
    sudo mkdir -p /usr/local/lib/pkgconfig
    sudo cp -a "$BACKUP_BASE/lib/pkgconfig/libsobacas.pc" /usr/local/lib/pkgconfig/
    if [ -d "$BACKUP_BASE/lib/etc" ] && [ -n "$(ls -A "$BACKUP_BASE/lib/etc" 2>/dev/null)" ]; then
        sudo cp -a "$BACKUP_BASE/lib/etc/." /usr/local/etc/
    fi
    sudo ldconfig
    echo "  -> libyakisoba / libsobacas を復元しました"
else
echo "=== 3/9: 復号ライブラリのビルド ==="
cd "$DTV_DIR"
for repo in "libyakisoba" "libsobacas"; do
    if [ ! -d "$repo" ]; then
        git clone "https://github.com/tsunoda14/${repo}.git" || {
            echo "WARNING: ${repo} のクローンに失敗しました"
            continue
        }
    fi
    cd "$repo"
    autoreconf -i || true
    mkdir -p build && cd build
    if [ "$repo" == "libyakisoba" ]; then
        ../configure --sysconfdir=/usr/local/etc || true
    else
        ../configure || true
    fi
    make -j"$(nproc)" || true
    sudo make install || true
    cd "$DTV_DIR"
done
sudo ldconfig
fi
fi

# ============================================================
# 4. Rust と ツール群のビルド (recisdb / mirakc。バックアップがあれば復元のみ)
# ============================================================
if [ "$RESCAN_ONLY" = false ]; then
echo "=== 4/9: Rust と ツールのビルド ==="

NEED_RUST=false
[ "$USE_BACKUP_SOFTCAS_BUILD" = false ] && NEED_RUST=true
[ "$USE_BACKUP_MIRAKC_BUILD" = false ] && NEED_RUST=true

if [ "$NEED_RUST" = true ]; then
    if ! command -v cargo &> /dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    fi
    source "$HOME/.cargo/env" 2>/dev/null || export PATH="$HOME/.cargo/bin:$PATH"
fi

# --- recisdb ---
if [ "$USE_BACKUP_SOFTCAS_BUILD" = true ]; then
    echo "バックアップから recisdb を復元中（rustビルド省略）..."
    sudo cp "$BACKUP_BASE/recisdb/recisdb" /usr/local/bin/recisdb
    sudo chmod +x /usr/local/bin/recisdb
else
    sudo mkdir -p /usr/local/lib/pkgconfig
    sudo tee /usr/local/lib/pkgconfig/libsobacas.pc > /dev/null <<EOF
prefix=/usr/local
libdir=/usr/local/lib
includedir=/usr/include

Name: libsobacas
Description: PCSC compatible ECM decoder library
Version: 0.0.0
Libs: -L\${libdir} -lsobacas
Cflags: -I\${includedir}/PCSC
EOF

    cd "$DTV_DIR"
    if [ ! -d "recisdb-rs" ]; then
        git clone --recursive https://github.com/kazuki0824/recisdb-rs.git || {
            echo "ERROR: recisdb-rs のクローンに失敗しました"
            echo "手動で https://github.com/kazuki0824/recisdb-rs を確認してください"
        }
    fi
    if [ -d "recisdb-rs" ]; then
        cd recisdb-rs
        if [ -f "b25-sys/build.rs" ]; then
            sed -i 's/pcsclite/sobacas/g' b25-sys/build.rs || true
        fi
        cargo build -F dvb --release || {
            echo "ERROR: recisdb のビルドに失敗しました"
            exit 1
        }
        sudo systemctl stop mirakc 2>/dev/null || true
        sudo cp target/release/recisdb /usr/local/bin/
    fi
fi

# --- mirakc ---
if [ "$USE_BACKUP_MIRAKC_BUILD" = true ]; then
    echo "バックアップから mirakc を復元中（cargo build --release を省略）..."
    sudo systemctl stop mirakc 2>/dev/null || true
    sudo cp "$BACKUP_BASE/mirakc/mirakc" /usr/local/bin/mirakc
    sudo chmod +x /usr/local/bin/mirakc
else
    echo "=== mirakc ビルド中（数分かかります）==="
    cd "$DTV_DIR"
    if [ ! -d "mirakc-src" ]; then
        git clone --recursive https://github.com/mirakc/mirakc.git mirakc-src || {
            echo "ERROR: mirakc のクローンに失敗しました"
            exit 1
        }
    fi
    cd mirakc-src
    git pull --recurse-submodules || true
    cargo build --release || {
        echo "ERROR: mirakc のビルドに失敗しました"
        exit 1
    }
    sudo systemctl stop mirakc 2>/dev/null || true
    sudo cp target/release/mirakc /usr/local/bin/
fi
fi

# ============================================================
# 5. mirakc-arib: ソースビルド (バックアップがあれば復元のみ)
# GCC 15 対策: CXXFLAGS_EXTRA=-Wno-error で対応
# ============================================================
if [ "$RESCAN_ONLY" = false ]; then
echo "=== mirakc-arib セットアップ ==="
MIRAKC_ARIB_VERSION="0.24.29"

if [ "$USE_BACKUP_MIRAKC_ARIB_BUILD" = true ]; then
    echo "バックアップから mirakc-arib を復元中（cmake/ninja vendorビルドを省略）..."
    sudo cp "$BACKUP_BASE/mirakc-arib/mirakc-arib" /usr/local/bin/mirakc-arib
    sudo chmod +x /usr/local/bin/mirakc-arib
elif ! command -v mirakc-arib &> /dev/null; then
    echo "mirakc-arib をソースからビルド中..."
    cd "$DTV_DIR"

    if [ ! -d "mirakc-arib" ]; then
        git clone --recursive --depth 1 -b "$MIRAKC_ARIB_VERSION" https://github.com/mirakc/mirakc-arib.git 2>/dev/null || {
            echo "WARNING: バージョン $MIRAKC_ARIB_VERSION のタグが見つかりません。最新版を取得します..."
            rm -rf mirakc-arib
            git clone --recursive --depth 1 https://github.com/mirakc/mirakc-arib.git || {
                echo "ERROR: mirakc-arib のクローンに失敗しました"
                exit 1
            }
        }
    fi
    cd mirakc-arib

    echo "サブモジュールを同期中..."
    git submodule sync --recursive
    git submodule update --init --recursive --depth 1 || {
        echo "ERROR: サブモジュールの取得に失敗しました"
        exit 1
    }

    # 過去の失敗ビルドのキャッシュが残っていると依存関係が壊れる
    if [ -d build ]; then
        echo "既存の build ディレクトリをクリーンアップ中..."
        rm -rf build
    fi

    # CMakeLists.txt を修正: GCC 13 参照を除去し、-Wno-error のみを追加
    echo "CMakeLists.txt を修正中..."
    # 既に GCC 13 の設定が注入済みの場合は除去
    sed -i 's/ CC=gcc-13 CXX=g++-13 GCC=gcc-13//g' CMakeLists.txt || true
    sed -i 's/ CC=gcc-13//g' CMakeLists.txt || true
    sed -i 's/ CXX=g++-13//g' CMakeLists.txt || true
    sed -i 's/ GCC=gcc-13//g' CMakeLists.txt || true

    # CXXFLAGS_EXTRA=-Wno-error を追加（既にあればスキップ）
    if ! grep -q "CXXFLAGS_EXTRA=-Wno-error" CMakeLists.txt; then
        echo "CMakeLists.txt に -Wno-error を追加中..."
        sed -i 's|make -j ${NPROC} SYSPREFIX=${MIRAKC_ARIB_VENDOR_DIR} ${MIRAKC_ARIB_TSDUCK_DEFS}|make -j ${NPROC} SYSPREFIX=${MIRAKC_ARIB_VENDOR_DIR} CXXFLAGS_EXTRA=-Wno-error ${MIRAKC_ARIB_TSDUCK_DEFS}|g' CMakeLists.txt || true
        sed -i 's|make -j ${NPROC} install-devel SYSPREFIX=${MIRAKC_ARIB_VENDOR_DIR} ${MIRAKC_ARIB_TSDUCK_DEFS}|make -j ${NPROC} install-devel SYSPREFIX=${MIRAKC_ARIB_VENDOR_DIR} CXXFLAGS_EXTRA=-Wno-error ${MIRAKC_ARIB_TSDUCK_DEFS}|g' CMakeLists.txt || true
    fi

    # CMake の CXXFLAGS_EXTRA 変数も設定
    if ! grep -q "MIRAKC_ARIB_TSDUCK_ARIB_CXXFLAGS_EXTRA" CMakeLists.txt | head -1; then
        sed -i 's|set(MIRAKC_ARIB_TSDUCK_ARIB_CXXFLAGS_EXTRA ${MIRAKC_ARIB_TSDUCK_ARIB_CXXFLAGS})|set(MIRAKC_ARIB_TSDUCK_ARIB_CXXFLAGS_EXTRA "-Wno-error")|g' CMakeLists.txt || true
    fi

    echo "CMake 構成中..."
    cmake -S . -B build -G Ninja -D CMAKE_BUILD_TYPE=Release -DMIRAKC_ARIB_TSDUCK_ARIB_CXXFLAGS="-Wno-error" || {
        echo "ERROR: mirakc-arib の cmake 設定に失敗しました"
        exit 1
    }

    echo "vendor ターゲットをビルド中（tsduck-arib 等の取得・ビルド、数分かかります）..."
    VENDOR_OK=false
    for attempt in 1 2 3; do
        if ninja -C build vendor; then
            VENDOR_OK=true
            break
        fi
        echo "WARNING: vendor ビルド失敗 (試行 $attempt/3)。build をクリーンして再試行します..."
        rm -rf build
        cmake -S . -B build -G Ninja -D CMAKE_BUILD_TYPE=Release -DMIRAKC_ARIB_TSDUCK_ARIB_CXXFLAGS="-Wno-error" || true
    done

    if [ "$VENDOR_OK" != true ]; then
        echo "ERROR: mirakc-arib の vendor ビルドが複数回失敗しました"
        echo "手動で確認してください: cd $DTV_DIR/mirakc-arib && ninja -C build vendor"
        exit 1
    fi

    # vendor 完了検証
    TSDUCK_LIB=$(find build -iname "*tsduck*" -name "*.a" 2>/dev/null | head -1)
    if [ -z "$TSDUCK_LIB" ]; then
        echo "WARNING: vendor ビルド後に tsduck-arib のライブラリが見つかりません。続行します..."
    else
        echo "vendor ビルド完了を確認: $TSDUCK_LIB"
    fi

    # vendor 完了後に CMake キャッシュを再生成
    echo "CMake 再構成中（vendor 反映）..."
    cmake -S . -B build -G Ninja -D CMAKE_BUILD_TYPE=Release -DMIRAKC_ARIB_TSDUCK_ARIB_CXXFLAGS="-Wno-error" || {
        echo "ERROR: mirakc-arib の cmake 再設定に失敗しました"
        exit 1
    }

    echo "利用可能なターゲットを確認中..."
    # NOTE: head -5 がパイプを早期に閉じると上流(grep/ninja)が SIGPIPE で
    # 異常終了し、pipefail + set -e によりスクリプトが無言で停止するため
    # || true を付与する (表示専用の行であり失敗してもスクリプトを止めない)
    ninja -C build -t targets all 2>/dev/null | grep -i "mirakc\|arib" | head -5 || true

    echo "mirakc-arib 本体ビルド中..."
    if ! ninja -C build mirakc-arib; then
        echo "WARNING: 'mirakc-arib' ターゲットが見つかりません。build ターゲットを試行します..."
        if ! ninja -C build; then
            echo "ERROR: mirakc-arib のビルドに失敗しました"
            exit 1
        fi
    fi

    if [ ! -f build/bin/mirakc-arib ]; then
        echo "ERROR: build/bin/mirakc-arib が生成されませんでした"
        echo "build ディレクトリ内のバイナリを確認してください: find build -name 'mirakc-arib' -type f"
        exit 1
    fi

    sudo cp build/bin/mirakc-arib /usr/local/bin/mirakc-arib
    sudo chmod +x /usr/local/bin/mirakc-arib
    echo "mirakc-arib ビルド完了"
fi

# mirakc-arib の動作確認
if ! mirakc-arib --version > /dev/null 2>&1; then
    echo "ERROR: mirakc-arib が正常にインストールされていません。"
    exit 1
fi
echo "mirakc-arib インストール確認: $(mirakc-arib --version | head -1)"
fi

# ============================================================
# 6. キーの保存
# ============================================================
if [ "$RESCAN_ONLY" = false ]; then
echo "=== 5/9: キー保存 ==="
sudo mkdir -p /usr/local/etc
if [ "$USE_BACKUP_KEY" = true ]; then
    sudo cp "$BACKUP_BASE/key/bcas_keys" /usr/local/etc/bcas_keys
    echo "バックアップキーを復元しました"
else
    echo "$BCAS_CONTENT" | sudo tee /usr/local/etc/bcas_keys > /dev/null
fi

# キー読み込みテスト
echo "bcas_keys の内容を確認中..."
KEY_COUNT=$(grep -c '^Key\[' /usr/local/etc/bcas_keys 2>/dev/null || echo 0)
echo "  登録キー数: $KEY_COUNT"
if grep -q 'Key\[17\]' /usr/local/etc/bcas_keys 2>/dev/null; then
    echo "  CS (Key[17]) キー: OK"
else
    echo "  WARNING: CS (Key[17]) キーがありません。CS視聴はできません。"
fi
fi

# ============================================================
# 7. ISDBScanner 実行 (バックアップがあれば復元してスキャンを省略)
# ============================================================
echo "=== 6/9: チャンネルスキャン ==="
if [ ! -f /usr/local/bin/isdb-scanner ]; then
    sudo wget -q https://github.com/tsukumijima/ISDBScanner/releases/download/v1.3.3/isdb-scanner -O /usr/local/bin/isdb-scanner || {
        echo "ERROR: ISDBScanner のダウンロードに失敗しました"
        exit 1
    }
    sudo chmod +x /usr/local/bin/isdb-scanner
fi

# 既存の mirakc/EDCB を一旦止めてチューナーを解放する
# (稼働中の mirakc/EDCB がチューナーを掴んでいると ISDBScanner が
#  チューナーを開けず、サイレントに 0 件スキャンになることがある)
sudo systemctl stop mirakc 2>/dev/null || true
sudo systemctl stop edcb 2>/dev/null || true

# バックアップのスキャン結果があれば先に復元しておく。
# (この後の NEED_SCAN 判定が、復元したファイルを見て
#  自動的にスキャンを省略してくれる)
if [ "$RESCAN_ONLY" = false ] && [ "$USE_BACKUP_SCAN" = true ] && [ ! -d "$DTV_DIR/scanned" ]; then
    echo "バックアップからチャンネルスキャン結果を復元中（ISDBScannerの実行を省略）..."
    mkdir -p "$DTV_DIR/scanned"
    cp -a "$BACKUP_BASE/scanned/." "$DTV_DIR/scanned/"
fi

# --rescan-only の場合は強制的に再スキャンする。通常実行時は
# 既存のスキャン結果があれば使うが、中身が空/不正なら再スキャンする。
NEED_SCAN=true
if [ "$RESCAN_ONLY" = false ] && [ -f "$DTV_DIR/scanned/mirakc/config.yml" ]; then
    EXISTING_CH_COUNT=$(grep -c '^\s*- name:' "$DTV_DIR/scanned/mirakc/config.yml" 2>/dev/null || echo 0)
    if [ "$EXISTING_CH_COUNT" -gt 0 ]; then
        echo "既存のスキャン結果 (${EXISTING_CH_COUNT} チャンネル) を使用します。再スキャンする場合は $DTV_DIR/scanned を削除してから再実行してください。"
        NEED_SCAN=false
    fi
fi

if [ "$NEED_SCAN" = true ]; then
    echo "ISDBScanner を実行します（チューナーを使用してチャンネルスキャンを行うため数分かかります）..."
    rm -rf "$DTV_DIR/scanned"
    mkdir -p "$DTV_DIR/scanned"

    SCAN_LOG="/tmp/isdb-scanner.log"
    set +e
    timeout 600 isdb-scanner "$DTV_DIR/scanned/" 2>&1 | tee "$SCAN_LOG"
    SCAN_RC=${PIPESTATUS[0]}
    set -e

    if [ "$SCAN_RC" -ne 0 ]; then
        echo ""
        echo "ERROR: isdb-scanner が異常終了しました (終了コード: $SCAN_RC)"
        echo "ログ: $SCAN_LOG"
        echo ""
        echo "よくある原因:"
        echo "  - チューナーが他のプロセスに使用中 (mirakc/EDCB が起動していないか確認)"
        echo "  - チューナーが信号を受信できない (アンテナ線・B-CASカードの接触不良)"
        echo "  - bcas_keys が正しく設定されていない"
        echo ""
        echo "対処後、このスクリプトを '--rescan-only' オプション付きで再実行してください:"
        echo "  $RESCAN_CMD"
        exit 1
    fi
fi

# スキャン結果の検証: config.yml が存在し、かつチャンネルが1件以上あるか確認
if [ ! -f "$DTV_DIR/scanned/mirakc/config.yml" ]; then
    echo ""
    echo "ERROR: $DTV_DIR/scanned/mirakc/config.yml が生成されませんでした。"
    echo "ISDBScanner はチャンネルを検出できなかったか、出力先パスが想定と異なります。"
    echo "$DTV_DIR/scanned/ の内容を確認してください: find $DTV_DIR/scanned -type f"
    find "$DTV_DIR/scanned" -type f 2>/dev/null || true
    exit 1
fi

SCANNED_CH_COUNT=$(grep -c '^\s*- name:' "$DTV_DIR/scanned/mirakc/config.yml" 2>/dev/null || echo 0)
if [ "$SCANNED_CH_COUNT" -eq 0 ]; then
    echo ""
    echo "ERROR: スキャン結果に登録されたチャンネルが0件です。"
    echo "$DTV_DIR/scanned/mirakc/config.yml の内容を確認してください:"
    cat "$DTV_DIR/scanned/mirakc/config.yml" 2>/dev/null || true
    echo ""
    echo "チューナー/アンテナ線/B-CASキーを確認の上、再実行してください:"
    echo "  $RESCAN_CMD"
    exit 1
fi
echo "チャンネルスキャン完了: ${SCANNED_CH_COUNT} チャンネルを検出しました"

# ============================================================
# 8. mirakc ネイティブセットアップ (mirakc 4.x 対応)
# ============================================================
echo "=== 7/9: mirakc セットアップ ==="
MIRAKC_ETC="/etc/mirakc"
MIRAKC_DATA="/var/lib/mirakc/epg"
sudo mkdir -p "$MIRAKC_ETC" "$MIRAKC_DATA"

# バックアップの EPG/サービスキャッシュがあれば先に復元しておく
# (これにより、後段の「初回サービススキャン」を省略できる)
if [ "$USE_BACKUP_MIRAKC_EPG" = true ] && [ -d "$BACKUP_BASE/mirakc-epg" ]; then
    echo "バックアップから mirakc EPG/サービスキャッシュを復元中..."
    sudo cp -a "$BACKUP_BASE/mirakc-epg/." "$MIRAKC_DATA/"
    sudo chown -R "$REAL_USER:$REAL_USER" "$MIRAKC_DATA"
    echo "  -> 初回サービススキャンを省略します"
fi

# config.yml は必ず ISDBScanner の結果を使う。
# (ダミー設定へのフォールバックは廃止 — 上のスキャン検証で
#  0件の場合は既に exit している)
sudo cp "$DTV_DIR/scanned/mirakc/config.yml" "$MIRAKC_ETC/config.yml"

# scan-services / sync-clocks / update-schedules を無効化する。
# 旧版は既存の "disabled: false" 行を残したまま下に "disabled: true" を
# 追記してしまい、YAML 内に重複キーが残る不具合があったため、
# Python で安全にパースして上書きする。
python3 << PYEOF
import re

path = "$MIRAKC_ETC/config.yml"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# jobs: セクションが既に存在する場合は disabled の値を true に統一する
if re.search(r'^jobs:\s*$', content, re.MULTILINE):
    for job in ("scan-services", "sync-clocks", "update-schedules"):
        # "  job-name:\n    disabled: false" -> "  job-name:\n    disabled: true"
        pattern = re.compile(
            r'(^\s*' + re.escape(job) + r':\s*\n(?:\s+\S.*\n)*?\s*disabled:\s*)(true|false)',
            re.MULTILINE,
        )
        if pattern.search(content):
            content = pattern.sub(lambda m: m.group(1) + "true", content)
        else:
            # job 自体はあるが disabled 行がない場合は追加
            job_pattern = re.compile(r'(^\s*' + re.escape(job) + r':\s*\n)', re.MULTILINE)
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

print("jobs.*.disabled を true に設定しました")
PYEOF

# strings.yml をコピー (mirakc 4.x で必須)
if [ -f "$DTV_DIR/mirakc-src/resources/strings.yml" ]; then
    sudo cp "$DTV_DIR/mirakc-src/resources/strings.yml" "$MIRAKC_ETC/strings.yml"
elif [ "$USE_BACKUP_MIRAKC_BUILD" = true ] && [ -f "$BACKUP_BASE/mirakc/strings.yml" ]; then
    sudo cp "$BACKUP_BASE/mirakc/strings.yml" "$MIRAKC_ETC/strings.yml"
    echo "  -> strings.yml をバックアップから復元しました"
elif [ ! -f "$MIRAKC_ETC/strings.yml" ]; then
    echo "WARNING: strings.yml が見つかりません。"
fi

# tuners.*.command が ISDBScanner の出力したデバイスパスと一致しているか確認。
# 一致しない場合 (例: チューナーを差し替えた、デバイスノード名が変わった) は
# 検出済みの $TUNER_DEVICE に書き換える。
if ! grep -q "$TUNER_DEVICE" "$MIRAKC_ETC/config.yml"; then
    echo "WARNING: config.yml 内のチューナーデバイスパスが現在検出されているデバイス ($TUNER_DEVICE) と一致しません。"
    echo "  config.yml 内の記述:"
    grep -A2 "^tuners:" "$MIRAKC_ETC/config.yml" | head -10 || true
    echo "  自動置換は行いません。視聴できない場合は $MIRAKC_ETC/config.yml の tuners セクションを手動確認してください。"
fi

# update-epg.sh: 番組情報の手動更新スクリプト (Docker不使用)
cat > "$REAL_HOME/update-epg.sh" << UPDATEEPG
#!/bin/bash
# update-epg.sh - Manual EPG update script
# Run this when NOT watching TV (it will occupy the tuner for several minutes)
#
# Usage: sudo bash ~/update-epg.sh

set -e

echo "=== EPG Manual Update ==="
echo "WARNING: This will occupy the tuner for several minutes."
echo "Do NOT run this while watching TV."
echo ""

echo "[1/2] Syncing clocks..."
recisdb tune --device ${TUNER_DEVICE} --channel T27 - 2>/dev/null | timeout 30 mirakc-arib sync-clocks 2>&1 | head -20
echo ""

echo "[2/2] Collecting EIT data (番組情報更新)..."
recisdb tune --device ${TUNER_DEVICE} --channel T27 - 2>/dev/null | timeout 120 mirakc-arib collect-eits \$(cat /var/lib/mirakc/epg/services.json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
if isinstance(d, list):
    sids = [str(item[0] if isinstance(item, list) else item.get('id','')) for item in d[:200]]
    print(' '.join(['--sids=' + s for s in sids[:50]]))
elif isinstance(d, dict):
    sids = list(d.keys())[:50]
    print(' '.join(['--sids=' + str(s) for s in sids]))
" 2>/dev/null) 2>&1 | tail -5
echo ""
echo "=== EPG Update Complete ==="
UPDATEEPG
chmod +x "$REAL_HOME/update-epg.sh"

# mirakc systemd サービス
sudo tee /etc/systemd/system/mirakc.service > /dev/null << EOT
[Unit]
Description=mirakc TV Recorder
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$REAL_USER
Environment=MIRAKC_CONFIG=$MIRAKC_ETC/config.yml
ExecStart=/usr/local/bin/mirakc --config $MIRAKC_ETC/config.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOT

sudo systemctl daemon-reload
sudo systemctl enable mirakc
sudo systemctl restart mirakc

echo "mirakc 起動待機中..."
MIRAKC_READY=false
for i in $(seq 1 30); do
    if curl -s http://127.0.0.1:40772/api/tuners >/dev/null 2>&1; then
        echo "mirakc API 応答OK"
        MIRAKC_READY=true
        break
    fi
    sleep 2
    echo "  待機中... ($((i*2))秒経過)"
done

if [ "$MIRAKC_READY" = false ]; then
    echo "WARNING: mirakc が応答しません。ログを確認してください:"
    echo "  journalctl -u mirakc -n 50"
    sudo systemctl status mirakc --no-pager || true
fi

# ============================================================
# 初回サービススキャン
# (バックアップの mirakc EPG/サービスキャッシュを復元済みの場合は、
#  チューナーを占有する重いスキャン処理をスキップし、件数確認のみ行う)
# ============================================================
if [ "$MIRAKC_READY" = true ] && [ "$USE_BACKUP_MIRAKC_EPG" = false ]; then
    echo ""
    echo "=== 初回サービススキャンを実行します（チューナーを使用、数分かかります）==="

    sudo sed -i '/scan-services:/,/disabled:/ s/disabled: true/disabled: false/' "$MIRAKC_ETC/config.yml"
    sudo systemctl restart mirakc

    echo "mirakc 再起動待機中 (scan-services 有効)..."
    for i in $(seq 1 30); do
        if curl -s http://127.0.0.1:40772/api/tuners >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    SCAN_OK=false
    for i in $(seq 1 90); do
        API_SVC_COUNT=$(curl -s http://127.0.0.1:40772/api/services 2>/dev/null | grep -o '"id"' | wc -l || echo 0)
        if [ "$API_SVC_COUNT" -gt 0 ]; then
            echo "サービススキャン完了: ${API_SVC_COUNT} 件のサービスを検出"
            SCAN_OK=true
            break
        fi
        sleep 5
        echo "  スキャン中... ($((i*5))秒経過)"
    done

    if [ "$SCAN_OK" != true ]; then
        echo "WARNING: サービススキャンがタイムアウトしました。services が0件のままです。"
        echo "  mirakc のログを確認してください: journalctl -u mirakc -n 100"
        echo "  手動再試行: docker 不使用のため、以下を実行してください:"
        echo "    sudo systemctl restart mirakc"
        echo "    curl http://127.0.0.1:40772/api/services"
    fi

    # scan-services を無効化に戻して再起動 (起動時にチューナーを毎回占有しないようにする)
    sudo sed -i '/scan-services:/,/disabled:/ s/disabled: false/disabled: true/' "$MIRAKC_ETC/config.yml"
    sudo systemctl restart mirakc

    echo "mirakc 再起動待機中 (scan-services 無効化に戻す)..."
    MIRAKC_READY=false
    for i in $(seq 1 30); do
        if curl -s http://127.0.0.1:40772/api/tuners >/dev/null 2>&1; then
            MIRAKC_READY=true
            break
        fi
        sleep 2
    done

    # スキャンで取得した services が再起動後も保持されているか確認
    if [ "$MIRAKC_READY" = true ]; then
        API_SVC_COUNT=$(curl -s http://127.0.0.1:40772/api/services 2>/dev/null | grep -o '"id"' | wc -l || echo 0)
        echo "mirakc API 上のサービス件数 (scan-services 無効化後): ${API_SVC_COUNT}"
        if [ "$API_SVC_COUNT" -eq 0 ] && [ "$SCAN_OK" = true ]; then
            echo "WARNING: スキャン直後は services を検出していましたが、再起動後に0件になりました。"
            echo "  /var/lib/mirakc/epg/ 以下のキャッシュファイルの権限・永続化を確認してください:"
            ls -la /var/lib/mirakc/epg/ 2>/dev/null || true
        fi
    fi
elif [ "$MIRAKC_READY" = true ] && [ "$USE_BACKUP_MIRAKC_EPG" = true ]; then
    API_SVC_COUNT=$(curl -s http://127.0.0.1:40772/api/services 2>/dev/null | grep -o '"id"' | wc -l || echo 0)
    echo "mirakc API 上のサービス件数 (バックアップから復元、初回スキャン省略): ${API_SVC_COUNT}"
    if [ "$API_SVC_COUNT" -eq 0 ]; then
        echo "WARNING: バックアップを復元しましたがサービスが0件です。"
        echo "  手動でスキャンしてください: $RESCAN_CMD"
    fi
fi

# ============================================================
# 9. EDCB (EpgTimerSrv) のセットアップ
# ============================================================
if [ "$RESCAN_ONLY" = false ]; then
echo "=== 8/9: EDCB セットアップ ==="
cd "$DTV_DIR"
if [ ! -d "EDCB" ]; then
    git clone https://github.com/xtne6f/EDCB || {
        echo "ERROR: EDCB のクローンに失敗しました"
        exit 1
    }
fi
cd EDCB/Document/Unix
make -j"$(nproc)" || {
    echo "WARNING: EDCB ビルドでエラーが発生しました。続行します..."
}
sudo make install || true
make extra || true
sudo make install_extra || true

# EDCB lua ライブラリ修正
EDCB_LUA_DIR=$(find "$DTV_DIR/EDCB" -path "*/EpgTimerSrv/EpgTimerSrv" -type d 2>/dev/null | head -1)
if [ -n "$EDCB_LUA_DIR" ]; then
    ln -sf /usr/lib/x86_64-linux-gnu/liblua5.2.so "$EDCB_LUA_DIR/" 2>/dev/null || true
    ln -sf /usr/lib/x86_64-linux-gnu/liblua5.2.a "$EDCB_LUA_DIR/" 2>/dev/null || true
    cd "$EDCB_LUA_DIR" && make -j"$(nproc)" 2>/dev/null || true
    cd "$DTV_DIR/EDCB/Document/Unix"
    sudo make install 2>/dev/null || true
fi

sudo mkdir -p /var/local/edcb
sudo chown -R "$REAL_USER:$REAL_USER" /var/local/edcb
make setup_ini || true

# EMWUI
cd "$DTV_DIR"
if [ ! -d "EDCB_Material_WebUI" ]; then
    git clone https://github.com/EMWUI/EDCB_Material_WebUI || {
        echo "WARNING: EDCB_Material_WebUI のクローンに失敗しました"
    }
fi
if [ -d "EDCB_Material_WebUI" ]; then
    sudo cp -r EDCB_Material_WebUI/HttpPublic /var/local/edcb/ 2>/dev/null || true
    sudo cp -r EDCB_Material_WebUI/Setting    /var/local/edcb/ 2>/dev/null || true
fi

# BonDriver_LinuxMirakc
cd "$DTV_DIR"
if [ ! -d "BonDriver_LinuxMirakc" ]; then
    git clone https://github.com/matching/BonDriver_LinuxMirakc.git --recurse-submodules || {
        echo "WARNING: BonDriver_LinuxMirakc のクローンに失敗しました"
    }
fi
if [ -d "BonDriver_LinuxMirakc" ]; then
    cd BonDriver_LinuxMirakc

    if [ -f "src/BonDriver_LinuxMirakc.cpp" ]; then
        python3 << 'PYEOF' || true
with open('src/BonDriver_LinuxMirakc.cpp', 'r') as f:
    content = f.read()
content = content.replace('char szHeader[ 64 ];', 'char szHeader[ 256 ];')
import re
content = re.sub(r'char szHeader\[len\];', 'char szHeader[256];', content)
old = 'sprintf(szHeader, "Connection: close\\r\\nX-Mirakurun-Priority: %d", g_Priority);'
new = 'sprintf(szHeader, "Host: %s:%d\\r\\nConnection: close\\r\\nX-Mirakurun-Priority: %d", g_ServerHost, g_ServerPort, g_Priority);'
content = content.replace(old, new)
with open('src/BonDriver_LinuxMirakc.cpp', 'w') as f:
    f.write(content)
PYEOF
    fi

    make -j"$(nproc)" || {
        echo "WARNING: BonDriver_LinuxMirakc のビルドに失敗しました"
    }
    if [ -f "BonDriver_LinuxMirakc.so" ]; then
        sudo cp BonDriver_LinuxMirakc.so /usr/local/lib/edcb/
    fi
fi

sudo tee /usr/local/lib/edcb/BonDriver_LinuxMirakc.so.ini > /dev/null << 'EOT'
[GLOBAL]
SERVER_HOST="127.0.0.1"
SERVER_PORT=40772
SERVER_TYPE="http"
DECODE_B25=1
PRIORITY=10
SERVICE_SPLIT=0
EOT

# スキャン結果のコピー（存在する場合のみ）
if [ -f "$DTV_DIR/scanned/EDCB-Wine/ChSet5.txt" ]; then
    cp "$DTV_DIR/scanned/EDCB-Wine/ChSet5.txt" /var/local/edcb/Setting/ 2>/dev/null || true
fi
if [ -f "$DTV_DIR/scanned/EDCB-Wine/BonDriver_mirakc(BonDriver_mirakc).ChSet4.txt" ]; then
    cp "$DTV_DIR/scanned/EDCB-Wine/BonDriver_mirakc(BonDriver_mirakc).ChSet4.txt" \
       "/var/local/edcb/Setting/BonDriver_LinuxMirakc(LinuxMirakc).ChSet4.txt" 2>/dev/null || true
fi

if [ -f /var/local/edcb/HttpPublic/legacy/util.lua ]; then
    sed -i -e 's/^ALLOW_SETTING=.*/ALLOW_SETTING=true/' /var/local/edcb/HttpPublic/legacy/util.lua
fi

# ------------------------------------------------------------
# 録画フォルダのセットアップ
# ホスト側のマウントポイント /opt/lxd-data/tv を
# /var/local/edcb/HttpPublic/video にバインドマウントする
#
# /opt/lxd-data はホストが所有するディレクトリのため、
# コンテナ内から直接 mkdir できない場合がある。
# 存在しない場合は警告を表示して処理を継続する。
# ------------------------------------------------------------
RECORD_SRC="/opt/lxd-data/tv"
RECORD_DST="/var/local/edcb/HttpPublic/video"
echo "録画フォルダをセットアップ中: $RECORD_SRC -> $RECORD_DST"

# 録画先ディレクトリ（コンテナ内側）は必ず作成する
sudo mkdir -p "$RECORD_DST"

# ソース側（ホストマウントポイント）は存在する場合のみ処理する
if [ -d "$RECORD_SRC" ]; then
    if grep -q "$RECORD_DST" /etc/fstab; then
        echo "fstab: $RECORD_DST は既に登録済みのためスキップします"
    else
        echo "$RECORD_SRC $RECORD_DST none bind 0 0" | sudo tee -a /etc/fstab > /dev/null
        echo "fstab: $RECORD_DST を登録しました"
    fi

    if mountpoint -q "$RECORD_DST"; then
        echo "バインドマウント: $RECORD_DST は既にマウント済みです"
    else
        sudo mount --bind "$RECORD_SRC" "$RECORD_DST"
        echo "バインドマウント: $RECORD_DST をマウントしました"
    fi
else
    echo "警告: $RECORD_SRC が存在しないためバインドマウントをスキップします。"
    echo "  ホスト側でディレクトリを作成してから手動でマウントしてください。"
    echo "  例（ホスト側）: sudo mkdir -p $RECORD_SRC"
    echo "  例（コンテナ内）: sudo mount --bind $RECORD_SRC $RECORD_DST"
fi

# 録画先の所有者を実行ユーザーに設定する（EDCB からの書き込みを可能にする）
sudo chown -R "$REAL_USER:$REAL_USER" "$RECORD_DST" 2>/dev/null || true

# チューナー数の自動検出
ISDB_DEV_COUNT=$(ls /dev/isdb2056video* 2>/dev/null | wc -l || echo 0)
PX4_DEV_COUNT=$(ls /dev/px4video* 2>/dev/null | wc -l || echo 0)
if [ "$ISDB_DEV_COUNT" -gt 0 ]; then
    TUNER_COUNT="$ISDB_DEV_COUNT"
elif [ "$PX4_DEV_COUNT" -gt 0 ]; then
    TUNER_COUNT=$(( PX4_DEV_COUNT / 4 ))
    [ "$TUNER_COUNT" -eq 0 ] && TUNER_COUNT=1
else
    TUNER_COUNT=1
fi
echo "検出チューナー数: ${TUNER_COUNT}"

sudo tee /var/local/edcb/EpgTimerSrv.ini > /dev/null << EOT
[SET]
EnableHttpSrv=1
EnableTCPSrv=1
RecEndMode=0
Data=1
HttpAccessControlList=+127.0.0.0/8,+10.0.0.0/8,+172.16.0.0/12,+192.168.0.0/16,+169.254.0.0/16,+100.64.0.0/10
CompatFlags=128
[BonDriver_LinuxMirakc.so]
Count=${TUNER_COUNT}
GetEpg=1
EPGCount=0
Priority=0
EOT

sudo tee /var/local/edcb/Common.ini > /dev/null << 'EOT'
[SET]
RecFolderPath0=/var/local/edcb/HttpPublic/video
RecFolderNum=1
EOT

sudo tee /var/local/edcb/EpgDataCap_Bon.ini > /dev/null << 'EOT'
[SET]
BonDriverDllPath=/usr/local/lib/edcb
EOT

# EDCB サービス (Docker依存なし)
sudo tee /etc/systemd/system/edcb.service > /dev/null << EOT
[Unit]
Description=EpgTimerSrv
After=network-online.target mirakc.service
Requires=mirakc.service
[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=/usr/local/lib/edcb
ExecStart=/usr/local/bin/EpgTimerSrv
Restart=always
[Install]
WantedBy=default.target
EOT

sudo systemctl daemon-reload
sudo systemctl enable edcb
sudo systemctl restart edcb

# ============================================================
# EPG 受信開始 (バックアップがあれば復元し、受信はスキップ)
# ============================================================
if [ "$USE_BACKUP_EPG" = true ] && [ -n "$BACKUP_BASE" ] && [ -d "$BACKUP_BASE/epg" ] && [ -n "$(ls -A "$BACKUP_BASE/epg" 2>/dev/null)" ]; then
    echo ""
    echo "=== バックアップから EDCB EPG データを復元中 ==="
    EPG_DST="/var/local/edcb/Setting/EpgData"
    mkdir -p "$EPG_DST"
    cp -a "$BACKUP_BASE/epg"/* "$EPG_DST/"
    EPG_RESTORED=$(ls "$EPG_DST" 2>/dev/null | wc -l || echo 0)
    echo "  -> EPG データを復元しました ($EPG_RESTORED ファイル)"
else
    echo ""
    echo "=== EPG 受信を開始します ==="
    (
        echo "EDCBの起動を待機中..."
        for i in $(seq 1 60); do
            if curl -sf "http://127.0.0.1:5510/legacy/index.html" -o /dev/null 2>/dev/null; then
                echo "EDCB: 起動確認 (${i}秒)"
                break
            fi
            sleep 1
        done
        sleep 5

        echo "EPG取得リクエストを送信中..."
        CTOK=$(curl -s http://127.0.0.1:5510/legacy/index.html \
            | grep -o 'name="ctok" value="[^"]*"' | head -1 \
            | grep -o 'value="[^"]*"' | cut -d'"' -f2)
        RESULT=$(curl -s -X POST "http://127.0.0.1:5510/legacy/index.html" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "ctok=${CTOK}&epgcap=y" \
            | grep -o 'id="result">[^<]*')
        if echo "$RESULT" | grep -q "開始しました"; then
            echo "EPG受信: 開始しました"
        else
            echo "警告: EPG取得リクエストの応答: $RESULT"
        fi
    ) >> /var/log/dtv_epg_start.log 2>&1 &
    echo "EPG受信をバックグラウンドで開始しました（KonomiTVインストール中に受信進行中）"
    echo "進捗ログ: tail -f /var/log/dtv_epg_start.log"
fi
fi

# ============================================================
# 10. KonomiTV インストール
# ============================================================
if [ "$RESCAN_ONLY" = false ]; then
echo "=== 9/9: KonomiTV インストール ==="

# pm2 のインストール (sudo用PATH対応)
sudo npm install -g pm2 || {
    echo "WARNING: pm2 のインストールに失敗しました"
}
PM2_BIN=$(find /usr/local/lib/node_modules -name "pm2" -path "*/bin/*" -type f 2>/dev/null | head -1)
if [ -n "$PM2_BIN" ]; then
    PM2_BIN="$(readlink -f "$PM2_BIN")"
    sudo rm -f /usr/local/bin/pm2
    sudo ln -s "$PM2_BIN" /usr/local/bin/pm2
    sudo chmod +x "$PM2_BIN"
fi
echo "pm2: $(/usr/local/bin/pm2 --version 2>/dev/null || echo 'not found')"

cd "$DTV_DIR"
if [ ! -f KonomiTV-Installer.elf ]; then
    curl -LO https://github.com/tsukumijima/KonomiTV/releases/latest/download/KonomiTV-Installer.elf || {
        echo "ERROR: KonomiTV インストーラーのダウンロードに失敗しました"
        exit 1
    }
    chmod +x KonomiTV-Installer.elf
fi

if ! command -v expect &> /dev/null; then
    sudo apt install -y expect
fi

INSTALLER_PATH="$DTV_DIR/KonomiTV-Installer.elf"
if ! expect << EXPECT_EOF
set timeout 600
log_file /tmp/konomi_install.log

spawn $INSTALLER_PATH

expect -re {\[1/2/3/4/5\].*:} { send "1\r" }
expect -re {フォルダのパス:} { send "/opt/KonomiTV\r" }
expect -re {\[EDCB/Mirakurun\].*:} { send "EDCB\r" }
expect -re {TCP API の URL:} { send "tcp://127.0.0.1:4510/\r" }
expect -re {\[FFmpeg.*\].*:} { send "FFmpeg\r" }
expect -re {録画フォルダのパス:} { send "/var/local/edcb/HttpPublic/video\r" }
expect -re {録画フォルダのパス:} { send "\r" }
expect -re {キャプチャ画像の保存先フォルダのパス:} { send "/var/local/edcb/HttpPublic/video\r" }
expect -re {キャプチャ画像の保存先フォルダのパス:} { send "\r" }

expect eof
EXPECT_EOF
then
    echo "WARNING: KonomiTV の自動インストールで問題が発生しました"
    echo "手動でインストールしてください: cd $DTV_DIR && sudo ./KonomiTV-Installer.elf"
fi

KONOMI_CONFIG="/opt/KonomiTV/config.yaml"
if [ ! -f "$KONOMI_CONFIG" ]; then
    KONOMI_CONFIG=$(find /opt /usr/local /home -name "config.yaml" -path "*/KonomiTV/*" 2>/dev/null | head -1)
fi

if [ -z "$KONOMI_CONFIG" ] || [ ! -f "$KONOMI_CONFIG" ]; then
    KONOMI_CONFIG=$(find /opt /usr/local /home -name "config.yml" -path "*/KonomiTV/*" 2>/dev/null | head -1)
fi

if [ -z "$KONOMI_CONFIG" ]; then
    echo "WARNING: KonomiTV の config.yaml が見つかりませんでした。"
    echo "手動で設定ファイルを確認してください。"
else
    echo "KonomiTV config.yaml を更新中: $KONOMI_CONFIG"
    sudo sed -i 's/always_receive_tv_from_mirakurun: false/always_receive_tv_from_mirakurun: true/' "$KONOMI_CONFIG" || true
    sudo /usr/local/bin/pm2 restart KonomiTV 2>/dev/null || sudo /usr/local/bin/pm2 start KonomiTV 2>/dev/null || {
        echo "WARNING: KonomiTV の再起動に失敗しました。手動で再起動してください。"
    }
fi

fi

# --rescan-only の場合は KonomiTV も再起動してチャンネル一覧を再取得させる
if [ "$RESCAN_ONLY" = true ]; then
    echo "KonomiTV を再起動してチャンネル一覧を再取得させます..."
    sudo /usr/local/bin/pm2 restart KonomiTV 2>/dev/null || true
fi

# ============================================================
# 完了
# ============================================================

CONTAINER_NAME=$(hostname 2>/dev/null || echo "localhost")
KONOMI_URLS=()
KONOMI_URLS+=("https://my.local.konomi.tv:7000/|ローカルホスト")
while read -r addr iface; do
    IP=$(echo "$addr" | cut -d/ -f1)
    [ -z "$IP" ] || [ "$IP" = "127.0.0.1" ] && continue
    IP_DASH=$(echo "$IP" | tr '.' '-')
    KONOMI_URLS+=("https://${IP_DASH}.local.konomi.tv:7000/|${iface}")
done < <(ip -4 addr show | awk '/inet / {print $2, $NF}')

echo ""
echo "============================================================"
echo " セットアップ完了 (GitHub版)"
echo "============================================================"
echo ""
echo " サービス:"
echo "   mirakc:   http://127.0.0.1:40772/"
echo " EDCB Web:"
echo "   http://${CONTAINER_NAME}:5510/"
echo ""
echo " KonomiTV:"
for entry in "${KONOMI_URLS[@]}"; do
    URL="${entry%%|*}"
    LABEL="${entry##*|}"
    printf "   %-52s (%s)\n" "$URL" "$LABEL"
done
echo ""
echo " サービス操作:"
echo "   mirakc 再起動:    sudo systemctl restart mirakc"
echo "   EDCB 再起動:      sudo systemctl restart edcb"
echo "   KonomiTV 再起動:  sudo pm2 restart KonomiTV"
echo ""
echo " チャンネルが表示されない場合の再スキャン:"
echo "   $RESCAN_CMD"
echo ""
echo " EPG取得状況の確認（.tmpが無くなれば完了）:"
echo "   ls /var/local/edcb/Setting/EpgData"
echo ""
echo " BCASキーの再設定:"
echo "   sudo nano /usr/local/etc/bcas_keys"
echo "   sudo systemctl restart mirakc"
echo ""
echo " 番組情報の更新 (視聴していない時に実行):"
echo "   sudo bash ~/update-epg.sh"
echo ""
echo " EPG:"
echo "   確認:       ls /var/local/edcb/Setting/EpgData"
echo "   ログ:       tail -f /var/log/dtv_epg_start.log"
echo "   インストールログ: tail -f $LOG_FILE"
echo "============================================================"
