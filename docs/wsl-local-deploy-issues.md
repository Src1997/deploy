# WSL 本地宝塔部署问题记录

> **Category**: Guide（人类排障档案，非规范约束）  
> **日期**: 2026-07-31（问题 1–11 初始）; 2026-07-31 追加（问题 12–13）  
> **环境**: WSL Ubuntu 26.04 + 宝塔面板 + Windows 11  
> **目标**: 在本地 WSL 中模拟服务器 A 的宝塔部署环境  
> **索引**: [docs/README.md](./README.md)

## 一、对正式服务器部署的影响评估

**结论：不影响正式服务器部署。**

| 改动类型 | 文件 | 影响 |
|----------|------|------|
| 行尾符污染 (CRLF) | `configs/`, `.gitattributes`, `projects.yaml` 等 | ✅ 已 `git checkout` 恢复，无残留 |
| Bug 修复 | `scripts/build.ps1` | ✅ 传参增加 `-SourceDir`，对正式部署有益 |
| Bug 修复 | `scripts/lib/load-projects.ps1` | ✅ 修复 `sourcePath` 为数组时的路径解析 |
| Bug 修复 | `scripts/pack-generic.ps1` | ✅ 修复 `robocopy` 退出码 8 误判 + 路径回退逻辑 |
| 临时脚本 | `scripts/_wsl-local-archive/` | ✅ 已归档，未跟踪，不进入 Git |
| 数据库 dump | `scripts/dumps/` | ✅ 本地数据导出，不提交 |
| 宝塔 API 文档 | `docs/baota-linux-panel.openapi.yaml` | ✅ 宝塔面板 API 定义，参考用 |

### 保留的实际修复（建议提交）

1. **`build.ps1`**: `& $p.PackScript -ProjectId $p.ProjectId -SourceDir $p.Dir`
   - 原因：打包时需要显式传递源码目录，否则 `pack-generic.ps1` 无法定位
2. **`load-projects.ps1`**: `Get-ProjectSourcePath` 函数增加数组类型处理
   - 原因：`projects.json` 中 `sourcePath` 可能是数组（如 financial-api 有多个源码目录）
3. **`pack-generic.ps1`**: 路径回退逻辑 + `robocopy` 退出码分级处理
   - 原因：`robocopy` 退出码 8（部分文件复制失败）不应中断打包

---

## 二、遇到的问题及解决方法

### 问题 1：宝塔安装脚本不支持 Ubuntu 26.04

**现象**: 宝塔官方安装脚本检测到 Ubuntu 26.04 后直接退出，提示"不支持的系统版本"。

**原因**: 宝塔安装脚本 (`install_panel.sh`) 内硬编码了支持的 Ubuntu 版本列表，最高只到 24.04。

**解决**: 下载安装脚本后，用 `sed` 补丁添加 26.04 支持：
```bash
sed -i 's/ubuntu_24/ubuntu_26/g' install_panel.sh
sed -i 's/24\.04/26.04/g' install_panel.sh
```

---

### 问题 2：WSL 网络异常（软路由 fake-IP 模式干扰）

**现象**: WSL 内无法访问外网，`apt update`、`wget` 全部超时。DNS 解析返回 `198.18.x.x`（fake-IP 段）。

**原因**: Windows 侧运行的软路由（Clash/Surge 等）开启了 TUN 模式或 fake-IP DNS，劫持了 WSL 的 DNS 解析。

**解决**: 临时关闭软路由后恢复正常。如需同时使用软路由，需在 WSL 内手动配置 DNS：
```bash
# /etc/wsl.conf
[network]
generateResolvConf = false

# /etc/resolv.conf
nameserver 8.8.8.8
nameserver 223.5.5.5
```

---

### 问题 3：宝塔面板 API 调用 "IP 验证失败"

**现象**: 使用宝塔 API 时返回 `{"status": false, "msg": "IP validation failed"}`，即使已在面板设置中添加 IP。

**原因**: 宝塔面板有两层 IP 白名单：
1. `iplist.txt` — 面板登录 IP 限制
2. `config/api.json` 中的 `limit_addr` — API 接口 IP 白名单

**解决**: 修改 `api.json` 中的 `limit_addr`：
```python
# 使用宝塔自带 Python 操作
import json
path = "/www/server/panel/config/api.json"
with open(path) as f:
    config = json.load(f)
config["limit_addr"] = ["127.0.0.1", "0.0.0.0", "::1"]
with open(path, "w") as f:
    json.dump(config, f)
```

