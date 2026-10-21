# TermSpike MANUAL TEST · GHOSTTY vs SWIFTTERM

這份是給人手動跑的測試清單，用來補自動化測試（`--probe`、`--bench`）量不到的部分：輸入法、Claude 實際互動、選取／捲動、渲染正確性。
自動化結果在 `RESULTS.md`。每一項都請兩個引擎各測一次，結果填在最後的 RESULTS TABLE。

> 本清單的 B、C、D、H 會啟動真正的 `claude`，會消耗額度；自動化測試從不啟動 claude。

---

## 0. SETUP

1. 建置（Debug，日常互動用）：

   ```sh
   cd <repo>/Spikes && xcodegen generate && \
   xcodebuild -project TermSpike.xcodeproj -scheme TermSpike -configuration Debug \
     -derivedDataPath <repo>/build/spike \
     -skipPackagePluginValidation -skipMacroValidation build 2>&1 | grep -E "error:|BUILD"
   ```

   想感受效能時改用 Release：把 `-configuration Debug` 換成 `Release`，App 會在 `build/spike/Build/Products/Release/`。

2. 開啟：

   ```sh
   open <repo>/build/spike/Build/Products/Debug/TermSpike.app
   ```

   需要環境變數時（例如 Ghostty 的 resize 節流），改成直接執行執行檔：

   ```sh
   GHOSTTY_SURFACE_RESIZE_THROTTLE_MS=96 \
     <repo>/build/spike/Build/Products/Debug/TermSpike.app/Contents/MacOS/TermSpike
   ```

   其他參數：`--layout ghostty|swiftterm|sbs`、`--command "zsh -l"`、`--autostart`、`--pattern`；`--report` 只從 `results/*.json` 重建 `RESULTS.md`。
   診斷用環境變數：`SPIKE_GHOSTTY_CONFIG="cursor-style-blink=false"`（追加 Ghostty 設定，分號分隔多項）、`SPIKE_SWIFTTERM_METAL=0`（SwiftTerm 改用 CoreGraphics）。

3. 視窗上方工具列：

   | 控制項 | 作用 |
   |---|---|
   | `GHOSTTY` / `SWIFTTERM` / `SIDE BY SIDE` | 切換顯示的引擎。隱藏的引擎保留 PTY、持續解析，但不繪製 |
   | `CMD` | 要執行的指令，預設 `zsh -l`；會包在 `zsh -l -c` 裡，PATH 來自登入 shell |
   | `START` | 對目前可見的引擎（SIDE BY SIDE 時兩個都會）重新開一個 PTY 並執行 CMD |
   | `STOP` | 掛斷可見引擎的程序 |
   | `PATTERN` | 把渲染測試圖樣直接送進可見引擎（不經過 PTY），用於 F、H |
   | `TERM_PROGRAM` | `(unset)` / `ghostty` / `CODD`，下次 START 生效；Claude 會依它開關部分功能 |

   每個引擎上方的標頭列顯示：引擎 · 指令 · pid · 格數（cols×rows）· renderer · `KEY→PTY` 延遲（p50 / p99 / max，ms）· 終端機標題。
   結束 App 時，stdout 會印出兩個引擎各自的 keyDown→ptyWrite 與 HID event→ptyWrite 統計。

4. 輸入法：本機已啟用內建「注音」（`com.apple.inputmethod.TCIM.Zhuyin`）。McBopomofo（小麥注音）**尚未安裝**；要測就從 https://mcbopomofo.openvanilla.org/ 安裝並在「系統設定 › 鍵盤 › 輸入方式」加入，不測就在表格填 `N/A`。

   本文用到的注音按鍵（大千鍵盤）：

   | 字 | 注音 | 按鍵 |
   |---|---|---|
   | 注音 | ㄓㄨˋ ㄧㄣ | `5` `j` `4` `u` `p` `空白` |
   | 中文 | ㄓㄨㄥ ㄨㄣˊ | `5` `j` `/` `空白` `j` `p` `6` |

5. Claude 測試用的空目錄（避免 Claude 讀寫正式專案）：CMD 填

   ```sh
   mkdir -p /tmp/termspike-claude && cd /tmp/termspike-claude && claude
   ```

   需要 Claude 持續輸出時，用這個提示詞（不會呼叫工具）：

   ```text
   請用繁體中文寫一篇約 1500 字、分成 10 段的文章介紹台灣夜市文化，每段加上小標題，不要使用任何工具。
   ```

