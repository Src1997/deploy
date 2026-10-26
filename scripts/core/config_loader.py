#!/usr/bin/env python3
"""config_loader.py — Direct TOML config reader (v2: intent-based).

Reads project-configs/*.toml on the fly and provides merged manifest data.
No intermediate file generation — all consumers call this module directly.

Usage:
    python3 config_loader.py --format json       # Full manifest as JSON (for pack.ps1)
    python3 config_loader.py --format bash-eval  # Bash eval-able assignments (for load-projects.sh)
    python3 config_loader.py --format check      # Validate only, print summary
    python3 config_loader.py --format nginx      # Routing-relevant data as JSON (native/docker)

    # Import from Python:
    from config_loader import load_manifest, validate
    manifest = load_manifest(configs_dir)

v2 配置哲学（2026-10-22 重写）：
    TOML 只声明「意图」（routes / process / companions），不含任何通道字眼；
    通道（baota/native/docker）各自把意图翻译成自己的实现：
      routes     → baota: 面板站点反代     native/docker: generate-nginx
      process    → baota: 宝塔 Python 项目  docker: 容器          native: systemd 单元
      companions → baota: supervisor 程序   native: systemd 单元  docker: 预留

Dependencies: Python 3.11+ (tomllib in stdlib).
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
import tomllib
from pathlib import Path


# ── TOML loading ────────────────────────────────────────────────────

def load_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def find_configs_dir(start: Path) -> Path:
    """Locate project-configs/ by walking up from *start*.

    Works in both source tree (scripts/core/) and dist/ (dist/core/).
    """
    for d in [start, start.parent, start.parent.parent, start.parent.parent.parent]:
        candidate = d / "project-configs"
        if candidate.is_dir():
            return candidate
    return start.parent.parent / "project-configs"


# ── snake_case → camelCase ─────────────────────────────────────────

_KEY_MAP = {
    "proxy_target": "proxyTarget",
    "proxy_path": "proxyPath",
    "spa_fallback": "spaFallback",
    "root_project": "rootProject",
    "special_headers": "specialHeaders",
    "nginx_mode": "nginxMode",
    "frontend_url": "frontendUrl",
    "www_domain": "wwwDomain",
    "display_name": "displayName",
    "source_path": "sourcePath",
    "public_url": "publicUrl",
    "deploy_path": "deployPath",
    "health_url": "healthUrl",
    "deploy_hook": "deployHook",
    "venv_shared": "venvShared",
    "package_manager": "packageManager",
    "build_script": "buildScript",
    "dist_dir": "distDir",
    "env_file": "envFile",
    "package_mode": "packageMode",
    "artifact_pattern": "artifactPattern",
    "include_files": "includeFiles",
    "include_env": "includeEnv",
    "extra_source": "extraSources",
    "key_files": "keyFiles",
    "exclude_dirs": "excludeDirs",
    "exclude_files": "excludeFiles",
    "extra_exclude_dirs": "extraExcludeDirs",
    "extra_exclude_files": "extraExcludeFiles",
    "backup_retention": "backupRetention",
    "health_timeout": "healthTimeout",
    "build_tool": "buildTool",
    "jar_dir": "jarDir",
    "jar_pattern": "jarPattern",
    "build_command": "buildCommand",
    "binary_name": "binaryName",
    "binary_dir": "binaryDir",
    "post_deploy_check_path": "postDeployCheckPath",
    "web_path": "webPath",
}


def _camel(key: str) -> str:
    return _KEY_MAP.get(key, key)


def _camel_dict(d: dict) -> dict:
    return {_camel(k): _camel_dict(v) if isinstance(v, dict) else v for k, v in d.items()}


# ── routes → 各通道消费格式 ─────────────────────────────────────────

_ROUTE_TYPES = ("root", "static", "proxy", "websocket")


def _normalize_companions(component: dict, comp_id: str) -> list[dict]:
    """归一化伴随服务声明。

    两种写法（可混用）：
      companions = ["quantdinger-mcp"]                          # 纯名字（宝塔/原生语义）
      companions = [{ name = "quantdinger-mcp",                 # 对象（docker 容器化需要）
                      cmd  = "python -m quantdinger_mcp.server",
                      port  = 7800 }]
    统一输出：[{name, cmd(""), port("")}]；宝塔/原生通道只读 name。
    """
    out = []
    for c in component.get("companions", []) or process_companions_fallback(component):
        if isinstance(c, str):
            out.append({"name": c, "cmd": "", "port": ""})
        elif isinstance(c, dict) and c.get("name"):
            out.append({
                "name": c["name"],
                "cmd": str(c.get("cmd", "")),
                "port": str(c.get("port", "")),
            })
        else:
            raise ValueError(f"[{comp_id}] 非法 companion 声明: {c!r}（需名字字符串或 {name,cmd,port} 表）")
    return out


def process_companions_fallback(component: dict) -> list:
    """★TOML 陷阱兜底：companions 误写在 [components.process] 段内会被吞进 process。"""
    proc = component.get("process", {}) or {}
    return proc.get("companions", []) or []


def _normalize_routes(component: dict, comp_id: str) -> list[dict]:
    """归一化组件路由声明为统一 route 列表。

    route: {path, type, target?, spa?}
      type=root     根站点（native: root location；baota: 主站点）
      type=static   静态资源（spa=SPA 回退）
      type=proxy    HTTP 反代（target=完整上游 URL，含上游路径）
      type=websocket WS 反代（同 proxy + WS 头）
    """
    routes = []
    for r in component.get("routes", []):
        rtype = r.get("type", "static")
        if rtype not in _ROUTE_TYPES:
            raise ValueError(f"[{comp_id}] 非法 route type: {rtype}（可选: {'/'.join(_ROUTE_TYPES)}）")
        route = {"path": r.get("path", ""), "type": rtype}
        if rtype in ("proxy", "websocket"):
            if not r.get("target"):
                raise ValueError(f"[{comp_id}] route {r.get('path')} 缺少 target")
            route["target"] = r["target"]
        if rtype in ("root", "static"):
            route["spa"] = bool(r.get("spa", False))
        routes.append(route)
    return routes


def _split_target(target: str) -> tuple[str, str]:
    """http://127.0.0.1:5000/api/ → ('http://127.0.0.1:5000', '/api/')"""
    m = re.match(r"^(https?://[^/]+)(/.*)?$", target)
    if not m:
        return target, ""
    return m.group(1), m.group(2) or ""


