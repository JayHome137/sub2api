<template>
  <AppLayout>
    <div class="space-y-6">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div><h1 class="text-2xl font-semibold">{{ t('qualityOps.title') }}</h1><p class="mt-2 text-sm text-gray-500">{{ t('qualityOps.description') }}</p></div>
        <div class="flex gap-2"><button class="btn btn-secondary" :disabled="busy" @click="load">{{ t('qualityOps.refresh') }}</button><button class="btn btn-primary" @click="newPlan">{{ t('qualityOps.create') }}</button></div>
      </div>
      <p v-if="error" role="alert" class="rounded-lg bg-red-50 p-3 text-red-700 dark:bg-red-950">{{ error }}</p>
      <p v-if="notice" role="status" class="rounded-lg bg-green-50 p-3 text-green-700 dark:bg-green-950">{{ notice }}</p>
      <form v-if="showForm" class="card space-y-4 p-5" @submit.prevent="save">
        <h2 class="text-lg font-semibold">{{ editing ? t('qualityOps.edit') : t('qualityOps.create') }}</h2>
        <div v-if="!editing" class="space-y-2">
          <label for="quality-account-search" class="block text-sm">{{ t('qualityOps.accounts') }}</label>
          <div class="flex gap-2"><input id="quality-account-search" v-model="search" class="input" :placeholder="t('qualityOps.search')" @keydown.enter.prevent="searchAccounts(1)" /><button type="button" class="btn btn-secondary shrink-0 whitespace-nowrap" @click="searchAccounts(1)">{{ t('qualityOps.search') }}</button></div>
          <div class="grid max-h-44 gap-2 overflow-auto rounded border p-3 sm:grid-cols-2 dark:border-dark-600">
            <label v-for="account in accounts" :key="account.id" class="flex items-center gap-2 text-sm"><input v-model="selectedAccounts" type="checkbox" :value="account.id" :disabled="plans.some(p => p.account_id === account.id)" />{{ account.name }} <span class="text-gray-500">#{{ account.id }}</span></label>
          </div>
          <div class="flex items-center gap-3 text-sm"><button type="button" :disabled="accountPage <= 1" @click="searchAccounts(accountPage - 1)">←</button><span>{{ accountPage }} / {{ accountPages }}</span><button type="button" :disabled="accountPage >= accountPages" @click="searchAccounts(accountPage + 1)">→</button><span>{{ t('qualityOps.selected', { count: selectedAccounts.length }) }}</span></div>
        </div>
        <div class="grid gap-4 sm:grid-cols-2">
          <label class="space-y-1"><span>{{ t('qualityOps.model') }}</span><input v-model.trim="form.model_id" required maxlength="100" class="input" placeholder="gpt-5.4" /></label>
          <label class="space-y-1"><span>{{ t('qualityOps.cron') }}</span><input v-model.trim="form.cron_expression" required class="input" placeholder="*/30 * * * *" /></label>
          <label class="space-y-1"><span>{{ t('qualityOps.effort') }}</span><select v-model="form.pelican_config.reasoning_effort" class="input"><option v-for="effort in ['minimal', 'low', 'medium', 'high', 'xhigh']" :key="effort">{{ effort }}</option></select></label>
          <label class="space-y-1"><span>{{ t('qualityOps.parallel') }}</span><input v-model.number="form.pelican_config.parallel_count" type="number" min="1" max="8" required class="input" /></label>
        </div>
        <div><div class="mb-2 flex items-center justify-between"><label for="quality-prompt">{{ t('qualityOps.prompt') }}</label><button type="button" class="text-sm text-primary-600" @click="useCandy">{{ t('qualityOps.candy') }}</button></div><textarea id="quality-prompt" v-model="form.pelican_config.prompt" required maxlength="32000" rows="5" class="input font-mono text-sm" /></div>
        <label class="block space-y-1"><span>{{ t('qualityOps.answer') }}</span><input v-model="form.pelican_config.quality.expected_answer" required maxlength="4000" class="input" /></label>
        <fieldset class="space-y-3 rounded-lg border p-4 dark:border-dark-600">
          <legend class="px-2 font-medium">{{ t('qualityOps.judgeTitle') }}</legend>
          <div class="grid gap-4 sm:grid-cols-2">
            <label class="space-y-1"><span>{{ t('qualityOps.judgeGroup') }}</span>
              <select v-model.number="form.pelican_config.quality.judge.group_id" required class="input" @change="loadJudgeModels">
                <option disabled :value="0">{{ t('qualityOps.selectJudgeGroup') }}</option>
                <option v-for="group in groups.filter(g => g.status === 'active')" :key="group.id" :value="group.id">{{ group.name }} #{{ group.id }}</option>
              </select>
            </label>
            <label class="space-y-1"><span>{{ t('qualityOps.judgeModel') }}</span>
              <input v-model.trim="form.pelican_config.quality.judge.model_id" list="quality-judge-models" required maxlength="100" class="input" :placeholder="t('qualityOps.selectJudgeModel')" />
              <datalist id="quality-judge-models"><option v-for="model in judgeModels" :key="model" :value="model" /></datalist>
            </label>
          </div>
          <label class="block space-y-1"><span>{{ t('qualityOps.judgePrompt') }}</span><textarea v-model="form.pelican_config.quality.judge.prompt" required maxlength="16000" rows="3" class="input text-sm" /></label>
          <p class="text-sm text-gray-500">{{ t('qualityOps.grading') }}</p>
        </fieldset>
        <fieldset class="space-y-3 rounded-lg border p-4 dark:border-dark-600">
          <legend class="px-2 font-medium">{{ t('qualityOps.failureAction') }}</legend>
          <label class="flex items-center gap-2"><input v-model="form.pelican_config.quality.action" type="radio" value="remove_groups" />{{ t('qualityOps.removeGroups') }}</label>
          <div v-if="form.pelican_config.quality.action === 'remove_groups'" class="grid max-h-40 gap-2 overflow-auto pl-6 sm:grid-cols-2">
            <label v-for="group in groups" :key="group.id" class="flex items-center gap-2 text-sm"><input v-model="form.pelican_config.quality.remove_group_ids" type="checkbox" :value="group.id" />{{ group.name }} #{{ group.id }}</label>
          </div>
          <label class="flex items-center gap-2"><input v-model="form.pelican_config.quality.action" type="radio" value="disable_scheduling" />{{ t('qualityOps.disableScheduling') }}</label>
        </fieldset>
        <label class="flex items-center gap-2"><input v-model="form.pelican_config.quality.auto_restore" type="checkbox" />{{ t('qualityOps.autoRestore') }}</label>
        <p class="text-sm text-gray-500">{{ t('qualityOps.restoreHelp') }}</p>
        <label class="flex items-center gap-2"><input v-model="form.enabled" type="checkbox" />{{ t('qualityOps.enabled') }}</label>
        <div class="flex gap-2"><button class="btn btn-primary" :disabled="busy || (!editing && selectedAccounts.length === 0)">{{ t('qualityOps.save') }}</button><button type="button" class="btn btn-secondary" :disabled="busy" @click="showForm = false">{{ t('qualityOps.cancel') }}</button></div>
      </form>
      <div class="card overflow-x-auto">
        <table class="w-full text-left text-sm">
          <thead class="bg-gray-50 dark:bg-dark-800"><tr><th class="p-3">{{ t('qualityOps.accounts') }}</th><th class="p-3">{{ t('qualityOps.model') }}</th><th class="p-3">{{ t('qualityOps.failureAction') }}</th><th class="p-3">{{ t('qualityOps.schedule') }}</th><th class="p-3">{{ t('qualityOps.actions') }}</th></tr></thead>
          <tbody><tr v-for="plan in plans" :key="plan.id" class="border-t dark:border-dark-600">
            <td class="p-3">{{ accountNames[plan.account_id] || `#${plan.account_id}` }}<div class="text-xs text-gray-500">{{ t('qualityOps.rule') }} #{{ plan.id }}</div></td>
            <td class="p-3">{{ plan.model_id }}<div class="text-xs text-gray-500">{{ plan.cron_expression }}</div></td>
            <td class="p-3">{{ t(plan.pelican_config?.quality?.action === 'remove_groups' ? 'qualityOps.removeGroups' : 'qualityOps.disableScheduling') }}<div v-if="plan.pelican_config?.quality?.action === 'remove_groups'" class="text-xs text-gray-500">{{ plan.pelican_config.quality.remove_group_ids.map(id => groupNames[id] || `#${id}`).join('、') }}</div></td>
            <td class="p-3"><span :class="plan.enabled ? 'text-green-600' : 'text-gray-500'">{{ t(plan.enabled ? 'qualityOps.enabled' : 'qualityOps.paused') }}</span><div class="text-xs text-gray-500">{{ plan.enabled ? date(plan.next_run_at) : '—' }}</div><div v-if="!plan.pelican_config?.quality?.judge" class="mt-1 text-xs text-amber-600">{{ t('qualityOps.configureJudge') }}</div></td>
            <td class="p-3"><div class="flex flex-wrap gap-3"><button class="text-primary-600" :disabled="busy" @click="edit(plan)">{{ t('qualityOps.edit') }}</button><button :disabled="busy" @click="toggle(plan)">{{ t(plan.enabled ? 'qualityOps.pause' : 'qualityOps.enable') }}</button><button :disabled="busy || !plan.enabled" @click="run(plan)">{{ t('qualityOps.run') }}</button><button class="text-primary-600" :disabled="busy" @click="history(plan)">{{ t('qualityOps.history') }}</button><button class="text-red-600" :disabled="busy" @click="remove(plan)">{{ t('qualityOps.delete') }}</button></div></td>
          </tr><tr v-if="!plans.length"><td colspan="5" class="p-8 text-center text-gray-500">{{ t('qualityOps.empty') }}</td></tr></tbody>
        </table>
      </div>
      <section class="card overflow-hidden">
        <div class="flex flex-wrap items-center justify-between gap-2 p-5">
          <div><h2 class="text-lg font-semibold">{{ t('qualityOps.operations') }}</h2><p class="mt-1 text-sm text-gray-500">{{ t('qualityOps.operationsHelp') }}</p></div>
          <button class="btn btn-secondary" :disabled="busy" @click="refreshOperations">{{ t('qualityOps.refresh') }}</button>
        </div>
        <div class="overflow-x-auto">
          <table class="w-full text-left text-sm">
            <thead class="bg-gray-50 dark:bg-dark-800"><tr>
              <th class="px-4 py-3">{{ t('qualityOps.time') }}</th><th class="px-4 py-3">{{ t('qualityOps.accounts') }}</th>
              <th class="px-4 py-3">{{ t('qualityOps.operationStatus') }}</th><th class="px-4 py-3">{{ t('qualityOps.targetGroups') }}</th>
              <th class="px-4 py-3">{{ t('qualityOps.passCount') }}</th><th class="px-4 py-3">{{ t('qualityOps.actions') }}</th>
            </tr></thead>
            <tbody><tr v-for="operation in operations" :key="operation.id" class="border-t dark:border-dark-600">
              <td class="whitespace-nowrap px-4 py-3">{{ date(operation.started_at) }}</td>
              <td class="px-4 py-3">{{ operation.account_name }}<div class="text-xs text-gray-500">{{ t('qualityOps.rule') }} #{{ operation.plan_id }}</div></td>
              <td class="px-4 py-3"><span :class="operation.quality_action === 'restored' || operation.quality_action === 'passed' ? 'font-medium text-green-600' : 'text-amber-600'">{{ operation.quality_action === 'restored' && operation.pelican_config?.quality?.action === 'remove_groups' ? t('qualityOps.groupsRestored') : actionLabel(operation.quality_action) }}</span><div class="mt-1 text-xs text-gray-500">{{ date(operation.finished_at) }}</div></td>
              <td class="px-4 py-3">{{ operation.pelican_config?.quality?.action === 'remove_groups' ? operation.pelican_config.quality.remove_group_ids.map(id => groupNames[id] || `#${id}`).join('、') : t('qualityOps.disableScheduling') }}</td>
              <td class="whitespace-nowrap px-4 py-3">{{ operation.passed_count }} / {{ operation.total_count }}</td>
              <td class="px-4 py-3"><button class="text-primary-600" :disabled="busy" @click="operationDetails(operation)">{{ t('qualityOps.details') }}</button></td>
            </tr><tr v-if="!operations.length"><td colspan="6" class="p-8 text-center text-gray-500">{{ t('qualityOps.noResults') }}</td></tr></tbody>
          </table>
        </div>
        <div v-if="operationCursor" class="p-4 text-center"><button class="btn btn-secondary" :disabled="busy" @click="moreOperations">{{ t('qualityOps.loadMore') }}</button></div>
      </section>
      <section v-if="historyPlan" class="card space-y-3 p-5">
        <h2 class="font-semibold">{{ t('qualityOps.history') }} · #{{ historyPlan.id }}</h2>
        <p class="text-sm text-gray-500">{{ t('qualityOps.historyHelp') }}</p>
        <div v-for="result in results" :key="result.id" class="rounded border p-3 dark:border-dark-600">
          <div class="flex flex-wrap justify-between gap-2 text-sm"><span>{{ date(result.started_at) }}</span><span :class="result.status === 'success' ? 'text-green-600' : 'text-red-600'">{{ t(result.status === 'success' ? 'qualityOps.passed' : result.error_message === 'answer_mismatch' ? 'qualityOps.wrongAnswer' : result.quality_judgment?.verdict === 'unknown' || result.error_message.startsWith('judge_') ? 'qualityOps.judgeUnknown' : 'qualityOps.requestError') }}</span><span>{{ actionLabel(result.quality_action) }}</span></div>
          <p v-if="result.quality_judgment" class="mt-2 text-sm text-gray-500">{{ t('qualityOps.judgeReason') }}: {{ result.quality_judgment.reason }} <span class="text-xs">({{ result.quality_judgment.model_id || '—' }} · {{ groupNames[result.quality_judgment.group_id || 0] || result.quality_judgment.group_id || '—' }})</span></p>
          <pre class="mt-2 max-h-40 overflow-auto whitespace-pre-wrap break-all text-xs">{{ result.response_text || result.error_message }}</pre>
        </div>
        <p v-if="!results.length" class="text-gray-500">{{ t('qualityOps.noResults') }}</p>
      </section>
    </div>
  </AppLayout>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useI18n } from 'vue-i18n'
