#!/bin/sh
mkdir -p /www/modem /www/cgi-bin

# ── CGI ──────────────────────────────────────────────────────────────────────
cat > /www/cgi-bin/modem_api.sh << 'APIEOF'
#!/bin/sh
INTERFACE="usb0"
STATE_FILE="/tmp/last_refill_bytes"
DEV="/dev/ttyUSB2"
LIMIT_MB=800
SMS_NUMBER="80808"
SMS_MESSAGE="Refill"

if [ "$REQUEST_METHOD" = "POST" ]; then
  read -r POST_DATA
  ACTION=$(echo "$POST_DATA" | sed -n 's/.*action=\([^&]*\).*/\1/p')
else
  ACTION=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')
fi

at_cmd() { sms_tool -d "$DEV" at "$1" 2>/dev/null; }

decode_bands() {
  local hex="$1" dec b bit result=""
  dec=$(printf "%d" "0x${hex}" 2>/dev/null) || { echo "—"; return; }
  for b in 1 3 5 7 8 20 28; do
    case $b in 1) bit=1;; 3) bit=4;; 5) bit=16;; 7) bit=64;;
                8) bit=128;; 20) bit=524288;; 28) bit=134217728;; esac
    [ $(( dec & bit )) -ne 0 ] && result="${result}B${b} "
  done
  printf '%s' "${result:-—}"
}

band_mask() {
  local sum=0
  for b in $1; do
    case $b in 1) sum=$((sum+1));; 3) sum=$((sum+4));; 5) sum=$((sum+16));;
               7) sum=$((sum+64));; 8) sum=$((sum+128));; 20) sum=$((sum+524288));;
               28) sum=$((sum+134217728));; esac
  done
  printf "%X" "$sum"
}

je() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR>1{printf "\\n"} {printf "%s", $0}'
}

get_bytes() {
  [ -f "/sys/class/net/$INTERFACE/statistics/rx_bytes" ] || { echo 0; return; }
  RX=$(cat "/sys/class/net/$INTERFACE/statistics/rx_bytes")
  TX=$(cat "/sys/class/net/$INTERFACE/statistics/tx_bytes")
  echo $((RX + TX))
}

printf "Content-Type: application/json\r\nCache-Control: no-cache\r\n\r\n"

# state-changing actions only via POST
case "$ACTION" in set_bands|sms|restart)
  [ "$REQUEST_METHOD" = "POST" ] || ACTION="" ;;
esac

