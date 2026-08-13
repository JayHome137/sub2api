<template>
  <div ref="rootRef" class="relative">
    <template v-if="isAdmin">
      <button
        data-testid="version-badge"
        type="button"
        class="flex items-center gap-1.5 rounded-lg px-2 py-1 text-xs transition-colors"
        :class="badgeClass"
        :title="badgeTitle"
        @click="toggleDropdown"
      >
        <span v-if="displayVersion" class="font-medium">v{{ displayVersion }}</span>
        <span
          v-else
          class="h-3 w-12 animate-pulse rounded bg-gray-200 font-medium dark:bg-dark-600"
        ></span>
        <span v-if="needsUpgradeAttention" class="relative flex h-2 w-2" aria-hidden="true">
          <span
            class="absolute inline-flex h-full w-full animate-ping rounded-full bg-amber-400 opacity-75"
          ></span>
          <span class="relative inline-flex h-2 w-2 rounded-full bg-amber-500"></span>
        </span>
      </button>

      <transition name="dropdown">
        <div
          v-if="dropdownOpen"
          data-testid="version-status-panel"
          class="absolute left-0 z-50 mt-2 w-64 overflow-hidden whitespace-normal rounded-xl border border-gray-200 bg-white shadow-lg dark:border-dark-700 dark:bg-dark-800"
        >
          <div
            class="flex items-center justify-between border-b border-gray-100 px-4 py-3 dark:border-dark-700"
          >
            <span class="text-sm font-medium text-gray-700 dark:text-dark-300">
              {{ t('version.currentVersion') }}
            </span>
            <button
              type="button"
              class="rounded-lg p-1.5 text-gray-400 transition-colors hover:bg-gray-100 hover:text-gray-600 disabled:cursor-not-allowed disabled:opacity-50 dark:hover:bg-dark-700 dark:hover:text-dark-200"
              :disabled="loading"
              :title="t('version.refresh')"
              @click="refreshVersion(true)"
            >
              <Icon
                name="refresh"
                size="sm"
                :stroke-width="2"
                :class="{ 'animate-spin': loading }"
              />
            </button>
          </div>

          <div class="p-4">
            <div
              v-if="loading"
              data-testid="upgrade-status-loading"
              class="flex items-center justify-center py-6 text-primary-500"
            >
              <Icon name="refresh" size="sm" :stroke-width="2" class="animate-spin" />
            </div>

            <template v-else>
              <div class="mb-4 text-center">
                <div class="inline-flex items-center gap-2">
                  <span class="text-2xl font-bold text-gray-900 dark:text-white">
                    {{ displayVersion ? `v${displayVersion}` : '--' }}
                  </span>
                  <span
                    v-if="!needsUpgradeAttention && !statusUnavailable"
                    class="flex h-5 w-5 items-center justify-center rounded-full bg-green-100 text-green-600 dark:bg-green-900/30 dark:text-green-400"
                    aria-hidden="true"
                  >
                    ✓
                  </span>
                </div>
                <p
                  v-if="showUpgradeCandidate || !upstreamHasUpdate"
                  class="mt-1 text-xs text-gray-500 dark:text-dark-400"
                >
                  {{
                    showUpgradeCandidate && latestVersion
                      ? `${t('version.latestVersion')}: v${latestVersion}`
                      : t('version.upToDate')
                  }}
                </p>
              </div>

              <div
                v-if="statusUnavailable"
                data-testid="upgrade-status-unavailable"
                class="rounded-lg border border-red-200 bg-red-50 p-3 dark:border-red-800/50 dark:bg-red-900/20"
              >
                <p class="text-sm font-medium text-red-700 dark:text-red-300">
                  {{ t('version.statusUnavailable') }}
                </p>
                <p class="mt-1 text-xs leading-5 text-red-600/80 dark:text-red-400/80">
                  {{ t('version.statusUnavailableHint') }}
                </p>
              </div>

              <div
                v-else-if="showUpgradeCandidate && bridgeUnavailable"
                data-testid="upgrade-status-bridge-unavailable"
                class="rounded-lg border border-red-200 bg-red-50 p-3 dark:border-red-800/50 dark:bg-red-900/20"
              >
                <p class="text-sm font-medium text-red-700 dark:text-red-300">
                  {{ t('version.bridgeUnavailable') }}
                </p>
                <p class="mt-1 text-xs leading-5 text-red-600/80 dark:text-red-400/80">
                  {{ t('version.bridgeUnavailableHint') }}
                </p>
              </div>

              <div
                v-else-if="showUpgradeCandidate && upgradeStatus"
                :data-testid="upgradeStateTestId"
                class="space-y-2"
              >
                <div class="rounded-lg border p-3" :class="upgradeStateClass">
                  <div class="flex items-start gap-2">
                    <Icon
                      v-if="upgradeState === 'deploying' || upgradeState === 'preparing'"
                      name="refresh"
                      size="sm"
                      :stroke-width="2"
                      class="mt-0.5 shrink-0 animate-spin"
                    />
                    <div class="min-w-0 flex-1">
                      <p class="text-sm font-medium">
                        {{ t(upgradeStateTitleKey) }}
                      </p>
                      <p class="mt-1 text-xs leading-5 opacity-80">
                        {{ t(upgradeStateHintKey, { version: `v${latestVersion}` }) }}
                      </p>
                    </div>
                  </div>
                </div>

                <button
                  v-if="canDispatch"
                  data-testid="dispatch-aifoo-upgrade"
                  type="button"
                  class="flex w-full items-center justify-center gap-2 rounded-lg bg-primary-500 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-primary-600 disabled:cursor-not-allowed disabled:opacity-60"
                  :disabled="dispatching"
                  @click="dispatchUpgrade"
                >
                  <Icon
                    v-if="dispatching"
                    name="refresh"
                    size="sm"
                    :stroke-width="2"
                    class="animate-spin"
                  />
                  <Icon v-else name="download" size="sm" :stroke-width="2" />
                  {{ t(upgradeState === 'failed' ? 'version.retryUpdate' : 'version.updateNow') }}
                </button>
              </div>

              <a
                v-if="showUpgradeCandidate && officialReleaseUrl"
                :href="officialReleaseUrl"
                target="_blank"
                rel="noopener noreferrer"
                class="mt-2 flex items-center justify-center gap-1 text-xs text-gray-500 transition-colors hover:text-gray-700 dark:text-dark-400 dark:hover:text-dark-200"
              >
                {{ t('version.viewChangelog') }}
                <Icon name="externalLink" size="xs" :stroke-width="2" />
              </a>
            </template>
          </div>
        </div>
      </transition>
    </template>

    <span v-else-if="version" class="text-xs text-gray-500 dark:text-dark-400">
      v{{ version }}
    </span>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { useAppStore, useAuthStore } from '@/stores'
