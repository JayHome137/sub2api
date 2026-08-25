import { beforeEach, describe, expect, it, vi } from 'vitest'

const { get, post } = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn(),
}))

vi.mock('../client', () => ({
  apiClient: {
    get,
    post,
  },
}))

import {
  getRollbackVersions,
  performUpdate,
  restartService,
  rollback,
  type RollbackVersionInfo
} from '@/api/admin/system'

describe('admin system rollback API', () => {
  beforeEach(() => {
    get.mockReset()
    post.mockReset()
  })

  it('getRollbackVersions fetches the rollback version list', async () => {
    const versions: RollbackVersionInfo[] = [
      {
        version: '0.1.146',
        published_at: '2026-07-07T00:00:00Z',
        html_url: 'https://github.com/Wei-Shaw/sub2api/releases/tag/v0.1.146'
      }
    ]
    get.mockResolvedValue({ data: { versions } })

    const result = await getRollbackVersions()

    expect(get).toHaveBeenCalledWith('/admin/system/rollback-versions')
    expect(result.versions).toEqual(versions)
  })

  it('rollback posts the target version in the request body', async () => {
    post.mockResolvedValue({ data: { message: 'ok', need_restart: true } })

    const result = await rollback('0.1.146')
    expect(post).toHaveBeenCalledWith(
      '/aifoo-upgrade/rollback',
      { version: '0.1.146' },
      { timeout: 900000 },
    )
    expect(result.need_restart).toBe(true)
  })

  it('prepares an official update through the local bridge', async () => {
    post.mockResolvedValue({ data: { message: 'ready', need_restart: true } })

    await performUpdate()
    expect(post).toHaveBeenCalledWith('/aifoo-upgrade/update', undefined, {
      timeout: 900000
    })
  })

  it('activates the prepared image through the local bridge', async () => {
    post.mockResolvedValue({ data: { message: 'active' } })

    await restartService()
    expect(post).toHaveBeenCalledWith('/aifoo-upgrade/restart', undefined, {
      timeout: 900000
    })
  })
})
