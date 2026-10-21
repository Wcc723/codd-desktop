import Foundation

/// Mock terminal content per session (TermMarkup), transcribed from the Main artboard.
/// The real engine replaces all of this; it exists so the shell can be judged with real text.
enum MockTranscripts {
    /// Claude tab (or the shell tab of a SHELL session).
    static func primary(for id: SessionID) -> String {
        switch id {
        case "s1": permission + inputBoxNone
        case "s2": question
        case "s3": error + inputBox(mode: shortcuts)
        case "s4": done + inputBox(mode: shortcuts)
        case "s5": busyDesign + inputBox(mode: acceptEdits)
        case "s7": busyMCP + inputBox(mode: shortcuts)
        case "s9": busyPunch + inputBox(mode: acceptEdits)
        case "s10": compacting + inputBox(mode: shortcuts)
        case "s6", "s11", "s13": idle(id) + inputBox(mode: shortcuts)
        case "s14": idle(id) + "\n\n<d>// 唯讀：這個 session 在其他終端機執行，畫面由對話紀錄重建 · 接管後才能在這裡輸入</d>"
        case "s8": MockShellTranscripts.npmRunDev
        case "s12": exited
        default: inputBox(mode: shortcuts)
        }
    }

    private static let shortcuts = "? for shortcuts"
    private static let acceptEdits = "▸▸ accept edits on (shift+tab to cycle)"
    private static let inputBoxNone = ""

    private static func inputBox(mode: String) -> String {
        """


        <d>╭──────────────────────────────────────────────────────────────────────╮</d>
        <d>│</d> <a>></a> <cur> </cur>                                                                  <d>│</d>
        <d>╰──────────────────────────────────────────────────────────────────────╯</d>
          <d>\(mode)</d>
        """
    }

    private static let permission = """
    <d>></d> 登入 API 在 token 過期後會回 401，幫我修好並補測試

    <cc>●</cc> 我先看 auth middleware 的流程。

    <cc>●</cc> <w>Read</w>(src/middleware/auth.ts)
      <d>⎿  Read 84 lines</d>

    <cc>●</cc> 問題在第 41 行：token 過期時直接回 401，沒有先用 refresh token 換新的 session。

    <cc>●</cc> <w>Update</w>(src/middleware/auth.ts)
      <d>⎿  Updated src/middleware/auth.ts with 12 additions and 3 removals</d>
         <del> 41 -   if (isExpired(token)) return res.status(401).end()            </del>
         <add> 41 +   if (isExpired(token)) {                                       </add>
         <add> 42 +     const next = await refreshSession(req, res)                 </add>
         <add> 43 +     if (!next) return res.status(401).json({ code: 'EXPIRED' }) </add>

    <cc>●</cc> <w>Update</w>(test/auth.spec.ts)
      <d>⎿  Updated test/auth.spec.ts with 18 additions</d>
         <add> 58 +   it('refreshes an expired token', async () => {                </add>
         <add> 59 +     const res = await request(app).get('/me').set(expired)      </add>
         <add> 60 +     expect(res.status).toBe(200)                                </add>

    <cc>●</cc> 改好了，接著跑 auth 的測試確認。

    <a>╭──────────────────────────────────────────────────────────────────────╮</a>
    <a>│</a> <w>Bash command</w>                                                         <a>│</a>
    <a>│</a>                                                                      <a>│</a>
    <a>│</a>   npm test -- auth.spec.ts                                           <a>│</a>
    <a>│</a>   <d>執行 auth 相關的單元測試</d>
    <a>│</a>                                                                      <a>│</a>
    <a>│</a> Do you want to proceed?                                              <a>│</a>
    <a>│</a> <a>❯ 1. Yes</a>                                                             <a>│</a>
    <a>│</a>   2. Yes, and don't ask again for <w>npm test</w> commands in this project  <a>│</a>
    <a>│</a>   3. No, and tell Claude what to do differently <d>(esc)</d>                <a>│</a>
    <a>╰──────────────────────────────────────────────────────────────────────╯</a>
    """

