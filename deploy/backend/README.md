# AIFoo 官方后端交付

此目录只负责验证并切换官方稳定 Release 的 `weishaw/sub2api@sha256:...`。AIFoo 不定制后端；前端 UI 仍由私有镜像维护。

## 按钮出现前

`upstream-sync.yml` 每 3 小时（北京时间 02:17、05:17、…）检查官方稳定 Release。候选源码、必要 CI、UI 兼容、前端镜像均通过后：

- 前端镜像预加载到 VPS；
- 仅在官方后端运行时变化时，`backend-preparation.yml` 验证官方 tag、commit、不可变镜像和 migration 计划；
- Runner 用隔离 PostgreSQL/Redis 验证升级及旧镜像回滚；
- VPS 只预拉取目标镜像，并保存当前 Compose、旧镜像引用和容器指纹作为本机回滚状态；
- 不切换容器、不修改 Compose、不接触生产数据。

前端 `vps-preloaded`，以及后端变化时的 `backend-prepared`，全部完成后才添加 `ready-for-vps`，网页才显示一键更新。

## 点击一键更新后

纯前端更新只激活已预加载前端镜像。

后端更新只执行：

1. 核对 prepared state 未漂移；
2. Compose 仅替换 `sub2api.image`，重建后端单个服务；
3. 核对镜像、版本、commit、migration 和一次公网健康检查；
4. 切换失败时恢复按钮出现前保存的旧镜像和 Compose。

点击路径不会重新 pull 镜像、运行隔离升级测试或重复完整 CI。

## 数据边界

- 更新流程不创建数据库、Redis 或应用数据备份。
- 更新流程不执行数据库恢复。
- migration 仍由官方后端镜像启动时按原版逻辑执行。
- 旧镜像和 Compose 只用于程序版本回滚，与业务数据备份无关。

## Helper 安装边界

生产 helper 固定为 `/usr/local/sbin/deploy-sub2api-backend`，须由 root 持有且 group/world 不可写。工作流用仓库 helper 的 SHA-256 做 preflight；helper 尚未按新版本更新到 VPS 时，准备流程会安全阻断，不会切换生产。
