# claude-starter 專案使用教程

[English](./TUTORIAL.md) · **繁體中文**

> 本教程對應 claude-starter **v4.0**(2026-10-29)。若此處版本落後
> [MIGRATION.md](./MIGRATION.md) 最新一節,表示機制已經前進 ——
> 以 MIGRATION 為準。

實戰走一遍:從零到一次以證據檢查的長程 run。架構原理見
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

新專案自帶全部機制:hooks、`/wrap`、帶著 executor 與 checker 的 `/task`、
`/prove`、`/debug`、`/number-check`、`/backtest-check` 與 `/defect` 這些
skill,以及 `.ai_context/` 骨架;模板自身的基建檔案已被清掉。

## 2. 第一次 session——`/setup` 跑出生協定

在專案裡打開 Claude。只要 `CLAUDE.md` 還是模板佔位符狀態,session-start
hook 就會指示 Claude 在**第一則回覆**執行 **`/setup`**——而且 Stop gate
會擋住第一次回合結束,直到草稿落地。這是機制,不是模型可以漂過去的建議。
協定內容:一輪批次訪談(只問程式碼答不了的)→ 鷹架 stack + 接 `lint.sh`
→ 起草 CLAUDE.md / README / state.md → 寫出專案的 `verify` skill,並在
`.claude/done-lanes` 宣告它的 lane → 逐條 trust(你確認;它的 canary 必須
失敗)並實跑一次 → commit。

你的工作是花 2 分鐘審,不是花 10 分鐘寫——而你的修改恰好落在 Claude
猜不到的地方:

- **Verify** —— 端到端證明改動有效的那條命令(smoke run、一個真實請求),
  不只是測試套件。
- **Definition of done** —— 專案特有的門檻:效能下限、覆蓋率、「必須能跑
  範例資料」。意圖住在這裡,不在程式碼裡。
- **Lane** —— 對 `/task` 而言算證據的那 1–3 條命令。核准它的 trust 提示
  之前,每一條都讀過。

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

1. **Intake** —— Claude 先讀需求會碰到的程式碼、複述目標,問那一個最能
   改變結果的問題,外加「就算每個檢查都綠,什麼情況下你還是會退件?」。
   你會拿到 2–3 個做法,附上建置與驗證成本。
2. **Card** —— 一頁的 `card.md`:目標、在跑起來的產品上「完成」是什麼意思、
   帶標籤的決策、slice(slice 1 = 最薄的真實端到端路徑)。讀過之後,核准
   `evidence.sh approve` 跳出的確認。之後除了狀態標記以外的任何修改,都要
   你再核准一次,工作才會繼續。
3. **Lane** —— 算證據的檢查,來自 `.claude/done-lanes`(由 `/setup` 宣告)。
   一條 lane 第一次用到時,`evidence.sh trust` 會請你確認 —— 先讀過
   `.claude/done-lanes` 裡那一行 —— 然後跑它的 canary,而 canary 必須失敗。
   只核准你看得懂的命令。
4. **Slice** —— 每個 slice:全新 context 的 `executor` 實作、跑 lane
   (`evidence.sh run`)並 commit,全新的 `checker` 從 diff 與原始紀錄重新
   檢查,`codex: yes` 的 slice 加上 Codex(pair 模式),最後
   `evidence.sh done S<n>` 把它標成帶紀錄編號的 `[x]` —— 或印出還缺什麼。
   你可以走開。
5. **閘門** —— 它不跑任何 lane。某個 slice 標了 `[x]` 卻沒有有效紀錄,或
   `Closed:` 行過期,回合就結束不了;其餘情況你只會看到一行狀態。同一份
   card 與內容上連續擋兩次,run 就交到你手上(`STUCK`)。
6. **卡關?** —— `/debug` 接手:兩次修失敗 → 測它們共同的前提;三次 → 停下
   回報。同一條 lane 在同一個 slice 連續失敗三次後,再跑之前會先問你
   (`ESCALATE`)。
