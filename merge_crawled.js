const fs = require('fs-extra');
const path = require('path');

const BANGUMI_DATA = path.resolve(__dirname, '../bangumi-data/data/items');
const CRAWLED = path.resolve(__dirname, 'data/items/0000');

async function merge() {
  const gamerItems = await fs.readJSON(path.join(CRAWLED, 'gamer.json')).catch(() => []);
  const bilibiliItems = await fs.readJSON(path.join(CRAWLED, 'bilibili.json')).catch(() => []);

  if (!gamerItems.length && !bilibiliItems.length) {
    console.error('错误：data/items/0000/ 下没有 gamer.json 或 bilibili.json');
    console.error('请先运行：node bin/bdh.js hokan gamer  和  node bin/bdh.js hokan bilibili');
    process.exit(1);
  }

  const years = (await fs.readdir(BANGUMI_DATA)).filter(y => /^\d{4}$/.test(y));
  let totalUpdated = 0;

  for (const year of years) {
    const yearDir = path.join(BANGUMI_DATA, year);
    const months = (await fs.readdir(yearDir)).filter(f => f.endsWith('.json'));
    for (const monthFile of months) {
      const filePath = path.join(yearDir, monthFile);
      const items = await fs.readJSON(filePath);
      let changed = false;

      for (const item of items) {
        for (const site of item.sites) {
          if (site.site?.startsWith('gamer') && site.id) {
            const match = gamerItems.find(g => String(g.id) === String(site.id));
            if (match && match.video_sn) {
              site.video_sn = match.video_sn;
              changed = true;
              totalUpdated++;
            }
          }
          if (site.site?.startsWith('bilibili') && site.id) {
            const match = bilibiliItems.find(b => String(b.id) === String(site.id));
            if (match && match.season_id) {
              site.season_id = match.season_id;
              changed = true;
              totalUpdated++;
            }
          }
        }
      }

      if (changed) {
        await fs.outputJson(filePath, items, { spaces: 2 });
        console.log(`已更新: ${year}/${monthFile}`);
      }
    }
  }
  console.log(`\n合并完成！共更新 ${totalUpdated} 条 site 记录。`);
}

merge();
