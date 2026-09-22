# 快捷指令 (Apple Shortcuts) 接入指南

本目录包含为 `apple-fm-audit` 服务预生成的 macOS / iOS 快捷指令文件及构建脚本。

---

## 预置快捷指令清单

| 文件名 | 适用平台 | 触发方式 | 调用模型 / 机制 | 功能说明 |
| :--- | :--- | :--- | :--- | :--- |
| **`AFM 智能问答.shortcut`** | macOS / iOS | 菜单栏 / 快捷键 / Siri | `system` (本地模型) / HTTP POST | 弹窗提问，请求结果写入剪贴板并弹窗显示。 |
| **`AFM 私有云问答 (PCC).shortcut`** | macOS / iOS | 菜单栏 / 快捷键 / Siri | `pcc` (私有云计算) / HTTP POST | 路由至 Apple PCC 模型处理，兼具本地回退。 |
| **`AFM 划词总结.shortcut`** | macOS | 右键「服务」菜单 / 划词快捷键 | `system` (本地模型) / 快速操作 | 读取任意软件中选中的文字，提炼要点并输出。 |
| **`AFM 极速问答 (Shell).shortcut`** | macOS | 菜单栏 / 终端 / 快捷键 | 本地 `scripts/afm-ask` 进程调用 | 绕过 HTTP 字典解析，由本地 Python 脚本直接输出。 |

---

## 安装与导入步骤

### 1. 导入到快捷指令 App
在终端中执行以下命令，系统将调起「快捷指令」的添加面板：

```bash
open "shortcuts/AFM 智能问答.shortcut"
open "shortcuts/AFM 划词总结.shortcut"
open "shortcuts/AFM 私有云问答 (PCC).shortcut"
open "shortcuts/AFM 极速问答 (Shell).shortcut"
```

或在 Finder 中双击对应的 `.shortcut` 文件点击「添加快捷指令」。

### 2. 为「划词总结」绑定全局快捷键 (macOS)
1. 打开 **系统设置 -> 键盘 -> 键盘快捷键 -> 服务 -> 文本**。
2. 找到 **`AFM 划词总结`**。
3. 双击右侧设置快捷键（例如 `⌥ + Space` 或 `⌘ + ⇧ + X`）。
4. 在任意浏览器或文本编辑器中选中文字，按下快捷键即可触发总结。

### 3. Siri 语音联动
- 快捷指令名称即为 Siri 唤起词。
- 呼叫：*“嘿 Siri，AFM 智能问答”*，系统将提示输入或直接读取问题并播报结果。

---

## 跨设备使用 (iPhone / iPad)

### 局域网连接
若在同一 Wi-Fi 网络下：
1. 查看 Mac 的局域网 IP（如 `192.168.1.100`）。
2. 在 iOS 快捷指令 App 中编辑该快捷指令。
3. 将请求 URL 从 `http://127.0.0.1:1977/v1/chat/completions` 修改为：
   ```
   http://192.168.1.100:1977/v1/chat/completions
   ```

### 公网 / Cloudflare Tunnel
若配置了 Cloudflare Tunnel 域名（如 `https://cpmmw.53116091.xyz`）：
1. 将 URL 修改为：
   ```
   https://cpmmw.53116091.xyz/v1/chat/completions
   ```
2. iPhone 无论在蜂窝网络还是外网环境，均可直接调用家中/办公室 Mac 的 Apple Foundation Model。

---

## 命令行 CLI 工具 (`scripts/afm-ask`)

仓库提供独立 CLI 脚本 [scripts/afm-ask](file:///Users/roy/developer/apple-fm-audit/scripts/afm-ask)，便于在终端、Alfred、Raycast 或第三方自动化工具中调用：

```bash
# 1. 基础问答
./scripts/afm-ask "用一句话解释摩尔定律"

# 2. 管道输入与 System Prompt
git diff | ./scripts/afm-ask -s "用简短的中文总结这份 git diff 的修改内容"

# 3. 指定私有云计算模型
./scripts/afm-ask -m pcc "分析分布式一致性协议 Raft 与 Paxos 的区别"
```

---

## 重新生成快捷指令

如需调整默认提示词或模型参数，可直接编辑 [shortcuts/build_shortcuts.py](file:///Users/roy/developer/apple-fm-audit/shortcuts/build_shortcuts.py)，然后执行：

```bash
python3 shortcuts/build_shortcuts.py
```
脚本将自动生成并使用 macOS 开发者/本地账户证书对 `.shortcut` 文件进行签名。