7. **結案** —— `evidence.sh close`(每個 slice 都 `[x]`、card 引用的每條
   lane 在最終的樹上都新鮮,加上一次最終檢查:pair 開時是 Codex、關時是
   checker),你對 repo 外部分的驗收,最後 `/wrap` 追加算出來的記分板列並
   清掉 `tasks/CURRENT`。最後問你要 merge 還是開 PR。

**無人值守模式:**`/task --auto <描述>` —— 意圖型的判斷不再暫停詢問,改記成
card 上的 `[ASSUMED: ...]` 決策,收尾時全部列出給你審。破壞性/對外動作照舊
停下確認。`/goal` 只用在會收斂的機械性工作,並設回合上限。

**中斷了?** 重開 session 即可——hook 會把 card 與一行證據狀態注回去;任務
進行中再喊 `/task` 是**續跑**,從 `[~]` 的 slice 接著做(絕不重新規劃)。
7 天沒動的 card(card、donelog 與 `task/<slug>` 分支都沒動)不再注入、也不
再檢查;它仍留在磁碟上。

## 5. Pair 模式(Codex)

一個在 herdr 相鄰 pane 裡的 Codex judge 在三個點檢查工作;所有的工作仍由
Claude 做。需要:session 跑在 herdr 的 pane 裡、Codex CLI 已登入、repo 在
Codex 裡 trust 過一次,而且沒有 `AGENTS.md` 或 `AGENTS.override.md`(或與
`CLAUDE.md` 完全相同)。它處理的對話框文字是在 Codex 0.165.0 與 herdr 0.9.0
上錄的;遇到不認得的對話框,它會停下 run、把 pane 交給你。

| 階段 | 時機 | Codex 檢查什麼 |
|---|---|---|
| card | slice 1 之前 | 每個 slice 都可能失敗、都有 lane 與看得見的結果;slice 1 是端到端;金錢/密鑰/安裝類 slice 標了 `codex: yes` |
| slice | `codex: yes` 的 slice 在 `done` 之前 | 重跑 lane,或說明為什麼不能;檢查那個檢查本身 |
| final | `close` 之前 | 整個分支的正確性、回歸、測試完整性;一輪反駁 |

開啟方式:`.claude/done-lanes` 裡寫 `@pair codex`(專案預設;之後重新 trust
一條 lane,因為 `@` 行是 trust 的一部分),或在 card header 寫
`pair: codex`(只能調高、不能調低)。一次 judge run 大約 6 分鐘(最長一小時;
腳本的等待在 2 小時放棄,`task-pair.sh wait <seq>` 可重新接上),期間 tree
不能變動;通過需要 `verdict: pass`、零個 blocker、零個 major,而且由 judge
自己寫出(它寫 result 的動作必須出現在它的 Codex transcript 裡)。

run 會花你的 Codex 額度。pair 開著啟動 `/task` 涵蓋 card 檢查與一次重試;
核准 card 涵蓋它顯示的估計(每個 `codex: yes` slice 一次、final 一次、每個
單元一次重試、一輪反駁)。超過估計時腳本會停下問你。Codex 無法回答時,
`bash scripts/evidence.sh approve --waive <unit> --reason "…"` 憑你一句話讓
那個單元過關 —— 它會先問你,card 一改就失效。

## 6. 升級既有專案

```bash
cd claude-starter && ./sync-project.sh ../my-older-project
```

只增不改:缺的機制檔補上,已存在的絕不覆寫——改以建議清單提示手動
合併。兩個進階模式:`--update-stock` 會連「可證明未被客製的 stock 檔」
一起前進(內容與模板任一歷史版本逐位元相同才換),並刪除模板已退役檔案的
stock 副本(客製檔照樣絕不碰;有在 v3 下開始、仍在進行的任務時它會拒絕);
`--adopt` 收編既有的非 starter repo(先建骨架,再由 `/setup` 從既有
程式碼起草簡報)。完整指南:[MIGRATION.md](./MIGRATION.md)。

## 7. 疑難排解

