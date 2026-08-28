Скрипт:

определяет архитектуру через opkg print-architecture (aarch64 / mipsel / mips);
качает нужный *_compressed.ipk и singbox-*_compressed;
ставит IPK через opkg;
кладёт sing-box в /opt/etc/awg-manager/singbox/sing-box.


Можно задать свои интерфейсы:
shDL_IFACES="nwg0 t2s0" sh -c "$(curl -sL https://raw.githubusercontent.com/rndnaame/awg-compressed/main/install-compressed.sh)"
