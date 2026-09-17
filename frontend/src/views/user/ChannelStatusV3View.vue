<template>
  <AppLayout>
    <div class="space-y-5 pb-12">
      <section class="glass-card overflow-hidden p-0">
        <header class="flex flex-wrap items-start justify-between gap-4 border-b border-gray-100 px-5 py-4 dark:border-dark-700 sm:px-6">
          <div class="min-w-0">
            <h1 class="page-title flex items-center gap-2 text-xl font-black text-gray-900 dark:text-white">
              <span class="grid h-8 w-8 place-items-center rounded-xl bg-primary-50 text-primary-500 dark:bg-primary-900/30 dark:text-primary-300"><Icon name="chart" size="sm" /></span>
              {{ t('channelMonitorV3.title') }}
            </h1>
            <div class="mt-1.5 flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
              <span class="h-2 w-2 rounded-full" :class="refreshing ? 'bg-gray-400' : 'bg-emerald-500'" />
              <span>{{ monitorDisabled ? t('channelMonitorV3.disabled') : snapshot ? t('channelMonitorV3.updatedTo', { time: formatTime(snapshot.coverage.data_through) }) : t('common.loading') }}</span>
              <span v-if="snapshot && !snapshot.coverage.coverage_complete" class="badge badge-warning">{{ t('channelMonitorV3.partialCoverage') }}</span>
            </div>
          </div>
          <button class="btn btn-secondary btn-icon h-8 w-8 rounded-lg" type="button" :disabled="loading || refreshing" :title="t('common.refresh')" @click="reload(false)"><Icon name="refresh" size="sm" :class="refreshing ? 'animate-spin' : ''" /></button>
        </header>
        <div class="flex flex-wrap items-center gap-2 px-4 py-3 sm:px-5">
          <button v-for="option in ranges" :key="option.value" type="button" class="tab !px-2.5 !py-1 text-xs" :class="filter.range === option.value ? 'tab-active' : ''" @click="setRange(option.value)">{{ option.label }}</button>
          <span class="mx-1 hidden h-5 w-px bg-gray-200 dark:bg-dark-700 sm:block" />
          <span class="text-xs text-gray-500 dark:text-gray-400">{{ t('channelMonitorV3.description') }}</span>
          <span v-if="snapshot" class="ml-auto text-xs font-medium tabular-nums text-gray-500 dark:text-gray-400">{{ t('channelMonitorV3.summary', { success: formatPercent(monitorAvailability(snapshot.metrics, snapshot.health)), cache: formatPercent(monitorCacheRate(snapshot.metrics, snapshot.health)) }) }}</span>
        </div>
      </section>

      <div v-if="loading && rows.length === 0" class="grid grid-cols-1 gap-5 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4">
        <div v-for="i in 8" :key="i" class="h-72 animate-pulse rounded-[24px] bg-white/60 dark:bg-dark-800" />
      </div>
      <EmptyState v-else-if="rows.length === 0" :title="t('channelMonitorV3.emptyTitle')" :description="t('channelMonitorV3.emptyDescription')" />
      <div v-else class="channel-status-board space-y-8" data-testid="channel-status-board">
        <section
          v-for="(block, index) in layoutBlocks"
          :key="channelStatusLayoutBlockKey(block, index)"
          :data-layout="block.kind"
          :data-testid="block.kind === 'cluster' ? `channel-status-platform-${block.platform}` : 'channel-status-compact-platforms'"
        >
          <template v-if="block.kind === 'cluster'">
            <h2 class="mb-3 flex items-center gap-2 px-1 text-sm font-semibold text-gray-700 dark:text-gray-200">
              {{ providerLabel(block.platform) }}
              <span class="rounded-full bg-gray-100 px-1.5 py-px font-mono text-[10px] font-medium text-gray-500 dark:bg-dark-700 dark:text-gray-400">{{ block.rows.length }}</span>
            </h2>
            <div class="grid grid-cols-1 gap-5 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4">
              <ChannelMonitorV3Card
                v-for="row in block.rows"
                :key="row.group_id ?? `${row.platform}:${row.group_name ?? ''}`"
                :row="row"
                :user-rate-multiplier="getUserRateMultiplier(row.group_id)"
                :countdown-seconds="countdownSeconds"
                :timeline-length="timelineLength"
                :coverage="matrix?.coverage"
              />
            </div>
          </template>
          <div
            v-else
            class="grid grid-cols-1 gap-5 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4"
          >
            <div
              v-for="item in block.items"
              :key="item.row.group_id ?? `${item.platform}:${item.row.group_name ?? ''}`"
              :data-testid="`channel-status-platform-${item.platform}`"
            >
              <h2 class="mb-3 px-1 text-sm font-semibold text-gray-700 dark:text-gray-200">{{ providerLabel(item.platform) }}</h2>
              <ChannelMonitorV3Card
                :row="item.row"
                :user-rate-multiplier="getUserRateMultiplier(item.row.group_id)"
                :countdown-seconds="countdownSeconds"
                :timeline-length="timelineLength"
                :coverage="matrix?.coverage"
              />
            </div>
          </div>
        </section>
      </div>
    </div>
  </AppLayout>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import AppLayout from '@/components/layout/AppLayout.vue'
