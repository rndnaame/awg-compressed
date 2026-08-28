#!/bin/sh
# Универсальная установка сжатых awg-manager + sing-box
# Репозиторий: https://github.com/rndnaame/awg-compressed
#
# Запуск:
#   curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
#
# Без вопросов:
#   INSTALL_AWG=1 INSTALL_SB=0 sh -c "$(curl -sL .../install-compressed.sh)"
#   INSTALL_AWG=0 INSTALL_SB=1 ...

set -e

REPO="rndnaame/awg-compressed"
TAG="compressed"
TMP="/tmp/awg-compressed-install"
SINGBOX_DIR="/opt/etc/awg-manager/singbox"

ask() {
  prompt="$1"
  default="$2"
  if [ -r /dev/tty ]; then
    printf "%s" "$prompt" > /dev/tty
    read -r answer < /dev/tty || answer="$default"
  else
    answer="$default"
  fi
  [ -z "$answer" ] && answer="$default"
  echo "$answer"
}

yes_no() {
  # $1 prompt, $2 default y|n → echo 1 or 0
  prompt="$1"
  default="$2"
  a=$(ask "$prompt" "$default")
  case "$a" in
    y|Y|yes|YES) echo 1 ;;
    *) echo 0 ;;
  esac
}

# сравнение версий: 0 = equal, 1 = v1 > v2, 2 = v1 < v2
ver_cmp() {
  v1="$1"
  v2="$2"
  [ "$v1" = "$v2" ] && { echo 0; return; }
  # sort -V: меньшая первая
  first=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -1)
  if [ "$first" = "$v1" ]; then
    echo 2
  else
    echo 1
  fi
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

# --- текущие версии ---
CUR_AWG=$(opkg list-installed 2>/dev/null | awk '/^awg-manager /{print $3; exit}')
[ -z "$CUR_AWG" ] && CUR_AWG=""

CUR_SB_RAW=""
CUR_SB_VER=""
if [ -x "$SINGBOX_DIR/sing-box" ]; then
  CUR_SB_RAW=$("$SINGBOX_DIR/sing-box" version 2>/dev/null | head -1 || true)
elif command -v sing-box >/dev/null 2>&1; then
  CUR_SB_RAW=$(sing-box version 2>/dev/null | head -1 || true)
fi
# вытащить что-то вроде 1.14.0-rc.1 или 1.14.0-rc.1-awgm.14
if [ -n "$CUR_SB_RAW" ]; then
  CUR_SB_VER=$(echo "$CUR_SB_RAW" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*' | head -1 || true)
fi

echo "Сейчас на роутере:"
if [ -n "$CUR_AWG" ]; then
  echo "   awg-manager : $CUR_AWG"
else
  echo "   awg-manager : не установлен"
fi
if [ -n "$CUR_SB_RAW" ]; then
  echo "   sing-box    : $CUR_SB_RAW"
else
  echo "   sing-box    : не найден"
fi
echo ""

# --- ассеты ---
echo "→ Получаем список файлов из релиза..."
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

IPK_NAME=""
SB_NAME=""
NEW_AWG=""
NEW_SB=""
[ -n "$IPK_URL" ] && IPK_NAME=$(basename "$IPK_URL")
[ -n "$SB_URL" ] && SB_NAME=$(basename "$SB_URL")

# awg-manager_2.17.3_aarch64-3.10-kn_compressed.ipk → 2.17.3
if [ -n "$IPK_NAME" ]; then
  NEW_AWG=$(echo "$IPK_NAME" | sed -n 's/^awg-manager_\([^_]*\)_.*/\1/p')
fi
# singbox-1.14.0-rc.1-awgm.14-aarch64-3.10_compressed → 1.14.0-rc.1-awgm.14
if [ -n "$SB_NAME" ]; then
  NEW_SB=$(echo "$SB_NAME" | sed -n 's/^singbox-\(.*\)-\(aarch64\|mipsel\|mips\)-.*/\1/p')
fi

echo "Доступно в релизе ($TAG):"
echo "   IPK      : ${IPK_NAME:-—} ${NEW_AWG:+($NEW_AWG)}"
echo "   sing-box : ${SB_NAME:-—} ${NEW_SB:+($NEW_SB)}"
echo ""

# --- меню ---
DO_AWG=""
DO_SB=""
AWG_MODE=""   # install | upgrade | reinstall
SB_MODE=""    # install | upgrade | replace

if [ -n "$INSTALL_AWG" ] || [ -n "$INSTALL_SB" ]; then
  DO_AWG=${INSTALL_AWG:-0}
  DO_SB=${INSTALL_SB:-0}
  [ "$DO_AWG" = "1" ] && AWG_MODE="install"
  [ "$DO_SB" = "1" ] && SB_MODE="install"
else
  echo "Что сделать?"
  echo "  [1] Только awg-manager"
  echo "  [2] Только sing-box"
  echo "  [3] Оба"
  echo "  [0] Отмена"
  echo ""
  choice=$(ask "Выбор [0-3], по умолчанию 3: " "3")
  case "$choice" in
    1) DO_AWG=1; DO_SB=0 ;;
    2) DO_AWG=0; DO_SB=1 ;;
    3) DO_AWG=1; DO_SB=1 ;;
    0|n|N|q|Q) echo "Отменено."; exit 0 ;;
    *) echo "Неверный выбор."; exit 1 ;;
  esac