def _companion_services_yaml(companions: list[dict]) -> str:
    """docker compose services 段：有 cmd 意图的 companion → 独立容器（host 网络）。
    纯名字形式（无 cmd）的 companion 无容器化意图 → 跳过（宝塔/原生通道语义）。"""
    blocks = []
    for c in companions:
        if not c.get("cmd"):
            continue
        cmd = c["cmd"].replace(".venv/bin/", "")
        lines = [
            f"  {c['name']}:",
            "    build: .",
            f"    container_name: {c['name']}",
            "    restart: unless-stopped",
            "    network_mode: host",
            f'    command: ["bash", "-c", "{cmd}"]',
            "    env_file:",
            "      - path: .env",
            "        required: false",
        ]
        blocks.append("\n".join(lines))
    return "\n".join(blocks)


def _routes_to_nginx(routes: list[dict]) -> dict | None:
    """routes → generate-nginx.py 消费的 nginx JSON（native/docker 路由后端）。"""
    if not routes:
        return None
    if any(r["type"] == "root" for r in routes):
        return {"rootProject": True}
    locations = []
    for r in routes:
        if r["type"] in ("proxy", "websocket"):
            t_host, t_path = _split_target(r["target"])
            locations.append({
                "path": r["path"],
                "type": r["type"],
                "proxyTarget": t_host,
                "proxyPath": t_path or r["path"],
            })
        else:  # static
            loc = {"path": r["path"], "type": "static"}
            if r.get("spa"):
                loc["spaFallback"] = True
            locations.append(loc)
    return {"locations": locations}


# ── Component → manifest entry ─────────────────────────────────────

