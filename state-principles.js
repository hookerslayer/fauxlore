export const PRINCIPLES = {
  authority: ['Династия', 'Магистрат', 'Клир', 'Диктат', 'Вече'],
  structure: ['Ленное право', 'Деспотизм', 'Консорциум', 'Содружество', 'Командорство'],
  economy: ['Крепостничество', 'Гильдии', 'Адмиралтейство', 'Корсарство', 'Работорговля'],
  military: ['Сословная армия', 'Кондотьеры', 'Фирд', 'Гвардия', 'Тумены'],
  ephemeral: ['Мораторий', 'Придворные чародеи', 'Герметизм', 'Святые Таинства', 'Артефакторика'],
};

const BASES = {
  'Династия': ['Феодальная монархия', 'Деспотия', 'Патримониалия', 'Уния', 'Марка'],
  'Магистрат': ['Республика', 'Олигархия', 'Директория', 'Вольный союз', 'Подеста'],
  'Клир': ['Княжество-епископство', 'Теократия', 'Аббатская синьория', 'Конгрегация', 'Орден'],
  'Диктат': ['Синьория', 'Тирания', 'Компания', 'Протекторат', 'Стратократия'],
  'Вече': ['Боярская республика', 'Революционная диктатура', 'Коммуна', 'Кантональный союз', 'Вольница'],
};
const ECONOMY_ADJECTIVES = {
  'Крепостничество': ['Аграрная', 'Поместная'],
  'Гильдии': ['Торговая', 'Ганзейская'],
  'Адмиралтейство': ['Морская', 'Флотская'],
  'Корсарство': ['Пиратская', 'Каперская'],
  'Работорговля': ['Работорговая', 'Рабовладельческая'],
};
const MILITARY_ADJECTIVES = {
  'Сословная армия': ['Шляхетская', 'Рыцарская'],
  'Кондотьеры': ['Вольная', 'Кондотьерская'],
  'Фирд': ['Гражданская', 'Земская'],
  'Гвардия': ['Патрицианская', 'Гвардейская'],
  'Тумены': ['Степная', 'Ордынская'],
};

export function principleConflict({ authority, structure, economy, military }) {
  if (military === 'Тумены' && (
    ['Гильдии', 'Адмиралтейство', 'Корсарство'].includes(economy) ||
    ['Консорциум', 'Командорство'].includes(structure)
  )) return 'Тумены несовместимы с выбранным укладом или структурой владения.';
  if (military === 'Фирд' && ['Династия', 'Диктат'].includes(authority))
    return 'Фирд несовместим с Династией и Диктатом.';
  if (authority === 'Клир' && economy === 'Корсарство')
    return 'Клир несовместим с Корсарством.';
  if (authority === 'Вече' && structure === 'Деспотизм' && economy === 'Крепостничество')
    return 'Сочетание Вече, Деспотизм и Крепостничество несовместимо.';
  return '';
}

function agree(adjective, gender) {
  if (gender === 'f') return adjective;
  if (adjective.endsWith('ская')) return adjective.slice(0, -4) + (gender === 'm' ? 'ский' : 'ское');
  if (adjective.endsWith('ая')) return adjective.slice(0, -2) + (gender === 'm' ? 'ый' : 'ое');
  return adjective;
}

export function governmentName(selection) {
  if (Object.keys(PRINCIPLES).some(key => !PRINCIPLES[key].includes(selection[key])) || principleConflict(selection)) return '';
  const base = BASES[selection.authority][PRINCIPLES.structure.indexOf(selection.structure)];
  const gender = base === 'Княжество-епископство' ? 'n' :
    ['Вольный союз', 'Подеста', 'Орден', 'Протекторат', 'Кантональный союз'].includes(base) ? 'm' : 'f';
  const style = ['Магистрат', 'Вече'].includes(selection.authority) ? 0 : 1;
  return [agree(MILITARY_ADJECTIVES[selection.military][style], gender),
    agree(ECONOMY_ADJECTIVES[selection.economy][style], gender).toLowerCase(), base.toLowerCase()].join(' ');
}