import Icon from '@/components/icons/Icon.vue'
import { sanitizeUrl } from '@/utils/url'
import {
  dispatchAIFooUpgrade,
  getAIFooUpgradeStatus,
  type AIFooUpgradeState,
  type AIFooUpgradeStatus
} from '@/api/admin/upgrade'

const props = defineProps<{
  version?: string
}>()

const { t } = useI18n()
const authStore = useAuthStore()
const appStore = useAppStore()

const rootRef = ref<HTMLElement | null>(null)
const dropdownOpen = ref(false)
const statusUnavailable = ref(false)
const bridgeUnavailable = ref(false)
const bridgeLoading = ref(false)
const dispatching = ref(false)
const upgradeStatus = ref<AIFooUpgradeStatus | null>(null)
let pollTimer: ReturnType<typeof setTimeout> | null = null
let dispatchStartedHere = false
let disposed = false

const isAdmin = computed(() => authStore.isAdmin)
const loading = computed(() => appStore.versionLoading || bridgeLoading.value || dispatching.value)
const displayVersion = computed(() => appStore.currentVersion || props.version || '')
const latestVersion = computed(() => appStore.latestVersion || '')
const upstreamHasUpdate = computed(() => Boolean(appStore.hasUpdate && latestVersion.value))
const officialReleaseUrl = computed(() => sanitizeUrl(appStore.releaseInfo?.html_url || ''))
const canDispatch = computed(() => Boolean(upgradeStatus.value?.can_dispatch && !dispatching.value))
const upgradeState = computed<AIFooUpgradeState>(
  () => upgradeStatus.value?.state || 'preparing'
)
const upgradeStateTestId = computed(() => `upgrade-status-${upgradeState.value}`)
const upgradeStateTitleKey = computed(() => `version.state.${upgradeState.value}`)
const upgradeStateHintKey = computed(() => `version.stateHint.${upgradeState.value}`)
const showUpgradeCandidate = computed(
  () =>
    Boolean(upgradeStatus.value?.can_dispatch) ||
    ['deploying', 'deployed'].includes(upgradeState.value)
)
const needsUpgradeAttention = computed(
  () => Boolean(upgradeStatus.value?.can_dispatch) || upgradeState.value === 'deploying'
)
const upgradeStateClass = computed(() => {
  switch (upgradeState.value) {
    case 'ready':
      return 'border-amber-200 bg-amber-50 text-amber-700 dark:border-amber-800/50 dark:bg-amber-900/20 dark:text-amber-300'
    case 'deploying':
      return 'border-blue-200 bg-blue-50 text-blue-700 dark:border-blue-800/50 dark:bg-blue-900/20 dark:text-blue-300'
    case 'deployed':
      return 'border-green-200 bg-green-50 text-green-700 dark:border-green-800/50 dark:bg-green-900/20 dark:text-green-300'
    case 'ui_review_required':
      return 'border-purple-200 bg-purple-50 text-purple-700 dark:border-purple-800/50 dark:bg-purple-900/20 dark:text-purple-300'
    case 'failed':
      return 'border-red-200 bg-red-50 text-red-700 dark:border-red-800/50 dark:bg-red-900/20 dark:text-red-300'
    default:
      return 'border-gray-200 bg-gray-50 text-gray-700 dark:border-dark-700 dark:bg-dark-900/50 dark:text-dark-300'
  }
})