def _component_to_entry(
    component: dict,
    project_id: str,
    project_display_name: str,
    key_files: list[str],
    shared_defaults: dict,
    project_enabled: bool = True,
) -> dict:
    kind = component.get("kind", "frontend")
    comp_id = component["id"]

    process = component.get("process", {}) or {}
    routes = _normalize_routes(component, comp_id)

    entry = {
        "id": comp_id,
        "project": project_id,
        # 项目级 enabled（如 fullstack-demo 模板默认不上线）优先，其次组件级
        "enabled": bool(component.get("enabled", project_enabled)),
        "kind": kind,
        "displayName": component.get("display_name", comp_id),
        "sourcePath": component.get("source_path", ""),
        "publicUrl": component.get("public_url", ""),
        "deployPath": component.get("deploy_path", ""),
        "healthUrl": component.get("health_url", ""),
        "venvShared": component.get("venv_shared", False),
        "postDeployCheckPath": component.get("post_deploy_check_path", ""),
        "webPath": component.get("web_path", ""),
        "deployHook": component.get("deploy_hook", ""),
        # 前端站点名（宝塔通道消费；面板要求域名格式，默认 <id>.local）
        "siteName": component.get("site_name", f"{comp_id}.local"),
        # ── 意图模型（v2）：通道无关 ──
        "routes": routes,
        "process": {
            "port": process.get("port", ""),
            "cmd": process.get("cmd", ""),
            "migrate": process.get("migrate", ""),
            # java 专用：jar 相对 deployPath / JDK bin 绝对路径
            "jar": process.get("jar", ""),
            "jdk": process.get("jdk", ""),
        },
        # companions 归一化（str/对象混用 → {name,cmd,port}；含 process 段误写兜底）
        "companions": _normalize_companions(component, comp_id),
        # 反代清单（"目录|目标URL"）——由聚合 pass 填充（见 load_manifest）
        "proxySpecs": [],
    }

    if kind == "frontend":
        b = component.get("build", {})
        build = {
            "packageManager": b.get("package_manager", "pnpm"),
            "script": b.get("build_script", "build"),
            "distDir": b.get("dist_dir", "dist"),
            "artifact": b.get("artifact", f"{comp_id}-dist.tar.gz"),
        }
        if b.get("env_file"):
            build["envFile"] = b["env_file"]
        entry["build"] = build

    elif kind == "java":
        b = component.get("build", {})
        build = {
            "buildTool": b.get("build_tool", "maven"),
            "jarDir": b.get("jar_dir", "target"),
            "artifactPattern": b.get("artifact_pattern", f"{comp_id}-*.tar.gz"),
            "includeFiles": list(b.get("include_files", [])),
            "includeEnv": list(b.get("include_env", [])),
            "keyFiles": list(key_files),
        }
        if b.get("jar_pattern"):
            build["jarPattern"] = b["jar_pattern"]
        entry["build"] = build

    else:  # python
        pack = component.get("pack", {})
        python_defaults = shared_defaults.get("python_defaults", {})
        mode = pack.get("package_mode", "app-package")
        artifact_pattern = pack.get("artifact_pattern", f"{comp_id}-*.tar.gz")
        exclude_dirs = list(python_defaults.get("exclude_dirs", []))
        exclude_dirs.extend(pack.get("extra_exclude_dirs", []))
        exclude_files = list(python_defaults.get("exclude_files", []))
        exclude_files.extend(pack.get("extra_exclude_files", []))
        include_files = list(key_files) + list(pack.get("include_files", []))
        extra_sources = [{"path": es["path"], "dest": es["dest"]} for es in pack.get("extra_source", [])]
        include_env = list(pack.get("include_env", []))
        build = {
            "mode": mode,
            "artifactPattern": artifact_pattern,
            "excludeDirs": exclude_dirs,
            "excludeFiles": exclude_files,
            "keyFiles": list(key_files),
            "includeFiles": include_files,
            "includeEnv": include_env,
            "extraSources": extra_sources,
        }
        entry["build"] = build

    return entry


# ── Server collection ──────────────────────────────────────────────

_ENV_SERVER_KEYS = ("DOMAIN", "WWW_DOMAIN", "NGINX_MODE", "SERVER_IP")


def _read_env_servers(deploy_root: Path) -> dict:
    """Scan deploy.env.server-* / deploy.env.vm for server definitions.

    ★ env 文件是域名/IP/nginx 模式的唯一来源（_shared.toml [servers] 不再
      重复维护——2026-10-19 之前 server-c 曾漏登记且无人发现，双源漂移）。
    无 DOMAIN 的 env（如 vm）不进入 servers 表。
    """
    servers: dict = {}
    if not deploy_root or not deploy_root.is_dir():
        return servers
    env_files = sorted(deploy_root.glob("deploy.env.server-*"))
    vm_env = deploy_root / "deploy.env.vm"
    if vm_env.exists():
        env_files.append(vm_env)
    for env_path in env_files:
        name = env_path.name[len("deploy.env."):]
        if not re.fullmatch(r"server-[a-z0-9]+|vm", name):
            continue  # 跳过 .bak_* 等备份/杂项文件
        values: dict = {}
        for line in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key in _ENV_SERVER_KEYS:
                values[key] = val
        domain = values.get("DOMAIN", "")
        if not domain:
            continue
        entry = {
            "nginxMode": values.get("NGINX_MODE", ""),
            "domain": domain,
            "wwwDomain": values.get("WWW_DOMAIN", ""),
            "serverIp": values.get("SERVER_IP", ""),
        }
        if entry["wwwDomain"]:
            entry["frontendUrl"] = f"https://{entry['wwwDomain']}"
        servers[name] = entry
    return servers