6. 重跑自動量測（螢幕要解鎖、不要操作電腦）。目前 `RESULTS.md` 是在螢幕鎖定、顯示器休眠時量的：visible 那幾列沒有真的繪製（標成 `ON SCREEN **NO**` 與 WARNING），注音那一輪按鍵表也被跳過（鎖定畫面開著 Secure Event Input，系統只允許 ASCII 鍵盤配置）。請在解鎖狀態重跑：

   ```sh
   cd <repo>/Spikes && \
   xcodebuild -project TermSpike.xcodeproj -scheme TermSpike -configuration Release \
     -derivedDataPath <repo>/build/spike \
     -skipPackagePluginValidation -skipMacroValidation build 2>&1 | grep -E "error:|BUILD"
   APP=<repo>/build/spike/Build/Products/Release/TermSpike.app/Contents/MacOS/TermSpike
   "$APP" --probe   # 約 15 秒；會暫時把輸入法切到注音、結束時切回原本的輸入法
   "$APP" --bench   # 約 4 分鐘；會開浮動視窗並搶焦點，期間請不要打字
   ```

   兩者都會重寫 `results/*.json` 與 `RESULTS.md`。

---

## A. 注音 at an idle zsh prompt

1. CMD `zsh -l` → `START`。點一下引擎區域讓它取得焦點。
2. 切到注音，打 `5` `j` `4`（先不要選字）。
   - **A1 preedit 位置**：組字中的「ㄓㄨˋ」出現在 zsh 提示字元後的游標位置（有底線），不是在視窗角落或下一行。
   - **A2 候選窗位置**：按 `空白` 或 `↓` 叫出候選窗，候選窗緊貼在游標下方。
3. 選「注」並繼續打 `u` `p` `空白` 完成「注音」，按 `Enter` 送字。
   - **A3 送字**：zsh 命令列出現「注音」，**沒有**多出或少字，也沒有亂碼。
4. 再打 `5` `j` `4`，在組字中按 `Esc`。
   - **A4 Esc 取消組字**：組字被取消，zsh 沒有收到 ESC（命令列沒有進入 vi 模式、沒有出現 `^[`）。
5. 組字中按 `Backspace`。
   - **A5 Backspace**：只刪組字裡的注音，不刪 zsh 命令列上已送出的字。
6. 在 zsh 打 `echo 注音輸入法測試` 按 Enter。
   - **A6 寬度**：輸出的中文每字佔兩格，游標停在正確位置；用 `←` 往回移動時每個中文字只要按一次。
7. 換 McBopomofo 重做 1–6（未安裝填 `N/A`）。
8. 輸入法停在注音（不組字），執行 `sleep 100` 後按 `Ctrl+C`。
   - **A8 注音狀態下 Ctrl+C**：`sleep` 被中斷，回到提示字元。

## B. 注音 inside `claude` while it is streaming

1. CMD 填第 0 節第 5 點的 claude 指令 → `START`。等 Claude 的輸入框（`❯`）出現。
2. 貼上長文提示詞並送出，Claude 開始串流輸出。
3. 串流進行中切到注音，打 `5` `j` `4`，**先不要選字**，觀察 5 秒。
   - **B1 preedit 位置**：組字出現在 Claude 輸入框 `❯` 的位置；記錄實際出現的位置（輸入框／畫面左下／Claude 最後輸出的那一行／其他）。
   - **B2 組字不被清掉**：Claude 重繪時組字仍在（Claude issue #47962：iTerm2 + McBopomofo 會被清掉）。
   - **B3 候選窗**：叫出候選窗後，它不會隨 Claude 每次重繪跳動。
4. 選字送出「注音」。
   - **B4 送字**：「注音」出現在 Claude 輸入框，沒有被當成按鍵指令（例如沒有觸發 Claude 的快捷鍵）。
5. 再次組字，按 `Esc`。
   - **B5 Esc**：只取消組字，**不會**中斷 Claude 的串流（Claude 收到 Esc 會停止生成）。
6. Claude 跳出權限詢問（可請它「建立一個 hello.txt」觸發）時重做 3–4。
   - **B6 權限畫面**：組字與送字在權限選單出現時仍正常。
