#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""baota_api.py — 宝塔面板 API 客户端（工具箱"一切基于宝塔"的统一通道）

方向（2026-10-20 用户定）：所有部署成果必须在宝塔面板原生出现、原生可管理——
  HTML 项目走宝塔建站、Python 走宝塔 Python 项目、Java 走宝塔 Java 项目。
本模块是工具箱与面板之间的唯一通道：不直写面板 DB、不手搓 nginx conf。

依赖配置（deploy.env.*）：
  BAOTA_PANEL_URL   如 https://192.168.31.166:27895
  BAOTA_API_KEY     面板 → 设置 → API 接口 的密钥（api.json 的 key 字段）

用法（CLI 探针）:
  python3 baota_api.py ping
  python3 baota_api.py list-sites

用法（作为库）:
  from baota_api import BaotaAPI
  api = BaotaAPI.from_env()      # 读 BAOTA_PANEL_URL / BAOTA_API_KEY
  api.ping()
"""
import hashlib
import json
import os
import ssl
import sys
import time
import urllib.parse
import urllib.request


class BaotaAPIError(Exception):
    """面板返回非 200 信封或网络失败。"""


class BaotaAPI:
    def __init__(self, panel_url, api_key, timeout=60, verify_ssl=False):
        self.url = panel_url.rstrip("/")
        self.key = api_key.strip()
        self.timeout = timeout
        self.ctx = None if verify_ssl else ssl._create_unverified_context()

    # ── 构造 ──
    @classmethod
    def from_env(cls, env=None):
        env = env or os.environ
        url = env.get("BAOTA_PANEL_URL", "")
        key = env.get("BAOTA_API_KEY", "")
        if not url or not key:
            raise BaotaAPIError("缺少 BAOTA_PANEL_URL / BAOTA_API_KEY（deploy.env.*）")
        return cls(url, key)

    # ── 签名与请求 ──
    def _signed(self, data):
        """宝塔 13.x 签名：request_token = md5(request_time + token)（单重 md5，
        源码 class/common.py check_api；老文档的双重 md5 公式已废弃）。"""
        data = dict(data or {})
        ts = str(int(time.time()))
        data["request_time"] = ts
        data["request_token"] = hashlib.md5((ts + self.key).encode()).hexdigest()
        return data

    def post(self, path, data=None):
        """POST /path?action=xxx，返回面板 JSON。非 dict 响应视为错误。"""
        payload = urllib.parse.urlencode(self._signed(data)).encode()
        req = urllib.request.Request(
            self.url + path,
            data=payload,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as r:
                body = r.read().decode("utf-8", "replace")
        except Exception as e:  # 网络/超时/SSL
            raise BaotaAPIError(f"请求失败 {path}: {e}") from e
        try:
            res = json.loads(body)
        except json.JSONDecodeError as e:
            raise BaotaAPIError(f"响应非 JSON {path}: {body[:200]!r}") from e
        # 宝塔错误信封常见形态：{"status": false, "msg": "..."} 或纯字符串
        if isinstance(res, dict) and res.get("status") is False:
            raise BaotaAPIError(f"面板拒绝 {path}: {res.get('msg', res)}")
        return res

    # ── 探针 ──
    def ping(self):
        """连通性探针：返回面板基础信息 dict。"""
        return self.post("/system?action=GetSystemTotal")

    # ── 站点（HTML 项目）──
    def get_site_types(self):
        """站点类型表（0=纯静态，其余为 PHP 版本等）。"""
        return self.post("/site?action=get_site_types")

    def list_sites(self, page=1, limit=100):
        """网站列表（data 字段为记录数组）。"""
        res = self.post("/data?action=getData&table=sites",
                        {"p": page, "limit": limit, "type": -1,
                         "order": "id desc", "search": ""})
        return res.get("data", []) if isinstance(res, dict) else res

    def site_exists(self, name):
        return any(s.get("name") == name for s in self.list_sites())

    def add_html_site(self, domain, path, ps="", extra_domains=()):
        """创建纯静态（HTML）站点。幂等：同名站点已存在则直接返回。
        ★project_type 必须是小写 'html'：前端标签值集合为 [php, proxy, html]，
        缺省会被归入 'PHP'，大写 'HTML' 则两边标签都不认（13.x 实测）。
        ★建站（含已存在路径）后自动执行 fix_html_conf_naming：AddSite 旧链路
        生成无前缀 conf，会让面板功能读不到（2026-10-23 B/C 实证）。"""
        created = False
        if self.site_exists(domain):
            result = {"status": True, "msg": "exists", "siteName": domain}
        else:
            created = True
            webname = json.dumps({
                "domain": domain,
                "domainlist": list(extra_domains),
                "count": 0,
            })
            result = self.post("/site?action=AddSite", {
                "webname": webname,
                "path": path,
                "type_id": 0,          # 0 = 纯静态
                "type": "1",           # 1 = 常规建站
                "version": "",
                "port": "80",
                "ps": ps,
                "ftp": "false",
                "sql": "false",
                "codeing": "utf8",
                "project_type": "html",
            })
        fixed = self.fix_html_conf_naming(domain)
        if fixed:
            result["conf_naming_fixed"] = fixed
        return result

    def fix_html_conf_naming(self, site_name):
        """★把建站产物 conf 对齐面板原生命名（只改名，不改路由内容）。
        背景（2026-10-23 B/C 实证）：面板 11.x 对 project_type='html' 的站点，
        流量限制/网站日志/伪静态等功能一律按 vhost/nginx/html_<站点名>.conf
        读取（无兜底），rewrite 目录同理；而 AddSite 旧链路生成无前缀
        <站点名>.conf → 面板报「配置文件读取错误/站点配置文件丢失」。
        面板原生 htmlModel 建站本就用 html_ 前缀，此处把 AddSite 产物对齐：
          ① nginx/<名>.conf → nginx/html_<名>.conf（同名并存时旧件挪 .bak）
          ② rewrite/<名>.conf → rewrite/html_<名>.conf + 同步 conf 内 include
          ③ 有改动时 nginx -t && reload（含 include 目标缺失兜底 touch）
        在非部署机上（无 /www/server/panel）静默跳过。"""
        import re
        import shutil
        nginx_dir = os.path.join(self.PANEL_ROOT, "vhost", "nginx")
        rw_dir = os.path.join(self.PANEL_ROOT, "vhost", "rewrite")
        if not os.path.isdir(nginx_dir):
            return None
        plain = os.path.join(nginx_dir, site_name + ".conf")
        prefixed = os.path.join(nginx_dir, "html_" + site_name + ".conf")
        actions = []
        if os.path.exists(plain):
            if os.path.exists(prefixed):
                bak = plain + ".bak-htmlnaming"
                shutil.move(plain, bak)   # 双 conf = server_name 冲突，旧件挪走
                actions.append(f"dup-moved:{bak}")
            else:
                shutil.move(plain, prefixed)
                actions.append(f"renamed:{prefixed}")
        # rewrite 文件对齐 + include 同步（conf 内引用无前缀 rewrite 时）
        rw_plain = os.path.join(rw_dir, site_name + ".conf")
        rw_prefixed = os.path.join(rw_dir, "html_" + site_name + ".conf")
        if os.path.exists(rw_plain) and not os.path.exists(rw_prefixed):
            shutil.move(rw_plain, rw_prefixed)
            actions.append(f"rew-renamed:{rw_prefixed}")
        if os.path.exists(prefixed):
            if not os.path.exists(rw_prefixed):
                open(rw_prefixed, "a", encoding="utf-8").close()
                actions.append(f"rew-created:{rw_prefixed}")
            with open(prefixed, encoding="utf-8", errors="replace") as f:
                conf = f.read()
            new_conf = re.sub(
                r"(vhost/rewrite/)%s\.conf" % re.escape(site_name),
                r"\g<1>html_%s.conf" % site_name, conf)
            if new_conf != conf:
                with open(prefixed, "w", encoding="utf-8") as f:
                    f.write(new_conf)
                actions.append("include-synced")
        if actions:
            import subprocess
            nginx_bin = shutil.which("nginx") or "/www/server/nginx/sbin/nginx"
            t = subprocess.run([nginx_bin, "-t"], capture_output=True, text=True)
            if t.returncode != 0:
                raise BaotaAPIError(f"nginx -t 失败（conf 改名后）: {t.stderr[-300:]}")
            subprocess.run([nginx_bin, "-s", "reload"], capture_output=True, text=True)
            actions.append("nginx-reloaded")
        return actions or None

    def remove_site(self, name):
        """删除站点（勿轻易调用——仅用于试点清理）。"""
        sid = self._site_id(name)
        return self.post("/site?action=DeleteSite", {"id": sid,
                                                     "webname": name})

    def remove_python_project(self, name, remove_env=False):
        """删除宝塔 Python 项目记录。remove_env=False 保护项目自带 venv
        （如 deepquant-backend 的 package/.venv 是真实运行环境）；
        True 仅用于面板自管 venv（pyporject_evn 下）的一次性项目。"""
        return self.post("/project/python/RemoveProject",
                         {"name": name,
                          "remove_env": "true" if remove_env else "false"})

    # ── 从零创建（面板 HTTP 路由 + 本机直调混合）──
    # 说明：宝塔 13 的部分能力（venv 注册、Java 项目）HTTP 表单传不了
    # 真 list / 需要面板内部类，统一走「本机直调」：subprocess 调面板
    # 自带 Python 执行面板源码。本机直调仅在部署机上可用（deploy.sh
    # 恰恰在服务器上执行），无面板目录时给出明确报错。

    PANEL_ROOT = "/www/server/panel"

    def _panel_python(self):
        p = os.path.join(self.PANEL_ROOT, "pyenv", "bin", "python3")
        if not os.path.exists(p):
            raise BaotaAPIError(
                f"本机直调需要面板环境，未找到 {p}（请在部署机上调用）")
        return p

    def _panel_exec(self, code):
        """本机直调面板源码（subprocess，stdout 取首个 {...} JSON 段解析；
        面板内部可能夹杂 print 的非 JSON 行）。"""
        import subprocess
        r = subprocess.run([self._panel_python(), "-c", code],
                           capture_output=True, text=True, timeout=300)
        out = r.stdout.strip()
        if r.returncode != 0:
            raise BaotaAPIError(f"面板直调失败: {r.stderr.strip()[-300:]}")
        s, e = out.find("{"), out.rfind("}")
        if s < 0 or e <= s:
            raise BaotaAPIError(f"面板直调输出非 JSON: {out[-200:]!r}")
        try:
            return json.loads(out[s:e + 1])
        except json.JSONDecodeError as ex:
            raise BaotaAPIError(f"面板直调输出解析失败: {out[s:e + 1][:200]!r}") from ex

    def register_python_venv(self, venv_root):
        """注册 venv 到面板环境列表（本机直调 EnvironmentManager）。
        幂等：注册表中已有以 venv_root 结尾的条目则跳过。"""
        reg = os.path.join(self.PANEL_ROOT, "data",
                           "python_project_name2env.txt")
        try:
            with open(reg) as f:
                if any(line.strip().endswith(venv_root) for line in f):
                    return
        except FileNotFoundError:
            pass
        code = (
            "import sys; "
            "sys.path.insert(0, %r); sys.path.insert(0, %r); "
            "from mod.project.python.environmentMod import EnvironmentManager; "
            "r = EnvironmentManager().add_python_env('venv', %r); "
            "import json; print(json.dumps({'err': r}))" %
            (self.PANEL_ROOT + "/class", self.PANEL_ROOT, venv_root)
        )
        out = self._panel_exec(code)
        err = out.get("err")
        if err:
            raise BaotaAPIError(f"venv 注册失败: {err}")

    def create_python_project(self, name, path, port, python_bin,
                              project_cmd, stype="command", user="root",
                              ps=""):
        """创建宝塔 Python 项目（HTTP /project/python/CreateProject）。
        stype: uwsgi | gunicorn | command。project_cmd 为启动命令。"""
        if self.python_project_exists(name):
            return {"status": True, "msg": "exists"}
        return self.post("/project/python/CreateProject", {
            "pjname": name,
            "port": str(port),
            "stype": stype,
            "path": path.rstrip("/"),
            "python_bin": python_bin,
            "project_cmd": project_cmd,
            "user": user,
            "ps": ps or name,
        })

    def ensure_python_project(self, name, path, port, venv_root,
                              project_cmd, stype="command", user="root"):
        """从零确保宝塔 Python 项目存在并运行：
        项目缺失 → 注册 venv → CreateProject → StartProject。
        已存在 → 原样返回（重启由 restart_python_project 负责）。"""
        if self.python_project_exists(name):
            return {"status": True, "msg": "exists"}
        self.register_python_venv(venv_root)
        r = self.create_python_project(name, path, port,
                                       f"{venv_root}/bin/python",
                                       project_cmd, stype=stype, user=user)
        if isinstance(r, dict) and r.get("status") is False:
            raise BaotaAPIError(f"创建 Python 项目失败: {r.get('msg', r)}")
        return self.post("/project/python/StartProject", {"name": name})

    def java_project_exists(self, name):
        """sites 表 project_type='Java' 是否有同名项目。"""
        res = self.post("/data?action=getData&table=sites",
                        {"p": 1, "limit": 100, "type": -1,
                         "order": "id desc", "search": name})
        for s in (res.get("data", []) if isinstance(res, dict) else []):
            if s.get("name") == name and s.get("project_type") == "Java":
                return True
        return False

    def ensure_java_project(self, name, jar_path, jdk_bin, project_cmd,
                            port, run_user="root", env_list=(), env_file="",
                            ps=""):
        """从零确保宝塔 Java（Spring Boot）项目存在并启动（本机直调，
        env_list 可传真 list——HTTP 表单传不了）。已存在则直接启动。"""
        if self.java_project_exists(name):
            return self._java_direct("start_project", name)
        args = {
            "project_type": 0,
            "project_name": name,
            "project_jar": jar_path,
            "project_jdk": jdk_bin,
            "project_cmd": project_cmd,
            "port": str(port),
            "run_user": run_user,
            "project_ps": ps or name,
            "proxy_path": "/",
            "env_list": list(env_list),
            "env_file": env_file,
        }
        return self._java_direct("create_project", name, args)

    def _java_direct(self, fun, name, create_args=None):
        """本机直调 mod/project/java/projectMod 的 main 类。"""
        args_js = json.dumps(create_args or {"project_name": name})
        code = (
            "import sys; "
            "sys.path.insert(0, %r); sys.path.insert(0, %r); "
            "import public; "
            "from mod.project.java.projectMod import main; "
            "import json; "
            "g = public.dict_obj(); [setattr(g, k, v) for k, v in json.loads(%r).items()]; "
            "r = main().%s(g); print(json.dumps(r, default=str))" %
            (self.PANEL_ROOT + "/class", self.PANEL_ROOT, args_js, fun)
        )
        return self._panel_exec(code)

    def _site_id(self, name):
        for s in self.list_sites():
            if s.get("name") == name:
                return s["id"]
        raise BaotaAPIError(f"站点不存在: {name}")

    # ── Python 项目（宝塔 13.x mod/project/python）──
    def list_python_projects(self):
        return self.post("/project/python/GetProjectList",
                         {"p": 1, "limit": 100, "search": ""})

    def python_project_exists(self, name):
        res = self.list_python_projects()
        items = res.get("data", res) if isinstance(res, dict) else res
        if isinstance(items, dict):
            items = items.get("list", [])
        return any((p.get("name") == name) for p in items)

    def get_python_project(self, name):
        """取单个 Python 项目记录（含 status 等运行态字段）。"""
        res = self.list_python_projects()
        items = res.get("data", res) if isinstance(res, dict) else res
        if isinstance(items, dict):
            items = items.get("list", [])
        for p in items:
            if p.get("name") == name:
                return p
        raise BaotaAPIError(f"宝塔 Python 项目不存在: {name}")

    def restart_python_project(self, name):
        """重启宝塔 Python 项目（原生通道；注意参数是 name 而非 pjname）。
        ★面板 restart = stop+start 立即连发，旧进程未退时 start 被端口
        检查静默拒绝——调用侧需轮询端口，必要时补 StartProject。"""
        return self.post("/project/python/RestartProject", {"name": name})

    def start_python_project(self, name):
        return self.post("/project/python/StartProject", {"name": name})

    def stop_python_project(self, name):
        return self.post("/project/python/StopProject", {"name": name})

    # ── 反向代理（宝塔 13.x panelSite.CreateProxy，配置落 extension/<site>/）──
    def get_proxy_list(self, site_name):
        return self.post("/site?action=GetProxyList", {"sitename": site_name})

    def create_proxy(self, site_name, proxy_name, proxy_dir, target_url,
                     to_domain=None, cache=0, advanced=0, cachetime=1):
        """在站点下创建反向代理（面板可见、面板可管）。
        proxy_dir 形如 /api/；target_url 形如 http://127.0.0.1:5000/api/。
        幂等：同名代理已存在则直接返回。"""
        existing = self.get_proxy_list(site_name)
        # GetProxyList 因面板版本而异：裸 list 或 {"data": [...]}, 两种都兼容
        if isinstance(existing, dict):
            items = existing.get("data", []) or existing.get("list", []) or []
        elif isinstance(existing, list):
            items = existing
        else:
            items = []
        if isinstance(items, list):
            for p in items:
                if p.get("proxyname") == proxy_name:
                    return {"status": True, "msg": "exists"}
        return self.post("/site?action=CreateProxy", {
            "proxyname": proxy_name,
            "sitename": site_name,
            "proxydir": proxy_dir,
            "proxysite": target_url,
            "todomain": to_domain or "127.0.0.1",
            "type": 1,             # 1 = 启用（type != 1 在面板语义里是"已暂停"）
            "cache": cache,
            "subfilter": json.dumps([]),
            "advanced": advanced,
            "cachetime": cachetime,
        })

    def add_domain(self, site_name, domain):
        """给已有站点追加域名（域名收编用）。"""
        return self.post("/site?action=AddDomain", {
            "webname": site_name,
            "domain": domain,
        })

    def del_domain(self, site_name, domain):
        """从站点移除域名（域名收编纠偏用）。
        ★面板 11.x DelDomain 必须带 port（否则报"请选择端口"）。"""
        return self.post("/site?action=DelDomain", {
            "webname": site_name,
            "domain": domain,
            "port": 80,
            "id": self._site_id(site_name),
        })

    def set_site_ssl(self, site_name, key, pem):
        """导入自定义证书（key=私钥 PEM，pem=fullchain PEM）。
        ★面板 11.x SetSSL 的证书字段名叫 csr（实际收 fullchain）。"""
        return self.post("/site?action=SetSSL", {
            "type": 1, "siteName": site_name,
            "key": key, "csr": pem,
            "forceName": False, "isTemp": 0, "ssl_type": 1,
        })

    def get_site_path(self, name):
        """取站点根目录（sites 表 path 字段，13.x 在 site.db）。"""
        for s in self.list_sites():
            if s.get("name") == name:
                return s.get("path", "")
        raise BaotaAPIError(f"站点不存在: {name}")

    # ── SSL 信息 ──
    def get_ssl(self, site_name):
        return self.post("/site?action=GetSSL", {"siteName": site_name})


# ── CLI ──
def _main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    api = BaotaAPI.from_env()
    cmd = argv[1]
    if cmd == "ping":
        info = api.ping()
        print("OK 面板版本:", info.get("version"), "| 时间:", info.get("time"))
        return 0
    if cmd == "list-sites":
        for s in api.list_sites():
            print(s.get("id"), s.get("name"), s.get("path"))
        return 0
    if cmd == "list-python-projects":
        res = api.list_python_projects()
        items = res.get("data", res) if isinstance(res, dict) else res
        if isinstance(items, dict):
            items = items.get("list", [])
        for p in items:
            print(p.get("name", "?"),
                  p.get("port", "-"),
                  p.get("path", "") or p.get("project_path", ""))
        return 0
    if cmd == "ensure-html-site":
        # ensure-html-site <domain> <path> [ps]
        r = api.add_html_site(argv[2], argv[3], ps=argv[4] if len(argv) > 4 else "")
        print(json.dumps(r, ensure_ascii=False))
        return 0
    if cmd == "restart-python":
        r = api.restart_python_project(argv[2])
        print(json.dumps(r, ensure_ascii=False))
        return 0
    if cmd == "start-python":
        r = api.start_python_project(argv[2])
        print(json.dumps(r, ensure_ascii=False))
        return 0
    if cmd == "ensure-python":
        # ensure-python <name> <path> <port> <venv_root> <project_cmd> [stype]
        r = api.ensure_python_project(
            argv[2], argv[3], argv[4], argv[5], argv[6],
            stype=argv[7] if len(argv) > 7 else "command")
        print(json.dumps(r, ensure_ascii=False))
        return 0
    if cmd == "ensure-java":
        # ensure-java <name> <jar_path> <jdk_bin> <project_cmd> <port> [run_user]
        r = api.ensure_java_project(
            argv[2], argv[3], argv[4], argv[5], argv[6],
            run_user=argv[7] if len(argv) > 7 else "root")
        print(json.dumps(r, ensure_ascii=False))
        return 0
    if cmd == "python-status":
        p = api.get_python_project(argv[2])
        print(json.dumps({k: p.get(k) for k in ("name", "status", "run", "port")},
                         ensure_ascii=False))
        return 0
    if cmd == "list-proxy":
        # list-proxy <site> → 每行 "proxydir|proxysite"（裸 list 或 {"data": [...]} 兼容）
        r = api.get_proxy_list(argv[2])
        items = (r.get("data") if isinstance(r, dict) else r) or []
        for px in items:
            d = px.get("proxydir", "")
            t = px.get("proxysite", "")
            if d:
                print(f"{d}|{t}")
        return 0
    if cmd == "del-site-domain":
        r = api.del_domain(argv[2], argv[3])
        print("OK" if not isinstance(r, dict) or r.get("status") in (True, None, 1) else r)
        return 0
    if cmd == "add-site-domain":
        r = api.add_domain(argv[2], argv[3])
        print("OK" if not isinstance(r, dict) or r.get("status") in (True, None, 1) else r)
        return 0
    if cmd == "set-site-ssl":
        r = api.set_site_ssl(argv[2], open(argv[3]).read(), open(argv[4]).read())
        print("SetSSL:", r.get("status") if isinstance(r, dict) else r)
        return 0
    if cmd == "create-proxy":
        # create-proxy <site> <proxy_name> <proxy_dir> <target_url>
        r = api.create_proxy(argv[2], argv[3], argv[4], argv[5])
        print(json.dumps(r, ensure_ascii=False))
        return 0
    if cmd == "site-path":
        print(api.get_site_path(argv[2]))
        return 0
    if cmd == "remove-site":
        r = api.remove_site(argv[2])
        print(json.dumps(r, ensure_ascii=False))
        return 0
    if cmd == "remove-python-project":
        # remove-python-project <name> [true|false]  — false 保护项目自带 venv
        r = api.remove_python_project(argv[2],
                                      len(argv) > 3 and argv[3] == "true")
        print(json.dumps(r, ensure_ascii=False))
        return 0
    print(f"未知命令: {cmd}")
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
