const dayjs = require('dayjs');
const { fetch } = require('../utils.js');
const ora = require('ora');

/**
 * Fetches and merges data from the AnimeAggregations and anibridge-mappings.
 */

const anibridgeMappingsUrl = 'https://github.com/anibridge/anibridge-mappings/releases/download/v3/mappings.min.json';
const animeToTitleUrl = 'https://raw.githubusercontent.com/notseteve/AnimeAggregations/main/aggregate/AnimeToTitle.json';
const animeToExternalUrl = 'https://raw.githubusercontent.com/notseteve/AnimeAggregations/main/aggregate/AnimeToExternal.json';
const animeUrl = 'https://raw.githubusercontent.com/notseteve/AnimeAggregations/main/anime/';

function toNumber(v) {
  return v && /^\d+$/.test(v) ? v : undefined;
}

function buildOutput(item, site) {
  let siteId = undefined;
  if (site === 'mal') {
    if (item.myanimelistid) {
      siteId = item.myanimelistid;
    }
  } else if (site === 'aniList') {
    if (item.aniListid) {
      siteId = item.aniListid;
    }
  } else if (site === 'anidb') {
    if (item.anidbid) {
      siteId = item.anidbid;
    }
  } else if (site === 'tmdb') {
    if (item.tmdbmovie) {
      siteId = `movie/${item.tmdbmovie}`;
    } else if (item.tmdbtv) {
      siteId = `tv/${item.tmdbtv}`;
      if (item.tmdbseason && String(item.tmdbseason) !== '1') {
        siteId = `tv/${item.tmdbtv}/season/${item.tmdbseason}`;
      }
    }
  }

  if (siteId) {
    return {
      ...item,
      id: siteId,
    };
  }
  return null;
}

/**
 *
 * @param {string} site
 * @returns {string} id - id of input param site
 * @returns {string} title - title in Japanese
 * @returns {array} titleTranslate - title in Chinese or English
 * @returns {string} year
 * @returns {string} season - SPRING / SUMMER / FALL / WINTER / UNDEFINED
 * @returns {string} all ID of different sites
 */
exports.getAll = async function getAll(site) {
  const spinner = ora('Downloading data - AnimeAggregations').start();
  const animeToTitle = await fetch(animeToTitleUrl).then((res) => res.json());
  const animeToExternal = await fetch(animeToExternalUrl).then((res) => res.json());
  spinner.text = 'Downloading data - anibridge-mappings';
  const anibridgeMappings = await fetch(anibridgeMappingsUrl).then((res) => res.json());

  spinner.text = 'Merging data';
  const items = [];
  for (const [animeId, metadata] of Object.entries(animeToExternal.animes)) {
    const malArray = metadata.resources.MAL;
    if (!malArray) {
      continue;
    }
    let anime = {
      animeId,
      myanimelistid: malArray[0],
    };

    // get title
    const titleJp = { OFFICIAL: undefined, SYNONYM: [] };
    const titleTranslate = {};
    animeToTitle.animes[animeId].filter((title) => title.language === 'ENGLISH' || title.language === 'JAPANESE' || (title.language.startsWith('CHINESE') && title.language.includes('TRANSLITERATED')))
      .forEach((title) => {
        if (title.language === 'JAPANESE') {
          if (title.type === 'OFFICIAL') {
            titleJp.OFFICIAL = title.title;
          } else {
            titleJp.SYNONYM.push(title.title);
          }
        } else {
          const lang = (title.language === 'ENGLISH') ? 'en' : title.language.startsWith('CHINESE_T') ? 'zh-Hant' : 'zh-Hans';
          let titles = titleTranslate[lang] ?? [];
          titles.push(title.title);
          titleTranslate[lang] = titles;
        }
      });
    anime.title = titleJp.OFFICIAL ? titleJp.OFFICIAL : titleJp.SYNONYM[0];
    if (titleJp.SYNONYM.length > 0) {
      titleTranslate['jp'] = titleJp.SYNONYM;
    }
    anime.titleTranslate = titleTranslate;
    anime.titleSynonym = titleJp.SYNONYM;

    // get ids
    const mapping = anibridgeMappings[`mal:${anime.myanimelistid}`];
    if (mapping) {
      for (const [key, value] of Object.entries(mapping)) {
        const keys = key.split(':');
        if (keys[0] === 'anilist') {
          anime.aniListid = keys[1];
        } else if (keys[0] === 'anidb') {
          anime.anidbid = keys[1];
        } else if (keys[0] === 'tmdb_movie') {
          anime.tmdbmovie = keys[1];
        } else if (keys[0] === 'tmdb_show') {
          anime.tmdbtv = keys[1];
          anime.tmdbseason = keys[2].substring(1); // remove 's' prefix
        }
      }
    }

    anime = buildOutput(anime, site);
    if (anime) {
      items.push(anime);
    }
  }
  spinner.stop();

  return items;
};

exports.matchBegin = async function matchBegin (bangumiBeginDate, item) {
  if (item.animeId) {
    const json = await fetch(animeUrl + item.animeId + '.json').then((res) => res.json());
    const jsonStartDate = dayjs(json.start_date, "YYYY-MM-DD");
    let match = dayjs(bangumiBeginDate).year() === jsonStartDate.year() &&
      dayjs(bangumiBeginDate).month() === jsonStartDate.month();
    if (!match) {
      // try to match previous month
      const prevMonthDate = dayjs(bangumiBeginDate).subtract(1, 'month');
      match = prevMonthDate.year() === jsonStartDate.year() &&
        prevMonthDate.month() === jsonStartDate.month();
    }
    return match;
  }
  return false;
};
