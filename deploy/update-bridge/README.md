# AIFoo 本地更新控制面

网页版本面板继续使用现有的版本检查、回滚列表和交互。三个 Docker mutation 改由同源本地桥处理，版本来源和运行镜像都属于 `JayHome137/sub2api`：

- `POST /api/v1/aifoo-upgrade/update`：查询自有 GitHub Release，准备 `ghcr.io/jayhome137/sub2api:<version>`，解析并锁定精确 digest。
- `POST /api/v1/aifoo-upgrade/rollback`：准备管理员选择的自有旧版本镜像并锁定 digest。
- `POST /api/v1/aifoo-upgrade/restart`：只重建 Compose 的全栈 app 服务，验证容器健康、镜像 digest 和版本；失败时恢复原 Compose 和原 app。

日常更新只拉取已经发布的 Release 和 GHCR 镜像，不触发 Actions，不在生产机编译代码，也不使用 VM。桥只监听 `127.0.0.1:8091`，每个 mutation 都把浏览器现有的 Bearer Token 回查本机管理员 API。它不读取 GitHub PAT。

当前 GHCR 包为私有包。首次安装控制面后，在生产机用有权读取该包的 GitHub 用户名和短期令牌完成一次登录；凭据会写入 systemd bridge 使用的独立 Docker 配置目录，不会写入 Compose 或仓库：

```bash
read -r -s GHCR_TOKEN
printf '%s' "$GHCR_TOKEN" | sudo env DOCKER_CONFIG=/var/lib/aifoo-deploy-helper/docker-config \
  /usr/local/libexec/aifoo-deploy-helper registry-login "$GHCR_USERNAME"
unset GHCR_TOKEN
```

## Release 安装

生产环境优先解压与应用镜像同版本的
`sub2api_control_<version>_linux_amd64.tar.gz`，再运行包内的
`install.sh`。这样主机控制面和应用镜像始终来自同一次 Release，不需要在
生产机 checkout 源码或重新编译。

```bash
tar -xzf sub2api_control_<version>_linux_amd64.tar.gz
cd sub2api_control_<version>_linux_amd64
sudo ./install.sh ./aifoo-update-bridge ./aifoo-deploy-helper deploy-user
```

## 源码构建与安装

在可信的 Linux amd64 环境构建两个静态二进制：

```bash
(cd deploy/update-bridge && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o aifoo-update-bridge .)
(cd deploy/deploy-helper && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o aifoo-deploy-helper .)
sudo deploy/update-bridge/install.sh \
  deploy/update-bridge/aifoo-update-bridge \
  deploy/deploy-helper/aifoo-deploy-helper \
  deploy-user
```

将 `nginx-location.conf` 安装到现有 TLS server 已 include 的 snippet 路径，执行 `nginx -t` 后 reload。安装器只重启 bridge，不重启 Sub2API、数据库、Redis 或前端。

受保护状态保存在 `/var/lib/aifoo-deploy-helper`；安装时只保留一份控制面二进制和 systemd unit 的 `.previous` 回退副本。app 激活成功后只保留当前镜像和激活前一份 app 镜像，并删除同一自有仓库中更旧的带标签镜像；不执行 `docker system prune`，也不处理任何 Docker volume。Compose 回退文件始终只保留一份并在下一次激活时覆盖。

Release 同时提供应用镜像、应用二进制和 Linux amd64 控制面包。生产机先安装与 Release 同版本的控制面包，再使用网页按钮切换后续全栈镜像；控制面升级不会改动 PostgreSQL、Redis 或应用数据卷。

## 验证

```bash
(cd deploy/update-bridge && go test ./... && go vet ./...)
(cd deploy/deploy-helper && go test ./... && go vet ./...)
```
