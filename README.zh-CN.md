# vim-calltree

[English](README.md) | 中文

Vim 的调用层级树。显示光标所在函数被谁调用、又调用了谁，以懒加载的树形结构展示，
右侧附带源码预览。数据来自 [vim-lsp](https://github.com/prabirshrestha/vim-lsp)
与 LSP 3.16 的 Call Hierarchy 协议。

```
● mid  main.go:7
  ▾ ▲ Callers (1)
    ▾ top  main.go:9
      ▸ main  main.go:11
  ▾ ▼ Callees (1)
    ▸ leaf  main.go:5
```

## 环境要求

- Vim 8.2 及以上（依赖 job、text properties、共享 dict）。已在 Vim 9.2 +
  `g:lsp_use_native_client = 1` 下验证。
- vim-lsp。
- 实现 `callHierarchyProvider` 的语言服务器。已验证 gopls。

## 安装

```vim
Plug 'prabirshrestha/vim-lsp'
Plug 'lyuangg/vim-calltree'
```

## 使用

将光标放在函数名上，执行 `:CallTree`。位置必须落在标识符上，这是
`textDocument/prepareCallHierarchy` 的要求。

树在新建的 tab 中打开：左侧为树，右侧为源码预览，原 tab 不受影响。

### 命令

| 命令 | 说明 |
| --- | --- |
| `:CallTree` | 打开当前函数的调用树，调用者与被调用者各展开一层 |
| `:CallTreeCallers` | 仅显示调用者 |
| `:CallTreeCallees` | 仅显示被调用者 |
| `:CallTreeExpand` | 将可见部分再展开一层 |
| `:CallTreeQF` | 将可见节点导出到 quickfix |
| `:CallTreeRefresh` | 从打开时的位置重新解析 |
| `:CallTreeClose` | 关闭树所在 tab |

### 键位

所有映射均为树窗口的 buffer-local 映射，并同时提供 `<Plug>`。

| 键 | `<Plug>` | 说明 |
| --- | --- | --- |
| `<CR>`、`o` | `(calltree-toggle)` | 展开或折叠光标所在节点 |
| `e` | `(calltree-open)` | 在执行 `:CallTree` 的窗口中打开该文件并定位到定义 |
| `g<CR>` | `(calltree-jump)` | 在预览窗口显示函数定义 |
| `gs` | `(calltree-jump-site)` | 在预览窗口显示调用点 |
| `K` | `(calltree-float)` | 在浮动窗口中预览函数定义 |
| `L` | `(calltree-expand-level)` | 将可见部分再展开一层 |
| `]c`、`[c` | `(calltree-next-site)`、`(calltree-prev-site)` | 切换到下一个 / 上一个调用点 |
| `<BS>` | `(calltree-parent)` | 跳到父节点 |
| `Q` | `(calltree-quickfix)` | 导出到 quickfix |
| `r` | `(calltree-refresh)` | 重新解析 |
| `q` | `(calltree-close)` | 关闭树所在 tab |

### 预览

在树中用 `j`、`k`、`gg`、`G` 或搜索移动时，预览窗口会跟随更新。预览窗口使用
scratch buffer（`calltree://<path>`，`buftype=nofile`），不是文件本身：不会加入
buffer 列表，也不会发送 `didOpen`。内容优先取自已加载的 buffer（因此未保存的修改
可见），否则从磁盘读取；`filetype` 按扩展名设置，语法高亮保留。

默认预览调用点。设置 `g:calltree_preview_site = 0` 改为预览定义。

### 排序

同层节点按源码位置排序，不采用服务器返回的顺序：

- 被调用者：按调用在函数体中出现的先后。
- 调用者：按文件，再按调用者的定义位置。
- 同一函数的多个调用点：按行号升序，与 `]c`/`[c` 的顺序一致。

### 标记

| 标记 | 含义 |
| --- | --- |
| `●` | 根节点 |
| `▾` / `▸` | 已展开 / 已折叠 |
| `·` | 叶子（无结果） |
| `…` | 请求进行中 |
| `↻` | 环，祖先中已包含该函数 |
| `×N` | 被调用 N 次 |
| `…+N` | 因 `g:calltree_max_children` 省略了 N 个符号 |

### 高亮组

| 高亮组 | 元素 | 默认值 |
| --- | --- | --- |
| `CallTreeRoot` | 根节点 | 加粗，黄色（深色背景）/ 棕色（浅色背景） |
| `CallTreeCaller` | 调用者节点 | 绿色 |
| `CallTreeCallee` | 被调用者节点 | 蓝色 |
| `CallTreeStdlib` | 标准库（`GOROOT/src` 下） | 斜体，青灰 |
| `CallTreeExternal` | 第三方代码（module cache、`vendor/`） | 琥珀色 |
| `CallTreeCycle` | 环标记 | 加粗，橙色 |
| `CallTreeLoading` | 请求中 | 斜体，灰色 |
| `CallTreeCount` | `×N`、`…+N` | 紫色 |
| `CallTreeLocation` | 文件路径 | 灰色 |
| `CallTreeLine` | 行号 | 链接到 `LineNr` |
| `CallTreeMarker` | `●▾▸·↻` | 链接到 `NonText` |
| `CallTreeError` | 错误文本 | 链接到 `ErrorMsg` |

所有高亮组均使用 `highlight default` 定义，可在 vimrc 中覆盖；在 `ColorScheme`
与 `:set background` 之后会自动重新应用。

## 配置

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `g:calltree_tab` | `1` | 在新 tab 中打开。`0` 表示在当前 tab 分屏 |
| `g:calltree_width` | `50` | 树窗口宽度，占 `&columns` 的百分比 |
| `g:calltree_max_children` | `50` | 每个节点最多列出的子节点数 |
| `g:calltree_auto_expand` | `1` | 打开时自动展开的层数 |
| `g:calltree_expand_limit` | `30` | 单次 `:CallTreeExpand` 的最大并发请求数 |
| `g:calltree_preview` | `1` | 光标移动时是否更新预览窗口 |
| `g:calltree_preview_site` | `1` | 预览调用点而非定义 |
| `g:calltree_preview_delay` | `60` | 预览防抖，单位毫秒 |
| `g:calltree_preview_max_bytes` | `2097152` | 超过该字节数的文件不预览内容 |
| `g:calltree_float_height` | `20` | `K` 浮窗的最大高度（行），超出部分用 `<C-d>`/`<C-u>` 翻页 |
| `g:calltree_float_width` | `100` | `K` 浮窗的最大宽度（单元格） |
| `g:calltree_default_maps` | `1` | 安装默认键位。`0` 仅提供 `<Plug>` |

## 限制

- 调用图来自静态分析，反射、生成代码、经由 `any` 的调用无法解析。
- 每次展开都是独立请求。代码修改后按 `r` 重新解析。
- 每个节点的调用者/被调用者数量受 `g:calltree_max_children` 限制，其余以 `…+N` 表示。

## 测试

```sh
# 树模型、渲染与 quickfix 导出，无需语言服务器
vim -Nu NONE -es -S test/smoke.vim && cat test/smoke.log

# 使用 gopls 做端到端验证
test/integration.sh
```
