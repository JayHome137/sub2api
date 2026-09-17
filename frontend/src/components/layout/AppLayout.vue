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

<script lang="ts">
let activeShellOwner: symbol | null = null
</script>

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
const shellOwner = Symbol('aifoo-layout')
let appliedRouteClass = ''

function applyAifooShell(nextClass: string) {
  const root = document.documentElement
  // A redirect or a remounted layout may leave the bootstrap/previous route behind.
  for (const name of [...root.classList]) {
    if (name.startsWith('route-')) root.classList.remove(name)
  }
  appliedRouteClass = nextClass
  root.classList.add('console-shell')
  document.body.classList.add('console-override-active')
  if (nextClass) root.classList.add(nextClass)
}

watch(routeClass, (nextClass) => {
  applyAifooShell(nextClass)
}, { immediate: true })

onMounted(() => {
  activeShellOwner = shellOwner
  applyAifooShell(routeClass.value)
  onboardingStore.setReplayCallback(replayTour)
})

onBeforeUnmount(() => {
  const root = document.documentElement
  // route.path may already point to the next page while this layout is unmounting.
  if (activeShellOwner === shellOwner) {
    activeShellOwner = null
    root.classList.remove('console-shell', appliedRouteClass)
    document.body.classList.remove('console-override-active')
  }
})

defineExpose({ replayTour })
</script>
