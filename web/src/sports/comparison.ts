// SportsStatComparison: values are parsed only for the comparison bars; the
// provider's strings stay the visible truth, including zero and missing data.

export interface StatComparison {
  left: number;
  right: number;
  leftShare: number;
}

function leadingNumber(value: string | undefined): number | undefined {
  if (value === undefined) return undefined;
  const m = /^\s*([0-9]+(?:\.[0-9]+)?)/.exec(value);
  if (!m) return undefined;
  const n = Number(m[1]);
  return Number.isFinite(n) ? n : undefined;
}

export function statComparison(row: string[]): StatComparison | undefined {
  const left = leadingNumber(row[1]);
  const right = leadingNumber(row[2]);
  if (left === undefined || right === undefined) return undefined;
  return { left, right, leftShare: left + right === 0 ? 0.5 : left / (left + right) };
}
