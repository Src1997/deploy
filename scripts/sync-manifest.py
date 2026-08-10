#!/usr/bin/env python3
"""sync-manifest.py — 从 project-configs/*.toml 生成 projects.json（manifest）

设计：
  project-configs/*.toml 是唯一 SSOT（人类编辑源）。
  本脚本把它编译成与旧 deploy.sh / generate-nginx.py / detect-status.sh
  兼容的 projects.json，同时包含完整打包信息供 pack.ps1 使用。

  合并逻辑：
    _shared.toml  →  全局默认值 + 后端公共排除列表 + 服务器定义 + nginx_extras
    <project>/project.toml  →  项目级配置（可覆盖共享值）

用法：
  python3 scripts/sync-manifest.py            # 生成 projects.json
  python3 scripts/sync-manifest.py --check    # 仅校验，不写文件
  python3 scripts/sync-manifest.py --print    # 打印生成的 JSON

依赖：仅标准库 tomllib（Python 3.11+ 自带），无第三方依赖。
"""

import argparse
import json
import sys
import tomllib
from pathlib import Path


# ── TOML loading ────────────────────────────────────────────────────

def load_toml(path: Path) -> dict:
    """Load a TOML file and return a dict."""
    with path.open("rb") as f:
        return tomllib.load(f)


def resolve_dirs(script_dir: Path) -> tuple[Path, Path]:
    """Return (deploy_dir, configs_dir)."""
    deploy_dir = script_dir.parent
    return deploy_dir, deploy_dir / "project-configs"


# ── snake_case → camelCase ─────────────────────────────────────────

def snake_to_camel_key(key: str) -> str:
    """Convert a single snake_case key to camelCase."""
    mapping = {
        "proxy_target": "proxyTarget",
        "proxy_path": "proxyPath",
        "spa_fallback": "spaFallback",
        "root_project": "rootProject",
        "special_headers": "specialHeaders",
        "nginx_mode": "nginxMode",
        "nginx_reload": "nginxReload",
        "frontend_url": "frontendUrl",
        "www_domain": "wwwDomain",
        "display_name": "displayName",
        "source_path": "sourcePath",
        "public_url": "publicUrl",
        "deploy_path": "deployPath",
        "health_url": "healthUrl",
        "deploy_hook": "deployHook",
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
        # Java-specific
        "build_tool": "buildTool",
        "jar_dir": "jarDir",
        "jar_pattern": "jarPattern",
    }
    return mapping.get(key, key)


def snake_to_camel_dict(d: dict) -> dict:
    """Recursively convert dict keys from snake_case to camelCase."""
    if not isinstance(d, dict):
        return d
    return {snake_to_camel_key(k): snake_to_camel_dict(v) for k, v in d.items()}


def snake_to_camel_list(lst: list) -> list:
    """Recursively convert list elements."""
    return [snake_to_camel_dict(item) if isinstance(item, dict) else item for item in lst]


# ── Component → manifest entry ─────────────────────────────────────

def build_nginx(component: dict) -> dict | None:
    """Build the nginx section for a manifest entry."""
    nginx_cfg = component.get("nginx", {})
    if nginx_cfg.get("root_project"):
        return {"rootProject": True}
    locs = nginx_cfg.get("locations", [])
    if not locs:
        return None
    return {"locations": [snake_to_camel_dict(loc) for loc in locs]}


