<template>
  <div class="mt-3 space-y-3 rounded border p-4 dark:border-dark-600">
    <p class="text-sm" role="status">{{ text('内核状态', 'Kernel status') }}: {{ status?.phase || '—' }} · {{ status?.nodes || 0 }} {{ text('个节点', 'nodes') }}</p>
    <p v-if="error || status?.error" class="text-sm text-red-600" role="alert">{{ error || status?.error }}</p>
    <div class="flex gap-2">
      <button type="button" class="btn btn-secondary" :disabled="pending" @click="refresh">{{ text('检测状态', 'Check status') }}</button>
      <button v-if="!status?.installed" type="button" class="btn btn-primary" :disabled="pending || status?.busy || !status?.supported" @click="operate('install')">{{ text('检测并安装', 'Install kernel') }}</button>
      <button v-else-if="!status?.running" type="button" class="btn btn-secondary" :disabled="pending || status?.busy || !status?.nodes" @click="operate('start')">{{ text('启动内核', 'Start kernel') }}</button>
    </div>
    <template v-if="status?.installed">
      <label class="block text-sm" for="mihomo-subscriptions">{{ text('机场订阅地址（每行一个）', 'Subscription URLs (one per line)') }}</label>
      <textarea id="mihomo-subscriptions" v-model="subscriptions" class="input w-full" rows="3" autocomplete="off" spellcheck="false" />
      <p class="text-xs text-gray-500">{{ text('已保存', 'Saved') }} {{ status.subscriptions }} {{ text('个订阅；地址不回显，留空保留。支持 Clash/Mihomo YAML 订阅。', 'subscriptions; URLs are hidden. Leave empty to keep. Requires Clash/Mihomo YAML.') }}</p>
      <input type="file" accept=".txt,text/plain" :aria-label="text('导入订阅 TXT', 'Import subscription TXT')" @change="importFile" />
      <label class="flex items-center gap-2 text-sm"><input v-model="append" type="checkbox" />{{ text('追加到已保存订阅（不勾选则替换）', 'Append to saved subscriptions (otherwise replace)') }}</label>
      <button type="button" class="btn btn-primary" :disabled="pending || status.busy" @click="operate('apply')">{{ text('保存并应用', 'Save and apply') }}</button>
      <button v-if="status.running" type="button" class="btn btn-secondary ml-2" @click="$emit('ready', status.endpoint)">{{ text('设为打票代理', 'Use for ticket harvesting') }}</button>
      <p class="text-xs text-gray-500">{{ text('应用成功后点击“设为打票代理”，再保存系统设置。', 'After applying, select Use for ticket harvesting and save system settings.') }}</p>
      <details v-if="status.node_states?.length">
        <summary class="cursor-pointer text-sm">{{ text('节点管理', 'Manage nodes') }}</summary>
        <p class="my-2 text-xs text-gray-500">{{ text('检测仅测试网络连接，不调用模型。失败或停用节点需手动恢复。', 'Tests network connectivity only. Failed or disabled nodes require manual recovery.') }}</p>
        <div class="max-h-64 overflow-auto">
          <div v-for="node in status.node_states" :key="node.name" class="flex items-center gap-2 py-1 text-xs">
            <code>{{ node.name }}</code><span>{{ node.state }}</span>
            <button type="button" class="btn btn-secondary btn-sm" :disabled="pending || status.busy || !status.running" @click="operate('probe/' + node.name)">{{ text('检测', 'Test') }}</button>
            <button type="button" class="btn btn-secondary btn-sm" :disabled="pending || status.busy" @click="operate((node.state === 'enabled' ? 'disable/' : 'recover/') + node.name)">{{ node.state === 'enabled' ? text('停用', 'Disable') : text('恢复', 'Recover') }}</button>
          </div>
        </div>
      </details>
    </template>
  </div>
</template>

<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import { apiClient } from '@/api/client'

const { locale } = useI18n()
const text = (zh: string, en: string) => locale.value.startsWith('zh') ? zh : en
defineEmits<{ ready: [endpoint: string] }>()

interface Status {
  installed: boolean
  running: boolean
  busy: boolean
  supported: boolean
  phase: string
  error?: string
  nodes: number
  subscriptions: number
  endpoint: string
  node_states?: { name: string; state: string }[]
}

const status = ref<Status>()
const subscriptions = ref('')
const append = ref(false)
const pending = ref(false)
const error = ref('')
let timer: ReturnType<typeof setTimeout> | undefined
let disposed = false

async function refresh() {
  if (timer) clearTimeout(timer)
  try {
    status.value = (await apiClient.get<Status>('/admin/system/mihomo')).data
  } catch {
    error.value = text('无法读取内核状态', 'Cannot read kernel status')
  }
  if (!disposed && status.value?.busy) timer = setTimeout(refresh, 1500)
}

async function operate(action: string) {
  pending.value = true
  error.value = ''
  try {
    status.value = (await apiClient.post<Status>('/admin/system/mihomo', {
      action,
      subscriptions: subscriptions.value.split(/\r?\n/).filter(value => value.trim()),
      append: append.value
    })).data
    subscriptions.value = ''
    await refresh()
  } catch {
    error.value = text('操作未提交，请检查服务状态后重试', 'Operation was not accepted; check service status and retry')
  } finally {
    pending.value = false
  }
}

async function importFile(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (!file) return
  if (file.size > 256 * 1024) {
    error.value = text('文件不能超过 256 KiB', 'File must be at most 256 KiB')
    return
  }
  subscriptions.value = await file.text()
  input.value = ''
}

onMounted(refresh)
onUnmounted(() => {
  disposed = true
  if (timer) clearTimeout(timer)
})
</script>
