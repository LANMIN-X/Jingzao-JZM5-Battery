# 京东京造 JZM5 电量

让 macOS 电池小组件和 [AirBattery](https://github.com/lihaoyun6/AirBattery) 显示京东京造 JZM5 的 2.4G 模式电量。

程序直接读取接收器的私有 HID 电量报告，每分钟更新一次电量和充电状态，并在菜单栏提供权限状态、开机启动和退出选项。它不会修改 AirBattery，也不会写入 AirBattery 的容器目录。

![macOS 电池小组件显示京东京造 JZM5 电量](assets/macos-battery-widgets.png)

## 下载与启动

1. 从 Releases 下载 `JZM5BatteryTray.app.zip`，解压后把应用拖到“应用程序”。
2. 本项目没有 Apple Developer ID 签名和公证。若 macOS 提示应用已损坏或无法验证开发者，只移除本应用的下载隔离属性：

   ```bash
   sudo xattr -dr com.apple.quarantine /Applications/JZM5BatteryTray.app
   ```

3. 启动应用，点击菜单栏鼠标图标里的“输入监控授权…”，再到“系统设置 → 隐私与安全性 → 输入监控”允许“京东京造 JZM5 电量”。授权后重新启动应用。

不要使用 `spctl --master-disable` 全局关闭 Gatekeeper。

## AirBattery Nearcast

AirBattery 不是必需的；macOS 电池小组件可由本程序独立更新。需要同步到 AirBattery 时：

1. 在 AirBattery 设置中开启 Nearcast。
2. 在终端运行一次下面的命令，把 AirBattery 的 Nearcast 群组 ID 写入本程序自己的偏好设置：

   ```bash
   defaults write local.jzm5.batterytray nearcastGroupID \
     "$(defaults read com.lihaoyun6.AirBattery ncGroupID)"
   ```

3. 重新启动 `JZM5BatteryTray.app`，并在 macOS 询问时允许其访问本地网络。

群组 ID 不会写入应用包或上传到网络。AirBattery 重置群组 ID、重新安装或换 Mac 后，需要重新执行上述命令。

## 注意事项

- 仅适配京东京造 JZM5 的 2.4G 接收器 `VID 0x362D / PID 0xD107`，不适用于蓝牙模式或其他型号。
- 鼠标必须已与接收器配对；网页驱动运行时可能占用 HID 接口，测试前请关闭相关页面。
- 应用需要“输入监控”权限读取 HID 报告；Nearcast 还需要“本地网络”权限。
- 应用启动时立即查询一次，之后每 60 秒查询。读取失败时保留上一次有效电量，不会发布假 `0%`。
- 应用退出后，macOS 电源项会消失；AirBattery 会收到离线状态，但其界面或小组件可能要等下一次时间线刷新才消失。
- 系统电池小组件的刷新由 macOS 调度，显示可能比真实电量晚一个刷新周期。
- 系统电源项使用 macOS 的非公开 IOKit 接口，未来系统版本可能改变行为。
- Release 为 Apple Silicon（arm64）版本。Intel Mac 可从源码自行构建。

## 从源码构建

需要 macOS 13 或更高版本及 Xcode Command Line Tools：

```bash
./build.sh
open dist/JZM5BatteryTray.app
```

构建脚本使用 ad-hoc 签名，不需要开发者证书。产物位于 `dist/JZM5BatteryTray.app`。

## 工作原理

程序在接收器的 `Usage Page 0x008C / Usage 0x01` 接口发送 Output Report `0xB3 + 0x06`，从 Input Report `0xB4` 的第 19 字节解析电量。随后将电量发布为 macOS Accessory Power Source，并可选通过 AirBattery Nearcast 在本机同步。

## Contributors

- LANMIN-X
- OpenAI Codex：协助协议分析、macOS 桥接实现与文档整理
