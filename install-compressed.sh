#!/bin/sh
# Установка compressed awg-manager + sing-box (Keenetic / Entware)
# https://github.com/rndnaame/awg-compressed
#
# Запуск:
#   curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
#   wget -qO- https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
#
# Без меню:
#   INSTALL_AWG=1 INSTALL_SB=0 sh -c "$(curl -sL .../install-compressed.sh)"
#   DL_IFACES="nwg0 t2s0" DL_TIMEOUT=60 ...
#   BACKUP_SB=1 NO_COLOR=1 ...

set -e

# ---------------------------------------------------------------------------
# Константы
# ---------------------------------------------------------------------------
REPO="rndnaame/awg-compressed"
TAG="compressed"
TMP="/tmp/awg-compressed-install"
SINGBOX_DIR="/opt/etc/awg-manager/singbox"
TUNNEL_SCRIPT_URL="https://raw.githubusercontent.com/rndnaame/awg-compressed/main/awg-manager-tunnel-access.sh"
DEFAULT_IFACES="nwg0 nwg1 t2s0 t2s1 opkgtun10 awgm0 __default__"

# ---------------------------------------------------------------------------
# UI (цвета как у awgm-installer; NO_COLOR=1 — без ANSI)
# ---------------------------------------------------------------------------
green="\033[92m"
red="\033[91m"
yellow="\033[93m"
light_blue="\033[96m"
bold="\033[1m"
reset="\033[0m"

HL_UPD='\033[1;93m'
HL_RST='\033[0m'

if [ -n "$NO_COLOR" ]; then
  green=""; red=""; yellow=""; light_blue=""; bold=""; reset=""
  HL_UPD=""; HL_RST=""
fi

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
  # $1 prompt, $2 default y|n → 1|0
  a=$(ask "$1" "$2")
  case "$a" in
    y|Y|yes|YES) echo 1 ;;
    *) echo 0 ;;
  esac
}

hl_line() {
  if [ "$1" = "1" ]; then
    printf '%b%s%b\n' "$HL_UPD" "$2" "$HL_RST"
  else
    printf '%s\n' "$2"
  fi
}

print_banner() {
  clear 2>/dev/null || true
  printf '%b\n' "${light_blue}================================================${reset}"
  printf '%b\n' "${light_blue}   Интерактивный установщик AWG-Manager (Sing-Box)${reset}"
  printf '%b\n' "${light_blue}================================================${reset}"
  echo ""
}

# 0 = equal, 1 = v1 > v2, 2 = v1 < v2
ver_cmp() {
  v1="$1"
  v2="$2"
  [ "$v1" = "$v2" ] && { echo 0; return; }
  first=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -1)
  if [ "$first" = "$v1" ]; then
    echo 2
  else
    echo 1
  fi
}

