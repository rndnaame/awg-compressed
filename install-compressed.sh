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
  printf '%b\n' "${light_blue}Интерактивный установщик AWG-Manager (Sing-Box)${reset}"
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
    printf '%b\n' "${yellow}Выбрать пакет для установки:${reset}"
    echo ""
    echo "  AWG-Manager"
    echo "    [1]  официальная версия"
    echo "    [2]  UPX версия (сжатая)"
    echo ""
    echo "  Sing-Box"
    echo "    [3]  официальная версия"
    echo "    [4]  UPX версия (сжатая)"
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

# Пункт [5]: доступ через туннель (встроено, без скачивания)
run_tunnel_access() {
  echo ""
  echo "=== Настройка доступа через туннель ==="
  echo ""

  TUN_TMP="/tmp/awg-manager-tunnel-access.$$.sh"
  rm -f "$TUN_TMP"

  # Встроенная копия awg-manager-tunnel-access.sh
  cat > "$TUN_TMP" << 'AWG_TUNNEL_EMBED_EOF'
#!/bin/sh
#
# AWG Manager Tunnel Access for Keenetic + Entware
# Russian interface
#
# Purpose:
#   Give AWG Manager access through a selected Keenetic tunnel interface
#   (WireGuard nwgN or ZeroTier ztN) and provide a reliable rollback
#   to the exact saved state.
#
# Requirements:
#   - KeeneticOS with ndmc
#   - Entware
#   - jq (opkg install jq)
#   - AWG Manager with /opt/etc/awg-manager/settings.json
#
# JSON layout this script edits (verified on schemaVersion 32):
#   .server.interfaces  -> array, e.g. ["br0"]
#   .server.port        -> number
#   .server.interface   -> NOT touched by this script (single primary iface)
#
# ndmc output format:
#   Разные сборки KeeneticOS отдают "show interface X" либо текстом
#   (key: value), либо JSON. Формат определяется один раз при старте
#   (ndmc_preflight) и парсер выбирается соответственно.
#
# Run as root.
#

PATH="/opt/bin:/opt/sbin:/bin:/sbin:/usr/bin:/usr/sbin:$PATH"

# settings.json содержит приватные ключи — временные файлы создаём
# только с правами владельца.
umask 077

AWG_SETTINGS="/opt/etc/awg-manager/settings.json"
AWG_DIR="/opt/etc/awg-manager"
AWG_INIT="/opt/etc/init.d/S99awg-manager"
AWG_PKG="awg-manager"
# HTTP, а не HTTPS: официальная инструкция AWG Manager использует именно
# http://repo.hoaxisr.ru/install.sh, так как busybox wget на многих
# прошивках Keenetic не умеет TLS. Это только текст подсказки при ошибке
# (скрипт больше не выполняет установку сам), поэтому безопасно.
AWG_INSTALL_URL="http://repo.hoaxisr.ru/install.sh"
BACKUP_ROOT="$AWG_DIR/.tunnel-access-backup"
STATE_FILE="$BACKUP_ROOT/state.tsv"
FULL_SETTINGS="$BACKUP_ROOT/settings.json"
LOCK_FILE="/tmp/awg-manager-tunnel-access.lock"

MAX_WG_INDEX=63
MAX_ZT_INDEX=15
PORT_WAIT_SECONDS=10

TMP_LIST="/tmp/awg-tun-list.$$"
TMP_SETTINGS="$AWG_DIR/.settings.tmp.$$"
TMP_STATE="$BACKUP_ROOT/.state.tmp.$$"

NDMC_FORMAT=""      # json | text, определяется в ndmc_preflight
LOCK_OWNED=0

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() { warn "ОШИБКА: $*"; exit 1; }


# Интерактивный ввод всегда с /dev/tty (иначе при curl|sh меню читает мусор/пустоту).
read_tty() {
    _prompt="$1"
    _var="$2"
    if [ -n "$_prompt" ]; then
        if [ -w /dev/tty ]; then
            printf '%s' "$_prompt" > /dev/tty
        else
            printf '%s' "$_prompt"
        fi
    fi
    if [ -r /dev/tty ]; then
        IFS= read -r "$_var" < /dev/tty || return 1
    else
        IFS= read -r "$_var" || return 1
    fi
    return 0
}


cleanup() {
    [ "$LOCK_OWNED" = "1" ] && rm -f "$LOCK_FILE"
    rm -f "$TMP_LIST" "$TMP_SETTINGS" "$TMP_STATE"
    return 0
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

[ "$(id -u 2>/dev/null)" = "0" ] || die "скрипт нужно запускать от root"
command -v opkg >/dev/null 2>&1 || die "не найден opkg (нужен Entware)"
command -v jq >/dev/null 2>&1 || die "не найден jq (opkg install jq)"
command -v ndmc >/dev/null 2>&1 || die "не найден ndmc"

# Stale-lock aware locking: store PID, verify liveness on collision.
# ВАЖНО: trap ставится только ПОСЛЕ захвата lock — иначе выход по
# "скрипт уже выполняется" удалил бы lock чужого работающего процесса.
if [ -e "$LOCK_FILE" ]; then
    old_pid="$(cat "$LOCK_FILE" 2>/dev/null)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        die "скрипт уже выполняется (pid $old_pid)"
    fi
    say "Найден протухший lock-файл (pid ${old_pid:-?} не активен) — снимаю."
    rm -f "$LOCK_FILE"
fi
printf '%s\n' "$$" > "$LOCK_FILE" || die "не удалось создать $LOCK_FILE"
LOCK_OWNED=1
trap cleanup EXIT INT TERM

# Этот скрипт не устанавливает и не обновляет AWG Manager — это отдельная
# задача. Здесь только проверка, что пакет установлен и рабочий.
if ! opkg list-installed 2>/dev/null | grep -q "^$AWG_PKG - "; then
    die "AWG Manager не установлен. Установка: wget -qO- $AWG_INSTALL_URL | sh"
fi

[ -f "$AWG_SETTINGS" ] || die "не найден $AWG_SETTINGS"
[ -x "$AWG_INIT" ] || die "не найден $AWG_INIT"

jq empty "$AWG_SETTINGS" 2>/dev/null || die "$AWG_SETTINGS повреждён (невалидный JSON)"

# ---------------------------------------------------------------------------
# ndmc wrappers
#
# Раньше здесь было `ndmc -c "$1" 2>/dev/null` без проверки кода возврата:
# при недоступном CLI скрипт получал пустой вывод, считал, что WireGuard
# нет, и молча возвращался в меню. Теперь ошибка видна.
# ---------------------------------------------------------------------------

ndmc_run() {
    _cmd="$1"
    _quiet="${2:-}"

    _out="$(ndmc -c "$_cmd" 2>&1)"
    _rc=$?

    # ndmc может завершиться с кодом 0, напечатав диагностику ndm.
    case "$_out" in
        *'failed to initialize'*|*'ndmc: system failed'*|*'Cli::Main'*) _rc=1 ;;
    esac

    if [ "$_rc" -ne 0 ]; then
        [ -n "$_quiet" ] || warn "ndmc: $_out"
        return 1
    fi

    printf '%s\n' "$_out"
    return 0
}

ndmc_cmd() { ndmc_run "$1"; }
ndmc_try() { ndmc_run "$1" quiet; }

ndmc_preflight() {
    if ! _ver="$(ndmc_try 'show version')"; then
        say ""
        say "Keenetic CLI недоступен — ndmc не отвечает:"
        ndmc -c "show version" 2>&1 | sed 's/^/  /'
        say ""
        say "Что проверить:"
        say "  1. Слот CLI занят другой сессией. Закрой веб-интерфейс роутера"
        say "     и лишние telnet/SSH-сессии, затем повтори."
        say "     Текущие сессии: ps w | grep '[n]dmc'"
        say "  2. Если вход был по telnet с логин-шеллом ndmc, этот ndmc держит"
        say "     слот. Запусти скрипт из отдельной сессии (dropbear из Entware)."
        say "  3. Служба ndm запущена: ps w | grep '[n]dm'"
        return 1
    fi

    if printf '%s' "$_ver" | jq empty 2>/dev/null; then
        NDMC_FORMAT="json"
    else
        NDMC_FORMAT="text"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# jq helpers — all reads/writes of settings.json go through these
# ---------------------------------------------------------------------------

get_server_port() {
    p="$(jq -r '.server.port // empty' "$AWG_SETTINGS" 2>/dev/null)"
    case "$p" in
        ''|*[!0-9]*) printf '2222\n' ;;
        *) printf '%s\n' "$p" ;;
    esac
}