fi

# --- решение по awg-manager ---
if [ "$DO_AWG" = "1" ]; then
  if [ -z "$IPK_URL" ]; then
    echo "❌ IPK для $ARCH не найден"
    DO_AWG=0
  elif [ -z "$CUR_AWG" ]; then
    AWG_MODE="install"
    echo "→ awg-manager: будет установка $NEW_AWG"
  else
    cmp=$(ver_cmp "$NEW_AWG" "$CUR_AWG")
    case "$cmp" in
      0)
        # та же версия — только по согласию переустановить сжатый пакет
        if [ "$(yes_no "awg-manager $CUR_AWG уже стоит (та же версия). Переустановить сжатый пакет? [y/N]: " "n")" = "1" ]; then
          AWG_MODE="reinstall"
        else
          echo "→ awg-manager пропущен (уже $CUR_AWG)"
          DO_AWG=0
        fi
        ;;
      1)
        # в релизе новее
        if [ "$(yes_no "awg-manager: $CUR_AWG → $NEW_AWG. Обновить? [Y/n]: " "y")" = "1" ]; then
          AWG_MODE="upgrade"
        else
          echo "→ awg-manager пропущен"
          DO_AWG=0
        fi
        ;;
      2)
        # на роутере новее, чем в compressed-релизе
        if [ "$(yes_no "На роутере awg-manager $CUR_AWG новее, чем в релизе ($NEW_AWG). Всё равно поставить из релиза? [y/N]: " "n")" = "1" ]; then
          AWG_MODE="reinstall"
        else
          echo "→ awg-manager пропущен (оставлен $CUR_AWG)"
          DO_AWG=0
        fi
        ;;
    esac
  fi
fi

# --- решение по sing-box ---
if [ "$DO_SB" = "1" ]; then
  if [ -z "$SB_URL" ]; then
    echo "⚠ sing-box для $ARCH нет в релизе"
    DO_SB=0
  elif [ -z "$CUR_SB_RAW" ]; then
    SB_MODE="install"
    echo "→ sing-box: будет установка ${NEW_SB:-из релиза}"
  else
    # грубое сравнение строк версий
    same=0
    if [ -n "$CUR_SB_VER" ] && [ -n "$NEW_SB" ]; then
      case "$CUR_SB_RAW" in
        *"$NEW_SB"*) same=1 ;;
      esac
      [ "$CUR_SB_VER" = "$NEW_SB" ] && same=1
    fi
    if [ "$same" = "1" ]; then
      if [ "$(yes_no "sing-box уже $NEW_SB. Заменить сжатым бинарником? [y/N]: " "n")" = "1" ]; then
        SB_MODE="replace"
      else
        echo "→ sing-box пропущен"
        DO_SB=0
      fi
    else
      if [ "$(yes_no "sing-box: обновить до ${NEW_SB:-новой версии}? (сейчас: $CUR_SB_RAW) [Y/n]: " "y")" = "1" ]; then
        SB_MODE="upgrade"
      else
        echo "→ sing-box пропущен"
        DO_SB=0
      fi
    fi
  fi
