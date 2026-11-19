# dsh-task-chime-badge

[![ci](https://github.com/todrinkcho/dsh-task-chime-badge/actions/workflows/ci.yml/badge.svg)](https://github.com/todrinkcho/dsh-task-chime-badge/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/dsh-task-chime-badge.svg)](https://www.npmjs.com/package/dsh-task-chime-badge)

给 DeepSeek Harness 的 Windows 桌面端加一层「跑完了叫我」：任务跑完响一声，并在 Harness 的任务栏按钮上留一个彩色圆点，直到你看过为止。

| 时机 | 声音 | 任务栏按钮 |
| --- | --- | --- |
| 一轮任务跑完，并且没有别的 agent 还在跑 | 一声「叮」 | 绿色圆点 |
| agent 弹问题 / 审批，等你回答 | 两声「叮咚」 | 黄色圆点 |
| 你把窗口切到前台（= 已读） | — | 圆点消失；问题若还没答，切走后黄点会再出现 |

圆点是 Windows 的**任务栏按钮叠加图标**（`ITaskbarList3::SetOverlayIcon`）。Windows 11 把它画在按钮图标的右上角，所以看起来像一个「绿色消息泡」；位置由 Explorer 决定，应用无法微调。Windows 没有「未读数」这类 API，所以它是圆点而不是数字。

IM 机器人（微信 / 飞书 / 钉钉等，经 dsh-im 接入）发起的回复**不提醒**：否则机器人在群里一直回，你的电脑就一直响。桌面窗口里发起的任务，或被目标轮次 / 子代理 / 后台任务唤醒的那一轮，照常提醒。

只在 Windows 桌面端有效——角标需要桌面壳真实的任务栏按钮；用浏览器打开 `dsh web` 时声音照旧会响，但没有按钮可打角标。

## 安装

要求：Windows 10/11 + DeepSeek Harness 桌面端；Node 18+（随 DSH 安装）。无需管理员权限、无需构建、无第三方依赖。

**用 npm**（不用下载）：在 **插件** 里装名为 `dsh-task-chime-badge` 的 bundle，或者让 agent 用 `plugin_manager` 的 `install_bundle`、target 填这个名字。（走 npmmirror 这类镜像的话，新版本要等镜像同步几分钟。）

**用 Release 的 zip**：到 [Releases](https://github.com/todrinkcho/dsh-task-chime-badge/releases/latest) 下载 `dsh-task-chime-badge-1.0.0.zip` 解压（里面就是一个 `dsh-task-chime-badge/` 目录），然后把这个目录当 bundle 装上：

- **界面**：**插件** → **添加插件**，选中该目录；
- **让 agent 装**：用 `plugin_manager` 的 `install_bundle`，target 填该目录的绝对路径。

**用 git**：`git clone https://github.com/todrinkcho/dsh-task-chime-badge.git`，然后按上面两种方式之一装。

- **界面**：**插件**（Plugins）→ **添加插件**，选中 clone 下来的目录；
- **让 agent 装**：让它用 `plugin_manager` 的 `install_bundle`，target 填这个目录的绝对路径。

到 **插件** 里确认「任务完成提醒与消息泡」这一行已启用，然后发一轮任务、切到别的窗口，就能看到绿点。这是一个只有 Host 半边的 bundle：npm 上没有包，clone 下来的目录本身就是包（`dsh.bundle.patch` 指向 `cordis.patch.yml`）。

## 配置

改 `cordis.patch.yml` 的 `config`（在插件管理面板里改也行）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | `true` | 总开关 |
| `chimeOnDone` | `true` | 完成时是否响 |
| `chimeOnAsk` | `true` | 需要你回答时是否响 |
| `watchApprovals` | `true` | 审批弹窗是否也算「需要你回答」 |
| `ignoreImTurns` | `true` | IM 机器人发起的那一轮跑完时不提醒（不响、不亮绿点） |
| `imRpcIdPrefixes` | 见下 | 判定「来自 IM」的 rpcId 前缀，默认覆盖 dsh-im 全部渠道 |
| `quietMs` | `900` | 最后一个 agent 空闲后等多久再判定「跑完」，避免连续工具调用误报 |
| `processName` | `DeepSeek Harness` | 要打角标的窗口进程名。改了安装目录名才需要动 |
| `helperPollMs` | `350` | 助手轮询间隔（毫秒），越小越跟手、越费电 |
| `debug` | `true` | 是否写下面的日志 |

`imRpcIdPrefixes` 默认：`feishu`、`weixin`、`dingtalk`、`wecomapp`、`wecom`、`qq`、`slack`、`telegram`、`discord`、`whatsapp`、`imessage`、`matrix`、`email`、`office`、`im`。桌面窗口发起的 prompt 用裸 UUID，不带渠道前缀，所以不会被误判。

## 日志

都在 `%USERPROFILE%\.dsh\cache\task-chime-badge\`，超过 256 KB 自动清空：

- `plugin.log`：Host 侧判断过程（哪个 agent 开始/结束、什么时候判定「跑完」、命令序号）；
- `helper.log`：助手侧实际动作（找到哪个窗口、打了什么角标、声音是否播放成功、焦点变化）。

把 `debug` 改成 `false` 就不再写。

## 实现方式

- `index.js`（Host 半边）监听四个接口：
  - `agent/status` 收集所有 running 的 agent，最后一个转 idle 且静默 `quietMs` 后判定「这一轮跑完了」；
  - `session/event` 跟 `turn/start` / `user/message` / `turn/end`，记下这一轮里每条真实 prompt 的 `source.rpcId`，于是「整轮都来自 IM」时能跳过提醒；轮次里没有 prompt（目标轮次、子代理、后台任务唤醒）照常提醒；
  - `user-questions/request` / `approval/request` 在 `next()` 前后包一层：进入等待亮黄点，答完/取消后清掉。
- 每次状态变化只写一个 JSON 命令文件 `%USERPROFILE%\.dsh\cache\task-chime-badge\command.json`，带时间戳递增的 `seq`，先写临时文件再改名，读者不会读到半截。
- `helper/taskbar-helper.ps1` 是一个隐藏的常驻 PowerShell 进程：轮询命令文件，用 COM 接口 `ITaskbarList3` 打叠加图标，用 `winmm!PlaySound` 播 WAV，并监视前台窗口；宿主进程一消失它自己退出。没有 socket、不联网、不要管理员权限、不动系统提示音。
- 两个声音是合成出来的 WAV（`assets/done.wav`、`assets/ask.wav`），所以既不依赖也不修改你的 Windows 声音方案。

## 限制

- 只在 Windows 桌面端有效。`ITaskbarList3` 需要真实的任务栏按钮，浏览器标签页没有。
- 是叠加圆点，不是未读数——Windows 没有任务栏角标计数 API。
- 窗口在前台时不显示圆点（等于已读），但声音照响。想「看到」圆点，请在任务跑着的时候切到别的窗口。
- 有全屏应用（浏览器按 F11、游戏）时整个任务栏被盖住，圆点看不见；退出全屏即恢复。
- 角标只打在任务栏按钮上：窗口缩进托盘、或任务栏被隐藏时，没有按钮可打。
- Explorer 重启能自愈（COM 对象失败后重建）；但宿主重启后才会换掉旧的助手进程。

## 排障

| 现象 | 先看 |
| --- | --- |
| 没声音也没圆点 | `plugin.log`：这一轮有没有被判定为「跑完」？`enabled` 是不是 true？ |
| 有声音但一直没有圆点 | `helper.log` 里有没有 `no taskbar window`：窗口是否缩进了托盘、任务栏是否被隐藏、`processName` 是否对 |
| 一轮响两次 | 装了两份插件，两个助手都在跑 |
| 完全没日志 | 插件没激活：看 **插件** 里的那一行，然后重启应用 |

## 卸载

在 **插件** 里停用或删除这个 bundle。助手会随宿主进程一起退出，除了 `%USERPROFILE%\.dsh\cache\task-chime-badge\` 下两个日志文件（可以直接删）不留任何东西。

## 许可

[MIT](LICENSE)