# Returns 0 (true) if iface is already present in .server.interfaces
interface_present() {
    iface="$1"
    jq -e --arg i "$iface" '.server.interfaces | index($i) != null' \
        "$AWG_SETTINGS" >/dev/null 2>&1
}

# Атомарная подмена settings.json: временный файл лежит в том же каталоге,
# поэтому mv — переименование в пределах ФС, а не copy+unlink.
# Права оригинала сохраняются.
commit_settings() {
    _new="$1"

    [ -s "$_new" ] || { warn "пустой результат jq"; return 1; }
    jq empty "$_new" 2>/dev/null || { warn "jq сгенерировал невалидный JSON"; return 1; }

    _mode="$(stat -c '%a' "$AWG_SETTINGS" 2>/dev/null)"
    case "$_mode" in
        ''|*[!0-7]*) _mode=600 ;;
    esac
    chmod "$_mode" "$_new" 2>/dev/null

    mv "$_new" "$AWG_SETTINGS" || { warn "не удалось сохранить settings.json"; return 1; }
    return 0
}

add_interface_to_awg() {
    linux="$1"

    interface_present "$linux" && return 0

    jq --arg i "$linux" \
       '.server.interfaces = ((.server.interfaces // []) + [$i] | unique)' \
       "$AWG_SETTINGS" > "$TMP_SETTINGS" 2>/dev/null

    if ! jq -e --arg i "$linux" '.server.interfaces | index($i) != null' \
            "$TMP_SETTINGS" >/dev/null 2>&1; then
        rm -f "$TMP_SETTINGS"
        warn "не удалось добавить $linux в .server.interfaces"
        return 1
    fi

    commit_settings "$TMP_SETTINGS" || { rm -f "$TMP_SETTINGS"; return 1; }
    return 0
}