def _collect_servers(shared_servers: dict, project_configs: list[dict],
                     env_servers: dict) -> dict:
    """env 文件为基础事实，TOML [servers] 仅作逐键覆盖（如异构 frontend_url）。"""
    servers = {name: dict(cfg) for name, cfg in env_servers.items()}
    for source in [shared_servers] + [r.get("servers") or {} for r in project_configs]:
        for name, cfg in source.items():
            merged = dict(servers.get(name, {}))
            merged.update(_camel_dict(cfg))
            servers[name] = merged
    return servers


# ── Manifest generation ────────────────────────────────────────────

def load_manifest(configs_dir: Path) -> dict:
    """Read all TOML configs and return the merged manifest dict."""
    shared_path = configs_dir / "_shared.toml"
    shared = load_toml(shared_path) if shared_path.exists() else {}

    defaults = shared.get("defaults", {})
    shared_defaults = {
        "python_defaults": shared.get("python_defaults", {}),
        "java_defaults": shared.get("java_defaults", {}),
        "nodejs_defaults": shared.get("nodejs_defaults", {}),
    }
    shared_servers = shared.get("servers", {})
    nginx_extras = shared.get("nginx_extras", [])

    project_configs = []
    for toml_path in sorted(configs_dir.glob("*/project.toml")):
        project_configs.append(load_toml(toml_path))

    projects = []
    for r in project_configs:
        proj = r.get("project", {})
        project_id = proj.get("id", "")
        project_display_name = proj.get("display_name", project_id)
        key_files = proj.get("key_files", [])
        # 项目级 enabled：整项目下线开关（模板项目默认不进路由/部署清单）
        project_enabled = bool(proj.get("enabled", True))
        for comp in r.get("components", []):
            projects.append(_component_to_entry(
                comp, project_id, project_display_name,
                key_files, shared_defaults, project_enabled,
            ))

    # ── 反代聚合 pass（v2 语义修正）──
    # proxy/websocket 路由声明在上游（backend）组件，但反代实体属于前端站点。
    # 规则：项目内全部 proxy 路由 → 挂到项目主前端站点
    #      （有 type=root 路由的前端优先，否则第一个前端）。
    by_project: dict[str, list[dict]] = {}
    for p in projects:
        by_project.setdefault(p["project"], []).append(p)
    for projs in by_project.values():
        specs = [
            f"{r['path']}|{r['target']}"
            for comp in projs for r in comp.get("routes", [])
            if r["type"] in ("proxy", "websocket")
        ]
        if not specs:
            continue
        frontends = [c for c in projs if c["kind"] == "frontend"]
        if not frontends:
            continue
        main_fe = next((c for c in frontends
                        if any(r["type"] == "root" for r in c.get("routes", []))),
                       frontends[0])
        main_fe["proxySpecs"] = specs

    return {
        "version": defaults.get("version", 1),
        "workspaceRoot": defaults.get("workspace_root", ""),
        "projectBase": defaults.get("project_base", "/www/wwwroot/project"),
        "projects": projects,
        "servers": _collect_servers(
            shared_servers, project_configs,
            _read_env_servers(configs_dir.parent),
        ),
        "nginxExtras": [_camel_dict(e) for e in nginx_extras],
    }


# ── Validation ─────────────────────────────────────────────────────

