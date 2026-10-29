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
context 壓縮、人類健忘之下依然成立。第五層讓大任務保持誠實:`/task`
用一頁 card 帶著長程工作走,而在腳本記錄下產品真的跑過、獨立的檢查者
也看過之前,什麼都不算完成。

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
│ 第 5 層 — 執行        /task + 證據 + 檢查者              │
│   長程 harness:一頁 task card、只有腳本能寫的            │
│   執行證據、每個 slice 一個全新檢查者、Codex             │
│   檢查 card、slice 與結案(pair 模式)。                   │
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
| 「Codex judge 只檢查、從不寫入,它的 verdict 只以紀錄的形式算數」(pair-codex) | `scripts/task-pair.sh`:關掉 hooks 啟動 judge;`AGENTS.md` 或 `AGENTS.override.md` 與 `CLAUDE.md` 不同就拒絕;每次 run 前後比對 tree 指紋(`tree_changed` 作廢該次 run);掃描對話框;judge 的草稿放在 `/tmp` 底下(`pair/` 裡多出任何東西就作廢:`scratch_in_mailbox`);六行 result 契約;自己永不印 verdict。每次真的送到 judge 的 run 都經 `evidence.sh codex` 變成一筆 `codex-<stage>` 紀錄(`not_started` 的嘗試不記錄也不計數);紀錄只有在 run 完成、`verdict: pass`、0 個 blocker、0 個 major,且 judge 自己用 `apply_patch` 寫出這份 result 的動作出現在它的 Codex transcript 裡(`prov=ok`)時才算核准。pair 開啟期間,`done` 與 `close` 需要核准的 card、`codex: yes` slice 與 final 紀錄 —— 或你的豁免 `evidence.sh approve --waive`(要你確認,card 一改就失效)—— `tests/run.sh` L1-23、L1-39–L1-44、L1-47 以 fake herdr 測試 |
| 「commit 裡不准有密鑰」(H1) | gitleaks pre-commit + `settings.json` 禁止讀取 `.env*` 與 `.secrets/**` |
| 「密鑰只給 runtime:程式可讀,Claude 和 git 不可」 | `.secrets/` 資料夾 —— Read 工具被 deny(`settings.json`)、Bash 觸及降級為確認提示(`bash-guard.sh`)、git 只看得見佔位檔;執行期讀取(`GOOGLE_APPLICATION_CREDENTIALS=.secrets/sa.json ...`)完全不受影響。Read 工具是硬擋,其餘是絆索 —— 能讀到密鑰的代碼永遠可能洩漏它,所以代碼不要把密鑰印到 stdout |
| 「state.md 不超過 5 KB」(S7) | pre-commit 大小檢查 + session 開始時警告 |
| 「會老化的事實要標日期」(S3) | session-start hook 偵測 `state.md` 過期並警告 |
| 「先證明,再開口」 | `/prove`、`/debug`、`/number-check`、`/backtest-check` 是模型可自行呼叫的 skill:描述符合當下情境時 Claude 會載入 —— 是指引,不是閘門 —— 每個都以可檢查的輸出收尾(引用的實跑輸出、`VERIFIED` / `NOT VERIFIED` / `INCONCLUSIVE` 標籤、每項檢查一行 pass/fail)。專案的 `verify` skill 由 `/setup` 從 `.claude/skills/setup/verify-template.md` 寫出,是 Claude Code 在 commit 前會跑的那一個,所以要維持在幾分鐘內。`/task` 裡的強制版本是下一列 |
| 「完成表示產品真的跑過 —— 由腳本記錄,不是口頭宣稱」 | 只有 `scripts/evidence.sh done S<n>` 能寫出 slice 的 `[x]`,紀錄編號接在 ` ✓ ` 後面。下列任一不成立它就拒絕,並逐條列出缺口:slice 引用的每條 lane 都有一筆在 `evidence.sh start S<n>` 之後、用目前 trust 的 lane 定義、對它 `paths` 目前內容跑出的通過紀錄;該 slice 在這份內容上有通過的 checker 紀錄(沒有 `NOT VERIFIED`,且第一條宣稱 —— slice 本身的結果 —— 是實際跑過的 `VERIFIED`,L4/L5;否則記為 fail);pair 開且 `codex: yes` 時,有核准的 `codex-slice` 紀錄或你的豁免;你的核准對得上目前的 card;slice 開始以來改動的檔案都在它的 lane `paths` 之內。Stop gate 重新檢查每個 `[x]` 的引用,不跑任何 lane。`/task` 之外仍由 CLAUDE.md 的 `Verify` + **Definition of done** 管 —— 散文,加上可選的 `lint.sh` post-edit hook |
| 「不可能失敗的檢查不算檢查」 | `evidence.sh trust <lane>` 拒絕純靜態指令(每一段都是 `bash -n`、`py_compile`、`shellcheck`、`grep`/`rg`、`test`、`ls`、`cat`、`echo`……,或帶 `--help`、`--version`、`--list-*`、`--parse-check`、`--selftest`、`--dry-run`、`--collect-only`)、空的或空洞的 canary(`false`、`exit 1`、lane 自己的指令),以及底下沒有任何被追蹤或未被忽略檔案的 paths;`.claude/done-lanes` 本身就拒收 `min_secs` 小於 1 與空的 `expect`。之後它跑 canary —— 一個已知壞掉的輸入,必須讓 lane 變紅、把弄壞的東西復原、而且不印出任何會被 log 掃描抓到的東西;`canary = skip:<reason>` 要再跑一次 `--skip-canary`,也就是第二次確認 |
| 「證據屬於它跑過的那份內容」 | 每筆 run 紀錄綁定 lane `paths` 的內容 id(被追蹤與未被忽略的未追蹤檔,從 worktree 雜湊 —— 標了 assume-unchanged 或 skip-worktree 的檔也算;`.ai_context/` 與 `.claude/evidence/` 永遠不算):內容變了 → stale;跑的期間內容變了 → 作廢,並點名至多五個改動的路徑;單純 `amend`/`rebase` 不會讓它失效;早於該 slice `evidence.sh start` 的紀錄不算數 |
| 「零執行等於未證明」 | run 只有在 exit 0、每個 `expect` 標記都比對到、執行數 > 0(第一個標記那行的第一個數字)、且至少跑了 `min_secs` 秒時才通過;它的 log(`.claude/evidence/logs/`,權限 600)用 `.claude/gitleaks.toml` 掃描 —— gitleaks 預設規則加上內部 IPv4(放行 QEMU 的 `10.0.2.0/24`)、tailnet 主機名、URL 憑證規則;沒裝 gitleaks 時只用 `grep -E` 跑內部 IP 規則 —— 命中就判失敗;`done`、`close`、`show` 最後一定列出這些紀錄*沒有*證明什麼 |
| 「你對 card 的核准是一筆紀錄」 | `evidence.sh approve` 要你確認後才跑,寫一行帶 card digest 的 `APPROVE` donelog 列(狀態標記、` ✓ ` token 與 `Closed:` 行不計);之後任何其他修改,`start` 會拒絕、`done`/`close` 會列出缺口,直到你再核准一次。card 沒通過 `evidence.sh lint` 時 `approve` 拒絕:header、`Goal:`、`Done when: … ; outside check:`、帶標籤的決策、能解析且只引用已宣告 lane 的 slice 行、沒有重複編號、至多一個 `[~]`、引用的 `notes.md` § 都存在、≤4096 B 且留得下證據後綴 |
| 「三振是機械的」 | 同一條 lane 在同一個 slice(自它 start 起)連續失敗三次 → `evidence.sh run` 寫一行 `ESCALATE` 並拒絕下一次(exit 5);`run --escalated` 要經 bash-guard 確認才繼續(這是 hook 的 ask —— `bypassPermissions` 下不會出現);`/debug` 規定三次就停下回報 |
| 「被擋下的停止必須抵達人類,不能死在 transcript 裡」 | 計數式讓行:同一 session、同一份 card 與內容上連續擋兩次之後,第三次停止 exit 0,寫一行 `STUCK` donelog 列並發出 `{"systemMessage"}` —— 交棒是看得見的,不是無聲放行;每個(session、card、內容)只寫一行 `STUCK`,記分板把一次交棒算成一次。計數器放在專案之外(`$TMPDIR`,沒有就 `/tmp`);寫不進去時立刻讓行並寫 `GATE-ERROR` 列,不做沒有上限的擋 |
| 「擋下必須在宿主 CLI 手上活下來,不只是在 hook 裡」(v3.14) | 每條 exit-2 路徑先印一行固定的 stdout marker —— 否則 CLI 的 missing-hook heuristic(`exit 2` + 空 stdout + stderr 符合 `/no such file\|can't open/i`,觀察到 2.1.229 為止)會把正當的擋下降級成不擋。v4 的外層只有在內層 exit 2 且第一行是那個 marker 時才把擋下傳出去。L1-21 逐一測每條擋下路徑 |
| 「執行中的檢查是喚醒保證,不是紅燈」 | `evidence.sh run` 與 `task-pair.sh send` 執行期間在 `.claude/evidence/locks/` 持有 pid lock;閘門遇到 pid 還活著(有 `ps` 時還要確認仍是 `evidence.sh` 或 `task-pair.sh`)的 lock,或 Stop payload 的 `background_tasks` 裡有 `"type": "subagent"` 的項目,就延後 —— 寫 `WAITING` donelog 列 + systemMessage,安靜地停;跑完時會喚醒 session。pid 已死的是過期 lock(`evidence.sh status` 會清掉),不算等待 |
| 「閘門的 bug 永遠不會卡住工作」 | 閘門分兩層跑:外層只有在內層 exit 2 且第一行是 marker 時才傳出擋下;其他任何情況 —— 崩潰、語法錯誤、25 秒沒回應 —— 都變成一行 `GATE-ERROR` donelog 列加一則 systemMessage,這次停止放行。只有證據會擋。閒置超過 7 天的任務(card、donelog、`task/<slug>` 分支都沒動)不注入也不檢查,v3 的 `plan.md` 任務也一樣 |
| 「獨立 checker 真的跑過 —— 由 hook 說了算,不是計畫說了算」 | `spawn-log.sh` 掛在 `SubagentStart`/`SubagentStop`,依 matcher 分流(`executor`、`checker`;分流不解析 payload),寫 `SPAWN`/`RETURN` donelog 列;checker 結束時它只從這一次喚醒取報告 —— 它的 `SubagentHandback` 訊息,沒有就取 payload 的 `last_assistant_message`,再沒有就取 transcript 裡它最後一段文字 —— 交給 `evidence.sh check` 寫出 `done` 要求的 checker 紀錄。什麼都沒抓到 → `uncaptured`;檢查期間該單元內容變了 → `void`;`done` 兩者都不收 |
| 「重新錨定最多一頁」 | session-start 注入 INDEX + state + 進行中的 card —— 4096 B,超過就在最後一個完整行截斷並警告 —— 加一行 `evidence.sh status --line`;`notes.md` 永不注入(超過 16 KB 警告),executor 與 checker 只讀 slice 行引用的那個 `§`;CLAUDE.md 超過 20 KB 警告 |
| 「長任務會衰變:漂移、無聲錯誤、狀態流失」 | `/task` v4:一頁你核准的 card、slice 1 是最薄的真實端到端路徑、每個 slice 一個全新 `executor` 與一個獨立 `checker`、pair 開時 Codex 檢查 card、`codex: yes` slice 與結案(pair 關時由 checker 檢查 card —— 給你看的報告 —— 與結案)、卡住時用 `/debug`;狀態放在 hooks 會重新注入的檔案裡 |
| 「範圍蔓延看得見」 | `harness-report.sh --tripwire`(`evidence.sh status` 會顯示,觸發後狀態行也會)比較這個任務在 `@verify-paths` 底下新增的行數與其他地方的行數,以及核准以來的時數與行數相對 card 估計;任一超過 2 倍,或驗證程式碼比產品程式碼多 50 行以上,就顯示 `TRIPPED` —— 是報告,永遠不擋 |
| 「slice 是看得見的東西,每個決策都標明是誰做的」 | card 上每個 slice 寫出使用者會看到什麼與它的 lane;`Decisions:` 每條帶 `[human]`、`[inferred]`、`[own]`,或 —— `--auto` 沒問就做的意圖判斷 —— `[ASSUMED]`(`lint` 拒收沒標籤的);`[o]` 表示 slice 在等負責人 —— 會顯示,但永遠不擋停止(`close` 仍要它是 `[x]`) |
| 「新專案的第一個 session 要完成設置」 | session-start 的 `SETUP REQUIRED` 指令 + Stop gate 擋住第一次回合結束(每 session 一次);兩者都認 CLAUDE.md 裡的 `claude-starter: UNCONFIGURED` sentinel,`/setup` 起草完成時刪掉它 |
| 「檢查不能被悄悄換掉」 | lane 放在 `.claude/done-lanes`(≤3,一行一條;`cmd` 與 `canary` 不能有 `\|` —— 更長的寫成 wrapper script);`evidence.sh trust <lane>` —— 要你確認:你讀過那一行 —— 把整條 lane 行、它的 `cmd` 與 `canary` 連同它們提到的每個 repo 檔、每個 `@` 行、`.claude/gitleaks.toml` 雜湊進 `.claude/done-lanes.trust`(入 git、append-only、只有 `trust` 會寫、Edit 被 deny);任何一項不同時 `run` 都拒絕,舊定義下的紀錄也不再算數 —— 所以改 lane、改它呼叫的腳本、改指令行或掃描規則,都要在你面前重新 trust |
| 「災難性 bash 絕不無人看管地執行」(永不 force-push、不 sudo) | `bash-guard.sh` PreToolUse 絆索:任何拼寫的 force-push(旗標或 `+refspec`)/ `sudo` / 根目錄刪除(含 `--no-preserve-root`,v3.10)一律拒絕並記錄到 `private/bash-guard.log`;跳出專案樹的 `rm -rf`(絕對路徑、`~/`、`$HOME/`、`..` —— v3.14.3)與 `.env` 存取降級為確認提示 —— session 自己的 `/tmp/claude-*/…/scratchpad` 樹除外(v3.14.1:harness 本來就會丟掉它,每次清理都問只會訓練出無腦點過)。hook 是唯一的 `rm` 層:v3.14.2 把 `settings.json` 的 `Bash(rm -rf:*)` ask 規則拿掉了 —— CLI 對宣告式 `ask` 規則在所有模式(含 bypass)都會問、逐子指令比對、不管 hook 說什麼,所以那條規則在 hook 之外每次清理 scratchpad 都跳確認,任何 hook 端的豁免都碰不到它(CLI 內建的關鍵路徑保護仍會在所有模式下對根目錄 / 頂層目錄 / home / cwd 的刪除發問)。宣告式 `ask`(push、reset --hard、clean、sudo)與 `deny` 規則留在 `settings.json`,給的是連 bypass 下都該問的事 —— v3.14.3 再加三條給 `rm -rf ~/*`、`$HOME/*`、`../*`:bypass 會丟掉 hook 的 ask,而這三種寫法永遠碰不到 `/tmp` 的 scratchpad,所以能在 bypass 下發問又不會連環確認;hook 端也鏡射它們(任何旗標拼寫),給其他模式用。v3.14.4:ask 層改讀剝掉 heredoc 內文的指令 —— 寫進記憶檔的文字不是指令(fleet 的 48 次 subagent `.env` 卡關有 17 次就是這樣,每次中位數等 10 分鐘),而且專案自己的樹對 `rm -rf` 比照 scratchpad 豁免;deny 層仍讀全文。v3.14.5:`/tmp/<name>…` 也放行 —— 開發機上 `/tmp` 本來就是可拋棄的,fleet 的 subagent 刪過的 `/tmp/<name>` 全是自己建的 —— 但 `/tmp`、`/tmp/`、`/tmp/*` 照問(整棵 `/tmp/claude-<uid>` 會放行:已知邊界)。contains 匹配強過前綴規則 —— 但它是絆索,不是沙箱 |
| 「任務中的工作絕不整批 stage 或整批丟棄」 | 任務進行中,`bash-guard.sh` 在下列指令前發問:`git add -A`/`--all`/`.`/`:/`/`*`、`git checkout [ref] [--] <path>`(任何一個字指到既有路徑)、`git checkout .`、`git checkout -f`、`git switch --discard-changes`/`-f`、`git restore`(單獨的 `--staged` 除外)、`git stash`(`list`/`show` 除外);`git commit -a` 不問(它不會丟東西)。checker 被告知絕不改動 git 狀態(`checker.md`;它沒有 Edit 或 Write 工具)—— 這是 prompt 規則,不是鎖 |
| 「`--local` 生成永不帶走本機狀態」 | 複製改用 `git archive HEAD` —— 只帶被追蹤的內容:gitignore 的憑證(`.secrets/`)、本機設定、未追蹤的草稿全部留在原地;未提交的模板修改也不會跟著走(先 commit)。非 git 來源退回 `cp -R` + 清除已知洩漏點(v3.10) |
| 「失敗與放棄的任務也要進資料集」 | `harness-report.sh --row <slug>` 只從 card 與 donelog 算出記分板列 —— run 紀錄是每台機器各自的;只有 card 有 `Closed:` 行且有對應的 `CLOSE` 列時 `outcome` 才是 `success`,否則必須給定(`--outcome failed\|abandoned`,問你);`/wrap` 在每次收尾(包含放棄)把這列追加到 `.ai_context/scoreboard-v4.csv`,報表也會列出從沒進記分板的任務目錄 |
| 「每筆記分板列都標明產生它的 harness 版本」 | `harness-report.sh --row` 從 `.claude/.starter-version` 最後一行的 `claude-starter@<ref>` 戳記填入 `harness` 欄;release 都打 git tag,ref→版本的對映是機械的。戳記說真話(v3.10):**任何**改動了機制的 sync 都追加 `synced-to:` 戳記(不再只限 `--update-stock`);GitHub 模式生成蓋的是實際 clone 到的 template head,不是可能過期的 spawner checkout |
| 「harness 的摩擦是資料,不是體感」 | `/wrap` 只在機制真的出問題時把枚舉列(`area` × `severity`)寫進 `.ai_context/friction.csv`;`harness-report.sh` 把它們和 donelog 的 `STUCK`、`GATE-ERROR` 列並列報告 |
| 「評分是算出來的,不是回憶出來的」 | `scripts/harness-report.sh`(CI 有測)按 harness 版本彙總 donelog、card、pair runlog、`scoreboard.csv`(v3 列,現在唯讀)、`scoreboard-v4.csv`、`defects.csv` 與 `friction.csv`;`--csv` v2 第一欄是 `csv_version`;N<5 不印百分比;刻意不存在綜合分數 |
| 「評分資料要交叉核對,不是照單全收」 | `harness-report.sh` 的 `== integrity` 列出有 card 卻沒有記分板列的任務目錄、不是 `evidence.sh done` 寫的 `[x]` slice、沒有 `CLOSE` 列的 `Closed:` 行、記分板與 donelog 不一致(擋下數、STUCK 數、Codex run 數)與枚舉違規;`== defects` 列出任務結案後 30 天內、動到它的檔案的修復 commit —— 由你確認(`/defect`)或排除(`--defect-dismiss <sha>`)的候選。一律不自動修復 |
| 「缺陷是數出來的,不是記得的」 | `.ai_context/defects.csv`(`date,slug,slice,finder,phase,severity,n,summary,fixed_in,ref`)的列來自:每筆帶 `NOT VERIFIED` 宣稱的失敗 checker 紀錄(severity `unrated`)與每筆有 blocker 或 major 的 Codex slice/final 紀錄 —— 這兩種由 `evidence.sh` 自己寫 —— 加上你確認的修復 commit 候選,以及你用 `/defect` 記下的負責人、正式環境或結案後審查發現;全部經過 `harness-report.sh --defect`,它推導 `phase`(pre-done、post-done、post-close),並拒收沒有對應帳本紀錄的 checker 或 Codex 列。標頭不同的 `defects.csv` 會被報告並略過,永不追加 |
| 「常駐注入的檔案必須保持小」 | card 4096 B(注入時截斷、`lint` 拒收)、INDEX 大小測試 + 超過 4 KB 時 session-start 警告、`state.md` 5 KB pre-commit 上限 + 警告(S7)、`notes.md` 超過 16 KB 警告、CLAUDE.md 超過 20 KB 警告 |
| 「大塊資料外部化」(S2) | `check-context-bulk.sh` pre-commit:任何 staged 的 `.ai_context` 檔案超過 100 KB 即擋下 —— dump 用引用,不用貼上。任務 donelog(與 v3 的 gatelog/spawnlog)豁免:它們是機器 log、append-only,長任務本來就會超過上限 |
| 「記分板數字必須是真的」 | `scoreboard-v4.csv` 每一欄都來自 card 或 donelog(`harness-report.sh --row`);`interventions` 在專案內一律是 `-` —— 它只能從 session transcript 數出來,不能靠記憶 |
| 「append-only 檔案永不改寫」(decisions、journal、兩份記分板、friction、defects、任務 donelog、`.claude/done-lanes.trust`、v3 的 gatelog/spawnlog) | `check-append-only.sh` pre-commit:staged 變更若修改或刪除既有行 —— 或刪掉檔案本身 —— 即拒絕;更正靠追加。`knowledge/lessons/*` 依設計就地更新 —— 一個 lesson 一個檔 |
| 「證據只由腳本寫入」 | `settings.json` 對 `.claude/evidence/**`、`.claude/done-lanes.trust`、`.claude/gitleaks.toml`、`tasks/**/donelog`、`tasks/**/pair/**`、`~/.codex/sessions/**` 與 v3 凍結的 `gatelog`/`spawnlog` 禁用 `Edit(...)`(Edit 規則也涵蓋 Write),並在 Edit 證據鏈信任的腳本、hooks、checker agent 與設定檔前發問;`bash-guard.sh` 在下列情況發問:提到帳本或 trust 檔、但不是單一一個允許的 `evidence.sh run\|status\|show\|start\|done\|close\|lint` 呼叫的指令;用 Bash 寫 donelog、`pair/` mailbox、Codex 的 session log 或上述腳本與設定檔;以及 `evidence.sh trust`、`approve`、`check`、`codex` 與 `run --escalated`。`bypassPermissions` 下 Claude Code 會丟掉 hook 的 ask:那時只剩 `settings.json` 的規則會攔你 —— Edit 的 deny 與 ask,以及 `evidence.sh trust`、`approve`、`check` 的宣告式 ask。append-only pre-commit 替 donelog 與 trust 檔做後盾。這是防捷徑與失手的絆索,不是防蓄意繞過的沙箱:用 glob、變數或 symlink 指向腳本就能繞過 bash-guard —— 最後一道防線是 checker 與 Codex 重跑 lane |
| 「沒跑 /wrap 就死掉的 session」 | session-start 偵測 commit 比 `state.md` 新時發出警告 |