remove_interface_from_awg() {
    linux="$1"

    interface_present "$linux" || return 0

    jq --arg i "$linux" \
       '.server.interfaces = ((.server.interfaces // []) - [$i])' \
       "$AWG_SETTINGS" > "$TMP_SETTINGS" 2>/dev/null

    commit_settings "$TMP_SETTINGS" || { rm -f "$TMP_SETTINGS"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# Tunnel interface discovery (WireGuard + ZeroTier, Keenetic CLI)
# ---------------------------------------------------------------------------
#
# Keenetic names:
#   WireguardN  -> Linux nwgN
#   ZeroTierN   -> Linux ztN  (ndmc: ZeroTier0, ZeroTier1, ...)
#
# Парсеры печатают 5 полей через TAB: ip, desc, sec, state, link.
# Пустые значения → "-" (чтобы IFS=TAB не схлопывал поля).

parse_tun_json() {
    # $1 = raw json, $2 = expected type (wireguard|zerotier), case-insensitive
    _want="$2"
    printf '%s' "$1" | jq -r --arg want "$_want" '
        def d: if . == null or . == "" then "-" else . end;
        (($.type // "") | ascii_downcase) as $t |
        if $t == $want then
            [ (.address | d),
              (.description | d),
              (."security-level" | d),
              (.state | d),
              (.link | d) ] | @tsv
        else empty end' 2>/dev/null
}

parse_tun_text() {
    # $1 = raw text, $2 = expected type substring (wireguard|zerotier)
    _o="$1"
    _want="$2"

    printf '%s' "$_o" | grep -qi "type:[[:space:]]*${_want}" || return 1

    _ip="$(printf '%s' "$_o" | sed -n 's/^[[:space:]]*address:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"
    _desc="$(printf '%s' "$_o" | sed -n 's/^[[:space:]]*description:[[:space:]]*\(.*\)$/\1/p' | head -n 1 | tr '\t' ' ')"
    _sec="$(printf '%s' "$_o" | sed -n 's/^[[:space:]]*security-level:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"
    _state="$(printf '%s' "$_o" | sed -n 's/^[[:space:]]*state:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"
    _link="$(printf '%s' "$_o" | sed -n 's/^[[:space:]]*link:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${_ip:--}" "${_desc:--}" "${_sec:--}" "${_state:--}" "${_link:--}"
    return 0
}

# probe one ndmc interface name; on success print: Name\tip\tdesc\tsec\tstate\tlink
probe_ndmc_iface() {
    _ndmc_name="$1"
    _type_want="$2"

    _out="$(ndmc_try "show interface $_ndmc_name")" || return 1
    [ -n "$_out" ] || return 1

    if [ "$NDMC_FORMAT" = "json" ]; then
        _fields="$(parse_tun_json "$_out" "$_type_want")"
    else
        _fields="$(parse_tun_text "$_out" "$_type_want")"
    fi
    [ -n "$_fields" ] || return 1
    printf '%s\t%s\n' "$_ndmc_name" "$_fields"
    return 0
}

list_wg_interfaces() {
    _i=0
    while [ "$_i" -le "$MAX_WG_INDEX" ]; do
        probe_ndmc_iface "Wireguard$_i" "wireguard" || true
        _i=$((_i + 1))
    done
}

list_zt_interfaces() {
    # Keenetic CLI: ZeroTier0, ZeroTier1, ... → Linux zt0, zt1, ...
    _i=0
    while [ "$_i" -le "$MAX_ZT_INDEX" ]; do
        probe_ndmc_iface "ZeroTier$_i" "zerotier" || true
        _i=$((_i + 1))
    done

    # Запасной путь: Linux ztN уже есть (Entware ZeroTier / другой клиент),
    # а в ndmc интерфейса ZeroTierN нет. Добавляем ztN в список.
    # security-level для таких записей не меняем (имя уже linux).
    for _zt in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^zt[0-9]+$' || true); do
        _n="${_zt#zt}"
        # уже есть из ndmc?
        if grep -qE "^(ZeroTier|Zerotier)${_n}	" "$TMP_LIST" 2>/dev/null; then
            continue
        fi
        if grep -q "^${_zt}	" "$TMP_LIST" 2>/dev/null; then
            continue
        fi
        _ip=$(ip -4 -o addr show dev "$_zt" 2>/dev/null | awk '{print $4}' | head -1 | cut -d/ -f1)
        [ -n "$_ip" ] || _ip="-"
        # name=ztN, ip, desc, sec=- (не трогаем), state=up/down, link=-
        _state="up"
        ip link show "$_zt" 2>/dev/null | grep -q 'state DOWN' && _state="down"
        printf '%s	%s	%s	%s	%s	%s
' "$_zt" "$_ip" "ZeroTier(linux)" "-" "$_state" "-"
    done
}

# Объединённый список: сначала WG, потом ZeroTier
list_tunnel_interfaces() {
    list_wg_interfaces
    list_zt_interfaces
}

get_linux_name() {
    # WireguardN -> nwgN, ZeroTierN/ZerotierN -> ztN
    case "$1" in
        Wireguard*)
            n="${1#Wireguard}"
            if ip link show "nwg$n" >/dev/null 2>&1; then
                printf 'nwg%s\n' "$n"
            else
                printf '%s\n' "-"
            fi
            ;;
        ZeroTier*|Zerotier*)
            n="${1#ZeroTier}"
            n="${n#Zerotier}"
            if ip link show "zt$n" >/dev/null 2>&1; then
                printf 'zt%s\n' "$n"
            elif ip link show "zt$n" >/dev/null 2>&1; then
                printf 'zt%s\n' "$n"
            else
                # иногда индекс в Linux совпадает, даже если ndmc-имя другое
                if ip link show zt0 >/dev/null 2>&1 && [ "$n" = "0" ]; then
                    printf 'zt0\n'
                else
                    printf '%s\n' "-"
                fi
            fi
            ;;
        *)
            # если передали уже linux-имя
            if ip link show "$1" >/dev/null 2>&1; then
                printf '%s\n' "$1"
            else
                printf '%s\n' "-"
            fi
            ;;
    esac
}

iface_kind_label() {
    case "$1" in
        Wireguard*) printf 'WG' ;;
        ZeroTier*|Zerotier*) printf 'ZT' ;;
        *) printf '?' ;;
    esac
}

