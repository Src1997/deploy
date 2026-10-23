# WireGuard（随包分发版）

跨机互联默认方案。**完整文档在仓库 `docs/guide/multi-server-interconnect.md`**（决策树、
fdw、接入清单、踩过的坑），本文件只保留服务器侧跑得了的部分。

## 本机侧配置（幂等，重跑安全）

```bash
bash setup-wireguard.sh --name <本机名> --tunnel-ip 10.10.0.x/24 \
  --peer-name <对端名> --peer-public-key <对端公钥> \
  --peer-tunnel-ip 10.10.0.y --peer-endpoint <对端公网IP>:51820 \
  --allow-ports 6379,5432
```

自动完成：装 wireguard → 生成/复用密钥 → 写 `/etc/wireguard/wg0.conf` → 起隧道 +
开机自启 → ufw 放行（对端 IP→51820/udp、wg0 接口→业务端口）。

## 三条铁律

1. **wg0 接口的业务端口必须显式放行**（`ufw allow in on wg0 ...`）——WG 进来的包也过 INPUT 链
2. **pg_hba 按隧道网段逐条加**，禁止 `0.0.0.0/0` 全网规则
3. **私钥禁入库**；对端档案（公钥/网段）更新在仓库 `configs/wireguard/peers.md`

## 当前对等关系

见 `peers.md`（同目录）。
