# AIFoo VPS 控制面维护

该目录只维护两项 root-owned 控制面文件：

- `/usr/local/sbin/deploy-sub2api-backend`
- `/usr/local/libexec/aifoo-update-bridge`

它不操作 Docker Compose、数据库、Nginx 或 Sub2API 服务。每次更新在写入前把这两个现有文件备份到 `/var/backups/aifoo-control-plane`，仅重启 `aifoo-update-bridge`，并通过其本机 `/health` 验证；失败时立即恢复这两个文件并重启旧 bridge。

## 一次性 root bootstrap

现有 Actions SSH 用户只被允许调用固定的部署 helper，不能安全推断为拥有写 `/usr/local` 或重启 systemd 服务的权限。因此首次启用必须经已有 root 管理通道，在 VPS 上从经过审查的仓库版本执行：

```sh
sudo ./install-control-plane.sh \
  --sudo-user <现有受限 SSH 用户> \
  --signing-public-key ./deploy/control-plane/component-signing-public.pem
```

这会安装 root-owned `/usr/local/sbin/deploy-update-components`、Actions 专用签名公钥，并创建只允许该用户调用其四个固定子命令、严格限定参数形状的 sudoers 规则；不会修改 Sub2API、Compose、数据库、Nginx 或 bridge 二进制。VPS helper 会在写入前验证 root-owned 公钥签名和每个 payload SHA，因此受限 SSH 用户不能以自带 archive 获得 root 代码执行。

bootstrap 必须从将要触发工作流的同一 `production` revision 执行；控制面 helper 自身变更后也必须重复 bootstrap，工作流会拒绝不匹配的 helper SHA。

仓库中的 `component-signing-public.pem` 是本次 trust anchor（SHA-256：`a27c123f3a7e66840c917f897ff086852e945cf1328cda7086c31e1325951184`）。将对应私钥以原 PEM 内容写入 GitHub Secret `AIFOO_CONTROL_PLANE_SIGNING_KEY`；私钥不进入仓库、Issue、日志或 VPS。

## 后续受控更新

bootstrap 后，仓库 owner 在 `production` 手动触发 `deploy-update-components.yml` 并输入 `UPDATE-AIFOO-CONTROL-PLANE`。工作流先运行 bridge 的 `go test ./...`、`go vet ./...` 和静态 Linux 构建，再用 GitHub Secret `AIFOO_CONTROL_PLANE_SIGNING_KEY` 签署 payload manifest。VPS helper 必须用 root-owned 公钥验签，并二次校验 archive 与成员 SHA，才会原子替换文件、只重启 bridge、执行本机健康检查；验证失败会恢复本机即时备份。

更新器自身的 SHA 也在每次操作前比对；更新该 root helper 本身时，重复一次 root bootstrap。
