#!/bin/sh
# Универсальная установка сжатых awg-manager + sing-box
# Репозиторий: https://github.com/rndnaame/awg-compressed
#
# Запуск на роутере:
#   curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
#   wget -qO- https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
#
# Без вопросов (для скриптов):
#   INSTALL_AWG=1 INSTALL_SB=0 sh install-compressed.sh
#   INSTALL_AWG=0 INSTALL_SB=1 sh install-compressed.sh
#   INSTALL_AWG=1 INSTALL_SB=1 sh install-compressed.sh

set -e

REPO="rndnaame/awg-compressed"
TAG="compressed"
TMP="/tmp/awg-compressed-install"
SINGBOX_DIR="/opt/etc/awg-manager/singbox"

# чтение с терминала даже при curl | sh
ask() {
  prompt="$1"
  default="$2"
  if [ -r /dev/tty ]; then
    printf "%s" "$prompt" > /dev/tty
    read -r answer < /dev/tty || answer="$default"
  else
    answer="$default"
  fi
  echo "$answer"
}

echo "=== Установка compressed AWG + sing-box ==="
echo ""

# --- архитектура ---
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
    opkg print-architecture 2>/dev/null || true
    exit 1
    ;;
esac
echo "✅ Архитектура: $A → $ARCH"
echo ""

# --- что уже установлено ---
CUR_AWG=$(opkg list-installed 2>/dev/null | awk '/^awg-manager /{print $3; exit}')
if [ -z "$CUR_AWG" ]; then
  CUR_AWG="не установлен"
fi

CUR_SB="не найден"
if [ -x "$SINGBOX_DIR/sing-box" ]; then
  CUR_SB=$("$SINGBOX_DIR/sing-box" version 2>/dev/null | head -1 || echo "есть (версия неизвестна)")
elif command -v sing-box >/dev/null 2>&1; then
  CUR_SB=$(sing-box version 2>/dev/null | head -1 || echo "есть (версия неизвестна)")
fi

echo "Сейчас на роутере:"
echo "   awg-manager : $CUR_AWG"
echo "   sing-box    : $CUR_SB"
echo ""

# --- список ассетов ---
echo "→ Получаем список файлов из релиза..."
ASSETS=""
ASSETS=$(curl -sL "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" 2>/dev/null \
  | grep -oE '"browser_download_url":\s*"[^"]+"' \
  | sed 's/.*"\([^"]*\)"/\1/' || true)

if [ -z "$ASSETS" ]; then
  echo "   API недоступен, пробуем HTML..."
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

IPK_URL=$(echo "$ASSETS" | grep -E "$IPK_PAT" | head -1)
SB_URL=$(echo "$ASSETS" | grep -E "$SB_PAT" | head -1)

IPK_NAME="—"
SB_NAME="—"
[ -n "$IPK_URL" ] && IPK_NAME=$(basename "$IPK_URL")
[ -n "$SB_URL" ] && SB_NAME=$(basename "$SB_URL")

echo "Доступно в релизе ($TAG):"
echo "   IPK      : $IPK_NAME"
echo "   sing-box : $SB_NAME"
echo ""

# --- выбор: env или интерактивно ---
DO_AWG=""
DO_SB=""

if [ -n "$INSTALL_AWG" ] || [ -n "$INSTALL_SB" ]; then
  # неинтерактивный режим через переменные
  DO_AWG=${INSTALL_AWG:-0}
  DO_SB=${INSTALL_SB:-0}
else
  echo "Что установить?"
  echo "  [1] Только awg-manager"
  echo "  [2] Только sing-box"
  echo "  [3] Оба (awg-manager + sing-box)"
  echo "  [0] Отмена"
  echo ""
  choice=$(ask "Выбор [0-3], по умолчанию 3: " "3")
  case "$choice" in
    1) DO_AWG=1; DO_SB=0 ;;
    2) DO_AWG=0; DO_SB=1 ;;
    3|"") DO_AWG=1; DO_SB=1 ;;
    0|n|N|q|Q)
      echo "Отменено."
      exit 0
      ;;
    *)
      echo "Неверный выбор, отмена."
      exit 1
      ;;
  esac
fi

# подтверждение, если awg уже стоит
if [ "$DO_AWG" = "1" ] && [ "$CUR_AWG" != "не установлен" ]; then
  conf=$(ask "awg-manager уже установлен ($CUR_AWG). Переустановить? [y/N]: " "n")
  case "$conf" in
    y|Y|yes|YES) ;;
    *)
      echo "→ awg-manager пропущен"
      DO_AWG=0
      ;;
  esac
fi

if [ "$DO_SB" = "1" ] && [ "$CUR_SB" != "не найден" ]; then
  conf=$(ask "sing-box уже есть ($CUR_SB). Заменить? [y/N]: " "n")
  case "$conf" in
    y|Y|yes|YES) ;;
    *)
      echo "→ sing-box пропущен"
      DO_SB=0
      ;;
  esac
fi

if [ "$DO_AWG" != "1" ] && [ "$DO_SB" != "1" ]; then
  echo "Нечего устанавливать. Выход."
  exit 0
fi

mkdir -p "$TMP"
cd "$TMP"
rm -f ./* 2>/dev/null || true

# --- awg-manager ---
if [ "$DO_AWG" = "1" ]; then
  if [ -z "$IPK_URL" ]; then
    echo "❌ IPK для $ARCH не найден в релизе"
    exit 1
  fi
  echo ""
  echo "⬇ Скачиваем $IPK_NAME ..."
  wget -q --show-progress -O "$IPK_NAME" "$IPK_URL" 2>/dev/null \
    || wget -q -O "$IPK_NAME" "$IPK_URL" \
    || curl -sL -o "$IPK_NAME" "$IPK_URL"
  if [ ! -s "$IPK_NAME" ]; then
    echo "❌ Ошибка скачивания IPK"
    exit 1
  fi
  echo "📦 Установка $IPK_NAME ..."
  opkg install --force-reinstall "./$IPK_NAME" || opkg install "./$IPK_NAME"
  echo "✅ awg-manager установлен"
fi

# --- sing-box ---
if [ "$DO_SB" = "1" ]; then
  if [ -z "$SB_URL" ]; then
    echo "⚠ sing-box для $ARCH в релизе нет — пропуск"
  else
    echo ""
    echo "⬇ Скачиваем $SB_NAME ..."
    wget -q --show-progress -O "$SB_NAME" "$SB_URL" 2>/dev/null \
      || wget -q -O "$SB_NAME" "$SB_URL" \
      || curl -sL -o "$SB_NAME" "$SB_URL"
    if [ -s "$SB_NAME" ]; then
      mkdir -p "$SINGBOX_DIR"
      cp "$SB_NAME" "$SINGBOX_DIR/sing-box"
      chmod +x "$SINGBOX_DIR/sing-box"
      echo "✅ sing-box → $SINGBOX_DIR/sing-box"
      "$SINGBOX_DIR/sing-box" version 2>/dev/null | head -1 || true
    else
      echo "❌ Ошибка скачивания sing-box"
      exit 1
    fi
  fi
fi

echo ""
echo "=== Готово ($ARCH) ==="
[ "$DO_AWG" = "1" ] && echo "   awg-manager: $IPK_NAME"
[ "$DO_SB" = "1" ] && echo "   sing-box:    $SINGBOX_DIR/sing-box"

rm -rf "$TMP"
echo "Временные файлы удалены."