# ---------------------------------------------------------------------------
# Сеть
# ---------------------------------------------------------------------------
run_timeout() {
  secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" 2>/dev/null
    return $?
  fi
  "$@" 2>/dev/null &
  pid=$!
  i=0
  while [ "$i" -lt "$secs" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return $?
    fi
    sleep 1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 124
}

iface_exists() {
  ip link show "$1" >/dev/null 2>&1 || ifconfig "$1" >/dev/null 2>&1
}

iface_ip() {
  ip -4 -o addr show dev "$1" 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1
}

# GitHub HTTP-прокси (быстрый fallback, как в awgm-installer)
GH_PROXIES="https://gh-proxy.com/ https://ghfast.top/"

# Скачать URL → OUT через curl/wget [iface] [proxy_prefix]
# $1=url $2=out $3=try_secs $4=curl_iface $5=wget_bind $6=proxy_prefix
_dl_once() {
  _u="$1"; _o="$2"; _ts="$3"; _ci="$4"; _wb="$5"; _px="$6"
  _real="$_u"
  [ -n "$_px" ] && _real="${_px}${_u}"
  rm -f "$_o"
  if [ "$HAS_CURL" -eq 1 ]; then
    # shellcheck disable=SC2086
    run_timeout "$_ts" curl -fL --connect-timeout 5 --max-time "$_ts" \
      --speed-time 15 --speed-limit 1000 \
      -H "Cache-Control: no-cache" -H "Pragma: no-cache" \
      $_ci -o "$_o" "$_real" && return 0
  fi
  if [ "$HAS_WGET" -eq 1 ]; then
    # shellcheck disable=SC2086
    run_timeout "$_ts" wget -q -T 10 --no-cache $_wb -O "$_o" "$_real" 2>/dev/null && return 0
  fi
  rm -f "$_o"
  return 1
}

# download_file URL OUT [min_bytes]
download_file() {
  url="$1"
  out="$2"
  min_size="${3:-1000}"
  try_secs="${DL_TIMEOUT:-45}"

  out_dir=$(dirname "$out")
  [ -n "$out_dir" ] && [ "$out_dir" != "." ] && mkdir -p "$out_dir" 2>/dev/null || true

  HAS_CURL=0
  HAS_WGET=0
  command -v curl >/dev/null 2>&1 && HAS_CURL=1
  command -v wget >/dev/null 2>&1 && HAS_WGET=1
  if [ "$HAS_CURL" -eq 0 ] && [ "$HAS_WGET" -eq 0 ]; then
    echo "   ✗ нет curl и wget"
    return 1
  fi

  rm -f "$out"
  ifaces="${DL_IFACES:-$DEFAULT_IFACES}"

  try_ok() {
    [ -s "$out" ] || return 1
    [ "$(wc -c < "$out" 2>/dev/null || echo 0)" -ge "$min_size" ]
  }

  for iface in $ifaces; do
    if [ "$iface" = "__default__" ]; then
      label="default"
      curl_iface=""
      wget_bind=""
    else
      if ! iface_exists "$iface"; then
        echo "   ⏭  $iface — нет интерфейса"
        continue
      fi
      label="$iface"
      curl_iface="--interface $iface"
      _ip=$(iface_ip "$iface")
      [ -n "$_ip" ] && wget_bind="--bind-address=$_ip" || wget_bind=""
    fi

    echo "   ↻ через $label (макс ${try_secs}с) ..."
    if _dl_once "$url" "$out" "$try_secs" "$curl_iface" "$wget_bind" ""; then
      if try_ok; then
        echo "   ✓ $label ($(du -h "$out" | awk '{print $1}'))"
        return 0
      fi
    fi
    rm -f "$out"
  done

  # HTTP-прокси GitHub (после интерфейсов)
  case "$url" in
    https://github.com/*|https://api.github.com/*|https://raw.githubusercontent.com/*)
      for px in $GH_PROXIES; do
        px_label=$(echo "$px" | sed 's|https://||;s|/$||')
        echo "   ↻ proxy $px_label (макс ${try_secs}с) ..."
        if _dl_once "$url" "$out" "$try_secs" "" "" "$px"; then
          if try_ok; then
            echo "   ✓ proxy/$px_label ($(du -h "$out" | awk '{print $1}'))"
            return 0
          fi
        fi
        rm -f "$out"
      done
      ;;
  esac

  echo "   ✗ не удалось скачать"
  return 1
}

# Быстрый GitHub API — как awgm-installer: голый curl без run_timeout/speed-limit
# Порядок: direct → gh-proxy → ghfast → (тихо) fetch_text с интерфейсами
fetch_github_api() {
  url="$1"
  _out=""

  if command -v curl >/dev/null 2>&1; then
    _out=$(curl -s --connect-timeout 5 --max-time 12 "$url" 2>/dev/null) || true
    if [ -n "$_out" ]; then
      printf '%s\n' "$_out"
      return 0
    fi
    for px in $GH_PROXIES; do
      _out=$(curl -s --connect-timeout 5 --max-time 12 "${px}${url}" 2>/dev/null) || true
      if [ -n "$_out" ]; then
        printf '%s\n' "$_out"
        return 0
      fi
    done
  elif command -v wget >/dev/null 2>&1; then
    _out=$(wget -q -T 8 -O - "$url" 2>/dev/null) || true
    if [ -n "$_out" ]; then
      printf '%s\n' "$_out"
      return 0
    fi
    for px in $GH_PROXIES; do
      _out=$(wget -q -T 8 -O - "${px}${url}" 2>/dev/null) || true
      if [ -n "$_out" ]; then
        printf '%s\n' "$_out"
        return 0
      fi
    done
  fi

  # Медленный fallback (туннели) — без лишнего вывода
  fetch_text "$url"
}

# fetch текста (HTML/прочее): default → proxy → интерфейсы
fetch_text() {
  url="$1"
  try_secs="${FETCH_TEXT_TIMEOUT:-8}"
  short_secs=5
  ifaces="${DL_IFACES:-$DEFAULT_IFACES}"

  HAS_CURL=0
  HAS_WGET=0
  command -v curl >/dev/null 2>&1 && HAS_CURL=1
  command -v wget >/dev/null 2>&1 && HAS_WGET=1
  [ "$HAS_CURL" -eq 1 ] || [ "$HAS_WGET" -eq 1 ] || return 1

  tmpf=$(mktemp 2>/dev/null || echo "/tmp/ft_$$")

  # 1) Прямой канал без run_timeout (быстрее на Entware)
  if [ "$HAS_CURL" -eq 1 ]; then
    curl -sL --connect-timeout 5 --max-time "$short_secs" -o "$tmpf" "$url" 2>/dev/null || true
    if [ -s "$tmpf" ]; then
      cat "$tmpf"
      rm -f "$tmpf"
      return 0
    fi
    rm -f "$tmpf"
  fi

  # 2) HTTP-прокси для GitHub
  case "$url" in
    https://github.com/*|https://api.github.com/*|https://raw.githubusercontent.com/*)
      for px in $GH_PROXIES; do
        if [ "$HAS_CURL" -eq 1 ]; then
          curl -sL --connect-timeout 5 --max-time "$short_secs" -o "$tmpf" "${px}${url}" 2>/dev/null || true
          if [ -s "$tmpf" ]; then
            cat "$tmpf"
            rm -f "$tmpf"
            return 0
          fi
          rm -f "$tmpf"
        fi
      done
      ;;
  esac

  # 3) Интерфейсы (туннели)
  for iface in $ifaces; do
    [ "$iface" = "__default__" ] && continue
    iface_exists "$iface" || continue
    curl_iface="--interface $iface"
    _ip=$(iface_ip "$iface")
    [ -n "$_ip" ] && wget_bind="--bind-address=$_ip" || wget_bind=""
    if _dl_once "$url" "$tmpf" "$try_secs" "$curl_iface" "$wget_bind" ""; then
      if [ -s "$tmpf" ]; then
        cat "$tmpf"
        rm -f "$tmpf"
        return 0
      fi
    fi
    rm -f "$tmpf"
  done

  rm -f "$tmpf"
  return 1
}

# Показать body релиза из GitHub API JSON по tag_name
show_changelog() {
  _json="$1"
  _tag="$2"
  [ -n "$_json" ] && [ -n "$_tag" ] || { echo "   (changelog недоступен)"; return 1; }
  echo ""
  echo "========== Changelog: $_tag =========="
  echo "$_json" | sed -n "/\"tag_name\": *\"$_tag\"/,/\"body\":/p" | tail -n 1 | \
    sed 's/^[[:space:]]*"body":[[:space:]]*"//; s/\",$//; s/"$//; s/\\r\\n/\n/g; s/\\n/\n/g; s/\\"/"/g; s/\\\//\//g'
  echo "======================================"
  echo ""
}

# Предупреждение перед force-reinstall / force-downgrade
warn_force_backup() {
  echo ""
  echo "⚠ ВНИМАНИЕ: перед переустановкой или откатом версии сделайте бэкап настроек AWGM!"
  if [ "$(yes_no "Продолжить установку? [Y/n]: " "y")" != "1" ]; then
    echo "→ установка отменена"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Архитектура и установленные версии
# ---------------------------------------------------------------------------
detect_arch() {
  A=$(opkg print-architecture 2>/dev/null | sort -k3 -nr | awk '$2!="all"{print $2;exit}')
  case "$A" in
    aarch64*|arm*)
      ARCH=aarch64
      IPK_PAT="awg-manager_.*_aarch64-3.10-kn_compressed\\.ipk"
      SB_PAT="singbox-.*-aarch64-3.10_compressed"
      ARCH_SUFFIX="aarch64-3.10-kn"
      ARCH_REPO="aarch64-k3.10"
      ;;
    mipsel*)
      ARCH=mipsel
      IPK_PAT="awg-manager_.*_mipsel-3.4-kn_compressed\\.ipk"
      SB_PAT="singbox-.*-mipsel-3.4_compressed"
      ARCH_SUFFIX="mipsel-3.4-kn"
      ARCH_REPO="mipsel-k3.4"
      ;;
    mips*)
      ARCH=mips
      IPK_PAT="awg-manager_.*_mips-3.4-kn_compressed\\.ipk"
      SB_PAT="singbox-.*-mips-3.4_compressed"
      ARCH_SUFFIX="mips-3.4-kn"
      ARCH_REPO="mips-k3.4"
      ;;
    *)
      echo "❌ Неизвестная архитектура: ${A:-пусто}"
      opkg print-architecture 2>/dev/null || true
      exit 1
      ;;
  esac
  echo "✅ Архитектура: $A → $ARCH"
}