    private static let question = """
    <d>></d> 發票列表加一個匯出 CSV，會計每月對帳要用

    <cc>●</cc> 我先看發票查詢的欄位，再決定匯出格式。

    <cc>●</cc> <w>Read</w>(src/routes/invoices.ts)
      <d>⎿  Read 156 lines</d>

    <cc>●</cc> <w>Search</w>(pattern: "toCsv|exportInvoices", path: "src")
      <d>⎿  Found 0 files</d>

    <cc>●</cc> <w>Write</w>(src/export/invoiceCsv.ts)
      <d>⎿  Wrote 48 lines to src/export/invoiceCsv.ts</d>
         <d>import { stringify } from 'csv-stringify/sync'</d>
         <d>const COLUMNS = ['發票號碼', '開立日期', '買受人', '統一編號', '金額', '稅額']</d>
         <d>… +46 lines (ctrl+r to expand)</d>

    <cc>●</cc> 欄位有中文，編碼會影響會計用 Excel 開檔的結果，先跟你確認。

    <a>╭──────────────────────────────────────────────────────────────────────╮</a>
    <a>│</a> <inv> 編碼 </inv>
    <a>│</a>                                                                      <a>│</a>
    <a>│</a> <w>CSV 要用哪種編碼？</w>
    <a>│</a>                                                                      <a>│</a>
    <a>│</a> <a>❯ 1. UTF-8 with BOM（Excel 開啟不亂碼）</a>
    <a>│</a>   2. Big5（舊系統相容）
    <a>│</a>   3. UTF-8（無 BOM）
    <a>│</a>   4. Type something                                                  <a>│</a>
    <a>│</a>                                                                      <a>│</a>
    <a>│</a> <d>Enter to select · ↑/↓ to navigate · Esc to cancel</d>                    <a>│</a>
    <a>╰──────────────────────────────────────────────────────────────────────╯</a>
    """

    private static let error = """
    <d>></d> 場景第一次載入要 6 秒，幫我找出瓶頸並優化

    <cc>●</cc> 我先量測載入流程每個階段的時間。

    <cc>●</cc> <w>Bash</w>(npm run profile:scene)
      <d>⎿  [scene] parse gltf       1,820ms</d>
         <d>[scene] upload textures  2,960ms</d>
         <d>[scene] build bvh          740ms</d>
         <d>… +4 lines (ctrl+r to expand)</d>

    <cc>●</cc> 貼圖上傳佔了將近一半。我改成 KTX2 壓縮，視野外的貼圖延後載入。

    <cc>●</cc> <w>Read</w>(src/scene/loader.ts)
      <d>⎿  Read 212 lines</d>

    <cc>●</cc> <w>Update</w>(src/scene/loader.ts)
      <d>⎿  Updated src/scene/loader.ts with 9 additions and 4 removals</d>

      <d>⎿  API Error (529 overloaded_error) · Retrying in 8 seconds… (attempt 9/10)</d>
      <r>⎿  API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}</r>
    """

    private static let done = """
    <d>></d> 把第二版原型的審查流程整理成 review/flow.md，從推 PR 到合併都要有

    <cc>●</cc> <w>Read</w>(review/README.md)
      <d>⎿  Read 41 lines</d>

    <cc>●</cc> <w>Write</w>(review/flow.md)
      <d>⎿  Wrote 86 lines to review/flow.md</d>

    <cc>●</cc> <w>Update</w>(review/README.md)
      <d>⎿  Updated review/README.md with 2 additions</d>

    <cc>●</cc> 審查流程整理好了，放在 <c>review/flow.md</c>：

      1. 提交：同事推 PR，標題用「v2 - 功能名稱」
      2. 自動檢查：CI 跑 lint 與 3 個必要測試，失敗會自動留言
      3. 程式碼審查：依審查清單的四個面向看過，每項附一句具體建議
      4. 收尾：合併前在 PR 留總結，結果同步到追蹤表

      README 也補上了流程連結。下一步可以把審查清單做成 PR 範本裡的 checklist。
    """