const badgeClass = computed(() => {
  if (needsUpgradeAttention.value) {
    return 'bg-amber-100 text-amber-700 hover:bg-amber-200 dark:bg-amber-900/30 dark:text-amber-400 dark:hover:bg-amber-900/50'
  }
  if (statusUnavailable.value) {
    return 'bg-red-100 text-red-700 hover:bg-red-200 dark:bg-red-900/30 dark:text-red-400 dark:hover:bg-red-900/50'
  }
  return 'bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-dark-800 dark:text-dark-400 dark:hover:bg-dark-700'
})

const badgeTitle = computed(() => {
  if (statusUnavailable.value) return t('version.statusUnavailable')
  if (needsUpgradeAttention.value) return t(upgradeStateTitleKey.value)
  return t('version.upToDate')
})

function toggleDropdown() {
  dropdownOpen.value = !dropdownOpen.value
}

async function refreshVersion(force = true) {
  if (!isAdmin.value) return
  statusUnavailable.value = false
  const result = await appStore.fetchVersion(force)
  if (disposed) return
  statusUnavailable.value = result == null
  if (!result) {
    stopPolling()
    return
  }
  const trackedVersion = result.latest_version || result.current_version
  if (trackedVersion) {
    await refreshUpgradeStatus(`v${trackedVersion.replace(/^v/, '')}`)
  } else {
    bridgeUnavailable.value = false
    upgradeStatus.value = null
    stopPolling()
  }
}

async function refreshUpgradeStatus(releaseTag: string, polling = false) {
  if (!polling) bridgeLoading.value = true
  try {
    const result = await getAIFooUpgradeStatus(releaseTag)
    if (disposed) return
    upgradeStatus.value = result
    bridgeUnavailable.value = false
    if (result.state === 'deploying') {
      schedulePolling(releaseTag)
    } else {
      stopPolling()
    }
    if (result.state === 'deployed' && dispatchStartedHere) {
      dispatchStartedHere = false
      await appStore.fetchVersion(true)
      window.location.reload()
    }
  } catch {
    if (disposed) return
    bridgeUnavailable.value = true
    if (polling) schedulePolling(releaseTag)
  } finally {
    bridgeLoading.value = false
  }
}

async function dispatchUpgrade() {
  const releaseTag = upgradeStatus.value?.release_tag
  if (!releaseTag || !canDispatch.value) return
  dispatching.value = true
  try {
    upgradeStatus.value = await dispatchAIFooUpgrade(releaseTag)
    if (disposed) return
    bridgeUnavailable.value = false
    dispatchStartedHere = true
    appStore.showInfo(t('version.deploymentStarted'))
    schedulePolling(releaseTag)
  } catch {
    appStore.showError(t('version.deploymentStartFailed'))
  } finally {
    dispatching.value = false
  }
}

function schedulePolling(releaseTag: string) {
  if (disposed) return
  stopPolling()
  pollTimer = setTimeout(() => {
    pollTimer = null
    void refreshUpgradeStatus(releaseTag, true)
  }, 5000)
}

function stopPolling() {
  if (pollTimer) {
    clearTimeout(pollTimer)
    pollTimer = null
  }
}

function handleClickOutside(event: MouseEvent) {
  if (rootRef.value && !rootRef.value.contains(event.target as Node)) {
    dropdownOpen.value = false
  }
}

onMounted(() => {
  disposed = false
  if (isAdmin.value) {
    void refreshVersion(false)
  }
  document.addEventListener('click', handleClickOutside)
})

onBeforeUnmount(() => {
  disposed = true
  stopPolling()
  document.removeEventListener('click', handleClickOutside)
})
</script>

<style scoped>
.dropdown-enter-active,
.dropdown-leave-active {
  transition: opacity 0.2s ease, transform 0.2s ease;
}

.dropdown-enter-from,
.dropdown-leave-to {
  opacity: 0;
  transform: scale(0.95) translateY(-4px);
}
</style>