---

## 快速開始

> 實戰教程(生成 → 日常迴圈 → `/task` → pair 模式):
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

只補上缺少的機制檔案(絕不覆寫),其餘以建議清單印出。`--update-stock`
還會把可證明未被客製的 stock 檔推進到新版,並刪除模板已退役檔案的 stock
副本(v4 退役了九個);客製過的檔案絕不碰。專案裡若有在 v3 下開始的
`/task`,要先做完或放棄 —— 有進行中的 v3 任務時 `--update-stock` 會拒絕。
詳見 [MIGRATION.md](./MIGRATION.md)。

---

## 長程任務 —— `/task`

記憶層讓 *session 之間*連續;`/task` 讓*單一大任務*保持誠實。v4.0 起,
它靠三件事撐住,而不是規劃儀式與會跑 verify 的閘門:一頁你核准的 card、
只有腳本能寫的執行證據、每個 slice 一個獨立的檢查者。

1. **Intake** —— 先讀需求會碰到的東西再開口;複述目標;問那一個最能改變
   做出什麼的問題,外加「什麼情況下就算每個檢查都綠你也會退件?」;給 2–3
   個做法,附上建置成本與驗證成本;實證型的分岔用 ≤30 分鐘的拋棄式實驗解決;
   沒被要求的機制寫成「考慮過、沒做」,不直接做出來。
