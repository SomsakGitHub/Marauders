import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {SignJWT} from 'jose';
import {webcrypto} from 'node:crypto';
globalThis.crypto ??= webcrypto;
const source='https://api.example/v1/media/videos/11111111-1111-4111-8111-111111111111.mp4';
globalThis.audioSource=source;
const bundle=await build({entryPoints:['src/index.ts'],bundle:true,write:false,platform:'node',format:'esm',plugins:[{name:'sql',setup(build){
 build.onResolve({filter:/^@neondatabase\/serverless$/},()=>({path:'sql',namespace:'fake'}));
 build.onLoad({filter:/.*/,namespace:'fake'},()=>({contents:`export function neon(){return async(strings,...values)=>{const q=strings.join('?');if(q.includes('rate_limit_counters')) return [{count:1}];if(q.includes('SELECT stream_url')) return globalThis.audioSource ? [{stream_url:globalThis.audioSource}] : [];return [];};}`}));
}}]});
const {default:worker}=await import('data:text/javascript;base64,'+Buffer.from(bundle.outputFiles[0].text).toString('base64'));
const core=await build({entryPoints:['src/audio/cache.ts'],bundle:true,write:false,platform:'node',format:'esm'});
const {sourceHash,validateThaiAudio,readAudioBody,THAI_AUDIO_MAX_BYTES}=await import('data:text/javascript;base64,'+Buffer.from(core.outputFiles[0].text).toString('base64'));
const cleanup=await build({entryPoints:['src/routes/thaiAudio.ts'],bundle:true,write:false,platform:'node',format:'esm'});
const {deleteThaiAudio}=await import('data:text/javascript;base64,'+Buffer.from(cleanup.outputFiles[0].text).toString('base64'));
const secret='shared-audio-test-secret-with-at-least-32-characters';
const id='11111111-1111-4111-8111-111111111111';
async function token(user){return new SignJWT({}).setProtectedHeader({alg:'HS256'}).setSubject(user).setExpirationTime('1h').sign(new TextEncoder().encode(secret));}
const a=await token('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
const b=await token('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
const objects=new Map();let writes=0;
const bucket={
 async head(key){const value=objects.get(key);return value?{key,size:value.length}:null;},
 async put(key,body,options){writes++;assert.equal(options.onlyIf.get('If-None-Match'),'*');if(objects.has(key))return null;objects.set(key,new Uint8Array(body));return {key};},
 async delete(keys){for(const key of Array.isArray(keys)?keys:[keys])objects.delete(key);},
 async list({prefix}){return {objects:[...objects.keys()].filter(k=>k.startsWith(prefix)).map(key=>({key})),truncated:false};}
};
const env={DATABASE_URL:'test',JWT_SIGNING_SECRET:secret,VIDEOS:bucket};
const hash=await sourceHash(source);
async function request(method='GET',{auth,body,sourceHash: supplied=hash,type='audio/mp4'}={}){
 const headers={};if(auth)headers.Authorization='Bearer '+auth;
 if(method==='POST'){headers['X-Source-SHA256']=supplied;headers['Content-Type']=type;}
 const url='https://api.example/v1/videos/'+id+'/thai-audio'+(method==='GET'?'?source='+supplied:'');
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
validateThaiAudio(audio({duration:600}));
for(const invalid of [Buffer.from('not audio'),audio({duration:0}),audio({handler:'vide'}),audio({codec:'enca'}),audio().subarray(0,50)]){
 assert.throws(()=>validateThaiAudio(invalid));
 assert.equal((await request('POST',{auth:a,body:invalid})).status,422);assert.equal(objects.size,0);
}
assert.equal((await request('POST',{auth:a,body:audio(),type:'text/html'})).status,415);
let canceled=false;
const streamed=new ReadableStream({start(controller){controller.enqueue(new Uint8Array(THAI_AUDIO_MAX_BYTES+1));},cancel(){canceled=true;}});
await assert.rejects(()=>readAudioBody(new Request('https://api.example',{method:'POST',body:streamed,duplex:'half'})));assert.equal(canceled,true);
globalThis.audioSource=source+'?revision=2';
assert.equal((await request('GET')).status,409,'old source cannot reuse a different clip revision');
assert.equal((await request('POST',{auth:a,body:audio(),sourceHash:await sourceHash(globalThis.audioSource)})).status,200);
objects.set('translations/22222222-2222-4222-8222-222222222222/other.m4a',new Uint8Array([1]));
await deleteThaiAudio(bucket,id);assert.equal(objects.size,1,'deletion must only remove this clip cache');
globalThis.audioSource=null;
assert.equal((await request('GET')).status,404);
console.log('Thai audio cache passed: auth, shared reuse, first-write concurrency, source revisions, bounded AAC validation and scoped deletion.');
