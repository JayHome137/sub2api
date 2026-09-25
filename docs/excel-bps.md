# Excel / BPS 协议（OpenAI OAuth）

在账号管理 → 编辑现有 OpenAI OAuth 账号 → 打开“Excel / BPS 协议”并保存。使用该账号已有的 ChatGPT access token/account ID，不需要 GitHub 登录、sidecar 或新建 API Key 上游账号。原有凭据刷新逻辑继续生效。默认关闭；切换后新开 Codex 会话。

本入口面向 HTTP `/v1/responses` 和 `/v1/responses/compact`。强制上游 HTTP/SSE，优先于账号的自动透传、WS mode 和 Codex ticket 注入。保持原始模型名或显式账号映射，不因模型权限不足偷偷切换模型。现有调度、分组授权和并发额度继续生效；开关不会重新启用已停用的账号。

## 工具调用与并发

- 客户端 tools 转成 developer 消息中的目录；只解析上游 `run_officejs.code` 内的 JSON，不在服务器执行 OfficeJS 或客户端命令。
- 支持 function、custom、namespace、Lite additional_tools，保留 custom 原始文本与 JSON 大整数。
- 文本增量实时转发；工具等完整 response.completed 到齐后统一验证，失败、不完整或未知工具不会被提前发送执行。
- 完整原生 item 按账号、API Key、线程作用域缓存。回放保留上游 ID、summary、references 等内容；多个完整工具和乱序结果按 call_id 配对。
- 子线程优先使用 thread-id / x-codex-turn-metadata，不因共用父会话 session_id 混用缓存；没有设置全账号串行锁。并行子代理仍受账号并发数、调度及上游能力约束。
- 提示词仍要求每个 transport 内只放一个工具对象，响应声明 parallel_tool_calls=false。多工具转换与子线程隔离已有离线回归，不等于真实 Codex 多代理工作流已完整验收。
- 缓存位于当前进程，有条数和内存上限。重启、跨实例、换账号或淘汰后的缺失原始调用会报错，不能恢复任意旧线程。

### 账号工具探测

在账号管理的连接测试中，已启用 Excel / BPS 的 OpenAI OAuth 账号可选择「BPS 工具往返」。管理员主动运行后，最多发起三次实际上游请求：先校验随机 nonce 的完整文本响应，再要求调用一次无外部副作用的 echo 工具，最后回传该工具结果并核对完整响应。每一步固定使用所选账号和模型的 BPS 路径；协议关闭、模型不在 BPS 范围、错误终态或工具参数不符时立即失败，不切换到普通 Codex 重试。每个服务实例最多同时运行 3 个探测，同账号只能运行 1 个；其他账号连接测试不受此限制。

此测试不自动定时运行，也不写入持久能力判定。通过仅证明测试时该账号的基础文本与所声明 echo 工具完成了一次 BPS 往返，不代表 Codex Desktop 默认工具集、多代理协作或所有业务模型均已通过。

### 下游转发与错误定位

- 模型将单个工具写成 `functions.shell({"command":"pwd"})` 时, 适配器按完整调用解析工具名和一个 JSON 字面量参数. 允许可选的 `await` / `return` 和末尾分号, 工具必须已在客户端目录中声明. function 参数必须为 JSON 对象; custom 参数必须为 JSON 字符串, 解码后原样交给客户端. 此处不运行 JavaScript.
- 不从脚本, 多调用, 数组, 未闭合调用或带尾随内容的字符串中截取工具对象. 这类返回会产生 `basispoints_protocol_error`, 不会先发送其中一个工具执行. 未带明确工具身份的原始代码仍会被拒绝.
- `basispoints_request_invalid` 的内容错误附带分叉接收到的字段位置, 例如 `path=input[2].output[1]; type=input_file`. 位置同时覆盖消息内容和 function/custom 工具结果. `input_image` URL 校验失败也附带位置.
- 错误仅显示固定的已知协议类型名称; 任意未知类型归类为 `unknown`, 缺失类型或非对象内容分别标记. 不回显正文, 图片字节, URL 或任意自定义 type 值. 不支持的文件, 音频或其他内容仍返回明确错误, 不会静默丢弃或伪装为文本.
- `supports text and HTTPS input_image content only` 表示内容分块类型不被支持, 单凭这条错误不能判断为 base64 转换失败. 下游应保留完整错误消息及请求 ID, 以便定位字段而不需要保存客户正文.

## 缓存创建计量

- 在账号编辑中勾选现有的缓存创建转普通输入选项后, 实际走 BPS 的请求同时调整本系统记账和返回下游的 `usage`. 默认仍关闭, 不需要修改下游原版 Sub2API 或 Compose 配置.
- 返回下游的缓存创建/写入字段及 5 分钟, 1 小时明细归零. 总输入已包含这部分 token, 因此不额外增加 `input_tokens` / `total_tokens`; 缓存读取, 输出和推理明细保持不变. 例如总输入 1000, 缓存读取 100, 缓存创建 200, 开启后下游得到普通输入 900, 缓存读取 100, 缓存创建 0.
- 同时覆盖流式事件和非流式 Responses/compact 响应, 包括顶层 `usage` 和 `response.usage`. 本系统在响应改写前读取原始上游用量, 继续使用既有计费逻辑.
- 该选项改变计量分类, 不会关闭上游实际缓存. 未开启选项或实际未走 BPS 的请求保持原有行为; 下游独立配置的强制缓存计费规则不受此选项控制.

## 能力限制

`max`/`ultra` 映射 `xhigh`，`none`/`minimal` 映射 `low`，实际 effort 出现在响应/用量中。拒绝强制指定工具、托管工具、结构化输出与仅 previous_response_id 的增量历史。不要把 HTTP 200 当作模型能力证明。

仅转发 HTTPS 图片 URL，不上传本地图片，不接受 base64/data URL 或 file_id。本地请求校验通过不等于上游视觉已验收。CPA 参考项目也记录了实际图片 422。

原始协议来自 hloolx/codex2api：9d02d3f5 → c125e560 → 20ff3e86 → d39f7e36 → 4dea83ec（含中间依赖修复）。另外对照 JaxsonWang/cpa-plugin-oai-basispoints 05b2d97 的工具目录、信封和回放实现。出处见 `backend/internal/service/basispoints/NOTICE.md`。

验证区分：账号 300 的 gpt-5.6-sol 直连 BPS 糖果题返回 21；这只是文本上游验证。PR 中完整 Sub2API 转发、工具回放、多个子线程使用 mock 回归，尚未将该改动部署到生产。
