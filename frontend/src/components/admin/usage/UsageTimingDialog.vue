<template>
  <BaseDialog :show="!!record" :title="t('requestTiming.title')" width="extra-wide" @close="$emit('close')">
    <div v-if="record" class="space-y-5">
      <div class="rounded-xl bg-gray-50 p-4 dark:bg-dark-800">
        <div class="flex flex-wrap justify-between gap-2"><strong>{{ record.model }}</strong><span>{{ formatDateTime(record.created_at) }}</span></div>
        <div class="mt-2 break-all font-mono text-xs text-gray-500">{{ record.request_id }}</div>
      </div>
      <div class="grid grid-cols-2 gap-3 md:grid-cols-3">
        <div v-for="item in summaries" :key="item.label" class="rounded-xl border border-gray-200 p-4 dark:border-dark-600">
          <div class="text-sm text-gray-500">{{ item.label }}</div><strong class="mt-2 block text-xl tabular-nums">{{ ms(item.value) }}</strong>
        </div>
      </div>
      <p v-if="loading" role="status">{{ t('requestTiming.loading') }}</p>
      <div v-else-if="error" role="alert"><p>{{ t('requestTiming.loadError') }}</p><button class="btn btn-secondary mt-2" @click="load">{{ t('requestTiming.retry') }}</button></div>
      <p v-else-if="!trace" class="rounded-lg bg-gray-50 p-4 text-sm dark:bg-dark-800">{{ t('requestTiming.empty') }}</p>
      <template v-if="trace">
        <label v-if="traces.length > 1" class="block text-sm">{{ t('requestTiming.traceSelection') }}
          <select v-model="selected" class="input mt-2 w-full"><option v-for="(item, i) in traces" :key="item.trace_id" :value="i">{{ formatDateTime(item.started_at) }} · {{ ms(item.total_ms) }}</option></select>
        </label>
        <p class="text-sm text-gray-500">{{ t('requestTiming.scope') }}</p>
        <p v-if="trace.truncated" class="text-amber-600">{{ t('requestTiming.truncated') }}</p>
        <div class="grid gap-4 lg:grid-cols-3">
          <section v-for="group in groups" :key="group.title" class="rounded-xl border border-gray-200 p-4 dark:border-dark-600">
            <h4 class="mb-4 font-semibold">{{ group.title }}</h4>
            <dl class="space-y-3"><div v-for="row in group.rows" :key="row[0]" class="flex justify-between gap-4 text-sm"><dt class="text-gray-500">{{ row[0] }}</dt><dd class="shrink-0 tabular-nums">{{ row[1] }}</dd></div></dl>
          </section>
        </div>
        <section class="rounded-xl border border-gray-200 p-4 dark:border-dark-600">
          <h4 class="mb-3 font-semibold">{{ t('requestTiming.timeline') }}</h4>
          <p class="mb-3 text-xs text-gray-500">{{ t('requestTiming.overlap') }}</p>
          <div v-for="(span, i) in orderedSpans" :key="i" class="mb-3">
            <div class="flex justify-between gap-2 text-xs"><span>{{ label(span.name) }}</span><span>{{ ms(span.start_ms) }} → {{ ms(span.end_ms) }} · {{ ms(span.end_ms - span.start_ms) }}</span></div>
            <div class="mt-1 h-2 rounded bg-gray-100 dark:bg-dark-700"><div class="h-full rounded bg-primary-500" :style="bar(span)" /></div>
          </div>
        </section>
        <section v-for="attempt in trace.attempts" :key="attempt.number" class="rounded-xl border border-gray-200 p-4 dark:border-dark-600">
          <h4 class="font-semibold">{{ t('requestTiming.attempt') }} #{{ attempt.number }} · {{ t('requestTiming.account') }} #{{ attempt.account_id }} · {{ attempt.proxy_id > 0 ? `${t('requestTiming.proxy')} #${attempt.proxy_id}` : t('requestTiming.direct') }}</h4>
          <div class="mt-3 grid gap-x-8 gap-y-3 text-sm md:grid-cols-2">
            <div v-for="row in attemptRows(attempt)" :key="row[0]" class="flex justify-between gap-4"><span class="text-gray-500">{{ row[0] }}</span><span class="tabular-nums">{{ row[1] }}</span></div>
          </div>
        </section>
        <div class="break-all text-xs text-gray-500">Trace: {{ trace.trace_id }} · {{ t('requestTiming.retention', { days: retention }) }}</div>
      </template>
    </div>
  </BaseDialog>