detect_installed() {
  CUR_AWG=$(opkg list-installed 2>/dev/null | awk '/^awg-manager /{print $3; exit}')
  [ -z "$CUR_AWG" ] && CUR_AWG=""

  CUR_SB_RAW=""
  CUR_SB_VER=""
  # Быстрый путь: meta.json (не запускаем бинарник)
  _meta="$SINGBOX_DIR/sing-box.meta.json"
  if [ -f "$_meta" ]; then
    CUR_SB_VER=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_meta" | head -1)
    [ -n "$CUR_SB_VER" ] && CUR_SB_RAW="$CUR_SB_VER"
  fi
  # Fallback: запуск sing-box version
  if [ -z "$CUR_SB_VER" ]; then
    if [ -x "$SINGBOX_DIR/sing-box" ]; then
      CUR_SB_RAW=$("$SINGBOX_DIR/sing-box" version 2>/dev/null | head -1 || true)
    elif command -v sing-box >/dev/null 2>&1; then
      CUR_SB_RAW=$(sing-box version 2>/dev/null | head -1 || true)
    fi
    if [ -n "$CUR_SB_RAW" ]; then
      CUR_SB_VER=$(echo "$CUR_SB_RAW" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*' | head -1 || true)
    fi
  fi
}

show_installed() {
  echo "Сейчас на роутере:"
  if [ -n "$CUR_AWG" ]; then
    echo "   awg-manager : $CUR_AWG"
  else
    echo "   awg-manager : не установлен"
  fi
  if [ -n "$CUR_SB_VER" ]; then
    echo "   sing-box    : $CUR_SB_VER"
  elif [ -n "$CUR_SB_RAW" ]; then
    _sb=$(echo "$CUR_SB_RAW" | sed -n 's/.*[Vv]ersion[[:space:]]*//p' | awk '{print $1}')
    [ -z "$_sb" ] && _sb="$CUR_SB_RAW"
    echo "   sing-box    : $_sb"
  else
    echo "   sing-box    : не найден"
  fi
  echo ""
}

# Записать версию в meta.json (для быстрого чтения в меню)
write_sb_meta() {
  _ver="$1"
  [ -n "$_ver" ] || return 0
  mkdir -p "$SINGBOX_DIR" 2>/dev/null || true
  printf '{"version":"%s"}\n' "$_ver" > "$SINGBOX_DIR/sing-box.meta.json" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Релиз compressed
# ---------------------------------------------------------------------------
fetch_release_assets() {
  echo "→ Получаем список файлов из релиза..."
  API_JSON=$(fetch_github_api "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" || true)
  ASSETS=$(echo "$API_JSON" | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"/\1/' || true)

  if [ -z "$ASSETS" ]; then
    echo "   API недоступен, пробуем HTML..."
    HTML=$(fetch_text "https://github.com/${REPO}/releases/expanded_assets/${TAG}" || true)
    ASSETS=$(echo "$HTML" | grep -oE 'href="[^"]*releases/download/[^"]+"' | sed 's/href="//;s/"$//' | while read -r p; do
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

  IPK_URL=$(echo "$ASSETS" | grep -E "$IPK_PAT" | sort -V | tail -1)
  SB_URL=$(echo "$ASSETS" | grep -E "$SB_PAT" | sort -V | tail -1)

  IPK_NAME=""
  SB_NAME=""
  NEW_AWG=""
  NEW_SB=""
  [ -n "$IPK_URL" ] && IPK_NAME=$(basename "$IPK_URL")
  [ -n "$SB_URL" ] && SB_NAME=$(basename "$SB_URL")

  if [ -n "$IPK_NAME" ]; then
    NEW_AWG=$(echo "$IPK_NAME" | sed -n 's/^awg-manager_\([^_]*\)_.*/\1/p')
  fi
  if [ -n "$SB_NAME" ]; then
    NEW_SB=$(echo "$SB_NAME" | sed -n 's/^singbox-\(.*\)-\(aarch64\|mipsel\|mips\)-.*/\1/p')
  fi
}

show_available() {
  echo "Доступно в релизе:"

  AWG_HL=0
  if [ -n "$NEW_AWG" ]; then
    if [ -z "$CUR_AWG" ]; then
      AWG_HL=1
    else
      _c=$(ver_cmp "$NEW_AWG" "$CUR_AWG")
      [ "$_c" = "1" ] && AWG_HL=1
    fi
  fi
  AWG_LINE="   awg-manager : ${NEW_AWG:-—}"
  [ "$AWG_HL" = "1" ] && AWG_LINE="${AWG_LINE}  ⚡"
  hl_line "$AWG_HL" "$AWG_LINE"

  SB_HL=0
  if [ -n "$NEW_SB" ]; then
    if [ -z "$CUR_SB_RAW" ]; then
      SB_HL=1
    else
      case "$CUR_SB_RAW" in
        *"$NEW_SB"*) SB_HL=0 ;;
        *) SB_HL=1 ;;
      esac
    fi
  fi
  SB_LINE="   sing-box    : ${NEW_SB:-—}"
  [ "$SB_HL" = "1" ] && SB_LINE="${SB_LINE}  ⚡"
  hl_line "$SB_HL" "$SB_LINE"
  echo ""
}

# ---------------------------------------------------------------------------
# Меню и решения
# ---------------------------------------------------------------------------
run_menu() {
  DO_AWG=""
  DO_SB=""
  AWG_MODE=""
  SB_MODE=""

  if [ -n "$INSTALL_AWG" ] || [ -n "$INSTALL_SB" ]; then
    DO_AWG=${INSTALL_AWG:-0}
    DO_SB=${INSTALL_SB:-0}
    [ "$DO_AWG" = "1" ] && AWG_MODE="install"
    [ "$DO_SB" = "1" ] && SB_MODE="install"
    return 0
  fi

  # Цикл главного меню: 0 — полный выход; в подменю 0 — возврат сюда
  while true; do
    echo "Что сделать?"
    echo ""
    echo "  awg-manager"
    echo "    [1]  официальный  · выбор версии"
    echo "    [2]  UPX          · выбор версии"
    echo ""
    echo "  sing-box"
    echo "    [3]  официальный  · выбор версии"
    echo "    [4]  UPX          · выбор версии"
    echo ""
    echo "  прочее"
    echo "    [5]  Настроить доступ через туннель"
    echo "    [0]  выход"
    echo ""
    choice=$(ask "Выбор [0-5], по умолчанию 1: " "1")
    case "$choice" in
      1)
        # set -e: вызов в if, иначе return 2 (в меню) роняет скрипт
        if install_awg_version_select; then
          exit 0
        fi
        echo ""
        ;;
      2)
        if install_awg_upx_version_select; then
          exit 0
        fi
        echo ""
        ;;
      3)
        if install_sb_official_version_select; then
          exit 0
        fi
        echo ""
        ;;
      4)
        if install_sb_version_select; then
          exit 0
        fi
        echo ""
        ;;
      5)
        run_tunnel_access || true
        echo ""
        ;;
      0|n|N|q|Q)
        echo "Выход."
        exit 0
        ;;
      *)
        echo "Неверный выбор."
        echo ""
        ;;
    esac
  done
}

