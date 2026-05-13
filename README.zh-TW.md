# claude-starter

[English](./README.md) · **繁體中文**

> 不限程式語言的 Claude Code 專案 scaffold,內建結構化的持久記憶層。

當你跨多個 session 跟 Claude 工作,通常會遇到兩個問題:

1. **Claude 會忘記。** 週二做的決定,週四就消失了。你重新解釋,Claude 重新摸索,時間就漏掉了。
2. **補丁式解法每次都長不一樣。** 一份 `CLAUDE.md` 加一個筆記資料夾,各專案各做各的。規則漂移、敏感資料外洩、新人不知道該先讀什麼。

`claude-starter` 是同一個解法,但只設計一次、到處重用 — 一個三層架構,讓 Claude 在每個專案、每台機器、每個 collaborator 之間都有一致的專案記憶。

---

## 架構

```
┌──────────────────────────────────────────────────────────┐
│ Layer 1 — 全域       ~/.claude/CLAUDE.md                 │
│   工程原則、.ai_context schema 約定、soft rules          │
│   每個專案、每個 session 都會載入                        │
└──────────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────┐
│ Layer 2 — 專案       <project>/CLAUDE.md                 │
│   技術棧、指令、專案特定規則。30–60 行                   │
│   只放這個專案才成立、全域不成立的東西                   │
└──────────────────────────────────────────────────────────┘
                            ▼
┌──────────────────────────────────────────────────────────┐
│ Layer 3 — 專案記憶          <project>/.ai_context/       │
│   ├── INDEX.md      Registry:列出有哪些檔案              │
│   ├── state.md      現在(可覆寫)                       │
│   ├── decisions.md  永久(append-only ADR log)           │
│   ├── knowledge/    長期參考                             │
│   ├── journal/      日期化的事件紀錄                     │
│   └── private/      敏感暫存(gitignored)               │
└──────────────────────────────────────────────────────────┘
```

每一層回答一個問題:

- **全域:** Claude 該怎麼*思考、行動*?
- **專案:** *這個專案*是什麼?
- **專案記憶:** *已經發生過*什麼?*現在*的事實是什麼?

這個切分是刻意的。它讓同一套架構能服務軟體開發、log 分析、研究筆記、寫作 — 不被某種角色框架綁死。

---

## Quick start

### 1. 設定全域層(每台機器一次)

Clone 這個 repo 然後跑 bootstrap:

```bash
git clone https://github.com/<your-username>/claude-starter.git
cd claude-starter
./bootstrap-machine.sh
```

