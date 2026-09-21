#!/bin/sh
# ==============================================================================
# 🚀 Интерактивный установщик AmneziaWG Manager (AWGM)
# ==============================================================================
# Описание: 
#   Скрипт для удобного скачивания, установки, обновления и отката 
#   пакетов AWGM на роутерах с Entware (KeeneticOS и др.).
#
# Ключевые возможности:
#   • 🛡️ Анти-блок: автоматический перебор прокси-зеркал для GitHub.
#   • 📦 Парсинг версий: динамическое получение списка релизов через API.
#   • 🛠️ Поддержка develop: корректное извлечение номера тестовых сборок.
#   • 📜 Changelog: просмотр истории изменений релиза прямо в консоли.
#   • 🧠 Умная логика: автоопределение установленной версии (opkg) и 
#     вывод только актуальных действий (обновить/откатить/переустановить).
#   • ⚠️ Защита: предупреждение о бэкапе при форсированном изменении версии.
#   • 🧹 Изоляция: работа во временной директории (/opt/tmp).
# ==============================================================================

# Цветовая палитра
green="\033[92m"
red="\033[91m"
yellow="\033[93m"
light_blue="\033[96m"
reset="\033[0m"

REPO="hoaxisr/awg-manager"
API_URL="https://api.github.com/repos/$REPO/releases"
WORK_DIR="/opt/tmp"

clear
echo -e "${light_blue}================================================${reset}"
echo -e "${light_blue}   Интерактивный установщик AmneziaWG Manager   ${reset}"
echo -e "${light_blue}================================================${reset}\n"

download_file() {
    local url="$1"
    local output="$2"
    
    echo -e "Скачивание файла: ${yellow}${output}${reset}\n"
    
    echo -e "  [1] Прямое подключение к GitHub..."
    if curl -fLo "$output" --connect-timeout 5 "$url"; then
        echo -e "  ${green}✓ Успешно скачано напрямую${reset}"
        return 0
    fi
    
    echo -e "  ${yellow}Прямой доступ закрыт.${reset} [2] Пробуем gh-proxy.com..."
    if curl -fLo "$output" --connect-timeout 5 "https://gh-proxy.com/$url"; then
        echo -e "  ${green}✓ Успешно скачано через gh-proxy.com${reset}"
        return 0
    fi

    echo -e "  ${yellow}Сайт недоступен.${reset} [3] Пробуем ghfast.top..."
    if curl -fLo "$output" --connect-timeout 5 "https://ghfast.top/$url"; then
        echo -e "  ${green}✓ Успешно скачано через ghfast.top${reset}"
        return 0
    fi

    echo -e "\n${red}✗ Ошибка: Не удалось скачать файл ни через один из шлюзов.${reset}"
    return 1
}

# --- ШАГ 1: Получение списка версий ---
echo -e "Получение списка версий из ${yellow}${REPO}${reset}..."

releases_json=$(curl -s --connect-timeout 5 "$API_URL")
if [ -z "$releases_json" ]; then
    releases_json=$(curl -s --connect-timeout 5 "https://gh-proxy.com/$API_URL")
fi

if [ -z "$releases_json" ]; then
    echo -e "${red}Не удалось связаться с GitHub API!${reset}"
    exit 1
fi