decide_awg() {
  [ "$DO_AWG" = "1" ] || return 0

  if [ -z "$IPK_URL" ]; then
    echo "❌ IPK для $ARCH не найден"
    DO_AWG=0
    return 0
  fi

  if [ -z "$CUR_AWG" ]; then
    AWG_MODE="install"
    echo "→ awg-manager: будет установка $NEW_AWG"
    return 0
  fi

  cmp=$(ver_cmp "$NEW_AWG" "$CUR_AWG")
  case "$cmp" in
    0)
      if [ "$(yes_no "awg-manager $CUR_AWG уже стоит (та же версия). Переустановить сжатый пакет? [y/N]: " "n")" = "1" ]; then
        AWG_MODE="reinstall"
      else
        echo "→ awg-manager пропущен (уже $CUR_AWG)"
        DO_AWG=0
      fi
      ;;
    1)
      if [ "$(yes_no "awg-manager: $CUR_AWG → $NEW_AWG. Обновить? [Y/n]: " "y")" = "1" ]; then
        AWG_MODE="upgrade"
      else
        echo "→ awg-manager пропущен"
        DO_AWG=0
      fi
      ;;
    2)
      if [ "$(yes_no "На роутере awg-manager $CUR_AWG новее, чем в релизе ($NEW_AWG). Всё равно поставить из релиза? [y/N]: " "n")" = "1" ]; then
        AWG_MODE="reinstall"
      else
        echo "→ awg-manager пропущен (оставлен $CUR_AWG)"
        DO_AWG=0
      fi
      ;;
  esac
}

decide_sb() {
  [ "$DO_SB" = "1" ] || return 0

  if [ -z "$SB_URL" ]; then
    echo "⚠ sing-box для $ARCH нет в релизе"
    DO_SB=0
    return 0
  fi

  if [ -z "$CUR_SB_RAW" ]; then
    SB_MODE="install"
    echo "→ sing-box: будет установка ${NEW_SB:-из релиза}"
    return 0
  fi

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
    if [ "$(yes_no "sing-box: обновить до ${NEW_SB:-новой версии}? (сейчас: ${CUR_SB_VER:-$CUR_SB_RAW}) [Y/n]: " "y")" = "1" ]; then
      SB_MODE="upgrade"
    else
      echo "→ sing-box пропущен"
      DO_SB=0
    fi
  fi
}

# ---------------------------------------------------------------------------
# Установка
# ---------------------------------------------------------------------------
install_awg_upx() {
  echo ""
  echo "⬇ Скачиваем $IPK_NAME ..."
  if ! download_file "$IPK_URL" "$IPK_NAME" 100000; then
    echo "❌ Ошибка скачивания IPK"
    exit 1
  fi

  case "$AWG_MODE" in
    upgrade|install)
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
      warn_force_backup || return 0
      opkg install --force-reinstall "./$IPK_NAME" || opkg install "./$IPK_NAME"
      echo "✅ awg-manager переустановлен"
      ;;
  esac
}