- **lane 檢查的東西不對** —— 改 `.claude/done-lanes`,再跑一次
  `bash scripts/evidence.sh trust <lane>`(舊的雜湊不能再跑),並在
  `notes.md` §Tried 記下舊命令沒檢查到什麼 —— 沒寫這個理由就改了 lane,
  checker 會標出來。舊紀錄不再算數。
- **lane 跑得很慢** —— 把幾分鐘內跑完的路徑放進 `verify` skill(Claude Code
  會在 commit 前跑它);慢的路徑(VM、完整回測)各自一條 lane,在背景跑 ——
  run 的 lock 還活著時閘門會等。
- **閘門自己出問題** —— 它永遠不會因為自己的 bug 擋你:它在 donelog 記一筆
  `GATE-ERROR` 並讓回合結束。把它記成一筆 friction。
- **commit 訊息觸發了 bash-guard 的確認** —— bash-guard 把指令依 `;` `&`
  `|` `(` `)`、反引號與換行切開後,認位於指令位置的
  `evidence.sh trust|approve|check|codex`;訊息裡若在 `evidence.sh <sub>` 前
  正好有其中一個字元,它看起來就像指令。改寫訊息,或用 `git commit -F <file>`
  提交。反過來就是邊界:用 glob(`evid*.sh`)、變數或 symlink 指向腳本,它
  抓不到 —— 它擋的是失手,不是蓄意繞過。
- **想放棄整個任務** —— 跑 `/wrap` 並說明:它把這次 run 記成 abandoned(或
  failed)寫進 `scoreboard-v4.csv`,並刪掉 `.ai_context/tasks/CURRENT`;任務
  目錄留著。手動刪 `CURRENT` 也會解除 harness,但 `harness-report.sh` 之後會
  把這個任務列為孤兒。想續跑再把 slug 寫回去。
- **hooks 好像沒生效** —— hooks 在 session 啟動時載入;改過
  `settings.json` 要重開 session。最快自檢:新 session 開頭有沒有
  INDEX/state 注入。
- **state.md 過期/超量警告** —— 跑 `/wrap`,它會刷新日期並歸檔已解決
  的段落。

**每種訊息代表什麼。** harness 的訊息都以固定前綴開頭,常見的如下。

