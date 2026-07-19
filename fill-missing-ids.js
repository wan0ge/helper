/**
 * fill-missing-ids.js
 *
 * 定向补全 bangumi-data 中缺失的 season_id / video_sn，不做全量爬取。
 *
 * 支持的 site：
 *   season_id: bilibili, bilibili_hk_mo_tw, bilibili_tw, bilibili_hk_mo
 *   video_sn:  gamer, gamer_hk
 *
 * 用法：
 *   node fill-missing-ids.js
 *   node fill-missing-ids.js --dry-run       # 只打印，不写文件
 *   node fill-missing-ids.js --site bilibili  # 只处理指定 site
 *   node fill-missing-ids.js --skip-test      # 跳过网络连通性测试
 */

'use strict';

const fs = require('fs-extra');
const path = require('path');
const { fetch, delay } = require('./lib/utils.js');

// ─── 配置 ──────────────────────────────────────────────────────────────────

const BANGUMI_DATA_DIR = path.resolve(__dirname, '../bangumi-data/data/items');

// site 分类：需要补充哪个字段
const SITE_SEASON_ID = new Set(['bilibili', 'bilibili_hk_mo_tw', 'bilibili_tw', 'bilibili_hk_mo']);
const SITE_VIDEO_SN  = new Set(['gamer', 'gamer_hk']);

// gamer 详情页地址（HTML 抓取首集 video_sn）
const GAMER_ORIGINAL_URL = 'https://acg.gamer.com.tw/acgDetail.php?s=';
const GAMER_PROXY_URL    = 'https://elegy233.netlify.app/bahamutAcg/acgDetail.php?s=';

// gamer 搜索 API 地址（通过标题搜索获取 video_sn，搜索结果直接包含 video_sn）
const GAMER_SEARCH_DIRECT_URL = 'https://api.gamer.com.tw/mobile_app/anime/v1/search.php?kw=';
const GAMER_SEARCH_PROXY_URL  = 'https://elegy233.netlify.app/bahamut/mobile_app/anime/v1/search.php?kw=';

// gamer 请求间隔（毫秒），应对风控
const GAMER_DELAY_MS = 5000;

// 搜索 API 请求头（模拟巴哈姆特动画 App，API 要求移动端 UA）
const GAMER_SEARCH_HEADERS = {
  'Content-Type': 'application/json',
  'User-Agent': 'Anime/2.29.2 (7N5749MM3F.tw.com.gamer.anime; build:972; iOS 26.0.0) Alamofire/5.6.4',
};

// skip-list 持久化路径：记录连续失败的条目，达到阈值后跳过 30 天
const SKIP_LIST_PATH = path.resolve(__dirname, 'skip-list.json');
const SKIP_DAYS = 30;
const SKIP_FAILURE_THRESHOLD = 3;    // 连续失败 3 次后进入跳过列表
const MAX_RETRIES = 3;               // 网络错误最多重试 3 次（共 4 次尝试）

// 命令行参数
const args = process.argv.slice(2);
const DRY_RUN   = args.includes('--dry-run');
const SKIP_TEST = args.includes('--skip-test');
const SITE_ONLY = (() => {
  const idx = args.indexOf('--site');
  return idx !== -1 ? args[idx + 1] : null;
})();
const STATS_FILE = (() => {
  const idx = args.indexOf('--stats-file');
  return idx !== -1 ? args[idx + 1] : null;
})();

// ─── 工具函数 ──────────────────────────────────────────────────────────────

/** 从数组中随机取 n 个元素 */
function pickRandom(arr, n) {
  const copy = [...arr];
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy.slice(0, Math.min(n, copy.length));
}

/**
 * 判断 reason 是否为网络层错误（地址不可达）
 * 内容层失败（番剧未上架、下架等）不算网络错误
 */
function isNetworkError(reason) {
  if (!reason) return false;
  return reason.includes('网络错误') || reason.includes('ECONNREFUSED') || reason.includes('ENOTFOUND');
}

/**
 * 判断 reason 是否为 HTTP 错误（服务端返回非 2xx 状态码）
 * 如 HTTP 403 Forbidden、HTTP 429 Too Many Requests 等
 */
function isHttpError(reason) {
  if (!reason) return false;
  return /^HTTP \d{3}/.test(reason);
}

// ─── Skip List 持久化 ──────────────────────────────────────────────────────

/** 加载 skip-list.json */
async function loadSkipList() {
  try {
    if (await fs.pathExists(SKIP_LIST_PATH)) {
      return await fs.readJSON(SKIP_LIST_PATH);
    }
  } catch (e) { /* 文件损坏则重建 */ }
  return {};
}

/** 保存 skip-list.json */
async function saveSkipList(data) {
  await fs.outputJson(SKIP_LIST_PATH, data, { spaces: 2 });
}

/**
 * 检查某条 ID 是否应跳过
 * @returns {boolean}
 */
function isSkipped(skipList, type, id) {
  const entry = skipList[type]?.[id];
  if (!entry || !entry.skipUntil) return false;
  const skipUntil = new Date(entry.skipUntil);
  if (new Date() >= skipUntil) {
    // 跳过时间已到，从列表中移除
    delete skipList[type][id];
    if (Object.keys(skipList[type]).length === 0) delete skipList[type];
    return false;
  }
  return true;
}

/**
 * 记录一次失败
 * 连续失败达到阈值后设置 30 天跳过标记
 */
