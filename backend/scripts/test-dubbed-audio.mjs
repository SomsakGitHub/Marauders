import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {SignJWT} from 'jose';
import {webcrypto} from 'node:crypto';
import {readFileSync} from 'node:fs';
globalThis.crypto ??= webcrypto;
const source='https://api.example/v1/media/videos/11111111-1111-4111-8111-111111111111.mp4';
globalThis.audioSource=source;
const bundle=await build({entryPoints:['src/index.ts'],bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'sql',setup(build){
 build.onResolve({filter:/^@neondatabase\/serverless$/},()=>({path:'sql',namespace:'fake'}));
 build.onLoad({filter:/.*/,namespace:'fake'},()=>({contents:`export function neon(){return async(strings,...values)=>{const q=strings.join('?');if(globalThis.fakeSql){const r=globalThis.fakeSql(q,values);if(r)return r;}if(q.includes('rate_limit_counters')) return [{count:1}];if(q.includes('SELECT stream_url')) return globalThis.audioSource ? [{stream_url:globalThis.audioSource}] : [];return [];};}`}));
}}]});
const {default:worker}=await import('data:text/javascript;base64,'+Buffer.from(bundle.outputFiles[0].text).toString('base64'));
const core=await build({entryPoints:['src/audio/cache.ts'],bundle:true,write:false,platform:'node',format:'esm'});
const {sourceHash,validateDubbedAudio,readAudioBody,DUBBED_AUDIO_MAX_BYTES,parseDubbingLanguage,audioKey,DUBBING_LANGUAGES}=await import('data:text/javascript;base64,'+Buffer.from(core.outputFiles[0].text).toString('base64'));
const cleanup=await build({entryPoints:['src/routes/dubbedAudio.ts'],bundle:true,write:false,platform:'node',format:'esm'});
const {deleteDubbedAudio}=await import('data:text/javascript;base64,'+Buffer.from(cleanup.outputFiles[0].text).toString('base64'));
const secret='shared-audio-test-secret-with-at-least-32-characters';
const id='11111111-1111-4111-8111-111111111111';
async function token(user){return new SignJWT({}).setProtectedHeader({alg:'HS256'}).setSubject(user).setExpirationTime('1h').sign(new TextEncoder().encode(secret));}
const a=await token('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
const b=await token('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
const objects=new Map();const metas=new Map();let writes=0;let lastPut=null;
const bucket={
 async head(key){const value=objects.get(key);return value?{key,size:value.length,customMetadata:metas.get(key)}:null;},
 async put(key,body,options){writes++;lastPut={key,options};assert.equal(options.onlyIf.get('If-None-Match'),'*');if(objects.has(key))return null;objects.set(key,new Uint8Array(body));metas.set(key,options.customMetadata);return {key};},
 async delete(keys){for(const key of Array.isArray(keys)?keys:[keys])objects.delete(key);},
 async list({prefix}){return {objects:[...objects.keys()].filter(k=>k.startsWith(prefix)).map(key=>({key})),truncated:false};}
};
const env={DATABASE_URL:'test',JWT_SIGNING_SECRET:secret,VIDEOS:bucket};
const hash=await sourceHash(source);
async function request(method='GET',{auth,body,sourceHash: supplied=hash,type='audio/mp4',lang='th',legacy=false,omitLang=false}={}){
 const headers={};if(auth)headers.Authorization='Bearer '+auth;
 if(method==='POST'){headers['X-Source-SHA256']=supplied;headers['Content-Type']=type;}
 const query=new URLSearchParams();if(method==='GET')query.set('source',supplied);if(!legacy&&!omitLang)query.set('lang',lang);
 const url='https://api.example/v1/videos/'+id+(legacy?'/thai-audio':'/dubbed-audio')+(query.size?'?'+query:'');
 return worker.fetch(new Request(url,{method,headers,body}),env);
}
function atom(name,body){const size=Buffer.alloc(4);size.writeUInt32BE(body.length+8);return Buffer.concat([size,Buffer.from(name),body]);}
function audio({duration=1,handler='soun',codec='mp4a'}={}){
 const mvhd=Buffer.alloc(24);mvhd.writeUInt32BE(1000,12);mvhd.writeUInt32BE(duration*1000,16);
 const hdlr=Buffer.concat([Buffer.alloc(8),Buffer.from(handler),Buffer.alloc(8)]);
 const stsd=Buffer.concat([Buffer.alloc(4),Buffer.from([0,0,0,1]),atom(codec,Buffer.alloc(8))]);
 return Buffer.concat([atom('ftyp',Buffer.from('M4A \x00\x00\x00\x00M4A ')),atom('moov',Buffer.concat([atom('mvhd',mvhd),atom('trak',atom('mdia',Buffer.concat([atom('hdlr',hdlr),atom('minf',atom('stbl',atom('stsd',stsd)))])))])),atom('mdat',Buffer.from([1,2,3,4]))]);
}
assert.equal((await request('POST',{body:audio()})).status,401);
assert.equal((await request('GET',{auth:'invalid'})).status,401);
assert.equal((await request('GET')).status,200);
assert.equal((await (await request('GET')).json()).status,'missing');
assert.equal((await request('POST',{auth:a,body:audio(),sourceHash:'0'.repeat(64)})).status,409);
assert.equal(objects.size,0);
const first=await request('POST',{auth:a,body:audio()});assert.equal(first.status,200);
const published=await first.json();assert.equal(published.kind,'ai_translation');assert.equal(objects.size,1);
for(const auth of [undefined,a,b])assert.equal((await (await request('GET',{auth})).json()).audioURL,published.audioURL);
const before=writes;await request('POST',{auth:b,body:audio()});assert.equal(writes,before,'existing audio must not be rewritten');
objects.clear();writes=0;
const results=await Promise.all([request('POST',{auth:a,body:audio()}),request('POST',{auth:b,body:audio()})]);
assert.ok(results.every(r=>r.status===200));assert.equal(objects.size,1,'concurrent completions share one immutable object');
objects.clear();
validateDubbedAudio(audio({duration:600}));
for(const invalid of [Buffer.from('not audio'),audio({duration:0}),audio({handler:'vide'}),audio({codec:'enca'}),audio().subarray(0,50)]){
 assert.throws(()=>validateDubbedAudio(invalid));
 assert.equal((await request('POST',{auth:a,body:invalid})).status,422);assert.equal(objects.size,0);
}
assert.equal((await request('POST',{auth:a,body:audio(),type:'text/html'})).status,415);
let canceled=false;
const streamed=new ReadableStream({start(controller){controller.enqueue(new Uint8Array(DUBBED_AUDIO_MAX_BYTES+1));},cancel(){canceled=true;}});
await assert.rejects(()=>readAudioBody(new Request('https://api.example',{method:'POST',body:streamed,duplex:'half'})));assert.equal(canceled,true);
globalThis.audioSource=source+'?revision=2';
assert.equal((await request('GET')).status,409,'old source cannot reuse a different clip revision');
assert.equal((await request('POST',{auth:a,body:audio(),sourceHash:await sourceHash(globalThis.audioSource)})).status,200);
objects.set('translations/22222222-2222-4222-8222-222222222222/other.m4a',new Uint8Array([1]));
await deleteDubbedAudio(bucket,id);assert.equal(objects.size,1,'deletion must only remove this clip cache');
globalThis.audioSource=null;
assert.equal((await request('GET')).status,404);
globalThis.audioSource=source;
objects.clear();

// Listening languages: each language is cached on its own, Thai keeps its original key, and the legacy path serves Thai.
assert.deepEqual(DUBBING_LANGUAGES.filter(l=>parseDubbingLanguage(l)!==l),[]);
// The app's listening-language list and this allow-list must not drift apart.
const swift=readFileSync(new URL('../../Marauders-ios/Marauders/Domain/Entities/ListeningLanguage.swift',import.meta.url),'utf8');
const appCodes=[...swift.match(/static let codes = \[([^\]]*)\]/s)[1].matchAll(/"([a-z]{2,3})"/g)].map(m=>m[1]);
assert.deepEqual([...appCodes].sort(),[...DUBBING_LANGUAGES].sort(),'iOS ListeningLanguage.codes must match DUBBING_LANGUAGES');
assert.equal(parseDubbingLanguage('EN'),'en');assert.equal(parseDubbingLanguage(' th '),'th');
for(const bad of [null,undefined,'','xx','eng','th/es','../th','en-US','yue'])assert.equal(parseDubbingLanguage(bad),null,String(bad));
assert.equal(audioKey(id.toUpperCase(),hash,'th'),`translations/${id}/${hash}-th-v1.m4a`);
const thai=await (await request('POST',{auth:a,body:audio(),lang:'th'})).json();
assert.equal(thai.language,'th');assert.ok(thai.audioURL.endsWith(`/v1/media/translations/${id}/${hash}-th-v1.m4a`));
assert.equal(lastPut.options.customMetadata.language,'th');
assert.equal((await (await request('GET',{lang:'es'})).json()).status,'missing','Thai audio must not be served for another language');
const spanish=await (await request('POST',{auth:b,body:audio(),lang:'es'})).json();
assert.equal(spanish.language,'es');assert.ok(spanish.audioURL.endsWith(`-es-v1.m4a`));assert.notEqual(spanish.audioURL,thai.audioURL);
assert.equal(lastPut.options.customMetadata.language,'es');assert.equal(objects.size,2);
assert.equal((await (await request('GET',{lang:'ES'})).json()).audioURL,spanish.audioURL,'language codes are case-insensitive');
assert.equal((await (await request('GET',{legacy:true})).json()).audioURL,thai.audioURL,'legacy Thai path shares the Thai object');
const legacyWrites=writes;assert.equal((await request('POST',{auth:a,body:audio(),legacy:true})).status,200);assert.equal(writes,legacyWrites,'legacy upload must not rewrite existing Thai audio');
objects.clear();
const legacyFirst=await (await request('POST',{auth:a,body:audio(),legacy:true})).json();
assert.equal(legacyFirst.language,'th');assert.equal(lastPut.options.customMetadata.language,'th');
assert.equal((await (await request('GET',{lang:'th'})).json()).audioURL,legacyFirst.audioURL,'legacy upload is readable through the new path');
for(const bad of ['xx','','eng','th%2Fes','yue'])for(const method of ['GET','POST']){
 const before=objects.size;
 const url='https://api.example/v1/videos/'+id+'/dubbed-audio?lang='+bad+(method==='GET'?'&source='+hash:'');
 const headers={Authorization:'Bearer '+a,'X-Source-SHA256':hash,'Content-Type':'audio/mp4'};
 const response=await worker.fetch(new Request(url,{method,headers,body:method==='POST'?audio():undefined}),env);
 assert.equal(response.status,400,bad+' '+method);assert.equal(objects.size,before);
}
assert.equal((await request('GET',{omitLang:true})).status,400,'new path requires a language');
assert.equal((await request('POST',{auth:a,body:audio(),omitLang:true})).status,400);
assert.equal((await request('POST',{auth:a,body:audio(),lang:'EN'})).status,200,'upper-case codes are normalized');
assert.ok([...objects.keys()].some(k=>k.endsWith(`${hash}-en-v1.m4a`)));
objects.set('translations/'+id+'/stale-fr-v1.m4a',new Uint8Array([1]));
await deleteDubbedAudio(bucket,id);assert.equal([...objects.keys()].filter(k=>k.startsWith('translations/'+id+'/')).length,0,'deleting a clip removes every language');
// The media route must serve what the cache route hands out, for every language and nothing else.
const media=await build({entryPoints:['src/validation.ts'],bundle:true,write:false,platform:'node',format:'esm'});
const {assertMediaObjectKey}=await import('data:text/javascript;base64,'+Buffer.from(media.outputFiles[0].text).toString('base64'));
for(const language of DUBBING_LANGUAGES)assert.doesNotThrow(()=>assertMediaObjectKey(audioKey(id,hash,language)),language);
for(const bad of [`translations/${id}/${hash}-xx-v1.m4a`,`translations/${id}/${hash}-EN-v1.m4a`,`translations/${id}/${hash}-en-v2.m4a`,`translations/${id}/${hash.slice(1)}-en-v1.m4a`,`translations/${id}/${hash}-en-v1.mp4`,`translations/${id}/nested/${hash}-en-v1.m4a`,`translations/not-an-id/${hash}-en-v1.m4a`,`translations/${id}/${hash}-th|en-v1.m4a`])assert.throws(()=>assertMediaObjectKey(bad),bad);
// End to end: a language other than Thai is uploaded, then its audioURL is actually served.
objects.clear();
const dubbed=await (await request('POST',{auth:a,body:audio(),lang:'es'})).json();
const mediaPath=new URL(dubbed.audioURL).pathname;
const stored=objects.get(audioKey(id,hash,'es'));
bucket.get=async(key)=>{const value=objects.get(key);return value?{body:new Blob([value]).stream()}:null;};
const served=await worker.fetch(new Request('https://api.example'+mediaPath),env);
assert.equal(served.status,200,'dubbed audio in a non-Thai language must be playable');
assert.equal(served.headers.get('content-type'),'audio/mp4');
assert.equal(new Uint8Array(await served.arrayBuffer()).length,stored.length);
assert.equal((await worker.fetch(new Request('https://api.example/v1/media/translations/'+id+'/'+hash+'-xx-v1.m4a'),env)).status,400);

// ---- Reporting a bad shared dub ----
const owner='cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const ownerToken=await token(owner);
const reportRows=new Set();const sqlLog=[];
globalThis.owner=owner;
globalThis.fakeSql=(q,v)=>{
 sqlLog.push([q,v]);
 if(q.includes('SELECT stream_url')&&q.includes('owner_user_id'))return globalThis.audioSource?[{stream_url:globalThis.audioSource,owner_user_id:globalThis.owner}]:[];
 if(q.includes('INSERT INTO dubbed_audio_reports')){reportRows.add(v.join('|'));return [];}
 if(q.includes('SELECT COUNT(*)')&&q.includes('dubbed_audio_reports')){const p=v.slice(0,3).join('|')+'|';return [{reports:String([...reportRows].filter(r=>r.startsWith(p)).length)}];}
 if(q.includes('DELETE FROM dubbed_audio_reports')){const p=v.slice(0,3).join('|')+'|';for(const r of [...reportRows])if(r.startsWith(p))reportRows.delete(r);return [];}
 return null;
};
const c=await token('dddddddd-dddd-4ddd-8ddd-dddddddddddd');
async function report({auth,lang='th',supplied=hash,video=id,omitHash=false}={}){
 const headers={};if(auth)headers.Authorization='Bearer '+auth;if(!omitHash)headers['X-Source-SHA256']=supplied;
 return worker.fetch(new Request('https://api.example/v1/videos/'+video+'/dubbed-audio/report?lang='+lang,{method:'POST',headers}),env);
}
async function text(user,lang='th'){return worker.fetch(new Request('https://api.example/v1/videos/'+id+'/dubbed-audio?lang='+lang+'&kind=text',{method:'POST',headers:{Authorization:'Bearer '+user,'X-Source-SHA256':hash,'Content-Type':'text/plain'},body:'hello'}),env);}
const textObjectKey=audioKey(id,hash,'th').replace(/\.m4a$/,'.txt');
async function got(lang='th'){return (await request('GET',{lang})).json();}
objects.clear();metas.clear();globalThis.audioSource=source;
assert.equal((await report()).status,401);
assert.equal((await report({auth:'invalid'})).status,401);
assert.equal((await report({auth:a,lang:'xx'})).status,400);
assert.equal((await report({auth:a,video:'not-a-uuid'})).status,400);
assert.equal((await report({auth:a,supplied:'0'.repeat(64)})).status,409);
assert.equal((await report({auth:a,omitHash:true})).status,409);
globalThis.audioSource=null;assert.equal((await report({auth:a})).status,404);globalThis.audioSource=source;
const none=await report({auth:a});assert.equal(none.status,200);assert.equal(none.headers.get('cache-control'),'no-store');assert.deepEqual(await none.json(),{status:'missing'});
// Uploaded by A: strangers B and C need two reports.
assert.equal((await request('POST',{auth:a,body:audio()})).status,200);assert.equal((await text(a)).status,200);
assert.ok(objects.has(textObjectKey));
assert.deepEqual(await (await report({auth:b})).json(),{status:'reported',reports:1});
assert.equal((await got()).status,'ready','one stranger report keeps the audio');
assert.deepEqual(await (await report({auth:b})).json(),{status:'reported',reports:1},'the same user twice counts once');
assert.equal(reportRows.size,1);
assert.deepEqual(await (await report({auth:c})).json(),{status:'removed'});
assert.equal(objects.size,0,'audio and subtitle text are both deleted');assert.equal(reportRows.size,0,'report rows are cleared');
assert.equal((await got()).status,'missing');
// Replacement upload works after removal and starts with a clean report count.
assert.equal((await request('POST',{auth:b,body:audio()})).status,200);assert.equal((await got()).status,'ready');
assert.deepEqual(await (await report({auth:c})).json(),{status:'reported',reports:1});
// Other languages are independent.
assert.equal((await (await report({auth:c,lang:'es'})).json()).status,'missing');
objects.clear();metas.clear();reportRows.clear();
// The clip owner removes at once.
await request('POST',{auth:a,body:audio()});await text(a);
assert.deepEqual(await (await report({auth:ownerToken})).json(),{status:'removed'});assert.equal(objects.size,0);
// The uploader removes at once.
await request('POST',{auth:b,body:audio()});
assert.deepEqual(await (await report({auth:b})).json(),{status:'removed'});assert.equal(objects.size,0);assert.equal(reportRows.size,0);
// Rate limit scope.
sqlLog.length=0;await report({auth:a});
assert.ok(sqlLog.some(([q,v])=>q.includes('rate_limit_counters')&&v.some(x=>String(x).includes('dubbed-audio-report'))),'report uses the dubbed-audio-report rate-limit scope');
globalThis.fakeSql=null;
console.log('Dubbed audio cache passed: auth, shared reuse per language, legacy Thai path, first-write concurrency, source revisions, bounded AAC validation and scoped deletion, and reporting bad dubs.');