def validate(manifest: dict) -> list[str]:
    errors = []
    seen_ids = set()
    for p in manifest["projects"]:
        pid = p.get("id", "")
        if not pid:
            errors.append("Project entry missing 'id'")
            continue
        if pid in seen_ids:
            errors.append(f"Duplicate project id: {pid}")
        seen_ids.add(pid)
        kind = p.get("kind", "")
        if kind not in ("frontend", "python", "java"):
            errors.append(f"[{pid}] Invalid kind: {kind}")
        if not p.get("sourcePath"):
            errors.append(f"[{pid}] Missing sourcePath")
        if not p.get("deployPath"):
            errors.append(f"[{pid}] Missing deployPath")
        build = p.get("build", {})
        if kind == "frontend":
            if not build.get("artifact"):
                errors.append(f"[{pid}] Frontend missing build.artifact")
        else:
            if not build.get("artifactPattern"):
                errors.append(f"[{pid}] {kind} missing build.artifactPattern")
            if kind == "python" and not build.get("mode"):
                errors.append(f"[{pid}] Python missing build.mode")
        # process 校验：cmd 与 port 必须成对出现
        proc = p.get("process", {})
        if bool(proc.get("cmd")) != bool(proc.get("port")):
            errors.append(f"[{pid}] process.port 与 process.cmd 必须同时配置（或都不配）")
        if process_companions_fallback({"process": proc}) and not p.get("companions"):
            errors.append(f"[{pid}] companions 误写在 [components.process] 段内，请移到组件根级（process 段之前）")
    return errors


# ── Bash eval output ───────────────────────────────────────────────

def to_bash_eval(manifest: dict, project_base: str = "") -> str:
    """Generate bash eval-able assignments for load-projects.sh."""
    pb = project_base or manifest.get("projectBase", "/www/wwwroot/project")
    ws = manifest.get("workspaceRoot", "")
    lines = []

    lines.append("declare -gA DEPLOY_PATH ARTIFACT_NAME SERVICES HEALTH_URL "
                 "PROJECT_KIND PROJECT_DISPLAY_NAME "
                 "PUBLIC_URL PROJECT_ROOT VENV_SHARED PROJECT_ID "
                 "POST_DEPLOY_CHECK_PATH WEB_PATH DEPLOY_HOOK "
                 "PROC_PORT PROC_CMD PROC_MIGRATE PROC_JAR PROC_JDK COMPANIONS ROUTES_JSON "
                 "SITE_NAME PROXY_SPECS COMPANION_JSON COMPANION_SERVICES")

    enabled = [p for p in manifest["projects"] if p.get("enabled", True)]
    ids = " ".join(p["id"] for p in enabled)
    lines.append(f"PROJECT_IDS={shlex.quote(ids)}")
    lines.append(f"WORKSPACE_ROOT={shlex.quote(ws)}")
    lines.append(f"PROJECT_BASE={shlex.quote(pb)}")

    for p in enabled:
        pid = p["id"]
        dp = p.get("deployPath", "")
        lines.append(f"DEPLOY_PATH[{pid}]={shlex.quote(pb + '/' + dp)}")

        art = p.get("build", {}).get("artifact", "")
        pat = p.get("build", {}).get("artifactPattern", "")
        lines.append(f"ARTIFACT_NAME[{pid}]={shlex.quote(art or pat)}")

        # SERVICES（兼容派生数组）= 主组件（有 process 时）+ companions
        proc = p.get("process", {})
        svc_list = ([pid] if proc.get("cmd") else []) + [c["name"] for c in p.get("companions", [])]
        lines.append(f"SERVICES[{pid}]={shlex.quote(' '.join(svc_list))}")

        lines.append(f"HEALTH_URL[{pid}]={shlex.quote(p.get('healthUrl', ''))}")
        lines.append(f"PROJECT_KIND[{pid}]={shlex.quote(p.get('kind', ''))}")
        lines.append(f"PROJECT_DISPLAY_NAME[{pid}]={shlex.quote(p.get('displayName', ''))}")
        lines.append(f"PUBLIC_URL[{pid}]={shlex.quote(p.get('publicUrl', ''))}")
        routes = p.get("routes", [])
        lines.append(f"PROJECT_ROOT[{pid}]={'true' if any(r['type'] == 'root' for r in routes) else 'false'}")
        lines.append(f"VENV_SHARED[{pid}]={'true' if p.get('venvShared') else 'false'}")
        lines.append(f"PROJECT_ID[{pid}]={shlex.quote(p.get('project', ''))}")
        lines.append(f"POST_DEPLOY_CHECK_PATH[{pid}]={shlex.quote(p.get('postDeployCheckPath', ''))}")
        lines.append(f"WEB_PATH[{pid}]={shlex.quote(p.get('webPath', ''))}")
        lines.append(f"DEPLOY_HOOK[{pid}]={shlex.quote(p.get('deployHook', ''))}")
        lines.append(f"SITE_NAME[{pid}]={shlex.quote(p.get('siteName', ''))}")
        # 反代清单（"目录|目标URL" 空格分隔）——聚合自项目内全部组件的 proxy 路由
        # （owner=主前端站点，见 load_manifest 聚合 pass；宝塔 CreateProxy 直接消费）
        lines.append(f"PROXY_SPECS[{pid}]={shlex.quote(' '.join(p.get('proxySpecs', [])))}")

        # 意图模型（v2）
        proc_port = proc.get("port", "")
        proc_cmd = proc.get("cmd", "")
        proc_migrate = proc.get("migrate", "")
        lines.append(f"PROC_PORT[{pid}]={shlex.quote(str(proc_port))}")
        lines.append(f"PROC_CMD[{pid}]={shlex.quote(proc_cmd)}")
        lines.append(f"PROC_MIGRATE[{pid}]={shlex.quote(proc_migrate)}")
        lines.append(f"PROC_JAR[{pid}]={shlex.quote(proc.get('jar', ''))}")
        lines.append(f"PROC_JDK[{pid}]={shlex.quote(proc.get('jdk', ''))}")
        comps = p.get("companions", [])
        lines.append(f"COMPANIONS[{pid}]={shlex.quote(' '.join(c['name'] for c in comps))}")
        # 对象形式（docker 容器化消费）：[{name,cmd,port},...]
        lines.append(f"COMPANION_JSON[{pid}]={shlex.quote(json.dumps(comps, ensure_ascii=True, separators=(',', ':')))}")
        # 渲染好的 compose services 段（docker 通道直接内插进 docker-compose.yml）
        lines.append(f"COMPANION_SERVICES[{pid}]={shlex.quote(_companion_services_yaml(comps))}")
        lines.append(f"ROUTES_JSON[{pid}]={shlex.quote(json.dumps(routes, ensure_ascii=True, separators=(',', ':')))}")

    return "\n".join(lines)