function recordFailure(skipList, type, id) {
  if (!skipList[type]) skipList[type] = {};
  if (!skipList[type][id]) skipList[type][id] = { failures: 0 };

  const entry = skipList[type][id];
  entry.failures++;
  entry.lastFailed = new Date().toISOString().split('T')[0];

  if (entry.failures >= SKIP_FAILURE_THRESHOLD) {
    const skipUntil = new Date();
    skipUntil.setDate(skipUntil.getDate() + SKIP_DAYS);
    entry.skipUntil = skipUntil.toISOString().split('T')[0];
  }
}

/**
 * 成功后重置失败计数（重新上架的番剧不再被跳过）
 */
function recordSuccess(skipList, type, id) {
  if (skipList[type]?.[id]) {
    delete skipList[type][id];
    if (Object.keys(skipList[type]).length === 0) delete skipList[type];
  }
}

/**
 * 从 bilibili site 的 comment 中提取配音版本 MD
 * 正则匹配 "中配版: 28236257" / "粤配版: 28339619" 等
 * @param {string} comment
 * @returns {Array<{label: string, id: string}>}
 */
function parseCommentMDs(comment) {
  if (!comment || typeof comment !== 'string') return [];
  const re = /((?:普通[话話]|[国國][语語]|中文配音|中配|中文|[粤粵][语語]配音|[粤粵]配|[粤粵][语語]|[台臺]配|[台臺][语語]|港配|港[语語]|字幕|助[听聽]|日[语語]|日配|原版|原[声聲])(?:版)?)\s*:\s*(\d+)/g;
  const result = [];
  let m;
  while ((m = re.exec(comment)) !== null) {
    result.push({ label: m[1], id: m[2] });
  }
  return result;
}

// ─── API 工具 ──────────────────────────────────────────────────────────────

/**
 * 通过 media_id 查询 bilibili 的 season_id
 * @returns {{ value: string|null, reason: string }}
 */
async function fetchBilibiliSeasonId(mediaId) {
  const url = `https://api.bilibili.com/pgc/review/user?media_id=${mediaId}`;
  const t0 = Date.now();
  let lastError = null;

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    try {
      const res = await fetch(url);
      const elapsed = Date.now() - t0;
      if (!res.ok) {
        return { value: null, elapsed, reason: `HTTP ${res.status} ${res.statusText}` };
      }
      const json = await res.json();
      const { code, message, result } = json;
      if (code === 0 && result && result.media && result.media.season_id) {
        return { value: `${result.media.season_id}`, elapsed, reason: null };
      }
      return { value: null, elapsed, reason: `API code=${code} message=${message || '(无)'}` };
    } catch (e) {
      lastError = e;
      if (attempt < MAX_RETRIES) {
        await delay(2000);  // 重试前等待 2 秒
      }
    }
  }
  return { value: null, elapsed: Date.now() - t0, reason: `网络错误(重试${MAX_RETRIES}次后失败): ${lastError.message}` };
}

/**
 * 通过 gamer 番剧 id 查询首集 video_sn
 * @param {string} id - 番剧 id
 * @param {string} [baseUrl] - 可选，自定义基础 URL（用于测试反代）
 * @returns {{ value: string|null, reason: string }}
 */
async function fetchGamerVideoSn(id, baseUrl) {
  const base = baseUrl || GAMER_ORIGINAL_URL;
  const url = `${base}${id}`;
  const t0 = Date.now();
  let lastError = null;

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    try {
      const cheerio = require('cheerio');
      const res = await fetch(url);
      const elapsed = Date.now() - t0;
      if (!res.ok) {
        return { value: null, elapsed, reason: `HTTP ${res.status} ${res.statusText}` };
      }
      const html = await res.text();
      const $ = cheerio.load(html);
      const href = $('.seasonACG>ul>li>a:first').attr('href');
      if (!href) {
        const title = $('title').text().trim() || '(无标题)';
        return { value: null, elapsed, reason: `未找到视频链接，页面标题: ${title}` };
      }
      const m = /animeVideo\.php\?sn=(\d+)/.exec(href);
      if (!m) {
        return { value: null, elapsed, reason: `href 格式不匹配: ${href}` };
      }
      return { value: m[1], elapsed, reason: null };
    } catch (e) {
      lastError = e;
      if (attempt < MAX_RETRIES) {
        await delay(GAMER_DELAY_MS);  // gamer 请求间隔
      }
    }
  }
  return { value: null, elapsed: Date.now() - t0, reason: `网络错误(重试${MAX_RETRIES}次后失败): ${lastError.message}` };
}

/**
 * 将标题按标点分割取前半段，用于搜索降级
 * 示例："骸骨騎士様、只今異世界へお出掛け中Ⅱ" → "骸骨騎士様、只今"
 *
 * @param {string} title - 原始标题
 * @returns {string|null} 切半后的标题，无法切分时返回 null
 */
function halfCutTitle(title) {
  if (!title || title.length < 4) return null;

  // 按常见分隔符分割，取分隔符后 2 个字符确保搜索词有足够区分度
  const delimiters = ['、', '，', ',', '。', '・', '：', ':', '～', '~'];
  for (const delim of delimiters) {
    const idx = title.indexOf(delim);
    if (idx > 0 && idx < title.length - 3) {
      return title.substring(0, Math.min(idx + 3, title.length));
    }
  }

  // 无标点时按半长度切分
  const mid = Math.floor(title.length / 2);
  if (mid >= 2) return title.substring(0, mid);

  return null;
}

