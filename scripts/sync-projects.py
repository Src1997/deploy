#!/usr/bin/env python3
"""将 projects.yaml 同步为 projects.json（机器读取源）。

用法: python3 scripts/sync-projects.py
"""
import json
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEPLOY_DIR = os.path.dirname(SCRIPT_DIR)
YAML_PATH = os.path.join(DEPLOY_DIR, 'projects.yaml')
JSON_PATH = os.path.join(DEPLOY_DIR, 'projects.json')


def parse_yaml_simple(text):
    """极简 YAML 子集解析器（仅支持本文件用到的结构）。"""
    result = {}
    lines = text.split('\n')
    i = 0

    # 解析顶层 key: value
    while i < len(lines):
        line = lines[i].strip()
        if not line or line.startswith('#'):
            i += 1
            continue
        if line.startswith('version:'):
            result['version'] = int(line.split(':')[1].strip())
        elif line.startswith('workspaceRoot:'):
            val = line.split(':', 1)[1].strip().strip('"').strip("'")
            result['workspaceRoot'] = val
        elif line.startswith('projectBase:'):
            val = line.split(':', 1)[1].strip()
            result['projectBase'] = val
        elif line.startswith('projects:'):
            i += 1
            result['projects'] = parse_projects(lines, i)
            break
        i += 1
    return result


def parse_projects(lines, start):
    """解析 projects 列表。"""
    projects = []
    i = start
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            i += 1
            continue
        if not stripped.startswith('- id:'):
            if not line.startswith(' ') and not line.startswith('\t'):
                break
            i += 1
            continue

        # 新项目开始
        proj = {}
        proj['id'] = stripped.split(':', 1)[1].strip()
        i += 1

        # 解析项目字段
        while i < len(lines):
            line = lines[i]
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                i += 1
                continue
            # 顶层 key 不以空格开头 → 列表结束
            if not line.startswith(' ') and not line.startswith('\t'):
                break
            # 新项目开始
            if stripped.startswith('- id:'):
                break

            if ':' in stripped:
                key, val = stripped.split(':', 1)
                key = key.strip()
                val = val.strip()

                if key == 'enabled':
                    proj[key] = val.lower() == 'true'
                elif key == 'services':
                    proj[key] = []
                    i += 1
                    while i < len(lines):
                        s = lines[i].strip()
                        if s.startswith('- '):
                            proj['services'].append(s[2:].strip())
                            i += 1
                        else:
                            break
                    continue
                elif key == 'exclude':
                    proj.setdefault('build', {})['exclude'] = []
                    i += 1
                    while i < len(lines):
                        s = lines[i].strip()
                        if s.startswith('- '):
                            proj['build']['exclude'].append(s[2:].strip())
                            i += 1
                        else:
                            break
                    continue
                elif key == 'include':
                    proj.setdefault('build', {})['include'] = []
                    i += 1
                    while i < len(lines):
                        s = lines[i].strip()
                        if s.startswith('- '):
                            proj['build']['include'].append(s[2:].strip())
                            i += 1
                        else:
                            break
                    continue
                elif val:
                    if val.startswith('"') or val.startswith("'"):
                        val = val.strip('"').strip("'")
                    if key in ('sourcePath', 'deployPath', 'healthUrl',
                               'nginxReload', 'deployHook', 'packer',
                               'artifactPattern', 'artifact', 'distDir',
                               'packageManager', 'script', 'envFile',
                               'mode', 'kind', 'displayName'):
                        if key in ('packer', 'artifactPattern', 'artifact',
                                   'distDir', 'packageManager', 'script',
                                   'envFile', 'mode'):
                            proj.setdefault('build', {})[key] = val
                        else:
                            proj[key] = val
                    elif key == 'nginxReload':
                        proj[key] = val.lower() == 'true'
            i += 1

        projects.append(proj)

    return projects


def main():
    if not os.path.exists(YAML_PATH):
        print(f'Error: {YAML_PATH} not found', file=sys.stderr)
        sys.exit(1)

    with open(YAML_PATH, encoding='utf-8') as f:
        text = f.read()

    data = parse_yaml_simple(text)

    with open(JSON_PATH, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write('\n')

    ids = [p['id'] for p in data.get('projects', [])]
    print(f'Synced {len(ids)} projects: {", ".join(ids)}')
    print(f'Output: {JSON_PATH}')


if __name__ == '__main__':
    main()