---

### 问题 4：宝塔面板 API "Secret key validation failed"

**现象**: IP 白名单修复后，API 调用返回密钥验证失败。

**原因**: 宝塔 API 的 token 生成需要使用 `api.json` 中的 `token` 字段（而非 `key` 字段），且需要按特定算法拼接时间戳生成 MD5。

**解决**: 正确的 token 生成方式：
```bash
API_TOKEN=$(python3 -c "import json; print(json.load(open('/www/server/panel/config/api.json'))['token'])")
NOW=$(date +%s)
API_KEY=$(echo -n "${API_TOKEN}${NOW}" | md5sum | awk '{print $1}')
# 请求时传 panel_key=$API_KEY&request_time=$NOW
```

---

### 问题 5：宝塔面板 Nginx 返回 404

**现象**: 部署完成后，访问 `http://127.0.0.1` 或宝塔面板均返回 404。

**原因**: 宝塔自带的 `phpfpm_status.conf` 配置监听了 `127.0.0.1` 的 80 端口，与项目 Nginx 配置冲突，劫持了所有请求。

**解决**: 禁用冲突配置：
```bash
mv /www/server/panel/vhost/nginx/phpfpm_status.conf \
   /www/server/panel/vhost/nginx/phpfpm_status.conf.bak
nginx -s reload
```

---

### 问题 6：deepquant-backend Python 3.14 与 coincurve 不兼容

**现象**: WSL Ubuntu 26.04 系统自带 Python 3.14，`pip install coincurve` 编译失败。

**原因**: `coincurve` 的 C 扩展尚未适配 Python 3.14，需要 Python 3.12 或更低版本。

**解决**: 使用宝塔的 Python 项目管理器安装 Python 3.12：
```bash
# 宝塔 Python 版本管理器插件路径
# /www/server/panel/plugin/pythonmamager/install_python.sh
sudo bash /www/server/panel/plugin/pythonmamager/install_python.sh 3.12.0

# Python 安装路径: /www/server/python_manager/versions/3.12.0/bin/python3

# 创建虚拟环境
sudo /www/server/python_manager/versions/3.12.0/bin/python3 -m venv .venv
```

---

### 问题 7：端口 5000 被多个 gunicorn 进程占用

**现象**: `deepquant-backend.service` 启动时报 `Address already in use: ('0.0.0.0', 5000)`。

**原因**: 部署过程中创建了两个 systemd 服务管理同一个后端：
- `quantdinger-backend.service` — 部署脚本创建的
- `deepquant-backend.service` — 手动修复时创建的

两个服务用同一个 venv 和端口，互相抢占。

**解决（WSL 临时）**: 当时禁用了其中一个单元以解除端口冲突。

> **正式 SSOT**：`projects.yaml` / `deploy.sh` 使用的单元名是 **`quantdinger-backend.service`**（见 `configs/quantdinger-backend.service`）。  
> WSL 本地若手写了 `deepquant-backend.service`，应迁回 SSOT 名称，避免与生产脚本不一致：
```bash
# 推荐：只保留 quantdinger-backend
sudo systemctl stop deepquant-backend quantdinger-backend 2>/dev/null || true
sudo systemctl disable deepquant-backend 2>/dev/null || true
sudo rm -f /etc/systemd/system/deepquant-backend.service
# 确保 quantdinger-backend.service 来自 configs/，再 enable + start
sudo systemctl daemon-reload
sudo systemctl enable --now quantdinger-backend
```

---

### 问题 8：宝塔面板看不到 PostgreSQL 和 Redis

**现象**: 宝塔面板的数据库管理页面为空，看不到已安装的 PostgreSQL 数据库。Redis 状态也显示异常。

**原因**:
1. **PostgreSQL**: 宝塔安装在 `/www/server/pgsql/`，但面板的 `pgsql_manager` 插件查找 `/www/server/postgresql/`，路径不匹配
2. **数据库**: 通过 `psql` 命令行创建的数据库没有在宝塔面板的 `default.db` 中注册
3. **Redis**: `redis_manager` 插件未安装

