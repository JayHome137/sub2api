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
        <span v-if="hasUpdate" class="relative flex h-2 w-2" aria-hidden="true">
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
              data-testid="github-upgrade-status-link"
              :href="upgradeStatusUrl"
              target="_blank"
              rel="noopener noreferrer"
              class="flex min-h-10 w-full items-center justify-center gap-2 rounded-lg bg-gray-900 px-4 py-2 text-sm font-medium text-white transition-colors hover:bg-gray-800 dark:bg-white dark:text-gray-900 dark:hover:bg-gray-200"
            >
              {{ t('version.viewGithubStatus') }}
              <Icon name="externalLink" size="xs" :stroke-width="2" />
            </a>

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
              {{ t('version.manualDeploymentRequired') }}
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

const UPGRADE_STATUS_URL =
  'https://github.com/JayHome137/sub2api/issues?q=is%3Aissue+is%3Aopen+label%3Aupstream-release'

const props = defineProps<{
  version?: string
}>()

const { t } = useI18n()
const authStore = useAuthStore()
const appStore = useAppStore()

const rootRef = ref<HTMLElement | null>(null)
const dropdownOpen = ref(false)
const statusUnavailable = ref(false)

const isAdmin = computed(() => authStore.isAdmin)
const loading = computed(() => appStore.versionLoading)
const displayVersion = computed(() => appStore.currentVersion || props.version || '')
const latestVersion = computed(() => appStore.latestVersion || '')
const hasUpdate = computed(() => Boolean(appStore.hasUpdate && latestVersion.value))
const officialReleaseUrl = computed(() => sanitizeUrl(appStore.releaseInfo?.html_url || ''))
const upgradeStatusUrl = UPGRADE_STATUS_URL

const badgeClass = computed(() => {
  if (hasUpdate.value) {
    return 'bg-amber-100 text-amber-700 hover:bg-amber-200 dark:bg-amber-900/30 dark:text-amber-400 dark:hover:bg-amber-900/50'
  }
  if (statusUnavailable.value) {
    return 'bg-red-100 text-red-700 hover:bg-red-200 dark:bg-red-900/30 dark:text-red-400 dark:hover:bg-red-900/50'
  }
  return 'bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-dark-800 dark:text-dark-400 dark:hover:bg-dark-700'
})

const badgeTitle = computed(() => {
  if (statusUnavailable.value) return t('version.statusUnavailable')
  if (hasUpdate.value) return t('version.stableReleaseDetected')
  return t('version.upgradeStatus')
})

function toggleDropdown() {
  dropdownOpen.value = !dropdownOpen.value
}

async function refreshVersion(force = true) {
  if (!isAdmin.value) return
  statusUnavailable.value = false
  const result = await appStore.fetchVersion(force)
  statusUnavailable.value = result == null
}

function handleClickOutside(event: MouseEvent) {
  if (rootRef.value && !rootRef.value.contains(event.target as Node)) {
    dropdownOpen.value = false
  }
}

onMounted(() => {
  if (isAdmin.value) {
    void refreshVersion(false)
  }
  document.addEventListener('click', handleClickOutside)
})

onBeforeUnmount(() => {
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