show_wg_list() {
    say ""
    say "Опрашиваю Keenetic CLI (WireGuard + ZeroTier)..."
    : > "$TMP_LIST"
    list_tunnel_interfaces >> "$TMP_LIST"

    if [ ! -s "$TMP_LIST" ]; then
        say "Туннели не найдены (Wireguard0-$MAX_WG_INDEX, ZeroTier0-$MAX_ZT_INDEX)."
        return 1
    fi

    say ""
    say "Туннели:"
    while IFS='	' read -r name ip desc sec state link; do
        _k="$(iface_kind_label "$name")"
        printf '  [%s] %-12s %-15s %-9s %s (%s/%s)\n' "$_k" "$name" "$ip" "$sec" "$desc" "$state" "$link"
    done < "$TMP_LIST"
    return 0
}

# 0 — выбран интерфейс, 1 — отмена/неверный ввод, 2 — интерфейсов нет
select_wg() {
    say ""
    say "Опрашиваю Keenetic CLI (WireGuard + ZeroTier)..."
    : > "$TMP_LIST"
    list_tunnel_interfaces >> "$TMP_LIST"
    [ -s "$TMP_LIST" ] || return 2

    say ""
    say "Выберите туннель (WireGuard / ZeroTier):"
    say ""
    n=1
    while IFS='	' read -r name ip desc sec state link; do
        _k="$(iface_kind_label "$name")"
        printf '%s) [%s] %s — %s — %s (%s/%s)\n' "$n" "$_k" "$name" "$ip" "$desc" "$state" "$link"
        n=$((n + 1))
    done < "$TMP_LIST"

    if ! read_tty "Выбор [1-$((n - 1)), 0=отмена]: " choice; then
        return 1
    fi

    case "$choice" in
        0|"") return 1 ;;
        *[!0-9]*) say "Неверный ввод."; return 1 ;;
    esac

    selected="$(sed -n "${choice}p" "$TMP_LIST")"
    [ -n "$selected" ] || { say "Нет пункта $choice."; return 1; }

    OLD_IFS="$IFS"
    IFS='	'
    # shellcheck disable=SC2086
    set -- $selected
    IFS="$OLD_IFS"

    SEL_NAME="$1"
    SEL_IP="$2"
    SEL_DESC="$3"
    SEL_SEC="$4"
    SEL_STATE="$5"
    SEL_LINK="$6"
    SEL_LINUX="$(get_linux_name "$SEL_NAME")"
    return 0
}

