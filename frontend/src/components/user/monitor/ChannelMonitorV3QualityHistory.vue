<template>
  <div
    v-if="enabled && groupId"
    class="channel-signal-quality-history mt-3 border-t border-white/70 pt-3 dark:border-dark-700/60"
    data-testid="channel-quality-history"
  >
    <div class="channel-signal-timeline__legend mb-1.5 flex items-center justify-between text-[10px] font-semibold uppercase tracking-widest text-gray-400">
      <span>{{ t('monitorCommon.qualityHistoryTitle', { n: events.length }) }}</span>
      <span v-if="degradedCount" class="tabular-nums text-red-500/90 dark:text-red-400/90">
        {{ t('monitorCommon.qualityHistoryDegradedCount', { n: degradedCount }) }}
      </span>
    </div>

    <div v-if="loading && !hasLoaded" class="pb-1 text-[10px] text-gray-400">{{ t('monitorCommon.qualityHistoryLoading') }}</div>
    <div v-else-if="loadFailed && !events.length" class="pb-1 text-[10px] text-red-500/90 dark:text-red-400/90">{{ t('monitorCommon.qualityHistoryFailed') }}</div>
    <div v-else-if="!events.length" class="pb-1 text-[10px] text-gray-400">{{ t('monitorCommon.qualityHistoryEmpty') }}</div>

    <div v-else class="quality-history-strip flex flex-wrap gap-1.5" @mouseleave="clearHover">
      <button
        v-for="(event, index) in events"
        :key="event.id"
        type="button"
        class="quality-history-chip"
        :class="[event.status === 'degraded' ? 'is-degraded' : 'is-pass', { 'is-active': hoveredIndex === index }]"
        :data-testid="`quality-history-chip-${event.id}`"
        :aria-label="chipLabel(event)"
        @mouseenter="hoverEvent(index, $event)"
        @focus="hoverEvent(index, $event)"
        @blur="clearHover"
      >
        <span class="quality-history-chip__dot" aria-hidden="true" />
        <span class="quality-history-chip__time tabular-nums">{{ formatChipTime(event.created_at) }}</span>
      </button>
    </div>

    <Teleport to="body">
      <Transition name="v3-timeline-tooltip">
        <div
          v-if="hovered && hoveredEvent"
          class="quality-history-popover"
          :style="popoverStyle"
          role="tooltip"
          data-testid="quality-history-popover"
        >
          <div class="quality-history-popover__head">
            <span
              class="font-semibold"
              :class="hoveredEvent.status === 'degraded' ? 'text-red-400' : 'text-emerald-400'"
            >
              {{ hoveredEvent.status === 'degraded' ? t('monitorCommon.qualityHistoryDegraded') : t('monitorCommon.qualityHistoryPass') }}
            </span>
            <span class="font-mono text-amber-300/90" data-testid="quality-history-event-id">#{{ hoveredEvent.id }}</span>
            <span class="text-gray-300">{{ formatFullTime(hoveredEvent.created_at) }}</span>
            <span v-if="hoveredEvent.model_id" class="truncate font-mono text-gray-400">{{ hoveredEvent.model_id }}</span>
          </div>
          <div
            v-if="hoveredEvent.quality_mode === 'candy' && hoveredEvent.status === 'success'"
            class="quality-history-popover__message"
          >
            {{ hoveredEvent.error_message || t('monitorCommon.qualityHistoryCandyPass') }}
          </div>
          <div v-if="artworkLoading" class="quality-history-popover__message">
            {{ t('monitorCommon.qualityArtworkLoading') }}
          </div>
          <div v-else-if="artworkFailed" class="quality-history-popover__message is-error">
            {{ t('monitorCommon.qualityArtworkFailed') }}
          </div>
          <iframe
            v-else-if="hoveredArtwork"
            class="quality-history-popover__preview"
            :srcdoc="hoveredArtworkSrcdoc"
            :title="t('monitorCommon.qualityArtworkPreview')"
            sandbox=""
            referrerpolicy="no-referrer"
          />
        </div>
      </Transition>
    </Teleport>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { getQualityEventArtwork, getQualityEvents, type MonitorQualityEvent } from '@/api/channelMonitorV2'

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
const hovered = ref(false)
const hoveredIndex = ref<number | null>(null)
const hoveredArtwork = ref('')
const artworkLoading = ref(false)
const artworkFailed = ref(false)
const popoverPosition = ref({ left: 0, top: 0, x: '-50%', y: '-100%' })
let hoverRequest = 0

const hoveredEvent = computed(() => (hoveredIndex.value === null ? null : events.value[hoveredIndex.value] ?? null))
const degradedCount = computed(() => events.value.filter((event) => event.status === 'degraded').length)
const hoveredArtworkSrcdoc = computed(() => {
  if (!hoveredArtwork.value || typeof DOMParser === 'undefined') return ''
  const document = new DOMParser().parseFromString(hoveredArtwork.value, 'text/html')
  for (const meta of document.querySelectorAll('meta[http-equiv]')) meta.remove()
  const policy = document.createElement('meta')
  policy.httpEquiv = 'Content-Security-Policy'
  policy.content = [
    "default-src 'none'",
    'img-src data: blob:',
    "style-src 'unsafe-inline' data:",
    'font-src data:',
    'media-src data:',
    "connect-src 'none'",
    "frame-src 'none'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "navigate-to 'none'",
  ].join('; ')
  document.head.prepend(policy)
  return `<!doctype html>${document.documentElement.outerHTML}`
})

