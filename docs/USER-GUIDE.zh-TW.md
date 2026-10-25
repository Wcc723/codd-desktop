# CODD Desktop 使用說明

CODD Desktop 是一個原生的 macOS App，讓你在同一個視窗裡開啟、查看與切換很多個 Claude Code session。
所有東西都在這台 Mac 上執行：不連任何伺服器，也不呼叫 Anthropic 的 API。每個終端機都由一個小小的
`codd-holder` 程式持有，所以結束、更新甚至當掉 CODD 都不會中斷正在跑的 session，下次打開 CODD 會自動接回。

這份說明對應 CODD 1.0.0。文中英文大寫的字（例如 SESSIONS、NEEDS YOU、RESUME）就是畫面上的
標籤，`[按鈕]` 是按鈕，`A › B` 是選單或設定頁的路徑。例子裡的帳號、專案與 session 名稱都是示意用的。

內容：

1. 安裝
2. 首次啟動設定
3. Session
4. Composer（⌘L）
5. 筆記本
6. 檔案編輯器
7. MCP
8. 清理與保留
9. 帳號（cswap）
10. 選單列與 Dock
11. 快捷鍵一覽
12. 資料放在哪裡
13. 更新與解除安裝
14. 疑難排解

---

## 1. 安裝

### 1.1 下載或從原始碼建置

CODD 需要 macOS 26 以上。可以下載建置好的 App，也可以從原始碼建置（完整需求見專案根目錄的 README）。

