import { apiClient } from './client'

export type ChannelQualityStatus = 'healthy' | 'degraded' | 'unknown' | 'running'

export interface ChannelQualityResult {
  id: number
  group_id: number
  channel_id?: number | null
  group_name: string
  channel_name: string
  platform: string
  model: string
  status: ChannelQualityStatus
  message: string
  latency_ms?: number | null
  checked_at: string
}

export interface ChannelQualityView {
  group_id: number
  channel_id?: number | null
  group_name: string
  channel_name: string
  platform: string
  model: string
  status: ChannelQualityStatus
  message: string
  latency_ms?: number | null
  checked_at?: string | null
  timeline: ChannelQualityResult[]
}

export interface ChannelQualityListResponse {
  items: ChannelQualityView[]
}

export interface ChannelQualityConfig {
  enabled: boolean
  interval_seconds: number
  model: string
  prompt: string
  expected_answer: string
  history_limit: number
  last_run_at?: string | null
  updated_at?: string
}

export async function list(): Promise<ChannelQualityListResponse> {
  const { data } = await apiClient.get<ChannelQualityListResponse>('/channel-quality')
  return data
}

export async function history(groupId: number, limit = 60): Promise<{ items: ChannelQualityResult[] }> {
  const { data } = await apiClient.get<{ items: ChannelQualityResult[] }>(`/channel-quality/${groupId}/history`, { params: { limit } })
  return data
}

export const channelQualityUserAPI = { list, history }

export default channelQualityUserAPI
