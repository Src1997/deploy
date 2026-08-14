#!/usr/bin/env python3
"""config_loader.py — Direct TOML config reader (replaces sync-manifest.py + projects.json).

Reads project-configs/*.toml on the fly and provides merged manifest data.
No intermediate file generation — all consumers call this module directly.

Usage:
    python3 config_loader.py --format json       # Full manifest as JSON (for pack.ps1)
    python3 config_loader.py --format bash-eval  # Bash eval-able assignments (for load-projects.sh)
    python3 config_loader.py --format check      # Validate only, print summary
    python3 config_loader.py --format nginx      # Nginx-relevant data as JSON

    # Import from Python:
    from config_loader import load_manifest, validate
    manifest = load_manifest(configs_dir)

Dependencies: Python 3.11+ (tomllib in stdlib).
"""

from __future__ import annotations

import argparse
import json
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

    Works in both source tree (scripts/lib/) and dist/ (dist/lib/).
    """
    for d in [start, start.parent, start.parent.parent, start.parent.parent.parent]:
        candidate = d / "project-configs"
        if candidate.is_dir():
            return candidate
    # Fallback: assume deploy root is 2 levels up from scripts/lib/
    return start.parent.parent / "project-configs"


# ── snake_case → camelCase ─────────────────────────────────────────

_KEY_MAP = {
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
}


def _camel(key: str) -> str:
    return _KEY_MAP.get(key, key)


def _camel_dict(d: dict) -> dict:
    return {_camel(k): _camel_dict(v) if isinstance(v, dict) else v for k, v in d.items()}


# ── Component → manifest entry ─────────────────────────────────────

def _build_nginx(component: dict) -> dict | None:
    nginx_cfg = component.get("nginx", {})
    if nginx_cfg.get("root_project"):
        return {"rootProject": True}
    locs = nginx_cfg.get("locations", [])
    if not locs:
        return None
    return {"locations": [_camel_dict(loc) for loc in locs]}


def _component_to_entry(
    component: dict,
    project_id: str,
    project_display_name: str,
    key_files: list[str],
    shared_defaults: dict,
) -> dict:
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
        "venvShared": component.get("venv_shared", False),
    }

    nginx = _build_nginx(component)
    if nginx is not None:
        entry["nginx"] = nginx

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

    elif kind == "go":
        b = component.get("build", {})
        build = {
            "buildCommand": b.get("build_command", "go build"),
            "artifactPattern": b.get("artifact_pattern", f"{comp_id}-*.tar.gz"),
            "includeFiles": list(b.get("include_files", [])),
            "includeEnv": list(b.get("include_env", [])),
            "keyFiles": list(key_files),
        }
        if b.get("binary_name"):
            build["binaryName"] = b["binary_name"]
        if b.get("binary_dir"):
            build["binaryDir"] = b["binary_dir"]
        entry["build"] = build

    elif kind == "nodejs":
        pack = component.get("pack", {})
        b = component.get("build", {})
        nodejs_defaults = shared_defaults.get("nodejs_defaults", {})
        mode = pack.get("package_mode", "app-package")
        artifact_pattern = pack.get("artifact_pattern", f"{comp_id}-*.tar.gz")
        exclude_dirs = list(nodejs_defaults.get("exclude_dirs", []))
        exclude_dirs.extend(pack.get("extra_exclude_dirs", []))
        exclude_files = list(nodejs_defaults.get("exclude_files", []))
        exclude_files.extend(pack.get("extra_exclude_files", []))
        include_files = list(key_files) + list(pack.get("include_files", []))
        include_env = list(pack.get("include_env", []))
        build = {
            "mode": mode,
            "packageManager": b.get("package_manager", "npm"),
            "buildScript": b.get("build_script", ""),
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
            "includeFiles": list(pack.get("include_files", [])),
            "includeEnv": include_env,
            "extraSources": extra_sources,
        }
        entry["build"] = build

    return entry


# ── Server collection ──────────────────────────────────────────────

def _collect_servers(shared_servers: dict, project_configs: list[dict]) -> dict:
    servers = {}
    for name, cfg in shared_servers.items():
        servers[name] = _camel_dict(cfg)
    for r in project_configs:
        for name, cfg in (r.get("servers") or {}).items():
            servers[name] = _camel_dict(cfg)
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
        "go_defaults": shared.get("go_defaults", {}),
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
        for comp in r.get("components", []):
            projects.append(_component_to_entry(
                comp, project_id, project_display_name,
                key_files, shared_defaults,
            ))

    return {
        "version": defaults.get("version", 1),
        "workspaceRoot": defaults.get("workspace_root", ""),
        "projectBase": defaults.get("project_base", "/www/wwwroot/project"),
        "projects": projects,
        "servers": _collect_servers(shared_servers, project_configs),
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
        if kind not in ("frontend", "python", "java", "go", "nodejs"):
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
    return errors


# ── Bash eval output ───────────────────────────────────────────────

def to_bash_eval(manifest: dict, project_base: str = "") -> str:
    """Generate bash eval-able assignments for load-projects.sh."""
    pb = project_base or manifest.get("projectBase", "/www/wwwroot/project")
    ws = manifest.get("workspaceRoot", "")
    lines = []

    # Declare associative arrays (idempotent with -gA)
    lines.append("declare -gA DEPLOY_PATH ARTIFACT_NAME SERVICES HEALTH_URL "
                 "NGINX_RELOAD DEPLOY_HOOK PROJECT_KIND PROJECT_DISPLAY_NAME "
                 "PUBLIC_URL PROJECT_ROOT VENV_SHARED PROJECT_ID")

    # Collect enabled project IDs
    enabled = [p for p in manifest["projects"] if p.get("enabled", True)]
    ids = " ".join(p["id"] for p in enabled)
    lines.append(f"PROJECT_IDS={shlex.quote(ids)}")
    lines.append(f"WORKSPACE_ROOT={shlex.quote(ws)}")
    lines.append(f"PROJECT_BASE={shlex.quote(pb)}")

    # Per-project associative arrays
    for p in enabled:
        pid = p["id"]
        dp = p.get("deployPath", "")
        lines.append(f"DEPLOY_PATH[{pid}]={shlex.quote(pb + '/' + dp)}")

        art = p.get("build", {}).get("artifact", "")
        pat = p.get("build", {}).get("artifactPattern", "")
        lines.append(f"ARTIFACT_NAME[{pid}]={shlex.quote(art or pat)}")

        svcs = " ".join(p.get("services", []))
        lines.append(f"SERVICES[{pid}]={shlex.quote(svcs)}")
        lines.append(f"HEALTH_URL[{pid}]={shlex.quote(p.get('healthUrl', ''))}")
        lines.append(f"NGINX_RELOAD[{pid}]={'true' if p.get('nginxReload') else 'false'}")
        lines.append(f"DEPLOY_HOOK[{pid}]={shlex.quote(p.get('deployHook', ''))}")
        lines.append(f"PROJECT_KIND[{pid}]={shlex.quote(p.get('kind', ''))}")
        lines.append(f"PROJECT_DISPLAY_NAME[{pid}]={shlex.quote(p.get('displayName', ''))}")
        lines.append(f"PUBLIC_URL[{pid}]={shlex.quote(p.get('publicUrl', ''))}")
        lines.append(f"PROJECT_ROOT[{pid}]={'true' if p.get('nginx', {}).get('rootProject') else 'false'}")
        lines.append(f"VENV_SHARED[{pid}]={'true' if p.get('venvShared') else 'false'}")
        lines.append(f"PROJECT_ID[{pid}]={shlex.quote(p.get('project', ''))}")

    return "\n".join(lines)


# ── Nginx-only JSON ────────────────────────────────────────────────

def to_nginx_json(manifest: dict) -> str:
    """Output only nginx-relevant data (projects with nginx + nginxExtras)."""
    nginx_projects = []
    for p in manifest["projects"]:
        if not p.get("enabled", True):
            continue
        nginx = p.get("nginx")
        if nginx:
            nginx_projects.append({
                "id": p["id"],
                "deployPath": p.get("deployPath", ""),
                "nginx": nginx,
            })
    return json.dumps({
        "projects": nginx_projects,
        "nginxExtras": manifest.get("nginxExtras", []),
    }, ensure_ascii=False, indent=2)


# ── Main ───────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Read project-configs/*.toml and output manifest data"
    )
    parser.add_argument("--format", choices=["json", "bash-eval", "check", "nginx"],
                        default="json", help="Output format")
    parser.add_argument("--configs-dir", default="", help="Path to project-configs/ directory")
    args = parser.parse_args()

    # Locate configs dir
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

    manifest = load_manifest(configs_dir)

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

    # json (default)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
