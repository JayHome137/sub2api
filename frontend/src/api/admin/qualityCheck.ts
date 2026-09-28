/**
 * Admin group quality check (降智检测) API endpoints.
 * Per-group degradation detection config and aggregated status.
 */

import { apiClient } from '../client'

export interface GroupQualityCheckStatus {
  group_id: number
  enabled: boolean
  status: 'unknown' | 'healthy' | 'suspect'
  checked_accounts: number
  degraded_accounts: number
  last_run_at: string | null
}

export interface GroupQualityCheckSettings {
  group_id: number
  enabled: boolean
  interval_minutes: number
  last_run_at: string | null
  created_at: string
  updated_at: string
}

export async function listQualityChecks(): Promise<Record<string, GroupQualityCheckStatus>> {
  const { data } = await apiClient.get<Record<string, GroupQualityCheckStatus>>('/admin/quality-check/groups')
  return data
}

export async function setGroupQualityCheck(groupId: number, enabled: boolean): Promise<GroupQualityCheckSettings> {
  const { data } = await apiClient.put<GroupQualityCheckSettings>(
    `/admin/quality-check/groups/${groupId}`,
    { enabled },
  )
  return data
}

export const qualityCheckAPI = {
  list: listQualityChecks,
  setEnabled: setGroupQualityCheck,
}

export default qualityCheckAPI
