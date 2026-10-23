# App Store 2.0 更新日志（What's New）

> 备选长文案。与你后台现有四行措辞逐句对齐的版本在
> [store-text-2.0.md](store-text-2.0.md)，正式提交用那份；本文件留作以后改版参考。

每个语言一段，直接复制进 App Store Connect → 版本信息 → **此版本的新增内容**。
字段上限 4000 字符，下面每段在 200–700 字符之间，留了改写余量。
后台语言下拉菜单里没有「Chinese (Traditional, Hong Kong)」时跳过香港那段即可，
其余 11 段与 App 内 `Localizable.xcstrings` 的语言一一对应。

内容依据当前工作区 2.0 的改动：搜索（`Features/Library/Models/MediaSearchQuery.swift`、
`Views/MediaSearchControls.swift`）、折叠屏铰链适配（`Shared/AdaptiveLayoutMode.swift`）、
播放器与预览叠层（`MediaViewer/MediaPlaybackButton.swift`、`MediaViewerOverlayLayout.swift`）、
相册与媒体库改版、新图标（`SecurityFolder/Gallery.icon`）、本地化扩展到 12 种。
提交前请对照实际发行版本删掉没做的条目。

---

## 简体中文 · Chinese (Simplified)

全新图标、更快的搜索，以及为大屏可折叠设备准备的布局。

• 搜索：按名称或原始文件名查找媒体，再按媒体类型、拍摄日期或导入日期筛选。
• 全新图标：重新绘制的图标，在 iOS 与 Mac 上跟随系统的 Liquid Glass 材质。
• 可折叠设备：布局随铰链位置调整，怎么拿都顺手。
• 媒体库与相册：改进的相册详情与浏览体验。
• 照片与视频预览：更顺手的播放按钮与进度条。
• 本地化扩展到 12 种语言。

---

## 繁體中文（台灣）· Chinese (Traditional)

全新圖示、更快的搜尋，以及為大螢幕摺疊裝置準備的版面。

• 搜尋：依名稱或原始檔名尋找媒體，再依媒體類型、拍攝日期或匯入日期篩選。
• 全新圖示：重新繪製的圖示，在 iOS 與 Mac 上跟著系統的 Liquid Glass 材質呈現。
• 摺疊裝置：版面會隨轉軸位置調整，怎麼拿都順手。
• 媒體庫與相簿：改進的相簿詳細資訊與瀏覽體驗。
• 照片與影片預覽：更好操作的播放按鈕與進度列。
• 在地化擴展到 12 種語言。

---

## 中文（香港）· Chinese (Traditional, Hong Kong)

全新圖示、快啲嘅搜尋，同埋為大螢幕摺機準備嘅版面。

• 搜尋：用名稱或者原始檔案名搵媒體，再按媒體類型、拍攝日期或者匯入日期篩選。
• 全新圖示：重新繪製嘅圖示，喺 iOS 同 Mac 上跟住系統嘅 Liquid Glass 材質。
• 摺機：版面會跟住鉸位調整，點樣揸都順手。
• 媒體庫同相簿：改良嘅相簿詳情同瀏覽體驗。
• 相片同影片預覽：更易用嘅播放按鈕同進度條。
• 本地化擴展到 12 種語言。

---

## English (U.S.)

A new icon, faster search, and layouts made for large foldable displays.

• Search: find media by name or original filename, then narrow it down by media type, capture date, or import date.
• New icon: a redrawn app icon that picks up the system's Liquid Glass material on iOS and Mac.
• Foldables: layouts follow the hinge, so the app stays comfortable however you hold the device.
• Library and albums: refined album details and browsing.
• Photo and video preview: easier playback controls and scrubbing.
• Localized into 12 languages.

---

## English (U.K.)

A new icon, faster search, and layouts made for large foldable displays.

• Search: find media by name or original filename, then narrow it down by media type, capture date or import date.
• New icon: a redrawn app icon that picks up the system's Liquid Glass material on iOS and Mac.
• Foldables: layouts follow the hinge, so the app stays comfortable however you hold the device.
• Library and albums: refined album details and browsing.
• Photo and video preview: easier playback controls and scrubbing.
• Localised into 12 languages.

---

## 日本語 · Japanese

新しいアイコン、より速い検索、そして大型の折りたたみディスプレイ向けのレイアウト。

• 検索：名前または元のファイル名でメディアを探し、メディアの種類・撮影日・読み込み日で絞り込めます。
• 新しいアイコン：描き直したアイコン。iOS と Mac ではシステムの Liquid Glass の質感に合わせて表示されます。
• 折りたたみデバイス：ヒンジの位置に合わせてレイアウトが変わり、持ち方にかかわらず操作しやすくなりました。
• ライブラリとアルバム：アルバムの詳細表示と閲覧を改善しました。
• 写真とビデオのプレビュー：再生ボタンとシークバーを操作しやすくしました。
• 12 言語にローカライズしました。