| 你看到 | 代表 | 怎麼做 |
|---|---|---|
| `SETUP GATE` | CLAUDE.md 還帶著 `UNCONFIGURED` sentinel | 讓 `/setup` 跑;或說明你不要 —— 讓行一次,下個 session 再武裝 |
| `GATE BLOCKED (block n of 2 …)` … `is marked [x] without an evidence reference` | 某個 slice 是 `[x]`,但不是 `evidence.sh done` 寫的;這個 turn 結束不了 | 讓它把那行改回 `[~]`,再跑 `evidence.sh done S<n>`;絕不手改 `[x]` |
| `… cites evidence that does not hold: …` | `[x]` 引用的紀錄不見了、是紅的、屬於別條 lane,或不是它的 `DONE` 列記的那筆 —— 或(`not evaluated by evidence.sh`)閘門看到一個 `[x]`,`evidence.sh status` 卻沒給它判定,閘門選擇擋下而不是不檢查就放行 | 重跑該 lane,再 `done` 一次;第二種情況先跑 `bash scripts/evidence.sh status`,修掉它報的問題 |
| `… the evidence is not fresh for the current content` | `close` 寫下 `Closed:` 之後內容又變了 | 重跑 lane(與最終 Codex),再 `close` 一次;或刪掉 `Closed:` 那行 |
| `claude-starter-gate: BLOCK` | 每次擋之前印的標記 | 不用做事 —— 它防止 CLI 把這次擋丟掉 |
| `… in flight; evidence check deferred until it reports`(`WAITING` 列) | lane、Codex 傳送或 subagent 還在跑 | 等 —— 它結束時會喚醒 session |
| `… is BLOCKED - n stops in a row on the same card and content …` `yielding now`(`STUCK` 列) | 同一份 card 與內容被擋兩次:這個 run 交給你了 | 讀 `donelog`;修掉原因、重新 trust 錯的 lane,或放棄 |
| `internal error` … `not blocking this stop`(`GATE-ERROR` 列),例如 `block counter not writable - yielding instead of blocking uncounted` | 閘門自己出錯,這次停止已放行 —— 例子裡是它沒辦法把擋下次數記在 `$TMPDIR`(沒有就 `/tmp`),所以寧可讓行,也不做沒有上限的擋 | 記一筆 friction 並修掉原因(讓 `$TMPDIR` 可寫);它出錯期間 slice 不會被檢查 |
| `codex no verdict twice` | judge 在同一個 unit、同一份內容上兩次沒給 verdict;`done`/`close` 對它一直拒絕 | 看 judge pane(可能有對話框要你處理),修好再重跑 —— 或豁免這個 unit:`evidence.sh approve --waive <unit> --reason "…"` |
| `TRUST REFUSED —` … `static-only command` | 這條 lane 只證明原始碼存在 | 讓 lane 真的跑產品 |
| `TRUST REFUSED —` … `the canary passed` | 餵已知壞的輸入,lane 還是綠的 | 修 lane 或它的 canary |
| `TRUST REFUSED —` … `the canary left the lane's content changed` | canary 弄壞了 lane paths 裡的東西卻沒復原,或在那裡寫了檔(至多點名五個路徑) | 讓 canary 復原它弄壞的東西;把它寫的 cache 加進 gitignore |
| `RUN REFUSED —` … `changed since trust` | trust 之後 lane 那行、它的命令或 canary 提到的檔、某個 `@` 行或 `.claude/gitleaks.toml` 變了 | 看過改動,再跑一次 `bash scripts/evidence.sh trust <lane>` |
| `ESCALATE —` … `failed 3 times in a row` | 同一條 lane 在同一個 slice 連續失敗三次 | 停下來回報(`/debug`);只有你想再試時才確認 `run --escalated` |
| `expect not matched` | 跑完了,但少了某個標記行 | 開它印出的 log 路徑;產品沒做到 lane 檢查的事 |
| `executed=0` | 什麼都沒跑(零個測試、資料列或請求) | 未證明,不是通過 —— 修正選取範圍 |
| `secret or internal-IP rule` | lane(或 canary)的 log 命中 `.claude/gitleaks.toml`;這次 run 判失敗 | 讓輸出別印出它;絕不貼那份 log |
| `lane files changed during the run` | lane 跑的時候它 paths 裡的檔案變了(至多點名五個)—— 你的修改,或 run 自己寫出的東西(例如 cache);紀錄作廢 | 把 run 自己寫的東西加進 gitignore;否則等改動停了再重跑 |
| `NOT DONE —` / `NOT CLOSED —` … `Not proven this time` | `done` 或 `close` 拒絕,並列出缺什麼(紀錄、checker、Codex、核准、lane 範圍外的檔、過期的 lane) | 補上缺的;說「完成」之前先讀「沒證明到什麼」那段 |
| `card changed since approval` / `CARD LINT —` | 你核准之後 card 被改了,或格式壞了 | 看過 diff 再核准一次 / 修掉 lint 指出的地方 |
| `scratch_in_mailbox` / `AGENTS.md differs from CLAUDE.md` | judge 往 `pair/` 寫了東西(這次 run 作廢)/ judge 會讀到錯的說明 | 不用做事 —— 它會重跑 / 刪掉 `AGENTS.md`,或用 `CLAUDE.md` 蓋過它 |
| `bash-guard` 跳出的確認提示 | 離開專案的 `rm -rf`、碰 `.env` 或 `.secrets/`;task 進行中的 `git add -A`/`.`、`git checkout [--] <path>`、`git checkout .`/`-f`、`git switch --discard-changes`/`-f`、`git restore`(單獨的 `--staged` 除外)、`git stash`(`list`/`show` 除外);任何時候:碰 `.claude/evidence/` 或 trust 檔的命令、寫 donelog、`pair/` mailbox 或 Codex 的 session log、寫證據鏈信任的腳本或設定(`evidence.sh`、各 hook、`guard-patterns.sh`、checker agent、gitleaks wrapper、`harness-report.sh`、`settings.json`、`settings.local.json` —— 用 Edit 改它們也會問)、`evidence.sh trust`/`approve`/`check`/`codex`、`run --escalated`、`task-pair.sh --over-estimate` | 只核准你真的要的;trust、approve、check 就是你的簽核。`bypassPermissions` 下 hook 的 ask 都不會出現 —— 只剩 `settings.json` 自己的 ask(trust/approve/check、對證據鏈檔案的 Edit ask、push/reset --hard/clean/sudo 與 `rm -rf ~/*` 這類規則) |
| `BASH GUARD — blocked (…)` | force-push、提權命令、`rm -rf /`:永不無人值守執行;記在 `private/bash-guard.log` | 真的要,就自己跑 |
| 讀 `.env*` / `.secrets/` 被權限拒絕 | H1:Claude 永遠不讀密鑰 | 密鑰放那裡;程式在 runtime 讀 |
| `WARNING: state.md last updated …` / `… is newer than state.md` / `WARNING: … bytes (cap …)` / `TRUNCATED: first 4096 of` | 記憶過期,或上個 session 沒跑 `/wrap`;或被注入的檔超過上限(state.md 5120、card.md 4096 —— 會被截斷、notes.md 16384、CLAUDE.md 20480) | `/wrap`;蒸餾,或把細節移到 `notes.md` |
| `has been idle` … `the Stop gate does not check it` / `a v3 plan.md task without card.md` | task 閒置超過 7 天 / `tasks/CURRENT` 指向 v3 task,v4 既不注入也不檢查 | 用 `/task` 續跑或刪 `CURRENT` / 在 `v3-final` checkout 上做完、改寫成 card,或刪 `CURRENT` |
| `harness-report.sh`:`defect candidate` | `Closed:` 之後 30 天內有 fix commit 動到這個 task 的檔 | 確認(`/defect`)或排除(`harness-report.sh --defect-dismiss <sha>`) |