/**
 * 从 bangumi-data 条目中提取搜索词候选列表
 * 优先级：繁体中文 > 日语原名 > 简体中文 > 日语原名切半
 *
 * @param {object} item - bangumi-data 条目（含 title 和 titleTranslate）
 * @returns {string[]} 搜索词候选列表（已去重）
 */
function getSearchCandidates(item) {
  const candidates = [];
  const seen = new Set();

  function add(candidate) {
    if (candidate && !seen.has(candidate)) {
      seen.add(candidate);
      candidates.push(candidate);
    }
  }

  // 繁体中文翻译
  const zhHant = item.titleTranslate?.['zh-Hant'];
  if (Array.isArray(zhHant) && zhHant.length > 0) {
    add(zhHant[0]);
  }

  // 日语原名
  add(item.title);

  // 简体中文翻译
  const zhHans = item.titleTranslate?.['zh-Hans'];
  if (Array.isArray(zhHans) && zhHans.length > 0) {
    add(zhHans[0]);
  }

  // 日语原名切半（搜索降级）
  add(halfCutTitle(item.title));

  return candidates;
}

/**
 * 通过搜索 API 按标题查询 video_sn
 * 搜索结果中包含 acg_sn，与本地 gamer id 对照确认后提取 video_sn
 *
 * 搜索词优先级见 getSearchCandidates，逐个尝试直到匹配成功
 *
 * @param {object} item - bangumi-data 条目（含 title 和 titleTranslate）
 * @param {string} gamerId - 本地 gamer site 的 id（对应 API 的 acg_sn）
 * @param {string} searchBaseUrl - 搜索 API 基础 URL（直连或反代）
 * @returns {{ value: string|null, elapsed: number, reason: string }}
 */
async function fetchGamerVideoSnViaSearch(item, gamerId, searchBaseUrl) {
  const candidates = getSearchCandidates(item);
  const t0 = Date.now();
  let lastReason = null;

  for (const keyword of candidates) {
    const encodedKw = encodeURIComponent(keyword);
    const url = `${searchBaseUrl}${encodedKw}`;
    let lastError = null;
    let apiResponded = false;

    for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
      try {
        const res = await fetch(url, { headers: GAMER_SEARCH_HEADERS });
        if (!res.ok) {
          // HTTP 错误（如 403），端点被阻断，后续搜索词同样无法访问
          return { value: null, elapsed: Date.now() - t0, reason: `HTTP ${res.status} ${res.statusText}` };
        }
        const json = await res.json();
        const animeList = json?.data?.anime || json?.anime || [];

        const match = animeList.find(a => String(a.acg_sn) === String(gamerId));
        if (match && match.video_sn) {
          return { value: String(match.video_sn), elapsed: Date.now() - t0, reason: null };
        }
        // API 返回成功但未匹配 acg_sn，尝试下一个搜索词
        apiResponded = true;
        lastReason = `搜索"${keyword}"未找到 acg_sn=${gamerId}`;
        break;
      } catch (e) {
        lastError = e;
        if (attempt < MAX_RETRIES) {
          await delay(GAMER_DELAY_MS);
        }
      }
    }

    if (!apiResponded && lastError) {
      return { value: null, elapsed: Date.now() - t0, reason: `网络错误(重试${MAX_RETRIES}次后失败): ${lastError.message}` };
    }

    await delay(GAMER_DELAY_MS);
  }

  return { value: null, elapsed: Date.now() - t0, reason: lastReason || `搜索API未找到 acg_sn=${gamerId} 的条目` };
}

// ─── 字段排序 ──────────────────────────────────────────────────────────────

/**
 * 确保 site 对象字段顺序为 site → id → season_id → video_sn → 其他
 * 这样 JSON 输出后新增字段紧跟在 id 下方，不会跑到末尾
 */
function reorderSiteFields(site, newFields = {}) {
  const ordered = { site: site.site, id: site.id };

  // 优先写 season_id、video_sn、related（新值覆盖旧值）
  const seasonId = newFields.season_id !== undefined ? newFields.season_id : site.season_id;
  const videoSn  = newFields.video_sn  !== undefined ? newFields.video_sn  : site.video_sn;
  const related  = newFields.related   !== undefined ? newFields.related   : site.related;

  if (seasonId !== undefined) ordered.season_id = seasonId;
  if (videoSn  !== undefined) ordered.video_sn  = videoSn;
  if (related  !== undefined && related.length > 0) ordered.related = related;

  // 复制其余字段（跳过已处理的）
  for (const key of Object.keys(site)) {
    if (key !== 'site' && key !== 'id' && key !== 'season_id' && key !== 'video_sn' && key !== 'related') {
      ordered[key] = site[key];
    }
  }

  return ordered;
}

// ─── 网络连通性测试 ────────────────────────────────────────────────────────

/**
 * 从最新月份的数据中查找测试条目
 * 从最新年份/月份往回扫描，找到 count 个条目的 id 列表
 */
async function findLatestSampleEntries(siteSet, count) {
  const years = (await fs.readdir(BANGUMI_DATA_DIR))
    .filter(y => /^\d{4}$/.test(y))
    .sort()
    .reverse(); // 最新在前

  const entries = [];
  for (const year of years) {
    const yearDir = path.join(BANGUMI_DATA_DIR, year);
    const files = (await fs.readdir(yearDir))
      .filter(f => f.endsWith('.json'))
      .sort()
      .reverse(); // 最新月份在前

    for (const file of files) {
      const items = await fs.readJSON(path.join(yearDir, file));
      for (const item of items) {
        if (!item.sites) continue;
        for (const site of item.sites) {
          if (siteSet.has(site.site) && site.id) {
            entries.push({
              site: site.site,
              id: site.id,
              title: item.title,
              yearFile: `${year}/${file}`,
            });
            if (entries.length >= count * 3) {
              // 多收集一些，方便随机取样
              return entries;
            }
          }
        }
      }
    }
  }
  return entries;
}