---

## 한국어 · Korean

새로운 아이콘, 더 빨라진 검색, 대형 폴더블 디스플레이에 맞춘 레이아웃을 준비했습니다.

• 검색: 이름이나 원본 파일 이름으로 미디어를 찾고, 미디어 유형·촬영 날짜·가져온 날짜로 좁힐 수 있습니다.
• 새로운 아이콘: 새로 그린 아이콘. iOS와 Mac에서 시스템의 Liquid Glass 질감을 따릅니다.
• 폴더블: 힌지 위치에 맞춰 레이아웃이 바뀌어 어떤 방식으로 들고 있어도 편하게 쓸 수 있습니다.
• 라이브러리와 앨범: 앨범 상세 화면과 탐색을 개선했습니다.
• 사진 및 동영상 미리보기: 재생 버튼과 진행 막대를 더 쓰기 쉽게 다듬었습니다.
• 12개 언어로 현지화했습니다.

---

## Deutsch · German

Ein neues Icon, schnellere Suche und Layouts für große faltbare Displays.

• Suche: Medien nach Namen oder ursprünglichem Dateinamen finden und anschließend nach Medientyp, Aufnahme- oder Importdatum eingrenzen.
• Neues Icon: ein neu gezeichnetes App-Icon, das unter iOS und macOS das Liquid-Glass-Material des Systems übernimmt.
• Faltbare Geräte: Die Layouts richten sich nach dem Scharnier, damit die App in jeder Haltung bequem bleibt.
• Mediathek und Alben: überarbeitete Albumdetails und verbesserte Navigation.
• Foto- und Videovorschau: leichter bedienbare Wiedergabetasten und Zeitleiste.
• In 12 Sprachen lokalisiert.

---

## Français · French

Une nouvelle icône, une recherche plus rapide et des mises en page pensées pour les grands écrans pliables.

• Recherche : retrouvez vos médias par nom ou par nom de fichier d'origine, puis affinez par type de média, date de prise de vue ou date d'importation.
• Nouvelle icône : une icône redessinée qui reprend le matériau Liquid Glass du système sur iOS et Mac.
• Appareils pliables : les mises en page suivent la charnière, l'app reste confortable quelle que soit la prise en main.
• Médiathèque et albums : détails d'album et navigation retravaillés.
• Aperçu des photos et des vidéos : commandes de lecture et barre de progression plus faciles à utiliser.
• Traduite en 12 langues.

---

## Español (España) · Spanish

Nuevo icono, búsqueda más rápida y diseños pensados para pantallas plegables grandes.

• Búsqueda: encuentra contenido por nombre o por nombre de archivo original y luego filtra por tipo de contenido, fecha de captura o fecha de importación.
• Nuevo icono: un icono redibujado que adopta el material Liquid Glass del sistema en iOS y Mac.
• Plegables: los diseños siguen la bisagra, así la app resulta cómoda sin importar cómo sostengas el dispositivo.
• Biblioteca y álbumes: detalles de álbum y navegación mejorados.
• Vista previa de fotos y vídeos: controles de reproducción y barra de progreso más fáciles de usar.
• Traducida a 12 idiomas.

---

## Italiano · Italian

Nuova icona, ricerca più rapida e layout pensati per i grandi display pieghevoli.

• Ricerca: trova i contenuti per nome o nome file originale, poi restringi per tipo di contenuto, data di scatto o data di importazione.
• Nuova icona: un'icona ridisegnata che adotta il materiale Liquid Glass di sistema su iOS e Mac.
• Pieghevoli: i layout seguono la cerniera, così l'app resta comoda in qualsiasi modo tu tenga il dispositivo.
• Libreria e album: dettagli degli album e navigazione migliorati.
• Anteprima di foto e video: comandi di riproduzione e barra di avanzamento più facili da usare.
• Localizzata in 12 lingue.

---

## Русский · Russian

Новая иконка, более быстрый поиск и интерфейс для больших складных экранов.

• Поиск: находите материалы по названию или исходному имени файла, а затем уточняйте по типу, дате съёмки или дате импорта.
• Новая иконка: перерисованная иконка, которая на iOS и Mac использует системный материал Liquid Glass.
• Складные устройства: раскладка подстраивается под петлю, поэтому приложением удобно пользоваться при любом хвате.
• Медиатека и альбомы: переработанные сведения об альбоме и навигация.
• Просмотр фото и видео: управление воспроизведением и полоса прокрутки стали удобнее.
• Локализация на 12 языков.

---

## 提交前检查

- 实际发布内容与本文件不一致时，先删条目再翻译，避免商店描述出现没有的功能。
- 新增语言时保持同一结构（首句一段 + 6 条 `•`），审核与用户阅读都更稳定。
- 首句不要出现版本号、价格、促销或「最好」这类绝对化说法。
