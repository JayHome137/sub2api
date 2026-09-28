<template>
  <AppLayout>
    <div class="w-full min-w-0 space-y-6 pb-8">
      <header class="page-header flex flex-wrap items-start justify-between gap-4 rounded-3xl bg-white p-5 shadow-sm ring-1 ring-gray-900/5 dark:bg-dark-800 dark:ring-dark-700 sm:p-6">
        <div>
          <h1 class="page-title flex items-center gap-2 text-xl font-black text-gray-900 dark:text-white">
            <span class="inline-flex h-8 w-8 items-center justify-center rounded-xl bg-blue-50 text-blue-500 dark:bg-blue-900/30 dark:text-blue-400">
              <Icon name="beaker" size="sm" />
            </span>
            {{ t('channelQuality.title') }}
          </h1>
          <p class="page-description mt-1.5 text-xs text-gray-500 dark:text-gray-400">{{ t('channelQuality.description') }}</p>
        </div>
        <div class="flex flex-wrap items-center gap-3">
          <label class="inline-flex items-center gap-2 text-sm text-gray-600 dark:text-gray-300">
            <input v-model="autoRefresh" type="checkbox" class="h-4 w-4 rounded border-gray-300 text-primary-600 focus:ring-primary-500" />
            {{ t('channelQuality.autoRefresh') }}
          </label>
          <button type="button" class="btn btn-secondary" :disabled="loading" :title="t('channelQuality.refresh')" @click="load()">
            <Icon name="refresh" size="sm" :class="loading ? 'animate-spin' : ''" />
            <span class="ml-1">{{ t('channelQuality.refresh') }}</span>
          </button>
        </div>
      </header>

      <section v-if="loading && items.length === 0" class="rounded-2xl bg-white p-8 text-center text-sm text-gray-500 shadow-sm dark:bg-dark-800 dark:text-gray-400">
        {{ t('common.loading') }}
      </section>
      <section v-else-if="items.length === 0" class="rounded-2xl bg-white p-8 text-center text-sm text-gray-500 shadow-sm dark:bg-dark-800 dark:text-gray-400">
        {{ t('channelQuality.noData') }}
      </section>
      <section v-else class="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <article v-for="item in items" :key="item.group_id" class="rounded-2xl bg-white p-5 shadow-sm ring-1 ring-gray-900/5 dark:bg-dark-800 dark:ring-dark-700">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <h2 class="truncate text-base font-bold text-gray-900 dark:text-white">{{ item.group_name }}</h2>
              <p class="mt-1 truncate text-xs text-gray-500 dark:text-gray-400">{{ item.channel_name }} · {{ item.platform }} · {{ item.model }}</p>
            </div>
            <span class="badge shrink-0" :class="statusClass(item.status)">{{ statusLabel(item.status) }}</span>
          </div>
          <div class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
            <span>{{ item.message }}</span>
            <span v-if="item.latency_ms != null">{{ item.latency_ms }}ms</span>
            <span v-if="item.checked_at">{{ formatCheckedAt(item.checked_at) }}</span>
          </div>
          <div class="mt-4 flex items-center gap-1.5" :aria-label="t('channelQuality.history')">
            <span v-for="point in item.timeline.slice(0, 16)" :key="point.id" class="h-2.5 flex-1 rounded-full" :class="statusDotClass(point.status)" :title="`${statusLabel(point.status)} · ${formatCheckedAt(point.checked_at)}`"></span>
          </div>
          <div class="mt-2 flex items-center justify-between text-[11px] text-gray-400 dark:text-gray-500">
            <span>{{ t('channelQuality.history') }}</span>
            <span>{{ item.timeline.length }} {{ t('channelQuality.latest') }}</span>
          </div>
        </article>
      </section>
    </div>
  </AppLayout>
</template>

<script setup lang="ts">
import { onMounted, onUnmounted, ref, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import AppLayout from '@/components/layout/AppLayout.vue'
import Icon from '@/components/icons/Icon.vue'
import channelQualityAPI, { type ChannelQualityListResponse, type ChannelQualityStatus } from '@/api/channelQuality'
import { useAppStore } from '@/stores/app'
import { extractApiErrorMessage } from '@/utils/apiError'
import { formatDateTime } from '@/utils/format'

const { t } = useI18n()
const appStore = useAppStore()
const items = ref<ChannelQualityListResponse['items']>([])
const loading = ref(false)
const autoRefresh = ref(true)
let refreshTimer: number | undefined

async function load(silent = false) {
  if (loading.value) return
  loading.value = true
  try {
    items.value = (await channelQualityAPI.list()).items || []
  } catch (error: unknown) {
    if (!silent) appStore.showError(extractApiErrorMessage(error, t('channelQuality.loadError')))
  } finally {
    loading.value = false
  }
}

function syncRefreshTimer() {
  if (refreshTimer !== undefined) window.clearInterval(refreshTimer)
  refreshTimer = autoRefresh.value ? window.setInterval(() => void load(true), 30_000) : undefined
}

function statusLabel(status: ChannelQualityStatus) {
  return t(`channelQuality.status.${status}`)
}

function statusClass(status: ChannelQualityStatus) {
  return status === 'healthy' ? 'badge-success' : status === 'degraded' ? 'badge-warning' : status === 'running' ? 'badge-info' : 'badge-gray'
}

function statusDotClass(status: ChannelQualityStatus) {
  return status === 'healthy' ? 'bg-emerald-500' : status === 'degraded' ? 'bg-amber-500' : status === 'running' ? 'bg-blue-500 animate-pulse' : 'bg-gray-300 dark:bg-dark-600'
}

function formatCheckedAt(value: string) {
  return formatDateTime(value)
}

watch(autoRefresh, syncRefreshTimer)
onMounted(() => {
  void load()
  syncRefreshTimer()
})
onUnmounted(() => {
  if (refreshTimer !== undefined) window.clearInterval(refreshTimer)
})
</script>