2. **Card** —— `tasks/<slug>/card.md`,≤4 KB,每個 session 都注入:目標、
   對「跑起來的產品」的完成判定加一個外部檢查、帶標籤的決策,以及 slice ——
   slice 1 是最薄的真實端到端路徑,每個 slice 寫出你會看到什麼與它的 lane。
   細節放 `notes.md`(永不注入;slice 行引用它的 `§`)。`evidence.sh lint`
   檢查格式;`evidence.sh approve` 在你確認後記下你的同意。pair 模式開著時,
   Codex 先檢查 card,而 `done`/`close` 需要這份審查(或你的豁免);關著時
   由 checker 檢查 card —— 那是給你看的報告,不是必要條件。
3. **Lane** —— 每個專案最多三條,寫在 `.claude/done-lanes`。
   `evidence.sh trust <lane>` 先問你,拒絕靜態檢查,跑 canary(必須失敗),
   再把 lane 那一行、它的指令與 canary 提到的檔案、每個 `@` 行與
   `.claude/gitleaks.toml` 的雜湊釘住 —— 任何一項改了,都要你重新 trust。
4. **Slice 迴圈** —— `evidence.sh start S<n>` → 全新的 `executor` 做這個
   slice、用 `evidence.sh run` 跑它的 lane、按路徑 commit → 全新的
   `checker` 拿到 card、diff 與原始紀錄 —— 永遠拿不到 executor 的摘要 ——
   並親自重跑 ≤10 分鐘的 lane → `codex: yes` 的 slice 交給 Codex(pair 開時)
   → `evidence.sh done S<n>` 寫出帶紀錄編號的 `[x]`,或列出還缺什麼。
