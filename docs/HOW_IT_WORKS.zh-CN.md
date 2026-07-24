# 打印与扫描兼容层工作原理

[English](HOW_IT_WORKS.md)

## 1. 打印机提供的能力

已测试的 G3010 固件版本为 `3.001`，它会广播：

- `/ipp/print` 上的 IPP 1.1 和 2.0；
- 600 dpi、sRGB/灰度的 PWG Raster；
- TCP 515 端口上的 LPD，远端队列名为 `auto`；
- IEEE-1284 设备命令，包括 `BJRaster3`、`NCCe` 和 `IVEC`；
- 彩色、单面、A4/Legal、照片纸、信封和部分无边距尺寸。

打印机不支持 PostScript 或 PCL，因此通用 PostScript/PCL 驱动不能驱动它。

## 2. 为什么没有采用 IPP 免驱方案

测试中，`IPP Everywhere` 队列能够成功建立，macOS 也能读取纸张和颜色能力。
但是打印测试页时，设备返回：

```text
printer-state-reasons = spool-area-full-report
printer-alert-description = Non-critical alert - spool area full
job-media-progress = 0
```

作业持续停在 `processing` 和 0%。这说明 G3010 虽然声明支持 PWG Raster，
但在已测试的 macOS 版本上，无法稳定处理系统生成的 600 dpi 整页栅格流。

## 3. 为什么可以复用 G3000 渲染器

佳能 G3000 macOS 官方安装包包含：

- `CanonIJG3000series.ppd.gz`；
- 同时支持 arm64 和 x86_64 的 CUPS 栅格过滤器 `Raster2CanonIJS`；
- G3000 型号数据库和颜色配置；
- 原生网络与打印机维护组件。

G3010 的设备信息明确报告支持 `BJRaster3`。G3000 过滤器会为相近的打印
引擎生成紧凑的佳能原生栅格数据。把该数据发送到 G3010 的 LPD 原始队列后，
测试作业正常完成，设备恢复空闲且没有告警。

这是经过实机验证的兼容关系，并不是佳能官方提供的兼容保证。

## 4. 打印数据流

```text
文档或图片
    │
    ▼
macOS 打印框架 / CUPS
    │  application/vnd.cups-raster
    ▼
佳能 Raster2CanonIJS
    │  兼容 BJRaster3 的原生数据流
    ▼
macOS LPD 后端
    │  TCP 515，远端队列 "auto"
    ▼
Canon G3010 固件与打印引擎
```

本仓库的开源代码只负责配置和验证这条路径，不复制、不修改、不逆向，
也不再分发佳能二进制文件。

## 5. 扫描协议

G3010 提供了 WSD 设备，其元数据中包含 `wscn:ScanDeviceType`。扫描服务
位于打印机局域网 HTTP 地址：

```text
http://打印机IP:80/wsd/scanservice.cgi
```

WSD Scan 使用 HTTP 上的 SOAP 消息。后端先读取扫描仪元素和配置，再按所选
分辨率、颜色模式和扫描区域创建任务，最后取回图像数据流。

本项目使用开源 `sane-airscan` 后端，在 WSD Scan 协议和标准 SANE API
之间转换。命令行由 `scanimage` 输出文件；macOS 图形应用由本项目的
轻量 eSCL 服务解析任务，再直接调用同一个 `scanimage`/WSD 链路。
整个过程不需要佳能扫描二进制文件、网页管理员密码、USB 连接或云服务。

## 6. 扫描数据流

```text
Apple“图像捕捉”/ macOS 扫描面板
    │  eSCL/AirScan
    ▼
本项目的轻量原生 eSCL 服务
    │  每个任务直接调用 scanimage
    ▼
sane-airscan WSD 后端
    │  局域网 SOAP/HTTP
    ▼
G3010 /wsd/scanservice.cgi
    │
    ▼
返回给 macOS 应用的 JPEG/PNG/PDF
```

命令行模式使用随包提供的原生 `scanimage`，并把 JPEG、PNG 或 TIFF
直接写入用户选择的 Mac 路径。

固定的上游源码版本和仓库中的移植补丁让原生扫描环境可以重复构建，
不需要改动 macOS 系统框架，也不用安装未签名的 ICA 插件。桥接只监听
回环接口，并只读取自动生成的配置文件。

真实设备已经报告并成功使用以下能力：

- 平板扫描；
- 150、300、600 dpi；
- 彩色和灰度；
- 最大扫描范围 215.9 × 296.672 毫米。

## 7. 自动发现

没有指定主机名时，安装器会通过 DNS-SD 解析：

```text
Canon G3010 series._printer._tcp.local.
```

然后从服务记录中提取打印机主机名和真实 UUID。打印队列使用带 UUID 的
DNS-SD URI，因此 IP 变化时打印也会重新解析；也可以用 `--host` 手动指定。

扫描命令会先读取已安装的 CUPS 队列，再尝试相同的 DNS-SD 服务；
`--ip` 可直接跳过发现。命令会生成指向 WSD 扫描端点的
`sane-airscan` 配置，从而避免组播发现并保持运行行为稳定。

图形桥接由 Mac 发布
`Canon G3010 series._uscan._tcp.local.`，TXT 记录中声明 `rs=eSCL`，
专用代理主机 `canon-g3010-bridge.local.` 的端点为
`127.0.0.1:8090`。“图像捕捉”发现 Bonjour 服务后，通过 Mac 回环接口
发送 eSCL 请求。扫描服务复用打印机 `_printer._tcp` 记录中的真实 UUID，
从而让打印和扫描具有相同的多功能设备身份。

用户级登录启动项会在登录后保持桥接和服务记录在线，并定期解析稳定的
`*.local.` 主机名。如果 DHCP 地址发生变化，桥接会更新 WSD 配置并自动重启。

## 8. 默认设置

安装器使用 G3000 与 G3010 都具备的保守设置：

- A4；
- 普通纸；
- 彩色；
- 正常质量；
- 后部/主进纸器；
- 单面打印。

照片纸、灰度、无边距和质量选项仍可在 macOS 打印窗口中选择。

扫描默认使用 A4、300 dpi、彩色和 JPEG。

## 9. 安全与隐私

- 自动发现只发生在本地局域网；
- 文档不会发送给本项目或任何云端服务；
- 打印与扫描数据只在 Mac 和打印机之间直接传输；
- 不使用也不保存打印机网页管理员密码；
- 命令行扫描只写入用户选择的输出路径；
- 图形桥接端口只绑定 `127.0.0.1`；其他局域网设备即使看到 Bonjour 记录，
  也无法连接扫描端点；
- 脚本不收集遥测数据；
- 本项目不会关闭 Gatekeeper 或系统完整性保护。

## 10. 兼容边界

- 编写不依赖佳能 G3000 包的原生开源 BJRaster3 渲染器；
- 原生 macOS ICA 插件（当前图形界面使用系统内置 eSCL/AirScan 客户端）；
- Developer ID 签名和公证；
- 在更多 macOS 和固件版本上自动测试。
