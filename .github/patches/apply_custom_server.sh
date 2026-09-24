#!/usr/bin/env bash
# 把自建服务器信息「烧」进客户端源码（在 CI 里 checkout 之后、编译之前执行）
#
# 原理（依据 rustdesk 1.5.0 源码）：
#   libs/hbb_common/src/config.rs
#     · PROD_RENDEZVOUS_SERVER  —— 未配置 ID 服务器时的默认 ID 服务器 → 自建域名/IP（端口自动补 21116）
#     · RS_PUB_KEY              —— 未配置 key 时的默认服务器公钥 → 自建服务器 id_ed25519.pub
#     · RENDEZVOUS_SERVERS      —— 官方公网 ID 兜底列表 → 替换为自建，杜绝回退公网
#   src/common.rs（get_api_server_，1125-1145）
#     · API 地址原本按 ID 服务器端口推导（http://<host>:21114）→ 改成走 nginx TLS：https://<host>（443）
#   中继(21117) 无需配置：由 hbbs 下发的 ph.relay_server 决定
#
# 取值顺序：命令行环境变量 > .github/patches/server.env > 文件内默认值
# 用法: bash .github/patches/apply_custom_server.sh
set -euo pipefail

# Windows 运行器的 Python 默认用 cp1252 输出，遇到 ✓/中文会 UnicodeEncodeError 直接把步骤打挂。
# 强制 UTF-8（并让下面 Python 的输出保持 ASCII 友好）。
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$HERE/server.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$HERE/server.env"; set +a
fi

HOST="${JYAI_RD_HOST:-rust.internal.jiayouexp.com}"
API="${JYAI_RD_API:-https://$HOST}"
KEY="${JYAI_RD_KEY:-}"
CONFIG=libs/hbb_common/src/config.rs
COMMON=src/common.rs
[ -f "$CONFIG" ] || { echo "!! 找不到 $CONFIG（submodule 没拉下来？）"; exit 1; }
[ -f "$COMMON" ] || { echo "!! 找不到 $COMMON"; exit 1; }
[ -n "$KEY" ] || { echo "!! 缺少 JYAI_RD_KEY（服务器公钥 id_ed25519.pub 内容），拒绝构建出连不上服务器的客户端"; exit 1; }
case "$KEY" in *"*"*) echo "!! JYAI_RD_KEY 里含 '*'（脱敏后的假值），请用真实公钥"; exit 1;; esac

cp "$CONFIG" "$CONFIG.orig"
cp "$COMMON" "$COMMON.orig"
# 自检/备份文件绝不留在工作区（否则会被 publish_fork.sh 的 git add -A 带进提交）
trap 'rm -f "$CONFIG.orig" "$COMMON.orig"' EXIT

# (1) 服务端三处编译期常量
python3 - "$CONFIG" "$HOST" "$KEY" <<'PY'
import re, sys
path, host, key = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()

s, n1 = re.subn(r'(PROD_RENDEZVOUS_SERVER: RwLock<String> = RwLock::new\(")([^"]*)(")',
                lambda m: m.group(1) + host + m.group(3), s, count=1)
s, n2 = re.subn(r'(pub const RS_PUB_KEY: &str = ")([^"]*)(";)',
                lambda m: m.group(1) + key + m.group(3), s, count=1)
s, n3 = re.subn(r'(pub const RENDEZVOUS_SERVERS: &\[&str\] = &\[)([^\]]*)(\];)',
                lambda m: m.group(1) + '"%s"' % host + m.group(3), s, count=1)

missing = [n for n, c in (('PROD_RENDEZVOUS_SERVER', n1), ('RS_PUB_KEY', n2), ('RENDEZVOUS_SERVERS', n3)) if c != 1]
if missing:
    sys.exit('!! failed to rewrite: %s' % ', '.join(missing))
open(path, 'w', encoding='utf-8').write(s)
for pat, name in ((r'PROD_RENDEZVOUS_SERVER: RwLock<String>.*', 'default-id-server'),
                  (r'pub const RS_PUB_KEY.*', 'pub-key'),
                  (r'pub const RENDEZVOUS_SERVERS.*', 'fallback-list')):
    print('  [OK] %s -> %s' % (name, re.search(pat, s).group(0)[:110]))
PY

# (2) 客户端默认 API 地址：http://<ID主机>:21114 → https://<ID主机>（走 nginx 443，TLS）
python3 - "$COMMON" "$API" <<'PY'
import re, sys
path, api = sys.argv[1], sys.argv[2]
s = open(path, encoding='utf-8').read()
old1 = 'return format!("http://{}:{}", s, config::RENDEZVOUS_PORT - 2);'
old2 = 'return format!("http://{}", s);'
c1, c2 = s.count(old1), s.count(old2)
if c1 != 1 or c2 != 1:
    sys.exit('!! src/common.rs api-derivation shape changed (hits %d/%d), refusing to patch' % (c1, c2))
host_only = api.split('://')[-1].split('/')[0]
# 两种分支都改成 https + 主机名（去掉 :21114 端口；443 由 nginx 承载）
new = ('// JYAI: self-hosted API is fronted by nginx TLS(443)\n'
       '            return format!("https://{}", s.split(\':\').next().unwrap_or(s.as_str()));')
s = s.replace(old1, new).replace(old2, new)
# 再把"兜底公网 API"也换掉，避免任何情况下回落到官方
s = s.replace('"https://admin.rustdesk.com".to_owned()', '"%s".to_owned()' % api)
open(path, 'w', encoding='utf-8').write(s)
print('  [OK] default api-server -> %s (was http://<host>:21114 / admin.rustdesk.com)' % api)
print('       target host: %s' % host_only)
PY

# 断言真的写进去了（防止"改了但没生效"）
grep -q "PROD_RENDEZVOUS_SERVER: RwLock<String> = RwLock::new(\"$HOST\"" "$CONFIG" || { echo "!! ID 服务器未写入"; exit 1; }
grep -q "RS_PUB_KEY: &str = \"$KEY\"" "$CONFIG"                                     || { echo "!! 公钥未写入"; exit 1; }
grep -q "RENDEZVOUS_SERVERS: &\[&str\] = &\[\"$HOST\"\]" "$CONFIG"                 || { echo "!! 兜底列表未写入"; exit 1; }
grep -q "https://{}" "$COMMON"                                                      || { echo "!! API 地址未写入"; exit 1; }
grep -qF '"https://admin.rustdesk.com".to_owned()' "$COMMON" && { echo "!! 官方 API 兜底地址仍在（get_api_server_ 回退分支）"; exit 1; } || true
echo "已烧入自建服务器：host=$HOST api=$API key=${KEY:0:12}…"
diff -u "$CONFIG.orig" "$CONFIG" | sed -n '1,24p' || true
diff -u "$COMMON.orig" "$COMMON" | sed -n '3,24p' || true