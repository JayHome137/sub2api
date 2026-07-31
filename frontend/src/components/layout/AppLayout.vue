<template>
  <div class="aifoo-console min-h-screen bg-gray-50 dark:bg-dark-950">
    <!-- Background Decoration -->
    <div class="pointer-events-none fixed inset-0 bg-mesh-gradient"></div>

    <!-- Sidebar -->
    <AppSidebar />

    <!-- Main Content Area -->
    <div
      class="relative min-h-screen transition-all duration-300"
      :class="[sidebarCollapsed ? 'lg:ml-[72px]' : 'lg:ml-64']"
    >
      <!-- Header -->
      <AppHeader />

      <!-- Main Content -->
      <main class="p-4 md:p-6 lg:p-8">
        <slot />
      </main>
    </div>
  </div>
</template>

<script setup lang="ts">
import '@/styles/onboarding.css'
import { computed, onBeforeUnmount, onMounted, watch } from 'vue'
import { useRoute } from 'vue-router'
import { useAppStore } from '@/stores'
import { useAuthStore } from '@/stores/auth'
import { useOnboardingTour } from '@/composables/useOnboardingTour'
import { useOnboardingStore } from '@/stores/onboarding'
import AppSidebar from './AppSidebar.vue'
import AppHeader from './AppHeader.vue'
import { aifooRouteClass } from '@/utils/aifoo'

const route = useRoute()
const appStore = useAppStore()
const authStore = useAuthStore()
const sidebarCollapsed = computed(() => appStore.sidebarCollapsed)
const isAdmin = computed(() => authStore.user?.role === 'admin')

const { replayTour } = useOnboardingTour({
  storageKey: isAdmin.value ? 'admin_guide' : 'user_guide',
  autoStart: true
})

const onboardingStore = useOnboardingStore()
const routeClass = computed(() => aifooRouteClass(route.path))

function applyAifooShell(nextClass: string, previousClass?: string) {
  const root = document.documentElement
  if (previousClass) root.classList.remove(previousClass)
  root.classList.add('console-shell')
  document.body.classList.add('console-override-active')
  if (nextClass) root.classList.add(nextClass)
}

watch(routeClass, (nextClass, previousClass) => {
  applyAifooShell(nextClass, previousClass)
}, { immediate: true })

onMounted(() => {
  applyAifooShell(routeClass.value)
  onboardingStore.setReplayCallback(replayTour)
})

onBeforeUnmount(() => {
  document.documentElement.classList.remove('console-shell', routeClass.value)
  document.body.classList.remove('console-override-active')
})

defineExpose({ replayTour })
</script>