/**
 * 连通性测试：随机测试几个条目确认网络正常
 *
 * 测试链路（级联）：
 *   1. gamer 详情抓取：原始地址 → 反代地址
 *   2. gamer 搜索API：直连 → 反代
 *   3. 策略决策：详情抓取可用时优先使用（直接 ID 查询），
 *      否则使用搜索API（标题搜索），两者均不可用时默认详情抓取
 *
 * @returns {{ bilibiliOk: boolean, gamerUrl: string, gamerUrlLabel: string,
 *            searchApiUrl: string, searchApiLabel: string, gamerStrategy: string }}
 */
async function testConnectivity() {
  console.log('──────────────────────────────────────────');
  console.log('🔍 网络连通性测试');
  console.log('──────────────────────────────────────────\n');

  const result = {
    bilibiliOk: true,
    gamerUrl: GAMER_ORIGINAL_URL,
    gamerUrlLabel: '原始地址',
    searchApiUrl: GAMER_SEARCH_DIRECT_URL,
    searchApiLabel: '直连',
    gamerStrategy: 'detail',
  };

  // ── 测试 bilibili ──
  const biliEntries = await findLatestSampleEntries(
    new Set(['bilibili', 'bilibili_hk_mo_tw', 'bilibili_tw', 'bilibili_hk_mo']),
    2
  );
  const biliSamples = pickRandom(biliEntries, 2);

  if (biliSamples.length === 0) {
    console.log('[bilibili] ⚠️  未在数据中找到 bilibili 条目，跳过测试\n');
  } else {
    console.log(`[bilibili] 随机选取 ${biliSamples.length} 个条目测试：`);
    let biliPass = 0, biliFail = 0;

    for (const entry of biliSamples) {
      const res = await fetchBilibiliSeasonId(entry.id);
      if (res.value) {
        console.log(`  ✅ [${entry.site}] media_id=${entry.id}  →  season_id=${res.value}  (${entry.title})`);
        biliPass++;
      } else {
        console.log(`  ❌ [${entry.site}] media_id=${entry.id}  →  ${res.reason}  (${entry.title})`);
        biliFail++;
      }
      await delay(1000);  // bilibili 风控间隔
    }

    if (biliPass === biliSamples.length) {
      console.log(`[bilibili] ✅ 全部通过 (${biliPass}/${biliSamples.length})\n`);
      result.bilibiliOk = true;
    } else {
      console.log(`[bilibili] ⚠️  部分失败 (${biliPass}/${biliSamples.length} 通过)，将继续尝试\n`);
      result.bilibiliOk = biliPass > 0;
    }
  }

  // ── 测试 gamer 详情抓取（原始地址） ──
  const gamerEntries = await findLatestSampleEntries(SITE_VIDEO_SN, 2);
  const gamerSamples = pickRandom(gamerEntries, 2);

  if (gamerSamples.length === 0) {
    console.log('[gamer] ⚠️  未在数据中找到 gamer 条目，跳过测试\n');
    return result;
  }

  console.log(`[gamer 详情抓取 原始地址] 随机选取 ${gamerSamples.length} 个条目测试：`);
  let origPass = 0, origNetworkFail = 0, origHttpFail = 0;
  for (const entry of gamerSamples) {
    const res = await fetchGamerVideoSn(entry.id, GAMER_ORIGINAL_URL);
    if (res.value) {
      console.log(`  ✅ [${entry.site}] id=${entry.id}  →  video_sn=${res.value}  (${entry.title})`);
      origPass++;
    } else if (isNetworkError(res.reason)) {
      console.log(`  ❌ [${entry.site}] id=${entry.id}  →  ${res.reason}  (${entry.title})`);
      origNetworkFail++;
    } else if (isHttpError(res.reason)) {
      console.log(`  ❌ [${entry.site}] id=${entry.id}  →  ${res.reason}  (${entry.title})`);
      origHttpFail++;
    } else {
      console.log(`  ⚠️  [${entry.site}] id=${entry.id}  →  ${res.reason}  (${entry.title})`);
    }
    await delay(GAMER_DELAY_MS);
  }

  // 详情抓取可用性：无网络错误且无 HTTP 错误（内容层失败不代表地址不可用）
  let detailWorks = (origNetworkFail === 0 && origHttpFail === 0);

  if (detailWorks) {
    if (origPass === gamerSamples.length) {
      console.log(`[gamer 详情抓取 原始地址] ✅ 全部通过 (${origPass}/${gamerSamples.length})`);
    } else {
      console.log(`[gamer 详情抓取 原始地址] ✅ 地址可达 (${origPass}/${gamerSamples.length} 有数据，其余为内容层无数据)`);
    }
    console.log(`  将使用原始地址：${GAMER_ORIGINAL_URL}\n`);
    result.gamerUrl = GAMER_ORIGINAL_URL;
    result.gamerUrlLabel = '原始地址';
  } else {
    // 原始地址有网络错误或 HTTP 错误，测试反代
    const failSummary = `网络${origNetworkFail}/${gamerSamples.length} HTTP${origHttpFail}/${gamerSamples.length}`;
    console.log(`[gamer 详情抓取 原始地址] ⚠️  不可用 (${failSummary})，测试反代...\n`);

    console.log(`[gamer 详情抓取 反代地址] 测试相同 ${gamerSamples.length} 个条目：`);
    let proxyPass = 0, proxyNetworkFail = 0, proxyHttpFail = 0;
    for (const entry of gamerSamples) {
      const res = await fetchGamerVideoSn(entry.id, GAMER_PROXY_URL);
      if (res.value) {
        console.log(`  ✅ [${entry.site}] id=${entry.id}  →  video_sn=${res.value}  (${entry.title})`);
        proxyPass++;
      } else if (isNetworkError(res.reason)) {
        console.log(`  ❌ [${entry.site}] id=${entry.id}  →  ${res.reason}  (${entry.title})`);
        proxyNetworkFail++;
      } else if (isHttpError(res.reason)) {
        console.log(`  ❌ [${entry.site}] id=${entry.id}  →  ${res.reason}  (${entry.title})`);
        proxyHttpFail++;
      } else {
        console.log(`  ⚠️  [${entry.site}] id=${entry.id}  →  ${res.reason}  (${entry.title})`);
      }
      await delay(GAMER_DELAY_MS);
    }

    detailWorks = (proxyNetworkFail === 0 && proxyHttpFail === 0);

    if (detailWorks) {
      if (proxyPass === gamerSamples.length) {
        console.log(`[gamer 详情抓取 反代地址] ✅ 全部通过 (${proxyPass}/${gamerSamples.length})`);
      } else {
        console.log(`[gamer 详情抓取 反代地址] ✅ 地址可达 (${proxyPass}/${gamerSamples.length} 有数据，其余为内容层无数据)`);
      }
    } else {
      const failSummary = `网络${proxyNetworkFail}/${gamerSamples.length} HTTP${proxyHttpFail}/${gamerSamples.length}`;
      console.log(`[gamer 详情抓取 反代地址] ⚠️  不可用 (${failSummary})`);
    }
    console.log(`  将使用反代地址：${GAMER_PROXY_URL}\n`);
    result.gamerUrl = GAMER_PROXY_URL;
    result.gamerUrlLabel = '反代地址';
  }

  // ── 测试 gamer 搜索 API（直连） ──
  console.log(`[gamer 搜索API 直连] 测试 ${gamerSamples.length} 个条目：`);
  let searchDirectOk = 0, searchDirectFail = 0;
  for (const entry of gamerSamples) {
    const encodedKw = encodeURIComponent(entry.title);
    const url = `${GAMER_SEARCH_DIRECT_URL}${encodedKw}`;
    try {
      const res = await fetch(url, { headers: GAMER_SEARCH_HEADERS });
      if (res.ok) {
        console.log(`  ✅ [${entry.site}] id=${entry.id}  →  HTTP ${res.status}  (${entry.title})`);
        searchDirectOk++;
      } else {
        console.log(`  ❌ [${entry.site}] id=${entry.id}  →  HTTP ${res.status}  (${entry.title})`);
        searchDirectFail++;
      }
    } catch (e) {
      console.log(`  ❌ [${entry.site}] id=${entry.id}  →  网络错误: ${e.message}  (${entry.title})`);
      searchDirectFail++;
    }
    await delay(GAMER_DELAY_MS);
  }

  let searchWorks = false;
  if (searchDirectOk > 0) {
    console.log(`[gamer 搜索API 直连] ✅ 可用 (${searchDirectOk}/${gamerSamples.length} 成功)`);
    result.searchApiUrl = GAMER_SEARCH_DIRECT_URL;
    result.searchApiLabel = '直连';
    searchWorks = true;
  } else {
    // 直连不可用，测试反代
    console.log(`[gamer 搜索API 直连] ❌ 不可用，测试反代...\n`);
    console.log(`[gamer 搜索API 反代] 测试 ${gamerSamples.length} 个条目：`);
    let searchProxyOk = 0, searchProxyFail = 0;
    for (const entry of gamerSamples) {
      const encodedKw = encodeURIComponent(entry.title);
      const url = `${GAMER_SEARCH_PROXY_URL}${encodedKw}`;
      try {
        const res = await fetch(url, { headers: GAMER_SEARCH_HEADERS });
        if (res.ok) {
          console.log(`  ✅ [${entry.site}] id=${entry.id}  →  HTTP ${res.status}  (${entry.title})`);
          searchProxyOk++;
        } else {
          console.log(`  ❌ [${entry.site}] id=${entry.id}  →  HTTP ${res.status}  (${entry.title})`);
          searchProxyFail++;
        }
      } catch (e) {
        console.log(`  ❌ [${entry.site}] id=${entry.id}  →  网络错误: ${e.message}  (${entry.title})`);
        searchProxyFail++;
      }
      await delay(GAMER_DELAY_MS);
    }

    result.searchApiUrl = GAMER_SEARCH_PROXY_URL;
    result.searchApiLabel = '反代';
    if (searchProxyOk > 0) {
      console.log(`[gamer 搜索API 反代] ✅ 可用 (${searchProxyOk}/${gamerSamples.length} 成功)`);
      searchWorks = true;
    } else {
      console.log(`[gamer 搜索API 反代] ❌ 不可用 (${searchProxyOk}/${gamerSamples.length} 成功)`);
      searchWorks = false;
    }
  }

  // ── 策略决策 ──
  if (detailWorks) {
    result.gamerStrategy = 'detail';
    console.log(`\n[gamer 策略] 详情抓取 (${result.gamerUrlLabel})\n`);
  } else if (searchWorks) {
    result.gamerStrategy = 'search';
    console.log(`\n[gamer 策略] 搜索API (${result.searchApiLabel})\n`);
  } else {
    result.gamerStrategy = 'detail';
    console.log(`\n[gamer 策略] 详情抓取和搜索API均不可用，默认详情抓取 (${result.gamerUrlLabel})\n`);
  }

  return result;
}

