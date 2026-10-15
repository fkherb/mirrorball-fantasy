// Used only until app_config is loaded, or if the configuration request fails.
let regularJudges = ['Carrie Ann', 'Derek', 'Bruno'];
let configRequest;
let loadedAt = 0;

export const regularJudgeNames = () => [...regularJudges];

export function configureRegularJudges(names) {
  if (!Array.isArray(names) || !names.length || names.some((name) => typeof name !== 'string' || !name.trim())) return false;
  const clean = names.map((name) => name.trim());
  if (new Set(clean.map((name) => name.toLowerCase())).size !== clean.length) return false;
  regularJudges = clean;
  return true;
}

export async function loadRegularJudges(db) {
  if (loadedAt && Date.now() - loadedAt < 60000) return regularJudgeNames();
  if (!configRequest) configRequest = (async () => {
    try {
      const { data, error } = await db.from('app_config').select('value').eq('key', 'regular_judges').single();
      if (error) throw error;
      if (!configureRegularJudges(data?.value)) throw new Error('Invalid regular_judges configuration');
      loadedAt = Date.now();
    } catch (error) {
      console.warn('Could not refresh regular judges:', error.message);
    }
    return regularJudgeNames();
  })().finally(() => { configRequest = null; });
  return configRequest;
}

export function judgeOrderFor(week = {}) {
  const guest = String(week.guest_judge_name || '').trim();
  const expected = [...regularJudges, ...(guest ? [guest] : [])];
  const saved = week.judge_order;
  return Array.isArray(saved) && saved.length === expected.length
    && new Set(saved).size === expected.length && expected.every((name) => saved.includes(name))
    ? [...saved] : expected;
}

export function sortJudgeScores(scores, week) {
  const order = judgeOrderFor(week);
  const rank = (name) => order.includes(name) ? order.indexOf(name) : order.length;
  return [...scores].sort((a, b) => rank(a.judge_name) - rank(b.judge_name)
    || String(a.judge_name).localeCompare(String(b.judge_name)));
}
