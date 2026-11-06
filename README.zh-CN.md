# Android File Transfer (Swift)

一个原生 macOS 端 MTP 客户端，通过 USB 在 Mac 与 Android 设备之间浏览和传输文件，完全使用 Swift、SwiftUI 与 Apple IOUSBHost 框架实现。

[English](README.md) · **简体中文**

## 项目简介

Android File Transfer (Swift) 通过 Apple 的 `IOUSBHost` 框架直接与 Android 设备通信 —— 不依赖 Go 运行时、libusb、`kalam.dylib`，也没有 FFI/JSON 桥。MTP 协议栈与 SwiftUI 界面均在本仓库中实现。

> 本项目为独立实现，与 Google 的 Android File Transfer 应用无关联。

## 功能

- 原生 SwiftUI 界面，侧边栏 + 双栏（本地 / 设备）
- 浏览内部存储与 SD 卡，支持分类存储
- 上传、下载文件及嵌套文件夹，递归汇总进度
- 持久化多任务传输队列，重启应用后仍可恢复
- 暂停、继续、取消、重试，以及每个任务的进度显示
- 冲突处理：替换、保留两者或取消
- 批量删除，支持递归删除文件夹
- 从 Finder 拖入设备上传，从设备拖出到 Finder
- 本地与设备文件的 Quick Look 预览
- IOKit 热插拔通知与自动重连
- 英文与简体中文，支持实时切换
- 首次启动引导、原生设置、文件访问权限引导
- 完全磁盘访问权限辅助，并提供隐私设置快捷入口

## 环境要求

- macOS 15 或更高版本
- Swift 6 工具链（Xcode 26 或更高版本）
- 支持 MTP 的 Android 设备（连接后选择“文件传输 / MTP”）

## 快速开始

```sh
git clone https://github.com/umbrella22/Android-File-Transfer.git
cd Android-File-Transfer

swift build
swift test          # 18 个测试
./Scripts/build-app.sh debug --install
open "$HOME/Applications/Android File Transfer.app"
```

应用需要从内置磁盘运行。直接从外接卷或项目卷运行 bundle 可能触发 macOS 隐私授权提示；`--install` 会先将其复制到 `~/Applications`。

## 目录结构

```
Sources/AndroidFileTransferKit/    MTP/PTP 协议栈与 USB 传输层
Sources/AndroidFileTransferApp/    SwiftUI macOS 应用
AppBundle/                         Info.plist、应用图标、中英文元数据
Scripts/build-app.sh               构建、复制资源、ad-hoc 签名、安装
Tests/AndroidFileTransferKitTests/ 编解码、数据集与 mock 会话测试
```

## 架构

`AndroidFileTransferKit` 分为三层：

- **PTP** — 容器编解码、MTP UTF-16 字符串、数据集类型。
- **USB** — `USBTransport` 字节管道抽象；`IOUSBHostTransport` 是生产实现。
- **MTP** — `MTPDeviceSession` actor，通过 FIFO 总线门串行化每个事务。

应用只依赖传输抽象，因此新增其他 USB 后端时无需修改 MTP 或 UI 层。

## 当前状态

- 18 个单元测试全部通过（PTP 编解码、数据集、mock MTP 会话）。
- 已在 nubia Z70 Ultra（MTP 6/1/1）上完成硬件验证，包括 4.1 GB 上传/下载往返，SHA-256 校验一致。
- 待验证：传输中物理拔插、睡眠/唤醒，以及更多厂商设备。

## 已知限制

- 暂停/继续会从头重新执行当前任务，不支持字节级续传。
- 拖出仅支持单个文件或单个文件夹，不支持多选。
- 不支持上传符号链接本身。
- 仅提供英文与简体中文本地化。
- 当前为 ad-hoc 签名，尚未配置公证与 App Store 打包。
