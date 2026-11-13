# amneziawg-hop

نصب AmneziaWG 2.0 روی سرور شخصی با یه دستور: تونل لایه‌ی ۳ برای کل دستگاه، با هدرهای مبهم، بسته‌های نویز، تقلید QUIC و پورت‌هاپینگ UDP.
English version: [below](#english)

آموزش ویدیویی (فارسی): کانال یوتیوب [@V7lthronyx](https://www.youtube.com/@V7lthronyx)، اینترنت آزاد فصل ۲: [قسمت ۴ — وایرگارد معمولی تو ۳ ثانیه لو میره](https://youtu.be/hopf439iVUE).

## چرا وایرگارد معمولی کافی نیست

هندشیک وایرگارد همیشه یه بسته‌ی UDP به طول ۱۴۸ بایت با چهار بایت اول `01 00 00 00` ـه، و جوابش ۹۲ بایت با `02 00 00 00`. یه فیلتر ساده همین الگو رو می‌گیره و همون بسته‌ی اول رو می‌اندازه. AmneziaWG همون هسته‌ی سریع وایرگارده، با این تفاوت که این امضاها رو از بین می‌بره:

| پارامتر | کار | باید دو طرف یکی باشه؟ |
|---|---|---|
| `H1`–`H4` | به‌جای نوع ثابت پیام (۱ تا ۴)، هر بسته یه عدد تصادفی از یه بازه‌ی جدا برمی‌داره | بله |
| `S1`–`S4` | بایت تصادفی به ابتدای پیام‌های Initiation، Response، Cookie و Transport اضافه می‌کنه؛ طول ثابت ۱۴۸ و ۹۲ بایت از بین میره | بله |
| `Jc`، `Jmin`، `Jmax` | قبل از هندشیک `Jc` بسته‌ی نویز با طول بین `Jmin` و `Jmax` می‌فرسته | نه |
| `I1` | یه بسته‌ی ساختگی شبیه QUIC Initial قبل از هندشیک می‌فرسته تا جریان شبیه HTTP/3 دیده بشه | نه (فقط کلاینت) |

مقدارها موقع نصب با `/dev/urandom` ساخته میشن و هر سرور مقادیر خودش رو داره.

## چی کار می‌کنه

- `amneziawg-go` و `awg` و `awg-quick` رو نصب می‌کنه. باینری‌ها از سورس رسمی `amnezia-vpn` با نسخه‌ی ثابت ساخته شدن (`amneziawg-go v3.1.20260828`، `amneziawg-tools v3.1.20260812`)، استاتیک‌ان و روی Ubuntu 22.04 / 24.04 و Debian 12 بدون هیچ وابستگی دیگه‌ای اجرا میشن. هش SHA-256 بسته‌ها توی خود `install.sh` ثابت شده، پس با چک کردن `install.sh.sha256` کل زنجیره چک میشه.
- کلید Curve25519 سرور و کلاینت، کلید اشتراکی (`PresharedKey`) و پارامترهای مبهم‌سازی رو تصادفی می‌سازه.
- سرویس `awg-quick@awg0` رو توی یه واحد systemd محدودشده بالا میاره. اگه کرنل ماژول `amneziawg` داشته باشه از اون استفاده میشه، وگرنه `amneziawg-go` (فضای کاربر) که روی OpenVZ و LXC هم کار می‌کنه.
- با یه قانون `iptables PREROUTING` بازه‌ی `30000:50000` رو روی پورت `51820` ریدایرکت می‌کنه. قانون‌ها داخل کانفیگ `awg0` هستن (`PostUp` / `PostDown`)، پس با بالا و پایین اومدن تونل میان و میرن و نیازی به `iptables-persistent` نیست.
- کلاینت‌ها رو از هم جدا می‌کنه (Peer Isolation)، دسترسی به `169.254.0.0/16` (متادیتای ابری) و رنج‌های خصوصی رو می‌بنده، `TCPMSS --clamp-mss-to-pmtu` و `MTU = 1280` می‌ذاره و `MASQUERADE` رو فعال می‌کنه.
- اگه از قسمت‌های قبل `xhttp-reality` (`443/tcp`) یا `hysteria2-hop` (`443/udp` و `20000:50000`) روی همون سرور داری، بازه‌ی پرش خودکار به `50001:60000` میره و هر سه کنار هم کار می‌کنن.

## پیش‌نیاز

- سرور خارج از ایران با Ubuntu 22.04 / 24.04 یا Debian 12 (x86_64 یا arm64) و systemd
- دسترسی root یا sudo و دستگاه `/dev/net/tun` (توی پنل بعضی ارائه‌دهنده‌ها باید TUN/TAP رو روشن کنی)
- باز بودن UDP روی پورت `51820` و بازه‌ی `30000-50000` توی فایروال پنل ارائه‌دهنده‌ی سرور

## نصب

```bash
curl -fsSLO https://github.com/w59520760-sketch/amneziawg-hop/releases/latest/download/install.sh
curl -fsSLO https://github.com/w59520760-sketch/amneziawg-hop/releases/latest/download/install.sh.sha256
sha256sum -c install.sh.sha256

sudo bash install.sh --firewall
sudo bash install.sh show
```

اسکریپت رو با `curl | bash` اجرا نکن. دانلود کن، هشش رو چک کن، یه نگاه بهش بنداز، بعد اجرا کن.

خروجی نصب این شکلیه:

```
[1/6] system   ubuntu 24.04, x86_64, systemd, tun ok
[2/6] binary   amneziawg-go v3.1.20260828, github release, sha256 ok
[3/6] keys     server + main keys, psk, jc=6 s1-s4 h1-h4 random
[4/6] config   /etc/amnezia/amneziawg/awg0.conf, mtu 1280
[5/6] service  awg-quick@awg0 active, userspace amneziawg
[6/6] network  udp 30000:50000 -> 51820, forward on, ufw on
done. client config: sudo bash install.sh show
```

اگه سرورت به گیت‌هاب دسترسی نداره، فایل `amneziawg-linux-amd64.tar.gz` (یا `arm64`) رو از صفحه‌ی Release بردار و کنار `install.sh` بذار. اگه دوست داری باینری‌ها رو خودت از سورس بسازی، `--from-source` رو بزن؛ این حالت اینترنت و `build-essential` لازم داره و سورس‌ها و ابزار Go رو با هش ثابت دانلود می‌کنه.

## استفاده روی دستگاه

خروجی `show` یه فایل کانفیگ کامل AmneziaWG ـه. به شکل فایل ذخیره‌ش کن یا با `--qr` کد QR بگیر:

```bash
sudo bash install.sh show > main.conf
sudo bash install.sh show main --qr
```

| دستگاه | برنامه | روش ورود |
|---|---|---|
| Android | AmneziaWG | اسکن QR یا ورود فایل `.conf` |
| iOS و macOS | AmneziaWG | اسکن QR یا ورود فایل `.conf` |
| Windows | AmneziaWG | ورود فایل `.conf` |
| همه‌ی سیستم‌ها | AmneziaVPN | ورود فایل `.conf` |
| همه‌ی سیستم‌ها | Hiddify | افزودن پروفایل از فایل یا کلیپ‌بورد |
| لینوکس | `awg-quick up ./main.conf` | بعد از نصب `amneziawg-linux-*.tar.gz` |

کانفیگ کلاینت با `AllowedIPs = 0.0.0.0/0, ::/0` ساخته میشه، یعنی کل ترافیک سیستم از تونل رد میشه و IPv6 هم نشت نمی‌کنه.

## دستورها

| دستور | کار |
|---|---|
| `sudo bash install.sh` | نصب، یا آپدیت باینری‌ها بدون تغییر کلیدها و پارامترها |
| `sudo bash install.sh show [NAME] [--qr]` | چاپ کانفیگ کلاینت (بدون اسم، کلاینت اول) |
| `sudo bash install.sh add NAME` | ساخت کلاینت جدید با کلید و آی‌پی جدا، بدون قطع بقیه |
| `sudo bash install.sh del NAME` | حذف کلاینت (همون لحظه از کار میفته) |
| `sudo bash install.sh users` | لیست کلاینت‌ها با آی‌پی و پورت اتصال |
| `sudo bash install.sh hop 40000:55000` | عوض کردن بازه‌ی پورت‌هاپینگ (یا `hop off`) |
| `sudo bash install.sh rotate [NAME]` | انتخاب پورت اتصال تازه برای کلاینت از داخل بازه‌ی پرش |
| `sudo bash install.sh status` | وضعیت سرویس، پورت، قانون‌های فایروال و آخرین هندشیک کلاینت‌ها |
| `sudo bash install.sh uninstall` | حذف کامل سرویس، فایل‌ها، کلیدها و قانون‌ها |

گزینه‌های نصب:

| گزینه | پیش‌فرض | توضیح |
|---|---|---|
| `--port N` | `51820` | پورت اصلی UDP سرور |
| `--hop START:END` | `30000:50000` | بازه‌ی پورت‌هاپینگ UDP (یا `off`) |
| `--user NAME` | `main` | اسم کلاینت اول |
| `--address HOST` | خودکار | آی‌پی یا دامنه‌ای که توی کانفیگ کلاینت میاد |
| `--dns A,B` | `1.1.1.1,9.9.9.9` | DNS داخل کانفیگ کلاینت |
| `--firewall` | خاموش | روشن کردن ufw (پورت‌های SSH، پروکسی‌های در حال اجرا و پورت AmneziaWG) |
| `--new-keys` | خاموش | موقع نصب دوباره، پارامترهای مبهم‌سازی تازه بساز (کانفیگ کلاینت‌ها رو دوباره بگیر) |
| `--from-source` | خاموش | ساخت باینری‌ها از سورس به‌جای بسته‌ی آماده |

## پورت‌هاپینگ

سرور فقط روی `51820` گوش میده، ولی کرنل هر بسته‌ی UDP که به آی‌پی خود سرور و پورت `30000` تا `50000` بیاد رو تحویلش میده. هر کلاینت یه پورت اتصال از داخل بازه توی `Endpoint` خودش داره. اگه یه پورت کُند یا بسته شد، پورت `Endpoint` رو توی کانفیگ کلاینت عوض کن (یا `rotate` رو بزن و کانفیگ تازه رو بگیر)؛ نه سرور ری‌استارت میشه و نه کلید جدیدی لازمه.

اگه ارائه‌دهنده‌ی سرورت بیرون از ماشین مجازی فایروال جدایی داره (Oracle Security List، Hetzner Firewall، AWS Security Group)، توی پنل اونجا هم UDP رو برای پورت `51820` و بازه‌ی `30000-50000` باز کن.

## چه فایل‌هایی عوض میشه

| مسیر | محتوا |
|---|---|
| `/usr/local/bin/amneziawg-go`، `awg`، `awg-quick` | باینری‌ها |
| `/etc/amnezia/amneziawg/awg0.conf` | کانفیگ سرور با کلیدها و قانون‌های فایروال (فقط root، `600`) |
| `/etc/amnezia/amneziawg/users` | کلیدها، آی‌پی و پورت اتصال کلاینت‌ها (فقط root، `600`) |
| `/etc/amnezia/amneziawg/amneziawg-hop.env` | تنظیمات و پارامترهای مبهم‌سازی (فقط root، `600`) |
| `/etc/systemd/system/awg-quick@.service` | واحد سرویس systemd |
| `/etc/sysctl.d/99-amneziawg.conf` | `ip_forward` و بافر UDP کرنل |

دستور `uninstall` همه‌ی این‌ها رو پاک می‌کنه جز قانون‌های `ufw`.

## مشکلات رایج

- **وصل نمیشه و `latest handshake` نداره:** فایروال پنل UDP رو بسته، یا کانفیگ کلاینت قدیمیه. `S1`–`S4` و `H1`–`H4` دو طرف باید دقیقاً یکی باشن؛ کانفیگ تازه رو با `show` بگیر.
- **بعد از `--new-keys` همه‌ی کلاینت‌ها قطع شدن:** پارامترهای مبهم‌سازی عوض شدن، کانفیگ همه‌ی کلاینت‌ها رو دوباره بگیر.
- **وصل میشه ولی سایت‌ها نیمه‌کاره باز میشن:** `MTU` کلاینت رو روی `1280` نگه دار.
- **با Hiddify وصل نمیشه:** از نسخه‌ی جدید برنامه استفاده کن و کانفیگ `.conf` رو بدون ویرایش وارد کن؛ نسخه‌های قدیمی `H1`–`H4` به شکل بازه رو نمی‌شناسن.
- **`awg-quick@awg0 did not start`:** خروجی `journalctl -u awg-quick@awg0 -n 50` رو ببین و مطمئن شو `/dev/net/tun` وجود داره.

## ساخت دوباره‌ی بسته‌ها

```bash
bash build-bundle.sh
```

این اسکریپت سورس رسمی `amnezia-vpn` رو با هش ثابت دانلود می‌کنه و با Go و ابزار musl دو بسته‌ی `amneziawg-linux-amd64.tar.gz` و `amneziawg-linux-arm64.tar.gz` می‌سازه. با Go 1.26.8 خروجی بایت‌به‌بایت با بسته‌های Release یکیه و هشش با هش‌های داخل `install.sh` می‌خونه.

## مجوز

MIT. [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go) و [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) متعلق به پروژه‌ی Amnezia VPN با مجوز MIT و GPL-2.0 هستن و این اسکریپت فقط اون‌ها رو نصب می‌کنه.

---

## English

One-command install of AmneziaWG 2.0 on a personal server: a layer-3 tunnel for the whole device with obfuscated headers, junk packets, QUIC mimicry and kernel-level UDP port hopping.

```bash
curl -fsSLO https://github.com/w59520760-sketch/amneziawg-hop/releases/latest/download/install.sh
curl -fsSLO https://github.com/w59520760-sketch/amneziawg-hop/releases/latest/download/install.sh.sha256
sha256sum -c install.sh.sha256

sudo bash install.sh --firewall
sudo bash install.sh show
```

What it does:

- installs `amneziawg-go`, `awg` and `awg-quick` as static binaries built from the pinned upstream `amnezia-vpn` sources; the SHA-256 digests of the release bundles are pinned inside `install.sh`, so verifying `install.sh.sha256` verifies the whole chain (or pass `--from-source` to build everything yourself; `bash build-bundle.sh` with Go 1.26.8 reproduces the release bundles byte for byte)
- generates the server and client Curve25519 keys, a `PresharedKey` and random AmneziaWG 2.0 parameters: `Jc` / `Jmin` / `Jmax` junk packets, `S1`–`S4` padding, non-overlapping `H1`–`H4` header ranges and a QUIC-like `I1` packet
- runs `awg-quick@awg0` in a hardened systemd unit, using the `amneziawg` kernel module when present and `amneziawg-go` otherwise
- redirects UDP `30000:50000` to `51820` with an `iptables` `PREROUTING` rule that lives in the `awg0` config (`PostUp` / `PostDown`), so no `iptables-persistent` is needed
- isolates clients from each other, blocks `169.254.0.0/16` and private ranges, clamps TCP MSS, sets `MTU = 1280` and masquerades client traffic
- shifts the hop range to `50001:60000` automatically when `hysteria2-hop` already owns `20000:50000`, so `xhttp-reality`, `hysteria2-hop` and `amneziawg-hop` share one VPS

`show` prints a complete client config for AmneziaWG (Android, iOS, macOS, Windows), AmneziaVPN and Hiddify; `--qr` prints a QR code. `add NAME` / `del NAME` manage clients without dropping the others, `hop START:END` changes the hopping range, `rotate [NAME]` picks a fresh endpoint port from the range, `status` shows live state and last handshakes, and `uninstall` removes everything except `ufw` rules.

Clients use `AllowedIPs = 0.0.0.0/0, ::/0`, so all traffic of the device goes through the tunnel and IPv6 cannot leak.

Remember to open **UDP** `51820` and `30000-50000` in your cloud provider's external firewall panel. Plain WireGuard (`01 00 00 00`, 148 bytes) is not what this script runs: `S1`–`S4` and `H1`–`H4` must be identical on both sides, which is why clients must always use the config printed by `show`.

License: MIT. amneziawg-go and amneziawg-tools belong to Amnezia VPN (MIT and GPL-2.0).

