# 兼容层工作原理

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

## 4. 数据流

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

## 5. 自动发现

没有指定主机名时，安装器会通过 DNS-SD 解析：

```text
Canon G3010 series._printer._tcp.local.
```

然后从服务记录中提取打印机主机名。也可以用 `--host` 参数手动指定。

## 6. 默认设置

安装器使用 G3000 与 G3010 都具备的保守设置：

- A4；
- 普通纸；
- 彩色；
- 正常质量；
- 后部/主进纸器；
- 单面打印。

照片纸、灰度、无边距和质量选项仍可在 macOS 打印窗口中选择。

## 7. 安全与隐私

- 自动发现只发生在本地局域网；
- 文档不会发送给本项目或任何云端服务；
- 打印数据从 Mac 直接传输给打印机；
- 脚本不收集遥测数据；
- 本项目不会关闭 Gatekeeper 或系统完整性保护。

## 8. 后续方向

- 编写不依赖佳能 G3000 包的原生开源 BJRaster3 渲染器；
- USB 传输；
- ICA 或 SANE 兼容扫描；
- Developer ID 签名和公证；
- 在更多 macOS 和固件版本上自动测试。
