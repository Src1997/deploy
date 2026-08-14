#!/usr/bin/env python3
"""Generate Nginx config from TOML project configs.

Usage:
    python3 scripts/tools/generate-nginx.py --mode http
    python3 scripts/tools/generate-nginx.py --mode ssl-redirect --domain example.com --www-domain www.example.com
    python3 scripts/tools/generate-nginx.py --mode ssl-combined --domain example.com --www-domain www.example.com

Modes:
    http           - HTTP only (no SSL), server_name _
    ssl-redirect   - SSL with HTTP→HTTPS redirect + bare domain → www redirect
    ssl-combined   - SSL combined HTTP+HTTPS in one server block
"""
import argparse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# -- Import config_loader (shared TOML reader) --
for _lib in [os.path.join(SCRIPT_DIR, 'lib'),
              os.path.join(SCRIPT_DIR, '..', 'lib')]:
    if os.path.isfile(os.path.join(_lib, 'config_loader.py')):
        sys.path.insert(0, _lib)
        break

import config_loader  # noqa: E402


def load_projects():
    """Load project manifest directly from TOML configs."""
    configs_dir = config_loader.find_configs_dir(__import__('pathlib').Path(SCRIPT_DIR))
    if not configs_dir.is_dir():
        print(f'Error: project-configs/ not found near {SCRIPT_DIR}', file=sys.stderr)
        sys.exit(1)
    return config_loader.load_manifest(configs_dir)


def generate_static_location(loc, deploy_path, project_base):
    """Generate a static file serving location block with SPA fallback."""
    path = loc['path']
    alias = f'{project_base}/{deploy_path}/'
    # Ensure alias ends with /
    if not alias.endswith('/'):
        alias += '/'

    # Remove trailing slash for the redirect location
    path_no_slash = path.rstrip('/')

    lines = []
    # Redirect without trailing slash
    lines.append(f'    location = {path_no_slash} {{ return 301 {path}; }}')
    lines.append(f'    location ^~ {path} {{')
    lines.append(f'        alias {alias};')
    lines.append(f'        index index.html;')
    lines.append(f'        try_files $uri $uri/ {path}index.html;')
    lines.append(f'    }}')
    # index.html no-cache
    lines.append(f'    location = {path}index.html {{')
    lines.append(f'        alias {alias}index.html;')
    lines.append(f'        add_header Cache-Control "no-cache, no-store, must-revalidate";')
    lines.append(f'        expires 0;')
    lines.append(f'    }}')
    return '\n'.join(lines)


def generate_proxy_location(loc):
    """Generate an HTTP reverse proxy location block."""
    path = loc['path']
    target = loc['proxyTarget']
    proxy_path = loc.get('proxyPath', path)

    # Determine proxy_pass: if target ends with / and path ends with /, keep trailing
    if target.endswith('/') and proxy_path.endswith('/'):
        proxy_pass = f'{target}'
    else:
        proxy_pass = f'{target}{proxy_path}'

    lines = []
    lines.append(f'    location ^~ {path} {{')
    lines.append(f'        proxy_pass {proxy_pass};')
    lines.append(f'        proxy_set_header Host $host;')
    lines.append(f'        proxy_set_header X-Real-IP $remote_addr;')
    lines.append(f'        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;')
    lines.append(f'        proxy_set_header X-Forwarded-Proto $scheme;')
    lines.append(f'        proxy_connect_timeout 10s;')
    lines.append(f'        proxy_read_timeout 60s;')
    lines.append(f'        proxy_send_timeout 60s;')
    lines.append(f'    }}')
    return '\n'.join(lines)


def generate_websocket_location(loc):
    """Generate a WebSocket reverse proxy location block."""
    path = loc['path']
    target = loc['proxyTarget']
    proxy_path = loc.get('proxyPath', path)
    proxy_pass = f'{target}{proxy_path}'

    lines = []
    lines.append(f'    location ^~ {path} {{')
    lines.append(f'        proxy_pass {proxy_pass};')
    lines.append(f'        proxy_http_version 1.1;')
    lines.append(f'        proxy_set_header Upgrade $http_upgrade;')
    lines.append(f'        proxy_set_header Connection "upgrade";')
    lines.append(f'        proxy_set_header Host $host;')
    lines.append(f'        proxy_set_header X-Real-IP $remote_addr;')
    lines.append(f'        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;')
    lines.append(f'        proxy_set_header X-Forwarded-Proto $scheme;')
    lines.append(f'        proxy_read_timeout 86400s;')
    lines.append(f'        proxy_send_timeout 86400s;')
    lines.append(f'        proxy_buffering off;')
    lines.append(f'    }}')
    return '\n'.join(lines)


