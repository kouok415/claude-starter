# claude-starter

[English](./README.md) · **繁體中文**

> 語言無關的 Claude Code 專案腳手架:結構化的持久記憶,
> 加上讓規則真正成立的機制層。

跨多個 session 與 Claude 協作時,會出三種問題:

1. **Claude 在 session 之間會忘記。** 週二做的決策到週四就消失,你重新解釋、
   Claude 重新摸索,時間白白流失。
2. **常見的解法是一份 `CLAUDE.md` 加一個筆記資料夾,隨手拼裝。** 每個專案
   長得都不一樣、規則各自漂移、敏感資料混進 commit。
3. **散文規則不會自我執行。**「先讀 state.md」「不准寫密鑰」「不超過 5 KB」
   —— 寫在 markdown 裡,只有模型剛好記得時才成立。

`claude-starter` 一次設計、處處重用地解決這三件事:三層記憶,外加第四層
**機制** —— hooks、權限規則、pre-commit 檢查 —— 讓協議在長 session、
context 壓縮、人類健忘之下依然成立。

---

## 架構

```
┌──────────────────────────────────────────────────────────┐
│ 第 1 層 — 全域        ~/.claude/CLAUDE.md                │
│   行為與偏好。每個專案、每個 session 都載入。            │
│   正本:本 repo 的 global/CLAUDE.md。                    │
└──────────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────┐
│ 第 2 層 — 專案        <project>/CLAUDE.md                │
│   技術棧、指令、Verify、Definition of done。             │
│   「只在這裡成立」的事實。                               │
└──────────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────┐
│ 第 3 層 — 記憶        <project>/.ai_context/             │
│   ├── INDEX.md      註冊表:什麼東西在哪                 │
│   ├── state.md      現在(可覆寫,≤5 KB)                │
│   ├── decisions.md  永久(append-only ADR 日誌)         │
│   ├── knowledge/    長期參考                             │
│   ├── journal/      逐事件記錄(含日期)                 │
│   └── private/      敏感草稿(gitignore)                │
└──────────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────┐
│ 第 4 層 — 機制        <project>/.claude/ + pre-commit    │
│   用 hooks、skills、權限規則去「強制」上面三層,         │
│   而不是指望它們被遵守。                                 │
└──────────────────────────────────────────────────────────┘
```

每一層回答一個問題:

- **全域:** Claude 應該*怎麼做事*?
- **專案:** *這個專案*是什麼?這裡的「完成」是什麼意思?
- **記憶:** *已經發生過什麼*?*現在什麼為真*?
- **機制:** 沒有人盯著的時候,什麼依然成立?

## 散文 → 機制

v2 的核心原則:重要的規則都配一個機制。散文是規格,機制才是保證。

| 規則(散文) | 機制(強制) |
|---|---|
| 「每個 session 先讀 INDEX.md 再讀 state.md」 | `SessionStart` hook 自動注入兩者 —— 啟動、resume、`/clear`、壓縮後皆然 |
| 「停下來之前把記憶寫回去」 | `/wrap` skill 執行寫回儀式 |
| 「commit 裡不准有密鑰」(H1) | gitleaks pre-commit + `settings.json` 禁止讀取 `.env*` |
| 「state.md 不超過 5 KB」(S7) | pre-commit 大小檢查 + session 開始時警告 |
| 「會老化的事實要標日期」(S3) | session-start hook 偵測 state.md 過期並警告 |
| 「驗證過才算完成」 | CLAUDE.md 的 **Verify** 指令 + **Definition of done** 契約;可選的 `lint.sh` 讓每次編輯即時回饋 |

---

## 快速開始

### 1. 設定全域層(每台機器一次)

```bash
git clone https://github.com/<your-username>/claude-starter.git
cd claude-starter
./bootstrap-machine.sh
```

repo 是自足的:`global/CLAUDE.md` 就在裡面。之後重跑會顯示 diff、
確認後才更新 `~/.claude/CLAUDE.md`(保留日期備份);`--force-global`
可跳過詢問。可選項:bun + uv 工具鏈、pre-commit + gitleaks、PUA plugin。

### 2. 把這個 repo 標記為 GitHub template

推上 GitHub 後,到 Settings → 勾選 "Template repository",
`gh repo create --template` 才能運作。

### 3. 生成新專案

```bash
./start_project.sh my-app                      # code 型,private
./start_project.sh --kind research my-survey   # 研究型
./start_project.sh --kind analysis my-backtest # 資料分析型
./start_project.sh --local --kind code demo    # 離線,不碰 GitHub
```

生成器會依 kind 個人化 CLAUDE.md、產生真正的專案 README、填入日期、
**移除腳手架自身的基建檔案**(新專案不會帶著 `start_project.sh`、
本說明文等),有 pre-commit 就順手安裝,最後 commit + push。

### 4. 開始工作

在專案裡打開 Claude。SessionStart hook 會自動注入 `INDEX.md` +
`state.md`。工作。停下來時跑 `/wrap` —— 它把 state、決策、journal
寫回去。

