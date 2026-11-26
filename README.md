<div align="right">简体中文 | <a href="README.en.md">English</a></div>

<div align="center">

<img src="https://raw.githubusercontent.com/DreamDZL/iMusic/main/platforms/ios/docs/iMusicIcon.png" width="140" alt="iMusic" />

# iMusic

**让发现、收藏与聆听，自然流动。**

SwiftUI · 系统 Liquid Glass · LX User API 音源 · LX Sync Server

QQ群：**827131879** · 欢迎加入交流、讨论和反馈 Bug

[![Platform](https://img.shields.io/badge/platform-iOS%2027%2B-blue?logo=apple)](#构建)
[![LGPL-3.0](https://img.shields.io/badge/license-LGPL--3.0-orange)](LICENSE)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-orange)](COPYING)

</div>

iMusic 是基于 [Moumusic](https://github.com/jiajia2222/Moumusic) 开发的原生 iOS 音乐客户端。主页、新发现、电台、资料库和搜索汇聚在熟悉的底部导航中；SwiftUI 和系统 Liquid Glass 让浏览与播放融为一体。

聚合搜索支持 QQ 音乐、网易云音乐、酷我音乐和酷狗音乐。导入 LX User API 音源后，可使用音源解析播放；可用性取决于音源和服务状态。自动模式也可能使用符合条件的已登录平台账号。

QQ 音乐和网易云公开歌单会导入为可编辑的本地副本。对这些副本的编辑只作用于 iMusic 中的副本，不会写回来源平台歌单。本地收藏和兼容歌单可通过自托管的 [LX Sync Server](https://github.com/lyswhut/lx-music-sync-server) 在设备间同步。音源脚本由每台设备分别管理。

登录网易云后，可在“我喜欢的音乐”中把账号红心复制到 iMusic 本地收藏。这是单向导入；之后的改动只保存在 iMusic 并可经 LX Sync 同步。

## 界面预览

<div align="center">
<img src="platforms/ios/docs/promo/01-home.png" width="19%" alt="主页推荐">
<img src="platforms/ios/docs/promo/02-radio.png" width="19%" alt="iMusic 电台">
<img src="platforms/ios/docs/promo/03-search.png" width="19%" alt="聚合搜索">
<img src="platforms/ios/docs/promo/04-player.png" width="19%" alt="全屏播放器">
<img src="platforms/ios/docs/promo/05-lyrics.png" width="19%" alt="同步歌词">
</div>

## 功能

- 原生主页、新发现、电台、资料库和搜索，适配浅色与深色外观
- 歌手、专辑与歌单详情，迷你播放器、全屏播放器、队列和同步歌词
- 原生锁屏与控制中心播放控制
- LX 音源文件/链接导入、检测、启停、切换、导出和删除
- 四平台聚合搜索，同一录音合并来源并支持选择播放来源
- 本地收藏、最近播放和可编辑歌单
- 下载音源明确提供的无 DRM 音频，在资料库离线播放和删除
- QQ 音乐与网易云公开歌单导入为本地副本
- 可选 LX Sync，支持兼容的收藏和歌单
- iOS 27 原生 Liquid Glass；透明度、着色及辅助功能表现跟随 iPhone 系统设置
- 连续装饰动效和音频频谱分析会根据低电量、设备热状态及应用场景活跃状态降载或暂停。后台播放时，进度与歌词游标回调由 0.2 秒降至 1 秒；“新发现”自动刷新间隔至少为 10 分钟

默认 iOS 目标不包含主屏幕小组件、自定义实时活动或 CarPlay 集成。锁屏与灵动岛仅使用 iOS 原生 Now Playing 媒体卡片。

## 音源与同步

进入 **资料库 → 更多 → 管理 LX 音源**，可从文件或 URL 导入音源并检测可用性。仓库不会预置第三方音源地址。

进入 **资料库 → 同步资料库**，填写 LX Sync Server 地址和连接码。客户端同步兼容的收藏与歌单；LX Sync 不同步音源脚本，因此每台设备需要分别导入。对导入的 QQ 音乐和网易云歌单副本进行编辑只保存在 iMusic，不会修改平台歌单。

## 下载与离线播放

从歌曲或播放器的更多菜单选择 **下载**，然后选择歌曲平台及音质。下载先以当前平台和选定的 LX 音源请求所选档位，再尝试其他已启用的音源。同平台候选用尽后，才尝试其他平台能唯一匹配的同一录音。**资料库 → 已下载** 显示实际文件格式、进度及失败原因，可在失败条目上重试原档位或明确选择其他档位，也可离线播放和删除。同一平台的同一条歌曲可更换版本，新的文件通过校验后才替换旧副本。

音频保存在 **文件 → 我的 iPhone → iMusic → Music**，旧下载在升级后移入此处。若从“文件”删除或移出音频，回到 iMusic 后该下载会从资料库移除。下载索引、音源脚本和账号数据仍保存在应用私有位置。

请只下载你有权保存的音频。iMusic 通过现有 LX 音源解析歌曲所属平台的地址，下载需要允许保存的完整 HTTPS 直链。服务端可以将文件作为附件发送，也可以使用内联响应或省略 `Content-Disposition`。服务端明确禁止保存（例如 `X-Download-Allowed: false`）或要求不存储响应（`Cache-Control: no-store`）时，iMusic 会跳过该候选。下载会核对实际文件。支持核验 MP3/AAC 的 128 与 320 kbps 档位（按文件报告的码率判断，无法确认所有 VBR 文件的编码目标），以及 FLAC、ALAC 和整数 PCM 的 16-bit 或 24-bit 及以上无损档位。单文件上限为 250 MB。应用会显示实际编码、码率或位深。Hi-Res 会先尝试 LX 的 `flac24bit`，失败后可改用音源声明支持的 `flac` 请求，再按实际 24-bit 或以上无损验收。母带、全景声、杜比和环绕声的所选档位目前无法核验。当前档位无法取得可保存的文件时，失败条目会区分音源解析、直链传输和文件核验原因。只有流媒体播放地址的音源仍可用于在线播放。

## 构建

iOS 应用需要 macOS 和 Xcode。使用 XcodeGen 生成 iOS App 目标：

```sh
cd platforms/ios/ios
xcodegen generate
xcodebuild -project KumoneIOS.xcodeproj -scheme KumoneIOS -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

2.1-dev 的系统版本为 `2.1.0`，本地默认构建号为 `214`，未签名 IPA 名为 `imusic_ios_2.1-dev.ipa`。

最低部署版本为 iOS 27，适配目标为常规 iPhone 尺寸；当前不提供折叠屏专属布局。

## 项目结构

```text
platforms/ios/
├── Sources/Kumone/
│   ├── Core/API/          目录、歌单导入和 LX 音源桥接
│   ├── Core/Models/       歌曲、歌单和歌词模型
│   ├── Core/Player/       AVPlayer、队列、歌词和系统播放状态
│   ├── Core/Storage/      本地资料库、音源配置和账号数据
│   ├── Core/Sync/         LX Sync 数据模型与客户端
│   ├── DesignSystem/      SwiftUI 主题和 Liquid Glass 辅助组件
│   └── Features/          主页、新发现、广播、资料库、搜索、设置和播放器
├── ios/                   iOS App 壳、测试和 XcodeGen 配置
└── docs/                  产品图标与截图
platforms/android/         保留的上游子树，不属于 iMusic iOS 目标
```

## 上游与许可证

- [Moumusic](https://github.com/jiajia2222/Moumusic)：原生 iOS 工程基础
- [LX Music Mobile](https://github.com/lyswhut/lx-music-mobile)：LX 音源与数据协议参考
- [LX Sync Server](https://github.com/lyswhut/lx-music-sync-server)：兼容的自托管同步服务

上游代码、资源和声明继续遵守各自许可证。详情见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[LICENSE](LICENSE) 和 [COPYING](COPYING)。
