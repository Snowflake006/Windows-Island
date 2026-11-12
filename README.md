# Windows Island

轻盈的 Windows 桌面信息岛，将智能体状态、音乐、通知和日常任务放到桌面边缘。

[下载 Windows x64](https://github.com/Snowflake006/Windows-Island/releases/latest) · [完整功能](docs/FEATURES.md) · [使用指南](docs/USAGE.md) · [反馈问题](https://github.com/Snowflake006/Windows-Island/issues)

> 本软件基于 **Renly1994** 的开源作品 **[岛仔 Daozai](https://github.com/Renly1994/xiaotang-daozai)** 进行二次开发。致敬原创，感谢原作者与贡献者。保留原项目 MIT 版权声明与第三方许可。

## 功能

| 类别 | 能力 |
| --- | --- |
| 智能体状态 | 多智能体图标、思考 / 工具 / 完成等状态、完成停留、Token 与上下文快照、窗口唤起 |
| 紧凑布局 | 按实际文字宽度收紧，内容增多时弹性展开；徽标与智能体 / 待办分别拖动 |
| 徽标与解锁 | 精致 Windows 原版蓝色徽标 / 中国传媒大学校徽切换，Windows 会话解锁问候与面容动画 |
| VPN 时间胶囊 | 明亮的整块彩色时间胶囊，无独立圆点；蓝色流畅、橙色偏慢、红色高延迟 |
| 桌面外观 | 五款皮肤，刘海 / 胶囊，顶部 / 左右停靠，多显示器，大小位置、极简和自动避让 |
| 音乐与歌词 | 播放 / 暂停、切歌、音量、进度、封面、同步歌词、岛上单行歌词与偏移调整 |
| 专注与饮水 | 专注 / 休息计时、饮水目标、每次饮水量、提醒间隔与时段、记录撤销 |
| 待办与日程 | 单次 / 每天 / 每周重复待办，空闲任务轮播，月历、时间线、会议与日程提醒 |
| 文件与剪贴板 | 文件置物架、拖入拖出、打开与定位，文字历史、固定与再次复制 |
| 通知与邮箱 | 系统通知、微信 / QQ 未读、邮件验证码、邮件正文、已读 / 删除 / 恢复、邮件会议邀请 |
| 日历连接 | 飞书、钉钉、企业微信、iCloud、CalDAV、Exchange ActiveSync 与 ICS 导入 |
| AI 账户额度 | Codex、Claude、Kimi、Grok Bot、Gemini、ZCode、WorkBuddy、DeepSeek；多账号、余额和重置时间 |
| 系统状态 | 电量、充电、网络、音量、蓝牙、大写锁定与输入语言提示 |
| 账户与备份 | GitHub 连接、个人偏好手动备份 / 恢复；微信和 QQ 待接入 |
| 本地更新 | 关于页检查本仓库正式版，立即更新、进度显示、SHA-256 校验、替换后重启并保留数据 |

详细操作、支持范围与限制见 [完整功能列表](docs/FEATURES.md) 和 [桌面状态说明](docs/COMPANION.md)。

## 下载与更新

在 [Releases](https://github.com/Snowflake006/Windows-Island/releases/latest) 下载 `Windows-Island-v版本号-windows-x64.zip`，完整解压后运行 `Windows Island.exe`。无需额外安装 Python。

后续进入 **设置 → 关于 → 检查更新 → 立即更新**。软件直接从本仓库下载并验证更新包，自动重启；不必手动前往 GitHub 下载覆盖。便携版与已安装版都会更新当前正在使用的程序位置。

**Windows 10 / 11 x64**。程序没有商业代码签名；若系统提示未知发布者，可对照发布页的 `SHA256SUMS.txt` 核验来源。

## 本地数据

沿用 `%APPDATA%\Daozai`，以兼容旧版设置、待办和记录。邮箱等凭据沿用 Windows 凭据管理器 / DPAPI；桌面智能体状态读取本机数据，不上传会话正文。邮箱、日历、歌词和更新等联网功能访问相应服务。见 [隐私说明](docs/PRIVACY.md)。

## 从源码构建

安装 Rust stable、Visual C++ 构建工具和 Windows SDK 后：

```powershell
cargo build --locked --release --bin daozai
.\target\release\daozai.exe
```

本地构建产物保留内部名称 `daozai` 以兼容原工程；正式发布文件名为 `Windows Island.exe`。

```powershell
.\scripts\package-island.ps1 -Executable .\target\release\daozai.exe
```

推送 `v版本号` 标签可通过 GitHub Actions 构建并发布；版本号需同时更新 Cargo.toml、Cargo.lock 和 app.rc。更新器只接受本仓库正式发布、版本更高且具有有效 SHA-256 摘要的对应 Windows x64 包。

## 致敬原创与许可

- 原创作者：**Renly1994**；原项目：[Renly1994/xiaotang-daozai](https://github.com/Renly1994/xiaotang-daozai)。
- 本二次开发版：[Snowflake006/Windows-Island](https://github.com/Snowflake006/Windows-Island)。
- 原项目采用 [MIT License](LICENSE)，版权声明完整保留。
- 设备图标：Solar Icons / 480 Design，CC BY 4.0。其余资源许可见 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)。品牌标识归各自权利人所有。