7. 換 McBopomofo 重做 3–6（未安裝填 `N/A`）。
8. 每個引擎各用 `TERM_PROGRAM: (unset)` 測一輪；Ghostty 另用 `TERM_PROGRAM: ghostty` 再測一輪，看結果是否不同。
9. 輸入法切到注音但**不組字**（選單列顯示「注」），在 Claude 串流中按 `Ctrl+C`。
   - **B9 注音狀態下 Ctrl+C**：Claude 停止生成。
   - 背景：較早一次 `--probe` 在注音為目前輸入法時量到，Claude 開啟 kitty keyboard（`CSI > 1 u`）後，**兩個引擎**都把 Ctrl+C 編成 `\e[12559;5u`（U+310F ㄏ）、Ctrl+V 編成 `\e[12562;5u`（U+3112 ㄒ），而不是 `\e[99;5u` / `\e[118;5u`。原因是兩者都用「目前鍵盤配置」換算 kitty 鍵碼（`NSEvent.characters(byApplyingModifiers: [])`），注音配置把字母鍵對到注音符號。legacy 模式（zsh）不受影響。若 B9 失敗就是這個問題，請記錄；修法在 host 端（Ctrl／Alt 組合鍵改用 ASCII 配置的鍵碼），與引擎選擇無關。
10. 同樣停在注音（不組字），擷取一張圖片到剪貼簿後在 Claude 輸入框按 `Ctrl+V`。
    - **B10 注音狀態下 Ctrl+V 貼圖**：出現 `[Image #N]`。
11. 打 `5` `j`（組字中、不選字）後按 `Ctrl+C`。
    - **B11 組字中按 Ctrl 鍵**：記錄實際結果（只取消組字／中斷 Claude／兩者／沒反應）；不得把注音符號或亂碼送進 Claude。

## C. Shift+Enter (and Option+Enter) in `claude`

1. 在 Claude 輸入框打 `line1`，按 `Shift+Enter`，再打 `line2`。
   - **C1**：輸入框變成兩行，**沒有**送出。
2. 同樣用 `Option+Enter`。
   - **C2**：換行不送出（若 Claude 把它當送出，記錄下來）。
3. 確認 `Enter` 會送出。
   - **C3**：單獨按 `Enter` 會送出。
4. 用三種 `TERM_PROGRAM` 各測一次 C1。自動化結果（`RESULTS.md` §2）顯示：Claude 開啟 kitty keyboard（`CSI > 1 u`）後，兩個引擎都送 `\e[13;2u`；在未開啟 kitty 的情況下，SwiftTerm 的 Shift+Enter 只送 `\r`。

## D. Image paste in `claude`

1. 用 `Cmd+Ctrl+Shift+4` 擷取一塊螢幕到剪貼簿（只有圖片、沒有文字）。
2. 在 Claude 輸入框按 `Ctrl+V`。
   - **D1**：Claude 顯示 `[Image #1]`（或類似的圖片標記）。
3. 再擷取一次，改按 `Cmd+V`。spike 會在剪貼簿只有圖片時把 `Cmd+V` 轉成 `Ctrl+V`（0x16）。
   - **D2**：同樣出現圖片標記。
4. 從 Finder 複製一個圖片**檔案**後按 `Cmd+V`。
   - **D3**：貼上的是檔案路徑（文字），不是圖片標記。
5. 行內圖片（kitty graphics）。Claude 2.1.300 只在 XTVERSION 名稱是 `kitty` / `ghostty` 時才在終端機裡畫圖（`RESULTS.md` §1 的 CLAUDE 表：Ghostty 會開、SwiftTerm 不會），但環境變數 `CLAUDE_CODE_FORCE_TERMINAL_IMAGES` 可以強制打開，不必偽造 XTVERSION。SwiftTerm 用 CMD `CLAUDE_CODE_FORCE_TERMINAL_IMAGES=1 claude` 啟動（spike 會把開頭的變數指定交給 zsh 執行），Ghostty 用一般的 `claude`，重做 D1。
   - **D4**：兩邊都看得到 Claude 在畫面中畫出的圖片（縮圖或預覽），位置與大小正確、捲動時不殘留；看不到就記錄。

## E. Scroll, selection, copy

在 zsh：

1. 執行 `seq 1 5000`。
   - **E1 捲動**：觸控板／滑鼠滾輪可以往回捲到 1，慣性捲動順暢，沒有殘影。
2. 拖曳選取幾行，`Cmd+C`，貼到 CMD 欄位或 TextEdit。
   - **E2 選取複製**：內容正確，行尾沒有多餘空白或少字；包含中文時中文完整。
3. 雙擊選字、三擊選行。
   - **E3**：雙擊選到一個字詞，三擊選到整行。

在 claude（fullscreen 模式，你的設定是 `tui: fullscreen`）：

4. 讓 Claude 輸出超過一頁的內容後用滾輪捲動。
   - **E4**：捲的是 Claude 自己的對話紀錄（滑鼠回報），畫面不破。
