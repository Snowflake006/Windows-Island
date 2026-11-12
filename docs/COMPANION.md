# Windows Island · 桌面状态融合

本次保留Windows Island的原生 Rust / egui 界面、五款皮肤、刘海／胶囊、吉祥物和三边停靠，把原灵动岛的状态能力纳入同一套布局与交互。原来的 WPF 岛体没有移植。

- 收起时：蓝色 Windows 徽标、智能体品牌图标与状态灯、VPN 延迟时钟；空闲时显示今天未完成的待办，六秒轮播。
- 后台任务：工作时保留图标，真实完成后停留三秒再让位给待办；新任务会立即取消完成停留。
- 展开时：原 AI 页面改为“智能体”，包含“运行状态”和“账户额度”。运行列表可分页，点击查看状态来源、输入／缓存／输出 Token、上下文和日志中的额度快照，可唤起应用窗口。
- 解锁：Windows 会话解锁事件触发岛内短动画。面容提示使用本机 Windows BioFeedback 字形逐帧绘制；PIN 等方式使用Windows 原版蓝色徽标（可切换中国传媒大学校徽）。注册表提供的方式仅是最近登录方式提示，不用于验证身份。
- 设置 → 页面管理：在“常驻排列”中分别拖动“徽标”和“智能体 / 待办”，调整它与时间、电量、吉祥物、额度等组件的位置；旧版六组件排序自动兼容。
- “徽标与智能体”中可分别设置Windows 原版蓝色徽标（可切换中国传媒大学校徽）、智能体显示、状态文字、空闲待办、图标数量（1–6）与完成停留（1–10 秒）。
- “连接与解锁”中可设置 VPN 提示、彩色时间胶囊的显示开关、解锁问候及停留时长（1–8 秒）。修改自动保存。
- 其余功能：继续使用Windows Island原有待办、通知、专注计时、文件置物、剪贴板、邮箱、日程、开机启动和 AI 账户连接，不增加一套重复页面。

## 状态与数据

支持 Codex / ChatGPT、DeepSeek Harness、豆包、WorkBuddy、Claude、Cursor、OpenClaw、Ollama、Gemini。在线仅表示应用存在；工作状态来自本机日志生命周期或可读的窗口控件。读取不到时保留“待确认”，不按 CPU、内存或沉默时间猜测完成。ChatGPT / Gemini 隐藏窗口的控件可能被冻结，这种情况不能保证后台完成即时可见。

VPN 沿用原应用的 Clash Verge / Mihomo 本机命名管道适配，检查系统代理、TUN、模式和默认出口，通过当前节点访问 gstatic 的 generate_204 测延迟。≤150ms 绿色、超过150至300ms 黄色、更高或测速超时红色；这不是所有分流网站的实际延迟。

状态助手和 Python 嵌入运行时随可执行文件一起打包，首次运行释放到 `%APPDATA%\Daozai\companion-runtime`，状态缓存位于 `%APPDATA%\Daozai\companion`。无需运行原 `D:\灵动岛`，也无需另装 Python。助手以无窗口方式运行，跟随Windows Island退出；现有账户连接和数据目录继续保留。

本地日志仅提取状态和数值，不展示提示词、工具参数或对话正文；状态不上传到额外服务器。账户额度页面原有的提供商连接规则继续适用。用量是已读取的会话累计，缓存包含在输入总量中，不重复计入总量；没有额度快照时不估算余额。

## 验证入口

- `cargo check --locked --all-targets --features record`
- `cargo test --locked --lib companion::tests -- --test-threads=1`
- `python -m unittest discover -s src/companion -p test_telemetry.py`
- `powershell -NoProfile -ExecutionPolicy Bypass -File src/companion/Test-AgentStatus.ps1`
- `powershell -NoProfile -ExecutionPolicy Bypass -File src/companion/Test-AgentProcesses.ps1`
- `powershell -NoProfile -STA -ExecutionPolicy Bypass -File src/companion/DesktopAgentMonitor.ps1 -SelfTest`
- `cargo run --example companion-preview -- <预览输出目录>`：用真实绘制代码生成不同皮肤／停靠的静态预览，不启动状态助手。

Python 运行时的许可随嵌入包保留；智能体品牌图标来源见 `assets/agents/SOURCES.md`。


徽标与智能体 / 待办使用独立的位置设置；旧版排列会自动保留，并在智能体旁补上独立徽标。设置与主程序不再共用图标绝对位置动画，避免串位。


VPN 状态参考 Apple 状态栏，使用整块明亮时间胶囊，无独立圆点或光晕：绿色表示低延迟、黄色表示较高延迟、红色表示很高延迟；关闭胶囊底色后恢复普通时间。智能体区域按标签的实际字宽收紧；多个图标按需增加占位，并跟随岛的弹簧动画展开。待办文字按内容占位，长内容自动省略。
