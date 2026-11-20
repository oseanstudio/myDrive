import fs from 'node:fs';
import path from 'node:path';
const root=path.resolve(process.argv[2]??'.');
const findings=[]; let count=0;
const forbiddenDirs=new Set(['.tools','.runtime','.profiles','.zcode','.stversions','node_modules','target','bin','obj']);
const rules=[['studio machine path',/\b[A-Z]:[/\\]+OSEAN[ _]+(?:APP[ _]+DATA|STUDIO[ _]+APPS)\b/i],['access token',/\b(?:gh[pousr]_[A-Za-z0-9]{24,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16})\b/],['private key',/-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----/],['personal tailnet',/\b[\w.-]+\.tail(?!net\.)[a-z0-9]+\.ts\.net\b/],['personal Windows path',/[A-Z]:\\(?:\\)?Users\\(?:\\)?(?!YourName\b|user\b|test\b|Public\b)[^\\\s"']+/i],['personal Mac path',/\/Users\/(?!you\b|test\b|Shared\b|runner\b)[^/\s"']+/]];
function walk(dir){for(const item of fs.readdirSync(dir,{withFileTypes:true})){
 const file=path.join(dir,item.name),relative=path.relative(root,file).replaceAll('\\','/');
 if(item.name==='.git')continue;
 if(item.isSymbolicLink()){findings.push([relative,'symlink']);continue;}
 if(item.isDirectory()){if(forbiddenDirs.has(item.name))findings.push([relative,'machine-data directory']);else walk(file);continue;}
 count++;
 if(item.name.startsWith('._')||/\.(?:exe|dll|dylib|dmg|appimage|apk|ipa|p12|pfx|key|jks|keystore|lnk|zip|7z|tar|gz|db|sqlite|dmp)$/i.test(item.name)||/^(?:\.stignore|\.DS_Store|state\.dat|bookmarks\.json|connections\.json|preferences\.json|config\.xml|auth\.json|credentials\.json|sender-catalog\.json|link-claims\.json|project-root\.txt)$|\.(?:cany|log|jsonl)$/i.test(item.name))findings.push([relative,'private or generated binary']);
 if(/\.jar$/i.test(item.name)&&relative!=='Mobile/Android/gradle/wrapper/gradle-wrapper.jar')findings.push([relative,'unapproved packaged code']);
 if(/\.(?:png|ico|jar)$/i.test(item.name))continue;
 const text=fs.readFileSync(file,'utf8');
 for(const [name,rule]of rules)if(rule.test(text))findings.push([relative,name]);
}}
walk(root);
console.log(JSON.stringify({filesChecked:count,findings},null,2));
if(findings.length)process.exitCode=1;
