import fs from 'node:fs';
import path from 'node:path';
import { createInterface } from 'node:readline';
const command = process.argv[2];
const profile = process.argv[process.argv.indexOf('--profile') + 1];
const file = name => path.join(profile, name);
const emit = object => console.log(JSON.stringify(object));
if(command==='doctor')emit({ok:true});
else if(command==='init'){fs.mkdirSync(profile,{recursive:true});fs.writeFileSync(file('mydrive-profile.json'),'{}');emit({ok:true});}
else if(command==='serve'||command==='desktop-serve'){
  const desktop = command === 'desktop-serve';
  fs.writeFileSync(file('host-pid'),String(process.pid));emit({ok:true,event:'host_ready',poll_pipe:true});
  const reader = createInterface({input:process.stdin});
  reader.on('line',line=>{
    if(line==='STOP'){fs.writeFileSync(file('clean-stop'),command);process.exit(0);}
    const request=/^POLL ([0-9a-f]{32})$/.exec(line);
    if(request)emit({ok:true,event:'poll_result',request_id:request[1],
      status:{authenticated:desktop,desktop_session:desktop,native_auto_accept_disabled:false},devices:[],transfers:[]});
  });
  reader.on('close',()=>process.exit(0));
}
else if(command==='status'){
  if(fs.existsSync(file('stall-status')))setInterval(()=>{},1000);
  else emit({ok:true,authenticated:process.argv.includes('--socket'),desktop_session:process.argv.includes('--socket'),native_auto_accept_disabled:false,registration:'NOT_STARTED'});
}
else if(command==='devices')emit({ok:true,devices:[]});
else if(command==='search'){
  const query=fs.readFileSync(0,'utf8').trim();
  emit({ok:true,devices:query.toLowerCase()==='fixture@example.test'
    ? [{peer:'33333333-3333-4333-8333-333333333333:44444444-4444-4444-8444-444444444444',
        user_name:'Fixture contact', contact:'fixture@example.test'}] : []});
}
else if(command==='transfers')emit({ok:true,transfers:[]});
else if(command==='poll'){
  fs.writeFileSync(file('standalone-poll'), '');
  emit({ok:true,status:{authenticated:process.argv.includes('--socket'),desktop_session:process.argv.includes('--socket'),native_auto_accept_disabled:false},devices:[],transfers:[]});
}
else if(command==='accept'||command==='accept-manual'){
  fs.writeFileSync(file('last-accept-command'),command+':'+(process.argv.includes('--socket')?'desktop':'separate'));
  if(fs.existsSync(file('fail-accept'))){emit({ok:false,error:'acceptance_unconfirmed',native_status:'Invited'});process.exitCode=1;}
  else emit({ok:true,phase:'receiving_confirmed',native_status:'Pending'});
}
else if(command==='send'){
  const count=fs.existsSync(file('send-count'))?Number(fs.readFileSync(file('send-count'))):0;
  fs.writeFileSync(file('send-count'),String(count+1));
  if(fs.existsSync(file('fail-send'))){emit({ok:false,error:'uncertain'});process.exitCode=1;}
  else emit({ok:true,phase:'dispatch_requested',transfer_id:'33333333-3333-4333-8333-333333333333',completed:false});
}
else emit({ok:true});
