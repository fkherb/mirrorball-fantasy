const regularJudges = ['Carrie Ann', 'Derek', 'Bruno'];

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