</template>
<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import BaseDialog from '@/components/common/BaseDialog.vue'
import type { AdminUsageLog } from '@/types'
import { formatDateTime } from '@/utils/format'
import { getUsageTiming, type RequestTiming, type TimingAttempt, type TimingSpan } from '@/api/admin/usageTiming'
const props = defineProps<{ record: AdminUsageLog | null }>()
defineEmits<{ close: [] }>()
const { t } = useI18n()
const traces = ref<RequestTiming[]>([]), selected = ref(0), loading = ref(false), error = ref(false), retention = ref(30)
let controller: AbortController | undefined
const trace = computed(() => traces.value[selected.value])
const label = (name: string) => t(`requestTiming.fields.${name}`)
const ms = (value: number | null | undefined) => value == null ? t('requestTiming.missing') : value < 1 ? '<1ms' : value < 1000 ? `${value.toFixed(0)}ms` : `${(value / 1000).toFixed(2)}s`
const bytes = (value: number) => value < 0 ? t('requestTiming.missing') : `${(value / 1048576).toFixed(3)} MiB`
const yes = (value: boolean | null) => value == null ? t('requestTiming.missing') : t(value ? 'requestTiming.yes' : 'requestTiming.no')
const delta = (events: Record<string, number>, start: string, end: string) => events[start] == null || events[end] == null || events[end] < events[start] ? undefined : events[end] - events[start]
const duration = (name: string) => { const items = trace.value?.spans.filter(s => s.name === name); return items?.length ? items.reduce((n, s) => n + s.end_ms - s.start_ms, 0) : undefined }
const summaries = computed(() => [
  { label: t('requestTiming.legacyFirst'), value: props.record?.first_token_ms },
  { label: t('requestTiming.legacyTotal'), value: props.record?.duration_ms },
  { label: t('requestTiming.requestTotal'), value: trace.value?.total_ms },
  { label: label('first_semantic'), value: trace.value?.events.first_semantic },
  { label: label('first_visible'), value: trace.value?.events.first_visible },
  { label: label('first_output_flush'), value: trace.value?.events.first_output_flush }
])
const groups = computed(() => {
  const d = trace.value
  if (!d) return []
  const e = d.events
  return [
    { title: t('requestTiming.inbound'), rows: [
      [label('body_read_start'), ms(e.body_read_start)], [label('body_first_wait'), ms(delta(e, 'body_read_start', 'body_first_byte'))],
      [label('body_receive'), ms(delta(e, 'body_first_byte', 'body_received'))], [label('body_read_ms'), ms(d.body_read_ms)],
      [label('body_bytes'), bytes(d.body_bytes)], [label('body_rate'), d.body_read_ms > 0 ? `${(d.body_bytes / 1048576 / (d.body_read_ms / 1000)).toFixed(2)} MiB/s` : t('requestTiming.missing')],
      [label('body_complete'), yes(d.body_complete)]
    ] },
    { title: t('requestTiming.internal'), rows: ['api_key_auth', 'model_allowlist', 'composite_routing', 'handler_body_read', 'security_audit', 'billing_check', 'user_queue', 'account_selection', 'account_queue', 'upstream_credentials', 'build_upstream_request', 'handler'].map(name => [label(name), ms(duration(name))]) },
    { title: t('requestTiming.result'), rows: [
      [label('status'), String(d.status)], [label('attempts'), String(d.attempts.length)], [label('terminal'), d.terminal ? t(`requestTiming.${d.terminal}`) : t('requestTiming.missing')],
      [label('canceled'), yes(d.canceled)], [label('downstream_error'), yes(d.downstream_error)], [label('downstream_bytes'), bytes(d.downstream_bytes)],
      [label('downstream_write_ms'), ms(d.downstream_write_ms)], [label('ttft_mode'), d.ttft_mode || t('requestTiming.missing')]
    ] }
  ]
})
const orderedSpans = computed(() => [...(trace.value?.spans ?? [])].sort((a, b) => a.start_ms - b.start_ms))
const bar = (span: TimingSpan) => { const total = Math.max(trace.value?.total_ms ?? 1, 1); return { marginLeft: `${Math.min(100, span.start_ms / total * 100)}%`, width: `${Math.max(0.2, (span.end_ms - span.start_ms) / total * 100)}%`, maxWidth: '100%' } }
function attemptRows(a: TimingAttempt): string[][] {
  const e = a.events
  return [
    [label('attempt_total'), ms(a.end_ms == null ? undefined : a.end_ms - a.start_ms)], [label('status'), a.error ? t(`requestTiming.${a.error}`) : String(a.status)],
    [label('reused'), yes(a.reused)], [label('connection'), ms(delta(e, 'connection_start', 'connection_ready'))],
    ...['dns', 'tcp', 'tls'].map(name => [name.toUpperCase(), ms(delta(e, `${name}_start`, `${name}_end`))]),
    [label('request_write'), ms(delta(e, 'connection_ready', 'request_written'))], [label('wait_first_byte'), ms(delta(e, 'request_written', 'first_byte'))],
    [label('response_headers'), ms(e.response_headers == null ? undefined : e.response_headers - a.start_ms)],
    [label('stream_transfer'), ms(a.end_ms == null || e.response_headers == null ? undefined : a.end_ms - e.response_headers)],
    [label('request_bytes'), bytes(a.request_bytes)], [label('response_bytes'), bytes(a.response_bytes)], [label('body_eof'), yes(a.body_eof)]
  ]
}
async function load() {
  controller?.abort(); const current = new AbortController(); controller = current
  traces.value = []; selected.value = 0; error.value = false
  if (!props.record) { loading.value = false; return }
  loading.value = true
  try { const data = await getUsageTiming(props.record.id, current.signal); if (controller === current) { traces.value = data.traces; retention.value = data.retention_days } }
  catch { if (!current.signal.aborted && controller === current) error.value = true }
  finally { if (controller === current) loading.value = false }
}
watch(() => props.record?.id, load, { immediate: true })
onUnmounted(() => controller?.abort())
</script>