**解决**:
```bash
# PostgreSQL: 创建符号链接
sudo ln -s /www/server/pgsql /www/server/postgresql

# 数据库: 在宝塔 SQLite 中注册
sqlite3 /www/server/panel/data/default.db
INSERT INTO databases (pid, name, username, password, accept, ps, addtime)
VALUES (1, 'quantdinger', 'root', '<PG_PASSWORD>', '127.0.0.1', 'DeepQuant', strftime('%s','now'));
INSERT INTO databases (pid, name, username, password, accept, ps, addtime)
VALUES (2, 'quant_zc', 'root', '<PG_PASSWORD>', '127.0.0.1', 'Financial', strftime('%s','now'));

# Redis: 写入手动配置
# /www/server/panel/data/redis_config.json
```

---

### 问题 9：宝塔面板 SSL 导致访问不便

**现象**: 宝塔面板默认开启 SSL，访问 `http://127.0.0.1:8888` 无法打开，必须用 HTTPS。

**原因**: 宝塔安装后默认开启 SSL（`ssl.pl` 内容为 `True`），且面板端口随机分配（非 8888）。

**解决**:
```bash
echo "False" > /www/server/panel/data/ssl.pl
/etc/init.d/bt restart
# 然后通过 http://127.0.0.1:<port> 访问
# 端口查看: cat /www/server/panel/data/port.pl
```

---

### 问题 10：PowerShell 打包脚本路径解析错误

**现象**: `build.ps1` 打包后端时，`pack-generic.ps1` 无法找到源码目录，报错退出。

**原因**: `projects.json` 中部分项目的 `sourcePath` 是数组类型（如 financial-api 有多个源码目录），而 `Get-ProjectSourcePath` 函数直接拼接字符串，未处理数组。

**解决**: 修改 `load-projects.ps1` 中的 `Get-ProjectSourcePath` 函数：
```powershell
$sp = if ($proj.sourcePath -is [array]) { $proj.sourcePath[0] } else { [string]$proj.sourcePath }
return Join-Path $global:WorkspaceRoot $sp
```

同时修改 `build.ps1` 显式传递 `-SourceDir`：
```powershell
& $p.PackScript -ProjectId $p.ProjectId -SourceDir $p.Dir
```

---

### 问题 11：robocopy 退出码 8 误判为致命错误

**现象**: `pack-generic.ps1` 打包时 `robocopy` 返回退出码 8，脚本直接报错退出。

**原因**: `robocopy` 退出码 8 表示"部分文件复制失败"（如文件被占用），并非致命错误。原代码以 `> 7` 作为失败阈值过于严格。

**解决**: 分级处理退出码：
```powershell
$rc = $LASTEXITCODE
if ($rc -ge 16) { Write-Error "robocopy serious error"; exit 1 }
if ($rc -ge 8) { Write-Host "[warn] robocopy had some failures, continuing..." }
```

---

### 问题 12：宝塔面板 PostgreSQL 连接失败

**现象**: 宝塔面板显示 PostgreSQL 连接数据库失败。

**原因**: `postgres` 超级用户没有密码，宝塔通过 TCP（md5 认证）连接必然失败。

**解决**:
```bash
# 给 postgres 用户设置密码
ALTER ROLE postgres WITH PASSWORD 'postgres123';

# 创建宝塔密码存储文件
echo '{"password":"postgres123"}' > /www/server/panel/data/postgresAS.json
```

---

### 问题 13：宝塔面板 Redis 状态显示异常（多轮排查）

**现象**: 宝塔面板 Redis 一直显示"状态：异常"，重启 Redis、重载面板均无效。

**排查过程**（共 5 轮，逐层深入）：

| 轮次 | 排查发现 | 修复 | 是否解决 |
|------|----------|------|----------|
| 1 | `data/` 目录权限 `root:root`，宝塔用 `sudo -u redis` 启动失败 | `chown -R redis:redis /www/server/redis/data/` | ❌ |
| 2 | `redis.conf` 中 `requirepass` 行有 CRLF（`\r\n`），密码带 `\r` 导致认证失败 | `sed -i 's/\r$//' redis.conf` | ❌ |
| 3 | `bind` 是 `redis.conf` 第一行，宝塔正则 `\n\s*bind` 匹配不到 | 文件开头加空行 | ❌ |
| 4 | `/var/run/redis_6379.pid` 不存在，宝塔 `checkProcess` 检测失败 | 创建符号链接 → `/www/server/redis/redis.pid` | ❌ |
| 5 | 宝塔配置校验：`maxmemory 256mb` 非纯数字 + 缺少 `appendfsync` 参数 | `maxmemory 268435456` + 添加 `appendfsync everysec` | ✅ |

