# AIFoo 固定前端（历史测试资产）

该目录保留早期 V3 测试所需的独立前端资产。生产环境已经改为由
`ghcr.io/jayhome137/sub2api:<version>` 全栈镜像内嵌 AIFoo UI；这里的
独立镜像和 `frontend-activate` 路径不再是受支持的生产部署方式。

任何 AIFoo UI 修改都必须进入全栈 Release 工作流，和后端一起构建、验证和发布。
