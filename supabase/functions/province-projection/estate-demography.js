// The four-estate model shared by previews and turn calculations.
export const ESTATE_POPULATION_SHARES = Object.freeze({
  'Регион': Object.freeze({Крестьяне: .92, Горожане: .05, Духовенство: .02, Знать: .01}),
  'Городская': Object.freeze({Крестьяне: .65, Горожане: .30, Духовенство: .03, Знать: .02}),
  'Столичная': Object.freeze({Крестьяне: .55, Горожане: .38, Духовенство: .04, Знать: .03}),
});

export const BASE_ESTATE_TAX_RATES = Object.freeze({
  Знать: 10, Духовенство: 1, Горожане: 3, Крестьяне: 1,
});

export function estatePopulation(provinceType, population) {
  const shares = ESTATE_POPULATION_SHARES[provinceType];
  if (!shares || !Number.isSafeInteger(population) || population < 0) return null;
  const result = {
    Знать: Math.floor(population * shares.Знать),
    Духовенство: Math.floor(population * shares.Духовенство),
    Горожане: Math.floor(population * shares.Горожане),
  };
  result.Крестьяне = population - result.Знать - result.Духовенство - result.Горожане;
  return result;
}

export function developmentMultiplier(development) {
  const value = Number(development);
  return Number.isFinite(value) ? Math.max(0, value) / 100 : null;
}

export const PROVINCE_TAX_EFFICIENCY_BASE = .5;
export const PROVINCE_TAX_EFFICIENCY_ADJUSTMENTS = Object.freeze({
  'Столичная': .2,
  'Городская': .1,
  'Регион': -.2,
});

export function provinceTaxEfficiency(provinceType) {
  const adjustment = PROVINCE_TAX_EFFICIENCY_ADJUSTMENTS[provinceType];
  return adjustment === undefined ? null : Math.max(0, Math.min(1, PROVINCE_TAX_EFFICIENCY_BASE + adjustment));
}

// Gross tax before corruption, crime and distribution between treasuries.
export function estateGrossTax(provinceType, population, rates, modifiers = {}) {
  const people = estatePopulation(provinceType, population);
  const development = developmentMultiplier(modifiers.development ?? 100);
  const developmentTax = development === null ? null : Math.min(1, development);
  const efficiency = provinceTaxEfficiency(provinceType);
  const control = Number(modifiers.control ?? 100);
  const share = Number(modifiers.share ?? 1);
  if (!people || developmentTax === null || efficiency === null ||
      !Number.isFinite(control) || control < 0 || control > 100 ||
      !Number.isFinite(share) || share < 0 || share > 1) return null;
  let base = 0;
  for (const [estate, count] of Object.entries(people)) {
    const rate = Number(rates?.[estate]);
    if (!Number.isFinite(rate) || rate < 0) return null;
    base += count * rate;
  }
  return Math.floor(base * developmentTax * share * efficiency * control / 100);
}
