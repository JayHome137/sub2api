import { beforeEach, describe, expect, it, vi } from 'vitest'

const { get, post } = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn()
}))

vi.mock('../client', () => ({
  apiClient: { get, post }
}))

import { dispatchAIFooUpgrade, getAIFooUpgradeStatus } from '@/api/admin/upgrade'

describe('AIFoo upgrade bridge API', () => {
  beforeEach(() => {
    get.mockReset()
    post.mockReset()
  })

  it('queries the exact official release status', async () => {
    get.mockResolvedValue({
      data: {
        release_tag: 'v0.1.172',
        state: 'ready',
        can_dispatch: true,
        backend_required: true
      }
    })

    const result = await getAIFooUpgradeStatus('v0.1.172')

    expect(get).toHaveBeenCalledWith('/aifoo-upgrade/status', {
      params: { release: 'v0.1.172' }
    })
    expect(result.can_dispatch).toBe(true)
  })

  it('dispatches only the selected release tag', async () => {
    post.mockResolvedValue({
      data: {
        release_tag: 'v0.1.172',
        state: 'deploying',
        can_dispatch: false,
        backend_required: false
      }
    })

    const result = await dispatchAIFooUpgrade('v0.1.172')

    expect(post).toHaveBeenCalledWith('/aifoo-upgrade/dispatch', {
      release_tag: 'v0.1.172'
    })
    expect(result.state).toBe('deploying')
  })
})
