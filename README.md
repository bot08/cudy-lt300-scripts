# cudy-lt300-scripts

Shell scripts for a Cudy LT300 (OpenWrt) with a MEIG SLM770A modem. Requires `sms_tool`; modem AT port `/dev/ttyUSB2`.

| Script | What it does |
|---|---|
| `refill_sms.sh` | Sends a "Refill" SMS each time `usb0` traffic grows by 800 MB. Set `NUMBER` first. Run from cron, e.g. `*/5 * * * * /root/refill_sms.sh` |
| `band.sh` | Interactive LTE band menu (show / presets / custom / auto). `./band.sh [/dev/ttyUSBx]` |
| `install_webui.sh` | Installs a web panel at `http://<router>/modem/`: signal, bands, traffic counter, refill SMS, wwan restart |

Copy the scripts to the router, `chmod +x`, and run them.

> The web panel has no authentication, so keep it on the LAN only.