## 8. 速查表

| 動作 | 指令 |
|---|---|
| 新專案 | `./start_project.sh [--kind code\|research\|analysis] <name>` |
| 日常收尾 | `/wrap` |
| 大任務 | `/task <描述>` |
| 大任務(無人值守) | `/task --auto <描述>` |
| 放棄任務 | `/wrap`(記成 abandoned),或刪 `.ai_context/tasks/CURRENT` |
| 設置 / 重起草專案簡報 | `/setup` |
| trust 一條 lane | `bash scripts/evidence.sh trust <lane>` |
| 跑一條 lane | `bash scripts/evidence.sh run <lane>` |
| 把 slice 標成完成 | `bash scripts/evidence.sh done S<n>` |
| 任務進行到哪了? | `bash scripts/evidence.sh status` |
| 不經 Codex 讓一個單元過關 | `bash scripts/evidence.sh approve --waive <S<n>\|card\|final> --reason "…"` |
| 記下 done 之後才發現的缺陷 | `/defect` |
| 清掉舊的 lane log | `find .claude/evidence/logs -mtime +30 -delete` |
| 狀態行(選用) | 在 `.claude/settings.local.json` 加 `"statusLine": {"type": "command", "command": "bash scripts/evidence.sh status --line"}` |
| 舊專案升級 | `./sync-project.sh <path>` |
| 升級 + 推進 stock 檔 | `./sync-project.sh --update-stock <path>` |
| 收編既有 repo | `./sync-project.sh --adopt <path>` |
| 全域層更新 | `./bootstrap-machine.sh --force-global` |

建議的第一步:讓 `/setup` 宣告一條快的 lane,再挑一個真實的中型任務跑一次,
完事讀 `bash scripts/harness-report.sh` —— 那是「這套 harness 在你的工作負載
上值不值」的第一筆數據。
