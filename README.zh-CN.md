# View Media Info（媒体信息查看器）

这是一个原生 macOS 工具，用于查看图片、视频、音频和动态照片中的实用信息。它可以由 Finder／快捷指令传入媒体文件启动，也可以单独打开后通过 **文件 → 打开媒体…**（`⌘O`）选择文件。

[English README](README.md)

项目主页：[jingyuan-zheng.github.io](https://jingyuan-zheng.github.io) · 源码：[GitHub](https://github.com/Jingyuan-Zheng/View-Media-Info)

## 主要功能

- 默认展示最重要的信息：格式、文件大小、真实尺寸、拍摄／录音设备、拍摄时间、位置，以及存在时的相机、视频或音频参数。
- 需要时可以展开为完整且易读的媒体信息。
- 按空格键使用 macOS Quick Look 预览；视频与音频封面也可以点击播放按钮，图片与动态照片可以双击展示区域打开预览。
- 通过匹配同目录媒体的 `ContentIdentifier` 识别 Apple Live Photo，并循环播放配套视频；也识别常见 Android 动态照片标记及内嵌视频。
- 显示音乐封面、标题、专辑、艺术家、时长、编码、码率、采样率与声道；没有封面时使用系统图标占位。
- 日期和时间遵循系统格式；支持中文和英文。首次启动按 macOS 语言决定，设置中的语言选择在下一次启动生效。

## 隐私与文件安全

本软件只读取信息，不会编辑、重命名、上传或写回任何媒体文件。位置名称通过 Apple 系统服务按需解析；网络不可用或解析失败时，显示原始经纬度。

## 运行要求

- macOS 26 或更高版本。
- 图片与音频信息需要安装 [ExifTool](https://exiftool.org/)。程序会在 `/opt/homebrew/bin`、`/usr/local/bin`、`/usr/bin` 查找它。
- `ffprobe` 为可选但建议安装，可提供更完整的视频和音频流信息；程序会在 `/opt/homebrew/bin` 与 `/usr/local/bin` 查找它。

文件选择器仅允许图片、视频、音频文件。实际可读取的格式受 macOS 与已安装工具影响；常见 HEIC、JPEG、PNG、MOV、MP4、MP3、M4A、FLAC、WAV、AIFF 等格式都已支持。

## 使用方法

1. 构建或取得 App 后，直接打开，或向它传入一个媒体文件路径。
2. 无文件启动时，使用 **文件 → 打开媒体…** 或 `⌘O`。
3. 精简模式查看关键信息；点按 **详细信息** 查看完整内容；**复制结果** 会复制当前显示的信息。
4. 对图片、视频、音频或动态照片按空格键，可显示或关闭 Quick Look。

## 关于

在 **媒体信息 → 关于媒体信息** 中，可打开 macOS 原生的 About 面板。面板会显示 App 的图标和版本，并提供作者、项目主页、GitHub 仓库与 MIT 许可证链接。

## 安装

每个 Release 提供两种独立的安装方式：

### 独立 App

1. 下载 Release 中的 `Media Information-<版本>.dmg`。
2. 打开后，将 **View Media Info** 拖入 **应用程序**。
3. 打开 App；需要查看文件时，选择 **文件 → 打开媒体…**。

### Finder 快捷操作

1. 下载并解压 `View Media Data Quick Action-<版本>.zip`。
2. 双击 **View Media Data.workflow**，然后选择 **安装**。
3. 在 Finder 中选择图片、视频或音频文件；在右键菜单的 **快捷操作 → View Media Data** 中启动。

工作流内含独立的 App 副本，安装位置为 `~/Library/Services`，因此不依赖独立 App。

Release 使用 ad-hoc 签名，未进行公证。若 macOS 在首次启动时阻止，请按住 Control 点按 App 或工作流，选择 **打开**，再确认提示。

## 从源码构建

无需 Xcode：

```sh
./build_app.sh
```

脚本会以 `STANDALONE_MEDIA_INFO` 构建、进行本地 ad-hoc 签名并验证，输出压缩包：

```text
build/View Media Info.app.zip
```

若同级目录中已有 [Dmg Maker](../Dmg%20Maker)，可运行以下命令生成两种发布文件：

```sh
./scripts/package_release.sh
```

它会在 `release/` 中生成独立 App 的 DMG，以及可直接安装的 Finder 快捷操作 ZIP。

## 开发者说明

### 项目结构

- `Sources/ViewMediaInfo/main.swift`：应用源码。
- `Resources/`：应用图标与菜单本地化资源。
- `Info.plist`：应用包信息。
- `build_app.sh`：可复现的独立构建脚本。
- `Workflow/`：Finder 快捷操作模板；打包时会加入编译后的 App。
- `scripts/package_release.sh`：生成 DMG 与可安装工作流 ZIP。

这个项目刻意保持独立：它是另一个工作流辅助程序的可恢复副本，并非链接模块；请保持修改在本仓库内自洽。

### 信息读取方式

- ExifTool 用于图片、音频、XMP、相机、GPS、内嵌封面及 Live Photo 标识符。
- 可用时 `ffprobe` 用于视频与音频流的编码、帧率、码率、采样率、声道等信息。
- Core Location 与 MapKit 用于将坐标解析为位置，不会把结果保存到数据库。
- Quick Look 与 AVFoundation 用于缩略图、预览与动态照片循环播放。

所有解析均为只读。对于设备或软件写入的异常旧编码文本，程序仅进行针对性恢复；正常文本不会被改变。

## 许可证

本项目使用 [MIT 许可证](LICENSE)。