async function load() {
  if (!props.enabled || !props.groupId) {
    events.value = []
    clearHover()
    return
  }
  loading.value = true
  loadFailed.value = false
  try {
    const list = await getQualityEvents(props.groupId, 30)
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
  () => { void load() },
  { immediate: true },
)

function formatChipTime(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '--:--'
  return new Intl.DateTimeFormat(locale.value || undefined, { hour: '2-digit', minute: '2-digit' }).format(date)
}

function formatFullTime(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return '-'
  return new Intl.DateTimeFormat(locale.value || undefined, {
    month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit',
  }).format(date)
}

function chipLabel(event: MonitorQualityEvent) {
  const status = event.status === 'degraded' ? t('monitorCommon.qualityHistoryDegraded') : t('monitorCommon.qualityHistoryPass')
  return `#${event.id} · ${formatFullTime(event.created_at)} · ${status}`
}

function positionPopover(event?: Event) {
  const target = event?.currentTarget
  if (!(target instanceof HTMLElement) || typeof window === 'undefined') return
  const rect = target.getBoundingClientRect()
  const viewportGutter = 16
  const maxWidth = Math.min(360, window.innerWidth - viewportGutter * 2)
  const placeBelow = rect.top < 240
  const top = placeBelow ? rect.bottom + 8 : rect.top - 8
  const y = placeBelow ? '0%' : '-100%'
  const center = rect.left + rect.width / 2
  if (center + maxWidth / 2 > window.innerWidth - viewportGutter) {
    popoverPosition.value = { left: window.innerWidth - viewportGutter, top, x: '-100%', y }
  } else if (center - maxWidth / 2 < viewportGutter) {
    popoverPosition.value = { left: viewportGutter, top, x: '0%', y }
  } else {
    popoverPosition.value = { left: center, top, x: '-50%', y }
  }
}

function hoverEvent(index: number, event?: Event) {
  positionPopover(event)
  hovered.value = true
  hoveredIndex.value = index
  hoveredArtwork.value = ''
  artworkFailed.value = false
  const request = ++hoverRequest
  const item = events.value[index]
  if (!props.groupId || !item || item.quality_mode === 'candy') return
  artworkLoading.value = true
  void getQualityEventArtwork(props.groupId, item.id)
    .then((artwork) => {
      if (request === hoverRequest && hoveredIndex.value === index) hoveredArtwork.value = artwork
    })
    .catch(() => {
      if (request === hoverRequest && hoveredIndex.value === index) artworkFailed.value = true
    })
    .finally(() => {
      if (request === hoverRequest) artworkLoading.value = false
    })
}

function clearHover() {
  hoverRequest++
  hovered.value = false
  hoveredIndex.value = null
  hoveredArtwork.value = ''
  artworkLoading.value = false
  artworkFailed.value = false
}

const popoverStyle = computed(() => ({
  '--tooltip-left': `${popoverPosition.value.left}px`,
  '--tooltip-top': `${popoverPosition.value.top}px`,
  '--tooltip-x': popoverPosition.value.x,
  '--tooltip-y': popoverPosition.value.y,
}))
</script>

<style scoped>
.quality-history-strip {
  max-height: 3.6rem;
  overflow: auto;
}

.quality-history-chip {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  border: 1px solid rgb(148 163 184 / 0.35);
  border-radius: 999px;
  background: rgb(248 250 252 / 0.9);
  padding: 2px 7px;
  font-size: 10px;
  font-weight: 600;
  color: rgb(71 85 105);
  cursor: crosshair;
  transition: transform 160ms cubic-bezier(0.22, 1, 0.36, 1), box-shadow 160ms ease;
}

.quality-history-chip.is-active {
  transform: translateY(-1px);
  box-shadow: 0 4px 10px rgb(15 118 110 / 0.18);
}

.quality-history-chip__dot {
  width: 6px;
  height: 6px;
  border-radius: 999px;
}

.quality-history-chip.is-pass .quality-history-chip__dot {
  background: rgb(16 185 129);
}

.quality-history-chip.is-degraded .quality-history-chip__dot {
  background: rgb(239 68 68);
}

.quality-history-chip.is-degraded {
  border-color: rgb(248 113 113 / 0.55);
  color: rgb(185 28 28);
}

.dark .quality-history-chip {
  border-color: rgb(71 85 105 / 0.6);
  background: rgb(15 23 42 / 0.55);
  color: rgb(203 213 225);
}

.quality-history-popover {
  position: fixed;
  left: var(--tooltip-left, 50%);
  top: var(--tooltip-top, 0px);
  z-index: 50;
  width: max-content;
  max-width: min(360px, calc(100vw - 32px));
  transform: translateX(var(--tooltip-x, -50%)) translateY(var(--tooltip-y, -100%));
  border: 1px solid rgb(255 255 255 / 0.14);
  border-radius: 10px;
  background: rgb(15 23 42 / 0.96);
  padding: 8px 10px;
  color: rgb(248 250 252);
  box-shadow: 0 14px 30px rgb(15 23 42 / 0.35);
  pointer-events: none;
}

.quality-history-popover__head {
  display: flex;
  align-items: baseline;
  gap: 8px;
  font-size: 10px;
  line-height: 1.4;
  white-space: nowrap;
}

.quality-history-popover__preview {
  display: block;
  width: min(320px, calc(100vw - 52px));
  height: 200px;
  margin-top: 7px;
  border: 0;
  border-radius: 4px;
  background: white;
}

.quality-history-popover__message {
  margin-top: 8px;
  font-size: 10px;
  color: rgb(203 213 225);
}

.quality-history-popover__message.is-error {
  color: rgb(252 165 165);
}

@media (prefers-reduced-motion: reduce) {
  .quality-history-chip {
    transition: none;
  }
}
</style>
