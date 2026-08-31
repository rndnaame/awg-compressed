# awg-compressed

UPX-сжатые сборки **awg-manager** и **sing-box** для Keenetic + Entware, плюс установщик с меню на роутере.

| | |
|---|---|
| Релиз с файлами | [Releases → `compressed`](https://github.com/rndnaame/awg-compressed/releases/tag/compressed) |
| Установщик | [`install-compressed.sh`](https://github.com/rndnaame/awg-compressed/blob/main/install-compressed.sh) |
| Исходники пакетов | [hoaxisr/awg-manager](https://github.com/hoaxisr/awg-manager), [hoaxisr/amnezia-box](https://github.com/hoaxisr/amnezia-box), зеркало [repo.hoaxisr.ru](http://repo.hoaxisr.ru) |

GitHub Actions раз в ~12 часов проверяет зеркало и публикует:

| Релиз | Пример | Поведение |
|-------|--------|-----------|
| **Топик awg-manager** | `v2.17.4 (awg-manager UPX)` → тег `awgm-2.17.4` | архив, **остаётся навсегда** |
| **Топик sing-box** | `…awgm.15 (sing-box UPX)` → тег `sb-…` | архив, **остаётся навсегда** |
| **Latest** | тег **`compressed`** | **только крайние** версии; старые файлы из этого тега удаляются |

Установщик всегда берёт файлы из `compressed`. Старые сборки смотрите в топиках `awgm-*` / `sb-*`.

---

## Установка на роутер (одна команда)

```sh
curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
```

или:

```sh
wget -qO- https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
```

Нужны: Entware, `opkg`, root. Архитектура определяется сама.

### Меню

```
Что сделать?
  [1] Установить awg-manager (UPX-версия)          ← по умолчанию
  [2] Установить sing-box (UPX-версия)
  [3] Установить awg-manager + sing-box (UPX-версия)
  [4] Установка awg-manager (с выбором версии)
  [5] Настроить доступ через туннель
  [0] Отмена
```

| Пункт | Что делает |
|-------|------------|
| **1** | Сжатый IPK из release `compressed` этого репозитория |
| **2** | Сжатый бинарник sing-box из того же release |
| **3** | Пункты 1 + 2 |
| **4** | **Официальный** (несжатый) IPK с GitHub/зеркала, можно выбрать версию из списка |
| **5** | Скрипт доступа AWG Manager через WireGuard-интерфейс Keenetic |

Для пунктов **1–3** скрипт сравнивает версии: предложит обновить, переустановить или пропустить.  
Для **4**: `Номер (1–N) или версия (Enter = последняя, 0 = выход)`.

---

## Куда ставятся файлы

| Компонент | Путь |
|-----------|------|
| awg-manager | через `opkg install` (пакет) |
| sing-box | `/opt/etc/awg-manager/singbox/sing-box` |

Бэкап старого sing-box (`sing-box.bak`) — **только если согласитесь** (или `BACKUP_SB=1`).

---

## Архитектуры

| Entware | IPK / sing-box |
|---------|----------------|
| aarch64 | `aarch64-3.10-kn` / `aarch64-3.10` |
| mipsel | `mipsel-3.4-kn` / `mipsel-3.4` |
| mips | `mips-3.4-kn` / `mips-3.4` |

```sh
opkg print-architecture
```

---

## Если GitHub не открывается

Скачивание идёт по очереди через интерфейсы (таймаут ~45 с на каждый):

1. `nwg0`, `nwg1`  
2. `t2s0`, `t2s1`  
3. `opkgtun10`, `awgm0`  
4. обычный канал (default)

Свой список:

```sh
DL_IFACES="nwg0 opkgtun10" DL_TIMEOUT=60 \
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

Пример:

```sh
INSTALL_AWG=1 INSTALL_SB=0 sh -c "$(curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh)"
```

Пункты **4** и **5** в неинтерактивном режиме не вызываются — только через меню.

---

## Ручное скачивание из release

[Список файлов](https://github.com/rndnaame/awg-compressed/releases/tag/compressed)

```sh
# пример aarch64 — VERSION смотрите в релизе
wget -O /tmp/awg.ipk \
  "https://github.com/rndnaame/awg-compressed/releases/download/compressed/awg-manager_VERSION_aarch64-3.10-kn_compressed.ipk"
opkg install /tmp/awg.ipk

wget -O /opt/etc/awg-manager/singbox/sing-box \
  "https://github.com/rndnaame/awg-compressed/releases/download/compressed/singbox-VERSION-aarch64-3.10_compressed"
chmod +x /opt/etc/awg-manager/singbox/sing-box
```

---

## Автосборка (GitHub Actions)

Файл: [`.github/workflows/compress.yml`](.github/workflows/compress.yml)

1. Сравнивает версии на `repo.hoaxisr.ru` с ассетами release `compressed`
2. Если всё уже есть — **выходит без работы**
3. Иначе качает только недостающее, UPX (`-9 --lzma`, с таймаутом), публикует

Запуск вручную: **Actions → Compress AWG + sing-box → Run workflow**  
(не «Re-run» старого job — там может быть старый yaml).

---

## Файлы репозитория

| Файл | Назначение |
|------|------------|
| `install-compressed.sh` | Меню и установка на роутере |
| `awg-manager-tunnel-access.sh` | Пункт [5]: доступ через WG (оригинал: [genaRijoff/awgm_tun_wgX](https://github.com/genaRijoff/awgm_tun_wgX)) |
| `.github/workflows/compress.yml` | Автосжатие и публикация |
| `README.md` | Документация |

---

## Частые проблемы

| Симптом | Что сделать |
|---------|-------------|
| Скачивание долго / таймауты | Поднять туннель (`nwg0` и т.п.) или `DL_IFACES=...` |
| «Неизвестная архитектура» | `opkg print-architecture` — нужны aarch64 / mipsel / mips |
| opkg ругается на версию | Согласиться на обновление в меню или `opkg install --force-reinstall …` |
| Пункт [5] крутит меню | Обновить `awg-manager-tunnel-access.sh` в `main` (чтение с `/dev/tty`) |
| Release без новых файлов | Actions → **Run workflow**; в логе должны быть `SKIP` / `BUILD` |

sing-box:

```sh
chmod +x /opt/etc/awg-manager/singbox/sing-box
/opt/etc/awg-manager/singbox/sing-box version
```

---

## Дисклеймер

Проект **не связан** с авторами awg-manager, Amnezia и sing-box.  
Это вспомогательная автоматизация сжатия публичных сборок и удобный установщик.

Используйте на свой страх и риск. Перед обновлением сохраните доступ к роутеру по LAN.
