[English](README.en.md) | **中文**

# Loenn Ultra

Loenn Ultra 是 Celeste 地图编辑器 [Lönn](https://github.com/CelestialCartographers/Loenn) 的一个分支，fork 自 [LuckyBoy-7/Loenn](https://github.com/LuckyBoy-7/Loenn) 的 `better-loenn` 分支（v1.1.10）。保留原版全部功能，在此基础上改善中文支持、macOS Apple Silicon 支持、素材面板的信息展示、大图性能与插件兼容性。

- 仓库：<https://github.com/djgrayon/LoennUltra>
- 下载：<https://github.com/djgrayon/LoennUltra/releases>

---

## 与上游 Lönn 的差异

### 平台支持

- **macOS（Apple Silicon）**：macOS 包改用 LÖVE 11.5 universal 引擎；启动脚本检测到 Apple Silicon 时通过 `arch -arm64` 以原生架构启动，避免此前整棵进程树被 Rosetta 按 x86_64 拉起。该问题会导致编辑后持续卡顿、大型地图保存无法完成。启动日志会输出 `Runtime arch: <arch>` 可供确认。
- **macOS**：`nfd.so` 更换为 x86_64 + arm64 通用二进制，Intel Mac 与 Apple Silicon 均可使用。
- **macOS**：按 arm64 ABI 修正 `lfs_ffi.lua` 中 `dirent` 结构体的字段宽度，修复目录枚举出现空名或乱码文件名。
- **Linux**：修正 `utils/filesystem.lua` 与 `utils/threads.lua` 将非 Windows 平台判为 Windows 的问题，文件对话框依赖库（`nfd.so` / `nfd_zenity.so`）现可正常加载。

### 新增

- 文件菜单新增「关闭」：关闭当前地图但不退出编辑器；存在未保存改动时弹出保存确认，关闭后可继续打开其他地图。
- 信息面板：按 `~` 打开，显示光标坐标、当前房间名与画布缩放倍率。
- Debug 工具支持按名称查找实体与触发器，并可直接传送至其位置。
- 新增 14 个脚本，均支持多选（名称与界面显示一致）：
  - **Change Attributes**：把某一类型的所有实体改为另一种类型。
  - **String Replace in Entity/Trigger**：批量替换实体/触发器某个属性中的子串。
  - **Convert Fillers to Rooms**：把原版 filler 转换为房间，砖块取自相邻房间。
  - **Flip Room**：翻转房间内容或房间位置。
  - **Create Template Mod**：新建 mod 文件夹，含空白地图与默认的 Celeste XML 文件。
  - **Export to Zip**：更新 mod 版本并导出整个 mod 文件夹为 zip。
  - **Transfer Used Decals**：把地图用到的 decal 从其他 mod 复制进当前 mod。
  - **Get Decal Credits** / **Get Default Tile Credits**：汇总地图所用 decal / 默认 tileset 所属的 mod，用于撰写致谢。
  - **Auto Add Background Tiles** / **Auto Add Background Tiles Around**：生成并填充背景砖，或在前景砖边缘与 spinner 周围补背景砖。
  - **Auto Add Filler**：沿房间边缘扩展实心砖，并生成整砖 filler 房间。
  - **Add Spikes Around Object**：沿实体周围或前景砖区域轮廓添加刺。
  - **Add Spinners In Area**：在圆形区域内批量添加 spinner，右键可复制现有 spinner 的配置。
- 素材面板支持分级样式与预览图：decal、trigger、entity、tile 条目均可在列表中查看对应预览。
- Stylegrounds 面板支持直接拖拽添加 effect，拖拽过程有位置反馈。
- 面板条目支持拷贝资源路径、在文件管理器中打开资源所在目录。
- 字体支持自定义字号，界面字体与地图文字字体可分别设置。
- 支持系统输入法的候选词窗口与拼音预编辑，可在搜索框与属性输入框中正常输入中文。
- 收藏的条目会标注其来源 mod。

### 改进

- 地图加载改为多线程；mod 的 zip 包按需挂载；新增 Selene→Lua 编译结果缓存。
- 出厂默认语言设为中文；使用非中文界面时，加载画面首次出现可切换语言的提示。
- 通知栏移至工作区右下角，不再横跨窗口。
- 各类列表支持拖拽排序，条目间增加间距，文件路径按 VS Code 风格显示。
- 过长的 trigger 文本自动换行。
- 画布缩放倍率调整为 √2。
- 新增快捷键：`x` 切换当前/上一个工具，`Tab` 隐藏侧边栏，`f` / `b` 将选中 decal 切换至前景/背景。

### 修复

- **保存**：写盘失败后保存锁未释放，导致该地图后续所有保存无限等待；现会释放并报告失败原因。
- **保存**：写盘失败时静默跳过、无任何提示。
- **撤销**：bucket 的 all rooms 模式批量换砖后，一次撤销仅回退部分房间。
- **撤销**：撤销后画布仍显示旧内容。
- **渲染**：在图层列表中选中某一层后，该层内容不显示。
- **渲染**：`drawScreenText` 在 drawable 缺少宽高时崩溃（含 ExCameraDynamics `CameraReferenceFrame` 的地图缩放后必现）。
- **导出**：`地图 > 保存地图图片` 点击保存后崩溃。
- **导出**：`地图 > 保存地图图片` 只导出当前房间。
- **本地化**：仅提供 `en_gb.lang` 的插件在中文界面下全部显示为 `%unknown%`。
- **插件**：`Loenn2/` 隔离目录导致未迁移的旧插件静默失效（菜单无入口、日志无输出）。
- **插件**：`requireFromPlugin` 失败返回 `nil`，导致依赖它的插件启动时崩溃。
- **插件**：`drawableFunction` 截断插件追加的参数，导致 `sprite` 为 `nil`。
- **选择**：多选场景下 `isItemSelected` 遍历了错误的集合。
- **Linux**：文件对话框无法弹出。

### 已知问题

- 关闭地图后的空白界面中，中文提示文字不显示（该界面使用不含中文字形的像素字体渲染）。

---

## 安装

### Windows

下载 `LoennUltra-<版本>-windows.zip`，解压至空目录，运行 `Lönn.exe`。

### macOS

下载 `LoennUltra-<版本>-macos.zip`，解压得到 `LoennUltra.app`。

首次运行时若被系统拦截，在终端执行：

```bash
xattr -dr com.apple.quarantine /路径/到/LoennUltra.app
chmod +x /路径/到/LoennUltra.app/Contents/MacOS/*.sh
```

### Linux

下载 `LoennUltra-<版本>-linux.zip`，解压后执行：

```bash
chmod +x Lönn.sh
./Lönn.sh
```

压缩包内已包含 `nfd.so` 与 `nfd_zenity.so`。

---

## 从原版 Lönn 迁移

- 配置文件独立：本分支使用 `loenn2-settings.conf`，不会覆盖原版的 `settings.conf`；首次启动时会从原版配置迁移一次。
- 语言设置位于 Settings → General → Language。
- 插件加载优先读取 mod 的 `Loenn2/` 目录，该目录不存在时回退至原版使用的 `Loenn/`，现有插件通常无需修改。

## 快捷键

操作方式与原版一致。以下为常用项，全部可在 Settings → Hotkeys 中修改：

| 快捷键 | 作用 |
|---|---|
| `Ctrl + S` / `Ctrl + Shift + S` | 保存 / 另存为 |
| `Ctrl + Z` / `Ctrl + Shift + Z` | 撤销 / 重做 |
| `Ctrl + T` / `Ctrl + Shift + T` | 新建房间 / 配置当前房间 |
| `Alt + 方向键` | 移动房间 |
| `Ctrl + A` / `Ctrl + Shift + A` | 全选 / 取消选择 |
| `Ctrl + C` / `Ctrl + X` / `Ctrl + V` | 复制 / 剪切 / 粘贴 |
| `Q` / `E`、`A` / `D` | 调整宽度、高度（按住 `Ctrl` 为 1 像素步进） |
| `L` / `R`、`V` / `H` | 旋转、翻转 |
| `~` | 信息面板 |
| `Tab` | 隐藏侧边栏 |
| `x` | 切换当前/上一个工具 |
| 滚轮 | 缩放画布 |
| 按住右键拖动 | 平移视图 |

## 界面截图

主窗口：中文界面，右侧为素材面板。

![主窗口](docs/examples/example1.png)

房间编辑：选中房间中的触发器后，右侧列出可用实体并显示预览图。

![房间编辑](docs/examples/example2.png)

设置窗口（编辑器页）：可切换语言、界面字体与界面缩放。

![设置窗口](docs/examples/example3.png)

素材面板：实体按 mod 分组，选中条目时显示预览图。

![素材面板](docs/examples/example4.png)

滤镜预览：以缩略图网格浏览可用的滤镜贴图。

![滤镜预览](docs/examples/example5.png)

Stylegrounds 面板：选中条目时显示预览与属性。

![Stylegrounds 面板](docs/examples/example6.png)

依赖窗口：左侧为当前地图缺失的依赖，右侧为可用 mod。

![依赖窗口](docs/examples/example7.png)

## 反馈

- 问题与建议提交至本仓库 [Issues](https://github.com/djgrayon/LoennUltra/issues)。提交时请说明操作步骤、预期结果与实际结果，并尽量附上日志文件。
- 日志位置：Windows `%LOCALAPPDATA%\Loenn\`，macOS `~/Library/Application Support/Loenn/`。

## 关于本分支

### 代码来源

- 上游项目：Lönn（[CelestialCartographers/Loenn](https://github.com/CelestialCartographers/Loenn)）
- 直接上游：[LuckyBoy-7/Loenn](https://github.com/LuckyBoy-7/Loenn) 的 `better-loenn` 分支，fork 点为该分支的 `v1.1.10`（提交 `b084a59`）
- 该 `better-loenn` 分支本身基于 Lönn 上游的 `ui-olympUI` 分支
- 本仓库：`djgrayon/LoennUltra` 的 `better-loenn` 分支；`v1.1.10` 之后的改动均由本仓库维护

本分支由社区维护，属于非官方分支，与 Celeste 开发团队、原版 Lönn 作者、`better-loenn` 分支作者均无隶属关系。原版 Lönn 的问题请提交至原仓库；`better-loenn` 分支自身的问题请提交至该分支所在仓库。

原版 Lönn 是 [Ahorn](https://github.com/CelestialCartographers/Ahorn) 的后继项目，后者基于 [Maple](https://github.com/CelestialCartographers/Maple)。

## 许可

本项目源代码与资源（除下方列出的例外）沿用 Lönn 的 [MIT 许可](LICENSE)。

Lönn 的 logo 版权归原作者所有，仅可随原版软件分发。若基于本项目二次开发，请使用自己的名称与标识，避免与原版 Lönn 混淆。

本项目包含并使用以下开源项目：

- [dkjson](https://github.com/LuaDist/dkjson)
- [lua-yaml](https://github.com/exosite/lua-yaml)
- [luafilesystem 的 FFI 实现](https://github.com/sonoro1234/luafilesystem)
- [luajit-request 的一个 fork](https://github.com/Vexatos/luajit-request)
- [Selene](https://github.com/Vexatos/Selene)
- [xml2lua](https://github.com/manoelcampos/Xml2Lua)

依赖：

- [LÖVE](https://love2d.org/)
- [nativefiledialog 的 lua 绑定 fork](https://github.com/Vexatos/nativefiledialog/tree/master/lua)
- [libcurl](https://curl.se/libcurl/)