import EmptyState from '@/components/common/EmptyState.vue'
import Icon from '@/components/icons/Icon.vue'
import { useAppStore } from '@/stores/app'
import { extractApiErrorMessage } from '@/utils/apiError'
import * as api from '@/api/channelMonitorV2'
import userGroupsAPI from '@/api/groups'
import type { MonitorFilter, MonitorMatrixResponse, MonitorRange, MonitorSnapshot } from '@/api/channelMonitorV2'
import type { Group } from '@/types'
import ChannelMonitorV3Card from '@/components/user/monitor/ChannelMonitorV3Card.vue'
import { useChannelMonitorFormat } from '@/composables/useChannelMonitorFormat'
import { formatMonitorPercent } from '@/features/channel-monitor-v2/monitorFormat'
import { monitorAvailability, monitorCacheRate } from '@/features/channel-monitor-v2/monitorPresentation'
import { buildChannelStatusLayout, channelStatusLayoutBlockKey } from '@/features/channel-monitor-v2/channelStatusLayout'

const { t, locale } = useI18n()
const appStore = useAppStore()
const { providerLabel } = useChannelMonitorFormat()
const ranges = computed(() => [
  { value: '90m' as MonitorRange, label: t('channelMonitorV3.ranges.90m') },
  { value: '24h' as MonitorRange, label: t('channelMonitorV3.ranges.24h') },
  { value: '7d' as MonitorRange, label: t('channelMonitorV3.ranges.7d') },
  { value: '30d' as MonitorRange, label: t('channelMonitorV3.ranges.30d') },
])
const filter = ref<MonitorFilter>({ range: '90m', platforms: [], groupIds: [], models: [] })
const snapshot = ref<MonitorSnapshot | null>(null)
const matrix = ref<MonitorMatrixResponse | null>(null)
const loading = ref(false)
const refreshing = ref(false)
const monitorDisabled = ref(false)
const userGroupRates = ref<Record<number, number>>({})
const groupExclusive = ref<Record<number, boolean>>({})
const countdownSeconds = ref(0)
interface RangeData {
  snapshot: MonitorSnapshot
  matrix: MonitorMatrixResponse
  expiresAt: number
}
// View-local only: never share permission-scoped responses across login sessions.
const rangeCache = new Map<MonitorRange, RangeData>()
const pendingRanges = new Map<MonitorRange, Promise<RangeData>>()
const controllers = new Set<AbortController>()
let disposed = false
let renderRequest = 0
let prefetchTimer: number | null = null
let refreshTimer: number | null = null
let countdownTimer: number | null = null

// platform_group is intentionally used here: the backend scopes it to the
// monitor group_ids selected by the operator, so unrelated groups never appear.
const rows = computed(() => [...(matrix.value?.items ?? [])]
  .filter(row => row.group_id != null && row.group_id > 0)
  .sort((a, b) => (a.group_id ?? 0) - (b.group_id ?? 0)))
const platformSections = computed(() => {
  const grouped = new Map<string, typeof rows.value>()
  for (const row of rows.value) {
    const platform = row.platform || 'unknown'
    const current = grouped.get(platform) ?? []
    current.push(row)
    grouped.set(platform, current)
  }
  return [...grouped.entries()].map(([platform, sectionRows]) => ({
    platform,
    rows: sectionRows.sort((a, b) => groupCategory(a.group_id) - groupCategory(b.group_id)
      || (a.group_id ?? 0) - (b.group_id ?? 0)),
  }))
})
const layoutBlocks = computed(() => buildChannelStatusLayout(platformSections.value))
const timelineLength = computed(() => ({ '90m': 18, '24h': 24, '7d': 14, '30d': 30 })[filter.value.range])
function formatPercent(value: number | null) { return value == null ? '-' : formatMonitorPercent(value, locale.value || 'zh-CN') }
function formatTime(value?: string) { if (!value) return '-'; return new Intl.DateTimeFormat(locale.value || undefined, { dateStyle: 'short', timeStyle: 'short' }).format(new Date(value)) }
function setRange(value: MonitorRange) { filter.value = { ...filter.value, range: value } }

function groupCategory(groupId?: number) {
  const exclusive = groupId == null ? undefined : groupExclusive.value[groupId]
  return exclusive === false ? 0 : exclusive === true ? 1 : 2
}

