# CPA 额度菜单栏组件安装流程（macOS）

安装后，Mac 菜单栏会显示 Codex 剩余额度。点击可查看 **5 小时额度、周额度和重置时间**；只有官方接口返回的周期才会显示。

本组件仅支持 macOS，通过本项目的第三方 CPA 商店来源分发，不提交 CPA 官方插件商店。

1. 从 [CPA 发布页](https://github.com/router-for-me/EasyCLIProxyAPI/releases/latest) 下载适合你的 Mac 的版本，安装到“应用程序”并打开。
2. 在 CPA“版本管理”中安装支持插件的内核，回到首页启动内核。在 OAuth 页面授权 Codex 账号，确认账号有效。
3. 打开“插件”页，开启插件总开关。
4. 在“插件 → 设置 → 附加商店来源”加入本项目的第三方来源：

   ```text
   https://raw.githubusercontent.com/RoyalXC/cpa-plugin-codex-quota-menubar/main/registry.json
   ```

5. 返回插件商店，找到 **Codex Quota Menubar**，完成 CPA 的来源确认并安装、启用。菜单栏会自动出现百分比胶囊。

无需安装 Python、Node.js 或 Xcode。CPA 按内核架构自动下载 Apple Silicon 或 Intel 版本。

附加来源直接下载 GitHub 发布页的安装包并核对校验值，不依赖 GitHub API 查询。后续更新继续使用同一来源，更新后组件的本地设置会保留。

当前版本为 [0.5.0](https://github.com/RoyalXC/cpa-plugin-codex-quota-menubar/releases/tag/v0.5.0)。已通过原生 Apple Silicon、Intel 的 macOS 15 CI，以及 macOS 27.0.1 上的公开来源安装与本机 CPA 升级验证。安装包目前使用临时签名，尚未做 Apple 公证；macOS 13 为编译目标，尚未完成实机验证。

| 操作或显示 | 含义 |
| --- | --- |
| 菜单栏百分比 | 剩余 5 小时额度优先，额度未知时为 `--%` |
| 左键点击 | 展开或关闭详情，查看周额度、重置和获取时间 |
| 账号下拉框 | 选择展示账号，或恢复自动识别；不改变 CPA 路由 |
| 刷新图标 | 重新查询官方额度 |
| 百分比后的 `*` | 过期缓存，可手动刷新 |
| 右键 → 退出 | 停止组件，禁用再启用插件可恢复 |

账号认证过期时，请在 CPA 中重新授权。通过 CPA 的 Codex 请求会触发更新；绕过 CPA 的请求不会产生这些事件，可手动刷新。第三方 API Key 模型的额度不在此组件中显示。

数据默认保存在 `~/Library/Application Support/CodexQuotaMenubar`。标准 CPA 安装可直接使用；自定义账号目录或管理端口时，可在插件配置中填写 `cpaHome`、`authDir`、`managementPort`。

关闭 CPA 内核或禁用插件会关闭其托管的组件。保留上述附加来源，即可在 CPA 插件商店检查新版本。第三方分发方式、签名信息和验证环境见[项目说明](../README.md)。
