#!/usr/bin/env python3
"""将 projects.yaml 同步为 projects.json（机器读取源）。

用法: python3 scripts/sync-projects.py

依赖: PyYAML（WSL: apt install python3-yaml 或 pip install pyyaml）
"""
import json
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEPLOY_DIR = os.path.dirname(SCRIPT_DIR)
YAML_PATH = os.path.join(DEPLOY_DIR, 'projects.yaml')
JSON_PATH = os.path.join(DEPLOY_DIR, 'projects.json')

try:
    import yaml
except ImportError:
    print('Error: PyYAML not installed. Install with:', file=sys.stderr)
    print('  WSL: sudo apt install python3-yaml', file=sys.stderr)
    print('  Or:  pip install pyyaml', file=sys.stderr)
    sys.exit(1)


def main():
    if not os.path.exists(YAML_PATH):
        print(f'Error: {YAML_PATH} not found', file=sys.stderr)
        sys.exit(1)

    with open(YAML_PATH, encoding='utf-8') as f:
        data = yaml.safe_load(f)

    # Ensure required top-level fields
    data.setdefault('version', 1)
    data.setdefault('workspaceRoot', '')
    data.setdefault('projectBase', '/www/wwwroot/project')
    data.setdefault('projects', [])
    data.setdefault('nginxExtras', [])

    # Validate each project has required fields
    for p in data['projects']:
        for required in ('id', 'kind', 'sourcePath', 'deployPath'):
            if required not in p:
                print(f'Error: project "{p.get("id", "?")}" missing field: {required}', file=sys.stderr)
                sys.exit(1)
        p.setdefault('enabled', True)
        p.setdefault('displayName', p['id'])
        p.setdefault('publicUrl', '')
        p.setdefault('services', [])
        p.setdefault('healthUrl', '')
        p.setdefault('nginxReload', False)
        p.setdefault('deployHook', '')
        p.setdefault('nginx', None)

    with open(JSON_PATH, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')

    ids = [p['id'] for p in data.get('projects', [])]
    extras_count = len(data.get('nginxExtras', []))
    print(f'Synced {len(ids)} projects: {", ".join(ids)}')
    print(f'Nginx extras: {extras_count}')
    print(f'Output: {JSON_PATH}')


if __name__ == '__main__':
    main()