function getUserRateMultiplier(groupId?: number) {
  if (!groupId) return null
  const value = userGroupRates.value[groupId]
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

async function loadUserGroupRates() {
  try {
    const [groups, customRates] = await Promise.all([
      userGroupsAPI.getAvailable().then(groups => {
        groupExclusive.value = Object.fromEntries(groups.map(group => [group.id, group.is_exclusive]))
        return groups
      }),
      userGroupsAPI.getUserGroupRates(),
    ])
    userGroupRates.value = Object.fromEntries(
      (groups as Group[]).map(group => [group.id, customRates[group.id] ?? group.rate_multiplier]),
    )
  } catch (error) {
    // Monitoring remains usable when the optional pricing endpoint is unavailable.
    console.warn('Failed to load channel monitor group rates', error)
  }
}

function loadRange(range: MonitorRange): Promise<RangeData> {
  const pending = pendingRanges.get(range)
  if (pending) return pending
  const request = new AbortController()
  controllers.add(request)
  const rangeFilter = { ...filter.value, range }
  const pendingRequest = Promise.all([
    api.getSnapshot(rangeFilter, false, request.signal),
    api.getMatrix(rangeFilter, 'platform_group', false, request.signal),
  ]).then(([nextSnapshot, nextMatrix]) => {
    const seconds = nextSnapshot.coverage.bootstrap?.active ? 10 : Math.min(60, nextSnapshot.config.refresh_interval_seconds)
    const data = { snapshot: nextSnapshot, matrix: nextMatrix, expiresAt: Date.now() + seconds * 1000 }
    if (!disposed) rangeCache.set(range, data)
    return data
  }).finally(() => {
    pendingRanges.delete(range)
    controllers.delete(request)
  })
  pendingRanges.set(range, pendingRequest)
  return pendingRequest
}

async function prefetchRanges() {
  for (const { value } of ranges.value) {
    if (disposed || document.hidden) return
    if (value === filter.value.range || rangeCache.has(value)) continue
    try { await loadRange(value) } catch { /* The selected range reports its own errors. */ }
  }
}

function showRange(data: RangeData) {
  monitorDisabled.value = false
  snapshot.value = data.snapshot
  matrix.value = data.matrix
  scheduleRefresh(Math.ceil((data.expiresAt - Date.now()) / 1000))
}

async function reload(silent = true, useCache = false) {
  const revision = ++renderRequest
  const range = filter.value.range
  const cached = useCache ? rangeCache.get(range) : undefined
  if (useCache) {
    snapshot.value = cached?.snapshot ?? null
    matrix.value = cached?.matrix ?? null
  }
  if (cached && cached.expiresAt > Date.now()) {
    showRange(cached)
    loading.value = false
    refreshing.value = false
    return
  }
  refreshing.value = true
  if (!silent) loading.value = true
  try {
    const data = await loadRange(range)
    if (disposed || revision !== renderRequest) return
    showRange(data)
  } catch (error) {
    if (disposed || revision !== renderRequest) return
    const e = error as { name?: string; code?: string; reason?: string }
    if (e.code === 'CHANNEL_MONITOR_DISABLED' || e.reason === 'CHANNEL_MONITOR_DISABLED') {
      monitorDisabled.value = true
      snapshot.value = null
      matrix.value = null
      rangeCache.clear()
      controllers.forEach(request => request.abort())
      pendingRanges.clear()
      scheduleRefresh(60)
    } else if (e.name !== 'AbortError' && e.code !== 'ERR_CANCELED') appStore.showError(extractApiErrorMessage(error, t('channelMonitorV3.loadFailed')))
  } finally {
    if (revision === renderRequest) { loading.value = false; refreshing.value = false }
  }
}

function scheduleRefresh(seconds: number) {
  const interval = Math.max(10, seconds)
  if (refreshTimer) window.clearInterval(refreshTimer)
  if (countdownTimer) window.clearInterval(countdownTimer)
  countdownSeconds.value = interval
  countdownTimer = window.setInterval(() => {
    if (!document.hidden && countdownSeconds.value > 0) countdownSeconds.value -= 1
  }, 1000)
  refreshTimer = window.setInterval(() => {
    if (!loading.value && !refreshing.value && !document.hidden) void reload(true)
  }, interval * 1000)
}

watch(() => filter.value.range, () => void reload(false, true))
onMounted(() => {
  void loadUserGroupRates()
  void reload(false).then(() => {
    if (!disposed) prefetchTimer = window.setTimeout(() => void prefetchRanges(), 500)
  })
})
onBeforeUnmount(() => {
  disposed = true
  controllers.forEach(request => request.abort())
  if (prefetchTimer) window.clearTimeout(prefetchTimer)
  if (refreshTimer) window.clearInterval(refreshTimer)
  if (countdownTimer) window.clearInterval(countdownTimer)
})
</script>