def generate_mcp_location(loc):
    """Generate a special MCP proxy location block."""
    path = loc['path']
    target = loc['proxyTarget']
    proxy_path = loc.get('proxyPath', path)
    proxy_pass = f'{target}{proxy_path}'

    # Extract host:port for Host header
    host_header = target.replace('http://', '').replace('https://', '')

    lines = []
    lines.append(f'    location ^~ {path} {{')
    lines.append(f'        proxy_pass {proxy_pass};')
    lines.append(f'        proxy_http_version 1.1;')
    lines.append(f'        proxy_set_header Host {host_header};')
    lines.append(f'        proxy_set_header Connection "";')
    lines.append(f'        proxy_set_header Content-Type $content_type;')
    lines.append(f'        proxy_set_header Accept $http_accept;')
    lines.append(f'        proxy_set_header X-Real-IP $remote_addr;')
    lines.append(f'        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;')
    lines.append(f'        proxy_set_header X-Forwarded-Proto $scheme;')
    lines.append(f'        proxy_buffering off;')
    lines.append(f'        proxy_cache off;')
    lines.append(f'        proxy_read_timeout 300s;')
    lines.append(f'        proxy_send_timeout 300s;')
    lines.append(f'        chunked_transfer_encoding on;')
    lines.append(f'    }}')
    return '\n'.join(lines)


def generate_root_location(deploy_path, project_base):
    """Generate root / location for the rootProject."""
    root = f'{project_base}/{deploy_path}'
    lines = []
    lines.append(f'    root {root};')
    lines.append(f'    index index.html;')
    lines.append(f'')
    lines.append(f'    location = /index.html {{')
    lines.append(f'        root {root};')
    lines.append(f'        add_header Cache-Control "no-cache, no-store, must-revalidate";')
    lines.append(f'        expires 0;')
    lines.append(f'    }}')
    lines.append(f'')
    lines.append(f'    location / {{')
    lines.append(f'        try_files $uri $uri/ /index.html;')
    lines.append(f'    }}')
    return '\n'.join(lines)


def generate_location_block(loc, project, project_base):
    """Generate a location block based on type."""
    loc_type = loc.get('type', 'static')

    if loc_type == 'static':
        return generate_static_location(loc, project['deployPath'], project_base)
    elif loc_type == 'proxy':
        if loc.get('specialHeaders'):
            return generate_mcp_location(loc)
        return generate_proxy_location(loc)
    elif loc_type == 'websocket':
        return generate_websocket_location(loc)
    else:
        return f'    # Unknown location type: {loc_type} for {loc.get("path", "?")}'


def generate_header_http():
    """Generate HTTP-only server header."""
    return """server {
    listen 80;
    server_name _;

    # -- Gzip --
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        application/json
        application/javascript
        application/xml+rss
        text/javascript
        image/svg+xml;

    # -- Security headers --
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    client_max_body_size 20m;

    include mime.types;
    default_type application/octet-stream;
"""


def generate_header_ssl_redirect(domain, www_domain):
    """Generate SSL with HTTP→HTTPS redirect + bare domain → www redirect."""
    return f"""# -- HTTP -> HTTPS redirect --
server {{
    listen 80;
    server_name {domain} {www_domain};

    location ^~ /.well-known/acme-challenge/ {{
        root /www/wwwroot/project/acme;
    }}

    location / {{
        return 301 https://$host$request_uri;
    }}
}}

# -- HTTPS bare domain -> www redirect --
server {{
    listen 443 ssl http2;
    server_name {domain};

    ssl_certificate    /www/server/panel/vhost/cert/{www_domain}/fullchain.pem;
    ssl_certificate_key /www/server/panel/vhost/cert/{www_domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    return 301 https://{www_domain}$request_uri;
}}

# -- HTTPS main site (www) --
server {{
    listen 443 ssl http2;
    server_name {www_domain};

    ssl_certificate    /www/server/panel/vhost/cert/{www_domain}/fullchain.pem;
    ssl_certificate_key /www/server/panel/vhost/cert/{www_domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000" always;

    # -- Gzip --
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        application/json
        application/javascript
        application/xml+rss
        text/javascript
        image/svg+xml;

    # -- Security headers --
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    client_max_body_size 20m;

    include mime.types;
    default_type application/octet-stream;
"""