# ---------------------------------------------------------------------------
# Backup / restore
# ---------------------------------------------------------------------------

ensure_backup() {
    mkdir -p "$BACKUP_ROOT" || die "не удалось создать $BACKUP_ROOT"

    # Create the original snapshot only once. This is the rollback point.
    if [ ! -f "$FULL_SETTINGS" ]; then
        extra="$(jq -r '.server.interfaces // [] | map(select(. != "br0")) | .[]' "$AWG_SETTINGS" 2>/dev/null)"
        if [ -n "$extra" ]; then
            say ""
            say "ВНИМАНИЕ: в settings.json уже есть интерфейсы, кроме br0:"
            printf '%s\n' "$extra" | while IFS= read -r e; do say "  - $e"; done
            say "Это состояние будет сохранено как точка отката (\"исходное\")."
            say "Если это не так — сначала поправь settings.json/security-level вручную."
            printf "Продолжить и считать текущее состояние исходным? [y/N]: "
            if ! read_tty "" confirm_extra; then confirm_extra=""; fi
            case "$confirm_extra" in
                y|Y|д|Д) ;;
                *) say "Отменено."; return 1 ;;
            esac
        fi
        cp -p "$AWG_SETTINGS" "$FULL_SETTINGS" || die "не удалось сохранить settings.json"
    fi

    [ -f "$STATE_FILE" ] || : > "$STATE_FILE"

    if ! grep -q "^$SEL_NAME	" "$STATE_FILE" 2>/dev/null; then
        # Append atomically: write to tmp, then replace.
        cp -p "$STATE_FILE" "$TMP_STATE" 2>/dev/null || : > "$TMP_STATE"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$SEL_NAME" "$SEL_IP" "$SEL_SEC" "$SEL_LINUX" "$SEL_DESC" \
            "$(date '+%Y-%m-%d %H:%M:%S')" >> "$TMP_STATE"
        mv "$TMP_STATE" "$STATE_FILE" || die "не удалось обновить $STATE_FILE"
    fi
    return 0
}

