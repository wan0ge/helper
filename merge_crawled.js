const fs = require('fs-extra');
const path = require('path');
const { fetch, delay } = require('./lib/utils.js');

const BANGUMI_DATA = path.resolve(__dirname, '../bangumi-data/data/items');
const CRAWLED = path.resolve(__dirname, 'data/items/0000');

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

/**
 * 通过 media_id 查询 bilibili 的 season_id
 * @returns {{ value: string|null, reason: string }}
 */
async function fetchBilibiliSeasonId(mediaId) {
  const url = `https://api.bilibili.com/pgc/review/user?media_id=${mediaId}`;
  let lastError = null;
  for (let attempt = 0; attempt <= 3; attempt++) {
    try {
      const res = await fetch(url);
      if (!res.ok) {
        return { value: null, reason: `HTTP ${res.status} ${res.statusText}` };
      }
      const json = await res.json();
      const { code, message, result } = json;
      if (code === 0 && result && result.media && result.media.season_id) {
        return { value: `${result.media.season_id}`, reason: null };
      }
      return { value: null, reason: `API code=${code} message=${message || '(无)'}` };
    } catch (e) {
      lastError = e;
      if (attempt < 3) await delay(2000);
    }
  }
  return { value: null, reason: `网络错误: ${lastError.message}` };
}

/**
 * 确保 site 对象字段顺序为 site → id → season_id → video_sn → related → 其他
 */
function reorderSiteFields(site) {
  const ordered = { site: site.site, id: site.id };
  if (site.season_id !== undefined) ordered.season_id = site.season_id;
  if (site.video_sn  !== undefined) ordered.video_sn  = site.video_sn;
  if (site.related   !== undefined && site.related.length > 0) ordered.related = site.related;
  for (const key of Object.keys(site)) {
    if (key !== 'site' && key !== 'id' && key !== 'season_id' && key !== 'video_sn' && key !== 'related') {
      ordered[key] = site[key];
    }
  }
  return ordered;
}

async function merge() {
  // 读取所有爬取的数据文件
  const crawledFiles = (await fs.readdir(CRAWLED)).filter(f => f.endsWith('.json'));

  if (!crawledFiles.length) {
    console.error('错误：data/items/0000/ 下没有 JSON 文件');
    console.error('请先运行：node bin/bdh.js hokan <site>');
    process.exit(1);
  }

  console.log(`发现爬取数据文件：${crawledFiles.join(', ')}`);

  // 加载所有爬取数据，按文件名（site名）建立索引
  const crawledData = {};
  for (const file of crawledFiles) {
    const siteName = file.replace('.json', '');
    crawledData[siteName] = await fs.readJSON(path.join(CRAWLED, file)).catch(() => []);
    console.log(`  已加载 ${siteName}: ${crawledData[siteName].length} 条`);
  }

  const years = (await fs.readdir(BANGUMI_DATA)).filter(y => /^\d{4}$/.test(y));
  let totalUpdated = 0;

  // 文件缓存（第二遍 related 补全需要重新读取）
  const fileCache = {};

  // ── 第一遍：合并爬取的 season_id / video_sn ──────────────────────

  for (const year of years) {
    const yearDir = path.join(BANGUMI_DATA, year);
    const months = (await fs.readdir(yearDir)).filter(f => f.endsWith('.json'));
    for (const monthFile of months) {
      const filePath = path.join(yearDir, monthFile);
      const items = await fs.readJSON(filePath);
      let changed = false;

      for (const item of items) {
        for (const site of item.sites) {
          if (!site.site || !site.id) continue;

          const siteName = site.site;
          const crawledItems = crawledData[siteName];

          if (crawledItems && crawledItems.length) {
            const match = crawledItems.find(c => String(c.id) === String(site.id));
            if (match) {
              if (match.video_sn && !site.video_sn) {
                site.video_sn = match.video_sn;
                changed = true;
                totalUpdated++;
              }
              if (match.season_id && !site.season_id) {
                site.season_id = match.season_id;
                changed = true;
                totalUpdated++;
              }
            }
          }
        }
      }

      if (changed) {
        await fs.outputJson(filePath, items, { spaces: 2 });
        console.log(`已更新: ${year}/${monthFile}`);
      }

      // 缓存文件供第二遍使用
      fileCache[filePath] = items;
    }
  }

  // ── 第二遍：补全 bilibili comment 中的配音版本 season_id ────────

  let totalRelated = 0;
  const relatedToFetch = []; // { filePath, itemIdx, siteIdx, mediaId, label }

  // 扫描需要补全的 related 条目
  for (const year of years) {
    const yearDir = path.join(BANGUMI_DATA, year);
    const months = (await fs.readdir(yearDir)).filter(f => f.endsWith('.json'));
    for (const monthFile of months) {
      const filePath = path.join(yearDir, monthFile);
      const items = fileCache[filePath] || (await fs.readJSON(filePath));
      fileCache[filePath] = items;

      for (let i = 0; i < items.length; i++) {
        const item = items[i];
        if (!item.sites) continue;
        for (let j = 0; j < item.sites.length; j++) {
          const site = item.sites[j];
          if (!site.site || !site.id) continue;
          if (site.site !== 'bilibili' && !site.site.startsWith('bilibili')) continue;
          if (!site.comment) continue;

          const refs = parseCommentMDs(site.comment);
          for (const ref of refs) {
            const existing = site.related ? site.related.find(r => r.id === ref.id) : null;
            if (!existing || !existing.season_id) {
              relatedToFetch.push({ filePath, itemIdx: i, siteIdx: j, mediaId: ref.id, label: ref.label });
            }
          }
        }
      }
    }
  }

  if (relatedToFetch.length > 0) {
    console.log(`\n开始补全 related 配音版本 season_id（${relatedToFetch.length} 条）...`);
    const fileDirty = new Set();

    for (let idx = 0; idx < relatedToFetch.length; idx++) {
      const { filePath, itemIdx, siteIdx, mediaId, label } = relatedToFetch[idx];
      process.stdout.write(`\r  进度: ${idx + 1}/${relatedToFetch.length}  成功: ${totalRelated}`);

      const { value: seasonId } = await fetchBilibiliSeasonId(mediaId);
      if (seasonId) {
        const items = fileCache[filePath];
        const site = items[itemIdx].sites[siteIdx];
        let related = site.related || [];

        const existing = related.find(r => r.id === mediaId);
        if (existing) {
          existing.season_id = seasonId;
          if (!existing.label) existing.label = label;
        } else {
          related.push({ id: mediaId, season_id: seasonId, label });
        }

        items[itemIdx].sites[siteIdx] = reorderSiteFields(site);
        fileDirty.add(filePath);
        totalRelated++;
        totalUpdated++;
      }
      await delay(1000);
    }

    // 写回修改的文件
    for (const filePath of fileDirty) {
      await fs.outputJson(filePath, fileCache[filePath], { spaces: 2 });
    }
    console.log(`\n  related 配音版本补全完成：成功 ${totalRelated} / 共 ${relatedToFetch.length} 条`);
  } else {
    console.log('\n无需补全 related 配音版本。');
  }

  console.log(`\n合并完成！共更新 ${totalUpdated} 条 site 记录。`);
}

merge();
