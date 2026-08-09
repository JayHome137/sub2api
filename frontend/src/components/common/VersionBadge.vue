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
          class="absolute left-0 z-50 mt-2 w-72 overflow-hidden whitespace-normal rounded-lg border border-gray-200 bg-white shadow-lg dark:border-dark-700 dark:bg-dark-800"
        >
          <div
            class="flex items-center justify-between border-b border-gray-100 px-4 py-3 dark:border-dark-700"
          >
            <span class="text-sm font-medium text-gray-700 dark:text-dark-300">
              {{ t('version.upgradeStatus') }}
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

          <div class="space-y-3 p-4">
            <div class="text-center">
              <p class="text-xs text-gray-500 dark:text-dark-400">
                {{ t('version.currentVersion') }}
              </p>
              <p class="mt-1 text-2xl font-bold text-gray-900 dark:text-white">
                {{ displayVersion ? `v${displayVersion}` : '--' }}
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
              v-else-if="loading"
              data-testid="upgrade-status-loading"
              class="flex items-center justify-center gap-2 rounded-lg border border-gray-200 bg-gray-50 px-3 py-5 text-sm text-gray-500 dark:border-dark-700 dark:bg-dark-900/50 dark:text-dark-400"
            >
              <Icon name="refresh" size="sm" :stroke-width="2" class="animate-spin" />
              {{ t('version.checkingRelease') }}
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
              class="rounded-lg border p-3"
              :class="upgradeStateClass"
            >
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

              <button
                v-if="canDispatch"
                data-testid="dispatch-aifoo-upgrade"
                type="button"
                class="mt-3 flex min-h-10 w-full items-center justify-center gap-2 rounded-lg bg-amber-500 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-amber-600 disabled:cursor-not-allowed disabled:opacity-60"
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
                {{ t(upgradeState === 'failed' ? 'version.retryUpdate' : 'version.updateNow') }}
              </button>
            </div>

            <div
              v-else-if="hasUpdate"
              data-testid="upgrade-status-detected"
              class="rounded-lg border border-amber-200 bg-amber-50 p-3 dark:border-amber-800/50 dark:bg-amber-900/20"
            >
              <p class="text-sm font-medium text-amber-700 dark:text-amber-300">
                {{ t('version.stableReleaseDetected') }}
              </p>
              <p class="mt-1 text-xs text-amber-600/80 dark:text-amber-400/80">
                {{ t('version.latestVersion') }}: v{{ latestVersion }}
              </p>
            </div>

            <div
              v-else
              data-testid="upgrade-status-watching"
              class="rounded-lg border border-green-200 bg-green-50 p-3 dark:border-green-800/50 dark:bg-green-900/20"
            >
              <p class="text-sm font-medium text-green-700 dark:text-green-300">
                {{ t('version.noStableReleaseDetected') }}
              </p>
              <p class="mt-1 text-xs leading-5 text-green-600/80 dark:text-green-400/80">
                {{ t('version.githubStatusHint') }}
              </p>
            </div>

            <a
              v-if="hasUpdate && officialReleaseUrl"
              :href="officialReleaseUrl"
              target="_blank"
              rel="noopener noreferrer"
              class="flex items-center justify-center gap-1 text-xs text-gray-500 transition-colors hover:text-gray-700 dark:text-dark-400 dark:hover:text-dark-200"
            >
              {{ t('version.viewOfficialRelease') }}
              <Icon name="externalLink" size="xs" :stroke-width="2" />
            </a>

            <p class="text-center text-[11px] leading-4 text-gray-400 dark:text-dark-500">
              {{ t('version.webApprovalHint') }}
            </p>
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
const hasUpdate = computed(() => Boolean(appStore.hasUpdate && latestVersion.value))
const officialReleaseUrl = computed(() => sanitizeUrl(appStore.releaseInfo?.html_url || ''))
const canDispatch = computed(() => Boolean(upgradeStatus.value?.can_dispatch && !dispatching.value))
const upgradeState = computed<AIFooUpgradeState>(
  () => upgradeStatus.value?.state || 'preparing'
)
const upgradeStateTestId = computed(() => `upgrade-status-${upgradeState.value}`)
const upgradeStateTitleKey = computed(() => `version.state.${upgradeState.value}`)
const upgradeStateHintKey = computed(() => `version.stateHint.${upgradeState.value}`)
const showUpgradeCandidate = computed(
  () => hasUpdate.value || Boolean(upgradeStatus.value && upgradeState.value !== 'preparing')
)
const needsUpgradeAttention = computed(
  () =>
    hasUpdate.value ||
    ['ready', 'deploying', 'failed', 'ui_review_required'].includes(upgradeState.value)
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
  return t('version.upgradeStatus')
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
