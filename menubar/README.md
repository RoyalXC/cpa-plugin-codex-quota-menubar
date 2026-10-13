# 原生菜单栏额度 Helper

`QuotaMenubar.swift` 保留 46×18pt 电池样式百分比胶囊和额度卡片。弹窗使用 macOS 原生动效（遵循系统“减少动态效果”），再次点击胶囊或点击外部区域关闭。刷新时保留账号下拉控件，菜单交互结束后再应用待更新的额度内容。`QuotaEngine.swift` 集成 CPA 账号识别、官方额度查询、缓存、事件合并及生命周期检测。由 CPA 动态库直接启动，网络与 SQLite 读取在后台执行，不追踪 Codex 窗口。

默认数据目录为 `~/Library/Application Support/CodexQuotaMenubar`，支持显式 `--home`/环境变量覆盖。`cpa-plugin/settings.json` 保存 `cpaHome`、`authDir`、`managementPort` 和 `selectedAuthIndex`。插件通过 `--event-fd 198 --home <目录>` 传递所有权 socket；Q2 握手确认组件版本与菜单栏就绪。兼容的独立实例可接收事件，插件退出不会关闭它。

胶囊、悬浮提示、弹窗百分比及进度条统一展示剩余额度，按官方已用百分比计算 `100 - used_percent`；额度未知仍显示 `--%`，缓存过期仍保留 `*` 标记。

配色与 CPA GUI 0.3.11 的 [AuthFileQuotaPanel](https://github.com/router-for-me/EasyCLIProxyAPI/blob/v0.3.11/src/components/AuthFileQuotaPanel.tsx) 和 [主题颜色](https://github.com/router-for-me/EasyCLIProxyAPI/blob/v0.3.11/src/styles.css) 一致：剩余 `>30%` 为绿色，`>10% 且 ≤30%` 为琥珀色，`≤10%` 为红色，未知及过期缓存为灰色。胶囊边框、文字、填充和弹窗进度条共用规则，并随系统深浅外观切换对应色值；胶囊保持 46×18pt。

重置时间、获取时间与观察时间统一使用冒号，并附带“多久后”/“多久前”，按天、小时、分钟、秒取整显示。只在弹窗打开时每秒更新相对时间文案，不触发额度请求或重建下拉控件。

刷新入口为原生刷新图标；macOS 15 及以上在额度请求期间顺时针旋转，并禁用重复点击。完成或失败后停止旋转，弹窗隐藏时暂停动效；遵循系统“减少动态效果”设置，保留悬浮提示和辅助功能标签。

右键点击菜单栏胶囊（或按住 Control 点击）显示仅含“退出”的原生菜单；若额度弹窗已展开，先关闭弹窗再显示菜单。刷新图标仍在弹窗内，弹窗底部不再显示退出按钮及分隔线。普通左键仍只负责展开和关闭额度弹窗。

应用图标使用石墨银灰方形底与双层额度环，不含文字或百分号；[图标源文件及生成说明](assets/README.md)位于 `assets/`。构建时将多尺寸 `QuotaMenubar.icns` 写入应用资源并声明 `CFBundleIconFile`，签名后整体嵌入插件；菜单栏实时百分比胶囊不受影响。

macOS 27 使用系统菜单栏展开会话回调，关闭弹窗时同步结束系统会话；旧版 macOS 保留按钮切换。展开与关闭动画期间记录最后一次开关意图，动画完成后继续执行，避免关闭后的下一次点击失效。外部点击监听仅作用于本轮弹窗，过期回调不会关闭新打开的弹窗。

```sh
python3 scripts/build_release.py --arch arm64
"build/arm64/Codex Quota Menubar.app/Contents/MacOS/QuotaMenubar" --self-test
python3 menubar/runtime.py status
```

Python runtime 仅是开发构建/诊断工具，商店安装无需 Python。发布脚本编译三份 Swift 源码，链接系统 SQLite，签名完整应用后嵌入动态库。单实例锁、PID 归属、版本握手、主动退出信号及托管 EOF/禁用检测限制生命周期。安装与发布方式见[仓库说明](../README.md)。
