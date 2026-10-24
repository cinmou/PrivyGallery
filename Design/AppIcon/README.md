# PrivyGallery 图标

采用 Nord 的深蓝灰、雾蓝和银白配色，保留相册、双山和三辐保险锁。
素材不画阴影、倒角和高光，立体效果由 Icon Composer 提供。

## 文件

- `Layers/`：8 个 1024 × 1024 SVG，同一坐标系。
- `Exports/`：同名透明 PNG；相册裁切使用 SVG mask，导入 Composer 时使用 PNG。
- `Preview/`：无系统材质的合成图和 32/64/128 小尺寸检查图；
  `composer27-default.png` 是 Composer 27 模式的实际画布截图；
  `system-default.png` 为 Catalyst 构建产物，仅用于打包检查。
- `SecurityFolder/Gallery.icon`：应用实际使用的图标及已调好的材质。
- `Design/archive/Gallery-legacy.icon`：原版归档。

## 构图与颜色

相册范围 x 158–866、y 176–780，外圆角半径 110。
照片内容统一内缩 22，内圆角半径 88，与外框保持同心。
相册底板与锁外圈为同一轮廓，避免重叠边框和错开的圆角。
锁圆心 (512, 700)，外半径 150、内半径 106；旋钮半径 46，辐条宽 26。

配色参考 [Nord](https://www.nordtheme.com/docs/colors-and-palettes/)，
背景由 `#3B4252` 渐变至较深的 `#21252D`；只使用 Composer 填充，系统负责圆角裁切。
`01-background.svg` 仅供无材质预览使用。
相册 `#ECEFF4` → `#D8DEE9`，远山 `#81A1C1` → `#5E81AC`，
近山 `#5E81AC` → `#3B5575`；锁内部 `#2E3440`，辐条 `#8790A3`，
旋钮 `#E5E9F0`，太阳恢复为 `#FFFFFF`。部分渐变端点是针对本图标调整的衍生色。

## Composer 分组（从前到后）

| 组 | 图层 | 材质 |
| --- | --- | --- |
| Lock | 旋钮、辐条、凹槽 | Individual，自动高光，阴影 18%；凹槽关闭效果 |
| Mountains | 近山、远山 | Individual，内侧高光，阴影 5% |
| Album | 太阳、相册底板 | 底板自动高光，阴影 20%；太阳关闭效果 |

各组关闭模糊、折射和半透明，保留蓝色与银白色的对比。
双山使用 Individual，避免 Combined 在重叠区域产生穿透的斜向高光。
锁外圈与相册底板连成一体，旋钮、辐条和深色凹槽独立分层。
`06-lock-ring` 沿用素材文件名，目前承载深色凹槽。

## 重新生成

需要 Python 3、Pillow 和 `/Applications/Chromium.app`。

```sh
python3 Design/AppIcon/build_icon.py            # 生成素材与无材质预览
python3 Design/AppIcon/build_icon.py --install  # 更新图标和开屏图片，保留 Composer 材质
```

材质以 `.icon/icon.json` 为准，在 Icon Composer 中调整并保存。
`--install --reset-materials` 会重建初始材质配置，覆盖应用内调整，
只用于从头重建。更改图层名称或数量时同时维护脚本和图标清单。

检查默认、深色和单色外观，以及 32/64/128 小尺寸。
静态合成预览不包含系统材质，本次效果以 Composer 的 Design Generation 27 为准。

## 开屏图片

`LaunchLogo.imageset` 复用前景图层，保留相册、山峦、太阳和锁，使用透明背景，
不带应用图标最外层的圆角底板。由 `--install` 同步生成 1x/2x/3x 图片。
开屏使用静态图形，不叠加 Composer 动态材质。主体显示尺寸沿用原开屏布局；
背景为深蓝灰，默认 `#252C38`，深色外观 `#1E242E`。

## 版本信息页

`Logo.imageset` 使用 Icon Composer 27 导出的完整图标，提供 100、200、300 像素的 1x/2x/3x 图片，
供各平台共用的版本信息页显示；保留导出透明圆角，不再额外裁切。更新正式图标后同步更新这份展示资源。