import AppLayout from '@/components/layout/AppLayout.vue'
import { listQualityPlans, runQualityPlan, listQualityOperations, type QualityOperation } from '@/api/admin/accountQuality'
import scheduledTests from '@/api/admin/scheduledTests'
import * as accountsAPI from '@/api/admin/accounts'
import * as groupsAPI from '@/api/admin/groups'
import { CANDY_PROMPT } from '@/utils/intelligenceTest'
import type { AccountListItem, AdminGroup, ScheduledTestPlan, ScheduledTestResult } from '@/types'

const { t, te } = useI18n()
const plans = ref<ScheduledTestPlan[]>([])
const operations = ref<QualityOperation[]>([]), operationCursor = ref(0)
const judgeModels = ref<string[]>([])
let judgeModelsRequest = 0
const accounts = ref<AccountListItem[]>([])
const groups = ref<AdminGroup[]>([])
const accountNames = ref<Record<number, string>>({})
const groupNames = computed(() => Object.fromEntries(groups.value.map(g => [g.id, g.name])))
const busy = ref(false), error = ref(''), notice = ref(''), showForm = ref(false)
const editing = ref<number | null>(null), selectedAccounts = ref<number[]>([])
const search = ref(''), accountPage = ref(1), accountPages = ref(1)
const historyPlan = ref<ScheduledTestPlan | null>(null), results = ref<ScheduledTestResult[]>([])
function defaults() {
  return { model_id: '', cron_expression: '*/30 * * * *', enabled: true, max_results: 100, auto_recover: false,
    pelican_config: { question_kind: 'candy' as const, prompt: CANDY_PROMPT, reasoning_effort: 'high', parallel_count: 1,
      quality: { expected_answer: '21', action: 'remove_groups' as 'remove_groups' | 'disable_scheduling', remove_group_ids: [] as number[], auto_restore: false, judge: { group_id: 0, model_id: '', prompt: t('qualityOps.defaultJudgePrompt') } } } }
}
const form = ref(defaults())
function message(e: unknown): string { const err = e as { response?: { data?: { message?: string; error?: string } }; message?: string }; return err.response?.data?.message || err.response?.data?.error || err.message || t('qualityOps.error') }
async function task(fn: () => Promise<void>) { if (busy.value) return; busy.value = true; error.value = ''; notice.value = ''; try { await fn() } catch (e) { error.value = message(e) } finally { busy.value = false } }
async function searchAccounts(page = 1) { try { const data = await accountsAPI.list(page, 50, { search: search.value, lite: 'true' }); accounts.value = data.items; accountPage.value = page; accountPages.value = Math.max(1, Math.ceil(data.total / 50)); for (const a of data.items) accountNames.value[a.id] = a.name } catch (e) { error.value = message(e) } }
async function load() { await task(async () => { [plans.value, groups.value] = await Promise.all([listQualityPlans(), groupsAPI.getAllIncludingInactive()]); await fetchOperations(); if (historyPlan.value) results.value = await scheduledTests.listResults(historyPlan.value.id, 100) }) }
function newPlan() { editing.value = null; form.value = defaults(); selectedAccounts.value = []; showForm.value = true; void searchAccounts() }
function edit(plan: ScheduledTestPlan) { editing.value = plan.id; form.value = { ...defaults(), model_id: plan.model_id, cron_expression: plan.cron_expression, enabled: plan.enabled, max_results: plan.max_results, pelican_config: { ...defaults().pelican_config, ...JSON.parse(JSON.stringify(plan.pelican_config)) } }; form.value.pelican_config.quality.judge ||= defaults().pelican_config.quality.judge; showForm.value = true; void loadJudgeModels() }
function useCandy() { form.value.pelican_config.prompt = CANDY_PROMPT; form.value.pelican_config.quality.expected_answer = '21' }
async function save() { await task(async () => {
  if (!form.value.pelican_config.quality.judge.group_id || !form.value.pelican_config.quality.judge.model_id.trim() || !form.value.pelican_config.quality.judge.prompt.trim()) throw new Error(t('qualityOps.configureJudge'))
  if (form.value.pelican_config.quality.action === 'remove_groups' && !form.value.pelican_config.quality.remove_group_ids.length) throw new Error(t('qualityOps.selectGroups'))
  if (editing.value) await scheduledTests.update(editing.value, form.value)
  else {
    // Remove successful IDs before retrying so a partial batch cannot duplicate rules.
    for (const id of [...selectedAccounts.value]) { await scheduledTests.create({ ...form.value, account_id: id }); selectedAccounts.value = selectedAccounts.value.filter(value => value !== id) }
  }
  plans.value = await listQualityPlans(); showForm.value = false; notice.value = t('qualityOps.saved')
}) }
async function toggle(plan: ScheduledTestPlan) { await task(async () => { await scheduledTests.update(plan.id, { enabled: !plan.enabled }); plans.value = await listQualityPlans() }) }
async function run(plan: ScheduledTestPlan) { await task(async () => { await runQualityPlan(plan.id); notice.value = t('qualityOps.queued'); plans.value = await listQualityPlans() }) }
async function history(plan: ScheduledTestPlan) { await task(async () => { results.value = await scheduledTests.listResults(plan.id, 100); historyPlan.value = plan }) }
async function remove(plan: ScheduledTestPlan) { if (!window.confirm(t('qualityOps.deleteConfirm'))) return; await task(async () => { await scheduledTests.delete(plan.id); plans.value = await listQualityPlans(); if (historyPlan.value?.id === plan.id) historyPlan.value = null }) }
async function loadJudgeModels() {
  const request = ++judgeModelsRequest
  const id = form.value.pelican_config.quality.judge.group_id
  judgeModels.value = []
  if (!id) return
  try { const models = await groupsAPI.getModelAllowlistCandidates(id); if (request === judgeModelsRequest) judgeModels.value = models } catch { if (request === judgeModelsRequest) error.value = t('qualityOps.judgeModelsUnavailable') }
}
async function fetchOperations(append = false) { const page = await listQualityOperations(append ? operationCursor.value : 0); operations.value = append ? [...operations.value, ...page.items] : page.items; operationCursor.value = page.next_cursor }
async function refreshOperations() { await task(() => fetchOperations()) }
async function moreOperations() { await task(() => fetchOperations(true)) }
async function operationDetails(operation: QualityOperation) { await task(async () => { results.value = await Promise.all(operation.result_ids.map(id => scheduledTests.getResult(operation.plan_id, id))); historyPlan.value = plans.value.find(p => p.id === operation.plan_id) || { id: operation.plan_id } as ScheduledTestPlan }) }
function date(value: string | null) { return value ? new Date(value).toLocaleString() : '—' }
function actionLabel(action?: string) { const key = `qualityOps.outcomes.${action}`; return action && te(key) ? t(key) : '—' }
onMounted(async () => { await load(); await searchAccounts() })
</script>