def generate_header_ssl_combined(domain, www_domain):
    """Generate SSL combined HTTP+HTTPS in one server block."""
    # Use www_domain for cert path, fall back to domain
    cert_domain = www_domain or domain or '_'
    return f"""server {{
    listen 80;
    listen 443 ssl http2;
    server_name _;

    # -- SSL --
    ssl_certificate    /www/server/panel/vhost/cert/{cert_domain}/fullchain.pem;
    ssl_certificate_key /www/server/panel/vhost/cert/{cert_domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+CHACHA20-draft:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:EECDH+3DES:RSA+3DES:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    add_header Strict-Transport-Security "max-age=31536000";
    error_page 497  https://$host$request_uri;

    # -- Gzip --
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        application/json
        application/javascript
        application/xml+rss
        text/javascript
        image/svg+xml;

    # -- Security headers --
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    client_max_body_size 20m;

    include mime.types;
    default_type application/octet-stream;
"""


def generate_footer():
    """Generate common footer (health check, logging, closing brace)."""
    return """
    # -- Health check --
    location = /health {
        return 200 'OK';
        add_header Content-Type text/plain;
        access_log off;
    }

    # -- Logging --
    access_log /www/wwwlogs/access.log;
    error_log /www/wwwlogs/error.log;
}
"""


def main():
    parser = argparse.ArgumentParser(description='Generate Nginx config from TOML project configs')
    parser.add_argument('--mode', choices=['http', 'ssl-redirect', 'ssl-combined'],
                        default='http', help='Nginx mode')
    parser.add_argument('--domain', default='', help='Bare domain (for SSL)')
    parser.add_argument('--www-domain', default='', help='WWW domain (for SSL)')
    parser.add_argument('--project-base', default='/www/wwwroot/project',
                        help='Server project base path')
    parser.add_argument('--output', '-', help='Output file (default: stdout)')
    args = parser.parse_args()

    data = load_projects()
    project_base = args.project_base
    projects = data.get('projects', [])
    nginx_extras = data.get('nginxExtras', [])

    # Generate header
    if args.mode == 'http':
        header = generate_header_http()
    elif args.mode == 'ssl-redirect':
        if not args.domain or not args.www_domain:
            print('Error: --domain and --www-domain required for SSL modes', file=sys.stderr)
            sys.exit(1)
        header = generate_header_ssl_redirect(args.domain, args.www_domain)
    elif args.mode == 'ssl-combined':
        if not args.www_domain and not args.domain:
            print('Error: --www-domain or --domain required for SSL modes', file=sys.stderr)
            sys.exit(1)
        header = generate_header_ssl_combined(args.domain, args.www_domain)
    else:
        print(f'Error: unknown mode {args.mode}', file=sys.stderr)
        sys.exit(1)

    # Generate location blocks
    # Order: websocket → proxy → static → root (last)
    websocket_blocks = []
    proxy_blocks = []
    static_blocks = []
    root_block = None

    # First pass: find rootProject (determines whether to skip "/" static locations)
    has_root = any(
        p.get('nginx', {}).get('rootProject')
        for p in projects
        if p.get('enabled', True)
    )

    for proj in projects:
        if not proj.get('enabled', True):
            continue
        nginx = proj.get('nginx')
        if not nginx:
            continue

        if nginx.get('rootProject'):
            root_block = generate_root_location(proj['deployPath'], project_base)
            continue

        for loc in nginx.get('locations', []):
            # Skip static location "/" when a rootProject handles the root path
            if loc.get('path') == '/' and loc.get('type', 'static') == 'static' and has_root:
                continue
            block = generate_location_block(loc, proj, project_base)
            loc_type = loc.get('type', 'static')
            if loc_type == 'websocket':
                websocket_blocks.append(block)
            elif loc_type in ('proxy',):
                proxy_blocks.append(block)
            elif loc_type == 'static':
                static_blocks.append(block)

    # Extra locations (infrastructure-level)
    for loc in nginx_extras:
        block = generate_location_block(loc, {'deployPath': ''}, project_base)
        loc_type = loc.get('type', 'proxy')
        if loc_type == 'websocket':
            websocket_blocks.append(block)
        elif loc_type == 'proxy':
            proxy_blocks.append(block)
        elif loc_type == 'static':
            static_blocks.append(block)

    # Assemble config
    parts = [header]
    if websocket_blocks:
        parts.append('\n    # -- WebSocket locations --\n')
        parts.extend(websocket_blocks)
    if proxy_blocks:
        parts.append('\n    # -- Proxy locations --\n')
        parts.extend(proxy_blocks)
    if static_blocks:
        parts.append('\n    # -- Static locations --\n')
        parts.extend(static_blocks)
    if root_block:
        parts.append('\n    # -- Root project --\n')
        parts.append(root_block)
    parts.append(generate_footer())

    config = '\n'.join(parts)

    # Output
    if args.output and args.output != '-':
        with open(args.output, 'w', encoding='utf-8') as f:
            f.write(config)
        print(f'Generated: {args.output}', file=sys.stderr)
    else:
        print(config)


if __name__ == '__main__':
    main()