# ── Nginx-only JSON（native/docker 路由后端消费，形状兼容 v1）────────

def to_nginx_json(manifest: dict) -> str:
    """Output only routing-relevant data (projects with routes + nginxExtras)."""
    nginx_projects = []
    for p in manifest["projects"]:
        if not p.get("enabled", True):
            continue
        nginx = _routes_to_nginx(p.get("routes", []))
        if nginx:
            nginx_projects.append({
                "id": p["id"],
                "deployPath": p.get("deployPath", ""),
                "nginx": nginx,
            })
    return json.dumps({
        "projects": nginx_projects,
        "nginxExtras": manifest.get("nginxExtras", []),
    }, ensure_ascii=True, indent=2)


# ── Main ───────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Read project-configs/*.toml and output manifest data"
    )
    parser.add_argument("--format", choices=["json", "bash-eval", "check", "nginx"],
                        default="json", help="Output format")
    parser.add_argument("--configs-dir", default="", help="Path to project-configs/ directory")
    args = parser.parse_args()

    if args.configs_dir:
        configs_dir = Path(args.configs_dir)
    else:
        configs_dir = find_configs_dir(Path(__file__).resolve().parent)

    if not configs_dir.exists():
        print(f"[ERR] Configs directory not found: {configs_dir}", file=sys.stderr)
        sys.exit(1)

    tomls = list(configs_dir.glob("*/project.toml"))
    if not tomls:
        print(f"[ERR] No project-configs/*/project.toml found", file=sys.stderr)
        sys.exit(1)

    try:
        manifest = load_manifest(configs_dir)
    except ValueError as e:
        print(f"[ERR] {e}", file=sys.stderr)
        sys.exit(1)

    errors = validate(manifest)
    if errors:
        for e in errors:
            print(f"[ERR] {e}", file=sys.stderr)
        sys.exit(1)

    if args.format == "check":
        project_count = len(manifest["projects"])
        server_count = len(manifest["servers"])
        extras_count = len(manifest["nginxExtras"])
        print(f"[OK] Configs parsed: {project_count} components, "
              f"{server_count} servers, {extras_count} nginxExtras")
        groups: dict[str, list[str]] = {}
        for p in manifest["projects"]:
            groups.setdefault(p.get("project", "unknown"), []).append(p["id"])
        for group, ids in sorted(groups.items()):
            print(f"      {group}: {', '.join(ids)}")
        return

    if args.format == "bash-eval":
        print(to_bash_eval(manifest))
        return

    if args.format == "nginx":
        print(to_nginx_json(manifest))
        return

    print(json.dumps(manifest, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    main()
