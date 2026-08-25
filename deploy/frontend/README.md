# AIFoo 固定前端

该镜像只承载 AIFoo UI、登录页和公开 landing 静态资源；所有 API 请求继续代理给官方 `sub2api` 后端容器。

前端没有定时构建。只有 AIFoo UI 实际修改或上游新增界面需要人工兼容时，才手动运行仓库唯一的 `AIFoo UI` workflow。该工作流在自托管 VM 上完成 lint、类型检查、Vitest、Playwright、镜像构建和 GHCR 推送，不上传 Actions artifact。

生产部署使用精确 digest：

```bash
sudo /usr/local/libexec/aifoo-deploy-helper frontend-activate \
  ghcr.io/jayhome137/sub2api-frontend@sha256:<digest>
```

helper 只重建 Compose 的 `frontend` 服务并等待容器健康；失败会恢复原 Compose 和原前端。后端、PostgreSQL 和 Redis 不会被重建。