5. **閘門** —— `stop-gate.sh` 不跑任何 lane。它檢查每個 `[x]` 都引用了通過的
   紀錄、`Closed:` 行仍然新鮮;lane、Codex 傳送或 subagent 還在跑時就等;
   其餘情況印一行狀態、讓回合結束。閘門的 bug 會被記錄並放行,永遠不會卡住。
6. **卡關** —— `/debug`:先重現,一次改動一個假設;兩次修失敗 → 寫下它們
   共同的前提並測試;三次 → 停下回報。`evidence.sh run` 會強制執行:同一條
   lane 在同一個 slice 連續失敗三次後,下一次 run 要你確認(`ESCALATE`)。
7. **結案** —— `evidence.sh close` 要求每個 slice 都是 `[x]`、card 引用的每條
   lane 在最終的樹上都新鮮、自 card 的 base 以來沒有落在這些 lane paths 之外的
   改動,以及一次最終檢查 —— pair 開時是 Codex(或你的豁免)、關時是 checker
   的 `final` 通過 —— 接著是你對 repo 外部分的驗收,最後 `/wrap` 把
   `harness-report.sh --row` 算出的列追加到 `.ai_context/scoreboard-v4.csv`
   並清掉 `tasks/CURRENT`。在那之前,`.ai_context/` 以外的任何改動都會讓
   `Closed:` 行過期、閘門會擋;在那之後,什麼都不再檢查。