install_sb_upx() {
  echo ""
  echo "⬇ Скачиваем $SB_NAME ..."
  if ! download_file "$SB_URL" "$SB_NAME" 100000; then
    echo "❌ Ошибка скачивания sing-box"
    exit 1
  fi

  mkdir -p "$SINGBOX_DIR"

  if [ -x "$SINGBOX_DIR/sing-box" ] && { [ "$SB_MODE" = "upgrade" ] || [ "$SB_MODE" = "replace" ]; }; then
    do_bak=0
    if [ -n "$BACKUP_SB" ]; then
      case "$BACKUP_SB" in
        1|y|Y|yes|YES) do_bak=1 ;;
      esac
    else
      [ "$(yes_no "Сохранить старый sing-box как sing-box.bak? [y/N]: " "n")" = "1" ] && do_bak=1
    fi
    if [ "$do_bak" = "1" ]; then
      cp "$SINGBOX_DIR/sing-box" "$SINGBOX_DIR/sing-box.bak" 2>/dev/null || true
      echo "   💾 бэкап → $SINGBOX_DIR/sing-box.bak"
    fi
  fi

  cp "$SB_NAME" "$SINGBOX_DIR/sing-box"
  chmod +x "$SINGBOX_DIR/sing-box"
  [ -n "$NEW_SB" ] && write_sb_meta "$NEW_SB"
  echo "✅ sing-box ($SB_MODE) → $SINGBOX_DIR/sing-box"
  if [ -n "$NEW_SB" ]; then
    echo "   version: $NEW_SB"
  else
    "$SINGBOX_DIR/sing-box" version 2>/dev/null | head -1 || true
  fi
}

