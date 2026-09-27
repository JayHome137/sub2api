import { apiClient } from '../client'
import type { ChannelQualityConfig, ChannelQualityListResponse, ChannelQualityResult } from '../channelQuality'

export async function getConfig(): Promise<ChannelQualityConfig> {
  const { data } = await apiClient.get<ChannelQualityConfig>('/admin/channel-quality/config')
  return data
}

export async function updateConfig(config: ChannelQualityConfig): Promise<ChannelQualityConfig> {
  const { data } = await apiClient.put<ChannelQualityConfig>('/admin/channel-quality/config', config)
  return data
}

export async function list(): Promise<ChannelQualityListResponse> {
  const { data } = await apiClient.get<ChannelQualityListResponse>('/admin/channel-quality')
  return data
}

export async function runNow(): Promise<{ started: boolean }> {
  const { data } = await apiClient.post<{ started: boolean }>('/admin/channel-quality/run')
  return data
}

export async function history(groupId: number, limit = 60): Promise<{ items: ChannelQualityResult[] }> {
  const { data } = await apiClient.get<{ items: ChannelQualityResult[] }>(`/admin/channel-quality/${groupId}/history`, { params: { limit } })
  return data
}

export default { getConfig, updateConfig, list, runNow, history }
