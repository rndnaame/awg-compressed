#!/bin/sh
# Универсальная установка сжатых awg-manager + sing-box
# Репозиторий: https://github.com/rndnaame/awg-compressed
# Запуск на роутере:
#   curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
# или:
#   wget -qO- https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh

set -e

REPO="rndnaame/awg-compressed"
TAG="compressed"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
TMP="/tmp/awg-compressed-install"
SINGBOX_DIR="/opt/etc/awg-manager/singbox"

echo "=== Установка compressed AWG + sing-box ==="

# --- определение архитектуры ---
A=$(opkg print-architecture 2>/dev/null | sort -k3 -nr | awk '$2!="all"{print $2;exit}')
case "$A" in
  aarch64*|arm*)
    ARCH=aarch64
    IPK_PAT="awg-manager_.*_aarch64-3.10-kn_compressed\\.ipk"
    SB_PAT="singbox-.*-aarch64-3.10_compressed"
    ;;
  mipsel*)
    ARCH=mipsel
    IPK_PAT="awg-manager_.*_mipsel-3.4-kn_compressed\\.ipk"
    SB_PAT="singbox-.*-mipsel-3.4_compressed"
    ;;
  mips*)
    ARCH=mips
    IPK_PAT="awg-manager_.*_mips-3.4-kn_compressed\\.ipk"
    SB_PAT="singbox-.*-mips-3.4_compressed"
    ;;
  *)
    echo "❌ Неизвестная архитектура: ${A:-пусто}"
    echo "   opkg print-architecture:"
    opkg print-architecture 2>/dev/null || true
    exit 1
    ;;
esac

echo "✅ Архитектура: $A → $ARCH"

mkdir -p "$TMP"
cd "$TMP"
rm -f ./* 2>/dev/null || true

# --- список ассетов релиза (API → HTML fallback) ---
ASSETS=""
ASSETS=$(curl -sL "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" 2>/dev/null \
  | grep -oE '"browser_download_url":\s*"[^"]+"' \
  | sed 's/.*"\([^"]*\)"/\1/' || true)

if [ -z "$ASSETS" ]; then
  echo "API недоступен, пробуем HTML..."
  ASSETS=$(curl -sL "https://github.com/${REPO}/releases/expanded_assets/${TAG}" 2>/dev/null \
    | grep -oE 'href="[^"]*releases/download/[^"]+"' \
    | sed 's/href="//;s/"$//' \
    | while read -r p; do
        case "$p" in
          http*) echo "$p" ;;
          /*) echo "https://github.com$p" ;;
        esac
      done || true)
fi

if [ -z "$ASSETS" ]; then
  echo "❌ Не удалось получить список файлов из $REPO ($TAG)"
  exit 1
fi

# --- выбор файлов под архитектуру ---
IPK_URL=$(echo "$ASSETS" | grep -E "$IPK_PAT" | head -1)
SB_URL=$(echo "$ASSETS" | grep -E "$SB_PAT" | head -1)

if [ -z "$IPK_URL" ]; then
  echo "❌ IPK для $ARCH не найден в релизе"
  echo "Доступные файлы:"
  echo "$ASSETS" | sed 's|.*/||' | sed 's/^/  /'
  exit 1
fi

IPK_FILE=$(basename "$IPK_URL")
echo "⬇ IPK: $IPK_FILE"
wget -q --show-progress -O "$IPK_FILE" "$IPK_URL" 2>/dev/null || wget -q -O "$IPK_FILE" "$IPK_URL" || curl -sL -o "$IPK_FILE" "$IPK_URL"

if [ ! -s "$IPK_FILE" ]; then
  echo "❌ Ошибка скачивания IPK"
  exit 1
fi

echo "📦 Установка $IPK_FILE ..."
opkg install --force-reinstall "./$IPK_FILE" || opkg install "./$IPK_FILE"

# --- sing-box (опционально) ---
if [ -n "$SB_URL" ]; then
  SB_FILE=$(basename "$SB_URL")
  echo "⬇ sing-box: $SB_FILE"
  wget -q --show-progress -O "$SB_FILE" "$SB_URL" 2>/dev/null || wget -q -O "$SB_FILE" "$SB_URL" || curl -sL -o "$SB_FILE" "$SB_URL"
  if [ -s "$SB_FILE" ]; then
    mkdir -p "$SINGBOX_DIR"
    cp "$SB_FILE" "$SINGBOX_DIR/sing-box"
    chmod +x "$SINGBOX_DIR/sing-box"
    echo "✅ sing-box → $SINGBOX_DIR/sing-box"
  else
    echo "⚠ sing-box не скачался — пропуск"
  fi
else
  echo "⚠ sing-box для $ARCH в релизе нет — пропуск"
fi

echo ""
echo "✅ Готово ($ARCH)"
echo "   IPK: $IPK_FILE"
[ -n "$SB_URL" ] && echo "   sing-box: $SINGBOX_DIR/sing-box"
echo ""
echo "Очистка временных файлов..."
rm -rf "$TMP"
echo "Готово."
