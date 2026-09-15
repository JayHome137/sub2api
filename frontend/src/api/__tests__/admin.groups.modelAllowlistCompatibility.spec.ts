import { beforeEach, describe, expect, it, vi } from 'vitest'

const { get, post, put } = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn(),
  put: vi.fn(),
}))

vi.mock('@/api/client', () => ({
  apiClient: { get, post, put },
}))

import {
  create,
  getModelsListCandidates,
  list,
  update,
} from '@/api/admin/groups'

describe('admin group model allowlist compatibility', () => {
  beforeEach(() => {
    get.mockReset()
    post.mockReset()
    put.mockReset()
  })

  it('maps the official response field back to the unchanged AIFoo UI field', async () => {
    get.mockResolvedValue({
      data: {
        items: [
          {
            id: 1,
            model_allowlist: { enabled: true, models: ['gpt-5.5'] },
          },
        ],
        total: 1,
        page: 1,
        page_size: 20,
        pages: 1,
      },
    })

    const result = await list()

    expect(result.items[0].models_list_config).toEqual({
      enabled: true,
      models: ['gpt-5.5'],
    })
  })

  it('sends the official field while keeping the existing create payload shape', async () => {
    post.mockResolvedValue({
      data: {
        id: 2,
        model_allowlist: { enabled: true, models: ['claude-sonnet'] },
      },
    })

    const result = await create({
      name: 'compatibility',
      models_list_config: { enabled: true, models: ['claude-sonnet'] },
    } as never)

    expect(post).toHaveBeenCalledWith('/admin/groups', {
      name: 'compatibility',
      model_allowlist: { enabled: true, models: ['claude-sonnet'] },
    })
    expect(result.models_list_config).toEqual({
      enabled: true,
      models: ['claude-sonnet'],
    })
  })

  it('sends the official field for updates and uses the renamed candidate endpoint', async () => {
    put.mockResolvedValue({ data: { id: 3, model_allowlist: { enabled: false, models: [] } } })
    get.mockResolvedValue({ data: { models: ['gpt-5.5'] } })

    await update(3, { models_list_config: { enabled: false, models: [] } })
    await getModelsListCandidates(3, 'openai')

    expect(put).toHaveBeenCalledWith('/admin/groups/3', {
      model_allowlist: { enabled: false, models: [] },
    })
    expect(get).toHaveBeenCalledWith('/admin/groups/3/model-allowlist-candidates', {
      params: { platform: 'openai' },
    })
  })
})