這會安裝 `~/.claude/CLAUDE.md`(工程原則),並且可選擇安裝 [PUA plugin](https://github.com/tanweai/pua) — 一個第三方 Claude Code plugin,在 Claude 想放棄、卡關、或偵測到使用者 frustration 時自動 escalate。自動觸發,也可手動 `/pua`。

### 2. 把這個 repo 標記成 GitHub Template

Push 到 GitHub 之後,在 repo Settings 勾選 "Template repository"。後面 `gh repo create --template` 才能用。

### 3. 開新專案

```bash
./start_project.sh my-new-project
```

這會從 template 建一個新 GitHub repo、clone 下來、自動填入專案名稱。然後在新目錄跑你語言的 init 指令(`npm init`、`uv init`、`cargo init`、`flutter create .`,或如果是 research / docs / log-analysis 專案就什麼都不跑 — starter 刻意不限語言)。

### 4. 開始工作

在專案目錄打開 Claude。每個 session 都會這樣做:

1. 讀 `./.ai_context/INDEX.md`
2. 讀 `./.ai_context/state.md`
3. 只在 INDEX 裡的觸發條件成立時,才讀其他檔案

整個協定就這麼簡單。

---

## 內容物

```
claude-starter/
├── CLAUDE.md.template      專案 brief 範本 — 填入 stack、指令、規則
├── .gitignore              內建 AI 相關的 ignore;語言 ignore 自己 append
├── .claudeignore           Claude 不該掃的東西
├── .ai_context/
│   ├── INDEX.md            Read-first registry,內含 hard rules
│   ├── state.md            現況快照範本
│   ├── decisions.md        ADR log 範本
│   ├── knowledge/          空目錄;有需要再加檔案
│   ├── journal/            空目錄;格式 YYYY-MM-DD-<topic>.md
│   └── private/            Gitignored 暫存 — Claude 看得到、git 看不到
├── start_project.sh        Template-based 專案產生器
├── bootstrap-machine.sh    一次性的機器設定
├── MIGRATION.md            從其他 layout 遷移過來的指南
└── README.md               你在這裡
```

---

## 設計原則

### Hard rules(放在每個專案的 `INDEX.md`)

- **H1 — 沒有 secrets。** 連 placeholder 形式都不要。
- **H2 — 沒有事實複製。** 如果 README 或 source code 已經有,不要複製過來,用 reference。
- **H3 — 不把臆測當事實。** 不確定的東西標 `[TENTATIVE]`。
- **H4 — 對的檔案、對的目的。** 現在 → `state.md`、永久 → `decisions.md`、這次事件 → `journal/`。
- **L1 — 沒有真名。** 用角色代稱。真名最多寫在 `private/` 裡。

### Soft rules(放在 `~/.claude/CLAUDE.md`)

- **S1** — 持久性門檻:只寫*下次 session 還會用到*的東西。
- **S2** — 大段內容(>200 行)外部化,用 reference 不要 paste。
- **S3** — 會過時的資訊都加 timestamp。
- **S4** — 不寫廢話。寫*為什麼*,不寫「看起來不錯」。
- **L2** — 不寫情緒性內容。
- **L3** — 不複製 PR/commit description。
- **L4** — `state.md` 上限 5 KB,超過就 archive 到 `journal/`。

### 我們刻意*不做*的事

- **沒有角色人格(PM / Backend / Frontend / QA)。** 這把舊版架構綁死在軟體開發 workflow,移除。
- **沒有指令路由(`!plan`、`!review` 那一套)。** Slash commands 應該住在 slash command 系統裡,不該寫在 `CLAUDE.md`。
- **沒有 Discord 或聊天平台慣例。** Plug-in 層的事。
- **沒有對第三方 plugin 的硬相依。** 你裝了 ECC 之類的工具當然好,但架構不依賴它。
- **沒有預先 `mkdir src/`。** Source 結構由你語言的 scaffolding 工具決定,不是我們。

---

## FAQ

**Q:為什麼 `.ai_context/` 進 git?Repo 不會被污染嗎?**

進 git 是為了讓 Claude 跨機器、跨 contributor、跨幾個月之後還記得事情。代價是一個資料夾的小 markdown 檔;好處是「我們三月決定的事情」不會消失。用 commit type `chore(context): ...` 把這些變更從 release notes 過濾掉。

**Q:有 secrets 或敏感筆記怎麼辦?**

三層保護:(1) `.ai_context/private/` 是 gitignored;(2) `H1` 禁止任何地方寫 secrets;(3) `L1` 禁止真名。Push 到公開 repo 前要 audit。

**Q:一定要用 helper script 嗎?**

不用。它們只是方便。你也可以手動 clone template、手動 copy 檔案,隨你。架構就是檔案 + 慣例而已。

**Q:這跟單純用 `CLAUDE.md` 差在哪?**

單純的 `CLAUDE.md` 只涵蓋 Layer 2。這套加了 Layer 1(跨專案的預設)和 Layer 3(持久記憶)。重點是單純 `CLAUDE.md` *做不到的事* — 跨 session 記得決定、跨專案共用慣例、把「易變狀態」和「永久決定」分開存放。

**Q:我有舊的 multi-agent layout 專案,怎麼遷移?**

看 [`MIGRATION.md`](./MIGRATION.md)。從 PM/BE/FE/QA + ECC + Discord 的舊架構一步步轉過來。

**Q:團隊可以一起用嗎?**

可以。`bootstrap-machine.sh` 是每個開發者各自跑一次;template repo 是共享的。每個人拿到一樣的全域原則,每個專案拿到一樣的記憶 layout。

---

## License

MIT(或你想用的 — 公開之前選一個就好)。
