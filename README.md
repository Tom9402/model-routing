# Codex 模型分工 Skill

将常规工作优先交给 Luna，局部实现与审查交给 Terra，较难的独立任务交给 Sol，
由当前主模型负责整合和最终验收。模型只是偏好，按每台设备实际支持的能力选择。

## 一句话安装（推荐）

把下面这句话发给目标设备上的 Codex：

> 请从 https://github.com/Tom9402/model-routing 安装并启用 model-routing skill；读取仓库 SKILL.md，执行其安装流程，将模型分工规则合并到全局 AGENTS.md，保留已有指令，并验证安装。

无需手动下载文件。Codex 需要可访问 GitHub 和写入自身配置目录。

## 一条命令安装

在 **Windows PowerShell 5.1 或 PowerShell 7** 中运行：

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/Tom9402/model-routing/main/install.ps1).Content))
```

该命令下载并执行本仓库的安装脚本，需要信任仓库维护者。安装器下载同一提交版本的文件，
安装 skill，并自动启用全局分工规则。重复运行即可更新；更新会备份发生变化的旧文件。
安装后**新开 Codex 任务**。

## 安装位置与已有配置

- skill：`$CODEX_HOME/skills/model-routing`。
- 全局规则：`$CODEX_HOME/AGENTS.md` 中的 `<!-- model-routing:start -->` 与 `<!-- model-routing:end -->` 区块。
- 未设置 `CODEX_HOME` 时使用用户主目录下的 `.codex`。
- 保留区块外的指令。旧版无标记规则或损坏标记会停止安装，由 Codex 先检查迁移。
- 不修改 `config.toml`，不安装模型，不读取凭据文件或聊天记录，不上传本机数据。
  备份只保存在本机，包含被替换文件原有的内容。

仅通过通用 skill 安装器复制技能，未必会启用全局规则；上面的提示词和命令会完成两部分。

## 验证与定制

让 Codex 使用 `$model-routing` 检查安装。包内 `scripts/verify.ps1` 只检查文件和规则区块，
不会调用收费模型。真实委派是否可用，取决于当前会话的子代理工具、模型参数、账号和宿主。
实际验证应在独立小任务中调用子代理，并检查宿主执行记录，不能用模型自报身份代替。

默认路由可直接编辑全局文件的专属区块，或修改仓库 `assets/AGENTS.md` 后安装。
更新会替换该区块，先保留自己的定制。这里没有固定供应商价格表，按你的实际套餐调整。
Windows 安装流程经过隔离目录测试；macOS/Linux 尚未测试，可让 Codex 按 SKILL.md 适配。

## 移除

让 Codex 移除全局文件中的完整 model-routing 标记区块，以及对应的 `skills/model-routing`
目录，保留其他内容。不要删除整份 `AGENTS.md`，也不要盲目恢复备份覆盖后续修改。