set_security_level() {
    iface="$1"
    level="$2"
    ndmc_cmd "interface $iface security-level $level" >/dev/null || {
        warn "не удалось установить security-level $level для $iface"
        return 1
    }
    return 0
}

save_keenetic() {
    ndmc_cmd "system configuration save" >/dev/null || {
        warn "не удалось сохранить конфигурацию Keenetic"
        return 1
    }
    return 0
}

restart_awg() {
    "$AWG_INIT" restart >/dev/null 2>&1 || {
        say "ПРЕДУПРЕЖДЕНИЕ: AWG Manager не подтвердил перезапуск."
        return 1
    }
    return 0
}

# Совпадением считается и конкретный адрес, и wildcard (0.0.0.0 / :: / *),
# на котором демон слушает все интерфейсы.
port_is_listening() {
    _ip="$1"
    _port="$2"

    netstat -lnt 2>/dev/null | awk -v ip="$_ip" -v p="$_port" '
        $1 ~ /^tcp/ {
            n = split($4, a, ":")
            if (n < 2) next
            addr = ""
            for (i = 1; i < n; i++) addr = addr (i > 1 ? ":" : "") a[i]
            if (a[n] == p && (addr == ip || addr == "0.0.0.0" || addr == "::" || addr == "*"))
                found = 1
        }
        END { exit !found }'
}

# Ждёт до $PORT_WAIT_SECONDS, пока AWG Manager не начнёт слушать порт:
# после рестарта демону нужно время на инициализацию.
wait_for_port() {
    _ip="$1"
    _port="$2"

    command -v netstat >/dev/null 2>&1 || {
        say "ПРЕДУПРЕЖДЕНИЕ: netstat недоступен, проверка порта пропущена."
        return 2
    }

    say "Проверка порта..."
    _elapsed=0
    while [ "$_elapsed" -lt "$PORT_WAIT_SECONDS" ]; do
        port_is_listening "$_ip" "$_port" && return 0
        _elapsed=$((_elapsed + 1))
        sleep 1
    done

    port_is_listening "$_ip" "$_port"
}

# ---------------------------------------------------------------------------
# Main actions
# ---------------------------------------------------------------------------