    private static let busyDesign = """
    <d>></d> 把 16 張畫板的規格整理成 spec/SPEC.md，共用 CSS 抽到 spec/helmet.html

    <cc>●</cc> 先把共用的 helmet 和視窗 shell 定下來，再逐張寫畫板規格。

    <cc>●</cc> <w>Write</w>(spec/helmet.html)
      <d>⎿  Wrote 291 lines to spec/helmet.html</d>
         <d><link href="…fonts.googleapis.com/css2?family=JetBrains+Mono…" rel="stylesheet"></d>
         <d><style></d>
         <d>… +289 lines (ctrl+r to expand)</d>

    <cc>●</cc> <w>Write</w>(spec/shell-sessions.html)
      <d>⎿  Wrote 152 lines to spec/shell-sessions.html</d>

    <cc>●</cc> <w>Bash</w>(python3 -I dc_lint.py test/T.dc.html test/bad.html)
      <d>⎿  == test/T.dc.html: 0 error(s), 0 warning(s)</d>
         <d>== test/bad.html: 8 error(s), 1 warning(s)</d>

    <cc>●</cc> lint 會抓到 emoji、未閉合標籤和運算式 hole，接著寫主規格。

    <cc>●</cc> <w>Write</w>(spec/SPEC.md)

    <cc>✻ Writing…</cc> <d>(2m 04s · ↓ 3.4k tokens · esc to interrupt)</d>
    """

    private static let busyMCP = """
    <d>></d> 現場示範：用 MCP Inspector 連上 demo server，列出它提供的 tools

    <cc>●</cc> 先確認 demo server 的設定，再開 Inspector。

    <cc>●</cc> <w>Read</w>(demo/mcp.json)
      <d>⎿  Read 18 lines</d>

    <cc>●</cc> <w>Bash</w>(node demo/server.js --check)
      <d>⎿  demo-weather MCP server v0.3.1 · stdio · 3 tools</d>

    <cc>●</cc> <w>Bash</w>(npx @modelcontextprotocol/inspector node demo/server.js)
      <d>⎿  Starting MCP inspector...</d>
         <d>Proxy server listening on localhost:6277</d>
         <d>Session token: 3f9c0b7e…e21a</d>
         <d>MCP Inspector is up and running at:</d>
         <d>  http://localhost:6274/?MCP_PROXY_AUTH_TOKEN=3f9c0b7e…e21a</d>
         <d>Running…</d>

    <cc>✻ Running…</cc> <d>(1m 12s · ↓ 640 tokens · esc to interrupt)</d>
    """

    private static let busyPunch = """
    <d>></d> 照 codd://note/rwd-punch-k7x2 修打卡頁：iPhone SE 按鈕被導覽列蓋住、橫向表格溢出
      <d>⎿  codd：已展開 codd://note/rwd-punch-k7x2（打卡頁 RWD 跑版紀錄 · 2 張圖片）</d>

    <cc>●</cc> 我先讀打卡頁和按鈕元件，確認底部導覽列的高度。

    <cc>●</cc> <w>Read</w>(src/pages/punch.vue)
      <d>⎿  Read 186 lines</d>

    <cc>●</cc> <w>Read</w>(src/components/PunchButton.vue)
      <d>⎿  Read 64 lines</d>

    <cc>●</cc> <w>Update</w>(tailwind.config.js)
      <d>⎿  Updated tailwind.config.js with 3 additions</d>

    <cc>●</cc> <w>Update</w>(src/components/PunchButton.vue)
      <d>⎿  Updated src/components/PunchButton.vue with 3 additions and 2 removals</d>
         <del> 12 -  <div class="fixed bottom-0 w-full p-4">                        </del>
         <del> 13 -    <button class="punch-btn" @click="punch">                    </del>
         <add> 12 +  <div class="sticky w-full p-4"                                 </add>
         <add> 13 +       :style="{ bottom: 'env(safe-area-inset-bottom)' }">       </add>
         <add> 14 +    <button class="punch-btn min-h-12" @click="punch">           </add>

    <cc>●</cc> <w>Update</w>(src/pages/punch.vue)

    <cc>✻ Editing…</cc> <d>(6m 02s · ↓ 1.2k tokens · esc to interrupt)</d>
    """