# Мгновенно вытаскиваем все теги
tags=$(echo "$releases_json" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": "//; s/"//')

echo -e "\n${light_blue}Доступные версии:${reset}"
i=1
for t in $tags; do
    if [ "$t" = "latest" ]; then
        dev_file=$(echo "$releases_json" | grep -o '"browser_download_url": *"[^"]*"' | grep "/download/latest/awg-manager_" | head -n 1)
        if [ -n "$dev_file" ]; then
            dev_ver=$(echo "$dev_file" | sed 's/.*awg-manager_//; s/_[a-zA-Z0-9.-]*\.ipk.*//; s/%2B/+/g')
            echo -e "  $i) latest ${green}(Development build: $dev_ver)${reset}"
        else
            echo -e "  $i) latest ${green}(Development build)${reset}"
        fi
    else
        echo -e "  $i) $t"
    fi
    eval "tag_$i=\"$t\""
    i=$((i + 1))
done

echo
while true; do
    read -p "Выберите номер (x/ч - выход, c+номер - changelog, напр. c2) [1]: " ver_choice
    [ -z "$ver_choice" ] && ver_choice=1

    # Проверка на выход
    case "$ver_choice" in
        x|X|ч|Ч)
            echo -e "\n${yellow}Скрипт прерван пользователем.${reset}"
            exit 0
            ;;
    esac

    # Проверка на запрос changelog (обработка EN/RU раскладок и регистров)
    if echo "$ver_choice" | grep -q '^[cCсС][0-9][0-9]*$'; then
        # Надежное извлечение цифр (убираем все символы кроме цифр)
        cl_num=$(echo "$ver_choice" | sed 's/[^0-9]//g')
        eval "cl_tag=\$tag_$cl_num"
        if [ -n "$cl_tag" ]; then
            echo -e "\n${light_blue}================ Changelog: ${cl_tag} ================${reset}"
            # Извлекаем и форматируем описание релиза из JSON
            echo "$releases_json" | sed -n "/\"tag_name\": *\"$cl_tag\"/,/\"body\":/p" | tail -n 1 | \
            sed 's/^[[:space:]]*"body":[[:space:]]*"//; s/\",$//; s/\"$//; s/\\r\\n/\n/g; s/\\n/\n/g; s/\\"/"/g; s/\\\//\//g'
            echo -e "${light_blue}====================================================${reset}\n"
        else
            echo -e "${red}Ошибка: Версии под номером $cl_num нет в списке.${reset}\n"
        fi
        continue
    fi

    # Обычный выбор версии
    eval "selected_tag=\$tag_$ver_choice"
    if [ -n "$selected_tag" ]; then
        break
    else
        echo -e "${red}Ошибка выбора. Введите корректный номер.${reset}\n"
    fi
done

echo -e "Выбран тег: ${green}${selected_tag}${reset}\n"

# --- ШАГ 2: Выбор архитектуры ---
echo -e "${light_blue}Выберите архитектуру процессора:${reset}"
echo "  1) aarch64-3.10-kn (ARM64: KN-1011, KN-1811, KN-1910, KN-2710...)"
echo "  2) mips-3.4-kn     (MIPS: KN-1010, KN-1810, KN-1912...)"
echo "  3) mipsel-3.4-kn   (MIPSEL: KN-1111, KN-1211, KN-1611, KN-1711...)"
echo "  4) Ввести архитектуру вручную"
echo
read -p "Ваш выбор (x/ч для выхода) [по умолчанию 1]: " arch_choice
[ -z "$arch_choice" ] && arch_choice=1

if [ "$arch_choice" = "x" ] || [ "$arch_choice" = "X" ] || [ "$arch_choice" = "ч" ] || [ "$arch_choice" = "Ч" ]; then
    echo -e "\n${yellow}Скрипт прерван пользователем.${reset}"
    exit 0
fi

case "$arch_choice" in
    1) arch="aarch64-3.10-kn" ;;
    2) arch="mips-3.4-kn" ;;
    3) arch="mipsel-3.4-kn" ;;
    4) read -p "Введите суффикс (например: aarch64-3.10-kn): " arch ;;
    *) echo -e "${red}Неверный выбор.${reset}"; exit 1 ;;
esac

echo -e "Выбрана архитектура: ${green}${arch}${reset}\n"

# --- ШАГ 3: Поиск точной ссылки на файл ---
download_url=$(echo "$releases_json" | grep -o '"browser_download_url": *"[^"]*"' | grep "/download/$selected_tag/" | grep "_${arch}\.ipk" | head -n 1 | sed 's/"browser_download_url": "//; s/"//')

if [ -z "$download_url" ]; then
    echo -e "${red}Ошибка: Файл для архитектуры ${arch} в релизе ${selected_tag} не найден!${reset}"
    exit 1
fi

file_name=$(basename "$download_url" | sed 's/%2B/+/g')

# --- ШАГ 4: Переход в рабочую директорию и скачивание ---
mkdir -p "$WORK_DIR"
cd "$WORK_DIR" || { echo -e "${red}Ошибка: Не удалось получить доступ к директории ${WORK_DIR}${reset}"; exit 1; }