configure_access() {
    select_wg
    case "$?" in
        1) return 0 ;;
        2) say ""
           say "Туннели не найдены (WireGuard / ZeroTier)."
           say "Проверь: ndmc -c \"show interface Wireguard0\""
           say "         ndmc -c \"show interface ZeroTier0\""
           say "         ip link | grep -E 'nwg|zt'"
           return 1 ;;
    esac

    [ "$SEL_IP" != "-" ] || {
        say "У выбранного интерфейса нет IPv4-адреса."
        return 1
    }

    [ "$SEL_LINUX" != "-" ] || {
        say "Не найден Linux-интерфейс для $SEL_NAME (ожидается nwgN или ztN)."
        return 1
    }

    port="$(get_server_port)"

    say ""
    say "Выбран:"
    say "  Интерфейс: $SEL_NAME"
    say "  IP:        $SEL_IP"
    say "  Описание:  $SEL_DESC"
    say "  Было:      security-level $SEL_SEC"
    say "  Linux:     $SEL_LINUX"
    say ""
    say "security-level private снимает изоляцию интерфейса целиком, а не"
    say "только порт $port: с той стороны туннеля станут доступны все службы,"
    say "слушающие на 0.0.0.0. После настройки проверь: netstat -lnt"
    say ""

    printf "Продолжить? [y/N]: "
    if ! read_tty "" answer; then answer=""; fi
    case "$answer" in
        y|Y|д|Д) ;;
        *) say "Отменено."; return 0 ;;
    esac

    ensure_backup || return 1

    # Снимок непосредственно перед изменением — нужен для отката шага 1,
    # если шаг 2 не выполнится.
    before="$BACKUP_ROOT/settings.before.$SEL_NAME.json"
    cp -p "$AWG_SETTINGS" "$before" 2>/dev/null

    say "[1/4] Добавляю $SEL_LINUX в AWG Manager (.server.interfaces)..."
    add_interface_to_awg "$SEL_LINUX" || return 1

    case "$SEL_NAME" in
        zt[0-9]*|nwg[0-9]*)
            # Уже linux-имя (например zt0 из ip link) — security-level в ndmc не трогаем
            say "[2/4] security-level: пропуск (интерфейс $SEL_NAME без ndmc-имени)"
            ;;
        *)
            say "[2/4] Устанавливаю $SEL_NAME = private..."
            if ! set_security_level "$SEL_NAME" "private"; then
                say "Откатываю изменение settings.json..."
                if [ -f "$before" ] && cp -p "$before" "$AWG_SETTINGS"; then
                    say "settings.json возвращён к состоянию до запуска."
                else
                    say "ВНИМАНИЕ: откат settings.json не удался, проверь $AWG_SETTINGS"
                fi
                return 1
            fi
            ;;
    esac

    say "[3/4] Сохраняю конфигурацию Keenetic..."
    save_keenetic || say "ПРЕДУПРЕЖДЕНИЕ: конфигурация не сохранена, изменения пропадут после перезагрузки."

    say "[4/4] Перезапускаю AWG Manager..."
    restart_awg

    say ""
    wait_for_port "$SEL_IP" "$port"
    case "$?" in
        0) say "OK: AWG Manager слушает порт $port" ;;
        1) say "ПРЕДУПРЕЖДЕНИЕ: порт $port не обнаружен в LISTEN за $PORT_WAIT_SECONDS секунд."
           say "Проверь: netstat -lnt | grep $port" ;;
        2) : ;;  # already warned inside wait_for_port
    esac

    say ""
    say "Адрес AWG Manager:"
    say "  http://$SEL_IP:$port"
    say ""
    say "Точка отката сохранена в:"
    say "  $FULL_SETTINGS"
    say "  $STATE_FILE"
    return 0
}

