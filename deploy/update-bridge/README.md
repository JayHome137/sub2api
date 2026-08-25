# AIFoo 本地更新控制面

网页版本面板继续使用官方 Sub2API 的检查、回滚版本列表和交互。三个 Docker mutation 改由同源本地桥处理：

- `POST /api/v1/aifoo-upgrade/update`：查询官方最新版本，拉取 `weishaw/sub2api:<version>`，解析并锁定精确 digest。
- `POST /api/v1/aifoo-upgrade/rollback`：拉取管理员选择的官方旧版本并锁定 digest。
- `POST /api/v1/aifoo-upgrade/restart`：只重建 Compose 的 `sub2api` 服务，验证容器健康和二进制版本；失败时恢复原 Compose 和原后端。

日常后端更新不访问私有 GitHub 仓库，不触发 Actions，不构建后端，也不使用 VM。桥只监听 `127.0.0.1:8091`，每个 mutation 都把浏览器现有的 Bearer Token 回查官方管理员 API。它不读取 GitHub PAT。

## 构建与安装

在可信的 Linux amd64 环境构建两个静态二进制：

```bash
(cd deploy/update-bridge && CGO_ENABLED=0 go build -trimpath -o aifoo-update-bridge .)
(cd deploy/deploy-helper && CGO_ENABLED=0 go build -trimpath -o aifoo-deploy-helper .)
sudo deploy/update-bridge/install.sh \
  deploy/update-bridge/aifoo-update-bridge \
  deploy/deploy-helper/aifoo-deploy-helper \
  deploy-user
```

将 `nginx-location.conf` 安装到现有 TLS server 已 include 的 snippet 路径，执行 `nginx -t` 后 reload。安装器只重启 bridge，不重启 Sub2API、数据库、Redis 或前端。

受保护状态保存在 `/var/lib/aifoo-deploy-helper`；安装时只保留一份控制面二进制和 systemd unit 的 `.previous` 回退副本。

## 验证

```bash
(cd deploy/update-bridge && go test ./... && go vet ./...)
(cd deploy/deploy-helper && go test ./... && go vet ./...)
```