// ─── 主逻辑 ────────────────────────────────────────────────────────────────

async function run() {
  if (!await fs.pathExists(BANGUMI_DATA_DIR)) {
    console.error(`bangumi-data 目录不存在：${BANGUMI_DATA_DIR}`);
    console.error('请确认 bangumi-data 仓库与 helper 仓库在同一父目录下');
    process.exit(1);
  }

  // ── 第一步：扫描缺失条目 ───────────────────────────────────────

  // 加载 skip list
  const skipList = await loadSkipList();
  let skippedCount = 0;

  const years = (await fs.readdir(BANGUMI_DATA_DIR)).filter(y => /^\d{4}$/.test(y));

  const missingSeasonId = []; // { filePath, itemIdx, siteIdx, mediaId }
  const missingVideoSn  = []; // { filePath, itemIdx, siteIdx, gamerId }
  const missingRelated  = []; // { filePath, itemIdx, siteIdx, mediaId, label }

  let totalFiles = 0;
  for (const year of years.sort()) {
    const yearDir = path.join(BANGUMI_DATA_DIR, year);
    const files = (await fs.readdir(yearDir)).filter(f => f.endsWith('.json')).sort();
    for (const file of files) {
      totalFiles++;
      const filePath = path.join(yearDir, file);
      const items = await fs.readJSON(filePath);
      for (let i = 0; i < items.length; i++) {
        const item = items[i];
        if (!item.sites) continue;
        for (let j = 0; j < item.sites.length; j++) {
          const site = item.sites[j];
          if (!site.site || !site.id) continue;
          if (SITE_ONLY && site.site !== SITE_ONLY) continue;

          if (SITE_SEASON_ID.has(site.site) && !site.season_id) {
            if (isSkipped(skipList, 'bilibili', site.id)) {
              skippedCount++;
              continue;
            }
            missingSeasonId.push({ filePath, itemIdx: i, siteIdx: j, mediaId: site.id });
          } else if (SITE_VIDEO_SN.has(site.site) && !site.video_sn) {
            if (isSkipped(skipList, 'gamer', site.id)) {
              skippedCount++;
              continue;
            }
            missingVideoSn.push({ filePath, itemIdx: i, siteIdx: j, gamerId: site.id });
          }

          // 检查 bilibili comment 中的配音版本 MD（需要补全 related）
          if ((site.site === 'bilibili' || site.site.startsWith('bilibili')) && site.comment) {
            const refs = parseCommentMDs(site.comment);
            for (const ref of refs) {
              const existing = site.related ? site.related.find(r => r.id === ref.id) : null;
              if (!existing || !existing.season_id) {
                missingRelated.push({ filePath, itemIdx: i, siteIdx: j, mediaId: ref.id, label: ref.label });
              }
            }
          }
        }
      }
    }
  }

  // 过期的 skip 条目已由 isSkipped() 自动清除，刷新到磁盘
  await saveSkipList(skipList);

  const totalMissing = missingSeasonId.length + missingVideoSn.length + missingRelated.length;
  console.log(`\n扫描完成：共 ${totalFiles} 个月份文件`);
  console.log(`  缺失 season_id：${missingSeasonId.length} 条`);
  console.log(`  缺失 video_sn：${missingVideoSn.length} 条`);
  console.log(`  待补全 related（配音版本）：${missingRelated.length} 条`);
  if (skippedCount > 0) {
    console.log(`  跳过列表 (30天内连续失败${SKIP_FAILURE_THRESHOLD}次)：${skippedCount} 条`);
  }

  if (DRY_RUN) {
    console.log('\n[dry-run] 不写入文件，仅打印前 10 条缺失项：');
    console.log('--- season_id ---');
    missingSeasonId.slice(0, 10).forEach(e => console.log(`  ${e.filePath} item[${e.itemIdx}].sites[${e.siteIdx}] mediaId=${e.mediaId}`));
    console.log('--- video_sn ---');
    missingVideoSn.slice(0, 10).forEach(e => console.log(`  ${e.filePath} item[${e.itemIdx}].sites[${e.siteIdx}] gamerId=${e.gamerId}`));
    return;
  }

  if (missingSeasonId.length === 0 && missingVideoSn.length === 0 && missingRelated.length === 0) {
    console.log('\n所有条目已完整，无需补全。');
    return;
  }

  // ── 第二步：连通性测试 ─────────────────────────────────────────

  let gamerUrl = GAMER_ORIGINAL_URL;
  let gamerUrlLabel = '原始地址';
  let searchApiUrl = GAMER_SEARCH_DIRECT_URL;
  let searchApiLabel = '直连';
  let gamerStrategy = 'detail';

  if (!SKIP_TEST) {
    const testResult = await testConnectivity();
    gamerUrl = testResult.gamerUrl;
    gamerUrlLabel = testResult.gamerUrlLabel;
    searchApiUrl = testResult.searchApiUrl;
    searchApiLabel = testResult.searchApiLabel;
    gamerStrategy = testResult.gamerStrategy;
  } else {
    console.log('⏭️  跳过网络连通性测试（--skip-test）\n');
  }

  // ── 第三步：开始补全 ───────────────────────────────────────────

  const fileCache = {};  // filePath -> items[]
  const fileDirty = new Set();

  async function getItems(filePath) {
    if (!fileCache[filePath]) {
      fileCache[filePath] = await fs.readJSON(filePath);
    }
    return fileCache[filePath];
  }

  console.log('──────────────────────────────────────────');
  console.log('🚀 开始补全');
  console.log('──────────────────────────────────────────');
  if (gamerStrategy === 'search') {
    console.log(`  gamer 策略: 搜索API (${searchApiLabel}: ${searchApiUrl})`);
  } else {
    console.log(`  gamer 策略: 详情抓取 (${gamerUrlLabel}: ${gamerUrl})`);
  }

  // ── 补全 season_id ─────────────────────────────────────────────

  let doneSeasonId = 0, failSeasonId = 0;
  const failedSeasonId = []; // { mediaId, site, filePath, reason }
  const seasonIdDurations = []; // 成功请求耗时（ms）
  if (missingSeasonId.length > 0) {
    console.log(`\n开始补全 season_id（${missingSeasonId.length} 条）...`);
    for (let idx = 0; idx < missingSeasonId.length; idx++) {
      const { filePath, itemIdx, siteIdx, mediaId } = missingSeasonId[idx];
      process.stdout.write(`\r  进度: ${idx + 1}/${missingSeasonId.length}  成功: ${doneSeasonId}  失败: ${failSeasonId}  `);

      const { value: seasonId, elapsed, reason } = await fetchBilibiliSeasonId(mediaId);
      if (seasonId) {
        const items = await getItems(filePath);
        items[itemIdx].sites[siteIdx] = reorderSiteFields(items[itemIdx].sites[siteIdx], { season_id: seasonId });
        fileDirty.add(filePath);
        doneSeasonId++;
        seasonIdDurations.push(elapsed);
        recordSuccess(skipList, 'bilibili', mediaId);
      } else {
        failSeasonId++;
        const items = await getItems(filePath);
        const siteName = items[itemIdx].sites[siteIdx].site;
        failedSeasonId.push({ mediaId, site: siteName, filePath: path.relative(BANGUMI_DATA_DIR, filePath), reason });
        // HTTP 412 是临时风控，不计入 skip-list
        if (!reason || !reason.includes('HTTP 412')) {
          recordFailure(skipList, 'bilibili', mediaId);
        }
      }
      await delay(3000);  // 提高请求间隔，避免 bilibili 风控 412
    }
    console.log(`\n  season_id 补全完成：成功 ${doneSeasonId} / 失败 ${failSeasonId}`);
  }

  // ── 补全 video_sn ──────────────────────────────────────────────

  let doneVideoSn = 0, failVideoSn = 0;
  const failedVideoSn = []; // { gamerId, site, filePath, reason }
  const videoSnDurations = []; // 成功请求耗时（ms）
  if (missingVideoSn.length > 0) {
    console.log(`\n开始补全 video_sn（${missingVideoSn.length} 条）...`);
    for (let idx = 0; idx < missingVideoSn.length; idx++) {
      const { filePath, itemIdx, siteIdx, gamerId } = missingVideoSn[idx];
      process.stdout.write(`\r  进度: ${idx + 1}/${missingVideoSn.length}  成功: ${doneVideoSn}  失败: ${failVideoSn}  `);

      let result;
      if (gamerStrategy === 'search') {
        const items = await getItems(filePath);
        result = await fetchGamerVideoSnViaSearch(items[itemIdx], gamerId, searchApiUrl);
      } else {
        result = await fetchGamerVideoSn(gamerId, gamerUrl);
      }
      const { value: videoSn, elapsed, reason } = result;

      if (videoSn) {
        const items = await getItems(filePath);
        items[itemIdx].sites[siteIdx] = reorderSiteFields(items[itemIdx].sites[siteIdx], { video_sn: videoSn });
        fileDirty.add(filePath);
        doneVideoSn++;
        videoSnDurations.push(elapsed);
        recordSuccess(skipList, 'gamer', gamerId);
      } else {
        failVideoSn++;
        const items = await getItems(filePath);
        const siteName = items[itemIdx].sites[siteIdx].site;
        failedVideoSn.push({ gamerId, site: siteName, filePath: path.relative(BANGUMI_DATA_DIR, filePath), reason });
        // HTTP 412 是临时风控，不计入 skip-list
        if (!reason || !reason.includes('HTTP 412')) {
          recordFailure(skipList, 'gamer', gamerId);
        }
      }
      await delay(GAMER_DELAY_MS);
    }
    console.log(`\n  video_sn 补全完成：成功 ${doneVideoSn} / 失败 ${failVideoSn}`);
  }

  // ── 补全 related（bilibili comment 中的配音版本 season_id）──────

  let doneRelated = 0, failRelated = 0;
  const failedRelated = []; // { mediaId, label, filePath, reason }
  if (missingRelated.length > 0) {
    console.log(`\n开始补全 related 配音版本（${missingRelated.length} 条）...`);
    for (let idx = 0; idx < missingRelated.length; idx++) {
      const { filePath, itemIdx, siteIdx, mediaId, label } = missingRelated[idx];
      process.stdout.write(`\r  进度: ${idx + 1}/${missingRelated.length}  成功: ${doneRelated}  失败: ${failRelated}  `);

      const { value: seasonId, reason } = await fetchBilibiliSeasonId(mediaId);
      if (seasonId) {
        const items = await getItems(filePath);
        const site = items[itemIdx].sites[siteIdx];
        let related = site.related || [];

        // 去重：同 id 只保留一条
        const existing = related.find(r => r.id === mediaId);
        if (existing) {
          existing.season_id = seasonId;
          // 如果原来没有 label，补上
          if (!existing.label) existing.label = label;
        } else {
          related.push({ id: mediaId, season_id: seasonId, label });
        }

        items[itemIdx].sites[siteIdx] = reorderSiteFields(site, { related });
        fileDirty.add(filePath);
        doneRelated++;
      } else {
        failRelated++;
        failedRelated.push({ mediaId, label, filePath: path.relative(BANGUMI_DATA_DIR, filePath), reason });
      }
      await delay(3000);  // 提高请求间隔，避免 bilibili 风控 412
    }
    console.log(`\n  related 配音版本补全完成：成功 ${doneRelated} / 失败 ${failRelated}`);
  }

  // ── 写回文件 ───────────────────────────────────────────────────

  console.log(`\n写回文件（${fileDirty.size} 个文件修改）...`);
  for (const filePath of fileDirty) {
    await fs.outputJson(filePath, fileCache[filePath], { spaces: 2 });
  }

  const totalDone = doneSeasonId + doneVideoSn + doneRelated;
  const totalFail = failSeasonId + failVideoSn + failRelated;
  console.log(`\n✅ 全部完成！补全 ${totalDone} 条，无法获取 ${totalFail} 条`);

  // ── 请求耗时统计 ────────────────────────────────────────────────

  function durationStats(name, durations) {
    if (durations.length === 0) return;
    const sorted = [...durations].sort((a, b) => a - b);
    const sum = sorted.reduce((a, b) => a + b, 0);
    const avg = Math.round(sum / sorted.length);
    const min = sorted[0];
    const max = sorted[sorted.length - 1];
    const p50 = sorted[Math.floor(sorted.length * 0.5)];
    const p90 = sorted[Math.floor(sorted.length * 0.9)];
    console.log(`\n  📊 ${name} 请求耗时（仅成功请求，共 ${durations.length} 次）:`);
    console.log(`     平均: ${avg}ms  |  最小: ${min}ms  |  最大: ${max}ms`);
    console.log(`     P50: ${p50}ms  |  P90: ${p90}ms`);
  }

  durationStats('bilibili (season_id)', seasonIdDurations);
  durationStats('gamer (video_sn)', videoSnDurations);

  // 打印失败详情
  if (failedSeasonId.length > 0) {
    console.log(`\n─── 失败的 season_id（${failedSeasonId.length} 条）───`);
    for (const { mediaId, site, filePath, reason } of failedSeasonId) {
      console.log(`  [${site}] media_id=${mediaId}  文件: ${filePath}`);
      console.log(`    原因: ${reason}`);
    }
  }

  if (failedVideoSn.length > 0) {
    console.log(`\n─── 失败的 video_sn（${failedVideoSn.length} 条）───`);
    for (const { gamerId, site, filePath, reason } of failedVideoSn) {
      console.log(`  [${site}] id=${gamerId}  文件: ${filePath}`);
      console.log(`    原因: ${reason}`);
    }
  }

  if (failedRelated.length > 0) {
    console.log(`\n─── 失败的 related 配音版本（${failedRelated.length} 条）───`);
    for (const { mediaId, label, filePath, reason } of failedRelated) {
      console.log(`  [${label}] media_id=${mediaId}  文件: ${filePath}`);
      console.log(`    原因: ${reason}`);
    }
  }

  // ── 保存 skip list ────────────────────────────────────────────────

  await saveSkipList(skipList);

  // 统计 skip list 中的条目
  let skipListTotal = 0, skipListActive = 0;
  for (const type of Object.keys(skipList)) {
    for (const [id, entry] of Object.entries(skipList[type])) {
      skipListTotal++;
      if (entry.skipUntil) skipListActive++;
    }
  }
  if (skipListTotal > 0) {
    console.log(`\n📋 skip-list 状态：共追踪 ${skipListTotal} 个失败条目，其中 ${skipListActive} 个处于活跃跳过状态 (${SKIP_DAYS}天)`);
  }

  // ── 写入统计文件（供 auto-sync.sh 读取用于钉钉通知）──────────
  if (STATS_FILE) {
    const stats = {
      timestamp: new Date().toISOString(),
      total_files: totalFiles,
      season_id_total: missingSeasonId.length,
      season_id_filled: doneSeasonId,
      season_id_failed: failSeasonId,
      video_sn_total: missingVideoSn.length,
      video_sn_filled: doneVideoSn,
      video_sn_failed: failVideoSn,
      related_total: missingRelated.length,
      related_filled: doneRelated,
      related_failed: failRelated,
      files_modified: fileDirty.size,
      gamer_strategy: gamerStrategy,
      gamer_url_label: gamerUrlLabel,
      search_api_label: searchApiLabel,
      skipped_count: skippedCount,
      skip_list_active: skipListActive,
      skip_list_total: skipListTotal,
    };
    await fs.outputJson(STATS_FILE, stats, { spaces: 2 });
  }
}

run().catch(err => {
  console.error('\n脚本出错：', err.message);
  process.exit(1);
});
