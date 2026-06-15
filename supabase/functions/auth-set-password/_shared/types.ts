/** Profile returned by saas_verify_login / saas_verify_session (JSONB) */
export interface SaasUserProfile {
  id: number;
  username: string;
  display_name: string;
  email: string;
  role: string;
  permissions: Record<string, unknown>;
  company_id: number | null;
  company_name: string | null;
  company_code: string | null;
  company_status: string | null;
  max_employees: number;
}

export function parseSaasUser(data: unknown): SaasUserProfile | null {
  if (data == null || typeof data !== 'object') return null;
  const o = data as Record<string, unknown>;
  const id = typeof o.id === 'number' ? o.id : parseInt(String(o.id ?? ''), 10);
  if (!Number.isFinite(id) || id < 1) return null;
  if (!o.username || typeof o.username !== 'string') return null;

  return {
    id,
    username: o.username,
    display_name: o.display_name != null ? String(o.display_name) : '',
    email: o.email != null ? String(o.email) : '',
    role: o.role != null ? String(o.role) : '',
    permissions:
      o.permissions && typeof o.permissions === 'object' && !Array.isArray(o.permissions)
        ? (o.permissions as Record<string, unknown>)
        : {},
    company_id:
      o.company_id == null
        ? null
        : typeof o.company_id === 'number'
          ? o.company_id
          : parseInt(String(o.company_id), 10) || null,
    company_name: o.company_name != null ? String(o.company_name) : null,
    company_code: o.company_code != null ? String(o.company_code) : null,
    company_status: o.company_status != null ? String(o.company_status) : null,
    max_employees: parseInt(String(o.max_employees ?? 0), 10) || 0,
  };
}