5. 拖曳選取 Claude 畫面上的文字並複製。Claude 開了滑鼠回報時，終端機通常要按住修飾鍵才會做本地選取（Ghostty 是 `Shift`，SwiftTerm 試 `Option` 或 `Shift`）。
   - **E5**：能選取並複製出正確文字；記錄需要哪個修飾鍵。
6. 點擊位置。兩個引擎都回報支援 SGR pixel 滑鼠（DECRQM 1016），所以 Claude 用像素座標加上 `CSI 16 t` 回報的格子大小換算點到哪一格。在 Retina 螢幕上點 Claude 畫面裡可點的項目（例如工具結果的展開列、對話紀錄中的某一行）。
   - **E6**：點到的就是游標下那一格／那一行，左右上下都沒有偏移（偏一倍代表像素與格子大小的單位不一致）。

## F. Cmd+click links

1. 在 zsh 狀態按 `PATTERN`。
2. `Cmd+click` 「ghostty docs (Cmd+click)」（OSC 8 超連結）。
   - **F1**：瀏覽器開啟 https://ghostty.org/docs。
3. `Cmd+click` 後面的純文字網址。
   - **F2**：瀏覽器開啟 SwiftTerm 的 GitHub 頁（自動辨識網址）。
4. 請 Claude 在回答中附一個網址，`Cmd+click` 它。
   - **F3**：在 Claude 畫面中也能開啟。Claude 2.1.300 的 Cmd+click 特別處理（假設 Cmd+click 的滑鼠回報不帶修飾位元）只看 `TERM_PROGRAM=ghostty`，不看 XTVERSION；所以兩個引擎都要分別用 `TERM_PROGRAM: (unset)` 與 `TERM_PROGRAM: ghostty` 各測一次，記錄哪個組合能開。

## G. Resize

1. zsh 中執行 `stty size`，拖曳視窗邊緣改變大小後再執行一次。
   - **G1**：數字跟標頭列的 cols×rows 一致。
2. `SIDE BY SIDE` 拖曳中間分隔線，左右快速來回。
   - **G2**：兩邊都跟著重排，沒有殘留舊畫面或撕裂。
3. 在 claude（fullscreen）中快速拖曳視窗大小。
   - **G3**：Claude 畫面重繪正確，沒有重複的輸入框、斷掉的框線或錯位的狀態列。Ghostty 若表現不佳，以 `GHOSTTY_SURFACE_RESIZE_THROTTLE_MS=96` 重開再測，記錄差異。
4. `View › Enter Full Screen`（`Ctrl+Cmd+F`）進入 macOS 全螢幕再離開。
   - **G4**：進出全螢幕後格數與畫面都正確。

## H. Full-screen Claude TUI rendering

1. `SIDE BY SIDE`，兩邊都 `START` claude，送同一個提示詞（例如「列出 10 個台灣城市和它們的特色小吃，用表格呈現」）。
   - **H1 框線**：Claude 的輸入框、表格的 `─ │ ╭ ╮ ╰ ╯` 連續無斷點，角落接合。
   - **H2 顏色**：Claude 自己的主題色（truecolor）正確，沒有被 CODD 的琥珀色調覆蓋；diff 的紅綠底色正確。
   - **H3 CJK 寬度**：中文表格右邊框對齊；中英混排不會擠在一起或多出空格。
   - **H4 動態符號**：`✻` `◐` `◑` `●` `⎿` 都顯示，不是方框或問號。
   - **H5 串流穩定**：串流時沒有閃爍或整片重畫跳動（同步輸出 2026）。
   - **H6 游標**：Claude 等待輸入時游標在輸入框內，琥珀色方塊。
2. 回到 zsh 按 `PATTERN`。
   - **H7 測試圖樣**：16 色與 256 色、漸層、粗體／斜體／底線／波浪底線／刪除線／反白都正確；CJK 對齊區的四行 `|` 上下對齊；方框與區塊字元無縫。SwiftTerm 不支援 overline（SGR 53），stdout 會印 `Unknown SGR attribute: 53`，屬已知差異。

## I. Typing feel and latency

1. zsh 裡快速連打一串英文、再快速連打注音。
   - **I1**：沒有可感知的延遲或掉字；記錄標頭列的 `KEY→PTY` p99。
