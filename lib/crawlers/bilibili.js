const ora = require('ora');
const cheerio = require('cheerio');

const { delay, fetch, matchBangumi } = require('../utils.js');

function getAreaRegex(area) {
  switch (area) {
    case 'hk_mo_tw':
      // 港澳台
      return /[（(]?仅限?港澳台(?:及其他)?(?:地区)?[）)]?$/g;
    case 'hk_mo':
      // 港澳
      return /[（(]?仅限?港澳(?:及其他)?(?:地区)?[）)]?$/g;
    case 'tw':
      // 台湾
      return /[（(]?仅限?台湾(?:及其他)?(?:地区)?[）)]?$/g;
    default:
      // 中国
      return /(?:[（(]?仅限?[港澳台湾]+(?:及其他)?(?:地区)?[）)]?)$/g;
  }
}

exports.getTitleByArea = function getTitleByArea(title, area) {
  return title.replace(getAreaRegex(area), '');
}

exports.getAllBangumi = async function getAllBangumi(page, totalPage, area) {
  const spinner = ora(`Crawling page ${page}/${totalPage || '?'}`).start();
  const perPage = 1000;
  const api = `https://api.bilibili.com/pgc/season/index/result?st=1&year=-1&season_version=-1&spoken_language_type=-1&area=-1&is_finish=-1&copyright=-1&season_status=-1&season_month=-1&style_id=-1&order=3&sort=0&page=${page}&season_type=1&pagesize=${perPage}&type=1`;
  const { code, message, data } = await fetch(api, {
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Referer': 'https://www.bilibili.com/',
    },
  }).then((res) => res.json());
  spinner.stop();
  if (code) {
    throw new Error(message);
  }
  const items = data.list.filter((item) => {
    if (area) { // 港,澳,台
      return getAreaRegex(area).test(item.title);
    } else {  // 中国
      return !getAreaRegex(area).test(item.title);
    }
  });
  const { num, size, total } = data;
  if (num * size < total) {
    return items.concat(await getAllBangumi(page + 1, Math.ceil(total / size), area));
  }
  return items;
}

exports.getAll = async function getAll() {
  const items = await exports.getAllBangumi(1);
  return items.map((item) => ({
    id: `${item.media_id}`,
    season_id: item.season_id ? `${item.season_id}` : '',
    titleTranslate: { 'zh-Hans': [item.title] },
    img: item.cover,
    href: `https://www.bilibili.com/bangumi/media/md${item.media_id}/`,
  }));
};

async function callAPI(url) {
  const { code, result } = await fetch(url, {
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Referer': 'https://www.bilibili.com/',
    },
  }).then((res) => res.json());
  return code === 0 ? result : null;
}

exports.getBegin = async function getBegin(mediaId, site, seasonId) {
  let sid = seasonId;
  if (!sid) {
    const mediaResult = await callAPI(`https://api.bilibili.com/pgc/review/user?media_id=${mediaId}`);
    if (!mediaResult) return '';
    sid = mediaResult.media.season_id;
  }
  const seasonResult = await callAPI(`https://api.bilibili.com/pgc/view/web/season?season_id=${sid}`);
  if (!seasonResult) return '';

  const isOnair = seasonResult.media.new_ep.id !== 0;

  let time = new Date(`${seasonResult.publish.pub_time}+08:00`);
  if (isOnair) {
    time = seasonResult.episodes
      .filter((ep) => (/^[\d-]+$/.test(ep.title) || ep.title === '正片' || ep.title === '全片' || ep.title === '原版') && ep.pub_time > 0)
      .map((ep) => new Date(ep.pub_time * 1000))
      .sort((a, b) => a - b)
      .shift();
  }

  // 避免触发哔哩哔哩安全风控策略
  await delay(1000);

  return time ? time.toISOString() : '';
};

exports.matchBangumi = async (input, items) => {
  return matchBangumi(input, { items });
}

exports.getIsBangumiOffline = async (id) => {
  const api = `https://www.bilibili.com/bangumi/media/md${id}/`;
  const $ = await fetch(api, {
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      'Referer': 'https://www.bilibili.com/',
    },
  })
    .then((res) => res.text())
    .then(cheerio.load);
  return $('.error-container').length > 0;
}
