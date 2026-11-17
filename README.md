# Moni-Action-ImageText

Moni 的第三方动作示例：**框选图片 → OCR → 在 Photoshop 当前文档里生成可编辑的文字图层**。

这是「动作（Action）二次开发」的完整例子，包含：

- Moni 动作（Lua）与选项 schema；
- 动作自带的 Photoshop 脚本（ExtendScript / JSX）；
- 动作自己的「设置 PS 脚本」入口（`setup.lua`）；
- 纯 JS 单元测试（`node --test`）。

> 设计原则：**外部软件的安装/检查是动作自己的工作，不是 Moni 的工作。**
> Moni 只提供通用能力：按 `action.json` 的 `programs` 启动外部程序（`ctx.process.run`）
> 与本次执行的临时工作目录（`ctx.fs.*`）。Moni 不知道 Photoshop 装在哪、也不内置任何第三方安装器。

## 工作流程

```
用户框选
  └─ 动作检查 PS 脚本是否已安装（自带 runner 执行 ps/setup.jsx mode=check）
       ├─ 未安装 → 返回 A500_ACTION_FAILED（hint），提示用户去动作设置里点「设置 PS 脚本」
       └─ 已安装 → 截屏 → OCR → 自带 runner 执行 ps/image_text.jsx
                       └─ PS 当前文档中创建文字图层 / 组，一次 Ctrl+Z 可撤销
```

## 前置条件

- Moni（内置动作运行时，支持 `ctx.process.run` / `ctx.fs`）；
- Photoshop 22.0+（Windows 或 macOS），建议先启动并打开一个文档；
- macOS 首次调用会弹系统「自动化」授权，需要允许 Moni 控制 Photoshop。

## 安装动作

把本仓库目录作为动作包导入 Moni（`action.json` 在仓库根目录）。导入后在动作设置里点击
**「设置 PS 脚本」**，动作会调用自己的 `setup.lua` → `ps/setup.jsx`，把
`image_text.jsx` 复制到：

- Windows：`%APPDATA%\Adobe\Adobe Photoshop <版本>\Presets\Scripts\Moni\ps.image-to-text\`
- macOS：`~/Library/Application Support/Adobe/Adobe Photoshop <版本>/Presets/Scripts/Moni/ps.image-to-text/`

装好后可从 Photoshop 的「文件 > 脚本」手动运行，也可直接由动作自动调用。

## 权限

| 权限 | 用途 |
|---|---|
| `screen.capture` | 框选截图 |
| `ocr.run` | 识别截图文字 |
| `process.spawn:photoshop` | 启动 `programs.photoshop`（Windows：`Photoshop.exe -r runner.jsx`） |
| `process.spawn:osascript` | 启动 `programs.osascript`（macOS：`do javascript`） |

`action.json` 的 `programs` 声明程序候选路径（`%ProgramFiles%/Adobe Photoshop*/Photoshop.exe` 等），
宿主只按候选启动，不安装任何东西。动作不申请 `net.fetch`、`ps.install` 等能力——安装由动作自己的 JSX 完成。

## 选项

| 选项 | 取值 | 说明 |
|---|---|---|
| `lang` | `ch` / `en` / … | OCR 语言 |
| `min_score` | 0–1 | OCR 置信度阈值 |
| `font` | PostScript 字体名 | 例如 `SourceHanSansSC-Regular` |
| `fit_mode` | `auto` / `height` / `width` | 字号拟合方式 |
| `color_mode` | `sample` / `black` / `white` | 文字颜色；`sample` 取块中心像素 |
| `calibration` | `normalized` / `selection` | 截图坐标映射到整幅画布或当前选区 |
| `group` | 布尔 | 是否把图层放进一个组 |

## JSX 契约

动作脚本必须定义：

```js
function moniRun(job) {
  // job.params 是动作传入的 JSON 对象
  return { /* 可 JSON 序列化的结果 */ };
}
```

- 抛错时用 `throw { code: "A401_PS_NO_DOC", message: "..." }`，动作会把 `code`
  映射成动作错误码；
- 整批操作建议包在 `doc.suspendHistory(name, "回调函数()")` 里；
- 不要写 `#target photoshop`：脚本是由动作自带的 `ps/runner.jsx` 通过 `$.evalFile` 加载的。

## 开发与测试

```bash
node --test "tests/**/*.test.mjs"
```

测试用 Node 的 `vm` 直接加载 `ps/image_text.jsx` 中的纯函数（坐标映射、字号换算、
图层名、颜色选择），不依赖 Photoshop。

## 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `A500_ACTION_FAILED` + hint「还没有安装 Photoshop 脚本」 | 还没安装 PS 脚本：动作设置 →「设置 PS 脚本」 |
| `A407_PS_OFFLINE` | 找不到 Photoshop；安装后启动一次，或让动作 `programs.photoshop.candidates` 覆盖你的安装路径 |
| `A401_PS_NO_DOC` | Photoshop 里没有打开的文档 |
| 文字位置/字号有偏差 | `fit_mode=height` 是快速拟合；对精度要求高时用 `selection` 校准或手动调整 |
| macOS 无响应 | 系统设置 → 隐私与安全性 → 自动化，允许 Moni 控制 Photoshop |

## 许可

MIT