**根因**: 宝塔 `redis_main.py` 的配置校验逻辑（第 81–189 行）要求：
1. `maxmemory` 值必须是纯数字（字节），不认 `mb`/`gb` 后缀
2. `appendfsync` 参数必须存在，否则直接 `return public.returnMsg(False, ...)`

这两个条件任一不满足，宝塔面板就显示"异常"。

**解决**:
```bash
# maxmemory 改为纯数字（256MB = 268435456 字节）
sudo sed -i 's/^maxmemory 256mb/maxmemory 268435456/' /www/server/redis/redis.conf

# 添加 appendfsync 参数（在 appendonly no 后面）
sudo sed -i '/^appendonly no/a appendfsync everysec' /www/server/redis/redis.conf

# 重启 Redis + 宝塔面板
sudo /etc/init.d/redis restart
sudo /etc/init.d/bt restart
```

**教训**: 宝塔面板的"异常"状态不一定代表服务本身有问题，可能是面板自己的配置校验逻辑不通过。排查时应先查看面板给出的具体错误信息，而非从服务进程层面入手。

---

## 三、最终服务状态

| 服务 | 端口 | systemd 单元 | 状态 |
|------|------|--------------|------|
| DeepQuant Backend | 5000 | 应为 `quantdinger-backend.service`（SSOT；WSL 曾误用 `deepquant-backend`） | ✅ active |
| Financial API | 5001 | `financial-api.service` | ✅ active |
| Nginx | 80 | `nginx.service` | ✅ active |
| PostgreSQL 18 | 5432 | `bt-postgresql.service` | ✅ active |
| Redis 7.4 | 6379 | `bt-redis.service` | ✅ active |
| 宝塔面板 | 40038 | `bt.service` | ✅ active |

### Nginx 路由

| 路径 | 目标 | HTTP |
|------|------|------|
| `/` | financial-web (静态) | 200 |
| `/qd/` | official-site (静态) | 200 |
| `/quant/` | deepquant-web (静态) | 200 |
| `/api/` | financial-api :5001 | 200 |
| `/api/ws` | financial-api :5001 (WebSocket) | — |
| `/quant/api/` | deepquant-backend :5000 | 200 |

### 数据库

| 数据库 | 表数量 | 用途 |
|--------|--------|------|
| `quantdinger` | 42 张表 | DeepQuant 后端 |
| `quant_zc` | 50 张表 | Financial API |
| `ea_lab_db` | 新建空库 | EA Lab / 默认库 |

> 密码 SSOT 为 `deploy/deploy.env`，禁止写入文档。

---

## 四、关键路径速查

```
# 宝塔面板
面板端口:   cat /www/server/panel/data/port.pl
面板 SSL:   cat /www/server/panel/data/ssl.pl
面板数据库: /www/server/panel/data/default.db (SQLite)

# PostgreSQL
安装路径:   /www/server/pgsql (符号链接: /www/server/postgresql)
数据目录:   /www/server/pgsql/data
连接:       PGPASSWORD="$PG_PASSWORD" /www/server/pgsql/bin/psql -U root -h 127.0.0.1 -p 5432
            # 密码见本机 deploy.env / 服务器 deploy.env，禁止写入文档

# Redis
安装路径:   /www/server/redis
配置文件:   /www/server/redis/redis.conf
连接:       redis-cli -h 127.0.0.1 -p 6379 -a "$REDIS_PASSWORD"
注意:       redis.conf 中 maxmemory 必须用纯数字（字节），不能带 mb/gb 后缀
            redis.conf 中必须有 appendfsync 参数，否则宝塔面板显示异常
pidfile:    /www/server/redis/redis.pid (符号链接: /var/run/redis_6379.pid)

# Python 3.12 (宝塔管理)
安装路径:   /www/server/python_manager/versions/3.12.0/bin/python3

# Nginx
配置文件:   /www/server/panel/vhost/nginx/default.conf
主配置:     /www/server/nginx/conf/nginx.conf

# 项目部署
项目根目录: /www/wwwroot/project
deepquant:  /www/wwwroot/project/deepquant/backend/package
financial:  /www/wwwroot/project/financial/financial-api/package
```