fi

if [ "$DO_AWG" != "1" ] && [ "$DO_SB" != "1" ]; then
  echo "Нечего устанавливать. Выход."
  exit 0
fi

mkdir -p "$TMP"
cd "$TMP"
rm -f ./* 2>/dev/null || true

# --- установка awg-manager ---
if [ "$DO_AWG" = "1" ]; then
  echo ""
  echo "⬇ Скачиваем $IPK_NAME ..."
  wget -q --show-progress -O "$IPK_NAME" "$IPK_URL" 2>/dev/null \
    || wget -q -O "$IPK_NAME" "$IPK_URL" \
    || curl -sL -o "$IPK_NAME" "$IPK_URL"
  if [ ! -s "$IPK_NAME" ]; then
    echo "❌ Ошибка скачивания IPK"
    exit 1
  fi

  case "$AWG_MODE" in
    upgrade|install)
      # обычная установка/обновление без force-reinstall
      echo "📦 Обновление/установка awg-manager ($AWG_MODE)..."
      if opkg install "./$IPK_NAME"; then
        echo "✅ awg-manager: $CUR_AWG → $NEW_AWG"
      else
        echo "⚠ opkg install не удался, пробуем --force-reinstall..."
        opkg install --force-reinstall "./$IPK_NAME"
        echo "✅ awg-manager установлен (force)"
      fi
      ;;
    reinstall)
      echo "📦 Переустановка awg-manager (force-reinstall)..."
      opkg install --force-reinstall "./$IPK_NAME" || opkg install "./$IPK_NAME"
      echo "✅ awg-manager переустановлен"
      ;;
  esac
fi

# --- установка sing-box ---
if [ "$DO_SB" = "1" ]; then
  echo ""
  echo "⬇ Скачиваем $SB_NAME ..."
  wget -q --show-progress -O "$SB_NAME" "$SB_URL" 2>/dev/null \
    || wget -q -O "$SB_NAME" "$SB_URL" \
    || curl -sL -o "$SB_NAME" "$SB_URL"
  if [ ! -s "$SB_NAME" ]; then
    echo "❌ Ошибка скачивания sing-box"
    exit 1
  fi
  mkdir -p "$SINGBOX_DIR"
  # бэкап старого при обновлении
  if [ -x "$SINGBOX_DIR/sing-box" ] && { [ "$SB_MODE" = "upgrade" ] || [ "$SB_MODE" = "replace" ]; }; then
    cp "$SINGBOX_DIR/sing-box" "$SINGBOX_DIR/sing-box.bak" 2>/dev/null || true
  fi
  cp "$SB_NAME" "$SINGBOX_DIR/sing-box"
  chmod +x "$SINGBOX_DIR/sing-box"
  echo "✅ sing-box ($SB_MODE) → $SINGBOX_DIR/sing-box"
  "$SINGBOX_DIR/sing-box" version 2>/dev/null | head -1 || true
fi

echo ""
echo "=== Готово ($ARCH) ==="
[ "$DO_AWG" = "1" ] && echo "   awg-manager: $NEW_AWG ($AWG_MODE)"
[ "$DO_SB" = "1" ] && echo "   sing-box:    ${NEW_SB:-ok} ($SB_MODE)"

rm -rf "$TMP"
echo "Временные файлы удалены."
