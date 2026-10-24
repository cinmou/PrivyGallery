# App Store 创意素材

当前选用的成图；上传与审核状态以 App Store Connect 为准。

| 文件 | 用途 | 尺寸 |
| --- | --- | --- |
| [Header.png](Header.png) | 无文字标题图，各语言共用 | 3840 × 1646 |
| [Search-zh-Hans.png](Search-zh-Hans.png) | 简体中文搜索结果图 | 3840 × 2560 |
| [Search-en.png](Search-en.png) | 英文搜索结果图 | 3840 × 2560 |

标题图采用蜡笔画风，照片沿下凹弧线进入保险箱，上方两段蓝色短笔触、下方一段淡黄色短笔触；左上角留出系统控件空间。使用内置绘图工具润色并缩放导出，没有独立的矢量源文件。

搜索图由 HTML 排版，Logo 与名称居中对齐；设备保持正向，iPhone 位于最前层。带框截图由用户从 Figma 导出，界面保持原样，中文与英文版本只切换应用名称，截图内的语言不做重绘。

`Source/` 包含两版自包含目录结构的 HTML 和共用图像资源。直接用浏览器打开可查看；用 Chromium 无头模式按 3840 × 2560 视口、设备缩放 1 导出 PNG。标题图直接使用成图。旧设计留在本地，不作为当前发布素材收录。

README 与宣传页共用 `Materials/images/app-icon.png`，来自应用版本信息页的 Icon Composer 27 展示图；后续更换正式图标时同步更新。

验证：三张成图均为 PNG，无透明通道。搜索图是 3:2，标题图是 21:9；实际系统裁切和控件遮挡仍需在 App Store Connect 中预览。

规格与设计参考：[Apple 创意素材规格](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications)、[Apple 素材建议](https://developer.apple.com/app-store/asset-best-practices/)。
