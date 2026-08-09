import { flushPromises, mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import VersionBadge from '../VersionBadge.vue'

const { appStore, authStore, systemMutations, upgradeMutations } = vi.hoisted(() => ({
  appStore: {
    versionLoading: false,
    currentVersion: '0.1.169',
    latestVersion: '0.1.169',
    hasUpdate: false,
    releaseInfo: null as { html_url?: string } | null,
    fetchVersion: vi.fn(),
    showInfo: vi.fn(),
    showError: vi.fn(),
  },
  authStore: {
    isAdmin: false,
  },
  systemMutations: {
    performUpdate: vi.fn(),
    restartService: vi.fn(),
    getRollbackVersions: vi.fn(),
    rollback: vi.fn(),
  },
  upgradeMutations: {
    getAIFooUpgradeStatus: vi.fn(),
    dispatchAIFooUpgrade: vi.fn(),
  },
}))

vi.mock('@/stores', () => ({
  useAppStore: () => appStore,
  useAuthStore: () => authStore,
}))

vi.mock('@/api/admin/system', () => systemMutations)
vi.mock('@/api/admin/upgrade', () => upgradeMutations)

vi.mock('vue-i18n', async (importOriginal) => ({
  ...(await importOriginal<typeof import('vue-i18n')>()),
  useI18n: () => ({ t: (key: string) => key }),
}))

function mountBadge() {
  return mount(VersionBadge, {
    props: { version: '0.1.169' },
    global: {
      stubs: {
        Icon: { template: '<span data-testid="icon" />' },
      },
    },
  })
}

describe('VersionBadge AIFoo upgrade status', () => {
  beforeEach(() => {
    authStore.isAdmin = false
    appStore.versionLoading = false
    appStore.currentVersion = '0.1.169'
    appStore.latestVersion = '0.1.169'
    appStore.hasUpdate = false
    appStore.releaseInfo = null
    appStore.fetchVersion.mockReset()
    appStore.fetchVersion.mockResolvedValue({
      current_version: '0.1.169',
      latest_version: '0.1.169',
      has_update: false,
    })
    appStore.showInfo.mockReset()
    appStore.showError.mockReset()
    upgradeMutations.getAIFooUpgradeStatus.mockReset()
    upgradeMutations.getAIFooUpgradeStatus.mockResolvedValue({
      release_tag: 'v0.1.170',
      state: 'preparing',
      can_dispatch: false,
      backend_required: false,
    })
    upgradeMutations.dispatchAIFooUpgrade.mockReset()
    Object.values(systemMutations).forEach((mock) => mock.mockReset())
  })

  it('keeps the private upgrade entry hidden from non-admin users', async () => {
    const wrapper = mountBadge()
    await flushPromises()

    expect(wrapper.text()).toContain('v0.1.169')
    expect(wrapper.find('[data-testid="version-badge"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="github-upgrade-status-link"]').exists()).toBe(false)
    expect(appStore.fetchVersion).not.toHaveBeenCalled()
  })

  it('keeps private workflow details out of the admin panel', async () => {
    authStore.isAdmin = true
    const wrapper = mountBadge()
    await flushPromises()
    await wrapper.get('[data-testid="version-badge"]').trigger('click')

    expect(wrapper.find('[data-testid="github-upgrade-status-link"]').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('version.viewGithubStatus')
    expect(wrapper.text()).not.toContain('version.viewDeploymentRun')
    expect(wrapper.text()).toContain('version.currentVersion')
    expect(wrapper.text()).toContain('version.upToDate')
    expect(wrapper.find('[data-testid="dispatch-aifoo-upgrade"]').exists()).toBe(false)
    expect(appStore.fetchVersion).toHaveBeenCalledWith(false)
  })

  it('shows a clean preparation state without exposing backend implementation details', async () => {
    authStore.isAdmin = true
    appStore.hasUpdate = true
    appStore.latestVersion = '0.1.170'
    appStore.releaseInfo = {
      html_url: 'https://github.com/Wei-Shaw/sub2api/releases/tag/v0.1.170',
    }
    appStore.fetchVersion.mockResolvedValue({
      current_version: '0.1.169',
      latest_version: '0.1.170',
      has_update: true,
    })

    const wrapper = mountBadge()
    await flushPromises()
    await wrapper.get('[data-testid="version-badge"]').trigger('click')

    expect(wrapper.find('[data-testid="upgrade-status-preparing"]').exists()).toBe(true)
    expect(upgradeMutations.getAIFooUpgradeStatus).toHaveBeenCalledWith('v0.1.170')
    expect(wrapper.text()).not.toContain('version.updateNow')
    expect(wrapper.text()).not.toContain('version.rollback')
    expect(wrapper.text()).not.toContain('version.restartNow')
  })

  it('dispatches a ready release through the bridge and never calls official update APIs', async () => {
    authStore.isAdmin = true
    appStore.hasUpdate = true
    appStore.latestVersion = '0.1.170'
    appStore.fetchVersion.mockResolvedValue({
      current_version: '0.1.169',
      latest_version: '0.1.170',
      has_update: true,
    })
    upgradeMutations.getAIFooUpgradeStatus.mockResolvedValue({
      release_tag: 'v0.1.170',
      state: 'ready',
      can_dispatch: true,
      backend_required: true,
      issue_url: 'https://github.com/JayHome137/sub2api/issues/17',
      run_url: 'https://github.com/JayHome137/sub2api/actions/runs/123',
    })
    upgradeMutations.dispatchAIFooUpgrade.mockResolvedValue({
      release_tag: 'v0.1.170',
      state: 'deploying',
      can_dispatch: false,
      backend_required: true,
    })

    const wrapper = mountBadge()
    await flushPromises()
    await wrapper.get('[data-testid="version-badge"]').trigger('click')
    await wrapper.get('[data-testid="dispatch-aifoo-upgrade"]').trigger('click')
    await flushPromises()

    expect(upgradeMutations.dispatchAIFooUpgrade).toHaveBeenCalledWith('v0.1.170')
    expect(wrapper.find('[data-testid="upgrade-status-deploying"]').exists()).toBe(true)
    expect(wrapper.html()).not.toContain('github.com/JayHome137/sub2api')
    expect(appStore.showInfo).toHaveBeenCalledWith('version.deploymentStarted')
    expect(systemMutations.performUpdate).not.toHaveBeenCalled()
    expect(systemMutations.restartService).not.toHaveBeenCalled()
    expect(systemMutations.rollback).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('keeps UI-related releases blocked from web dispatch', async () => {
    authStore.isAdmin = true
    appStore.hasUpdate = true
    appStore.latestVersion = '0.1.170'
    appStore.fetchVersion.mockResolvedValue({
      current_version: '0.1.169',
      latest_version: '0.1.170',
      has_update: true,
    })
    upgradeMutations.getAIFooUpgradeStatus.mockResolvedValue({
      release_tag: 'v0.1.170',
      state: 'ui_review_required',
      can_dispatch: false,
      backend_required: false,
    })

    const wrapper = mountBadge()
    await flushPromises()
    await wrapper.get('[data-testid="version-badge"]').trigger('click')

    expect(wrapper.find('[data-testid="upgrade-status-ui_review_required"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="dispatch-aifoo-upgrade"]').exists()).toBe(false)
  })

  it('keeps showing an in-progress web update after the backend reaches the latest version', async () => {
    authStore.isAdmin = true
    appStore.currentVersion = '0.1.170'
    appStore.latestVersion = '0.1.170'
    appStore.hasUpdate = false
    appStore.fetchVersion.mockResolvedValue({
      current_version: '0.1.170',
      latest_version: '0.1.170',
      has_update: false,
    })
    upgradeMutations.getAIFooUpgradeStatus.mockResolvedValue({
      release_tag: 'v0.1.170',
      state: 'deploying',
      can_dispatch: false,
      backend_required: false,
    })

    const wrapper = mountBadge()
    await flushPromises()
    await wrapper.get('[data-testid="version-badge"]').trigger('click')

    expect(upgradeMutations.getAIFooUpgradeStatus).toHaveBeenCalledWith('v0.1.170')
    expect(wrapper.find('[data-testid="upgrade-status-deploying"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('does not report up-to-date when the release check is unavailable', async () => {
    authStore.isAdmin = true
    appStore.fetchVersion.mockResolvedValue(null)

    const wrapper = mountBadge()
    await flushPromises()
    await wrapper.get('[data-testid="version-badge"]').trigger('click')

    expect(wrapper.find('[data-testid="upgrade-status-unavailable"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="upgrade-status-watching"]').exists()).toBe(false)
  })

  it('refreshes only the read-only release check and never calls system mutations', async () => {
    authStore.isAdmin = true
    const wrapper = mountBadge()
    await flushPromises()
    await wrapper.get('[data-testid="version-badge"]').trigger('click')
    await wrapper.get('[title="version.refresh"]').trigger('click')
    await flushPromises()

    expect(appStore.fetchVersion).toHaveBeenLastCalledWith(true)
    expect(systemMutations.performUpdate).not.toHaveBeenCalled()
    expect(systemMutations.restartService).not.toHaveBeenCalled()
    expect(systemMutations.getRollbackVersions).not.toHaveBeenCalled()
    expect(systemMutations.rollback).not.toHaveBeenCalled()
  })
})
