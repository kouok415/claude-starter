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
context 壓縮、人類健忘之下依然成立。第五層把大任務變成有閘門的里程碑
管線:`/task` 負責規劃、執行、驗證那些單一 context 撐不完的長程工作。

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
                            ▼
┌──────────────────────────────────────────────────────────┐
│ 第 5 層 — 執行        /task + stop gate + agents         │
│   長程 harness:里程碑計畫、全新 context 的執行者、      │
│   對抗式驗收、強制閘門。                                 │
└──────────────────────────────────────────────────────────┘
```

每一層回答一個問題:

- **全域:** Claude 應該*怎麼做事*?
- **專案:** *這個專案*是什麼?這裡的「完成」是什麼意思?
- **記憶:** *已經發生過什麼*?*現在什麼為真*?
- **機制:** 沒有人盯著的時候,什麼依然成立?
- **執行:** 一個 context 裝不下的任務,怎麼做完 —— 而且*證明*做完?

## 散文 → 機制

v2 的核心原則:重要的規則都配一個機制。散文是規格,機制才是保證。

| 規則(散文) | 機制(強制) |
|---|---|
| 「每個 session 先讀 INDEX.md 再讀 state.md」 | `SessionStart` hook 自動注入兩者 —— 啟動、resume、`/clear`、壓縮後皆然 |
| 「停下來之前把記憶寫回去」 | `/wrap` skill 執行寫回儀式 |
| 「commit 裡不准有密鑰」(H1) | gitleaks pre-commit + `settings.json` 禁止讀取 `.env*` |
| 「state.md 不超過 5 KB」(S7) | pre-commit 大小檢查 + session 開始時警告 |
| 「會老化的事實要標日期」(S3) | session-start hook 偵測 state.md 過期並警告 |
| 「驗證過才算完成」 | **Stop gate**:`/task` 進行中時,當前里程碑的 verify 指令不通過,回合就結束不了(樹沒變動則命中 PASS-cache,不重跑);外加 CLAUDE.md 的 **Verify** + **Definition of done** 契約、可選的 `lint.sh` 即時回饋 |
| 「長任務會衰變:漂移、無聲錯誤、狀態流失」 | `/task` harness —— 帶可執行閘門的里程碑計畫、每個里程碑全新 executor context、對抗式 verifier、升級梯、過關即 commit |
| 「新專案的第一個 session 要完成設置」 | session-start 的 `SETUP REQUIRED` 指令 + Stop gate 擋住第一次回合結束(每 session 一次);兩者都認 CLAUDE.md 裡的 `claude-starter: UNCONFIGURED` sentinel,`/setup` 起草完成時刪掉它 |
| 「發現(discovery)只付一次,不是每個子代理付一次」 | `scout` agent 在 intake 寫出 `tasks/<slug>/brief.md`;session-start 自動注入;之後所有 context 按圖導航、發現地圖錯就附註修正,不再重新調查 |
| 「儀式隨任務規模縮放、驗證隨風險縮放」 | `/task` 把規模(S/M/L)記進 plan 頭部 —— S 直接在主 context 規劃執行;每個里程碑的 `risk:` 決定 只靠閘門 / 輕量 diff 審查 / 完整對抗驗證 |
| 「一個狀態錯字不能無聲解除閘門」 | session-start 偵測「任務有 `[pending]` 里程碑卻沒有 `[in_progress]`」時警告;Stop gate 對做到一半斷鏈(`[done]`+`[pending]` 卻無 in_progress)的狀態每 session 擋一次 |
| 「里程碑閘門絕不無聲熄滅」 | 其餘暗閘狀態 —— CURRENT 空白/損毀、plan.md 不存在或無里程碑標題、`[in_progress]` 里程碑缺 verify 指令、任務工作停在 main/master —— 每 session 擋一次,且每次偵測都在 gatelog 追加一行 `INTEGRITY`:安靜的 gatelog 從此可證明等於乾淨的一輪 |
| 「verify 指令要被稽核,不只是被執行」 | gatelog 每行記錄實際強制執行的指令(中途弱化留下痕跡);final panel 以 `git log -p -- spec.md` 稽核驗收準則是否被悄悄改弱 |
| 「verify 指令不能無人看管地做災難性操作」 | Stop gate denylist:含 `sudo`、`git push`、絕對路徑 `rm -rf` 的 verify 永不執行 —— 一律擋下、一律記錄 |
| 「失敗與放棄的任務也要進資料集」 | `/wrap` 在放棄時同樣寫入記分板列(`outcome` 釘死為 `success\|failed\|abandoned`),外加取自 git 時間戳的 `duration_min` —— 不留倖存者偏差 |
| 「每筆記分板列都標明產生它的 harness 版本」 | `/wrap` 從 `.claude/.starter-version` 最後一行的 `claude-starter@<ref>` 戳記填入 `harness` 欄;release 都打 git tag,ref→版本的對映是機械的 |
| 「harness 的摩擦是資料,不是體感」 | `/wrap` 只在機制真的出問題時把枚舉列(`area` × `severity`)寫進 `.ai_context/friction.csv`;`harness-report.sh` 把它跟 gatelog 的 `INTEGRITY` 列 join 起來 |
| 「評分是算出來的,不是回憶出來的」 | `scripts/harness-report.sh`(CI 有測)按 harness 版本計算 outcome/gate/escalation/成本聚合;N<5 不印百分比;刻意不存在綜合分數 |
| 「常駐注入的檔案必須保持小」 | `brief.md`/`lessons.md` 超過 4 KB 警告、`state.md` 5 KB pre-commit 上限 + 警告(S7)、`INDEX.md` 自身有大小守衛測試 |
| 「記分板數字必須是真的」 | Stop gate 每次真實執行寫入 `gatelog`;`/wrap` 彙總成 `scoreboard.csv` |
| 「沒跑 /wrap 就死掉的 session」 | session-start 偵測 commit 比 `state.md` 新時發出警告 |

---

## 快速開始

> 實戰教程(生成 → 日常迴圈 → `/task` → profile):
> **[TUTORIAL.zh-TW.md](./TUTORIAL.zh-TW.md)** · [English](./TUTORIAL.md)

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
寫回去。大任務用 `/task <描述>` 開跑 —— 見下方**長程任務**一節。

### 5. 升級先前生成的專案

```bash
./sync-project.sh ../my-older-project
```

只補上缺少的機制檔案(絕不覆寫),其餘以建議清單印出。
詳見 [MIGRATION.md](./MIGRATION.md)。

---

## 長程任務 —— `/task`

記憶層讓 *session 之間*連續;`/task` 讓*單一大任務*活著跑完。它把
「一個英雄式的長 context」換成有閘門的管線:

1. **Spec** —— 驗收標準必須是可執行的檢查,否則不開跑。
2. **Scout** —— 一次調查寫出 `brief.md`:之後每個 context 都按這張圖
   導航。context 為了判斷獨立性保持全新;事實用繼承的,不重新推導。
3. **計畫** —— 儀式隨記錄的規模縮放:**S** 直接起草(零 spawn)、
   **M** = 1 個 `planner` + 紅隊 `plan-critic`、**L** = 3 個視角
   planner + critic。小里程碑,每個帶 `verify:` 指令和 `risk:` 等級。
4. **里程碑迴圈** —— S 在主 context 執行;M/L 每個里程碑用全新
   `executor`。驗證深度看風險:`low` 只靠機械閘門、`med` 輕量 diff
   審查、`high` 完整對抗式 `verifier`。過關即 commit。
5. **Stop gate** —— 回合想結束時 `stop-gate.sh` 重跑當前里程碑的
   verify;紅燈就結束不了(樹沒變動則命中 PASS-cache,不重跑)。
   Definition of done 從散文變成物理法則。
6. **升級梯** —— 換方法重試 → 3 個分歧策略平行(worktree)→
   `reframer` 改寫問題本身 → 停下回報(三振規則)。

狀態放在 `.ai_context/tasks/<slug>/`(`spec.md`、`plan.md`、`brief.md`、
`lessons.md`),`/clear` 和壓縮後會自動重新注入,run 不怕 context
流失。完結時 `/wrap` 追加記分板一列(profile、size、閘門失敗數、
用到第幾級升級梯)—— 用數據判斷這套 harness 值不值得。

**Profile。** 協定按模型分級:可靠性核心(閘門、狀態、驗證)永遠全開;
里程碑粒度、planner 扇出、升級梯路徑隨 tier 縮放 —— intake 時偵測、
凍結進該任務的 `plan.md`,可用專案 CLAUDE.md 的 `Task profile:` 覆寫。
`mixed`(強模型指揮、便宜模型執行)只需一行 frontmatter:把
`.claude/agents/executor.md` 釘成 `model: opus`。任務中途換模型永不
靜默生效 —— 剩餘里程碑要顯式重切。

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
│   │   ├── session-start.sh    注入 INDEX+state(+ 進行中任務的 plan)
│   │   ├── post-edit.sh        編輯後即時 lint 回饋(委派 lint.sh)
│   │   ├── stop-gate.sh        /task 里程碑閘門 —— verify 紅燈不准停
│   │   └── lint.sh.example     語言 init 之後填入你的 linter
│   ├── agents/                 /task 班底:scout、planner、plan-critic、
│   │                           executor、verifier、reframer
│   └── skills/
│       ├── wrap/SKILL.md       /wrap —— session 收尾記憶寫回
│       ├── task/SKILL.md       /task —— 長程里程碑 harness
│       ├── task/reference.md   worktree 協定 + profile 旋鈕(按需載入)
│       └── setup/SKILL.md      /setup —— 第一次 session 的出生協定
├── .ai_context/                第 3 層(schema v3)
├── .pre-commit-config.yaml     H1 密鑰掃描 + S7 大小上限
├── scripts/                    pre-commit 輔助腳本(專案保留)
├── tests/run.sh                L1+L2 回歸套件(CI 內建執行)
├── .mcp.json.example           MCP 樣板(--kind analysis 保留)
├── .github/workflows/lint.yml  模板 repo 自身的 CI(生成時移除)
├── start_project.sh            生成器(驗證、個人化、清理)
├── bootstrap-machine.sh        機器設定 + 全域層升級
├── sync-project.sh             升級既有專案(只增不改,安全)
├── MIGRATION.md                v2 → v3、v1 → v2,以及更舊佈局的遷移
└── TUTORIAL.md / .zh-TW.md     實戰教程(生成專案時移除)
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

- **不做角色人設(PM / Backend / QA)。** 內建的 agent 是 `/task`
  迴圈的*功能性階段*(規劃、批判、執行、驗收、重述)—— 不跑 `/task`
  就完全惰性。組織圖式的人設依然不做;需要更多任務型 agent 在專案
  層自行加。
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