def component_to_entry(
    component: dict,
    project_id: str,
    project_display_name: str,
    key_files: list[str],
    shared_defaults: dict,
) -> dict:
    """Convert a recipe component into a manifest project entry.

    shared_defaults contains python_defaults, go_defaults, nodejs_defaults, etc.
    """
    kind = component.get("kind", "frontend")
    comp_id = component["id"]

    entry = {
        "id": comp_id,
        "project": project_id,
        "enabled": True,
        "kind": kind,
        "displayName": component.get("display_name", comp_id),
        "sourcePath": component.get("source_path", ""),
        "publicUrl": component.get("public_url", ""),
        "deployPath": component.get("deploy_path", ""),
        "services": component.get("services", []),
        "healthUrl": component.get("health_url", ""),
        "nginxReload": component.get("nginx_reload", False),
        "deployHook": component.get("deploy_hook", ""),
    }

    nginx = build_nginx(component)
    if nginx is not None:
        entry["nginx"] = nginx

    if kind == "frontend":
        build_cfg = component.get("build", {})
        build = {
            "packageManager": build_cfg.get("package_manager", "pnpm"),
            "script": build_cfg.get("build_script", "build"),
            "distDir": build_cfg.get("dist_dir", "dist"),
            "artifact": build_cfg.get("artifact", f"{comp_id}-dist.tar.gz"),
        }
        if build_cfg.get("env_file"):
            build["envFile"] = build_cfg["env_file"]
        entry["build"] = build

    elif kind == "java":
        build_cfg = component.get("build", {})
        build = {
            "buildTool": build_cfg.get("build_tool", "maven"),
            "jarDir": build_cfg.get("jar_dir", "target"),
            "artifactPattern": build_cfg.get("artifact_pattern", f"{comp_id}-*.tar.gz"),
            "includeFiles": list(build_cfg.get("include_files", [])),
            "includeEnv": list(build_cfg.get("include_env", [])),
            "keyFiles": list(key_files),
        }
        if build_cfg.get("jar_pattern"):
            build["jarPattern"] = build_cfg["jar_pattern"]
        entry["build"] = build

    elif kind == "go":
        build_cfg = component.get("build", {})
        build = {
            "buildCommand": build_cfg.get("build_command", "go build"),
            "artifactPattern": build_cfg.get("artifact_pattern", f"{comp_id}-*.tar.gz"),
            "includeFiles": list(build_cfg.get("include_files", [])),
            "includeEnv": list(build_cfg.get("include_env", [])),
            "keyFiles": list(key_files),
        }
        if build_cfg.get("binary_name"):
            build["binaryName"] = build_cfg["binary_name"]
        if build_cfg.get("binary_dir"):
            build["binaryDir"] = build_cfg["binary_dir"]
        entry["build"] = build

    elif kind == "nodejs":
        pack = component.get("pack", {})
        build_cfg = component.get("build", {})
        nodejs_defaults = shared_defaults.get("nodejs_defaults", {})

        mode = pack.get("package_mode", "app-package")
        artifact_pattern = pack.get("artifact_pattern", f"{comp_id}-*.tar.gz")

        # Merge shared excludes with project-specific extras
        exclude_dirs = list(nodejs_defaults.get("exclude_dirs", []))
        exclude_dirs.extend(pack.get("extra_exclude_dirs", []))
        exclude_files = list(nodejs_defaults.get("exclude_files", []))
        exclude_files.extend(pack.get("extra_exclude_files", []))

        include_files = list(key_files) + list(pack.get("include_files", []))
        include_env = list(pack.get("include_env", []))

        build = {
            "mode": mode,
            "packageManager": build_cfg.get("package_manager", "npm"),
            "buildScript": build_cfg.get("build_script", ""),
            "artifactPattern": artifact_pattern,
            "excludeDirs": exclude_dirs,
            "excludeFiles": exclude_files,
            "keyFiles": list(key_files),
            "includeFiles": list(pack.get("include_files", [])),
            "includeEnv": include_env,
        }
        entry["build"] = build

    else:  # python
        pack = component.get("pack", {})
        python_defaults = shared_defaults.get("python_defaults", {})
        mode = pack.get("package_mode", "app-package")
        artifact_pattern = pack.get("artifact_pattern", f"{comp_id}-*.tar.gz")

        # Merge shared excludes with project-specific extras
        exclude_dirs = list(python_defaults.get("exclude_dirs", []))
        exclude_dirs.extend(pack.get("extra_exclude_dirs", []))
        exclude_files = list(python_defaults.get("exclude_files", []))
        exclude_files.extend(pack.get("extra_exclude_files", []))

        # include_files = key_files (project-level) + component's own
        include_files = list(key_files) + list(pack.get("include_files", []))

        # extra sources (e.g. mcp_server)
        extra_sources = []
        for es in pack.get("extra_source", []):
            extra_sources.append({"path": es["path"], "dest": es["dest"]})

        # include_env: explicit .env allow-list (security-critical)
        include_env = list(pack.get("include_env", []))

        build = {
            "mode": mode,
            "artifactPattern": artifact_pattern,
            "excludeDirs": exclude_dirs,
            "excludeFiles": exclude_files,
            "keyFiles": list(key_files),
            "includeFiles": list(pack.get("include_files", [])),
            "includeEnv": include_env,
            "extraSources": extra_sources,
        }
        entry["build"] = build

    return entry


# ── Server collection ──────────────────────────────────────────────

def collect_servers(
    shared_servers: dict,
    project_configs: list[dict],
) -> dict:
    """Merge shared server definitions with project-level overrides."""
    servers = {}
    # Start with shared servers
    for name, cfg in shared_servers.items():
        servers[name] = snake_to_camel_dict(cfg)
    # Apply project-level overrides (if any project defines its own servers)
    for r in project_configs:
        for name, cfg in (r.get("servers") or {}).items():
            servers[name] = snake_to_camel_dict(cfg)
    return servers


# ── Manifest generation ────────────────────────────────────────────

