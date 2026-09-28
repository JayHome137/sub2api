<template>
  <AppLayout>
    <div class="w-full min-w-0 space-y-6 pb-8">
      <header class="page-header flex flex-wrap items-start justify-between gap-4 rounded-3xl bg-white p-5 shadow-sm ring-1 ring-gray-900/5 dark:bg-dark-800 dark:ring-dark-700 sm:p-6">
        <div>
          <h1 class="page-title flex items-center gap-2 text-xl font-black text-gray-900 dark:text-white">
            <span class="inline-flex h-8 w-8 items-center justify-center rounded-xl bg-blue-50 text-blue-500 dark:bg-blue-900/30 dark:text-blue-400"><Icon name="beaker" size="sm" /></span>
            {{ t('channelQuality.title') }}
          </h1>
          <p class="page-description mt-1.5 text-xs text-gray-500 dark:text-gray-400">{{ t('channelQuality.description') }}</p>
        </div>
        <div class="flex flex-wrap gap-2">
          <button type="button" class="btn btn-secondary" :disabled="loading" :title="t('channelQuality.refresh')" @click="load">
            <Icon name="refresh" size="sm" :class="loading ? 'animate-spin' : ''" /><span class="ml-1">{{ t('channelQuality.refresh') }}</span>
          </button>
          <button type="button" class="btn btn-primary" :disabled="running" @click="runNow">
            <Icon name="play" size="sm" :class="running ? 'animate-pulse' : ''" /><span class="ml-1">{{ t('channelQuality.runNow') }}</span>
          </button>
        </div>
      </header>

      <section class="rounded-2xl bg-white p-5 shadow-sm ring-1 ring-gray-900/5 dark:bg-dark-800 dark:ring-dark-700">
        <div class="mb-4 flex items-center gap-2 text-sm font-semibold text-gray-900 dark:text-white"><Icon name="cog" size="sm" class="text-gray-500" />{{ t('common.settings') }}</div>
        <form class="space-y-4" @submit.prevent="saveConfig">
          <label class="inline-flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300"><input v-model="config.enabled" type="checkbox" class="h-4 w-4 rounded border-gray-300 text-primary-600 focus:ring-primary-500" />{{ t('channelQuality.enabled') }}</label>
          <div class="grid grid-cols-1 gap-4 md:grid-cols-3">
            <label class="block"><span class="input-label">{{ t('channelQuality.interval') }}</span><input v-model.number="config.interval_seconds" type="number" min="60" max="86400" class="input" /></label>
            <label class="block"><span class="input-label">{{ t('channelQuality.historyLimit') }}</span><input v-model.number="config.history_limit" type="number" min="10" max="1000" class="input" /></label>
            <label class="block"><span class="input-label">{{ t('channelQuality.model') }}</span><input v-model="config.model" type="text" class="input" /></label>
          </div>
          <div class="grid grid-cols-1 gap-4 md:grid-cols-2">
            <label class="block"><span class="input-label">{{ t('channelQuality.prompt') }}</span><textarea v-model="config.prompt" rows="3" class="input" /></label>
            <label class="block"><span class="input-label">{{ t('channelQuality.expected') }}</span><textarea v-model="config.expected_answer" rows="3" class="input" /></label>
          </div>
          <div class="flex justify-end"><button type="submit" class="btn btn-primary" :disabled="saving"><Icon name="check" size="sm" :class="saving ? 'animate-pulse' : ''" /><span class="ml-1">{{ saving ? t('common.saving') : t('channelQuality.save') }}</span></button></div>
        </form>
      </section>

      <section v-if="loading && items.length === 0" class="rounded-2xl bg-white p-8 text-center text-sm text-gray-500 shadow-sm dark:bg-dark-800 dark:text-gray-400">{{ t('common.loading') }}</section>
      <section v-else-if="items.length === 0" class="rounded-2xl bg-white p-8 text-center text-sm text-gray-500 shadow-sm dark:bg-dark-800 dark:text-gray-400">{{ t('channelQuality.noData') }}</section>
      <section v-else class="grid grid-cols-1 gap-4 xl:grid-cols-2">
        <article v-for="item in items" :key="item.group_id" class="rounded-2xl bg-white p-5 shadow-sm ring-1 ring-gray-900/5 dark:bg-dark-800 dark:ring-dark-700">
          <div class="flex items-start justify-between gap-3"><div class="min-w-0"><h2 class="truncate text-base font-bold text-gray-900 dark:text-white">{{ item.group_name }}</h2><p class="mt-1 truncate text-xs text-gray-500 dark:text-gray-400">{{ item.channel_name }} · {{ item.platform }} · {{ item.model }}</p></div><span class="badge shrink-0" :class="statusClass(item.status)">{{ statusLabel(item.status) }}</span></div>
          <div class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-gray-500 dark:text-gray-400"><span>{{ item.message }}</span><span v-if="item.latency_ms != null">{{ item.latency_ms }}ms</span><span v-if="item.checked_at">{{ formatCheckedAt(item.checked_at) }}</span></div>
          <div class="mt-4 flex items-center gap-1.5"><span v-for="point in item.timeline.slice(0, 16)" :key="point.id" class="h-2.5 flex-1 rounded-full" :class="statusDotClass(point.status)" :title="`${statusLabel(point.status)} · ${formatCheckedAt(point.checked_at)}`"></span></div>
          <div class="mt-2 flex items-center justify-between text-[11px] text-gray-400 dark:text-gray-500"><span>{{ t('channelQuality.history') }}</span><span>{{ item.timeline.length }} {{ t('channelQuality.latest') }}</span></div>
        </article>
      </section>
    </div>
  </AppLayout>
