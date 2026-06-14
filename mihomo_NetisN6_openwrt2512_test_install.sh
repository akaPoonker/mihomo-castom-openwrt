#!/bin/sh

SCRIPT_VERSION="v0.1.7-netisn6-openwrt25.12-akaPoonker"

MIHOMO_INSTALL_DIR="/etc/mihomo"
MIHOMO_BIN="/usr/bin/mihomo"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${GREEN}=== $* ===${NC}"; }
log_done()  { echo -e "${GREEN}$*${NC}"; }
step_fail() { echo -e "${RED}[FAIL]${NC}"; exit 1; }

USE_APK=0
if command -v apk > /dev/null 2>&1; then
    USE_APK=1
fi

detect_mihomo_arch() {
    local arch
    arch=$(uname -m)
    local endian_byte
    endian_byte=$(hexdump -s 5 -n 1 -e '1/1 "%d"' /bin/busybox 2>/dev/null || echo "0")

    case "$arch" in
        x86_64)        echo "amd64" ;;
        i?86)          echo "386" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*)        echo "armv7" ;;
        armv5*|armv4*) echo "armv5" ;;
        mips*)
            local fpu
            fpu=$(grep -c "FPU" /proc/cpuinfo 2>/dev/null || echo 0)
            local floattype="softfloat"
            [ "$fpu" -gt 0 ] && floattype="hardfloat"
            if [ "$endian_byte" = "1" ]; then
                echo "mipsle-${floattype}"
            else
                echo "mips-${floattype}"
            fi
            ;;
        riscv64) echo "riscv64" ;;
        *)
            log_error "Архитектура $arch не распознана"
            exit 1
            ;;
    esac
}

install_deps() {
    log_info "Установка системных зависимостей через apk..."
    local PKG_LOG="/tmp/install_deps.log"

    apk update > "$PKG_LOG" 2>&1 || true
    apk add wget-ssl ca-certificates kmod-tun kmod-nft-tproxy kmod-nft-nat curl luci-app-commands >> "$PKG_LOG" 2>&1 || {
        log_error "Ошибка установки зависимостей:"; cat "$PKG_LOG"; rm -f "$PKG_LOG"; return 1;
    }

    rm -f "$PKG_LOG"
    log_info "Зависимости установлены"
}