case "$ACTION" in

  status)
    CSQ=$(at_cmd "AT+CSQ")
    RSSI=$(echo "$CSQ" | grep -oE '\+CSQ: [0-9]+' | grep -oE '[0-9]+' | head -1)
    [ -n "$RSSI" ] && [ "$RSSI" -lt 99 ] && DBM=$(( -113 + RSSI * 2 )) || DBM=-999

    SYSCFG=$(at_cmd "AT^SYSCFGEX?")
    LTEBAND=$(echo "$SYSCFG" | grep "SYSCFGEX:" \
      | sed 's/.*SYSCFGEX: *"\([^"]*\)",\([^,]*\),\([^,]*\),\([^,]*\),\([^,]*\).*/\5/')
    BANDS=$(je "$(decode_bands "$LTEBAND")")

    TOTAL=$(get_bytes)
    [ -f "$STATE_FILE" ] && LAST=$(cat "$STATE_FILE") || LAST=0
    [ "$TOTAL" -lt "$LAST" ] && LAST=0
    DIFF_MB=$(( (TOTAL - LAST) / 1048576 ))

    UPSEC=$(cut -d' ' -f1 /proc/uptime | cut -d'.' -f1)
    UPTIME="$((UPSEC/86400))d $(( (UPSEC%86400)/3600 ))h $(( (UPSEC%3600)/60 ))m"
    LOAD1=$(cut -d' ' -f1 /proc/loadavg)
    LOAD5=$(cut -d' ' -f2 /proc/loadavg)
    LOAD15=$(cut -d' ' -f3 /proc/loadavg)
    MEM_FREE=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    MEM_TOTAL=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)

    printf '{"ok":true,"dbm":%d,"bands":"%s","used_mb":%d,"limit_mb":%d,"uptime":"%s","load1":"%s","load5":"%s","load15":"%s","mem_free":%d,"mem_total":%d}' \
      "$DBM" "$BANDS" "$DIFF_MB" "$LIMIT_MB" \
      "$(je "$UPTIME")" "$LOAD1" "$LOAD5" "$LOAD15" "$MEM_FREE" "$MEM_TOTAL"
    ;;

  band_info)
    SYSCFG_RAW=$(at_cmd "AT^SYSCFGEX?")
    SYSINFO_RAW=$(at_cmd "AT^SYSINFOEX")
    COPS_RAW=$(at_cmd "AT+COPS?")
    CEREG_RAW=$(at_cmd "AT+CEREG?")
    CSQ_RAW=$(at_cmd "AT+CSQ")

    LTEBAND=$(echo "$SYSCFG_RAW" | grep "SYSCFGEX:" \
      | sed 's/.*SYSCFGEX: *"\([^"]*\)",\([^,]*\),\([^,]*\),\([^,]*\),\([^,]*\).*/\5/')
    BANDS=$(decode_bands "$LTEBAND")
    OPER=$(echo "$COPS_RAW" | grep -oE '"[^"]+"' | sed -n '1p' | tr -d '"')
    ACT=$(echo "$COPS_RAW" | grep -oE ',[0-9]+$' | tr -d ',')
    case $ACT in 0) NET="GSM (2G)";; 2) NET="UMTS (3G)";; 7) NET="LTE (4G)";; *) NET="Unknown";; esac
    STAT=$(echo "$CEREG_RAW" | grep -oE ',[0-9]+' | tail -1 | tr -d ',')
    case $STAT in 1) REG="Home";; 5) REG="Roaming";; 6) REG="SMS only";; *) REG="Not registered";; esac
    RSSI=$(echo "$CSQ_RAW" | grep -oE '\+CSQ: [0-9]+' | grep -oE '[0-9]+' | head -1)
    [ -n "$RSSI" ] && [ "$RSSI" -lt 99 ] && DBM=$(( -113 + RSSI * 2 )) || DBM=-999

    RAW=$(printf '%s\n%s' "$SYSCFG_RAW" "$SYSINFO_RAW")

    printf '{"ok":true,"bands":"%s","net":"%s","operator":"%s","reg":"%s","dbm":%d,"raw":"%s"}' \
      "$(je "$BANDS")" "$(je "$NET")" "$(je "${OPER:-—}")" "$(je "$REG")" "$DBM" "$(je "$RAW")"
    ;;

  set_bands)
    ENC=$(echo "$POST_DATA" | sed -n 's/.*bands=\([^&]*\).*/\1/p')
    # url-decode spaces (%20 or +), keep only digits/spaces unless "all"
    BANDS=$(echo "$ENC" | sed 's/%20/ /g; s/+/ /g')
    [ "$BANDS" != "all" ] && BANDS=$(echo "$BANDS" | tr -cd '0-9 ')

    if [ -z "$BANDS" ]; then
      printf '{"ok":false,"message":"No bands given"}'
    elif [ "$BANDS" = "all" ]; then
      RESP=$(at_cmd "AT^SYSCFGEX=\"00\",all,0,2,all,all,,,1")
    else
      HEX=$(band_mask "$BANDS")
      RESP=$(at_cmd "AT^SYSCFGEX=\"03\",40000000,3,2,$HEX,0,,,1")
    fi

    if [ -z "$BANDS" ]; then :
    elif echo "$RESP" | grep -q "ERROR"; then
      printf '{"ok":false,"message":"Modem rejected the command"}'
    else
      ( logger "modem-ui: applying bands [$BANDS], restarting"
        at_cmd "AT+CFUN=0" >/dev/null; sleep 3
        at_cmd "AT+CFUN=1" >/dev/null; sleep 5
        ifup wwan 2>/dev/null ) &
      printf '{"ok":true,"message":"Bands applied — modem restarting"}'
    fi
    ;;

  sms)
    OUT=$(sms_tool -d "$DEV" send "$SMS_NUMBER" "$SMS_MESSAGE" 2>&1)
    if [ $? -eq 0 ]; then
      echo "$(get_bytes)" > "$STATE_FILE"
      printf '{"ok":true,"message":"SMS sent, counter reset"}'
    else
      printf '{"ok":false,"message":"%s"}' "$(je "$OUT")"
    fi
    ;;

  restart)
    ( logger "modem-ui: restarting wwan/wwan6"
      ifdown wwan 2>/dev/null; ifdown wwan6 2>/dev/null; sleep 3
      ifup wwan 2>/dev/null; ifup wwan6 2>/dev/null ) &
    printf '{"ok":true,"message":"Restarting wwan and wwan6..."}'
    ;;

  *) printf '{"ok":false,"message":"unknown action"}' ;;
