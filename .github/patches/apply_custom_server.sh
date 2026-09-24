#!/usr/bin/env bash
# 把自建服务器信息「烧」进客户端源码（在 CI 里 checkout 之后、编译之前执行）
#
# 原理（依据 rustdesk 1.5.0 源码）：
#   libs/hbb_common/src/config.rs
#     · PROD_RENDEZVOUS_SERVER  —— 未配置 ID 服务器时的默认 ID 服务器 → 自建域名/IP（端口自动补 21116）
#     · RS_PUB_KEY             —— 未配置 key 时的默认服务器公钥 → 自建服务器 id_ed25519.pub
#     · RENDEZVOUS_SERVERS     —— 官方公网 ID 兜底列表 → 替换为自建，杜绝回退公网
#   中继(21117)/API(21114) 无需显式配置：客户端按 ID 服务器端口自动推导
#   （src/common.rs:1125-1145 get_api_server_ → increase_port(-2)；relay 由 hbbs 下发的 ph.relay_server 决定）
#
# 取值顺序：命令行环境变量 > .github/patches/server.env > 文件内默认值
# 用法: bash .github/patches/apply_custom_server.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$HERE/server.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$HERE/server.env"; set +a
fi

HOST="${JYAI_RD_HOST:-rust.internal.jiayouexp.com}"
KEY="${JYAI_RD_KEY:-}"
CONFIG=libs/hbb_common/src/config.rs
[ -f "$CONFIG" ] || { echo "!! 找不到 $CONFIG（submodule 没拉下来？）"; exit 1; }
[ -n "$KEY" ] || { echo "!! 缺少 JYAI_RD_KEY（服务器公钥 id_ed25519.pub 内容），拒绝构建出连不上服务器的客户端"; exit 1; }
case "$KEY" in *"*"*) echo "!! JYAI_RD_KEY 里含 '*'（脱敏后的假值），请用真实公钥"; exit 1;; esac

cp "$CONFIG" "$CONFIG.orig"
python3 - "$CONFIG" "$HOST" "$KEY" <<'PY'
import re, sys
path, host, key = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
before = s

# 1) 默认 ID 服务器：PROD_RENDEZVOUS_SERVER: RwLock<String> = RwLock::new("xxx".to_owned());
s, n1 = re.subn(r'(PROD_RENDEZVOUS_SERVER: RwLock<String> = RwLock::new\(")([^"]*)(")',
                lambda m: m.group(1) + host + m.group(3), s, count=1)
# 2) 默认公钥
s, n2 = re.subn(r'(pub const RS_PUB_KEY: &str = ")([^"]*)(";)',
                lambda m: m.group(1) + key + m.group(3), s, count=1)
# 3) 公网兜底列表 → 自建
s, n3 = re.subn(r'(pub const RENDEZVOUS_SERVERS: &\[&str\] = &\[)([^\]]*)(\];)',
                lambda m: m.group(1) + '"%s"' % host + m.group(3), s, count=1)

missing = [name for name, n in (('PROD_RENDEZVOUS_SERVER', n1), ('RS_PUB_KEY', n2), ('RENDEZVOUS_SERVERS', n3)) if n != 1]
if missing:
    sys.exit('!! 未能改写这些常量（源码结构变了？）: %s' % ', '.join(missing))
open(path, 'w', encoding='utf-8').write(s)

for pat, name in ((r'PROD_RENDEZVOUS_SERVER: RwLock<String>.*', '默认ID服务器'),
                  (r'pub const RS_PUB_KEY.*', '默认公钥'),
                  (r'pub const RENDEZVOUS_SERVERS.*', '公网兜底列表')):
    print('  ✓ %s → %s' % (name, re.search(pat, s).group(0)[:110]))
PY

# 断言真的写进去了（防止"改了但没生效"）
grep -q "PROD_RENDEZVOUS_SERVER: RwLock<String> = RwLock::new(\"$HOST\"" "$CONFIG" || { echo "!! ID 服务器未写入"; exit 1; }
grep -q "RS_PUB_KEY: &str = \"$KEY\"" "$CONFIG"                                     || { echo "!! 公钥未写入"; exit 1; }
grep -q "RENDEZVOUS_SERVERS: &\[&str\] = &\[\"$HOST\"\]" "$CONFIG"                 || { echo "!! 兜底列表未写入"; exit 1; }
echo "已烧入自建服务器：host=$HOST key=${KEY:0:12}…"
diff -u "$CONFIG.orig" "$CONFIG" | sed -n '1,30p' || true