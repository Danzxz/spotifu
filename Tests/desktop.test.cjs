const assert = require('node:assert/strict');
const { findLocalTrack } = require('../desktop/spotifu.js');
const saved = {title:'Song', artist:'Artist', duration:200};
const right = {uri:'spotify:local:Artist:Spotifu:Song:200', name:'Song', artists:[{name:'Artist'}], album:{name:'Spotifu'}, duration:{milliseconds:200000}};
assert.equal(findLocalTrack(saved,[right]),right);
assert.equal(findLocalTrack(saved,[{...right,name:'Song Live'}]),null);
assert.equal(findLocalTrack(saved,[{...right,album:{name:'Other'}}]),null);
assert.equal(findLocalTrack(saved,[{...right,duration:{milliseconds:230000}}]),null);
console.log('Native Spotify local-track matching tests passed');

const {downloadRequest}=require('../desktop/spotifu.js');
assert.deepEqual(downloadRequest({uri:'spotify:track:abc',name:'Song',artists:{items:[{profile:{name:'Artist'}}]},duration:{totalMilliseconds:200000}}),{id:'abc',title:'Song',artist:'Artist',duration:200});