# Пункт [1]: официальный IPK с выбором версии
install_awg_version_select() {
  echo ""
  echo "=== Установка awg-manager (официальный · выбор версии) ==="
  echo ""

  S="$ARCH_SUFFIX"
  R="$ARCH_REPO"
  if [ -z "$S" ] || [ -z "$R" ]; then
    echo "❌ Неизвестная архитектура: $ARCH"
    return 1
  fi
  echo "✅ Архитектура: $A → $S"

  mkdir -p /opt/etc/opkg
  echo "src/gz hoaxisr http://repo.hoaxisr.ru/$R" > /opt/etc/opkg/awg_manager.conf
  echo "✅ Репозиторий: http://repo.hoaxisr.ru/$R"

  echo "→ Список релизов hoaxisr/awg-manager..."
  API_JSON=$(fetch_github_api "https://api.github.com/repos/hoaxisr/awg-manager/releases?per_page=15" || true)
  # Быстрый разбор тегов (как awgm-installer)
  VERSIONS=$(echo "$API_JSON" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"//;s/"//g' | grep -v '^latest$' | head -12)

  if [ -z "$VERSIONS" ]; then
    echo "   API пуст, пробуем HTML..."
    HTML=$(fetch_text "https://github.com/hoaxisr/awg-manager/releases" || true)
    VERSIONS=$(echo "$HTML" | grep -oE '/hoaxisr/awg-manager/releases/tag/v[0-9][^"<> ]+' | sed 's|.*/||' | sort -u | sort -Vr | head -12)
  fi

  if [ -z "$VERSIONS" ]; then
    echo "❌ Не удалось получить список версий"
    return 1
  fi

  echo ""
  echo "🔢 Последние версии:"
  i=1
  echo "$VERSIONS" > /tmp/awg-ver-list.$$
  while read -r v; do
    [ -n "$v" ] || continue
    echo "   $i) ${v#v}"
    i=$((i + 1))
  done < /tmp/awg-ver-list.$$
  max=$((i - 1))
  echo "   (cN — changelog, напр. c2; 0 — в меню)"

  ver=""
  while true; do
    c=$(ask "Номер (1-$max) или версия (Enter = последняя, 0 = в меню): " "")
    if [ -z "$c" ]; then
      ver=$(head -1 /tmp/awg-ver-list.$$)
      break
    elif [ "$c" = "0" ]; then
      echo "→ главное меню"
      rm -f /tmp/awg-ver-list.$$
      return 2
    elif echo "$c" | grep -q '^[cCсС][0-9][0-9]*$'; then
      cl_num=$(echo "$c" | sed 's/[^0-9]//g')
      cl_tag=$(sed -n "${cl_num}p" /tmp/awg-ver-list.$$)
      if [ -n "$cl_tag" ]; then
        show_changelog "$API_JSON" "$cl_tag"
      else
        echo "❌ Нет версии под номером $cl_num"
      fi
      continue
    elif echo "$c" | grep -qE '^[0-9]+$'; then
      if [ "$c" -ge 1 ] && [ "$c" -le "$max" ]; then
        ver=$(sed -n "${c}p" /tmp/awg-ver-list.$$)
        break
      else
        echo "❌ Номер вне диапазона 1-$max"
      fi
    else
      ver="$c"
      break
    fi
  done
  rm -f /tmp/awg-ver-list.$$
  ver=${ver#v}

  ipk_name="awg-manager_${ver}_${S}.ipk"
  url="https://github.com/hoaxisr/awg-manager/releases/download/v${ver}/${ipk_name}"
  url_mirror="http://repo.hoaxisr.ru/${R}/${ipk_name}"

  echo ""
  echo "📥 Скачивание v$ver ($ipk_name)..."
  cd /tmp || return 1
  rm -f "$ipk_name"

  if ! download_file "$url" "$ipk_name" 100000; then
    echo "   GitHub не удалось — пробуем зеркало..."
    if ! download_file "$url_mirror" "$ipk_name" 100000; then
      echo "❌ Ошибка скачивания v$ver"
      return 1
    fi
  fi

  echo "📦 Установка $ipk_name ..."
  warn_force_backup || { rm -f "./$ipk_name"; return 2; }
  if opkg install --force-downgrade "./$ipk_name"; then
    echo "🎉 Установлен awg-manager v$ver"
  else
    echo "⚠️ Ошибка установки"
    rm -f "./$ipk_name"
    return 1
  fi
  rm -f "./$ipk_name"
  echo "Обновление позже: opkg update && opkg upgrade awg-manager"
  return 0
}

# Пункт [2]: UPX awg-manager с выбором версии (из топиков awgm-*)
install_awg_upx_version_select() {
  echo ""
  echo "=== Установка awg-manager (UPX · выбор версии) ==="
  echo ""

  S="$ARCH_SUFFIX"
  if [ -z "$S" ]; then
    echo "❌ Неизвестная архитектура: $ARCH"
    return 1
  fi
  echo "✅ Архитектура: $A → $S"

  echo "→ Список релизов awg-manager (UPX) из ${REPO}..."
  API_JSON=$(fetch_github_api "https://api.github.com/repos/${REPO}/releases?per_page=40" || true)
  VERSIONS=$(echo "$API_JSON" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"//;s/"//g' | grep '^awgm-' | head -15)

  if [ -z "$VERSIONS" ]; then
    echo "   API пуст, пробуем HTML..."
    HTML=$(fetch_text "https://github.com/${REPO}/releases" || true)
    VERSIONS=$(echo "$HTML" | grep -oE "/${REPO}/releases/tag/awgm-[^\"<> ]+" | sed 's|.*/||' | sort -u | sort -Vr | head -15)
  fi

  if [ -z "$VERSIONS" ]; then
    echo "❌ Не удалось получить список версий awg-manager UPX"
    return 1
  fi

  echo ""
  echo "🔢 Доступные версии (новые сверху):"
  i=1
  echo "$VERSIONS" > /tmp/awgm-upx-list.$$
  while read -r v; do
    [ -n "$v" ] || continue
    disp=${v#awgm-}
    echo "   $i) $disp"
    i=$((i + 1))
  done < /tmp/awgm-upx-list.$$
  max=$((i - 1))
  echo "   (cN — changelog, напр. c2; 0 — в меню)"

  ver_tag=""
  while true; do
    c=$(ask "Номер (1-$max) или версия (Enter = последняя, 0 = в меню): " "")
    if [ -z "$c" ]; then
      ver_tag=$(head -1 /tmp/awgm-upx-list.$$)
      break
    elif [ "$c" = "0" ]; then
      echo "→ главное меню"
      rm -f /tmp/awgm-upx-list.$$
      return 2
    elif echo "$c" | grep -q '^[cCсС][0-9][0-9]*$'; then
      cl_num=$(echo "$c" | sed 's/[^0-9]//g')
      cl_tag=$(sed -n "${cl_num}p" /tmp/awgm-upx-list.$$)
      if [ -n "$cl_tag" ]; then
        show_changelog "$API_JSON" "$cl_tag"
      else
        echo "❌ Нет версии под номером $cl_num"
      fi
      continue
    elif echo "$c" | grep -qE '^[0-9]+$'; then
      if [ "$c" -ge 1 ] && [ "$c" -le "$max" ]; then
        ver_tag=$(sed -n "${c}p" /tmp/awgm-upx-list.$$)
        break
      else
        echo "❌ Номер вне диапазона 1-$max"
      fi
    else
      case "$c" in
        awgm-*) ver_tag="$c" ;;
        *)      ver_tag="awgm-$c" ;;
      esac
      break
    fi
  done
  rm -f /tmp/awgm-upx-list.$$

  ver_disp=${ver_tag#awgm-}
  ipk_name="awg-manager_${ver_disp}_${S}_compressed.ipk"
  url="https://github.com/${REPO}/releases/download/${ver_tag}/${ipk_name}"

  echo ""
  echo "📥 Скачивание $ver_disp ($ipk_name)..."
  mkdir -p "$TMP"
  cd "$TMP" || return 1
  rm -f "$ipk_name"

  if ! download_file "$url" "$ipk_name" 100000; then
    echo "❌ Ошибка скачивания $ver_disp"
    echo "   URL: $url"
    return 1
  fi

  echo "📦 Установка $ipk_name ..."
  warn_force_backup || { rm -f "./$ipk_name"; return 2; }
  if opkg install --force-reinstall "./$ipk_name" 2>/dev/null || opkg install --force-downgrade "./$ipk_name"; then
    echo "🎉 Установлен awg-manager $ver_disp (UPX)"
  else
    echo "⚠️ Ошибка установки"
    rm -f "./$ipk_name"
    return 1
  fi
  rm -f "./$ipk_name"
  return 0
}

# Пункт [3]: официальный sing-box с выбором версии (hoaxisr/amnezia-box)
install_sb_official_version_select() {
  echo ""
  echo "=== Установка sing-box (официальный · выбор версии) ==="
  echo ""

  case "$ARCH" in
    aarch64) SB_ARCH_SUFFIX="aarch64-3.10" ;;
    mipsel)  SB_ARCH_SUFFIX="mipsel-3.4" ;;
    mips)    SB_ARCH_SUFFIX="mips-3.4" ;;
    *)
      echo "❌ Неизвестная архитектура: $ARCH"
      return 1
      ;;
  esac
  echo "✅ Архитектура: $A → $SB_ARCH_SUFFIX"

  echo "→ Список релизов hoaxisr/amnezia-box..."
  API_JSON=$(fetch_github_api "https://api.github.com/repos/hoaxisr/amnezia-box/releases?per_page=20" || true)
  VERSIONS=$(echo "$API_JSON" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"//;s/"//g' | grep -v '^latest$' | head -15)

  if [ -z "$VERSIONS" ]; then
    echo "   API пуст, пробуем HTML..."
    HTML=$(fetch_text "https://github.com/hoaxisr/amnezia-box/releases" || true)
    VERSIONS=$(echo "$HTML" | grep -oE '/hoaxisr/amnezia-box/releases/tag/[^"<> ]+' | sed 's|.*/||' | grep -v '^latest$' | sort -u | sort -Vr | head -15)
  fi

  if [ -z "$VERSIONS" ]; then
    echo "❌ Не удалось получить список версий sing-box"
    return 1
  fi

  echo ""
  echo "🔢 Доступные версии (новые сверху):"
  i=1
  echo "$VERSIONS" > /tmp/sb-off-list.$$
  while read -r v; do
    [ -n "$v" ] || continue
    echo "   $i) ${v#v}"
    i=$((i + 1))
  done < /tmp/sb-off-list.$$
  max=$((i - 1))
  echo "   (cN — changelog, напр. c2; 0 — в меню)"

  ver_tag=""
  while true; do
    c=$(ask "Номер (1-$max) или версия (Enter = последняя, 0 = в меню): " "")
    if [ -z "$c" ]; then
      ver_tag=$(head -1 /tmp/sb-off-list.$$)
      break
    elif [ "$c" = "0" ]; then
      echo "→ главное меню"
      rm -f /tmp/sb-off-list.$$
      return 2
    elif echo "$c" | grep -q '^[cCсС][0-9][0-9]*$'; then
      cl_num=$(echo "$c" | sed 's/[^0-9]//g')
      cl_tag=$(sed -n "${cl_num}p" /tmp/sb-off-list.$$)
      if [ -n "$cl_tag" ]; then
        show_changelog "$API_JSON" "$cl_tag"
      else
        echo "❌ Нет версии под номером $cl_num"
      fi
      continue
    elif echo "$c" | grep -qE '^[0-9]+$'; then
      if [ "$c" -ge 1 ] && [ "$c" -le "$max" ]; then
        ver_tag=$(sed -n "${c}p" /tmp/sb-off-list.$$)
        break
      else
        echo "❌ Номер вне диапазона 1-$max"
      fi
    else
      ver_tag="$c"
      break
    fi
  done
  rm -f /tmp/sb-off-list.$$

  ver_disp=${ver_tag#v}
  sb_name="singbox-${ver_disp}-${SB_ARCH_SUFFIX}"
  url="https://github.com/hoaxisr/amnezia-box/releases/download/${ver_tag}/${sb_name}"

  echo ""
  echo "📥 Скачивание $ver_disp ($sb_name)..."
  mkdir -p "$TMP"
  cd "$TMP" || return 1
  rm -f "$sb_name"

  if ! download_file "$url" "$sb_name" 100000; then
    echo "❌ Ошибка скачивания $ver_disp"
    echo "   URL: $url"
    return 1
  fi

  mkdir -p "$SINGBOX_DIR"

  if [ -x "$SINGBOX_DIR/sing-box" ]; then
    do_bak=0
    if [ -n "$BACKUP_SB" ]; then
      case "$BACKUP_SB" in
        1|y|Y|yes|YES) do_bak=1 ;;
      esac
    else
      [ "$(yes_no "Сохранить старый sing-box как sing-box.bak? [y/N]: " "n")" = "1" ] && do_bak=1
    fi
    if [ "$do_bak" = "1" ]; then
      cp "$SINGBOX_DIR/sing-box" "$SINGBOX_DIR/sing-box.bak" 2>/dev/null || true
      echo "   💾 бэкап → $SINGBOX_DIR/sing-box.bak"
    fi
  fi

  cp "$sb_name" "$SINGBOX_DIR/sing-box"
  chmod +x "$SINGBOX_DIR/sing-box"
  write_sb_meta "$ver_disp"
  echo "✅ sing-box $ver_disp → $SINGBOX_DIR/sing-box"
  echo "   version: $ver_disp"

  rm -f "$sb_name"
  echo "🎉 Установлен sing-box $ver_disp (официальный)"
  return 0
}

