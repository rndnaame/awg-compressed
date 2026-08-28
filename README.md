# awg-compressed

Автоматическая сборка **UPX-сжатых** пакетов [awg-manager](https://github.com/hoaxisr/awg-manager) и бинарников [sing-box (amnezia-box)](https://github.com/hoaxisr/amnezia-box) для роутеров Keenetic (Entware).

Раз в несколько часов GitHub Actions скачивает свежие релизы, сжимает их и публикует в [Releases](https://github.com/rndnaame/awg-compressed/releases/tag/compressed).

**Источники:**
- IPK: [repo.hoaxisr.ru](http://repo.hoaxisr.ru)
- sing-box: зеркало `repo.hoaxisr.ru/singbox/` / hoaxisr/amnezia-box

---

## Быстрая установка на роутер

Одна команда (архитектура определится сама):

```sh
curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
```

или:

```sh
wget -qO- https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh | sh
```

Скрипт:

1. Определит архитектуру (`aarch64` / `mipsel` / `mips`)
2. Покажет, что уже установлено и что есть в релизе
3. Спросит, что ставить:
   - только **awg-manager**
   - только **sing-box**
   - **оба**
4. Если версия уже стоит — предложит обновить или пропустить
5. Скачает файл (сначала через туннели `nwg0/1`, `t2s0/1`, потом обычный канал)
6. Установит пакет / положит бинарник

---

## Что куда ставится

| Компонент | Куда |
|-----------|------|
| awg-manager | `opkg install` сжатого `.ipk` |
| sing-box | `/opt/etc/awg-manager/singbox/sing-box` |

(Опционально, при согласии) При обновлении sing-box старый файл сохраняется как `sing-box.bak`.

---

## Архитектуры

| Архитектура Entware | Суффикс в имени файла |
|---------------------|------------------------|
| aarch64 | `aarch64-3.10` / `aarch64-3.10-kn` |
| mipsel | `mipsel-3.4` / `mipsel-3.4-kn` |
| mips | `mips-3.4` / `mips-3.4-kn` |

Проверка на роутере:

```sh
opkg print-architecture
```

---

## Установка без вопросов

Удобно для скриптов и cron.

| Задача | Команда |
|--------|---------|
| Только awg-manager | `INSTALL_AWG=1 INSTALL_SB=0 sh -c "$(curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh)"` |
| Только sing-box | `INSTALL_AWG=0 INSTALL_SB=1 sh -c "$(curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh)"` |
| Оба | `INSTALL_AWG=1 INSTALL_SB=1 sh -c "$(curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh)"` |

---

## Скачивание, если GitHub «висит»

У многих провайдеров GitHub через обычный WAN недоступен или очень медленный. Установщик по очереди пробует:

1. `nwg0`, `nwg1` (туннели awg-manager)
2. `t2s0`, `t2s1`
3. default (обычный интернет)

На каждую попытку — жёсткий таймаут (~45 с), затем следующий интерфейс.

Свой список интерфейсов:

```sh
DL_IFACES="nwg0 t2s0" DL_TIMEOUT=60 sh -c "$(curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh)"
```

---

## Ручное скачивание

Файлы: [Releases → compressed](https://github.com/rndnaame/awg-compressed/releases/tag/compressed)

Пример для aarch64:

```sh
# IPK
wget -O /tmp/awg.ipk \
  "https://github.com/rndnaame/awg-compressed/releases/download/compressed/awg-manager_VERSION_aarch64-3.10-kn_compressed.ipk"
opkg install /tmp/awg.ipk

# sing-box
wget -O /opt/etc/awg-manager/singbox/sing-box \
  "https://github.com/rndnaame/awg-compressed/releases/download/compressed/singbox-VERSION-aarch64-3.10_compressed"
chmod +x /opt/etc/awg-manager/singbox/sing-box
```

`VERSION` смотрите в списке файлов релиза (меняется с каждой сборкой).

---

## Как устроена автосборка

Файл: [`.github/workflows/compress.yml`](.github/workflows/compress.yml)

| Триггер | Действие |
|---------|----------|
| По расписанию (каждые 8 часов) | Проверка и сборка |
| Вручную (Actions → Run workflow) | То же |

Шаги:

1. Скачать последние IPK и sing-box с `repo.hoaxisr.ru`
2. Сжать бинарники UPX (`-9 --lzma`, с таймаутом; без медленного `--best`)
3. Опубликовать всё в release с тегом **`compressed`**

Сжатие больших mips-бинарей может занимать несколько минут — это нормально.

---

## Файлы в репозитории

| Файл | Назначение |
|------|------------|
| `install-compressed.sh` | Установщик на роутер |
| `.github/workflows/compress.yml` | GitHub Actions: скачать → UPX → release |
| `README.md` | Эта инструкция |

Локальный скрипт для сжатия на Ubuntu/роутере (опционально): можно использовать отдельно, основная поставка — через Actions.

---

## Типичные проблемы

**Скачивание зависает**  
Дождитесь перебора интерфейсов или задайте `DL_IFACES="nwg0"`. Убедитесь, что туннель поднят.

**`Неизвестная архитектура`**  
Проверьте `opkg print-architecture`. Поддерживаются aarch64, mipsel, mips (Entware на Keenetic).

**`opkg install` ругается на версию**  
Если пакет новее/тот же — скрипт спросит. При необходимости:  
`opkg install --force-reinstall /tmp/..._compressed.ipk`

**sing-box не запускается**  
```sh
chmod +x /opt/etc/awg-manager/singbox/sing-box
/opt/etc/awg-manager/singbox/sing-box version
```

**Release пустой / старый**  
GitHub → Actions → workflow **Compress AWG + sing-box** → Run workflow.

---

## Дисклеймер

Проект **не связан** с авторами awg-manager / Amnezia / sing-box.  
Это вспомогательная автоматизация сжатия публичных сборок для экономии места на роутере.

Используйте на свой страх и риск. Перед обновлением имейте доступ к роутеру по LAN.
