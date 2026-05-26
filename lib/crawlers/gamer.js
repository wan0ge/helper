const gamerCommon = require('./gamer_common.js');

exports.getAll = async function getAll() {
    const items = await gamerCommon.getAllBangumi('TW', 1);
    return items.map((item) => ({
        id: `${item.id}`,
        video_sn: item.video_sn || '',
        titleTranslate: item.titleTranslate,
        img: item.img,
        href: `https://ani.gamer.com.tw/animeRef.php?sn=${item.id}`,
    }));
};

exports.getBegin = async function getBegin(id) {
    return gamerCommon.getBegin(id);
};

exports.matchBangumi = async function matchBangumi(input, items) {
    return gamerCommon.matchBangumi(input, items);
};

exports.getIsBangumiOffline = async (id) => {
    return gamerCommon.getIsBangumiOffline(id);
}