# Пункт [4]: UPX sing-box с выбором версии (из топиков sb-*)
install_sb_version_select() {
  echo ""
  echo "=== Установка sing-box (UPX · выбор версии) ==="
  echo ""

  # ARCH уже определён в detect_arch: aarch64 / mipsel / mips
  case "$ARCH" in
    aarch64) SB_ARCH_SUFFIX="aarch64-3.10" ;;
    mipsel)  SB_ARCH_SUFFIX="mipsel-3.4" ;;
    mips)    SB_ARCH_SUFFIX="mips-3.4" ;;
    *)
      echo "❌ Неизвестная архитектура: $ARCH"
      return 1
      ;;
  esac
  echo "✅ Архитектура: $A → $SB_ARCH_SUFFIX"

  echo "→ Список релизов sing-box (UPX) из rndnaame/awg-compressed..."
  API_JSON=$(fetch_github_api "https://api.github.com/repos/${REPO}/releases?per_page=40" || true)
  VERSIONS=$(echo "$API_JSON" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"//;s/"//g' | grep '^sb-' | head -15)

  if [ -z "$VERSIONS" ]; then
    echo "   API пуст, пробуем HTML..."
    HTML=$(fetch_text "https://github.com/${REPO}/releases" || true)
    VERSIONS=$(echo "$HTML" | grep -oE '/rndnaame/awg-compressed/releases/tag/sb-[^"<> ]+' | sed 's|.*/||' | sort -u | sort -Vr | head -15)
  fi

  if [ -z "$VERSIONS" ]; then
    echo "❌ Не удалось получить список версий sing-box"
    return 1
  fi

  echo ""
  echo "🔢 Доступные версии (новые сверху):"
  i=1
  echo "$VERSIONS" > /tmp/sb-ver-list.$$
  while read -r v; do
    [ -n "$v" ] || continue
    # tag: sb-1.14.0-awgm.16 → показываем 1.14.0-awgm.16
    disp=${v#sb-}
    echo "   $i) $disp"
    i=$((i + 1))
  done < /tmp/sb-ver-list.$$
  max=$((i - 1))
  echo "   (cN — changelog, напр. c2; 0 — в меню)"

  ver_tag=""
  while true; do
    c=$(ask "Номер (1-$max) или версия (Enter = последняя, 0 = в меню): " "")
    if [ -z "$c" ]; then
      ver_tag=$(head -1 /tmp/sb-ver-list.$$)
      break
    elif [ "$c" = "0" ]; then
      echo "→ главное меню"
      rm -f /tmp/sb-ver-list.$$
      return 2
    elif echo "$c" | grep -q '^[cCсС][0-9][0-9]*$'; then
      cl_num=$(echo "$c" | sed 's/[^0-9]//g')
      cl_tag=$(sed -n "${cl_num}p" /tmp/sb-ver-list.$$)
      if [ -n "$cl_tag" ]; then
        show_changelog "$API_JSON" "$cl_tag"
      else
        echo "❌ Нет версии под номером $cl_num"
      fi
      continue
    elif echo "$c" | grep -qE '^[0-9]+$'; then
      if [ "$c" -ge 1 ] && [ "$c" -le "$max" ]; then
        ver_tag=$(sed -n "${c}p" /tmp/sb-ver-list.$$)
        break
      else
        echo "❌ Номер вне диапазона 1-$max"
      fi
    else
      case "$c" in
        sb-*) ver_tag="$c" ;;
        *)    ver_tag="sb-$c" ;;
      esac
      break
    fi
  done
  rm -f /tmp/sb-ver-list.$$

  ver_disp=${ver_tag#sb-}
  sb_name="singbox-${ver_disp}-${SB_ARCH_SUFFIX}_compressed"
  url="https://github.com/${REPO}/releases/download/${ver_tag}/${sb_name}"

  echo ""
  echo "📥 Скачивание $ver_disp ($sb_name)..."
  mkdir -p "$TMP"
  cd "$TMP" || return 1
  rm -f "$sb_name"

  if ! download_file "$url" "$sb_name" 100000; then
    echo "❌ Ошибка скачивания $ver_disp"
    echo "   URL: $url"
    return 1
  fi

  mkdir -p "$SINGBOX_DIR"

  # бэкап старого, если есть
  if [ -x "$SINGBOX_DIR/sing-box" ]; then
    do_bak=0
    if [ -n "$BACKUP_SB" ]; then
      case "$BACKUP_SB" in
        1|y|Y|yes|YES) do_bak=1 ;;
      esac
    else
      [ "$(yes_no "Сохранить старый sing-box как sing-box.bak? [y/N]: " "n")" = "1" ] && do_bak=1
    fi
    if [ "$do_bak" = "1" ]; then
      cp "$SINGBOX_DIR/sing-box" "$SINGBOX_DIR/sing-box.bak" 2>/dev/null || true
      echo "   💾 бэкап → $SINGBOX_DIR/sing-box.bak"
    fi
  fi

  cp "$sb_name" "$SINGBOX_DIR/sing-box"
  chmod +x "$SINGBOX_DIR/sing-box"
  write_sb_meta "$ver_disp"
  echo "✅ sing-box $ver_disp → $SINGBOX_DIR/sing-box"
  echo "   version: $ver_disp"

  rm -f "$sb_name"
  echo "🎉 Установлен sing-box $ver_disp (UPX)"
  return 0
}

