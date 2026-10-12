<template>
  <section
    v-if="groupId"
    class="channel-signal-quality-history mt-3 border-t border-white/70 pt-3 dark:border-dark-700/60"
    data-testid="channel-quality-history"
  >
    <div class="quality-history-header">
      <span class="quality-history-title">{{ t('monitorCommon.qualityHistoryStatusTitle') }}</span>
      <span class="quality-history-status" :class="statusClass(latestEvent?.status)">
        <span class="quality-history-status__dot" aria-hidden="true" />
        {{ latestStatusLabel }}
      </span>
    </div>

    <div class="quality-history-meta" data-testid="quality-history-meta">
      <span class="truncate" data-testid="quality-history-model">{{ latestModel }}</span>
      <span aria-hidden="true">·</span>
      <span>{{ t('monitorCommon.qualityHistoryIntervalLabel') }} {{ latestInterval }}</span>
      <span aria-hidden="true">·</span>
      <span>{{ t('monitorCommon.qualityHistoryRecent', { n: HISTORY_LIMIT }) }}</span>
    </div>

    <div
      class="quality-history-slots"
      role="img"
      :aria-label="t('monitorCommon.qualityHistoryStatusTitle')"
      data-testid="quality-history-slots"
    >
      <span
        v-for="(event, index) in historySlots"
        :key="event?.id ?? `empty-${index}`"
        class="quality-history-slot-wrap"
        @mouseleave="clearActiveSlot"
      >
        <button
          v-if="event"
          type="button"
          class="quality-history-slot"
          :class="statusClass(event.status)"
          :aria-label="eventLabel(event)"
          :aria-describedby="activeSlot === index ? `quality-history-tooltip-${event.id}` : undefined"
          :data-testid="`quality-history-slot-${index}`"
          @mouseenter="setActiveSlot(index)"
          @focus="setActiveSlot(index)"
          @blur="clearActiveSlot"
          @click="setActiveSlot(index)"
        />
        <span
          v-else
          class="quality-history-slot is-unknown is-empty"
          :aria-label="t('monitorCommon.qualityHistoryStatusNoResult')"
          :data-testid="`quality-history-slot-${index}`"
        />
        <span
          v-if="event && activeSlot === index"
          :id="`quality-history-tooltip-${event.id}`"
          class="quality-history-slot-tooltip"
          role="tooltip"
          data-testid="quality-history-tooltip"
        >
          <span>{{ t('monitorCommon.qualityHistoryTooltipTime') }}: {{ formatFullTime(event.created_at) }}</span>
          <span>{{ t('monitorCommon.qualityHistoryTooltipModel') }}: {{ event.model_id || '-' }}</span>
          <span>{{ t('monitorCommon.qualityHistoryTooltipResult') }}: {{ qualityStatusLabel(event.status) }}</span>
          <span>{{ t('monitorCommon.qualityHistoryTooltipLatency') }}: {{ formatLatency(event.latency_ms) }}</span>
          <span>{{ t('monitorCommon.qualityHistoryTooltipInterval') }}: {{ formatCronInterval(event.cron_expression) }}</span>
        </span>
      </span>
    </div>

    <div class="quality-history-footer">
      <span>{{ footerLabel }}</span>
      <time v-if="latestEvent" :datetime="latestEvent.created_at">
        {{ formatFullTime(latestEvent.created_at) }}
      </time>
    </div>
    <p v-if="loadFailed" class="quality-history-message is-error">
      {{ t('monitorCommon.qualityHistoryFailed') }}
    </p>
    <p v-else-if="loading && !hasLoaded" class="quality-history-message">
      {{ t('monitorCommon.qualityHistoryLoading') }}
    </p>
  </section>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { getQualityEvents, type MonitorQualityEvent } from '@/api/channelMonitorV2'

const HISTORY_LIMIT = 18

const props = withDefaults(defineProps<{
  groupId?: number
  enabled?: boolean
  refreshRevision?: number
}>(), {
  groupId: undefined,
  enabled: false,
  refreshRevision: 0,
})

const { t, locale } = useI18n()
const events = ref<MonitorQualityEvent[]>([])
const loading = ref(false)
const loadFailed = ref(false)
const hasLoaded = ref(false)
const activeSlot = ref<number | null>(null)

const latestEvent = computed(() => events.value[0] ?? null)
const latestModel = computed(() => latestEvent.value?.model_id || '-')
const latestInterval = computed(() => formatCronInterval(latestEvent.value?.cron_expression))
const historySlots = computed(() => {
  // The API returns newest first. The strip reads left to right from oldest to newest.
  const recent = events.value.slice(0, HISTORY_LIMIT).reverse()
  const emptyCount = Math.max(0, HISTORY_LIMIT - recent.length)
  return [...Array.from({ length: emptyCount }, () => null), ...recent]
})
const latestStatusLabel = computed(() => {
  if (!props.enabled) return t('monitorCommon.qualityHistoryStatusDisabled')
  if (!latestEvent.value) return t('monitorCommon.qualityHistoryStatusWaiting')
  return qualityStatusLabel(latestEvent.value.status)
})
const footerLabel = computed(() => {
  if (!props.enabled) return t('monitorCommon.qualityHistoryFooterDisabled')
  if (!latestEvent.value) return t('monitorCommon.qualityHistoryFooterWaiting')
  return t('monitorCommon.qualityHistoryLegend')
})

