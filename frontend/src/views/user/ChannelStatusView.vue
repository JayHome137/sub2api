<template>
  <ChannelStatusV1View v-if="isV1" />
  <ChannelStatusV2View v-else-if="showLegacyV2" />
  <ChannelStatusV3View v-else />
</template>

<script setup lang="ts">
import { computed } from 'vue'
import { isChannelMonitorV1Mode } from '@/utils/featureFlags'
import ChannelStatusV1View from './ChannelStatusV1View.vue'
import ChannelStatusV2View from './ChannelStatusV2View.vue'
import ChannelStatusV3View from './ChannelStatusV3View.vue'

// Presentation-only fallback; backend monitoring stays in official V2 mode.
const showLegacyV2 = new URLSearchParams(window.location.search).get('monitor_view') === 'v2'
const isV1 = computed(() => isChannelMonitorV1Mode())
</script>
