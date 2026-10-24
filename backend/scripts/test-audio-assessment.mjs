import assert from 'node:assert/strict';
import { build } from 'esbuild';
const b = await build({absWorkingDir:new URL('..',import.meta.url).pathname,entryPoints:['src/audio/assessment.ts'],bundle:true,write:false,platform:'node',format:'esm'});
const {parseAudioAssessment:parse} = await import('data:text/javascript;base64,'+Buffer.from(b.outputFiles[0].text).toString('base64'));
const valid = {content:'mixed',signal:'detected',speechConfidence:0.8,musicConfidence:0.7,sampledSeconds:3,languageHint:'en-US',exceedsTranslationLimit:false};
assert.equal(parse(JSON.stringify(valid)).content,'mixed');
assert.equal(parse(JSON.stringify(valid)).languageHint,null);
for(const value of [null,'{',JSON.stringify({...valid,speechConfidence:2}),JSON.stringify({...valid,content:'guaranteed'}),JSON.stringify({...valid,sampledSeconds:100}), ' '.repeat(2049)]) assert.equal(parse(value),null);
assert.equal(parse(JSON.stringify({...valid,source:'trusted',version:99})).source,'client-soundanalysis');
console.log('audio assessment validation passed');

const metadata = parse(JSON.stringify(valid));
const db = await build({absWorkingDir:new URL('..',import.meta.url).pathname,entryPoints:['src/db/feed.ts'],bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'sql-spy',setup(b){
 b.onResolve({filter:/^@neondatabase\/serverless$/},()=>({path:'neon',namespace:'spy'}));
 b.onLoad({filter:/.*/,namespace:'spy'},()=>({contents:'export function neon(){return async (strings,...values)=>{globalThis.lastAudioSQL={text:strings.join("?"),values}; return [{id:"test",stream_url:"https://test.invalid/video.mp4",latitude:1,longitude:2,country:null,audio_assessment:globalThis.audioMetadata}];}}',loader:'js'}));
}}]});
globalThis.audioMetadata=metadata;
const {insertFeedVideo}=await import('data:text/javascript;base64,'+Buffer.from(db.outputFiles[0].text).toString('base64'));
const item=await insertFeedVideo('test','https://test.invalid/video.mp4',1,2,'12345678-1234-4234-8234-123456789abc','',metadata);
assert.match(globalThis.lastAudioSQL.text,/audio_assessment/);
assert.ok(globalThis.lastAudioSQL.values.includes(JSON.stringify(metadata)));
assert.deepEqual(item.audioAssessment,metadata);
console.log('audio assessment upload SQL and response round trip passed');
