const fs = require('fs-extra');
const path = require('path');

const BANGUMI_DATA = path.resolve(__dirname, '../bangumi-data/data/items');
const CRAWLED = path.resolve(__dirname, 'data/items/0000');

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
          
          // 精确匹配 site 名称
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
    }
  }
  console.log(`\n合并完成！共更新 ${totalUpdated} 条 site 记录。`);
}

merge();
