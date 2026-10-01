# View Media Info（媒体信息查看器）

View Media Info 是一款原生 macOS App，用来快速查看照片、视频、音频和动态照片中的实用信息。可从 Finder 直接打开文件，也可在 App 中选择文件，查看格式、尺寸、日期、相机或录音设备、位置以及其他可用的元数据；不会修改文件。

[English README](README.md) · [项目主页](https://jingyuan-zheng.github.io) · [源码](https://github.com/Jingyuan-Zheng/View-Media-Info)

![动态照片的精简信息视图](docs/screenshots/live-photo-summary.png)

## 安装与开始使用

View Media Info 需要 macOS 26 或更高版本。

### 安装 App

1. 从项目的 Releases 页面下载 `Media Information-<版本>.dmg`。
2. 打开 DMG，将 **View Media Info** 拖入 **应用程序**。
3. 打开 **View Media Info**，选择 **文件 → 打开媒体…** 或按 `⌘O`，然后选择照片、视频或音频文件。

本 App 只读取信息，不会编辑、重命名、上传或向媒体文件写回元数据。

### 从 Finder 使用

可选的 Finder 快捷操作让你无需先打开 App，直接查看已选文件。

1. 下载并解压 `View Media Data Quick Action-<版本>.zip`。
2. 双击 **View Media Data.workflow**，然后选择 **安装**。
3. 在 Finder 中按住 Control 点按媒体文件，选择 **快捷操作 → View Media Data**。

快捷操作内含独立的 App 副本，安装在 `~/Library/Services`，与“应用程序”中的 App 相互独立。

### 查看、预览与复制信息

- 首个界面显示关键信息；选择 **详细信息** 可查看完整元数据。
- 选择 **复制结果**，即可复制当前显示的信息。
- 按空格键可打开或关闭 macOS Quick Look；双击图片或动态照片预览可在其中打开。
- 视频和音频封面在可预览时会显示播放按钮。
- 动态照片显示 HEIC 照片本身的尺寸，同时按正确方向播放配套视频。

### 调整设置

选择 **媒体信息 → 设置…** 可改为中文或英文。语言会在下次打开 App 时生效；日期和时间则遵循 Mac 的地区设置。

若 macOS 在首次启动时阻止 App 或工作流，请按住 Control 点按它，选择 **打开**，再确认提示。Release 使用 ad-hoc 签名，未进行公证。

## 示例

### 照片与动态照片

![照片的精简信息视图](docs/screenshots/photo-summary.png)

![HEIC 的完整文件信息](docs/screenshots/heic-details.png)

### 视频

![视频的精简信息视图](docs/screenshots/video-summary.png)

### 音频

![音频的精简信息视图](docs/screenshots/audio-summary.png)

## 详细功能

### 先看重点，按需展开全部信息

每个文件都会先显示便于快速阅读的精简信息：预览、最关键的尺寸或时长，以及该媒体类型最有用的字段。选择 **详细信息** 可展开按文件、技术参数、相机、录音、日期和位置分组的内容。**复制结果** 可复制当前显示的信息，方便粘贴到消息、笔记或问题报告中。

### 照片

- 显示格式、扩展名、MIME／容器信息、文件大小、存储像素宽高、像素数、位深、颜色信息、方向，以及可用的 XMP／IPTC 数据。
- 在缩略图旁用尺寸图展示图片比例与宽高，可快速识别横图、竖图及高分辨率图片。
- 读取可用的相机与镜头信息：制造商、型号、镜头名称、焦距及范围、光圈、快门、ISO、曝光设置和拍摄日期。
- 显示 GPS 坐标，并在 macOS 可查询时解析为地点名称；无法查询时，详细信息中仍保留原始坐标。

### Live Photo 与动态照片

- 通过同一目录中 HEIC 与配套视频的 `ContentIdentifier` 匹配识别 Apple Live Photo。
- 支持常见 Android 动态照片标记及内嵌视频载荷。
- 循环播放动态部分，同时始终显示静态照片本身的尺寸与像素数。
- 遵循配套视频的显示旋转信息，竖幅动态画面会以正确方向完整显示，不会被裁切。

### 视频

- 显示视频缩略图，可通过 Quick Look 预览；尺寸图会展示存储宽高、像素数和帧率。
- 在文件包含相关数据时，读取时长、编码、码率、容器格式、创建／拍摄日期、设备和位置。
- 同时展示可用的音频流参数，例如编码、码率、采样率和声道数。

### 音频

- 显示内嵌专辑封面；无封面时显示原生系统占位图标。
- 读取可用的标题、艺术家、专辑、专辑艺术家、作曲、音轨及碟号、年份、流派和备注。
- 显示时长、文件大小、格式、编码、码率、采样率、位深和声道布局。
- macOS 能够播放时，封面上会显示预览播放按钮。

### 原生 macOS 体验与隐私

- 使用 Quick Look 预览，使用标准 macOS About 面板显示 App 与版本信息。
- 支持中文和英文：首次启动遵循 macOS；在设置中选择语言后于下次启动生效。
- 只读取媒体，不改动文件，不保存元数据数据库，也不上传媒体。仅在需要地点名称时通过 Apple 系统服务进行反向地理编码。

文件选择器可选择图片、视频和音频。实际可读取的格式取决于 macOS 及已安装的信息读取工具；常见 HEIC、JPEG、PNG、MOV、MP4、MP3、M4A、FLAC、WAV、AIFF 等格式都已支持。

## 运行要求与信息读取工具

- **ExifTool** 是读取图片和音频元数据所必需的工具。App 会在 `/opt/homebrew/bin`、`/usr/local/bin`、`/usr/bin` 中查找它。
- **ffprobe** 不是必需，但可提供更完整的视频和音频流信息。App 会在 `/opt/homebrew/bin` 和 `/usr/local/bin` 中查找它。

如果你使用 Homebrew，可一次安装两者：

```sh
brew install exiftool ffmpeg
```

位置名称仅会在需要时通过 Apple 系统服务解析；无法查询时，App 会显示原始坐标。

## 关于

在 **媒体信息 → 关于媒体信息** 中可打开原生 macOS About 面板，查看 App 图标和版本，以及作者、项目主页、源码仓库和 MIT 许可证链接。

## 构建与发布

无需 Xcode，即可构建独立 App：

```sh
./build_app.sh
```

脚本会以 `STANDALONE_MEDIA_INFO` 编译、进行本地 ad-hoc 签名与验证，并写出 `build/View Media Info.app.zip`。

将 [Dmg Maker](../Dmg%20Maker) 放在本仓库同级目录后，可生成两种发布文件：

```sh
./scripts/package_release.sh
```

它会在 `release/` 中生成由 Dmg Maker 打包的独立 App DMG，以及包含可安装 Finder 快捷操作的 ZIP。

## 项目结构

- `Sources/ViewMediaInfo/main.swift`：应用源码。
- `Resources/`：App 图标与菜单本地化资源。
- `Info.plist`：包信息。
- `build_app.sh`：独立构建脚本。
- `Workflow/`：Finder 快捷操作模板；打包时加入已编译的 App。
- `scripts/package_release.sh`：发布打包脚本。

信息通过 ExifTool、ffprobe、ImageIO、AVFoundation、Quick Look、Core Location 和 MapKit 读取。所有解析均为只读；仅对异常旧编码元数据文本进行针对性恢复。

## 许可证

本项目使用 [MIT 许可证](LICENSE)。
