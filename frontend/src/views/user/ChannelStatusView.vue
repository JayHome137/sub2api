<template>
  <ChannelStatusV1View v-if="isV1" />
  <ChannelStatusV2View v-else-if="showLegacyV2" />
  <ChannelStatusV3View v-else />
</template>

<script setup lang="ts">
import { computed, defineAsyncComponent } from 'vue'
import { isChannelMonitorV1Mode } from '@/utils/featureFlags'
const ChannelStatusV1View = defineAsyncComponent(() => import('./ChannelStatusV1View.vue').then(module => module.default))
const ChannelStatusV2View = defineAsyncComponent(() => import('./ChannelStatusV2View.vue').then(module => module.default))
const ChannelStatusV3View = defineAsyncComponent(() => import('./ChannelStatusV3View.vue').then(module => module.default))

// Presentation-only fallback; backend monitoring stays in official V2 mode.
const showLegacyV2 = new URLSearchParams(window.location.search).get('monitor_view') === 'v2'
const isV1 = computed(() => isChannelMonitorV1Mode())
</script>