install_mihomo() {
    local REQ_ROOT_KB=18000
    local INSTALL_DIR_PATH
    INSTALL_DIR_PATH=$(dirname "$MIHOMO_BIN")
    local AVAIL_ROOT_KB
    AVAIL_ROOT_KB=$(df -k "$INSTALL_DIR_PATH" | awk 'NR==2 {print $4}')

    if [ "$AVAIL_ROOT_KB" -lt "$REQ_ROOT_KB" ]; then
        log_error "Недостаточно места во флеш-памяти! Доступно $((AVAIL_ROOT_KB/1024)) MB."
        return 1
    fi

    if [ -f "/etc/init.d/mihomo" ]; then
        /etc/init.d/mihomo stop 2>/dev/null || true
    fi

    if [ -z "${MIHOMO_ARCH+x}" ]; then
        MIHOMO_ARCH=$(detect_mihomo_arch)
    fi
    echo "--> Архитектура системы: $(uname -m) -> выбран файл: $MIHOMO_ARCH"

    mkdir -p "$MIHOMO_INSTALL_DIR" \
             /etc/mihomo/proxy-providers \
             /etc/mihomo/rule-providers \
             /etc/mihomo/rule-files \
             /etc/mihomo/UI

    echo "$MIHOMO_ARCH" > /etc/mihomo/.arch

    echo "--> Определение последней версии ядра Mihomo..."
    local RELEASE_TAG
    RELEASE_TAG=$(curl -skL -o /dev/null -w '%{url_effective}' https://github.com/MetaCubeX/mihomo/releases/latest | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -z "$RELEASE_TAG" ]; then
        log_error "Не удалось определить версию. Проверьте интернет-соединение."
        return 1
    fi
    echo "--> Последняя версия: $RELEASE_TAG"

    local FILENAME="mihomo-linux-${MIHOMO_ARCH}-${RELEASE_TAG}.gz"
    local DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${RELEASE_TAG}/${FILENAME}"
    local TMP_FILE="/tmp/mihomo.gz"

    log_info "Скачивание архива $FILENAME напрямую с GitHub..."
    if ! curl -skLf --retry 3 --retry-delay 2 "$DOWNLOAD_URL" -o "$TMP_FILE" >/dev/null 2>&1; then
        log_error "Ошибка скачивания! Проверьте интернет."
        return 1
    fi

    echo "--> Распаковка архива..."
    if ! gunzip -c "$TMP_FILE" > "$MIHOMO_BIN" 2>/dev/null; then
        log_error "Ошибка распаковки архива"
        rm -f "$TMP_FILE"
        return 1
    fi
    chmod +x "$MIHOMO_BIN"
    rm -f "$TMP_FILE"

    echo "--> Проверка работы ядра Mihomo..."
    if ! "$MIHOMO_BIN" -v >/dev/null 2>&1; then
        log_error "Ядро не запускается!"
        return 1
    fi

    touch /etc/mihomo/rule-files/servs.txt
    
    echo "--> Создание эталонного файла правил /etc/mihomo/rule-files/rules.txt..."
    cat > /etc/mihomo/rule-files/rules.txt <<'EOF'
payload:
  # === SPEEDTEST И ПРОВЕРКА IP ===
  - DOMAIN-SUFFIX,speedtest.net
  - DOMAIN-SUFFIX,ookla.com
  - DOMAIN-SUFFIX,2ip.io

  # === КИНО, ТОРРЕНТЫ И "КЛУБНИЧКА" ===
  - DOMAIN-SUFFIX,pornhub.com
  - DOMAIN-SUFFIX,phncdn.com
  - DOMAIN-SUFFIX,rezka.ag
  - DOMAIN-SUFFIX,hdrezka.me
  - DOMAIN-SUFFIX,voidboost.net
  - DOMAIN-SUFFIX,rutracker.org
  - DOMAIN-SUFFIX,rutracker.net
  - DOMAIN-SUFFIX,rutracker.cc
  - DOMAIN-SUFFIX,nnmstatic.win
  - DOMAIN-SUFFIX,rutor.info
  - DOMAIN-SUFFIX,kinozal.tv

  # === AI СЕРВИСЫ ===
  - DOMAIN-SUFFIX,openai.com
  - DOMAIN-SUFFIX,chatgpt.com
  - DOMAIN-SUFFIX,oaistatic.com
  - DOMAIN-SUFFIX,anthropic.com
  - DOMAIN-SUFFIX,claude.ai
  - DOMAIN-SUFFIX,midjourney.com
  - DOMAIN-SUFFIX,poe.com
  # Инфраструктура Google AI (Gemini / AI Studio):
  - DOMAIN-SUFFIX,gemini.google.com
  - DOMAIN-SUFFIX,aistudio.google.com
  - DOMAIN-SUFFIX,makersuite.google.com
  - DOMAIN-SUFFIX,generativelanguage.googleapis.com
  - DOMAIN-SUFFIX,ai.google.dev
  - DOMAIN-SUFFIX,google.com
  - DOMAIN-SUFFIX,googleapis.com
  - DOMAIN-SUFFIX,gstatic.com
  - DOMAIN-SUFFIX,googleusercontent.com
  - DOMAIN-SUFFIX,firebase.com
  - DOMAIN-SUFFIX,firebaseio.com
  - DOMAIN-KEYWORD,identitytoolkit
  - DOMAIN-SUFFIX,deepmind.com
  - DOMAIN-SUFFIX,deepmind.google
  - DOMAIN-SUFFIX,proactive.google.com
  - DOMAIN-SUFFIX,aisandbox-pa.googleapis.com
  - DOMAIN-SUFFIX,alkalicontent-pa.googleapis.com
  - DOMAIN-KEYWORD,google-analytics

  # === YOUTUBE И GOOGLE ===
  - DOMAIN-SUFFIX,youtube.com
  - DOMAIN-SUFFIX,youtu.be
  - DOMAIN-SUFFIX,googlevideo.com
  - DOMAIN-SUFFIX,ytimg.com
  - DOMAIN-SUFFIX,ggpht.com
  - DOMAIN-SUFFIX,youtube-nocookie.com

  # === СОЦСЕТИ И ИНТЕРНЕТ ===
  - DOMAIN-SUFFIX,instagram.com
  - DOMAIN-SUFFIX,cdninstagram.com
  - DOMAIN-SUFFIX,facebook.com
  - DOMAIN-SUFFIX,fbcdn.net
  - DOMAIN-SUFFIX,x.com
  - DOMAIN-SUFFIX,twitter.com
  - DOMAIN-SUFFIX,twimg.com
  - DOMAIN-SUFFIX,t.co
  - DOMAIN-SUFFIX,notion.so

  # === DISCORD ===
  - DOMAIN-SUFFIX,discord.com
  - DOMAIN-SUFFIX,discord.gg
  - DOMAIN-SUFFIX,discordapp.com
  - DOMAIN-SUFFIX,discordapp.net
  - DOMAIN-SUFFIX,discord.media

  # === TELEGRAM ===
  - DOMAIN-SUFFIX,telegram.org
  - DOMAIN-SUFFIX,t.me
  - DOMAIN-SUFFIX,tx.me
  - DOMAIN-SUFFIX,tdesktop.com
  - IP-CIDR,91.108.4.0/22,no-resolve
  - IP-CIDR,91.108.8.0/22,no-resolve
  - IP-CIDR,91.108.12.0/22,no-resolve
  - IP-CIDR,91.108.16.0/22,no-resolve
  - IP-CIDR,91.108.20.0/22,no-resolve
  - IP-CIDR,91.108.56.0/22,no-resolve
  - IP-CIDR,149.154.160.0/20,no-resolve
  - IP-CIDR,185.76.151.0/24,no-resolve

  # === WHATSAPP ===
  - DOMAIN-SUFFIX,whatsapp.com
  - DOMAIN-SUFFIX,whatsapp.net
  
  # === BRAWL STARS ===
  - DOMAIN-SUFFIX,supercell.com
  - DOMAIN-SUFFIX,supercellid.com
  - DOMAIN-SUFFIX,brawlstarsgame.com
  
  # === СИСТЕМНЫЕ СЛУЖБЫ ===
  - DOMAIN-SUFFIX,4pda.to
  - DOMAIN-SUFFIX,openwrt.org
  - DOMAIN-SUFFIX,intel.com
  - DOMAIN-SUFFIX,nvidia.com
  - DOMAIN-SUFFIX,github.com
  - DOMAIN-SUFFIX,githubusercontent.com
  - DOMAIN-SUFFIX,raw.githubusercontent.com
EOF

    echo "--> Создание эталонной конфигурации /etc/mihomo/config.yaml..."
    cat > /etc/mihomo/config.yaml <<'EOF'
mode: rule
ipv6: false
mixed-port: 7890
log-level: info
allow-lan: true
unified-delay: true
tcp-concurrent: false
find-process-mode: off
external-controller: 0.0.0.0:9090
external-ui: ./UI
secret: "12345"
external-ui-url: "https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
routing-mark: 2

profile:
  store-selected: true
  store-fake-ip: true

dns:
  enable: true
  listen: 0.0.0.0:7880
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 8.8.8.8
    - 1.1.1.1
    - https://dns.google/dns-query
  nameserver-policy:
    'geosite:category-gov-ru,ru,su,by,kz,am,private':
      - 77.88.8.8
      - 77.88.8.1

tun:
  enable: true
  stack: system
  dns-hijack:
    - any:53
  auto-route: true
  auto-redirect: true
  auto-detect-interface: true

proxy-providers:
  my_servers:
    type: file
    path: ./rule-files/servs.txt
    health-check:
      enable: true
      url: http://cp.cloudflare.com/generate_204
      interval: 300

rule-providers:
  extra_rules:
    type: file
    behavior: classical
    path: ./rule-files/rules.txt

proxies:
  - name: Домашний интернет
    type: direct

proxy-groups:
  - name: 🚀 ВЫБОР СЕРВЕРА
    type: select
    proxies:
      - ⚡ АВТО-ВЫБОР (Latency)
      - Домашний интернет
    use:
      - my_servers

  - name: ⚡ АВТО-ВЫБОР (Latency)
    type: url-test
    url: http://cp.cloudflare.com/generate_204
    interval: 300
    tolerance: 50
    use:
      - my_servers

rules:
  # 1. ИСКЛЮЧЕНИЯ ДЛЯ TAILSCALE И ЛОКАЛОК
  - DOMAIN-SUFFIX,tailscale.com,DIRECT
  - DOMAIN-SUFFIX,ts.net,DIRECT
  - DOMAIN-KEYWORD,tailscale,DIRECT
  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve

  # Блокировка QUIC
  - AND,((PROTOCOL,UDP),(DEST-PORT,443)),REJECT

  # 2. ПОДКЛЮЧАЕМ ВНЕШНИЙ ФАЙЛ ПРАВИЛ (rules.txt)
  - RULE-SET,extra_rules,🚀 ВЫБОР СЕРВЕРА

  # 3. ВСЁ ОСТАЛЬНОЕ НАПРЯМУЮ
  - MATCH,Домашний интернет
EOF

    echo "--> Создание скрипта обновления /usr/bin/update_servers.sh..."
    cat > /usr/bin/update_servers.sh <<'EOF'
#!/bin/sh
RESPONSE=$(curl -s -w "%{http_code}" -o /dev/null -X POST -H "Authorization: Bearer 12345" "http://127.0.0.1:9090/providers/proxies/my_servers")
if [ "$RESPONSE" -eq 204 ]; then
    echo "УСПЕШНО: Mihomo перечитал файл servs.txt и обновил серверы в памяти!"
else
    echo "ОШИБКА: Не удалось обновить серверы. Код ответа API: $RESPONSE"
    exit 1
fi
EOF
    chmod +x /usr/bin/update_servers.sh

    echo "--> Добавление кнопки в Пользовательские Команды (luci-app-commands)..."
    uci add luci_commands command
    uci set luci_commands.@command[-1].name='Обновить серверы в Mihomo'
    uci set luci_commands.@command[-1].command='/usr/bin/update_servers.sh'
    uci commit luci_commands

    echo "--> Создание системной службы /etc/init.d/mihomo..."
    cat > /etc/init.d/mihomo <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

MIHOMO_BIN="/usr/bin/mihomo"
MIHOMO_DIR="/etc/mihomo"
MIHOMO_CONF="/etc/mihomo/config.yaml"

start_service() {
    [ -x "$MIHOMO_BIN" ] || return 1
    [ -s "$MIHOMO_CONF" ] || return 1

    procd_open_instance "main"
    procd_set_param command "$MIHOMO_BIN" -d "$MIHOMO_DIR" -f "$MIHOMO_CONF"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "mihomo"
}
EOF
    chmod +x /etc/init.d/mihomo
    /etc/init.d/mihomo enable || log_warn "Не удалось включить автозапуск"

    echo "--> Настройка страницы LuCI для управления Mihomo..."
    mkdir -p /usr/share/luci/menu.d
    cat > /usr/share/luci/menu.d/luci-app-mihomo.json <<'EOF'
{
    "admin/services/mihomo": {
        "title": "Mihomo",
        "order": 60,
        "action": { "type": "view", "path": "mihomo/config" },
        "depends": { "acl": [ "luci-app-mihomo" ] }
    }
}
EOF

    mkdir -p /usr/share/rpcd/acl.d
    cat > /usr/share/rpcd/acl.d/luci-app-mihomo.json <<'EOF'
{
    "luci-app-mihomo": {
        "description": "Mihomo control",
        "read": {
            "file": {
                "/etc/mihomo/config.yaml": ["read"],
                "/etc/mihomo/rule-files/": ["list"],
                "/etc/mihomo/rule-files/*": ["read"]
            },
            "ubus": {
                "file": ["read", "list"],
                "service": ["list"]
            }
        },
        "write": {
            "file": {
                "/etc/mihomo/config.yaml": ["write"],
                "/etc/mihomo/rule-files/*": ["write"],
                "/usr/bin/mihomo": ["exec"],
                "/etc/init.d/mihomo": ["exec"],
                "/sbin/logread": ["exec"],
                "/bin/sh": ["exec"],
                "/bin/ash": ["exec"],
                "/usr/bin/curl": ["exec"],
                "/usr/bin/wget": ["exec"],
                "/bin/gzip": ["exec"],
                "/bin/chmod": ["exec"],
                "/bin/mv": ["exec"],
                "/bin/rm": ["exec"]
            },
            "ubus": {
                "file": ["write"],
                "service": ["list"]
            }
        }
    }
}
EOF

    local VIEW_PATH="/www/luci-static/resources/view/mihomo"
    local ACE_PATH="$VIEW_PATH/ace"
    mkdir -p "$ACE_PATH"

    echo "--> Определение последней версии ACE Editor..."
    local LATEST_ACE_VER
    LATEST_ACE_VER=$(curl -skL "https://api.cdnjs.com/libraries/ace" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 | head -1)
    if [ -z "$LATEST_ACE_VER" ]; then
        LATEST_ACE_VER="1.43.3"
    else
        echo "--> Актуальная версия ACE: $LATEST_ACE_VER"
    fi

    log_info "Скачивание файлов ACE Editor $LATEST_ACE_VER напрямую с GitHub..."
    local CDNJS_ACE_VER="1.43.6"
    for file in ace.js theme-merbivore_soft.js theme-tomorrow.js mode-yaml.js worker-yaml.js; do
        local dest="${ACE_PATH}/${file}"
        local success=0
        
        # Скачиваем файлы ACE напрямую
        for url in "https://cdn.jsdelivr.net/npm/ace-builds@${LATEST_ACE_VER}/src-min-noconflict/${file}" \
                   "https://raw.githubusercontent.com/ajaxorg/ace-builds/master/src-min-noconflict/${file}" \
                   "https://cdnjs.cloudflare.com/ajax/libs/ace/${CDNJS_ACE_VER}/${file}"; do
            
            echo -n "  -> Скачивание $file ... "
            if curl -skLf --connect-timeout 5 --max-time 30 -o "$dest" "$url" || wget -q -T 5 -O "$dest" "$url"; then
                if [ -s "$dest" ]; then
                    echo "OK"
                    success=1
                    break
                fi
            fi
            echo "FAIL"
        done

        if [ "$success" -eq 0 ]; then
            log_error "Не удалось скачать $file."
            return 1
        fi
    done

    # Создаем LuCI JavaScript файл
    echo "--> Создание config.js..."
    cat > "$VIEW_PATH/config.js" <<'EOF'
'use strict';
'require view';
'require fs';
'require ui';
'require rpc';

var ACE_DIR = '/luci-static/resources/view/mihomo/ace/';
var RELOAD_DELAY = 1000;
var MAIN_CONFIG = '/etc/mihomo/config.yaml';
var RULE_DIR = '/etc/mihomo/rule-files/';

var editor = null;
var currentFile = MAIN_CONFIG;
var cachedRuleFiles = [];
var mainConfigContent = '';
var loadedScripts = {};
var VALID_ACTIONS = ['start', 'stop', 'restart', 'check', 'logs'];

var callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: ['name']
});

