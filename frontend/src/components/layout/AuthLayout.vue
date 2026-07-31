<template>
  <div class="aifoo-auth-layout">
    <nav class="aifoo-auth-top-links" aria-label="登录页快捷导航">
      <a class="aifoo-auth-top-link" href="/#home">AI中转站</a>
      <a class="aifoo-auth-top-link" href="/docs-nodejs.html">接入文档</a>
      <a class="aifoo-auth-top-link" href="/pricing.html">模型价格</a>
    </nav>

    <button
      class="auth-theme-toggle"
      type="button"
      :aria-label="isDark ? '切换浅色模式' : '切换深色模式'"
      @click="toggleTheme"
    >
      <Icon :name="isDark ? 'sun' : 'moon'" size="sm" />
    </button>

    <div class="aifoo-auth-panel">
      <div class="aifoo-auth-brand">
        <img :src="aifooLogo" alt="AIFoo" />
      </div>

      <div class="aifoo-auth-card">
        <div v-if="routeMeta" class="aifoo-auth-route-meta">
          <span>{{ routeMeta.kicker }}</span>
          <strong>{{ routeMeta.title }}</strong>
          <p>{{ routeMeta.note }}</p>
        </div>
        <slot />
      </div>

      <div class="aifoo-auth-footer">
        <slot name="footer" />
      </div>

      <div class="aifoo-auth-copyright">
        &copy; {{ currentYear }} {{ siteName }}. All rights reserved.
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, onBeforeMount, onBeforeUnmount, onMounted, ref } from 'vue'
import { useRoute } from 'vue-router'
import { useAppStore } from '@/stores'
import Icon from '@/components/icons/Icon.vue'

const route = useRoute()
const appStore = useAppStore()

const siteName = computed(() => appStore.siteName || 'Sub2API')
const isDark = ref(document.documentElement.classList.contains('dark'))
const aifooLogo = computed(() => isDark.value
  ? '/landing-assets/foo_ai_logo_white.svg'
  : '/landing-assets/foo_ai_logo_black.svg')

const AUTH_ROUTE_META: Record<string, { kicker: string; title: string; note: string }> = {
  '/register': { kicker: 'AIFOO / REGISTER', title: '创建账户', note: '创建账户并开始使用统一的 AI API 服务。' },
  '/forgot-password': { kicker: 'AIFOO / RECOVERY', title: '找回密码', note: '通过邮箱安全重置账户密码。' },
  '/reset-password': { kicker: 'AIFOO / RESET', title: '重设密码', note: '设置新密码以继续完成恢复流程。' },
  '/email-verify': { kicker: 'AIFOO / VERIFY', title: '验证邮箱', note: '完成邮箱验证后继续账户流程。' }
}

const routeMeta = computed(() => AUTH_ROUTE_META[route.path])
const currentYear = computed(() => new Date().getFullYear())

function toggleTheme() {
  isDark.value = !isDark.value
  document.documentElement.classList.toggle('dark', isDark.value)
  localStorage.setItem('theme', isDark.value ? 'dark' : 'light')
}

onBeforeMount(() => {
  document.body.classList.add('auth-landing-page')
})

onMounted(() => {
  appStore.fetchPublicSettings()
})

onBeforeUnmount(() => {
  document.body.classList.remove('auth-landing-page')
})
</script>