### 5. 升級先前生成的專案

```bash
./sync-project.sh ../my-older-project
```

只補上缺少的機制檔案(絕不覆寫),其餘以建議清單印出。
詳見 [MIGRATION.md](./MIGRATION.md)。

---

## 盒子裡有什麼

```
claude-starter/
├── global/CLAUDE.md            第 1 層正本(bootstrap 安裝)
├── templates/
│   ├── CLAUDE.md.code          專案簡介:技術棧、指令、Verify、DoD
│   ├── CLAUDE.md.research      研究框架:來源登記、證據分級
│   ├── CLAUDE.md.analysis      資料框架:pipeline、可重現性
│   └── README.project.md       新專案的真 README 樣板
├── .claude/
│   ├── settings.json           hooks 接線 + 權限規則(入 git)
│   ├── hooks/
│   │   ├── session-start.sh    注入 INDEX+state;過期/超量警告
│   │   ├── post-edit.sh        編輯後即時 lint 回饋(委派 lint.sh)
│   │   └── lint.sh.example     語言 init 之後填入你的 linter
│   └── skills/wrap/SKILL.md    /wrap —— session 收尾記憶寫回
├── .ai_context/                第 3 層(schema v2)
├── .pre-commit-config.yaml     H1 密鑰掃描 + S7 大小上限
├── scripts/                    pre-commit 輔助腳本(專案保留)
├── .mcp.json.example           MCP 樣板(--kind analysis 保留)
├── .github/workflows/lint.yml  模板 repo 自身的 CI(生成時移除)
├── start_project.sh            生成器(驗證、個人化、清理)
├── bootstrap-machine.sh        機器設定 + 全域層升級
├── sync-project.sh             升級既有專案(只增不改,安全)
└── MIGRATION.md                v1 → v2,以及更舊佈局的遷移
```

---

## 設計原則

### 硬規則(在每個專案的 `INDEX.md`)

- **H1 — 不寫密鑰。** 機制:gitleaks + 禁讀 `.env*`。
- **H2 — 不重複事實。** README 或原始碼裡有的,引用,不複製。
- **H3 — 推測不當事實。** 未確認的主張標 `[TENTATIVE]`。
- **H4 — 對的檔案放對的東西。** 現在 → `state.md`;永久 →
  `decisions.md`;這次事件 → `journal/`。
- **L1 — 不寫真名。** 用角色代稱。真名最多放 `private/`。

### 軟規則(在 `global/CLAUDE.md` → `~/.claude/CLAUDE.md`)

S1 持久化門檻 · S2 大宗內容外部化 · S3 會老化的事實標日期 ·
S4 不寫廢話 · S5 不寫情緒 · S6 不複製 PR/commit 描述 ·
S7 `state.md` ≤ 5 KB。*(S5–S7 在 v1 編號為 L2–L4。)*

### 我們刻意不做的事

- **不做角色人設(PM / Backend / QA)。** 需要任務型 agent 時在專案的
  `.claude/agents/` 定義 —— opt-in,不內建。
- **不在 CLAUDE.md 裡做指令路由。** slash 指令屬於 skill 系統
  (`/wrap` 就是一個)。
- **不做施壓式 prompt。** 驗證迴路勝過精神喊話;DoD 契約和 hooks
  承擔這個職責。
- **不內建語言工具鏈。** `bootstrap-machine.sh` 把 bun/uv 列為可選;
  腳手架本身適用於程式、研究、分析、寫作。
- **不 `mkdir src/`。** 原始碼佈局是語言腳手架工具的事。

---

## FAQ

**Q:為什麼 `.ai_context/` 要進 git?**

跨機器、跨協作者、跨月份的連續性。用 `chore(context): ...` 提交,
可被 release-notes 過濾器排除。

**Q:`.claudeignore` 去哪了?**

v2 移除了 —— Claude Code 並不讀這個檔案,它只是裝飾。真正的機制是
`.claude/settings.json` 的權限規則(已內建),加上 Claude 本身就會
跳過 build 產物。

**Q:`.ai_context/` 和 Claude 原生記憶差在哪?**

`.ai_context/` 入 repo、可共享:專案真相。原生記憶(`~/.claude/...`)
屬於個人、跨專案:個人偏好。`global/CLAUDE.md` 明訂分工,避免雙寫。

**Q:團隊可以用嗎?**

可以 —— bootstrap 每人跑一次,模板共用。多人同時寫 ADR 時,把
`decisions.md` 改成一檔一 ADR(`decisions/NNN-title.md`);
`INDEX.md` 說明了時機。

**Q:我有 v1 佈局(或更古老的 PM/BE/FE/QA 佈局)的專案。**

v1 → v2 用 `./sync-project.sh <path>`;完整說明見
[MIGRATION.md](./MIGRATION.md)。

---

## 授權

MIT(或你偏好的授權 —— 公開前先決定)。