esac
APIEOF
chmod +x /www/cgi-bin/modem_api.sh

# ── HTML ──────────────────────────────────────────────────────────────────────
cat > /www/modem/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Modem</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#eef0f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#111827;padding:18px 16px 48px;max-width:580px;margin:0 auto}

/* Top bar */
.topbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:18px}
.topbar h1{font-size:.75rem;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:#9ca3af}
.topbar-right{display:flex;align-items:center;gap:8px}
#lu{font-size:.72rem;color:#b0b7c3}
.rbtn{background:#fff;border:1px solid #e2e5eb;color:#6b7280;border-radius:8px;padding:5px 13px;font-size:.78rem;font-weight:500;cursor:pointer;font-family:inherit;transition:background .15s}
.rbtn:hover{background:#f5f6fa}

/* Cards */
.card{background:#fff;border:1px solid #e2e5eb;border-radius:18px;padding:20px;margin-bottom:12px;box-shadow:0 1px 4px rgba(0,0,0,.05)}
.card-hdr{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px}
.card-lbl{font-size:.67rem;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#9ca3af}
.detail-btn{font-size:.75rem;font-weight:600;color:#6366f1;background:none;border:none;cursor:pointer;padding:2px 0;font-family:inherit;text-decoration:none}
.detail-btn:hover{text-decoration:underline}

/* Signal */
.sig-main{display:flex;align-items:center;gap:18px;margin-bottom:16px}
.bars{display:flex;align-items:flex-end;gap:4px;height:32px}
.bars span{width:9px;border-radius:3px;background:#e5e7eb;transition:background .4s}
.bars span:nth-child(1){height:28%}.bars span:nth-child(2){height:46%}
.bars span:nth-child(3){height:64%}.bars span:nth-child(4){height:82%}
.bars span:nth-child(5){height:100%}
.bars[data-l="5"] span{background:#16a34a}
.bars[data-l="4"] span:nth-child(-n+4){background:#16a34a}
.bars[data-l="3"] span:nth-child(-n+3){background:#d97706}
.bars[data-l="2"] span:nth-child(-n+2){background:#f97316}
.bars[data-l="1"] span:nth-child(1){background:#dc2626}
.sig-num{font-size:2.1rem;font-weight:700;font-variant-numeric:tabular-nums;line-height:1}
.sig-q{font-size:.8rem;color:#9ca3af;margin-top:5px}
.band-pill{display:inline-flex;align-items:center;gap:7px;background:#f5f3ff;border:1px solid #ddd6fe;border-radius:99px;padding:6px 15px;font-size:.82rem;font-weight:600;color:#5b21b6}
.bdot{width:6px;height:6px;border-radius:50%;background:#7c3aed;flex-shrink:0}

/* Usage */
.usage-row{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:10px}
.unum{font-size:1.65rem;font-weight:700;font-variant-numeric:tabular-nums}
.ulim{font-size:.85rem;color:#9ca3af}
.upct-lbl{font-size:.85rem;font-weight:600;color:#6b7280}
.track{height:10px;background:#f1f2f6;border-radius:99px;overflow:hidden;margin-bottom:7px}
.fill{height:100%;border-radius:99px;background:#6366f1;transition:width .6s ease,background .3s}
.fill.w{background:#d97706}.fill.c{background:#f97316}.fill.o{background:#dc2626}
.usage-sub{font-size:.74rem;color:#9ca3af;text-align:right}

/* Stats */
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:9px}
.stat{background:#f8f9fb;border:1px solid #eff0f5;border-radius:12px;padding:11px 13px}
.slbl{font-size:.62rem;font-weight:600;color:#9ca3af;letter-spacing:.06em;text-transform:uppercase}
.sval{font-size:.9rem;font-weight:600;margin-top:4px;font-variant-numeric:tabular-nums}
.mbar-track{height:4px;background:#e5e7eb;border-radius:99px;overflow:hidden;margin-top:6px}
.mbar-fill{height:100%;border-radius:99px;background:#6366f1;transition:width .5s}

/* Separator */
.sep{border:none;border-top:1px solid #f1f2f6;margin:14px 0}

/* Buttons */
.btn{display:flex;align-items:center;justify-content:center;width:100%;padding:13px;border:none;border-radius:13px;font-size:.93rem;font-weight:600;cursor:pointer;font-family:inherit;transition:filter .15s,transform .1s,background .2s}
.btn:active:not(:disabled){transform:scale(.97)}
.btn:disabled{cursor:not-allowed}
.btn-sms{background:#6366f1;color:#fff;margin-bottom:10px}
.btn-sms:hover:not(:disabled){filter:brightness(1.08)}
.btn-rst{background:#fff;border:1px solid #fca5a5;color:#dc2626}
.btn-rst:hover:not(:disabled){background:#fff8f8}

/* Shimmer loading state */
@keyframes shimmer{0%{background-position:200% center}100%{background-position:-200% center}}
.btn-loading-primary{background:linear-gradient(90deg,#4338ca 0%,#818cf8 50%,#4338ca 100%);background-size:200% auto;animation:shimmer 1.4s linear infinite;color:#fff;pointer-events:none}
.btn-loading-danger{background:linear-gradient(90deg,#fee2e2 0%,#fecaca 50%,#fee2e2 100%);background-size:200% auto;animation:shimmer 1.4s linear infinite;border-color:#fca5a5;color:#b91c1c;pointer-events:none}

/* Bottom toasts */
#toast-wrap{position:fixed;bottom:22px;left:0;right:0;display:flex;flex-direction:column;align-items:center;gap:8px;pointer-events:none;z-index:9999}
@keyframes t-in{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:translateY(0)}}
@keyframes t-out{from{opacity:1;transform:translateY(0)}to{opacity:0;transform:translateY(-8px)}}
.t{padding:10px 22px;border-radius:10px;font-size:.84rem;font-weight:500;box-shadow:0 4px 14px rgba(0,0,0,.13);animation:t-in .25s ease forwards;pointer-events:auto;max-width:320px;text-align:center}
.t.ok{background:#14532d;color:#dcfce7}
.t.err{background:#7f1d1d;color:#fee2e2}

/* Modal overlay */
.overlay{position:fixed;inset:0;background:rgba(0,0,0,.35);backdrop-filter:blur(2px);opacity:0;pointer-events:none;transition:opacity .25s;z-index:100}
.overlay.on{opacity:1;pointer-events:auto}
.modal{position:fixed;top:50%;left:50%;transform:translate(-50%,-46%);width:calc(100% - 32px);max-width:520px;max-height:88vh;background:#fff;border-radius:20px;box-shadow:0 16px 48px rgba(0,0,0,.18);display:flex;flex-direction:column;opacity:0;pointer-events:none;transition:opacity .25s,transform .25s;z-index:101}
.modal.on{opacity:1;pointer-events:auto;transform:translate(-50%,-50%)}
.modal-hdr{display:flex;justify-content:space-between;align-items:center;padding:18px 20px 0}
.modal-hdr span{font-size:.9rem;font-weight:700;color:#111827}
.modal-x{background:none;border:none;font-size:1.1rem;color:#9ca3af;cursor:pointer;line-height:1;padding:4px}
.modal-x:hover{color:#374151}
.modal-body{overflow-y:auto;padding:16px 20px 20px;flex:1}
.msec{font-size:.63rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#9ca3af;margin-bottom:10px}
.mgrid{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:4px}
.mbox{background:#f8f9fb;border:1px solid #eff0f5;border-radius:11px;padding:10px 12px}
.mbox .mk{font-size:.63rem;color:#9ca3af;letter-spacing:.05em;text-transform:uppercase}
.mbox .mv{font-size:.88rem;font-weight:600;margin-top:3px}
pre.raw{background:#f8f9fb;border:1px solid #eff0f5;border-radius:11px;padding:11px 13px;font-size:.72rem;font-family:'SFMono-Regular',Consolas,monospace;color:#374151;white-space:pre-wrap;word-break:break-all;line-height:1.5;margin-bottom:4px}
.divider{border:none;border-top:1px solid #f1f2f6;margin:16px 0}
.pbtn-grid{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:10px}
.pbtn{background:#f8f9fb;border:2px solid #eff0f5;border-radius:12px;padding:12px 10px;font-size:.82rem;font-weight:600;color:#374151;cursor:pointer;text-align:center;font-family:inherit;transition:border-color .15s,background .15s,color .15s;line-height:1.4}
.pbtn small{display:block;font-weight:400;font-size:.72rem;color:#9ca3af;margin-top:3px}
.pbtn:hover{border-color:#a5b4fc;background:#faf5ff}
.pbtn.sel{border-color:#6366f1;background:#eef2ff;color:#4338ca}
.pbtn.sel small{color:#6366f1}
.custom-row{display:flex;gap:8px;margin-bottom:12px}
.custom-row input{flex:1;background:#f8f9fb;border:1px solid #e2e5eb;border-radius:10px;padding:9px 12px;font-size:.85rem;color:#111827;outline:none;font-family:inherit}
.custom-row input:focus{border-color:#6366f1}
.use-btn{background:#f1f2f6;border:1px solid #e2e5eb;border-radius:10px;padding:9px 14px;font-size:.82rem;font-weight:600;color:#374151;cursor:pointer;font-family:inherit}
.use-btn:hover{background:#e8e9ef}
.apply-row{display:none}
.sel-preview{font-size:.8rem;color:#6366f1;font-weight:600;margin-bottom:10px;padding:8px 12px;background:#eef2ff;border-radius:9px;border:1px solid #c7d2fe}
.btn-apply{background:#4f46e5;color:#fff;padding:13px;border:none;border-radius:13px;font-size:.92rem;font-weight:600;width:100%;cursor:pointer;font-family:inherit;transition:filter .15s}
.btn-apply:hover:not(:disabled){filter:brightness(1.08)}
.btn-apply:disabled{opacity:.45;cursor:not-allowed}
.modal-spin{display:flex;align-items:center;justify-content:center;padding:32px;color:#9ca3af;font-size:.88rem}
</style>
</head>
<body>

<div class="topbar">
  <h1>Modem</h1>
  <div class="topbar-right">
    <span id="lu"></span>
    <button class="rbtn" onclick="loadStatus()">Refresh</button>
  </div>
</div>

<!-- Signal -->
<div class="card">
  <div class="card-hdr">
    <span class="card-lbl">Signal</span>
    <button class="detail-btn" onclick="openModal()">Details &amp; Bands &rsaquo;</button>
  </div>
  <div class="sig-main">
    <div class="bars" id="bars" data-l="0"><span></span><span></span><span></span><span></span><span></span></div>
    <div>
      <div class="sig-num" id="dbm">—</div>
      <div class="sig-q" id="sigq">—</div>
    </div>
  </div>
  <div class="band-pill"><span class="bdot"></span><span id="bands">—</span></div>
</div>

<!-- Usage -->
<div class="card">
  <div class="card-hdr"><span class="card-lbl">Data used this cycle</span></div>
  <div class="usage-row">
    <div><span class="unum" id="umb">—</span><span class="ulim"> / <span id="lmb">800</span> MB</span></div>
    <div class="upct-lbl" id="upct">—%</div>
  </div>
  <div class="track"><div class="fill" id="fill" style="width:0%"></div></div>
  <div class="usage-sub" id="usub">—</div>
</div>

<!-- Stats -->
<div class="card">
  <div class="stats">
    <div class="stat"><div class="slbl">Uptime</div><div class="sval" id="upt">—</div></div>
    <div class="stat"><div class="slbl">Load avg</div><div class="sval" id="load">—</div></div>
    <div class="stat">
      <div class="slbl">Free RAM</div>
      <div class="sval" id="memfree">—</div>
      <div class="mbar-track"><div class="mbar-fill" id="membar" style="width:0%"></div></div>
    </div>
  </div>
</div>

<!-- Actions -->
<div class="card">
  <button class="btn btn-sms" id="sbtn" onclick="sendSMS()">Send Refill SMS</button>
  <div class="sep"></div>
  <button class="btn btn-rst" id="rbtn" onclick="restartModem()">Restart Modem (wwan / wwan6)</button>
</div>

<!-- Toast container -->
<div id="toast-wrap"></div>

<!-- Modal overlay -->
<div class="overlay" id="overlay" onclick="closeModal()"></div>

<!-- Modal -->
<div class="modal" id="modal">
  <div class="modal-hdr">
    <span>Signal &amp; Bands</span>
    <button class="modal-x" onclick="closeModal()">&#x2715;</button>
  </div>
  <div class="modal-body" id="modal-body">
    <div class="modal-spin">Loading...</div>
  </div>
</div>

<script>
const API = '/cgi-bin/modem_api.sh';
let selBands = null;

function sigLvl(d){return d>=-65?5:d>=-75?4:d>=-85?3:d>=-95?2:d>-999?1:0}
function sigLbl(d){return d<=-999?'No signal':d>=-65?'Excellent':d>=-75?'Good':d>=-85?'Fair':d>=-95?'Poor':'Very poor'}
function sigClr(d){return d>=-75?'#16a34a':d>=-85?'#d97706':d>=-95?'#f97316':d>-999?'#dc2626':'#9ca3af'}

async function loadStatus(){
  document.getElementById('lu').textContent = '...';
  try{
    const r = await fetch(API+'?action=status',{cache:'no-store'});
    const d = await r.json();
    if(!d.ok) throw 0;

    const l = sigLvl(d.dbm);
    document.getElementById('bars').dataset.l = l;
    const de = document.getElementById('dbm');
    de.textContent = d.dbm > -999 ? d.dbm+' dBm' : '—';
    de.style.color = sigClr(d.dbm);
    document.getElementById('sigq').textContent = sigLbl(d.dbm);
    document.getElementById('bands').textContent = d.bands||'—';

    const u=d.used_mb||0, lm=d.limit_mb||800, p=Math.min(100,Math.round(u/lm*100));
    document.getElementById('umb').textContent = u;
    document.getElementById('lmb').textContent = lm;
    document.getElementById('upct').textContent = p+'%';
    document.getElementById('usub').textContent = '~'+Math.max(0,lm-u)+' MB remaining';
    const f = document.getElementById('fill');
    f.style.width = p+'%';
    f.className = 'fill'+(p>=100?' o':p>=80?' c':p>=60?' w':'');

    document.getElementById('upt').textContent = d.uptime||'—';
    document.getElementById('load').textContent = d.load1+' '+d.load5+' '+d.load15;
    const mf=d.mem_free||0, mt=d.mem_total||1;
    document.getElementById('memfree').textContent = mf+' MB';
    document.getElementById('membar').style.width = Math.round(mf/mt*100)+'%';

    const n = new Date();
    document.getElementById('lu').textContent = n.toTimeString().slice(0,8);
  }catch(e){
    document.getElementById('lu').textContent = 'error';
  }
}

function btnLoad(id,cls,txt){
  const b=document.getElementById(id);
  b.disabled=true; b.classList.add(cls); b.textContent=txt;
  return b;
}
function btnReset(b,origCls,origHtml){
  b.disabled=false; b.classList.remove('btn-loading-primary','btn-loading-danger'); b.innerHTML=origHtml;
}

async function sendSMS(){
  const b=btnLoad('sbtn','btn-loading-primary','Sending');
  try{
    const r=await fetch(API,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=sms'});
    const d=await r.json();
    showToast(d.ok,d.message);
    if(d.ok) loadStatus();
  }catch(e){showToast(false,'Connection error');}
  finally{btnReset(b,'btn-loading-primary','Send Refill SMS');}
}

async function restartModem(){
  if(!confirm('Restart wwan and wwan6?')) return;
  const b=btnLoad('rbtn','btn-loading-danger','Restarting');
  try{
    const r=await fetch(API,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'action=restart'});
    const d=await r.json();
    showToast(d.ok,d.message);
  }catch(e){showToast(false,'Connection error');}
  finally{setTimeout(()=>btnReset(b,'btn-loading-danger','Restart Modem (wwan / wwan6)'),8000);}
}

function showToast(ok,msg){
  const w=document.getElementById('toast-wrap');
  const el=document.createElement('div');
  el.className='t '+(ok?'ok':'err');
  el.textContent=msg;
  w.appendChild(el);
  setTimeout(()=>{
    el.style.animation='t-out .25s ease forwards';
    setTimeout(()=>el.remove(),260);
  },4000);
}

function openModal(){
  document.getElementById('overlay').classList.add('on');
  document.getElementById('modal').classList.add('on');
  document.body.style.overflow='hidden';
  loadBandInfo();
}
function closeModal(){
  document.getElementById('overlay').classList.remove('on');
  document.getElementById('modal').classList.remove('on');
  document.body.style.overflow='';
  selBands=null;
}

async function loadBandInfo(){
  document.getElementById('modal-body').innerHTML='<div class="modal-spin">Loading...</div>';
  try{
    const r=await fetch(API+'?action=band_info',{cache:'no-store'});
    const d=await r.json();
    if(!d.ok) throw new Error(d.message);
    renderModal(d);
  }catch(e){
    document.getElementById('modal-body').innerHTML='<div class="modal-spin">Error: '+e.message+'</div>';
  }
}

function renderModal(d){
  const regClr = d.reg==='Home'?'#16a34a':d.reg==='Roaming'?'#d97706':'#dc2626';
  document.getElementById('modal-body').innerHTML =
    '<div class="msec">Connection</div>'+
    '<div class="mgrid">'+
      '<div class="mbox"><div class="mk">Operator</div><div class="mv">'+(d.operator||'—')+'</div></div>'+
      '<div class="mbox"><div class="mk">Network</div><div class="mv">'+(d.net||'—')+'</div></div>'+
      '<div class="mbox"><div class="mk">Status</div><div class="mv" style="color:'+regClr+'">'+(d.reg||'—')+'</div></div>'+
      '<div class="mbox"><div class="mk">Signal</div><div class="mv">'+(d.dbm>-999?d.dbm+' dBm':'—')+'</div></div>'+
    '</div>'+
    '<div class="mbox" style="margin-top:8px"><div class="mk">Active bands</div><div class="mv">'+(d.bands||'—')+'</div></div>'+
    '<hr class="divider">'+
    '<div class="msec">Raw output</div>'+
    '<pre class="raw" id="raw-out"></pre>'+
    '<hr class="divider">'+
    '<div class="msec">Set bands</div>'+
    '<div class="pbtn-grid">'+
      '<button class="pbtn" data-b="1 3 7 8 20 28" onclick="pickBand(this)">Vodafone DE<small>B1 B3 B7 B8 B20 B28</small></button>'+
      '<button class="pbtn" data-b="20 28" onclick="pickBand(this)">Low bands<small>B20 B28 — coverage</small></button>'+
      '<button class="pbtn" data-b="3 7" onclick="pickBand(this)">High bands<small>B3 B7 — speed</small></button>'+
      '<button class="pbtn" data-b="all" onclick="pickBand(this)">Auto / All<small>reset to default</small></button>'+
    '</div>'+
    '<div class="custom-row">'+
      '<input type="text" id="cinput" placeholder="Custom: 3 7 20 28">'+
      '<button class="use-btn" onclick="useCustom()">Use</button>'+
    '</div>'+
    '<div class="apply-row" id="arow">'+
      '<div class="sel-preview" id="sprev"></div>'+
      '<button class="btn-apply" id="abtn" onclick="applyBands()">Apply &amp; Restart Modem</button>'+
    '</div>';

  // set raw text safely
  document.getElementById('raw-out').textContent = d.raw||'—';
}

function pickBand(el){
  document.querySelectorAll('.pbtn').forEach(b=>b.classList.remove('sel'));
  el.classList.add('sel');
  selBands = el.dataset.b;
  document.getElementById('cinput').value='';
  showApplyRow(selBands==='all'?'All bands (auto)':'Bands: '+selBands);
}
function useCustom(){
  const v=document.getElementById('cinput').value.trim();
  if(!v) return;
  document.querySelectorAll('.pbtn').forEach(b=>b.classList.remove('sel'));
  selBands=v;
  showApplyRow('Custom: '+v);
}
function showApplyRow(label){
  document.getElementById('sprev').textContent=label;
  document.getElementById('arow').style.display='block';
}

async function applyBands(){
  if(!selBands) return;
  const btn=document.getElementById('abtn');
  btn.disabled=true; btn.textContent='Applying...';
  btn.style.background='linear-gradient(90deg,#4338ca 0%,#818cf8 50%,#4338ca 100%)';
  btn.style.backgroundSize='200% auto';
  btn.style.animation='shimmer 1.4s linear infinite';
  try{
    const r=await fetch(API,{
      method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:'action=set_bands&bands='+encodeURIComponent(selBands)
    });
    const d=await r.json();
    showToast(d.ok,d.message);
    if(d.ok){ setTimeout(closeModal,400); }
    else{ btn.disabled=false; btn.textContent='Apply & Restart Modem'; btn.style.animation=''; }
  }catch(e){
    showToast(false,'Connection error');
    btn.disabled=false; btn.textContent='Apply & Restart Modem'; btn.style.animation='';
  }
}

loadStatus();
setInterval(loadStatus,30000);
</script>
</body>
</html>
HTMLEOF

IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
printf '\n  modem_api.sh -> /www/cgi-bin/modem_api.sh\n'
printf '  index.html   -> /www/modem/index.html\n'
printf '\n  Open: http://%s/modem/\n\n' "$IP"