2. （選做）Instruments 記錄 os_signpost：

   ```sh
   xcrun xctrace record --instrument os_signpost --attach TermSpike --time-limit 30s \
     --output /tmp/termspike-signpost.trace
   ```

   在 Instruments 中以 subsystem `app.fancycodd.TermSpike` 篩選：`keyDown→ptyWrite`（category `latency`）與 `ptyRead→feed`（category `io`）。
   要量真正的按鍵到字形延遲，需要 Typometer 或 Metal System Trace，記錄在備註欄。

## J. Restart after the program exits

1. CMD `zsh -l` → `START`，在 zsh 打 `exit`。標頭列顯示 `EXITED · exit 0`。
2. 再按 `START`，打幾個字。
   - **J1**：新的 zsh 有提示字元，打字有反應。背景：`--probe` 的「input after reported exit」顯示 Ghostty 在被告知子程序結束（`ghostty_surface_process_exit`）之後就不再送出按鍵，所以 spike 在這種情況會換一個新的引擎；這一項確認換過之後一切正常。CODD 也要做同樣的處理（或不要把結束告訴 Ghostty）。

---

## RESULTS TABLE

填 `PASS` / `FAIL` / `N/A`，FAIL 請在備註寫現象。

| ID | 項目 | GHOSTTY | SWIFTTERM | 備註 |
|---|---|---|---|---|
| A1 | zsh：注音 preedit 在游標位置 | | | |
| A2 | zsh：候選窗在游標下方 | | | |
| A3 | zsh：送字正確 | | | |
| A4 | zsh：Esc 只取消組字 | | | |
| A5 | zsh：Backspace 只改組字 | | | |
| A6 | zsh：中文寬度與游標移動 | | | |
| A7 | zsh：McBopomofo（A1–A6） | | | |
| A8 | zsh：注音狀態下 Ctrl+C | | | |
| B1 | claude 串流中：preedit 位置（寫出實際位置） | | | |
| B2 | claude 串流中：組字不被重繪清掉 | | | |
| B3 | claude 串流中：候選窗不跳動 | | | |
| B4 | claude：送字進輸入框 | | | |
| B5 | claude：Esc 只取消組字、不中斷 Claude | | | |
| B6 | claude 權限畫面：組字與送字 | | | |
| B7 | claude：McBopomofo（B1–B6） | | | |
| B8 | claude：TERM_PROGRAM=ghostty 時有差異嗎 | | | |
| B9 | claude：注音狀態下 Ctrl+C 中斷串流 | | | |
| B10 | claude：注音狀態下 Ctrl+V 貼圖 | | | |
| B11 | claude：組字中按 Ctrl+C（寫出結果） | | | |
| C1 | Shift+Enter 換行不送出（unset / ghostty / CODD） | | | |
| C2 | Option+Enter 換行不送出 | | | |
| C3 | Enter 送出 | | | |
| D1 | Ctrl+V 貼圖 | | | |
| D2 | Cmd+V 貼圖（spike 轉 ^V） | | | |
| D3 | Cmd+V 貼 Finder 檔案 → 路徑 | | | |
| D4 | 行內圖片（SwiftTerm 用 FORCE_TERMINAL_IMAGES） | | | |
| E1 | zsh 捲動 | | | |
| E2 | 選取與 Cmd+C（含中文） | | | |
| E3 | 雙擊選字、三擊選行 | | | |
| E4 | claude 內滾輪捲動 | | | |
| E5 | claude 內選取複製（修飾鍵：） | | | |
| E6 | claude 內點擊位置正確（Retina） | | | |
| F1 | Cmd+click OSC 8 連結 | | | |
| F2 | Cmd+click 純文字網址 | | | |
| F3 | Cmd+click claude 畫面中的網址（unset / ghostty） | | | |
| G1 | resize 後 stty size 正確 | | | |
| G2 | 分隔線快速拖曳不殘影 | | | |
| G3 | claude 中 resize 重繪正確（throttle 0 / 96） | | | |
| G4 | 進出 macOS 全螢幕 | | | |
| H1 | claude 框線連續 | | | |
| H2 | claude 顏色正確 | | | |
| H3 | claude CJK 寬度對齊 | | | |
| H4 | ✻ ◐ ◑ ● ⎿ 顯示 | | | |
| H5 | 串流不閃爍 | | | |
| H6 | 游標位置與顏色 | | | |
| H7 | PATTERN 測試圖樣 | | | |
| I1 | 打字手感、KEY→PTY p99（ms） | | | |
| J1 | 程式結束後再 START，打字正常 | | | |

測試日期：　　　　　　 macOS：27.0.1　 Claude Code 版本：　　　　　 測試者：
