# claude-starter 專案使用教程

[English](./TUTORIAL.md) · **繁體中文**

> 本教程對應 claude-starter **v3.10**(2026-07-23)。若此處版本落後
> [MIGRATION.md](./MIGRATION.md) 最新一節,表示機制已經前進 ——
> 以 MIGRATION 為準。

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

## 2. 第一次 session——`/setup` 跑出生協定

在專案裡打開 Claude。只要 `CLAUDE.md` 還是模板佔位符狀態,session-start
hook 就會指示 Claude 在**第一則回覆**執行 **`/setup`**——而且 Stop gate
會擋住第一次回合結束,直到草稿落地。這是機制,不是模型可以漂過去的建議。
協定內容:一輪批次訪談(只問程式碼答不了的)→ 鷹架 stack + 接 `lint.sh`
→ 起草 CLAUDE.md / README / state.md → 把起草的 Verify 實跑一次 → commit。

你的工作是花 2 分鐘審,不是花 10 分鐘寫——而你的修改恰好落在 Claude
猜不到的地方:

- **Verify** —— 端到端證明改動有效的那條命令(smoke run、一個真實請求),
  不只是測試套件。
- **Definition of done** —— 專案特有的門檻:效能下限、覆蓋率、「必須能跑
  範例資料」。意圖住在這裡,不在程式碼裡。

想先不弄也可以——閘門擋一次就讓路,下個 session 重新武裝。空專案沒程式
碼可讀?訪談會補上這個缺。

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
   用到第幾級)歸檔進 `journal/`,並在 `.ai_context/scoreboard.csv` 追加
   一列。閘門數字來自 hook 寫的 `gatelog` 檔案,不是模型的記憶。最後問
   你要 merge 還是開 PR。

**無人值守模式:**`/task --auto <描述>` —— 意圖型的判斷不再暫停詢問,
改記成 spec.md 的 `[ASSUMED: ...]` 條目,完工報告強制全部列出給你審。
破壞性/對外動作照舊停下確認。

**中斷了?** 重開 session 即可——hook 會把該任務的 `plan.md` +
`lessons.md` 注回去,從上一個過關的里程碑續跑。run 中途被壓縮同理,
不怕。任務進行中再喊 `/task` 是**續跑**(找到 `[in_progress]` 里程碑
直接回到迴圈,絕不重新規劃);要放棄就刪 `.ai_context/tasks/CURRENT`。

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
合併。兩個進階模式:`--update-stock` 會連「可證明未被客製的 stock 檔」
一起前進(內容與模板任一歷史版本逐位元相同才換;客製檔照樣絕不碰);
`--adopt` 收編既有的非 starter repo(先建骨架,再由 `/setup` 從既有
程式碼起草簡報)。完整指南:[MIGRATION.md](./MIGRATION.md)。

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
- **verify 命令是無提示執行的。** 閘門在每次回合結束時直接跑當前里程碑
  的 `- verify:`,不會彈權限確認——保持它們唯讀、快速(< 5 分鐘);
  plan-critic 會攔破壞性命令,計畫審查就是你的檢查點。

## 8. 速查表

| 動作 | 指令 |
|---|---|
| 新專案 | `./start_project.sh [--kind code\|research\|analysis] <name>` |
| 日常收尾 | `/wrap` |
| 大任務 | `/task <描述>` |
| 大任務(無人值守) | `/task --auto <描述>` |
| 放棄任務 | 刪 `.ai_context/tasks/CURRENT` |
| 設置 / 重起草專案簡報 | `/setup` |
| 舊專案升級 | `./sync-project.sh <path>` |
| 升級 + 推進 stock 檔 | `./sync-project.sh --update-stock <path>` |
| 收編既有 repo | `./sync-project.sh --adopt <path>` |
| 全域層更新 | `./bootstrap-machine.sh --force-global` |

建議的第一步:挑一個真實的中型任務,用 `mixed` profile 跑一次,完事讀
`journal/` 裡的記分板——那是「這套 harness 在你的工作負載上值不值」的
第一筆數據。
