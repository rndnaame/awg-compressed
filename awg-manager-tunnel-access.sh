#!/bin/sh
#
# AWG Manager Tunnel Access for Keenetic + Entware
# Russian interface
#
# Purpose:
#   Give AWG Manager access through a selected Keenetic WireGuard
#   interface and provide a reliable rollback to the exact saved state.
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
PORT_WAIT_SECONDS=10

TMP_LIST="/tmp/awg-wg-list.$$"
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
# WireGuard interface discovery (Keenetic CLI side)
# ---------------------------------------------------------------------------

# Оба парсера печатают 5 полей через TAB: ip, desc, sec, state, link.
# Пустые значения заменяются на "-": при разборе строки через IFS=TAB
# пустые поля схлопываются (TAB — whitespace для field splitting).

parse_wg_json() {
    printf '%s' "$1" | jq -r '
        def d: if . == null or . == "" then "-" else . end;
        if ((.type // "") | ascii_downcase) == "wireguard" then
            [ (.address | d),
              (.description | d),
              (."security-level" | d),
              (.state | d),
              (.link | d) ] | @tsv
        else empty end' 2>/dev/null
}

parse_wg_text() {
    _o="$1"

    printf '%s' "$_o" | grep -qi 'type:[[:space:]]*wireguard' || return 1

    _ip="$(printf '%s' "$_o" | sed -n 's/^[[:space:]]*address:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"
    _desc="$(printf '%s' "$_o" | sed -n 's/^[[:space:]]*description:[[:space:]]*\(.*\)$/\1/p' | head -n 1 | tr '\t' ' ')"
    _sec="$(printf '%s' "$_o" | sed -n 's/^[[:space:]]*security-level:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"
    _state="$(printf '%s' "$_o" | sed -n 's/^[[:space:]]*state:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"
    _link="$(printf '%s' "$_o" | sed -n 's/^[[:space:]]*link:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)"

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${_ip:--}" "${_desc:--}" "${_sec:--}" "${_state:--}" "${_link:--}"
    return 0
}

list_wg_interfaces() {
    _i=0
    while [ "$_i" -le "$MAX_WG_INDEX" ]; do
        if _out="$(ndmc_try "show interface Wireguard$_i")" && [ -n "$_out" ]; then
            if [ "$NDMC_FORMAT" = "json" ]; then
                _fields="$(parse_wg_json "$_out")"
            else
                _fields="$(parse_wg_text "$_out")"
            fi
            [ -n "$_fields" ] && printf 'Wireguard%s\t%s\n' "$_i" "$_fields"
        fi
        _i=$((_i + 1))
    done
}

get_linux_name() {
    # Keenetic WireguardN normally maps to nwgN. We verify it exists.
    n="${1#Wireguard}"
    if ip link show "nwg$n" >/dev/null 2>&1; then
        printf 'nwg%s\n' "$n"
    else
        printf '%s\n' "-"
    fi
}

show_wg_list() {
    say ""
    say "Опрашиваю Keenetic CLI..."
    list_wg_interfaces > "$TMP_LIST"

    if [ ! -s "$TMP_LIST" ]; then
        say "WireGuard-интерфейсы не найдены (Wireguard0-$MAX_WG_INDEX)."
        return 1
    fi

    say ""
    say "WireGuard:"
    while IFS='	' read -r name ip desc sec state link; do
        printf '  %-11s %-15s %-9s %s (%s/%s)\n' "$name" "$ip" "$sec" "$desc" "$state" "$link"
    done < "$TMP_LIST"
    return 0
}

# 0 — выбран интерфейс, 1 — отмена/неверный ввод, 2 — интерфейсов нет
select_wg() {
    say ""
    say "Опрашиваю Keenetic CLI..."
    list_wg_interfaces > "$TMP_LIST"
    [ -s "$TMP_LIST" ] || return 2

    say ""
    say "Выберите WireGuard:"
    say ""
    n=1
    while IFS='	' read -r name ip desc sec state link; do
        printf '%s) %s — %s — %s (%s/%s)\n' "$n" "$name" "$ip" "$desc" "$state" "$link"
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
           say "WireGuard-интерфейсы не найдены."
           say "ndmc отвечает, но ни один Wireguard0-$MAX_WG_INDEX не вернул type: Wireguard."
           say "Проверь вручную: ndmc -c \"show interface Wireguard0\""
           return 1 ;;
    esac

    [ "$SEL_IP" != "-" ] || {
        say "У выбранного интерфейса нет IPv4-адреса."
        return 1
    }

    [ "$SEL_LINUX" != "-" ] || {
        say "Не найден Linux-интерфейс $SEL_NAME -> ожидается nwgN."
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
        say " AWG Manager — доступ через WireGuard"
        say "========================================"
        say ""
        say "1. Настроить доступ через туннель"
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
