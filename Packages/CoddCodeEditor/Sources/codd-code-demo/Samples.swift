import AppKit
import CoddCodeEditor
import CoddUI

/// The FileEditor artboard's `punch.vue` (lines 13–49 are the artboard's, verbatim; the rest is
/// made up so the file is whole: 56 lines, `sticky` 7 times) and the other samples.
enum Samples {
    static let pink = NSColor(hex: 0xFF7CB5)

    static let punchVue = """
    <script setup>
    import { computed, onMounted } from 'vue'
    import { useWindowSize } from '@vueuse/core'
    import PunchButton from '@/components/PunchButton.vue'
    import PunchRecordCard from '@/components/PunchRecordCard.vue'
    import { usePunchStore } from '@/stores/punch'

    const store = usePunchStore()
    const { width } = useWindowSize()
    const isNarrow = computed(() => width.value < 640)
    const records = computed(() => store.todayRecords)

    onMounted(() => store.fetchToday())
    </script>

    <template>
      <main class="punch-page">
        <header class="punch-head">
          <h1 class="text-lg font-bold">今日打卡</h1>
          <span class="text-sm text-stone-500">{{ store.todayLabel }}</span>
        </header>
        <template v-if="isNarrow">
          <PunchRecordCard v-for="r in records" :key="r.id" :record="r" />
        </template>
        <table v-else class="punch-table">
          <tr v-for="r in records" :key="r.id">
            <td>{{ r.typeLabel }}</td>
            <td class="tabular-nums">{{ r.time }}</td>
            <td class="truncate">{{ r.location }}</td>
          </tr>
        </table>
        <div class="punch-sticky">
          <PunchButton :loading="store.pending" sticky @punch="store.punch" />
        </div>
      </main>
    </template>

    <style scoped>
    .punch-sticky {
      position: sticky;
      bottom: env(safe-area-inset-bottom);
      margin-bottom: 64px; /* 底部導覽列高度 */
      z-index: 10;
    }
    .punch-page {
      min-height: 100dvh;
      padding-bottom: calc(64px + env(safe-area-inset-bottom));
    }
    @media (max-width: 640px) {
      .punch-head {
        position: sticky;
        top: 0;
        z-index: 11; /* 疊在 .punch-sticky 上 */
        background: var(--sticky-bg); }
    }
    </style>
    """

    /// `@@ -40,2 +40,4 @@`: HEAD had `position: fixed; bottom: 0;` where lines 40–43 are now.
    static let punchHunk = InlineDiffHunk(
        id: 2, newLines: 39 ..< 43, deletedLines: ["  position: fixed;", "  bottom: 0;"],
        header: InlineDiffHeader(tagColor: pink, showAIChip: true, who: "打卡頁 RWD 調整 · 10:36", range: "@@ -40,2 +40,4 @@",
                                 removed: 2, added: 4, position: "2 / 2"))

    static let typescript = """
    import { defineStore } from 'pinia'
    import type { PunchRecord, PunchType } from '@/types/punch'

    /** 打卡紀錄：今日清單與送出狀態 */
    interface PunchState {
      records: PunchRecord[]
      pending: boolean
      error?: string
    }

    const API_BASE = import.meta.env.VITE_API_BASE ?? '/api'
    const TIME = /^(\\d{2}):(\\d{2})$/

    export const usePunchStore = defineStore('punch', {
      state: (): PunchState => ({ records: [], pending: false }),
      getters: {
        todayLabel: (state) => `${state.records.length} 筆 · ${new Date().toLocaleDateString('zh-TW')}`,
        lastType(state): PunchType | undefined {
          return state.records.at(-1)?.type
        },
      },
      actions: {
        async fetchToday() {
          const response = await fetch(`${API_BASE}/punch/today`)
          if (!response.ok) throw new Error(`HTTP ${response.status}`)
          this.records = (await response.json()) as PunchRecord[]
        },
        async punch(type: PunchType = 'in') {
          this.pending = true
          try {
            const body = JSON.stringify({ type, at: Date.now() })
            await fetch(`${API_BASE}/punch`, { method: 'POST', body })
            await this.fetchToday()
          } finally {
            this.pending = false // 送出後一律解除
          }
        },
      },
    })
    """

    static let json = """
    {
      "name": "orb-toolkit-frontend",
      "version": "0.8.2",
      "private": true,
      "type": "module",
      "scripts": {
        "dev": "vite",
        "build": "vue-tsc --noEmit && vite build",
        "preview": "vite preview --port 4173"
      },
      "dependencies": {
        "pinia": "^2.2.6",
        "vue": "^3.5.13",
        "vue-router": "^4.5.0"
      },
      "devDependencies": {
        "@vitejs/plugin-vue": "^5.2.1",
        "tailwindcss": "^3.4.16",
        "typescript": "~5.6.3",
        "vite": "^6.0.3"
      },
      "engines": { "node": ">=20" },
      "browserslist": ["> 1%", "last 2 versions", "not dead"],
      "sideEffects": false,
      "workspaces": null,
      "punchRetryCount": 3,
      "punchTimeoutSeconds": 12.5
    }
    """

    static let python = """
    #!/usr/bin/env python3
    \"\"\"匯出打卡紀錄成 CSV（每週一 09:00 排程）。\"\"\"
    from __future__ import annotations

    import csv
    from dataclasses import dataclass
    from datetime import date, timedelta
    from pathlib import Path


    @dataclass(frozen=True)
    class Punch:
        user: str
        kind: str  # "in" | "out"
        at: str


    def week_range(today: date) -> tuple[date, date]:
        start = today - timedelta(days=today.weekday() + 7)
        return start, start + timedelta(days=6)


    def export(rows: list[Punch], target: Path) -> int:
        with target.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(["user", "kind", "at"])
            for row in rows:
                writer.writerow([row.user, row.kind, row.at])
        return len(rows)


    if __name__ == "__main__":
        first, last = week_range(date.today())
        count = export([], Path(f"punch-{first:%Y%m%d}-{last:%m%d}.csv"))
        print(f"wrote {count} rows", r"raw \\d+", 0x1F, 3.5e2)
    """
}