狀態放在 `.ai_context/tasks/<slug>/`(`card.md`、`notes.md`、`donelog`、
`pair/`)並入 git,`.claude/done-lanes` 與 `.claude/done-lanes.trust` 也是;
run 紀錄與 lane log 放在 `.claude/evidence/`,每台機器各自一份、gitignore
(log 不會自動清:`find .claude/evidence/logs -mtime +30 -delete`)。紀錄在
別台機器上產生的 `[x]`,只要它的 `DONE` 列已 commit 就會通過。分數從 card 與
donelog 算出來,從不取自模型的說法。

**Lane。** 一條 lane 一行、欄位固定,外加 `@` 指令行:

    # name | paths | min_secs | expect (; separated, all must match) | canary | cmd
    @pair codex
    @verify-paths tests/ probes/
    smoke | . | 4 | ^verify: [1-9][0-9]* passed, 0 failed$ | <cmd that must fail> | bash scripts/verify.sh

`@pair codex` 讓 pair 模式成為專案預設;`@verify-paths` 指出測試與 probe
程式碼的位置,給 tripwire 報表用;`@ext <lane> <cmd>` 印出某條 lane 跑的外部
repo 的 commit,`close` 會檢查它沒有移動。`cmd` 與 `canary` 欄不能有 `|`:
需要 pipe 或不只一個好讀指令的,寫進 lane 呼叫的 wrapper script。任務的每個
改動都必須落在它的 slice 所引用 lane 的 paths 裡(`smoke` 用 `.`,文件與設定
也涵蓋在內);run 也不能在它的 paths 裡留下未追蹤、未忽略的檔案 —— 把它寫出
的 cache 加進 gitignore,否則紀錄作廢。快的路徑同時寫進專案的 `verify` skill
(Claude Code 會在 commit 前跑它);慢的(VM、完整回測)各自一條 lane、各自的
paths,在背景跑,閘門會等。