**下載建置好的 App**：只從 [Releases](https://github.com/Wcc723/codd-desktop/releases) 下載，其他地方的 CODD 都不是
作者發布的。下載 `CODD-<版本>-<建置編號>.zip`，解壓縮後把 `CODD.app` 拖進「應用程式」資料夾。打開前可以先對照這一版
Release 說明裡的 zip SHA-256 或 CDHash（選用，指令在 README 的「下載建置好的 App」）。CODD 用 ad-hoc 簽章、沒有經過
Apple 公證，所以第一次打開會被 macOS 擋下：按「完成」，到 系統設定 › 隱私權與安全性 的「安全性」按「強制打開」，依指示
輸入密碼（或使用 Touch ID），出現確認對話框時再按「強制打開」。這個按鈕只在你嘗試打開後約一小時內出現；找不到時先從
「應用程式」再打開一次 CODD。每個新版本第一次打開時都要做一次。macOS 說「CODD」已損毀時的處理方式也在 README 的
「下載建置好的 App」。

**從原始碼建置**：需要 Xcode 27 與 xcodegen。在一般的「終端機」App 裡（不要在 Claude Code 的 session 裡）進入這個專案的資料夾，執行：

```bash
scripts/release.sh --install
```

它會建置 Release 版、簽章、壓成 zip，然後裝到 `/Applications/CODD.app`；原本的 `/Applications/CODD.app`
會先移到垃圾桶（需要時可以「放回原處」）。新版先複製到 `/Applications/.CODD.app.installing`，確定舊版移走後才改名放好；
移不走舊版時它會停下來，兩個版本都留在原處。

- 預設用 ad-hoc 簽章；要用你的 Apple Development 或 Developer ID 憑證，加上 `--identity "<憑證名稱>"`
  （或設定 `RELEASE_IDENTITY`），這時憑證上的姓名與 Team ID 會寫進簽章。鑰匙圈裡的憑證不會自動被拿來用。
  最後一行 `RELEASE … identity=…` 會告訴你用了哪一種，`version=` 與 `build=` 是這次的版本與建置編號（建置編號是 git 的 commit 數）。
- `/Applications/CODD.app` 還在執行時，安裝會被拒絕：先在 CODD 按 ⌘Q，選 `結束 · session 繼續執行`
  （session 不會停）。
- 在 Claude Code 的 shell 裡執行 `--install` 會被拒絕：安裝只由你自己進行。
- 只想先看它會做什麼：`scripts/release.sh --dry-run`；只建置不安裝：`scripts/release.sh`
  （結果在 `build/release/CODD.app`，另有一個 `CODD-<版本>-<建置編號>.zip`）。`--install` 只安裝 `build/release` 裡的建置，
  而且會先建置一次。

### 1.2 第一次打開

從「應用程式」資料夾打開 CODD。如果 `~/Library/Application Support/CODD` 是新的（這台 Mac 第一次用 CODD），
會先出現「首次啟動設定」視窗（第 2 節），走完或關掉它之後才出現主視窗。「新的」是指資料夾裡還沒有側欄、分頁、
session 與首次啟動設定的紀錄（`layout.json`、`panes.json`、`sessions/*/meta.json`、`onboarding.json`）。已經用過 CODD
的人不會看到它：CODD 直接打開主視窗，不會打斷你。

主視窗左邊是 rail（SESSIONS、NOTES、STATUS、SETTINGS），接著是側欄，右邊是目前選取的 session。
關掉主視窗後 CODD 仍留在選單列與 Dock 上（第 10 節），session 照常執行；要完全結束 CODD 請按 ⌘Q。

session 裡的程式（例如 `osascript` 或其他命令列工具）要用相機、麥克風或控制其他 App 時，macOS 會以「CODD」的名義
詢問你：CODD 執行時，session 裡的程式都算在 CODD 頭上。CODD 本身不使用這些。

### 1.3 從舊版 CODD 換過來

如果你之前用的是自己 build 的開發版（例如 `build/user-m4` 裡的 CODD），1.0 換了 App 的識別碼
（`app.codd.CODD`）。側欄、筆記、設定與 session 都在同一個資料夾裡，不需要搬移；但有幾件事要知道：

1. **先結束舊的 CODD。** 在舊版按 ⌘Q，選 `結束 · session 繼續執行`。session 都會繼續跑；新的 CODD
   用同一個資料夾，打開後自動接回這些 session（hook 連接埠與 token 不變，正在跑的 claude 照常回報狀態）。
   舊版還開著時打開新版，新版只會把舊版叫到前面然後自己結束：一個資料夾同時只能有一個 CODD。
2. **視窗大小與選單列圖示的位置會沿用一次。** 新版第一次在你的資料夾啟動時，把舊版記住的主視窗大小、
   側欄寬度與選單列圖示位置複製過來，只做這一次（只在 `~/Library/Application Support/CODD` 上做；用 `-codd-data-root`
   指定別的資料夾時不做）；舊版自己的紀錄只讀、不會被改動。
3. **通知權限會再問一次。** macOS 的通知權限跟著 App 的識別碼走。新版第一次有通知要發時（或在首次啟動設定
   第 6 步按 `[允許通知]`），macOS 會問你是否允許 CODD 傳送通知。
4. **資料夾存取會再問一次。** session 的專案放在「桌面」、「文件」、「下載項目」或網路磁碟上時，macOS 會
   再問一次是否允許 CODD 存取。用 ad-hoc 簽章（預設，沒有用 `--identity` 指定憑證）時，macOS 用每次建置的簽章認 App，
   所以之後每次更新都可能再問；session 裡的程式用過的相機、麥克風、自動化等權限也一樣。
5. **登入時啟動要重設。** 如果你開過 設定 › 一般 › `登入時啟動`：把它關掉再打開一次，然後到
   系統設定 › 一般 › 登入項目（依 macOS 版本也可能叫「登入項目與延伸功能」）把舊的 CODD 刪掉。不刪的話，舊版可能
   在登入時先啟動並佔住資料夾，新版打開時就只會把舊版叫到前面。遇到這種情況，設定頁會在那一列下方提示
   「CODD 換了識別碼：請把「登入時啟動」關掉再打開一次」（`登入時啟動` 是開的、但系統裡沒有新版的登入項目時）。

---

## 2. 首次啟動設定

六個步驟。左邊是步驟列（做完的打勾，略過的標 `已略過 · 可在 SETTINGS 調整`），右邊上方是環境偵測的
開機紀錄：`[ OK ]` 正常、`[ .. ]` 待處理、`[FAIL]` 失敗、`[ -- ]` 略過。每一步都可以按 `[略過]`，
`[← 上一步]` 或點已完成、已略過的步驟可以回去看；⏎ 等於右下角的主要按鈕（注音組字中與群組選單打開時除外），
⌘[ 等於上一步。開著 鍵盤導覽（Full Keyboard Access）時，Tab 會依序走過每個按鈕與步驟。

在第 3 步按下 `套用並備份` 之前，CODD 不會改動 `~/.claude/settings.json`；每一步都能之後在 SETTINGS 調整。

| 步驟 | 做什麼 | 會寫入什麼 |
|---|---|---|
| 1 偵測環境 · DETECT | 檢查 claude（版本與位置）、cswap、`~/.claude/settings.json` 的 hooks、CODD 的資料夾能不能寫入，以及 MCP 位址。需要處理的項目下方有說明與按鈕（例如 `[第 3 步 →]`）；裝好缺的東西後按 `[↻ 重新偵測]`。 | 不寫入任何東西 |
| 2 匯入專案 · IMPORT PROJECTS | 從 `~/.claude.json` 列出你用 Claude Code 開過的專案，依最近使用排序。14 天內用過的會預先勾選（最多 12 個）；路徑裡有 `.claude-worktrees` 的 worktree 與只用 SDK 開過的專案預設隱藏（`[顯示隱藏項目]` 以淡色顯示）；已在側欄的專案不會列出（下方顯示 `另有 n 個已在側欄`），資料夾已經不在的也不會列出。`[依父資料夾建議分組]` 把同一個上層資料夾的專案放進同一個新群組；每一列的 GROUP 也可以自己選，或用 `+ 新群組…`。 | 按 `[下一步]` 時，把勾選的專案與群組加進 CODD 的側欄（資料夾裡的 `layout.json`）。`~/.claude.json` 只讀，不會被改動。按 `[略過]` 不匯入任何東西 |
| 3 安裝 hooks · HOOKS & STATUSLINE | CODD 開的 session 本來就會自動帶上 hooks 與狀態列，不必改全域設定。這一步只整理 `~/.claude/settings.json`：移除舊版 CODD web 留下的 hooks，或安裝選用的全域狀態列（讓 CODD 以外開的 claude 也回報用量）。`[預覽變更]` 打開 Hook 差異 對話框，列出確切的變更；其他工具的 hooks 保持不動。 | 只有在對話框按 `套用並備份` 才寫入 `~/.claude/settings.json`，寫入前先在旁邊備份成 `settings.json.codd-bak-<時間>` |
| 4 筆記本與 MCP · NOTEBOOK & MCP | 顯示筆記的位置（固定在 `~/Library/Application Support/CODD/notes`，`[在 Finder 中顯示]`）與 MCP 是否在運作。`CLAUDE CODE [註冊…]` 讓 CODD 以外開的 claude 也能讀筆記；`CODEX [複製設定…]` 給 Codex 一段設定。 | 只有在註冊對話框按 `套用並備份` 才寫入 `~/.claude.json`（先備份）；Codex 的設定由你自己貼上，CODD 不會改 `~/.codex` |
| 5 帳號 (cswap) · ACCOUNTS | 讀取 cswap 的狀態並列出帳號（只顯示別名，例如 `#3 工作`，不顯示 email），依每週重置時間排序。沒有 cswap 也能用 CODD：session 會用目前登入的帳號。`[+ 加入帳號]` 會把主視窗叫出來並打開加入帳號面板（第 9 節）；首次啟動設定的視窗留著，帳號變了會自動更新。 | 只讀；加入帳號時才會執行 `cswap add`（改的是 cswap 自己的檔案） |
| 6 完成 · DONE | 總結前面每一步。`[允許通知]` 請 macOS 允許 CODD 發通知：session 需要你回覆或出錯、而你不在 CODD 畫面前時，CODD 會提醒你。`[開始使用 →]` 結束設定並打開主視窗；這一步的 `[略過]` 也會結束，只是不問通知權限。 | 結束時在 CODD 的資料夾寫入 `onboarding.json`，之後不會再自動出現 |

- **關掉視窗也算完成**：一樣寫入 `onboarding.json`（當下那一步記成略過），不會每次都跳出來。設定進行到一半按 ⌘Q
  不會寫入 `onboarding.json`，下次打開 CODD 時首次啟動設定會再出現。只有第 2 步按過 `[下一步]` 時例外：匯入的專案
  已經在側欄裡，資料夾已經不是「新的」，首次啟動設定**不會自己再出現**，請用下面的 `說明 › 首次啟動設定…` 打開。
- **重新執行**：選單 `說明 › 首次啟動設定…`，或 設定 › 關於 › 首次啟動設定 `[重新執行]`。它從第 1 步開始、
  用當下的狀態偵測；第 2 步只列出還不在側欄的專案。重新執行本身不會自動改動任何檔案，寫入的時機和上表相同；
  結束時會覆寫 `onboarding.json`。視窗開著時，點 Dock 圖示、選單列的 `開啟 CODD` 或全域快捷鍵會把它叫到前面。
- **在臨時資料夾試用**：想先看看流程而不動到你真的資料，可以讓 CODD 用一個空的資料夾：

  ```bash
  T="$(mktemp -d)"
  mkdir -p "$T/root" "$T/claude/sessions"
  /Applications/CODD.app/Contents/MacOS/CODD -codd-data-root "$T/root" -codd-claude-dir "$T/claude"
  ```

  在這種資料夾上，首次啟動設定不會自動出現（用 `說明 › 首次啟動設定…` 打開）；而且 CODD 刻意不找 claude 與
  cswap、也不會寫入 `~/.claude.json`，所以第 1 步會顯示 claude 與 cswap 找不到，第 4 步的 Claude Code 註冊
  是停用的。這是設計如此（試用時不會動到你真的帳號與設定），不是錯誤。第 2 步讀的是 `$T/.claude.json`（通常不存在，
  所以沒有專案可匯入）。用完按 ⌘Q 結束，再刪掉 `$T`。

---

## 3. Session

### 3.1 開新 session（⌘N）

按 ⌘N（或側欄上方的 `[+ NEW ▾]`、專案或群組的右鍵選單、Home 的 `[+ CLAUDE]` `[+ SHELL]`、選單列）打開
NEW SESSION：

- **專案 PROJECT**：`最近` 是 CODD 裡的專案，`建議 · 來自 ~/.claude.json` 是還沒加入的資料夾，也可以
  `+ 選擇資料夾…`。從 Finder 把資料夾拖到側欄，也會變成專案；不論之前有沒有加過，那個專案都會展開、被選取並短暫亮起。
  想直接開始：游標移到側欄的專案列，按右側的 `+`，會用預設的啟動設定檔立刻在那個專案開一個 Claude Code session。
- **類型 KIND**：CLAUDE（在終端機裡執行 claude）或 SHELL（在專案資料夾開一個 zsh，燈號 `$`）。
- **開始方式**：新對話，或接續先前對話（列出這個資料夾過去的對話；快要被 Claude Code 清掉的會標
  `resume N 天後過期`；正在別處執行的那段不能選）。
- **帳號 ACCOUNT**（有 cswap 時，第 9 節）、**模型 MODEL**（預設是 `預設（跟隨 Claude Code 設定）`，不傳 `--model`；
  啟動設定檔有指定模型時才會帶上）、**權限**、**名稱**與**顏色**；最下面是會執行的指令預覽。
- 按 `[建立 ⌘⏎]`。新的 session 先顯示 `◌ STARTING`，claude 回報第一個 hook 後變成 `○ IDLE`。

### 3.2 狀態燈號

燈號的形狀和顏色一起表示狀態，標題列的狀態標籤會再加上原因與持續時間（例如 `◆ WAITING · PERMISSION · 3m`）。

| 燈號 | 標籤 | 意思 |
|---|---|---|
| ◆（琥珀色，脈動） | WAITING（PERMISSION / QUESTION / PLAN） | Claude 在等你：允許某個工具、回答問題或核准計畫。算在 NEEDS YOU |
| ▲（紅） | ERROR（OVERLOADED、RATE LIMIT、AUTH…） | 這一輪失敗了。算在 NEEDS YOU；橫幅上有 `[↻ 重送上一則]` 與 `[⟲ 稍後自動重試]` |
| ◇（青） | DONE | 你沒在看的時候做完了，還沒看過；點開後變成 IDLE |
| ●（綠） | BUSY | 正在產生回覆或執行工具 |
| ◌ | COMPACTING | 正在壓縮對話內容 |
| ○ | IDLE | 輪到你了，而且你已經看過。閒置超過 1 小時的列會變淡（stale） |
| ◌（閃爍） | STARTING | 剛啟動，還沒收到 hook |
| ●（淡）＋ `! NO HOOK` | RUNNING | 正在執行，但超過 20 秒都沒收到 hook（第 14 節） |
| $ | SHELL | 終端機還在，裡面沒有 claude（SHELL session） |
| ✕ | EXITED | 這次執行中結束了，顯示結束碼；SHELL 可以 `↻ 重新開始` |
| ⟲ | STOPPED · 可接續 | 之前留下的 claude session（例如重開機後），可以接續 |
| ◌（紅） | UNREACHABLE | 不是狀態，是疊加的警示：這個 session 的 holder 超過 45 秒沒有回應（第 14 節） |

列上的標記：`EXT`（在 CODD 外面啟動的 session，3.5）、`#2`（固定使用 #2 帳號的 session，第 9 節）、
`stale`（閒置很久）。群組標題的 `◆n ▲n ◇n ●n …` 是群組裡各狀態的數量。

### 3.3 NEEDS YOU 與允許（⌘⏎）

側欄最上面的 ◆ NEEDS YOU 列出所有在等你或出錯的 session（不論在哪個群組），下面一行 `◇ n 個待看` 是做完
但還沒看的。rail 的 SESSIONS 徽章、Dock 的數字、選單列圖示都跟著它。

Claude 要求授權時，終端機下方會出現回答列：`[1] Yes` `[2] Always` `[3] No` `[ESC]`。按 1 / 2 / 3 / Esc，
或按 ⌘⏎（等於 1，允許）。Home 與選單列面板上的 `[1 允許]` 也一樣。Claude 問問題時，回答列列出它的選項
（`Claude 在問你 · 回答問題`）。

### 3.4 停止、RESUME、封存與移除

- **停止**：⌘.（或右鍵 `■ 停止`），會先問 `要停止「…」嗎？`。session 還在 STARTING 時按停止，CODD 會記住，
  等它的 holder 啟動、連上後就照一般的方式停止它（claude 變成 STOPPED，shell 變成 EXITED）。
- **RESUME**：STOPPED 的 claude session（例如重開機後）選起來按 `[⟲ 接續對話]`（或右鍵 `⟲ 接續對話 resume`），
  CODD 用 `claude --resume` 接回同一段對話。右鍵 `↻ 重新開始（新對話）` 則開一段新的。
- **封存**：右鍵 `封存`（⌘⌫）。5 秒內可以 `[UNDO]`；之後從專案的右鍵 `封存 n ▸` 還原。停止很久的 session 也會
  自動封存（第 8 節）。群組標題 hover 時的 `清理已停止 (n)` 一次封存群組裡停止的 session。
- **移除**：右鍵 `✕ 移除 session…`，確認後結束它的 holder、刪掉 CODD 這邊的資料；Claude 的對話紀錄保留。
- **刪除對話紀錄**：右鍵 `✕ 刪除對話紀錄…`，要輸入名稱確認；那段對話在 `~/.claude/projects/…` 的檔案會移到
  垃圾桶（可以放回原處）。

### 3.5 外部 session（EXT）

你在 Terminal.app 或其他地方自己執行的 claude，會以帶 `EXT` 的列出現在對應的專案下（CODD 不認得的資料夾，
會出現在 `未分類` 底下的暫時專案，右鍵 `+ 加入為專案`）。CODD 只讀取它的狀態：會算進 NEEDS YOU 與 Dock 數字，
但不能在 CODD 裡輸入、沒有 `[1 允許]`、也不會發通知。在 CODD 的終端機分頁裡執行的 claude 也是 EXT，第二行
寫 `在 CODD shell 中`，`[前往 shell]` 帶你回到那個 shell。claude 結束後，那一列就消失。

### 3.6 切換、分頁與版面

- **⌘K 快速切換**：輸入 session 標題、專案或筆記的一部分（注音輸入也可以），結果分成 SESSIONS / NOTES /
  PROJECTS / ACTIONS（例如 `> 切換帳號到 #2 藍鵲`）。↑↓ 選擇 · ⏎ 開啟 · ⌘⏎ 在下方終端機開啟 · esc 關閉。
- **⌘1–⌘9**：跳到側欄順序的第 1–9 個 session；**⌃Tab / ⌃⇧Tab**：下一個 / 上一個。
- **終端機**：`◆ CLAUDE` 是 claude 本身。⌘T（或分頁列的 `+`）在下方面板開一個新的終端機；每個終端機分頁都可以用
  `✕`、右鍵選單的 `關閉終端機` 或 ⌘W 關閉，裡面還有程式在跑時會先問。CLAUDE 分頁按 ⌘W 會先問要不要結束 session。
- **⌘J 下方終端機**：session 底下的 shell 面板，可以有好幾個分頁（`+`），也可以最大化。跑著程式的分頁有綠色
  `●`，響過鈴的有琥珀色 `◆`。
- **⌘\ 專注模式**：隱藏 / 顯示側欄。
- **側欄**：`TREE | STATE` 切換依群組或依狀態排列；篩選框（⌥⌘F）；釘選到 PINNED（⌘P）；拖曳或 ⌥⇧↑↓ 調整順序
  （session 只在自己的專案內排序，專案可以拖到別的群組）；在列上停一下會出現 hover 卡片（最近的 prompt、路徑、
  模型）。
- **介面大小**：⌘+ 放大、⌘− 縮小、⌘0 實際大小（介面與終端機字級一起調整），或 設定 › 外觀 › `UI 字級`。

### 3.7 結束 CODD 時，session 會怎樣

有 session 在跑時按 ⌘Q，會出現結束對話框：

- `[全部停止並結束]`：停止所有 session 後結束。
- `[結束 · session 繼續執行]`：只結束 CODD，session 繼續跑，下次打開自動接回。
- `[保留在選單列（關閉視窗）]`：只關視窗，CODD 留在選單列。
- `[取消]`。勾 `下次直接保留在選單列` 後，⌘Q 只會關視窗（選單列圖示右鍵的 `結束` 仍會問）。預設行為在
  設定 › 一般 › `結束時`。

重開機之後 holder 都不在了：claude session 會是 `⟲ STOPPED · 可接續`（按 RESUME 接回對話），shell 會是
`✕ EXITED`（按 `↻ 重新開始`）。

---

## 4. Composer（⌘L）

在 claude session 按 ⌘L，終端機下方會出現一個輸入框，適合寫比較長的 prompt。它對注音等輸入法是安全的：

- 還在組字（有底線）時按 Enter 只會確認選字，**不會送出**；組字中按 Esc 只取消組字。
- `Enter 送出 · ⇧Enter 換行 · 貼上圖片會存成檔案路徑`；⌥Enter 也是換行；在第一行 / 最後一行按 ↑ / ↓ 叫出
  上一則 / 下一則；Esc 關閉。
- 多行的內容會當成**一則** prompt 送出。每個 session 的草稿與歷史（最多 100 則）都會保存，重開 CODD 後還在。
- Claude 在等你回答授權時，右下顯示 `Claude 在等你確認 · 先用下方按鍵回答`，暫時不能送出：先用回答列回答。
- `codd://note/<id>` 會顯示成琥珀色的標籤（第 5 節）。

**貼上圖片**：在 composer 按 ⌘V 貼上截圖，CODD 把它存成 PNG（放在那個 session 的資料夾的 `attachments/`），
並在游標處插入檔案路徑，claude 會把它當成圖片附件讀取。這些圖是暫存的：**最後一次送出後 24 小時刪除**（從沒送出
的，從貼上時算起）；只要還有沒送出的草稿用到它，就會保留。用 ↑ 叫出舊的 prompt 時，已經刪掉的圖會顯示成
`[圖已過期]`，送出的也是這幾個字，不會送出不存在的路徑。直接貼到終端機（不是 composer）的圖，由終端機自己暫存，
不經過 CODD。

---

## 5. 筆記本

點 rail 的 NOTES。筆記是一般的 Markdown 檔，放在固定的位置：

```
~/Library/Application Support/CODD/notes
```

每則筆記是一個 `.md` 檔（`<日期>-<標題>.md`），貼上的圖片在 `notes/assets/<筆記 id>/`，CODD 自己的狀態在
`notes/.codd/`。你也可以用別的編輯器改這些檔案，CODD 會自動讀到變更。位置不能搬動，更新 CODD 時保留。

- **清單**：INBOX、PINNED、PROMPTS、STALE、ARCHIVE、TRASH（30 天後永久刪除），以及 BY PROJECT 與 LOCAL FILES。
  在列表的筆記上按右鍵可以 `釘選`、`封存` 或 `移到垃圾桶`（TRASH 裡是 `還原`），之後可以按 `[UNDO]` 復原。
- **快速筆記** ⌘⇧N：任何地方都能按（選單列面板也有 `[QUICK NOTE ⌘⇧N]`）。
- **搜尋** ⌘F 或左上的搜尋欄：中文一兩個字也找得到。
- **編輯器**：即時預覽的 Markdown（游標所在那一行顯示原始標記），會自動存檔；⌘E 切換成原始碼。注音組字時
  不會存檔，也不會突然顯示或隱藏語法標記。
- **圖片**：直接貼上或拖進來，預設長邊壓到 2576px（設定 › 筆記本 & MCP）。
- **HISTORY**：右側資訊欄有每個版本，可以 `[比較]` 與還原。
- **AI 存取**：編輯器上方的 AI pill 決定 AI 能不能看到這則筆記：OFF（MCP 與引用展開都看不到）、READ（可讀）、
  APPEND（可讀，也可以在最後附加）。新筆記的預設值在 設定 › 筆記本 & MCP › `新筆記預設 AI 存取`；
  `AI 可寫入` 打開後，AI 才能改寫既有內容。

**圖片標註（⌘⇧A，標註模式）**：在筆記裡的圖片上加編號的框、點、箭頭或文字，每一個都附一段說明，座標用原圖的
像素（左上角為原點）。按 `完成` 後，標註存在筆記裡那張圖的下面；AI 讀到這則筆記時，會收到原圖、標上框和編號的圖，
以及座標清單，知道要改哪裡。

**COPY REF（⌘⇧C）**：複製這則筆記的引用，有五種：

| 形式 | 用途 |
|---|---|
| `codd://note/rwd-punch-k7x2` | 推薦。寫在 CODD 開的 session 的 prompt 裡，CODD 會自動展開 |
| `@codd:codd://note/rwd-punch-k7x2` | Claude Code 的 @ 附加（透過 MCP resource） |
| 檔案路徑 | 任何 agent 都能直接讀檔；路徑裡有空白（`Application Support`），能用 `codd://` 時優先用它 |
| 全文 Markdown | 直接貼到任何地方 |
| `http://127.0.0.1:<port>/n/<id>.md?t=…` | 瀏覽器或 curl 用的本機網址（Claude 的 WebFetch 讀不到 localhost）；AI 存取為 OFF 時不提供 |

**送到 session**：編輯器下方 `送到 [● session ▾]`，`[插入引用]`、`[插入全文]` 放進那個 session 的 composer，
`[送出 ⌘⏎]` 直接送出。只能送到 CODD 開的 claude session。session 標題列的 `✎ NOTES n` 打開筆記抽屜，列出連結
這個 session 的筆記。點筆記標題就在抽屜裡直接編輯（和筆記本一樣自動儲存；`‹` 回到清單，`[筆記本 ↗]` 到筆記本裡
繼續）；同一則筆記在兩邊同時開著也會同步。

**codd:// 引用**：在 CODD 開的 claude session 的 prompt 裡寫 `codd://note/<id>`，CODD 會在 Claude 讀到 prompt
之前把筆記內容附上，終端機會出現一行 `codd：已展開 codd://note/…（標題 · n 張圖片）`，Claude 不必再去讀檔。
AI 存取為 OFF 的筆記不會展開（`codd：codd://note/… 無法展開（AI 存取為 OFF）`）。

---

## 6. 檔案編輯器

從 session 標題列的檔案按鈕，或筆記本的 LOCAL FILES `[開啟資料夾…]`，可以在 CODD 裡打開專案的檔案（類似
VS Code）：左邊是檔案樹（git 改過的檔案有 `M`，被忽略的檔案變灰，上方是目前的分支），右邊是分頁。

- ⌘P 篩選檔案 · ⌘F 尋找與取代 · ⌘S 儲存 · ⌘W 關閉分頁。
- **只有按 ⌘S 才會寫入檔案**，不會自動存檔。原本的編碼與換行（UTF-8、BOM、UTF-16、Big5…；LF / CRLF）都保留。
  git 只讀，CODD 不會執行任何改動 repo 的 git 指令。
- **AI 標記**：Claude 用 Edit / Write 等工具改過的檔案，在檔案樹與分頁上有 `AI` 標記（session 的顏色），session
  抽屜的 `AI 改過的檔案` 也會列出。用 Bash 指令改的檔案只會有 git 的 `M`。
- **磁碟上的檔案被改了**：打開中的檔案被 AI 或別的程式改動時，上方出現橫幅（例如
  `磁碟上的檔案已被 AI 變更（打卡頁 RWD 調整 · 10:41）`），選 `[重新載入]`、`[保留我的]` 或 `[比較]`。
- **SHOW AI CHANGES**：打開後和 git HEAD 比較，差異直接顯示在程式碼裡；每一段可以 `[還原此段]`（只改編輯器裡的
  內容，按 ⌘S 才寫入）或 `[接受]`（收起那一段）。
- **有未儲存的分頁時結束 CODD**：會先問你（`[不儲存]` `[取消]` `[儲存全部]`）。登出、關機這類沒辦法問的情況，
  CODD 把未儲存的內容另存到資料夾的 `files/unsaved/<時間>/`，不會蓋掉原檔（目前要自己從那裡打開）。

---

## 7. MCP

CODD 內建一個 MCP server（和 hook 用同一個連接埠，只聽 127.0.0.1），讓 Claude 能搜尋、讀取筆記，在允許時附加
內容。工具：`notes_search`、`notes_list`、`notes_read`、`notes_append`、`notes_create`，以及 `AI 可寫入` 打開時的
`notes_write`。

- **讓 Claude 把文件寫成筆記**：`notes_create` 讓 Claude 把報告、計畫或摘要直接建立成一則新筆記（放在 INBOX，
  連結到那個 session 與專案，AI 存取為 APPEND），而不是在專案裡另寫 Markdown 檔。它只會新建，不會改既有筆記；
  每次建立前 Claude Code 會先問你（可以選一律允許）。建立後 CODD 顯示 `Claude 建立了筆記：<標題>` 與 `[開啟]`。
  內容最多 100,000 字。

- **CODD 的 session 自動帶上**：CODD 開的（或 RESUME 的）每個 claude session 都會掛上 `codd`（你自己已經有叫
  `codd` 的 server 時改叫 `codd-desktop`），你自己的 MCP server 照常可用。開關在 設定 › 筆記本 & MCP ›
  `自動掛載 MCP`（預設開）。這個版本之前就在跑的 session，要 RESUME 或重新開始後才會有。在 claude 裡輸入 `/mcp`
  可以看到它。
- **CODD 沒開的時候**：session 照常工作，但 `/mcp` 裡的 `codd` 會顯示失敗；重新打開 CODD 後在 `/mcp` 重新連線即可。
- **註冊到 Claude Code**（讓 CODD 以外開的 claude 也能讀筆記）：設定 › 筆記本 & MCP › 註冊 的 Claude Code
  `[註冊]`（或 STATUS › MCP SERVER、首次啟動設定第 4 步）。對話框只顯示 `~/.claude.json` 裡 `mcpServers` 新增
  `codd` 的差異（token 顯示成 `••••`）；按 `套用並備份` 才寫入，旁邊先備份成 `.claude.json.codd-bak-<時間>`。
  `[移除]` 會拿掉它。建議第一次註冊前自己也備份一份 `~/.claude.json`。`~/.claude.json` 與它的備份含 token，
  CODD 寫入時會把它們設成只有你能讀（0600）；舊版 CODD 註冊時留下其他帳號也讀得到的檔案，那一列會顯示
  `◆ 權限過寬`，按 `[收緊]` 再按 `收緊權限` 只改權限，內容不變、也不另外備份。
- **Codex**：`[註冊]` 只會顯示一段 `~/.codex/config.toml` 的設定讓你複製，CODD 不會改 Codex 的檔案。這段設定含 token，
  存檔後請執行 `chmod 600 ~/.codex/config.toml`，不讓其他帳號讀取。
- **輪替 token**：設定 › 筆記本 & MCP › Port 與 token 的 `[輪替]`。輪替後，已註冊的 client 要重新註冊
  （Claude Code 那一列會顯示 `需要重新註冊（token 已輪替）`，再按一次 `[註冊]`；Codex 重新複製設定）。CODD 自己開的
  session 用各自的 token，不受影響。
- **誰看得到什麼**：AI 存取為 OFF 的筆記，任何 AI 路徑都看不到。綁定某個專案的筆記，MCP 工具只提供給那個專案
  （或連結到這則筆記）的 session，以及你註冊的 client；但在 prompt 裡直接寫它的 `codd://note/<id>` 時，任何專案的
  session 都會展開它。這些都是建議性的：有 Bash 工具的 session 仍然可以直接讀筆記資料夾裡的檔案。
- **秘密只放在 AI OFF 的筆記**：在 CODD session 裡執行的任何程式（Claude 的 Bash 工具、專案的測試或安裝腳本、
  MCP server、狀態列指令）都以你的身分執行，讀得到每一則 AI 存取不是 OFF 的筆記，也能不經詢問建立筆記。
  API key、密碼、token 這類內容請放在 AI 存取為 OFF 的筆記裡。
- **筆記裡的圖片**：`notes_read` 與展開的筆記只會附上（或標出尺寸）筆記本資料夾裡的圖片，以及那個 session
  專案資料夾裡的圖片；連到其他位置的圖片只列出路徑並標示 `（未附上：圖片不在筆記本或專案資料夾內）`。你自己在
  筆記本裡看、插入全文或送出時照常顯示。

---

## 8. 清理與保留

CODD 會自動把舊東西移開，但每一步都可以復原；真正刪除只發生在你自己丟進垃圾桶的東西上。預設值（設定 › 清理
可以調整）：

| 對象 | 規則 |
|---|---|
| 筆記 | 14 天沒有活動 → STALE；30 天 → 自動封存（ARCHIVE） |
| 快速筆記（SCRATCH）、已送出的 PROMPT | 7 天後自動封存 |
| 筆記的 TRASH | 你丟進去 30 天後永久刪除（移到 macOS 的垃圾桶） |
| 例外 | 釘選的筆記，以及使用中 session 連結的筆記，不會被封存 |
| session | 停止 3 天 → 側欄變淡；停止 7 天 → 自動封存（可還原） |
| 終端機紀錄 | session 封存 30 天後，它的終端機紀錄移到垃圾桶 |
| Claude 的對話 | Claude Code 自己的 `cleanupPeriodDays`（預設 30 天）快到時，提醒 `resume N 天後過期` |

CODD 第一次在你的資料夾上啟用這些規則時，不會封存或丟掉任何東西，從那一刻才開始計算。

- **清理頁**：筆記本左下的 `清理建議 n →`（選單列面板與 設定 › 清理 也有）。NOTES / SESSIONS / FILES 三個分頁，
  每一列可以 `[保留 30 天]` 或 `[封存]`；勾選後下方有 `[封存]`、`[移到垃圾桶]`、`[交給 Claude 濃縮…]`。
- **每週提醒**：每週一 09:00（設定 › 清理 › `每週清理建議`：每週 / 雙週 / 每月 / 關），清理建議有 5 項以上時發一則
  `清理建議 · n 項` 的通知，按 `查看` 打開清理頁；同一週不會再提醒。
- **交給 Claude 濃縮**：在清理頁勾選幾則筆記，按 `[交給 Claude 濃縮…]`，選帳號與模型後按 `產生摘要`。CODD 用你的
  帳號執行一次 `claude -p`（會用掉少量額度），它只能讀這幾則筆記；幾十秒內出現摘要預覽。按 `建立摘要並封存原稿` 後
  多一則摘要筆記，原稿被封存（不刪除，可在 ARCHIVE 找到），摘要連回原稿。AI 存取為 OFF 的筆記不會送給 Claude。

---

## 9. 帳號（cswap）

CODD 透過 cswap（0.26 以上）管理多個 Claude 帳號。沒有 cswap 也能用 CODD，session 會用目前登入的帳號。

- **找 cswap**：設定 › 帳號 › `cswap 路徑`（有設定時），否則從你登入 shell 的 PATH 找，再找 `~/.local/bin/cswap`。
  版本太舊時顯示 `▲ 需 ≥ 0.26`。
- **只讀、只顯示別名**：CODD 只讀 cswap 的狀態檔（`~/.claude-swap-backup`），任何地方都只顯示 `#3 工作` 這樣的
  別名與方案，不顯示 email。帳號依每週重置時間排序（`依每週重置排序 · 越快重置越上面`），目前的帳號標 `✓ ACTIVE`。
- **用量**：5h 與 1w 的剩餘百分比，來自 CODD session 的狀態列（Claude Code 自己回報的）與 cswap 的快取，旁邊標示
  來源與時間（例如 `statusline · 12s 前`）。CODD 不呼叫用量 API。你原本的狀態列照常顯示（CODD 的狀態列串在它前面）。
- **直接切換**：在側欄底部（`▸ USAGE 剩餘` 展開後）、選單列面板的 ACCOUNTS、STATUS 或 ⌘K 點另一個帳號，就直接切換，
  出現 `已切換到 #2 藍鵲 · 12 個 session 約 30 秒內套用` 與 `[UNDO]`。跟隨全域登入的 session 約 30 秒內改用新帳號。
  想先確認再切換：設定 › 帳號 › `切換前確認`。
- **自動切換（預設關）**：設定 › 帳號 › `剩餘不足時自動切換`。目前帳號的 5 小時或每週剩餘 ≤ 門檻（預設 2%）時，
  切到排序中第一個兩種額度都還夠的帳號，冷卻 300 秒；全部都不夠時只通知 `所有帳號都低於 2%`。如果你同時在跑
  `cswap menubar` 或 `cswap auto`，設定頁會提醒兩邊可能同時切換。注意：Claude 官方不建議用多個帳號自動輪替來延長
  用量，可能違反 Anthropic 的使用條款；開啟時 CODD 會再問一次，請自行評估風險。
- **固定帳號的 session**：先在終端機執行一次 `cswap run 2`（之後可以結束它），回到 CODD 按 ⌘N，帳號選單會有
  `固定 #2 …（cswap run）`。用它開的 session 在側欄有 `#2` 標記，不管全域登入切到哪個帳號，都用 #2 的額度。
  cswap 說那個設定需要更新時，RESUME 會出現 `#2 的登入資料需要更新：先在終端機執行一次 cswap run 2`。
- **加入帳號**：設定 › 帳號 `+ 加入帳號`（或 STATUS、首次啟動設定第 5 步）。按 `[開啟登入終端機]`，在出現的終端機
  用新帳號完成 `claude /login`；回到面板按 `[擷取目前登入]`，輸入英文別名（小寫英文、數字與 `- _ .`），按
  `[加入 #n]`。cswap 加入後 CODD 自動切回你原本的帳號，那個登入終端機也會自動關掉。過程中全域登入會暫時改變。

---

## 10. 選單列與 Dock

**選單列圖示**：一個小小的單色圖示。中間的方塊亮琥珀色 = 有 session 需要你；空心 = hook 沒有在運作（第 14 節）；
整個變淡 = 通知暫停中。設定 › 通知 › `選單列圖示` 可以改成 `圖示 + 數字`。

- **點一下**打開面板：ACCOUNTS（最上面，點帳號就切換）、NEEDS YOU（`[前往]` `[1 允許]`）、READY、RUNNING，
  最下面是主機狀態、`清理建議 n →`、`[QUICK NOTE ⌘⇧N]`、`[OPEN CODD]`。
- **按右鍵**：`開啟 CODD`、`新增 session`、`快速筆記`、`切換帳號`、`暫停通知 1 小時`（暫停中變成 `恢復通知`）、
  `設定…`、`結束`（有 session 在跑時一定會先問）。
- **暫停通知 1 小時**：這段時間不跳通知也不出聲，徽章與數字照常更新。

**Dock**：徽章是需要你的 session 數（設定 › 通知 › `Dock 徽章`：等待數 / 全部 / 關）。有 session 開始需要你時，
Dock 圖示裡的琥珀色方塊慢慢閃 3 次，然後一直亮著，直到沒有 session 需要你；需要你的數量變多時會再閃。通知暫停時
不閃也不亮；開了 減少動態 時直接亮、不閃。設定 › 一般 › `顯示於 Dock` 關掉後只剩選單列圖示（⌘Tab 也看不到）。

**通知**：session 變成 WAITING 或 ERROR、而你沒在看它時，CODD 發一則通知（例如 `◆ 修正登入 API 401 需要授權`），
有 `前往` 與 `稍後`。哪些狀態要通知、聲音、勿擾時段（預設 23:00–08:00）、依群組靜音都在 設定 › 通知；
`[傳送測試通知]` 可以先試一則。

關掉主視窗後，用 Dock 圖示、選單列的 `開啟 CODD`、⌥⌘0 或全域快捷鍵（預設 ⌥Space，設定 › 一般 › `全域快捷鍵`）
叫回來。

---

## 11. 快捷鍵一覽

| 動作 | 按鍵 |
|---|---|
| 新增 session | ⌘N |
| 快速切換（session、筆記、專案、動作） | ⌘K |
| 跳到第 1–9 個 session | ⌘1 – ⌘9 |
| 下一個 / 上一個 session | ⌃Tab / ⌃⇧Tab |
| 允許（回答 1） | ⌘⏎ |
| 回答列的選項 | 1 / 2 / 3 / Esc |
| 新增終端機（下方面板） | ⌘T |
| 下方終端機 | ⌘J |
| Composer | ⌘L |
| 釘選 / 取消釘選 | ⌘P |
| 停止 session | ⌘. |
| 隱藏 / 顯示側欄（專注模式） | ⌘\ |
| 篩選 session | ⌥⌘F |
| 調整順序（側欄） | ⌥⇧↑ / ⌥⇧↓ |
| 重新命名 / 封存（側欄） | ⏎ / ⌘⌫ |
| 關閉分頁或視窗 | ⌘W |
| 快速筆記 | ⌘⇧N |
| 搜尋筆記 / 原始碼（NOTES） | ⌘F / ⌘E |
| 標註模式 / 複製引用（NOTES） | ⌘⇧A / ⌘⇧C |
| 儲存 / 篩選檔案 / 尋找（檔案編輯器） | ⌘S / ⌘P / ⌘F |
| 放大 / 縮小 / 實際大小 | ⌘+ / ⌘− / ⌘0 |
| CODD 主視窗 | ⌥⌘0 |
| 設定 | ⌘, |
| 結束 CODD | ⌘Q |
| 在任何 App 叫出 CODD（全域快捷鍵，可改） | ⌥Space |
| 首次啟動設定：主要按鈕 / 上一步 | ⏎ / ⌘[ |

**鍵盤與 VoiceOver**：打開 系統設定 › 鍵盤 › 鍵盤導覽（Full Keyboard Access）後，Tab 會走過 CODD 的每個按鈕、開關與清單，
有焦點的元件外圍出現琥珀色的框（用滑鼠點的時候不會出現）；空白鍵按下、⏎ 按下按鈕，方向鍵切換分段選項與數值。只能用
滑鼠點的地方都另外有選單項目：`顯示方式 › SESSIONS / NOTES / STATUS / SETTINGS`、`筆記 › 筆記本 / 檔案 / 清理建議`、
`Session › 筆記抽屜 / 新增群組… / 切換帳號`、`CODD › 暫停通知 1 小時`（這些沒有快捷鍵）。VoiceOver 會用文字念出
session 的狀態（例如 `修正登入 API 401，等待中 · 權限 · 3 分鐘`），不靠顏色。終端機有焦點時 Tab 是傳給 shell 的，
要離開終端機請用 ⌥⌘F（篩選 session）或選單。

Composer 裡：Enter 送出、⇧Enter 或 ⌥Enter 換行、↑ / ↓ 歷史、Esc 關閉。⌘K 裡：↑↓ 選擇、⏎ 開啟、⌘⏎ 在下方終端機
開啟、esc 關閉。這些按鍵在終端機有焦點、或開著注音輸入法時也照樣作用。

---

## 12. 資料放在哪裡

### 12.1 CODD 的資料夾

所有東西都在 `~/Library/Application Support/CODD`（設定 › 進階 › 資料庫 `[在 Finder 顯示]`）。裡面每一項不是
USER DATA 就是 DERIVED：

- **USER DATA**：CODD 無法重建的資料。每次更新都保留；格式改變時先備份再就地轉換。
- **DERIVED**：可以重建的資料。`cache/` 裡的東西隨時可以刪（先 ⌘Q 結束 CODD），CODD 下次需要時會重建。
  標「執行中」的項目被正在跑的 holder 或 session 用著，**不要手動刪除**。

| 路徑 | 類型 | 內容 |
|---|---|---|
| `layout.json` | USER DATA | 側欄：群組、專案、session、順序、顏色、釘選、封存 |
| `panes.json` | USER DATA | 每個 session 的分頁與下方終端機 |
| `preferences.json` | USER DATA | 所有設定（改過才會出現） |
| `profiles.json` | USER DATA | 啟動設定檔 |
| `config.json` | USER DATA | hook 連接埠與 token、MCP token（只有你能讀） |
| `cleanup.json` | USER DATA | 清理：保留期限、每週提醒的紀錄 |
| `claude-settings-backups.json` | USER DATA | `~/.claude/settings.json` 的備份清單 |
| `onboarding.json` | USER DATA | 首次啟動設定的完成紀錄：何時完成、各步驟做了或略過、匯入幾個專案與群組、通知權限的結果 |
| `sessions/<id>/` | USER DATA | 每個 session：holder 的 `meta.json`、終端機紀錄 `ring`、`holder.log`、終端機分頁 `tabs/`、composer 的草稿與歷史 `composer.json`（不會被 Time Machine 備份） |
| `sessions/<id>/attachments/` | USER DATA（暫存） | composer 貼上的圖，最後一次送出 24 小時後刪除（第 4 節） |
| `notes/` | USER DATA | 筆記本：`.md` 筆記、`assets/` 圖片、`.codd/`（狀態、歷史版本、TRASH） |
| `files/` | USER DATA | 檔案編輯器：最近開啟的檔案、AI 改過的檔案、未儲存的分頁複本 `unsaved/` |
| `cache/` | DERIVED | 筆記的搜尋索引、標註後的圖片、`VERSION`（快取格式的版本；不會被 Time Machine 備份） |
| `quota.json` | DERIVED | 各帳號最近的用量快照 |
| `hooks/` | DERIVED | 每個 session 最後一筆 hook 紀錄 |
| `bin/` | DERIVED（執行中） | holder、`codd-hook`、`codd-statusline` 的複本，session 用的就是這些 |
| `run/` | DERIVED（執行中） | holder 的 socket、濃縮工作的暫存 |
| `codd.lock` | DERIVED（執行中） | 確保一個資料夾只有一個 CODD |
| `sessions/<id>/mcp.json`、`answer.json`、`spawn.env` | DERIVED（執行中） | session 的 MCP 設定、等待中的提示內容、啟動用的環境變數 |

只在臨時資料夾（`-codd-data-root`）才有的 `trash/`：那裡被丟掉的東西不進 macOS 的垃圾桶，而是放這裡。

### 12.2 CODD 可能改動的其他檔案

CODD 讀很多 Claude Code 的檔案，但只在下面這些情況寫入資料夾以外的地方，而且除了你明確按下的動作以外不會自動做：

| 檔案或位置 | 什麼時候 | 備份 |
|---|---|---|
| `~/.claude/settings.json` | 在 Hook 差異 對話框按 `套用並備份`（STATUS、設定 › Hooks & Status、首次啟動設定第 3 步），或在備份清單按 `還原` | 旁邊的 `settings.json.codd-bak-YYYYMMDD-HHMMSS` |
| `~/.claude.json` | 只改 `mcpServers.codd`：在 MCP 註冊對話框按 `套用並備份`，或 `[移除]` | 旁邊的 `.claude.json.codd-bak-YYYYMMDD-HHMMSS` |
| `~/.claude/projects/…` 裡某段對話的檔案 | `✕ 刪除對話紀錄…`（要輸入名稱確認）：移到垃圾桶 | 可從垃圾桶放回原處 |
| cswap 的狀態（`~/.claude-swap-backup`） | 你切換帳號、加入帳號或改別名時，CODD 執行 `cswap switch` / `add` / `alias`，由 cswap 自己寫入 | cswap 自己的機制 |
| 你在檔案編輯器打開的檔案 | 只有按 ⌘S | 無（git 管理的專案可以用 git 還原） |
| macOS 的垃圾桶 | 永久刪除的筆記、封存很久的終端機紀錄、沒用到的筆記圖片 | 可從垃圾桶放回原處 |
| `/Applications/CODD.app` | 只有你執行 `scripts/release.sh --install` 時（下載版由你自己拖進去） | 舊版移到垃圾桶 |
| macOS 的設定 | 登入項目（改 `登入時啟動` 時）、通知權限（你允許時）、CODD 記住的視窗大小、側欄寬度與選單列圖示位置 | — |

CODD 從不改動 `~/.codex`、鑰匙圈或 cswap 的登入憑證。同一個檔名已經有備份時，新的備份名稱後面加 `-2`、`-3`…。

### 12.3 資料夾裡的備份與移開的檔案

| 名稱 | 意思 |
|---|---|
| `<檔名>.corrupt-<數字>` | 讀不出來而被移開的檔案（數字是當時的時間，毫秒），CODD 改用預設值（13.3） |
| `<檔名>.v<舊版本>-backup-<日期-時間>` | 格式轉換前的備份（1.0.0 的檔案都是第 1 版，目前不會出現） |

---

## 13. 更新與解除安裝

### 13.1 更新步驟

1. 在 CODD 按 ⌘Q，選 `結束 · session 繼續執行`（session 不會停）。和其他使用者帳號共用的 Mac 上改選
   `[全部停止並結束]`：CODD 沒在執行的這段時間，hook 連接埠沒有人看守（README 的「安全性」）；更新後再對 claude session
   按 RESUME。
2. 下載版：從 [Releases](https://github.com/Wcc723/codd-desktop/releases/latest) 下載新的 zip，把 `CODD.app` 拖進
   「應用程式」資料夾並選「取代」（要確認檔案的話照 1.1）；第一次打開新版時照 1.1 再按一次「強制打開」。從原始碼建置：
   在一般的「終端機」App 進入專案資料夾，更新原始碼後執行 `scripts/release.sh --install`。
3. 打開 `/Applications/CODD.app`：session 自動接回（選了 `[全部停止並結束]` 的話，對 claude session 按 RESUME），
   設定 › 關於 的 App 一列會顯示新的版本與建置編號（例如 `1.0.0 (6)`）。

### 13.2 資料的版本

CODD 寫的每個 JSON 檔都有版本號。每次啟動時，CODD 會在讀任何設定之前先檢查資料夾裡的檔案（只看各檔案自己的讀法
也會拒絕的問題，不會比原本更嚴格）：

- **比較舊的格式**：先備份（12.3），再轉換成這個版本的格式。
- **比較新的版本寫的**（例如你換回比較舊的 CODD）：能讀的部分照用，**不會存回這個檔案**，免得蓋掉新版的資料；畫面上方出現
  `▲ <檔名> 是較新版本的 CODD 寫的（v<n>）：能讀的部分照用，這次的變更不會存進這個檔案`。這段期間對這個檔案的改動
  （例如側欄的調整）不會被保存。
- **`cache/`**：版本不同時直接清空重建，不會出現提示（筆記索引會在背景重建）。

### 13.3 讀不出來的檔案

USER DATA 的檔案壞掉（不是有效的 JSON，例如被手動改壞）時，CODD 不會刪掉它，而是移到旁邊的
`<檔名>.corrupt-<數字>`，改用預設值繼續，並在上方顯示 `▲ <檔名> 無法讀取，已移到 <新名稱>，改用預設值`，按鈕有
`[在 Finder 中顯示]` 與 `[知道了]`。一次只顯示一個提示，按 `[知道了]` 才換下一個；一次啟動中每個問題只提示一次。
內容是有效 JSON、但格式不對而被讀取的程式自己移開的檔案（例如側欄的 `layout.json`），啟動完成後也會補上同樣的提示。

例外：`config.json`（hook 連接埠與 token）不會被移開，CODD 就地修好它，能讀到的連接埠會保留；DERIVED 的檔案
（`quota.json`、`hooks/` 裡的紀錄）壞掉時直接刪掉重建，不提示。

### 13.4 把移開的檔案改回來

如果你修好了被移開的檔案（或確定它其實沒問題），可以這樣換回去：

1. 在 CODD 按 ⌘Q，選 `結束 · session 繼續執行`。
2. 在「終端機」：

   ```bash
   cd ~/Library/Application\ Support/CODD
   ls *.corrupt-*
   mv layout.json layout.json.default
   mv layout.json.corrupt-1792312345678 layout.json
   ```

   （`layout.json` 換成提示裡的檔名，數字換成 `ls` 列出的那個。第一個 `mv` 把 CODD 用預設值新寫的那份留著備查。）
3. 重新打開 CODD。如果檔案還是讀不出來，CODD 會再把它移開一次（新的數字），不會遺失任何東西。

### 13.5 解除安裝

CODD 只在你明確按下的動作時才改動自己資料夾以外的檔案（12.2 有完整清單）。解除安裝前，先在 CODD 裡把它們改回來：

1. 安裝過全域狀態列時：設定 › Hooks & Status 的 `[解除安裝]`，在 Hook 差異 對話框按 `套用並備份`。
2. 把 MCP 註冊到 Claude Code 時：設定 › 筆記本 & MCP › 註冊 的 Claude Code `[移除]`（拿掉 `~/.claude.json` 裡的
   `mcpServers.codd`）。
3. 開過 `登入時啟動` 時：在 設定 › 一般 把它關掉。
4. 按 ⌘Q；有 session 在跑時選 `[全部停止並結束]`，停止所有 session 之後才結束（選 `結束 · session 繼續執行` 的話，
   session 會留在背景繼續跑）。
5. 把 `/Applications/CODD.app` 移到垃圾桶。
6. 要連資料一起刪除：刪掉 `~/Library/Application Support/CODD`。這裡面有你的筆記（`notes/`）與所有 session 的資料，
   刪除前請先備份需要的筆記。

不會自動刪掉的東西：

- CODD 寫入前留下的備份 `~/.claude/settings.json.codd-bak-*` 與 `~/.claude.json.codd-bak-*`，不需要時可以自己刪除。
- Claude Code 自己的對話紀錄（`~/.claude/projects/`）與 cswap 的資料，它們屬於 Claude Code 與 cswap。
- macOS 裡的通知權限與登入項目（系統設定 › 通知、系統設定 › 一般 › 登入項目）。

---

## 14. 疑難排解

### hook 連接埠被佔用

狀態列顯示 `hooks ▲ :47821 被其他程式佔用 · 只用 registry`，選單列圖示變成空心，STATUS 顯示 `▲ DEGRADED`。
這時 CODD 只能從 Claude Code 的 registry 判斷狀態（比較慢、比較粗略），新開的 session 不帶 hook，MCP 也暫停；
CODD 每隔幾秒會重試。

- 看看是誰佔用了：`lsof -nP -iTCP:47821 -sTCP:LISTEN`（47821 換成狀態列上的數字），結束那個程式後 CODD 會自動接上。
  `lsof` 只列出你自己的程式；什麼都沒列出、狀態列卻還是 ▲ 時，佔用的是別的使用者帳號的程式，改用
  `sudo lsof -nP -iTCP:47821 -sTCP:LISTEN`。
- 佔用的不是你認得的程式時，之前開的 session 可能已經把 prompt、工具的輸入輸出與 token 送給它，它也能回覆這些 hook
  （例如允許工具執行）：照 README 的「安全性」換掉 token。
- 顯示 `由另一個 CODD 使用`：另一個 CODD（例如舊的開發版）正在用同一個連接埠，先把它結束。CODD 用 token 確認對方是
  CODD；如果 token 曾經外洩，這個判斷也不可靠，照 README 的「安全性」換掉 token。
- 一定要換連接埠時：⌘Q 結束 CODD，把資料夾裡 `config.json` 的 `port` 改成一個沒被用的數字（例如 47822），再打開
  CODD。之後要對正在跑的 claude session 按 RESUME 或重新開始，它們才會改用新的連接埠；註冊過 Claude Code 的話也要
  重新註冊（第 7 節）。這是最後手段：CODD 沒有改連接埠的畫面，改壞了 `config.json` 時 CODD 會修好它（能讀到的連接埠
  會保留）。

### UNREACHABLE

session 的 holder 超過 45 秒沒有回應（例如被暫停、系統極度忙碌）時，那一列顯示 `Unreach`，標題列 `◌ UNREACHABLE`，
橫幅有 `[↻ 立即重試]`。session 不會因此停止；holder 恢復回應後約 10 秒內自動接回，按 `[↻ 立即重試]` 可以馬上重試。
一直不恢復時，`pgrep -lf codd-holder` 看看 holder 還在不在；不在的話，下次打開 CODD 會把它顯示成 STOPPED
（claude）或 EXITED（shell），可以 RESUME 或重新開始。

### NO HOOK

`● RUNNING ! NO HOOK`：claude 在跑，但超過 20 秒沒有收到任何 hook（時間在 設定 › 工作階段 › `NO HOOK 警示`）。
常見原因：

- hook 連接埠被佔用（上一項）。
- Claude Code 自己的設定（例如公司統一管理的設定）停用了 hooks。
- 到 STATUS › HOOKS 看 ACCEPTED / REJECTED：REJECTED 不是 0 時，記下 LAST REJECTION 的內容附在回報裡。對那個
  session 按 RESUME 或重新開始通常就會恢復：它會帶著目前的連接埠與 token 重新啟動 claude。

### 找不到 cswap

帳號區顯示 `// 找不到 cswap（設定 › 帳號）`：

- 裝 cswap 0.26 以上：`uv tool install claude-swap`（沒有 uv 時先 `brew install uv`）。STATUS 的帳號區、設定 › 帳號與
  首次啟動設定第 5 步都有安裝說明，`[複製]` 複製指令，`[在終端機執行]` 會開一個終端機把指令打好，由你按 Enter 執行；
  裝好後按重新偵測。cswap 要在登入 shell 的 PATH 裡或 `~/.local/bin/cswap`；或在 設定 › 帳號 › `cswap 路徑` 指定位置。
- 顯示 `▲ 需 ≥ 0.26`：cswap 太舊，請更新（`uv tool upgrade claude-swap`）。
- 在臨時資料夾（`-codd-data-root`）上 CODD 刻意不找 cswap，這是正常的（第 2 節）。

### 沒有通知

1. 系統設定 › 通知 › CODD：確認允許通知。換了識別碼的新版要重新允許（1.3）。
2. 設定 › 通知：確認 WAITING / ERROR 等的通知是開的，現在不在勿擾時段（預設 23:00–08:00），也沒有按
   `暫停通知 1 小時`（選單列圖示會變淡）。
3. CODD 只為你沒在看的 session 發通知；外部（EXT）session 不發通知。
4. 按 設定 › 通知 › `[傳送測試通知]`，應出現 `◆ 測試通知 · CODD`。

### 資料夾無法寫入

CODD 打開時顯示 `無法鎖定資料夾` 然後結束，或首次啟動設定第 1 步顯示 `▲ 資料夾無法寫入：<路徑>`：

- 確認 `~/Library/Application Support/CODD` 的擁有者是你，而且你可以寫入（Finder › 取得資訊 › 共享與權限）。
  不要用 `sudo` 執行 CODD，否則資料夾裡會有你自己不能改的檔案。
- 確認磁碟還有空間。
- 顯示 `另一個 CODD 正在使用這個資料夾`：已經有一個 CODD 在用它，請切換到那個 CODD（或先結束它）。

### 紀錄檔在哪裡

- CODD 的紀錄印在標準輸出，每一行以 `REALHOLDERS` 開頭（裡面不會有 email 或 token）。要看到它：⌘Q 結束 CODD
  （session 繼續跑），在「終端機」執行 `/Applications/CODD.app/Contents/MacOS/CODD`，重現問題後複製輸出。
  設定 › 進階 › `紀錄檔` 目前顯示 `—`：1.0 還沒有固定的紀錄檔。
- 每個 session 的 holder 紀錄：`~/Library/Application Support/CODD/sessions/<id>/holder.log`。
- STATUS 頁有 hooks、帳號、MCP 的即時狀態（不會顯示 token）。

### 回報問題

請附上：

- 設定 › 關於 › `[複製版本資訊]` 貼上的內容（App、macOS、Claude Code、cswap 與 libghostty 的版本）。
- 發生了什麼、你預期什麼、怎麼重現。
- 相關的 `REALHOLDERS` 紀錄行，以及 STATUS 頁的截圖。
- 有提示橫幅時，提示的完整文字。

不要附上 `config.json`、`~/.claude.json`、cswap 的檔案或任何 token；CODD 自己的紀錄與畫面不會包含 email 或 token。