if ! download_file "$download_url" "$file_name"; then
    exit 1
fi

# --- ШАГ 5: Интеллектуальное меню установки ---
if [ -f "$file_name" ]; then
    downloaded_ver=$(echo "$file_name" | sed 's/awg-manager_//; s/_[^_]*\.ipk//')
    installed_ver=$(opkg status awg-manager 2>/dev/null | grep -e '^Version:' | awk '{print $2}')
    
    if [ -z "$installed_ver" ]; then
        inst_msg="${yellow}не установлен${reset}"
        action_msg="Установить пакет"
        opkg_cmd="opkg install"
    elif [ "$installed_ver" = "$downloaded_ver" ]; then
        inst_msg="${green}${installed_ver}${reset}"
        action_msg="Переустановить эту же версию (--force-reinstall)"
        opkg_cmd="opkg install --force-reinstall"
    else
        inst_msg="${green}${installed_ver}${reset}"
        if opkg compare-versions "$installed_ver" "<" "$downloaded_ver" 2>/dev/null; then
            action_msg="Обновить версию"
            opkg_cmd="opkg install"
        elif opkg compare-versions "$installed_ver" ">" "$downloaded_ver" 2>/dev/null; then
            action_msg="Откатить на старую версию (--force-downgrade)"
            opkg_cmd="opkg install --force-downgrade"
        else
            action_msg="Установить другую версию (--force-reinstall --force-downgrade)"
            opkg_cmd="opkg install --force-reinstall --force-downgrade"
        fi
    fi

    echo
    echo -e "${light_blue}Текущая ситуация:${reset}"
    echo -e "  Установлено в системе: $inst_msg"
    echo -e "  Скачанный пакет:       ${green}${downloaded_ver}${reset}"
    echo
    echo "Что вы хотите сделать?"
    echo "  1) Оставить как есть (только сохранить архив)"
    echo -e "  2) ${green}${action_msg}${reset}"
    echo "  3) Распаковать архив"
    read -p "Ваш выбор (x/ч для выхода) [1]: " action_choice
    
    [ -z "$action_choice" ] && action_choice=1

    case "$action_choice" in
        x|X|ч|Ч)
            echo -e "\n${yellow}Скрипт прерван пользователем. Файл сохранен в ${WORK_DIR}/${file_name}.${reset}"
            exit 0
            ;;
        2)
            if echo "$opkg_cmd" | grep -q "force"; then
                echo -e "\n${red}ВНИМАНИЕ: Перед переустановкой или откатом версии необходимо сделать бэкап настроек AWGM!${reset}"
                read -p "Продолжить установку? (y/n/н) [y]: " confirm_install
                [ -z "$confirm_install" ] && confirm_install="y"
                case "$confirm_install" in
                    n|N|н|Н|x|X|ч|Ч)
                        echo -e "\n${yellow}Установка отменена. Файл сохранен в ${WORK_DIR}/${file_name}.${reset}"
                        exit 0
                        ;;
                esac
            fi
            
            echo -e "\nЗапуск установки: ${yellow}${opkg_cmd} ${file_name}${reset}"
            $opkg_cmd "$file_name"
            echo -e "\nUsage: /opt/etc/init.d/S99awg-manager {start|stop|restart|status}"
            ;;
        3)
            echo -e "\nРаспаковка ${yellow}${file_name}${reset} в директорию ${WORK_DIR}..."
            dir_name="${file_name%.ipk}_extracted"
            mkdir -p "$dir_name"
            if tar -xzf "$file_name" -C "$dir_name" 2>/dev/null; then
                echo -e "${green}Архив распакован в папку ${WORK_DIR}/${dir_name}/${reset}"
            elif ar x "$file_name" --output "$dir_name" 2>/dev/null; then
                echo -e "${green}Архив распакован (через ar) в папку ${WORK_DIR}/${dir_name}/${reset}"
            else
                echo -e "${red}Не удалось распаковать архив.${reset}"
            fi
            ;;
        *)
            echo -e "\n${green}Файл сохранен в ${WORK_DIR}/${file_name}.${reset}"
            ;;
    esac
fi

echo -e "\n${green}Готово!${reset}"
