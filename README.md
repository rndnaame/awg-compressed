# awg-compressed

UPX-сжатые сборки **awg-manager** и **sing-box** для Keenetic + Entware, плюс интерактивный установщик на роутере.

| | |
|---|---|
| Релиз с актуальными файлами | [Releases → **Latest** (`upx`)](https://github.com/rndnaame/awg-compressed/releases/tag/upx) |
| Установщик | [`install-compressed.sh`](https://github.com/rndnaame/awg-compressed/blob/main/install-compressed.sh) |
| Исходники | [hoaxisr/awg-manager](https://github.com/hoaxisr/awg-manager), [hoaxisr/amnezia-box](https://github.com/hoaxisr/amnezia-box), зеркало [repo.hoaxisr.ru](http://repo.hoaxisr.ru) |

GitHub Actions (каждые 12 часов / вручную) проверяет зеркало и публикует:

| Релиз | Тег | Поведение |
|-------|-----|-----------|
| **Latest** | **`upx`** | только крайние UPX-версии; обновляется при появлении новых |
| **Топик awg-manager** | `awgm-2.19.x` | архив, **не удаляется** |
| **Топик sing-box** | `sb-1.15.0-…` | архив, **не удаляется** |

Установщик берёт актуальные UPX-файлы из тега **`upx`**. Старые сборки — в топиках `awgm-*` / `sb-*`.

Если на зеркале ничего нового — workflow **ничего не пересобирает и релиз не трогает**.

---

## Установка на роутер

```sh
curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
```

или:

```sh
wget -qO- https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
```

Нужны: **Entware**, `opkg`, root. Архитектура определяется как в [nfqws-menu](https://github.com/rndnaame/nfqws-menu): `opkg print-architecture` → `opkg.conf` → `uname` (mips на Keenetic не используется).

### Меню

```
Выбрать пакет для установки:

  AWG-Manager
    [1]  официальная версия  ~28M
    [2]  UPX версия (сжатая)  ~8M

  Sing-Box
    [3]  официальная версия  ~59M
    [4]  UPX версия (сжатая)  ~13M

  прочее
    [5]  Настроить доступ через туннель
    [88] Удаление компонентов
    [0]  выход
```

| Пункт | Что делает |
|-------|------------|
| **1** | Официальный IPK awg-manager (hoaxisr + зеркало), выбор версии |
| **2** | UPX IPK awg-manager из топиков `awgm-*`, выбор версии |
| **3** | Официальный бинарник sing-box (hoaxisr/amnezia-box), выбор версии |
| **4** | UPX бинарник sing-box из топиков `sb-*`, выбор версии |
| **5** | Доступ к AWG Manager через туннель (WG / ZeroTier), встроенный модуль |
| **88** | Удаление: Sing-Box / AWG-Manager / полное |
| **0** | Выход |

**Подменю версий (1–4):** номер `1–N` или строка версии; `cN` — changelog; **Enter / 0** — в главное меню.  
**Главное меню:** **Enter / [0]** — выход.

При установке awg-manager: `opkg update`, зависимости (`ip-full`, `wireguard-tools`, `conntrack`), при ошибке — `--force-depends`.  
Перед force-reinstall / force-downgrade — предупреждение о бэкапе.

### Удаление [88]

| Подпункт | Действие |
|----------|----------|
| **1** | Удалить Sing-Box (`sing-box`, meta, bak) |
| **2** | `opkg remove awg-manager` (конфиг сохраняется) |
| **3** | Полное удаление (см. ниже) |

Полное удаление:

```sh
opkg remove awg-manager
rm -f /opt/etc/opkg/awg_manager.conf
rm -rf /opt/etc/awg-manager /opt/etc/awg-manager.pre-restore-*
ndmc -c "no ip host awgm-dnscheck.test"
ndmc -c "system configuration save"
```

---

## Куда ставятся файлы

| Компонент | Путь |
|-----------|------|
| awg-manager | через `opkg install` |
| sing-box | `/opt/etc/awg-manager/singbox/sing-box` |
| версия sing-box | `/opt/etc/awg-manager/singbox/sing-box.meta.json` |

Бэкап `sing-box.bak` — только по согласию (или `BACKUP_SB=1`).

---

## Архитектуры

| ARCH | IPK | sing-box |
|------|-----|----------|
| aarch64 | `aarch64-3.10-kn` | `aarch64-3.10` |
| mipsel | `mipsel-3.4-kn` | `mipsel-3.4` |
| mips | `mips-3.4-kn` | `mips-3.4` |

```sh
opkg print-architecture
# или
grep -E '^arch |^src' /opt/etc/opkg.conf
```

---

## Скачивание (если GitHub недоступен)

Порядок:

1. **Напрямую** (короткий таймаут)
2. **Зеркала** GitHub (`gh-proxy.com`, `ghfast.top`, …)
3. **Туннель-интерфейсы:** `nwg0`, `nwg1`, `t2s0`, `t2s1`, `opkgtun10`, `awgm0`, default

Свой список:

```sh
DL_IFACES="nwg0 t2s0" DL_TIMEOUT=60 \
  sh -c "$(curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh)"
```

---

## Без меню (скрипты / cron)

| Задача | Переменные |
|--------|------------|
| Только UPX awg-manager | `INSTALL_AWG=1 INSTALL_SB=0` |
| Только UPX sing-box | `INSTALL_AWG=0 INSTALL_SB=1` |
| Оба UPX | `INSTALL_AWG=1 INSTALL_SB=1` |
| Бэкап sing-box | `BACKUP_SB=1` |
| Без цветов | `NO_COLOR=1` |

```sh
INSTALL_AWG=1 INSTALL_SB=0 sh -c "$(curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh)"
```

Неинтерактивный режим ставит **последние UPX** из тега `upx` (пункты 1–5, 88 — только через меню).

---

## Ручное скачивание

[Ассеты Latest](https://github.com/rndnaame/awg-compressed/releases/tag/upx)

```sh
# VERSION — из имени файла в релизе
wget -O /tmp/awg.ipk \
  "https://github.com/rndnaame/awg-compressed/releases/download/upx/awg-manager_VERSION_aarch64-3.10-kn_compressed.ipk"
opkg install /tmp/awg.ipk

mkdir -p /opt/etc/awg-manager/singbox
wget -O /opt/etc/awg-manager/singbox/sing-box \
  "https://github.com/rndnaame/awg-compressed/releases/download/upx/singbox-VERSION-aarch64-3.10_compressed"
chmod +x /opt/etc/awg-manager/singbox/sing-box
```

---

## Автосборка (GitHub Actions)

[`.github/workflows/compress.yml`](.github/workflows/compress.yml)

1. Сравнивает `repo.hoaxisr.ru` с ассетами тега **`upx`**
2. Если всё актуально — **выход, релиз не пересоздаётся**
3. Иначе: UPX (`-9 --lzma`), топик-релиз + обновление **Latest**
4. UPX-бинарь качается **только если есть что сжимать**

Запуск: **Actions → Compress AWG + sing-box → Run workflow**

---

## Файлы репозитория

| Файл | Назначение |
|------|------------|
| `install-compressed.sh` | Меню, установка, туннель [5], удаление [88] |
| `.github/workflows/compress.yml` | Автосжатие и публикация |
| `README.md` | Документация |

---

## Частые проблемы

| Симптом | Что сделать |
|---------|-------------|
| «Неизвестная архитектура: пусто» | Проверьте `PATH` (`/opt/bin`), `opkg print-architecture`, `opkg.conf` |
| Скачивание долго / таймауты | Туннель (`nwg0`…) или `DL_IFACES=…` |
| opkg: нет ip-full / wireguard-tools | Скрипт ставит зависимости сам; иначе `opkg update && opkg install ip-full wireguard-tools conntrack` |
| «incompatible with the architectures» | После deps — повтор с `--force-depends` (скрипт делает сам) |
| Пункт [5] / jq | Предлагается установить `jq` через opkg |
| Release без новых файлов | Норма, если версии уже в `upx`; иначе Actions → **Run workflow** |

```sh
/opt/etc/awg-manager/singbox/sing-box version
opkg list-installed | grep awg-manager
```

---

## Дисклеймер

Проект **не связан** с авторами awg-manager, Amnezia и sing-box.  
Вспомогательная автоматизация сжатия публичных сборок и установщик.

Используйте на свой страх и риск. Перед обновлением сохраните доступ к роутеру по LAN.
'''