**Pair 模式。** 唯一的非 Claude 席位:一個在 [herdr](https://herdr.dev) 相鄰
pane(名為 `judge-<repo id>-<slug>`)裡、用你的 Codex 預設模型跑的 Codex judge
(不傳模型或 effort)。Claude 執行、Codex 檢查 —— 在三個點:動工前的 card、每個
標了 `codex: yes` 的 slice(金錢、密鑰、安裝),以及結案時的整個分支。
`.claude/done-lanes` 裡的 `@pair codex` 是專案預設(加上它就要重新 trust 一條
lane:`@` 行是 trust 的一部分);card 的 `pair:` header 只能調高、不能調低。
`scripts/task-pair.sh` 是筆:它產生每一份 packet(`check card`、
`check slice S<n>`、`check final`;`--since` 預設是、也必須是該 slice 的 start
head 或 card 的 base),關掉 Codex hooks 啟動 judge,`AGENTS.md` 或
`AGENTS.override.md` 與 `CLAUDE.md` 不同就拒絕,每次 run 前後比對 tree 指紋
(run 進行中什麼都不要改),把 judge 的草稿放在 `/tmp/pair-<repo hash>-<slug>/`
(`pair/` 裡多出任何東西就以 `scratch_in_mailbox` 作廢),只回應它認得的
Codex 對話框 —— 更新通知與 rate-limit 提示送 `esc`,`/new` 之後只在
"Use current Git worktree" 上送 `enter`;其他任何對話框都停下交給你(exit 4)
—— 自己永不印 verdict。它的執行狀態放在 `.claude/evidence/pair/<slug>/`。
judge 用六行固定格式回答(`run:`、`verdict:`、`base:`、`blocker: N`、
`major: N`、`minor: N`),只有在 run 完成、verdict 是 `pass`、沒有 blocker 也
沒有 major,而且 result 可證明出自 judge 時才算通過:它自己用 `apply_patch`
寫這個檔的動作出現在它的 Codex transcript 裡、那一輪正常結束、檔案內容仍是它
寫的。每次真的送到 judge 的 run(失敗的也算)都經 `evidence.sh` 變成一筆
`codex-<stage>` 紀錄,所以 `done` 與 `close` 讀 Codex 的結果就像讀 lane 的
結果;從沒變成一輪對話的嘗試(`not_started`)不記錄也不計數。run 會花你的
Codex 額度,你同意兩次:pair 開著啟動 `/task` 涵蓋 card 檢查與一次重試;核准
card 涵蓋它的估計 —— 每個 `codex: yes` slice 一次、final 一次、每個單元一次
重試、一輪反駁 —— 從這個任務的 Codex 紀錄計數。超過估計時 `task-pair.sh` 停下
(exit 3)問你;重新檢查上一次完成的審查已判失敗的同一份內容也一樣。Codex
無法回答時(同一份內容兩次 run 都沒有 verdict,或額度用完),`done`/`close`
對那個單元會一直拒絕,直到它通過或你豁免它:
`bash scripts/evidence.sh approve --waive <S<n>|card|final> --reason "…"`
—— 要你確認、會被記錄、card 一改就失效。對話框文字是在 Codex 0.165.0 與
herdr 0.9.0 上錄的。

**權限。** `evidence.sh run`、`status`、`show`、`start`、`done`、`close`、
`lint`,以及 `task-pair.sh check` 與 `wait` 在 allow 清單裡,所以預設權限模式
下 slice 可以無人值守地跑。`trust`、`approve`、`check` 一定會問:bash-guard
會問,而且它們也是 `settings.json` 裡的宣告式 `permissions.ask` 規則。在
`bypassPermissions`(`--dangerously-skip-permissions`)下 Claude Code 會丟掉
hook 的 ask,所以那時只剩 `settings.json` 會攔你 —— 那三條規則、對證據鏈信任的
腳本、hooks、checker agent 與設定檔的 `Edit` ask、`git push` / `reset --hard` /
`clean` / `sudo` / `rm -rf ~/*` 這類 ask,以及對帳本、trust 檔、donelog、pair
mailbox 與 Codex session log 的 `Edit` deny。bash-guard 在任務中的 git ask、
帳本與 donelog 的寫入 ask、`run --escalated` 與 `--over-estimate` 在那裡都不會
觸發;它的擋下(force-push、`sudo`、`rm -rf /`)照擋。這些都不是沙箱:用 glob、
變數或 symlink 指向 `evidence.sh` 就能繞過 bash-guard。

**狀態行(選用)。** 在 `.claude/settings.local.json` 加上
`"statusLine": {"type": "command", "command": "bash scripts/evidence.sh status --line"}`;
模板的 `settings.json` 不動你自己的狀態行。

**無人值守。** `/task --auto` 把意圖型判斷記成 card 上的 `[ASSUMED: …]` 決策
而不是發問,收尾時全部列出。核准、trust、破壞性與對外的步驟仍等你。`/goal`
只用在會收斂的機械性工作 —— 明確的證據條件加回合上限,永遠不做方向決定。

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
│   ├── gitleaks.toml           lane log 掃描規則:gitleaks 預設 + 內部 IP
│   ├── hooks/
│   │   ├── session-start.sh    注入 INDEX+state(+ task card、狀態行)
│   │   ├── post-edit.sh        編輯後即時 lint 回饋(委派 lint.sh)
│   │   ├── bash-guard.sh       PreToolUse 絆索(force-push/sudo/rm -rf /;帳本與任務中的 git ask)
│   │   ├── guard-patterns.sh   共用 matcher + task helper + setup sentinel
│   │   ├── spawn-log.sh        executor/checker 的 spawn → donelog + checker 紀錄
│   │   ├── stop-gate.sh        /task 證據閘門 —— 讀紀錄、不跑 lane
│   │   └── lint.sh.example     語言 init 之後填入你的 linter
│   ├── agents/                 /task 班底:executor(一個 slice、全新 context)、
│   │                           checker(每個 slice 一次獨立檢查)
│   └── skills/
│       ├── wrap/SKILL.md       /wrap —— session 收尾記憶寫回
│       ├── wrap/reference.md   任務收尾、lesson、缺陷、friction 列(按需載入)
│       ├── task/SKILL.md       /task —— card、lane、slice 迴圈、結案
│       ├── task/reference.md   card 格式、lane 範例、無人值守(按需載入)
│       ├── task/pair.md        pair-codex:card / slice / final 檢查(按需載入)
│       ├── setup/SKILL.md      /setup —— 第一次 session 的出生協定、lane
│       ├── setup/verify-template.md  專案 verify skill 的範本
│       ├── prove/SKILL.md      /prove —— 任何 done/fixed 宣稱之前先拿出證據
│       ├── debug/SKILL.md      /debug —— 先找原因再修;失敗 2 次 → 查前提,3 次 → 停
│       ├── defect/SKILL.md     /defect —— 記下 done 之後才發現的缺陷(使用者呼叫)
│       ├── backtest-check/SKILL.md  /backtest-check —— 回測與策略評估的完整性檢查
│       └── number-check/SKILL.md  /number-check —— 回報量測數字前先檢查它
├── .ai_context/                第 3 層(schema v4)—— INDEX、state、decisions…
├── .secrets/                   Runtime-only 憑證(Read 拒讀 · git 不追蹤)
├── .pre-commit-config.yaml     H1 密鑰掃描 + S7 大小上限 + S2 大宗 + append-only 守門
├── scripts/                    pre-commit 守門 + evidence.sh(lane、紀錄、
│                               done/close)+ task-pair.sh + harness-report.sh
├── tests/run.sh                L1+L2 回歸套件(CI 內建執行)
├── .mcp.json.example           MCP 樣板(--kind analysis 保留)
├── .github/workflows/lint.yml  模板 repo 自身的 CI(生成時移除)
├── start_project.sh            生成器(驗證、個人化、清理)
├── bootstrap-machine.sh        機器設定 + 全域層升級
├── sync-project.sh             升級專案(補檔;--update-stock 推進並退役 stock 副本)
├── NOTICE                      第三方 MIT 聲明(隨專案出貨)
├── MIGRATION.md                v3 → v4、v2 → v3、v1 → v2,以及更舊佈局的遷移
├── TUTORIAL.md                 實戰教程(生成專案時移除)
└── TUTORIAL.zh-TW.md           實戰教程繁中版(生成專案時移除)
```

---

## 設計原則

### 硬規則(在每個專案的 `INDEX.md`)

- **H1 — 不寫密鑰。** 機制:gitleaks + 禁讀 `.env*` 與 `.secrets/`
  (runtime-only 資料夾:程式讀得到,Claude 和 git 讀不到)。
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

- **不做角色人設(PM / Backend / QA)。** 內建的 agent 是 `/task` 的兩個
  工作階段(執行一個 slice、檢查它)—— 不跑 `/task` 就完全惰性。需要更多
  任務型 agent 在專案層自行加。
- **不做規劃儀式。** v3 的 planner 扇出、plan critic、風險分級、升級梯與
  reframer 都拿掉了:fleet 數據顯示計畫變大、卻看不出能多抓到問題,真正
  抓到 bug 的是獨立檢查(MIGRATION,v3-final → v4.0)。
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

**Q:專案可以留在 v3 嗎?**

可以。`v3-final` 打了 tag;從 `v3-final` 的 checkout 跑 `sync-project.sh`,
專案就維持 v3 的機制;在 v3 下開始的任務也要在那裡做完 —— v4 接不下去。
v3 若有修補,從 `v3-final` 切出的分支發出。若 v4.0 本身要撤掉,模板用一個新
commit 回退,不 force-push:
`git revert --no-commit v3-final..v4.0 && git commit` —— 已同步專案的做法見
[MIGRATION.md](./MIGRATION.md) §-9 Rollback。

**Q:commit 時也能掃內部 IP 嗎?**

預設不會:`.claude/gitleaks.toml`(gitleaks 預設規則 + 內部 IP、tailnet 與
URL 憑證規則)只套用在 lane 與 canary 的 log 上,pre-commit 掃描沿用 gitleaks
自己找設定檔的方式。要在 commit 時套用同一套規則,在 repo 根目錄加一個
`.gitleaks.toml`:

```toml
[extend]
path = ".claude/gitleaks.toml"
```

之後在 repo 根目錄找設定檔的 gitleaks 執行 —— pre-commit 掃描、
`gitleaks dir .` —— 都會讀它(`evidence.sh` 仍自己指定
`.claude/gitleaks.toml`),所以 commit 它之前先把被追蹤的檔案掃一次
(`gitleaks dir .`)。

---

## 授權

MIT(或你偏好的授權 —— 公開前先決定)。改寫自第三方專案的檔案及其 MIT
聲明列在 [NOTICE](./NOTICE)。