async function load() {
  if (!props.enabled || !props.groupId) {
    events.value = []
    activeSlot.value = null
    hasLoaded.value = false
    loadFailed.value = false
    return
  }
  loading.value = true
  loadFailed.value = false
  try {
    const list = await getQualityEvents(props.groupId, HISTORY_LIMIT)
    events.value = Array.isArray(list) ? list : []
    hasLoaded.value = true
  } catch {
    loadFailed.value = true
  } finally {
    loading.value = false
  }
}

watch(
  [() => props.groupId, () => props.enabled, () => props.refreshRevision],
  () => { if (document.visibilityState !== 'hidden') void load() },
  { immediate: true },
)

function formatFullTime(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '-'
  return new Intl.DateTimeFormat(locale.value || undefined, {
    month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  }).format(date)
}

function formatLatency(value?: number) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return '-'
  return `${(value / 1000).toFixed(2)}s`
}

function formatCronInterval(expression?: string) {
  const cron = expression?.trim()
  if (!cron) return t('monitorCommon.qualityHistoryIntervalUnknown')
  const everyMinutes = cron.match(/^\*\/(\d+)\s+\*\s+\*\s+\*\s+\*$/)
  if (everyMinutes) return `${everyMinutes[1]} min`
  if (cron === '0 * * * *') return '60 min'
  if (cron === '0 0 * * *') return '24 h'
  return cron
}

function statusClass(status?: string) {
  if (status === 'degraded' || status === 'failed') return 'is-degraded'
  if (status === 'success') return 'is-pass'
  return 'is-unknown'
}

function qualityStatusLabel(status?: string) {
  if (status === 'degraded' || status === 'failed') return t('monitorCommon.qualityHistoryStatusDegraded')
  if (status === 'success') return t('monitorCommon.qualityHistoryStatusPass')
  return t('monitorCommon.qualityHistoryStatusNoResult')
}

function eventLabel(event: MonitorQualityEvent) {
  return `${formatFullTime(event.created_at)} · ${qualityStatusLabel(event.status)}`
}

function setActiveSlot(index: number) {
  activeSlot.value = index
}

function clearActiveSlot() {
  activeSlot.value = null
}
</script>

<style scoped>
.channel-signal-quality-history {
  color: rgb(125 151 169);
}

.quality-history-header,
.quality-history-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}

.quality-history-title {
  color: rgb(214 232 242);
  font-size: 16px;
  font-weight: 700;
  letter-spacing: 0;
}

.quality-history-status {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  font-size: 16px;
  white-space: nowrap;
}

.quality-history-status__dot {
  width: 12px;
  height: 12px;
  flex: 0 0 auto;
  border-radius: 999px;
}

.quality-history-meta {
  display: flex;
  align-items: center;
  gap: 5px;
  margin-top: 8px;
  overflow: hidden;
  color: rgb(126 154 173);
  font-size: 14px;
  line-height: 1.3;
  white-space: nowrap;
}

.quality-history-slots {
  display: grid;
  grid-template-columns: repeat(18, minmax(0, 1fr));
  gap: 6px;
  margin-top: 16px;
}

.quality-history-slot-wrap {
  position: relative;
  min-width: 0;
}

.quality-history-slot {
  display: block;
  width: 100%;
  min-width: 0;
  height: 18px;
  border: 0;
  border-radius: 7px;
  background: rgb(71 91 105 / 0.72);
  cursor: pointer;
}

.quality-history-slot.is-empty {
  height: 6px;
  align-self: center;
  border-radius: 999px;
  background: rgb(100 116 139 / 0.75);
}

button.quality-history-slot:focus-visible {
  outline: 2px solid rgb(125 211 252);
  outline-offset: 2px;
}

.quality-history-slot-tooltip {
  position: absolute;
  bottom: calc(100% + 8px);
  left: 50%;
  z-index: 10;
  display: grid;
  width: max-content;
  max-width: min(260px, calc(100vw - 32px));
  transform: translateX(-50%);
  gap: 3px;
  border: 1px solid rgb(255 255 255 / 0.14);
  border-radius: 8px;
  background: rgb(15 23 42 / 0.96);
  padding: 7px 9px;
  color: rgb(226 232 240);
  box-shadow: 0 12px 24px rgb(15 23 42 / 0.28);
  font-size: 11px;
  line-height: 1.35;
  pointer-events: none;
  white-space: nowrap;
}

.quality-history-footer {
  margin-top: 12px;
  color: rgb(126 154 173);
  font-size: 13px;
  line-height: 1.3;
}

.quality-history-footer time {
  flex: 0 0 auto;
  font-variant-numeric: tabular-nums;
}

.quality-history-message {
  margin-top: 8px;
  color: rgb(126 154 173);
  font-size: 11px;
}

.quality-history-message.is-error {
  color: rgb(248 113 113);
}

.is-pass .quality-history-status__dot,
.quality-history-slot.is-pass {
  background: rgb(16 185 129);
}

.quality-history-status.is-pass {
  color: rgb(126 154 173);
}

.is-degraded .quality-history-status__dot,
.quality-history-slot.is-degraded {
  background: rgb(239 68 68);
}

.quality-history-status.is-degraded {
  color: rgb(248 113 113);
}

.is-unknown .quality-history-status__dot,
.quality-history-slot.is-unknown {
  background: rgb(100 116 139 / 0.75);
}

.quality-history-status.is-unknown {
  color: rgb(148 163 184);
}

@media (max-width: 640px) {
  .quality-history-title,
  .quality-history-status {
    font-size: 14px;
  }

  .quality-history-meta {
    font-size: 12px;
  }

  .quality-history-slots {
    gap: 3px;
    margin-top: 12px;
  }

  .quality-history-slot {
    height: 18px;
    border-radius: 7px;
  }

  .quality-history-footer {
    font-size: 11px;
  }
}
</style>
