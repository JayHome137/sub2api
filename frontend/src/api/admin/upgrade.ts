import { apiClient } from '../client'

export type AIFooUpgradeState =
  | 'preparing'
  | 'ui_review_required'
  | 'failed'
  | 'ready'
  | 'deploying'
  | 'deployed'

export interface AIFooUpgradeStatus {
  release_tag: string
  state: AIFooUpgradeState
  can_dispatch: boolean
  backend_required: boolean
  issue_url?: string
  run_url?: string
}

export async function getAIFooUpgradeStatus(releaseTag: string): Promise<AIFooUpgradeStatus> {
  const { data } = await apiClient.get<AIFooUpgradeStatus>('/aifoo-upgrade/status', {
    params: { release: releaseTag }
  })
  return data
}

export async function dispatchAIFooUpgrade(releaseTag: string): Promise<AIFooUpgradeStatus> {
  const { data } = await apiClient.post<AIFooUpgradeStatus>('/aifoo-upgrade/dispatch', {
    release_tag: releaseTag
  })
  return data
}
