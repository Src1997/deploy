# SSL 证书与域名管理（acme.sh 链路）

> **Category**: Guide
>
> 证书过期是最经典的线上事故，本文把散落在 DEPLOY-NOTES / ops 脚本里的证书知识收拢成一份手册。
> 铁律先行：**acme.sh 是唯一签发/续签链路，宝塔面板 SSL 页只读查看——勿点「续签」**。

## 1. 现状速查（2026-10-23）

| 服务器 | 主域 | acme.sh 证书目录 | 覆盖域名（SAN） | 有效期至 |
|--------|------|------------------|-----------------|----------|
| B（deepquant.club） | 深量科技 | `/root/.acme.sh/deepquant.club_ecc/` | deepquant.club + www + mail | acme.sh 自动续 |
| C（zhouchou.net） | 卓筹商学院 | `/root/.acme.sh/zhouchou.net_ecc/` | zhouchou.net + www + mail（2026-10-20 扩为三域合一） | **2027-01-18**（acme.sh 自动续） |

证书落位：`/www/server/panel/vhost/cert/<站点或域名>/`（B=financial-web.local、C=www.zhouchou.net），
站点 conf 内 `ssl_certificate` 指向这里。

## 2. 续签链路（自动，平时无需干预）

```
acme.sh 定时任务（crontab）→ webroot 验证（/www/wwwroot/project/acme/.well-known/acme-challenge/）
  → 签发/续签 ECC 证书 → reloadcmd 四路同步：
     ① 网站 vhost（nginx reload）
     ② 面板证书
     ③ 邮局证书（dovecot + postfix，见 §4）
     ④ 其余站点同步（B 走 /root/scripts/bt-cert-sync.sh，日志 /var/log/cert-sync.log）
```

## 3. 红线清单

1. **面板 → 站点 → SSL 页只读**——点「续签」会覆盖 acme.sh 链路（Let's Encrypt 面板通道与 acme.sh 双谱系）。
2. **宝塔邮局面板勿点「添加证书」**——会重写 `/etc/postfix/vmail_ssl.map` 并把 `texthash:` 改回 `hash:`（postfix 读 hash .db 报 malformed BASE64）。
3. **`scripts/ops/06-fix-ssl-cert.sh` 勿在 C 重跑**——该脚本不支持 ECC，会 `--force` 签一张新 RSA 证书与 `_ecc` 并存，造成双证书谱系。
4. 证书相关改动后固定验证：`nginx -t && nginx -s reload` + `curl -vI https://<域名> 2>&1 | grep -E "expire|subject"`。

## 4. 邮局证书接管明细（C 为准，B 同构）

| 组件 | 接管点 |
|------|--------|
| dovecot | `10-ssl.conf` → `/www/server/panel/plugin/mail_sys/cert/zhouchou.net/{fullchain.pem, privkey.pem}` |
| postfix main.cf | `smtpd_tls_chain_files = privkey.pem, fullchain.pem`（同目录）；原 `smtpd_tls_cert_file/key_file` 已清空（原 snakeoil 自签） |
| postfix master.cf | smtps(465) 段启用 `-o smtpd_tls_wrappermode=yes`（插件模板默认注释——**465 明文坑**） |
| SNI 接管 | `/etc/postfix/vmail_ssl.map` + `tls_server_sni_maps=texthash:`（★勿用 `hash:`，见红线 2） |

面板「SSL 列」的显示判定 = 证书文件存在 + map 含域名——只读确认即可。

## 5. 常用命令

```bash
# 查看所有证书与到期时间
/root/.acme.sh/acme.sh --list

# 手动立即续签（慎用 --force；正常交给 crontab）
/root/.acme.sh/acme.sh --renew -d zhouchou.net --ecc

# 验证当前线上证书到期日
curl -vI https://zhouchou.net 2>&1 | grep -E "expire date|subject:"

# 同步日志（B）
tail -50 /var/log/cert-sync.log

# 新签/扩域（在目标服务器上，B/A 适用；C 走既有 _ecc 扩 SAN，勿重跑脚本）
DOMAIN=deepquant.club \
EXTRA_DOMAINS="www.deepquant.club mail.deepquant.club" \
CERT_NAMES="www.deepquant.club mail.deepquant.club" \
bash scripts/ops/06-fix-ssl-cert.sh
```

## 6. 续签失败排查 SOP

1. **看 acme.sh 日志**：`tail -100 /root/.acme.sh/acme.sh.log`（常见：DNS 未生效、webroot 404）
2. **验证 80 端口可达**：`curl -I http://<域名>/.well-known/acme-challenge/test`——必须 200 或 404（不能 301 跳 https / 超时）
3. **webroot 目录**：`/www/wwwroot/project/acme/` 存在且 nginx 80 块含 `/.well-known/acme-challenge/` 验证路径（脚本幂等插入）
4. **CDN/防火墙**：验证路径不得被 CDN 缓存或 ufw 拦截 80
5. 修好后手动续签一次确认，再依赖 crontab 自动化
