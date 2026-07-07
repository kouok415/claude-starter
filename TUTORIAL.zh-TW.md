# claude-starter 專案使用教程

[English](./TUTORIAL.md) · **繁體中文**

實戰走一遍:從零到一次帶閘門的長程 run。架構原理見
[README.zh-TW.md](./README.zh-TW.md);舊專案升級見
[MIGRATION.md](./MIGRATION.md)。

---

## 0. 一次性:機器設定

```bash
git clone https://github.com/<your-username>/claude-starter.git
cd claude-starter
./bootstrap-machine.sh     # 安裝 ~/.claude/CLAUDE.md;可選 pre-commit/gitleaks
```

模板更新後重跑——它會顯示 diff、確認後才動你的全域層(留日期備份)。

## 1. 開新專案

```bash
./start_project.sh my-app                      # code 型,private
./start_project.sh --kind research my-survey   # 研究型
./start_project.sh --kind analysis my-backtest # 資料分析型
./start_project.sh --local --kind code demo    # 離線,不碰 GitHub
```

新專案自帶全部機制:hooks、`/wrap`、`/task`、agent 班底、`.ai_context/`
骨架;模板自身的基建檔案已被清掉。

## 2. 第一次 session——讓 Claude 起草 CLAUDE.md

在專案裡打開 Claude。只要 `CLAUDE.md` 還是模板佔位符狀態,session-start
hook 就會發警告,Claude 會主動提議**從 codebase 起草 Stack / Commands /
Verify / DoD** 給你。

你的工作是花 2 分鐘審,不是花 10 分鐘寫——而你的修改恰好落在 Claude
猜不到的地方:

- **Verify** —— 端到端證明改動有效的那條命令(smoke run、一個真實請求),
  不只是測試套件。
- **Definition of done** —— 專案特有的門檻:效能下限、覆蓋率、「必須能跑
  範例資料」。意圖住在這裡,不在程式碼裡。

空專案(還沒有程式碼)?Claude 會反過來訪談你。順手做:
`cp .claude/hooks/lint.sh.example .claude/hooks/lint.sh` 接上你的
linter——之後每次編輯即時回饋。

## 3. 日常迴圈(小任務)

```
打開 Claude ──→ hook 自動注入 INDEX + state(/clear 和壓縮後也會,
   │            不需要手動協議)
   正常工作
   │
收尾 ──→ /wrap ──→ state.md 刷新、決策進 ADR、大事件進 journal
   │
   └──→ 同意 commit:chore(context): wrap <topic>
```

記憶去哪裡(H4 規則一句話):**現在 → `state.md` · 永久 →
`decisions.md` · 這次事件 → `journal/` · 敏感 → `private/`**(永不入 git)。

## 4. 大任務——`/task`

預計超過約 30 分鐘自主工作的事:

```
/task 把認證從 session cookie 遷移到 JWT,不能破壞現有的 12 條 API 測試
```

依序會發生:

1. **Spec** —— 需求被煉成可執行的驗收標準。*意圖型*的模糊現在問,
   之後不問。
2. **計畫** —— planner 出里程碑草案、紅隊 critic 攻擊、綜合成
   `plan.md`:小里程碑,每個帶一條 `verify:` 命令。這是你瞄一眼
   切法的時點。
3. **里程碑迴圈** —— 每關:全新 context 的 `executor` 實作、對抗式
   `verifier` 親自重跑 verify 並檢查測試有沒有被改弱、過關即在
   `task/<slug>` 分支上 commit。你可以走開。
4. **閘門** —— verify 紅燈時 Claude 想結束回合?`stop-gate.sh` 攔下並把
   失敗輸出塞回去。你會看到 `GATE FAILED` + 命令輸出。「完成」從此
   不是散文。
5. **卡關?** —— 升級梯自動走:換方法重試 → 分歧策略平行 → `reframer`
   改寫問題本身 → 三振後停下、誠實回報。
6. **完成** —— 三鏡頭終審面板,`/wrap` 把記分板(profile、閘門失敗數、
   用到第幾級)歸檔進 `journal/`,然後問你要 merge 還是開 PR。

**無人值守模式:**`/task --auto <描述>` —— 意圖型的判斷不再暫停詢問,
改記成 spec.md 的 `[ASSUMED: ...]` 條目,完工報告強制全部列出給你審。
破壞性/對外動作照舊停下確認。

**中斷了?** 重開 session 即可——hook 會把該任務的 `plan.md` +
`lessons.md` 注回去,從上一個過關的里程碑續跑。run 中途被壓縮同理,
不怕。

## 5. Profile

| Profile | 啟用方式 | 時機 |
|---|---|---|
| `opus-tier` | session 用 opus 級模型跑(自動偵測) | 沒有 fable 額度、資安領域、延遲敏感 |
| `fable-tier` | session 用 fable 級模型跑(自動偵測) | 最高風險長程、通宵無人值守 |
| `mixed` | `.claude/agents/executor.md` 釘 `model: opus`,session 跑 fable 級 | **預設推薦** —— 強模型規劃/批判/終審,便宜檔執行 |

Profile 在 intake 偵測、**凍結進該任務的 plan.md**——想按專案釘死,
把 `CLAUDE.md` 裡對應的 `Task profile:` 註解取消。任務中途換模型永不
靜默生效:剩餘里程碑會被顯式重切。

## 6. 升級既有專案

```bash
cd claude-starter && ./sync-project.sh ../my-older-project
```

只增不改:缺的機制檔補上,已存在的絕不覆寫——改以建議清單提示手動
合併(典型是 v3 之前的 `settings.json` 要併入 `"Stop"` hook 區塊、
`session-start.sh` 要加任務注入段)。完整指南:
[MIGRATION.md](./MIGRATION.md)。

## 7. 疑難排解

- **閘門一直紅,但問題出在 verify 命令本身** —— 直接改 `plan.md` 裡
  那條 `- verify:`。閘門同一輪 stop 最多強制續跑一次(不可能死鎖),
  下一個 turn 重新武裝。
- **想放棄整個任務** —— 刪 `.ai_context/tasks/CURRENT`,harness 立即
  解除;任務目錄留著,想續跑再把 slug 寫回去。
- **hooks 好像沒生效** —— hooks 在 session 啟動時載入;改過
  `settings.json` 要重開 session。最快自檢:新 session 開頭有沒有
  INDEX/state 注入。
- **state.md 過期/超量警告** —— 跑 `/wrap`,它會刷新日期並歸檔已解決
  的段落。

## 8. 速查表

| 動作 | 指令 |
|---|---|
| 新專案 | `./start_project.sh [--kind code\|research\|analysis] <name>` |
| 日常收尾 | `/wrap` |
| 大任務 | `/task <描述>` |
| 大任務(無人值守) | `/task --auto <描述>` |
| 放棄任務 | 刪 `.ai_context/tasks/CURRENT` |
| 舊專案升級 | `./sync-project.sh <path>` |
| 全域層更新 | `./bootstrap-machine.sh --force-global` |

建議的第一步:挑一個真實的中型任務,用 `mixed` profile 跑一次,完事讀
`journal/` 裡的記分板——那是「這套 harness 在你的工作負載上值不值」的
第一筆數據。
