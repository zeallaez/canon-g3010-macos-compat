# 佳能 G3010 macOS 兼容层

[English](README.md) · [工作原理](docs/HOW_IT_WORKS.zh-CN.md) · [开源许可](LICENSE)

这是一个非官方的开源安装器，通过组合以下三部分，让现代 macOS 可以
通过局域网打印到 Canon PIXMA G3010：

- 佳能官方 G3000 macOS CUPS 渲染器；
- G3010 原生兼容的 BJRaster3 打印语言；
- 打印机提供的 LPD `auto` 原始队列。

已在 Apple 芯片 Mac、macOS 26.5.2 和佳能 G3000 CUPS 驱动
16.91.0.0 上测试。

> [!IMPORTANT]
> 本项目不包含佳能软件。使用前必须自行从佳能官网下载并安装官方
> G3000 CUPS 驱动。本项目独立、非官方，与佳能没有隶属、背书或支持关系。

## 功能

- 创建名为 `Canon_G3010` 的系统打印队列；
- 自动发现默认名称为 `Canon G3010 series` 的局域网服务；
- 自动发现失败时可手动指定打印机主机名；
- 默认配置 A4、彩色、普通纸、正常质量和单面打印；
- 可选发送一张 macOS 测试页；
- 提供可逆的卸载脚本和只读诊断工具；
- 可构建成 macOS `.pkg` 安装包。

当前支持打印，不包含扫描功能。

## 环境要求

- macOS 11 或更高版本；
- Canon PIXMA G3010 与 Mac 位于同一局域网；
- 已安装佳能 G3000 series CUPS Printer Driver 16.91.0.0
  或兼容的更新版本；
- macOS 要求授权时需要管理员权限。

请从[佳能官方支持页面](https://asia.canon/en/support/0101155813?model=PIXMA%20G3000)
下载依赖驱动。

兼容安装器会先检查以下文件，存在后才会修改打印队列：

```text
/Library/Printers/PPDs/Contents/Resources/CanonIJG3000series.ppd.gz
```

## 快速使用

### 使用 Release 安装包

1. 安装佳能官方 G3000 CUPS 驱动。
2. 从 GitHub Releases 下载
   `Canon-G3010-macOS-Compat-1.0.0.pkg`。
3. 打开安装包，按照 macOS 安装器提示操作。
4. 打印时选择 `Canon G3010 series (Mac compatibility)`。

当前安装包没有 Developer ID 签名。如果访达阻止打开，请使用下面的
终端命令，不要关闭 Gatekeeper：

```sh
sudo installer \
  -pkg Canon-G3010-macOS-Compat-1.0.0.pkg \
  -target /
```

### 从源码安装

```sh
git clone https://github.com/zeallaez/canon-g3010-macos-compat.git
cd canon-g3010-macos-compat
./src/install.sh --test
```

如果打印机使用了自定义主机名：

```sh
./src/install.sh --host my-printer.local. --test
```

运行 `./src/install.sh --help` 可以查看全部参数。

## 卸载

```sh
./src/uninstall.sh
```

卸载脚本只删除 `Canon_G3010` 打印队列，不会删除佳能官方依赖。

## 诊断

```sh
./scripts/diagnose.sh
```

诊断脚本只读取信息，不修改系统。它会显示 macOS 版本、芯片架构、
佳能依赖、CUPS 队列配置和可见的 G3010 网络服务。

## 工作原理

打印数据路径如下：

```text
macOS 应用程序
      ↓
macOS CUPS 栅格处理
      ↓
佳能官方 G3000 包中的 Raster2CanonIJS 渲染器
      ↓
兼容 BJRaster3 的打印数据
      ↓
LPD 515 端口，"auto" 队列
      ↓
Canon G3010
```

G3010 会广播 IPP 2.0 和 PWG Raster，但 macOS 以 600 dpi 免驱方式发送
测试页时，设备曾返回 `spool-area-full-report` 并停在 0%。改用 G3000
渲染器生成更紧凑的原生数据，再通过 LPD 发送后，测试作业正常完成。

协议细节、设计取舍和限制参见
[工作原理文档](docs/HOW_IT_WORKS.zh-CN.md)。

## 构建

在 macOS 上运行：

```sh
make check
make package
```

产物位于 `dist/`：

- 兼容层 `.pkg` 安装包；
- 源码压缩包；
- `SHA256SUMS` 校验文件。

## 已知限制

- 不包含扫描仪的 ICA/SANE 适配；
- 当前仅实现网络 LPD，未实现 USB 打印；
- 依赖佳能 G3000 渲染器，佳能不保证这种跨型号兼容；
- Apple 已弃用传统 PPD/CUPS 厂商驱动，未来 macOS 可能移除此路径；
- Release 安装包尚未进行 Developer ID 签名和公证。

## 贡献和安全

参见 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。

## 开源许可

本项目原创代码和文档使用 [MIT License](LICENSE)。佳能软件不属于本仓库，
仍受佳能自己的许可约束。详情参见 [NOTICE.md](NOTICE.md)。
