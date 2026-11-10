// Isolated migration prototype. Not enabled on the public site.
import {createVpsClient} from './vps-client.js';

const enabled = new Set(['fauxlore_api', 'map_revision_api', 'wall_api', 'state_journal_api', 'local_events_api', 'player_contacts_api', 'neutral_forces_api', 'admin_rollback_api',
  'government_form_preview_api', 'military_api', 'colonization_api', 'conquest_api', 'turn_limits_api', 'turn_report_api', 'militia_api', 'garrison_api',
  'estate_investment_api', 'estate_social_api', 'estate_fiscal_api', 'military_map_api', 'military_order_api', 'military_split_api',
  'military_transport_api', 'state_development_growth_api', 'admin_resources_api', 'admin_global_modifiers_api', 'admin_mercenaries_api',
  'admin_colonization_modifiers_api', 'judge_assignments_api', 'judge_state_statistics_api', 'instant_modifier_api',
  'admin_modifiers_api', 'wall_verdict_many']);

export function createPostgrestClient(fetchImpl = globalThis.fetch) {
  const existing = createVpsClient(fetchImpl);
  async function rpc(name, args = {}) {
    if (!enabled.has(name)) return {data: null, error: {message: 'Функция ещё не проверена'}, status: 501};
    try {
      const response = await fetchImpl(`/api/rpc/${name}`, {
        method: 'POST', credentials: 'same-origin', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(args),
      });
      const data = await response.json();
      if (!response.ok) return {data: null, error: {message: data?.message || 'Не удалось выполнить запрос', code: data?.code}, status: response.status};
      return {data, error: null, status: response.status};
    } catch {
      return {data: null, error: {message: 'Не удалось подключиться к серверу'}, status: 0};
    }
  }
  return {...existing, rpc};
}
