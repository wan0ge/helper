const youtube = require('./youtube.js');
const { matchBangumi } = require('../utils.js');

const channelUrl = "https://www.youtube.com/@MightyMedia99";
const channelId = "UCCrpNwDnc_ULP3tjUQsCkag";

exports.getAll = async function getAll() {
  const parseTitle = (title) => {
    const found = /《(.*)》([^|｜]*)/.exec(title);
    if (found) {
      return {
        'zh-Hant': [`${found[1]} ${found[2]}`.trim()],
      }
    }
    return { 'zh-Hant': [title] };
  }
  return await youtube.getAll(channelId, parseTitle);
};

exports.getBegin = async function getBegin(id) {
  return await youtube.getBegin(id);
};

exports.matchBangumi = async (input, items) => {
  return matchBangumi(input, { items });
}

exports.getIsBangumiOffline = async (id) => {
  return await youtube.getIsBangumiOffline(id);
}