function escapeHtml(text) {
    if (typeof text !== 'string') return text;
    return text.replace(/[&<>"']/g, function(m) {
        return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m];
    });
}

function validatePath(path, allowedBase) {
    if (!path || typeof path !== 'string') return false;
    if (path.includes('..') || path.includes('\0') || path.includes('~')) return false;
    var resolved = path.replace(/\/+/g, '/');
    if (!resolved.startsWith(allowedBase)) return false;
    if (resolved.length > 1024) return false;
    return true;
}

function isSafeRulePath(path) {
    return validatePath(path, RULE_DIR) && path !== MAIN_CONFIG;
}

function validateFilename(filename) {
    if (!filename || typeof filename !== 'string') return false;
    if (!/^[a-zA-Z0-9._-]+$/.test(filename)) return false;
    if (filename.length > 255) return false;
    var reservedNames = ['con', 'prn', 'aux', 'nul', 'com1', 'lpt1', '.'];
    if (reservedNames.includes(filename.toLowerCase())) return false;
    return true;
}

function sanitizeTabName(name) {
    if (!name) return '';
    return name.replace(/[<>"'`]/g, '');
}

function loadScript(src) {
    return new Promise(function(resolve, reject) {
        if (loadedScripts[src]) { resolve(); return; }
        var script = document.createElement('script');
        script.src = src;
        script.onload = function() { loadedScripts[src] = true; resolve(); };
        script.onerror = reject;
        document.head.appendChild(script);
    });
}

function detectRuleType(line) {
    line = line.trim();
    if (line.includes(':') && !line.match(/http(s)?:\/\//)) return 'IP-CIDR6';
    if (/^\d{1,3}(\.\d{1,3}){3}\/\d+$/.test(line)) return 'IP-CIDR';
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(line)) return 'IP-CIDR';
    if (line.startsWith('.')) return 'DOMAIN-WILDCARD';
    var cleanDomain = line.replace(/^\./, '');
    var dots = (cleanDomain.match(/\./g) || []).length;
    if (dots >= 2) return 'DOMAIN';
    if (dots === 1) return 'DOMAIN-SUFFIX';
    return 'DOMAIN-KEYWORD';
}

function generateProviderSnippet(filename) {
    if (filename === MAIN_CONFIG) return '';
    var baseName = filename.split('/').pop();
    if (!validateFilename(baseName)) throw new Error('Invalid filename');
    var nameNoExt = baseName.replace(/\.(yaml|txt)$/, '');
    var isTxt = baseName.endsWith('.txt');
    var behavior = isTxt ? 'domain' : 'classical';
    var format = isTxt ? 'text' : 'yaml';
    return `${nameNoExt}-list:\n  type: file\n  behavior: ${behavior}\n  format: ${format}\n  path: ./rule-files/${baseName}`;
}

function isLuciDarkMode() {
    try {
        var rgb = window.getComputedStyle(document.body).backgroundColor.match(/\d+/g);
        if (rgb) {
            var luma = 0.2126 * parseInt(rgb[0]) + 0.7152 * parseInt(rgb[1]) + 0.0722 * parseInt(rgb[2]); 
            return luma < 128;
        }
    } catch(e) {}
    return false;
}

return view.extend({
    isProcessing: false,
    currentVersion: 'Неизвестно',
    latestVersion: null,
    updateButton: null,
    latestVersionEl: null,
	
    getMihomoVersion: function() {
        return fs.stat('/usr/bin/mihomo')
            .then(function() { return fs.exec('/usr/bin/mihomo', ['--v']); })
            .then(function(res) {
                if (res.code === 0 && res.stdout) {
                    var match = res.stdout.match(/v(\d+\.\d+\.\d+)/);
                    return match ? match[0] : 'Неизвестно';
                }
                return 'Неизвестно';
            })
            .catch(function(err) {
                console.error('Error getting version:', err);
                return 'Неизвестно';
            });
    },

    renderUpdateStatus: function(latestVersion, isManual) {
        var currentVersion = this.currentVersion || 'Неизвестно';
        this.latestVersion = latestVersion;

        if (this.latestVersionEl) {
            this.latestVersionEl.textContent = _('(актуальное ядро %s)').format(latestVersion.replace('v', ''));
            this.latestVersionEl.style.display = 'inline';
            this.latestVersionEl.style.color = (latestVersion !== currentVersion) ? '#5cb85c' : '';
            this.latestVersionEl.style.opacity = (latestVersion !== currentVersion) ? '1' : '0.6';
        }

        if (latestVersion === currentVersion) {
            this.updateButton.textContent = _('Проверить обновление');
            this.updateButton.className = 'btn cbi-button-neutral';
            this.updateButton.disabled = false;
            this.updateButton.onclick = function() { window.location.reload(); };
            if (isManual) window.location.reload();
        } else {
            this.updateButton.textContent = _('Установить обновление');
            this.updateButton.className = 'btn cbi-button-action';
            this.updateButton.disabled = false;
            this.updateButton.onclick = ui.createHandlerFn(this, 'handleUpdateMihomo');
        }
    },
	
	checkForUpdates: function(isManual) {
		var self = this;
        var CACHE_KEY = 'mihomo_update_cache';
        var CACHE_TIME = 3600 * 1000;

        if (!isManual) {
            try {
                var cachedRaw = localStorage.getItem(CACHE_KEY);
                if (cachedRaw) {
                    var cached = JSON.parse(cachedRaw);
                    if (cached.version && (Date.now() - cached.timestamp < CACHE_TIME)) {
                        this