# Пункт [5]
run_tunnel_access() {
  echo ""
  echo "=== Настройка доступа через туннель ==="
  echo "Источник: rndnaame/awg-compressed"
  echo ""

  TUN_TMP="/tmp/awg-manager-tunnel-access.sh"
  rm -f "$TUN_TMP"

  if ! download_file "$TUNNEL_SCRIPT_URL" "$TUN_TMP" 500; then
    echo "❌ Не удалось скачать скрипт настройки туннеля"
    echo "   URL: $TUNNEL_SCRIPT_URL"
    return 1
  fi

  if ! head -1 "$TUN_TMP" | grep -q '^#!'; then
    echo "❌ Скачанный файл не похож на скрипт (нет shebang)"
    head -5 "$TUN_TMP" | sed 's/^/   /'
    rm -f "$TUN_TMP"
    return 1
  fi

  chmod +x "$TUN_TMP"
  echo "→ Запуск $TUN_TMP ..."
  echo ""
  # curl|sh: stdin — труба; без /dev/tty дочернее меню «крутится»
  if [ -r /dev/tty ]; then
    ( cd /tmp && exec </dev/tty >/dev/tty 2>/dev/tty; sh "$TUN_TMP" )
  else
    sh "$TUN_TMP"
  fi
  rc=$?
  rm -f "$TUN_TMP"
  return "$rc"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  print_banner

  detect_arch
  echo ""
  detect_installed
  show_installed
  fetch_release_assets
  show_available
  run_menu

  if [ "$DO_AWG" != "1" ] && [ "$DO_SB" != "1" ]; then
    echo "Нечего устанавливать. Выход."
    exit 0
  fi

  # NEW_AWG / NEW_SB уже из fetch_release_assets выше
  decide_awg
  decide_sb

  if [ "$DO_AWG" != "1" ] && [ "$DO_SB" != "1" ]; then
    echo "Нечего устанавливать. Выход."
    exit 0
  fi

  mkdir -p "$TMP"
  cd "$TMP"
  rm -f ./* 2>/dev/null || true

  [ "$DO_AWG" = "1" ] && install_awg_upx
  [ "$DO_SB" = "1" ] && install_sb_upx

  echo ""
  echo "=== Готово ($ARCH) ==="
  [ "$DO_AWG" = "1" ] && echo "   awg-manager: $NEW_AWG ($AWG_MODE)"
  [ "$DO_SB" = "1" ] && echo "   sing-box:    ${NEW_SB:-ok} ($SB_MODE)"

  rm -rf "$TMP"
  echo "Временные файлы удалены."
}

main "$@"
