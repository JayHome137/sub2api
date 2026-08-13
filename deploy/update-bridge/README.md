# AIFoo 网页更新桥接服务

该服务只把管理员在网页上的明确点击转换为私有仓库 `web-update.yml` 的一次 `workflow_dispatch`。上游同步工作流会先完成合并、UI 审查、测试、构建，并把精确前端镜像预加载到 VPS；若官方后端运行时变化，也会预先验证、隔离测试并准备镜像和回滚元数据。网页点击只执行必要的快速切换与健康检查，有 migration 时额外生成 PostgreSQL custom dump。

## 安全边界

- 仅监听 `127.0.0.1:8091`，公网只能通过同源 Nginx 精确路径访问。
- 每个状态或触发请求都必须携带现有管理员 Bearer Token，并回查到官方 `/api/v1/admin/system/version`；不接受 Cookie 代替。
- GitHub Fine-grained PAT 只从 `/etc/aifoo-update-bridge/github-token` 读取，不进入浏览器、前端镜像、仓库变量或 Actions Secret。
- 只允许触发 `production` 分支的固定 `web-update.yml`，Release 参数必须是 `vX.Y.Z`。
- 只有 Issue 同时带 `ready-for-vps`、`vps-preloaded`，且需要后端时还有 `backend-prepared`，并且没有失败/UI 阻断标签时才允许触发；两分钟内重复点击只产生一次调度。

PAT 仅授权此私有仓库，最小权限为 `Metadata: Read`、`Actions: Read and write`、`Issues: Read`。

## 构建与安装

先在可信环境构建 Linux 静态二进制：

```bash
cd deploy/update-bridge
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o aifoo-update-bridge .
```

把二进制和本目录传入 VPS 后执行：

```bash
sudo ./install.sh ./aifoo-update-bridge
read -rsp 'GitHub Fine-grained PAT: ' AIFOO_BRIDGE_TOKEN
printf '%s' "$AIFOO_BRIDGE_TOKEN" | sudo install -o root -g aifoo-update-bridge -m 0640 /dev/stdin /etc/aifoo-update-bridge/github-token
unset AIFOO_BRIDGE_TOKEN
sudo install -o root -g root -m 0644 nginx-location.conf /etc/nginx/snippets/aifoo-update-bridge.conf
```

在生产 TLS `server` 块中加入 `include /etc/nginx/snippets/aifoo-update-bridge.conf;`，先运行 `sudo nginx -t`，再 reload Nginx 并启动服务：

```bash
sudo systemctl enable --now aifoo-update-bridge
curl --fail http://127.0.0.1:8091/health
```

这些命令会修改生产环境，必须在现有配置备份和回滚方案准备完成后另行执行；本次仓库实施不自动运行它们。

## 本地验证

```bash
go test ./...
go vet ./...
```

## 受控更新

生产环境中更新 bridge 二进制或后端 helper 时，使用私有仓库的 `deploy-update-components.yml`。首次启用需由 VPS root 管理通道安装 root-owned `deploy-update-components`、签名公钥和窄 sudo 规则；后续工作流要求仓库 owner 在 `production` 上输入 `UPDATE-AIFOO-CONTROL-PLANE`，并只接收签名 manifest 验证通过的 payload。其本机备份、SHA 校验和失败回滚不涉及 Nginx、Docker Compose、数据库或 Sub2API 容器。
