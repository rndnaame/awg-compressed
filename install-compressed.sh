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
  first=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -1)
  if [ "$first" = "$v1" ]; then
    echo 2
  else
    echo 1
  fi
}

# Жёсткий таймаут процесса (curl на роутере часто игнорирует --max-time)
run_timeout() {
  secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" 2>/dev/null
    return $?
  fi
  # fallback: фоновый процесс + kill
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

# Скачивание: сначала туннели (nwg/t2s), default — последним
# DL_IFACES="nwg0 opkgtun10 awgm0" — свой порядок
download_file() {
  url="$1"
  out="$2"
  min_size="${3:-1000}"
  # на попытку: connect быстро, весь файл не дольше ~45с на iface
  try_secs="${DL_TIMEOUT:-45}"

  rm -f "$out"
  # туннели первыми — GitHub через WAN часто «висит»
  ifaces="${DL_IFACES:-nwg0 nwg1 t2s0 t2s1 opkgtun10 awgm0 __default__}"

  for iface in $ifaces; do
    if [ "$iface" = "__default__" ]; then
      label="default"
      iface_opt=""
    else
      if ! ip link show "$iface" >/dev/null 2>&1 && ! ifconfig "$iface" >/dev/null 2>&1; then
        echo "   ⏭  $iface — нет интерфейса"
        continue
      fi
      label="$iface"
      iface_opt="--interface $iface"
    fi

    echo "   ↻ через $label (макс ${try_secs}с) ..."
    rm -f "$out"
    # shellcheck disable=SC2086
    run_timeout "$try_secs" curl -fL --connect-timeout 8 --max-time "$try_secs" \
      --speed-time 15 --speed-limit 1000 \
      $iface_opt -o "$out" "$url"
    rc=$?
    if [ -s "$out" ] && [ "$(wc -c < "$out" 2>/dev/null || echo 0)" -ge "$min_size" ]; then
      echo "   ✓ скачано через $label ($(du -h "$out" | awk '{print $1}'))"
      return 0
    fi
    [ "$rc" = "124" ] && echo "   ⏱  таймаут $label"
    rm -f "$out"

    # wget только для default (без bind iface)
    if [ "$iface" = "__default__" ] && command -v wget >/dev/null 2>&1; then
      echo "   ↻ wget default (макс ${try_secs}с) ..."
      run_timeout "$try_secs" wget -q -T 15 -O "$out" "$url"
      if [ -s "$out" ] && [ "$(wc -c < "$out" 2>/dev/null || echo 0)" -ge "$min_size" ]; then
        echo "   ✓ скачано через wget ($(du -h "$out" | awk '{print $1}'))"
        return 0
      fi
      rm -f "$out"
    fi
  done

  echo "   ✗ не удалось скачать"
  return 1
}

fetch_text() {
  url="$1"
  try_secs=20
  ifaces="nwg0 nwg1 t2s0 t2s1 opkgtun10 awgm0 __default__"
  for iface in $ifaces; do
    if [ "$iface" = "__default__" ]; then
      iface_opt=""
    else
      ip link show "$iface" >/dev/null 2>&1 || ifconfig "$iface" >/dev/null 2>&1 || continue
      iface_opt="--interface $iface"
    fi
    tmpf=$(mktemp 2>/dev/null || echo "/tmp/ft_$$")
    # shellcheck disable=SC2086
    run_timeout "$try_secs" curl -fsL --connect-timeout 6 --max-time "$try_secs" \
      $iface_opt -o "$tmpf" "$url"
    if [ -s "$tmpf" ]; then
      cat "$tmpf"
      rm -f "$tmpf"
      return 0
    fi
    rm -f "$tmpf"
  done
  return 1
}


# Пункт меню [4]: установка AWG Manager с выбором версии (официальный IPK)
install_awg_version_select() {
  echo ""
  echo "=== Установка AWG Manager (выбор версии) ==="
  echo ""

  case "$ARCH" in
    aarch64) S="aarch64-3.10-kn"; R="aarch64-k3.10" ;;
    mipsel)  S="mipsel-3.4-kn";   R="mipsel-k3.4" ;;
    mips)    S="mips-3.4-kn";     R="mips-k3.4" ;;
    *)
      echo "❌ Неизвестная архитектура: $ARCH"
      return 1
      ;;
  esac
  echo "✅ Архитектура: $A → $S"

  mkdir -p /opt/etc/opkg
  echo "src/gz hoaxisr http://repo.hoaxisr.ru/$R" > /opt/etc/opkg/awg_manager.conf
  echo "✅ Репозиторий: http://repo.hoaxisr.ru/$R"

  echo "→ Список релизов hoaxisr/awg-manager..."
  API_JSON=$(fetch_text "https://api.github.com/repos/hoaxisr/awg-manager/releases?per_page=15" || true)
  VERSIONS=$(echo "$API_JSON" | sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p' | grep -v '^latest$' | head -10)

  if [ -z "$VERSIONS" ]; then
    echo "   API пуст, пробуем HTML..."
    HTML=$(fetch_text "https://github.com/hoaxisr/awg-manager/releases" || true)
    VERSIONS=$(echo "$HTML" | grep -oE '/hoaxisr/awg-manager/releases/tag/v[0-9][^"<> ]+' | sed 's|.*/||' | sort -u | sort -Vr | head -10)
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

  c=$(ask "Номер (1-$max) или версия (Enter = последняя, 0 = выход): " "")
  if [ -z "$c" ]; then
    ver=$(head -1 /tmp/awg-ver-list.$$)
  elif [ "$c" = "0" ]; then
    echo "Отменено."
    rm -f /tmp/awg-ver-list.$$
    return 0
  elif echo "$c" | grep -qE '^[0-9]+$'; then
    if [ "$c" -ge 1 ] && [ "$c" -le "$max" ]; then
      ver=$(sed -n "${c}p" /tmp/awg-ver-list.$$)
    else
      echo "❌ Номер вне диапазона 1-$max (0 = выход)"
      rm -f /tmp/awg-ver-list.$$
      return 1
    fi
  else
    ver="$c"
  fi
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

# Пункт меню [5]: настройка доступа AWG Manager через WireGuard-туннель
# Источник: https://github.com/genaRijoff/awgm_tun_wgX
TUNNEL_SCRIPT_URL="https://raw.githubusercontent.com/rndnaame/awg-compressed/main/awg-manager-tunnel-access.sh"

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

  # проверка, что это shell-скрипт, а не HTML-ошибка GitHub
  if ! head -1 "$TUN_TMP" | grep -q '^#!'; then
    echo "❌ Скачанный файл не похож на скрипт (нет shebang)"
    head -5 "$TUN_TMP" | sed 's/^/   /'
    rm -f "$TUN_TMP"
    return 1
  fi

  chmod +x "$TUN_TMP"
  echo "→ Запуск $TUN_TMP ..."
  echo ""
  # Важно: при запуске через «curl | sh» stdin — это труба со скриптом.
  # Без /dev/tty дочернее меню читает оставшиеся строки install-скрипта
  # как ответы и «крутится» много раз.
  if [ -r /dev/tty ]; then
    # subshell: fd 0 = tty so all reads block on real terminal
    ( cd /tmp && exec </dev/tty >/dev/tty 2>/dev/tty; sh "$TUN_TMP" )
  else
    sh "$TUN_TMP"
  fi
  rc=$?
  rm -f "$TUN_TMP"
  return "$rc"
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
API_JSON=$(fetch_text "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" || true)
ASSETS=$(echo "$API_JSON" | grep -oE '"browser_download_url":\s*"[^"]+"' | sed 's/.*"\([^"]*\)"/\1/' || true)

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

# при нескольких версиях в одном релизе — берём самую новую (sort -V)
IPK_URL=$(echo "$ASSETS" | grep -E "$IPK_PAT" | sort -V | tail -1)
SB_URL=$(echo "$ASSETS" | grep -E "$SB_PAT" | sort -V | tail -1)

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
  echo "  [1] Установить awg-manager (UPX-версия)"
  echo "  [2] Установить sing-box (UPX-версия)"
  echo "  [3] Установить AWG-M + Sing-Box (UPX-версия)"
  echo "  [4] Установка AWG-M (с выбором версии)"
  echo "  [5] Настроить доступ через туннель"
  echo "  [0] Отмена"
  echo ""
  choice=$(ask "Выбор [0-5], по умолчанию 1: " "1")
  case "$choice" in
    1) DO_AWG=1; DO_SB=0 ;;
    2) DO_AWG=0; DO_SB=1 ;;
    3) DO_AWG=1; DO_SB=1 ;;
    4)
      install_awg_version_select
      exit $?
      ;;
    5)
      run_tunnel_access
      exit $?
      ;;
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
  if ! download_file "$IPK_URL" "$IPK_NAME" 100000; then
    echo "❌ Ошибка скачивания IPK (пробовали nwg0/1, t2s0/1, opkgtun10, awgm0, default)"
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
  if ! download_file "$SB_URL" "$SB_NAME" 100000; then
    echo "❌ Ошибка скачивания sing-box (пробовали nwg0/1, t2s0/1, opkgtun10, awgm0, default)"
    exit 1
  fi
  mkdir -p "$SINGBOX_DIR"
  # бэкап старого — только по запросу
  if [ -x "$SINGBOX_DIR/sing-box" ] && { [ "$SB_MODE" = "upgrade" ] || [ "$SB_MODE" = "replace" ]; }; then
    if [ -n "$BACKUP_SB" ]; then
      # неинтерактивно: BACKUP_SB=1
      case "$BACKUP_SB" in
        1|y|Y|yes|YES)
          cp "$SINGBOX_DIR/sing-box" "$SINGBOX_DIR/sing-box.bak" 2>/dev/null || true
          echo "   💾 бэкап → $SINGBOX_DIR/sing-box.bak"
          ;;
      esac
    else
      if [ "$(yes_no "Сохранить старый sing-box как sing-box.bak? [y/N]: " "n")" = "1" ]; then
        cp "$SINGBOX_DIR/sing-box" "$SINGBOX_DIR/sing-box.bak" 2>/dev/null || true
        echo "   💾 бэкап → $SINGBOX_DIR/sing-box.bak"
      fi
    fi
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