def generate(configs_dir: Path) -> dict:
    """Read all TOML configs and produce the manifest dict."""
    shared_path = configs_dir / "_shared.toml"
    shared = load_toml(shared_path) if shared_path.exists() else {}

    defaults = shared.get("defaults", {})
    shared_defaults = {
        "python_defaults": shared.get("python_defaults", {}),
        "java_defaults": shared.get("java_defaults", {}),
        "go_defaults": shared.get("go_defaults", {}),
        "nodejs_defaults": shared.get("nodejs_defaults", {}),
    }
    shared_servers = shared.get("servers", {})
    nginx_extras = shared.get("nginx_extras", [])

    # Load all project configs
    project_configs = []
    for toml_path in sorted(configs_dir.glob("*/project.toml")):
        project_configs.append(load_toml(toml_path))

    # Build project entries
    projects = []
    for r in project_configs:
        proj = r.get("project", {})
        project_id = proj.get("id", "")
        project_display_name = proj.get("display_name", project_id)
        key_files = proj.get("key_files", [])

        for comp in r.get("components", []):
            projects.append(component_to_entry(
                comp, project_id, project_display_name,
                key_files, shared_defaults,
            ))

    manifest = {
        "version": defaults.get("version", 1),
        "workspaceRoot": defaults.get("workspace_root", ""),
        "projectBase": defaults.get("project_base", "/www/wwwroot/project"),
        "projects": projects,
        "servers": collect_servers(shared_servers, project_configs),
        "nginxExtras": [snake_to_camel_dict(e) for e in nginx_extras],
    }
    return manifest


# ── Validation ─────────────────────────────────────────────────────

def validate(manifest: dict) -> list[str]:
    """Validate the manifest and return a list of error messages (empty = valid)."""
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
        if kind not in ("frontend", "python", "java", "go", "nodejs"):
            errors.append(f"[{pid}] Invalid kind: {kind}")

        if not p.get("sourcePath"):
            errors.append(f"[{pid}] Missing sourcePath")

        if not p.get("deployPath"):
            errors.append(f"[{pid}] Missing deployPath")

        if kind == "frontend":
            build = p.get("build", {})
            if not build.get("artifact"):
                errors.append(f"[{pid}] Frontend missing build.artifact")
        elif kind == "java":
            build = p.get("build", {})
            if not build.get("artifactPattern"):
                errors.append(f"[{pid}] Java missing build.artifactPattern")
        elif kind == "go":
            build = p.get("build", {})
            if not build.get("artifactPattern"):
                errors.append(f"[{pid}] Go missing build.artifactPattern")
        elif kind == "nodejs":
            build = p.get("build", {})
            if not build.get("artifactPattern"):
                errors.append(f"[{pid}] Nodejs missing build.artifactPattern")
        else:  # python
            build = p.get("build", {})
            if not build.get("artifactPattern"):
                errors.append(f"[{pid}] Python missing build.artifactPattern")
            if not build.get("mode"):
                errors.append(f"[{pid}] Python missing build.mode")

    return errors


# ── Main ───────────────────────────────────────────────────────────

def main():
    script_dir = Path(__file__).resolve().parent
    deploy_dir, configs_dir = resolve_dirs(script_dir)

    parser = argparse.ArgumentParser(
        description="从 project-configs/*.toml 生成 projects.json"
    )
    parser.add_argument("--check", action="store_true", help="仅校验不写文件")
    parser.add_argument("--print", action="store_true", help="打印生成的 JSON")
    args = parser.parse_args()

    if not configs_dir.exists():
        print(f"[ERR] 配置目录不存在: {configs_dir}", file=sys.stderr)
        sys.exit(1)

    project_tomls = list(configs_dir.glob("*/project.toml"))
    if not project_tomls:
        print(f"[ERR] 未找到任何 project-configs/*/project.toml", file=sys.stderr)
        sys.exit(1)

    manifest = generate(configs_dir)

    # Validate
    errors = validate(manifest)
    if errors:
        for e in errors:
            print(f"[ERR] {e}", file=sys.stderr)
        sys.exit(1)

    if args.print:
        print(json.dumps(manifest, ensure_ascii=False, indent=2))
        return

    project_count = len(manifest["projects"])
    server_count = len(manifest["servers"])
    extras_count = len(manifest["nginxExtras"])

    if args.check:
        print(f"[OK] 配置解析成功：{project_count} 个项目组件，"
              f"{server_count} 个服务器，"
              f"{extras_count} 条 nginxExtras")
        # Show project grouping
        projects_by_group: dict[str, list[str]] = {}
        for p in manifest["projects"]:
            group = p.get("project", "unknown")
            projects_by_group.setdefault(group, []).append(p["id"])
        for group, ids in sorted(projects_by_group.items()):
            print(f"      {group}: {', '.join(ids)}")
        return

    out_path = deploy_dir / "projects.json"
    with out_path.open("w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"[OK] 已生成 {out_path}")
    print(f"     {project_count} 个项目组件，{server_count} 个服务器，{extras_count} 条 nginxExtras")
    # Show project grouping
    projects_by_group: dict[str, list[str]] = {}
    for p in manifest["projects"]:
        group = p.get("project", "unknown")
        projects_by_group.setdefault(group, []).append(p["id"])
    for group, ids in sorted(projects_by_group.items()):
        print(f"     {group}: {', '.join(ids)}")


if __name__ == "__main__":
    main()