restore_all() {
    if [ ! -f "$FULL_SETTINGS" ] && [ ! -f "$STATE_FILE" ]; then
        say ""
        say "Сохранённого состояния нет."
        return 0
    fi

    say ""
    say "Будут восстановлены изменения этого скрипта."
    say "Исходный settings.json: $FULL_SETTINGS"
    say ""

    printf "ТОЧНО вернуть всё как было? [y/N]: "
    if ! read_tty "" answer; then answer=""; fi
    case "$answer" in
        y|Y|д|Д) ;;
        *) say "Отменено."; return 0 ;;
    esac

    fail_count=0

    # Restore exact original AWG settings.
    if [ -f "$FULL_SETTINGS" ]; then
        jq empty "$FULL_SETTINGS" 2>/dev/null || die "резервный settings.json повреждён, откат остановлен"
        cp -p "$FULL_SETTINGS" "$AWG_SETTINGS" || die "не удалось восстановить settings.json"
        say "[+] settings.json восстановлен"
    fi

    # Restore exact original security levels.
    if [ -f "$STATE_FILE" ]; then
        while IFS='	' read -r iface ip oldsec linux desc timestamp; do
            [ -n "$iface" ] || continue
            [ -n "$oldsec" ] || continue
            [ "$oldsec" != "-" ] || {
                say "[!] $iface: исходный security-level неизвестен, пропускаю"
                fail_count=$((fail_count + 1))
                continue
            }

            say "[+] $iface -> security-level $oldsec"
            if ! set_security_level "$iface" "$oldsec"; then
                fail_count=$((fail_count + 1))
            fi
        done < "$STATE_FILE"
    fi

    say "[+] Сохраняю конфигурацию Keenetic..."
    save_keenetic || fail_count=$((fail_count + 1))

    say "[+] Перезапускаю AWG Manager..."
    restart_awg

    say ""
    if [ "$fail_count" -gt 0 ]; then
        say "Откат завершён С ОШИБКАМИ ($fail_count шаг(ов) не выполнены)."
        say "Проверь вручную: ndmc -c \"show interface WireguardN\""
        say "Резервная копия НЕ удалена (нужна для повторной попытки):"
        say "  $BACKUP_ROOT"
        return 1
    fi

    say "Откат завершён."
    # Полный успех: точка отката больше не актуальна для будущих запусков —
    # снимаем её, чтобы следующий configure_access() снял свежий снапшот
    # текущего (уже восстановленного) состояния.
    rm -f "$FULL_SETTINGS" "$STATE_FILE"
    rm -f "$BACKUP_ROOT"/settings.before.*.json 2>/dev/null
    say "Точка отката снята — при следующей настройке будет создана заново."
    return 0
}

show_status() {
    port="$(get_server_port)"

    say ""
    say "=== Состояние ==="
    show_wg_list

    say ""
    say "AWG Manager: порт $port, interfaces $(jq -c '.server.interfaces' "$AWG_SETTINGS" 2>/dev/null)"

    if command -v netstat >/dev/null 2>&1; then
        listen="$(netstat -lnt 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print $4}')"
        if [ -n "$listen" ]; then
            say "  LISTEN: $(printf '%s' "$listen" | tr '\n' ' ')"
        else
            say "  LISTEN на порту $port не найден"
        fi
    else
        say "  (netstat недоступен)"
    fi

    say ""
    if [ -f "$STATE_FILE" ]; then
        say "Точка отката: $BACKUP_ROOT"
        say "Изменённые интерфейсы:"
        while IFS='	' read -r iface ip oldsec linux desc ts; do
            [ -n "$iface" ] || continue
            printf '  %-11s было: %-8s %s (%s)\n' "$iface" "$oldsec" "$linux" "$ts"
        done < "$STATE_FILE"
    else
        say "Точка отката отсутствует."
    fi
    return 0
}

menu() {
    empty_streak=0
    while :; do
        say ""
        say "========================================"
        say " AWG Manager — доступ через туннель"
        say "========================================"
        say ""
        say "1. Настроить доступ через туннель (WG / ZeroTier)"
        say "2. Вернуть ВСЁ как было"
        say "3. Показать текущую конфигурацию"
        say "0. Выход"
        say ""

        if ! read_tty "Выберите [0-3]: " choice; then
            say "Нет ввода (EOF) — выход."
            exit 0
        fi

        case "$choice" in
            1) empty_streak=0; configure_access ;;
            2) empty_streak=0; restore_all ;;
            3) empty_streak=0; show_status ;;
            0) exit 0 ;;
            "")
                empty_streak=$((empty_streak + 1))
                if [ "$empty_streak" -ge 3 ]; then
                    say "Повторный пустой ввод — выход."
                    exit 0
                fi
                ;;
            *)
                empty_streak=0
                say "Неверный выбор."
                ;;
        esac
    done
}

ndmc_preflight || die "Keenetic CLI недоступен — настройка невозможна"

menu

AWG_TUNNEL_EMBED_EOF

  if ! head -1 "$TUN_TMP" | grep -q '^#!'; then
    echo "❌ Встроенный скрипт туннеля повреждён"
    rm -f "$TUN_TMP"
    return 1
  fi

  chmod +x "$TUN_TMP"
  echo "→ Запуск встроенного модуля туннеля ..."
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