    private static let compacting = """
    <d>></d> 麵包店老闆的對話要依好感度分三段，好感度存在 NPC 狀態裡

    <cc>●</cc> <w>Read</w>(src/npc/state.ts)
      <d>⎿  Read 98 lines</d>

    <cc>●</cc> <w>Update</w>(src/npc/dialogue/baker.ts)
      <d>⎿  Updated src/npc/dialogue/baker.ts with 38 additions and 6 removals</d>

    <cc>●</cc> <w>Task</w>(檢查其他 NPC 是否沿用同一套對話格式)
      <d>⎿  Done (6 tool uses · 14.2k tokens · 48s)</d>

    <cc>●</cc> 其他 5 個 NPC 還是舊格式，我把好感度分支抽成共用的 branchByAffinity()。

    <cc>●</cc> <w>Write</w>(src/npc/dialogue/branch.ts)
      <d>⎿  Wrote 54 lines to src/npc/dialogue/branch.ts</d>

      <a>Context low (9% remaining) · auto-compacting</a>

    <cc>✻ Compacting conversation…</cc> <d>(CTX 9%)</d>
    """

    private static let exited = """
    <d>></d> UsageBar 選單列要顯示 Claude 5h 剩餘額度，低於 20% 變紅

    <cc>●</cc> <w>Read</w>(Sources/UsageBar/StatusItemController.swift)
      <d>⎿  Read 132 lines</d>

    <cc>●</cc> <w>Update</w>(Sources/UsageBar/StatusItemController.swift)
      <d>⎿  Updated Sources/UsageBar/StatusItemController.swift with 24 additions and 5 removals</d>

    <cc>●</cc> <w>Bash</w>(swift build -c release)
      <d>⎿  Build complete! (38.12s)</d>

    <cc>●</cc> 選單列會顯示 5h 剩餘百分比，低於 20% 改成紅色，點開可看重置時間。

    <d>></d> /exit
      <d>⎿  Goodbye!</d>

    <d>Resume this session with:</d>
    <d>claude --resume 2f8d3b1e-6c4a-4d17-9e2b-5a0c71f3d8e6</d>

    <d>[process exited with code 0]</d>
    """

    /// Last exchange of idle sessions (calm prompt after it).
    private static func idle(_ id: SessionID) -> String {
        let parts: (prompt: String, tool: String, arg: String, result: String, reply1: String, reply2: String)
        switch id {
        case "s6":
            parts = ("依第二版原型的需求產生程式碼審查清單，四個面向、每項列出檢查重點", "Write", "checklist/v2-review.md",
                     "Wrote 64 lines to checklist/v2-review.md", "審查清單寫好了：需求理解、錯誤處理、驗證方式、文件，",
                     "每項列出檢查重點，各附一個範例。")
        case "s11":
            parts = ("第 3 章改成三段：問題、做法、示範，每段一張投影片", "Update", "chapters/03.md",
                     "Updated chapters/03.md with 42 additions and 18 removals", "第 3 章拆成三段了，示範那段先留了螢幕截圖的位置，",
                     "等你補圖再調整版面。")
        case "s13":
            parts = ("側欄 session 依群組分層，等待中的放最上面，但不要打亂原本順序", "Update",
                     "apps/web/src/components/SessionSidebar.vue",
                     "Updated apps/web/src/components/SessionSidebar.vue with 86 additions and 12 removals",
                     "改好了：NEEDS YOU 只做鏡像，原本的順序不動；", "群組可以收合，收合狀態存在 localStorage。")
        default:
            parts = ("幫我測 LINE webhook 的簽章驗證，用 channel secret 算 HMAC-SHA256", "Bash", "npm test -- signature",
                     "PASS  test/signature.test.js (3 tests)", "簽章驗證通過，3 個測試都是綠的。",
                     ".env 裡的 LINE_CHANNEL_SECRET 記得不要進版控。")
        }
        return """
        <d>></d> \(parts.prompt)

        <cc>●</cc> <w>\(parts.tool)</w>(\(parts.arg))
          <d>⎿  \(parts.result)</d>

        <cc>●</cc> \(parts.reply1)
          \(parts.reply2)
        """
    }
}