</template>

<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import AppLayout from '@/components/layout/AppLayout.vue'
import Icon from '@/components/icons/Icon.vue'
import adminChannelQualityAPI from '@/api/admin/channelQuality'
import type { ChannelQualityConfig, ChannelQualityListResponse, ChannelQualityStatus } from '@/api/channelQuality'
import { useAppStore } from '@/stores/app'
import { extractApiErrorMessage } from '@/utils/apiError'
import { formatDateTime } from '@/utils/format'

const { t } = useI18n()
const appStore = useAppStore()
const items = ref<ChannelQualityListResponse['items']>([])
const loading = ref(false)
const saving = ref(false)
const running = ref(false)
const config = reactive<ChannelQualityConfig>({ enabled: false, interval_seconds: 900, model: '', prompt: 'Reply with exactly: QUALITY_OK', expected_answer: 'QUALITY_OK', history_limit: 100 })

async function load() {
  loading.value = true
  try {
    const [nextConfig, list] = await Promise.all([adminChannelQualityAPI.getConfig(), adminChannelQualityAPI.list()])
    Object.assign(config, nextConfig)
    items.value = list.items || []
  } catch (error: unknown) {
    appStore.showError(extractApiErrorMessage(error, t('channelQuality.loadError')))
  } finally {
    loading.value = false
  }
}

async function saveConfig() {
  saving.value = true
  try {
    Object.assign(config, await adminChannelQualityAPI.updateConfig({ ...config }))
    appStore.showSuccess(t('channelQuality.configSaved'))
  } catch (error: unknown) {
    appStore.showError(extractApiErrorMessage(error, t('channelQuality.saveError')))
  } finally {
    saving.value = false
  }
}

async function runNow() {
  running.value = true
  try {
    await adminChannelQualityAPI.runNow()
    appStore.showSuccess(t('channelQuality.runStarted'))
    window.setTimeout(() => void load(), 1000)
  } catch (error: unknown) {
    appStore.showError(extractApiErrorMessage(error, t('channelQuality.runError')))
  } finally {
    running.value = false
  }
}

function statusLabel(status: ChannelQualityStatus) { return t(`channelQuality.status.${status}`) }
function statusClass(status: ChannelQualityStatus) { return status === 'healthy' ? 'badge-success' : status === 'degraded' ? 'badge-warning' : status === 'running' ? 'badge-info' : 'badge-gray' }
function statusDotClass(status: ChannelQualityStatus) { return status === 'healthy' ? 'bg-emerald-500' : status === 'degraded' ? 'bg-amber-500' : status === 'running' ? 'bg-blue-500 animate-pulse' : 'bg-gray-300 dark:bg-dark-600' }
function formatCheckedAt(value: string) { return formatDateTime(value) }

onMounted(() => void load())
</script>
