import Foundation

enum DeveloperLiveInterceptorScript {
    static let disable = #"""
    (() => {
      const bridge = window.__contextPortLiveInterceptorV1;
      if (bridge) bridge.enabled = false;
      return true;
    })();
    """#

    static func installAndDrain(captureBodyPreviews: Bool) -> String {
        let enabled = captureBodyPreviews ? "true" : "false"
        return source.replacingOccurrences(of: "__CAPTURE_BODIES__", with: enabled)
    }

    private static let source = #"""
    (() => {
      const KEY='__contextPortLiveInterceptorV1', MAX=500, PREVIEW=8192, RESPONSE=65536;
      const old=window[KEY];
      if(old&&old.version===1){old.enabled=true;old.captureBodies=__CAPTURE_BODIES__;return JSON.stringify(old.drain());}

      const b={version:1,enabled:true,captureBodies:__CAPTURE_BODIES__,sequence:0,buffer:[],dropped:0,
        id(prefix){this.sequence+=1;return `${prefix}-${Date.now()}-${this.sequence}`;},
        text(value,max=PREVIEW){if(value===undefined||value===null)return null;const s=String(value);return s.length<=max?s:`${s.slice(0,max)}\n… [truncated by ContextPort]`;},
        body(value){if(!this.captureBodies||value===undefined||value===null)return null;try{
          if(typeof value==='string')return this.text(value);
          if(value instanceof URLSearchParams)return this.text(value.toString());
          if(typeof FormData!=='undefined'&&value instanceof FormData){const a=[];for(const [k,v] of value.entries())a.push(typeof File!=='undefined'&&v instanceof File?`${k}=[File ${v.name} ${v.type||'unknown'} ${v.size} bytes]`:`${k}=${String(v)}`);return this.text(a.join('&'));}
          if(typeof Blob!=='undefined'&&value instanceof Blob)return `[Blob ${value.type||'unknown'} ${value.size} bytes]`;
          if(value instanceof ArrayBuffer)return `[ArrayBuffer ${value.byteLength} bytes]`;
          if(ArrayBuffer.isView(value))return `[TypedArray ${value.byteLength} bytes]`;
          return this.text(JSON.stringify(value));
        }catch(_){return `[${Object.prototype.toString.call(value)}]`; }},
        push(event){if(!this.enabled)return;const e=Object.assign({id:this.id(event.kind||'event'),timestamp:Date.now(),phase:'event'},event||{});if(this.buffer.length>=MAX){this.buffer.shift();this.dropped+=1;}this.buffer.push(e);},
        drain(){const out={events:this.buffer.splice(0),dropped:this.dropped};this.dropped=0;return out;}
      };
      window[KEY]=b;
      const url=v=>b.text(v,4096)||'', err=e=>b.text(e&&(e.stack||e.message||e),4096);

      try{if(typeof window.fetch==='function'){
        const nativeFetch=window.fetch;
        window.fetch=function(input,init){let u='',m='GET',body=null;try{if(typeof Request!=='undefined'&&input instanceof Request){u=input.url||'';m=(init&&init.method)||input.method||'GET';}else{u=String(input||'');m=(init&&init.method)||'GET';}body=b.body(init&&init.body);}catch(_){}
          const id=b.id('fetch'), started=performance.now();m=String(m).toUpperCase();b.push({id,kind:'fetch',phase:'request',method:m,url:url(u),requestBody:body});
          return Reflect.apply(nativeFetch,this,arguments).then(response=>{const type=response.headers&&response.headers.get?response.headers.get('content-type'):null;const length=response.headers&&response.headers.get?Number(response.headers.get('content-length')||0):0;
            b.push({id:`${id}-response`,kind:'fetch',phase:'response',method:m,url:url(response.url||u),status:response.status,duration:performance.now()-started,mimeType:b.text(type,256),transferSize:length>0?length:null});
            if(b.captureBodies&&length>0&&length<=RESPONSE&&type&&!/text\/event-stream/i.test(type)&&/(json|text|xml|javascript|html|css)/i.test(type)){try{response.clone().text().then(text=>b.push({id:`${id}-body`,kind:'fetch',phase:'body',method:m,url:url(response.url||u),status:response.status,mimeType:b.text(type,256),responseBody:b.text(text,RESPONSE)})).catch(()=>{});}catch(_){}}
            return response;
          },error=>{b.push({id:`${id}-error`,kind:'fetch',phase:'error',method:m,url:url(u),duration:performance.now()-started,detail:err(error)});throw error;});
        };
      }}catch(_){}

      try{if(typeof XMLHttpRequest!=='undefined'){
        const states=new WeakMap(), open=XMLHttpRequest.prototype.open, send=XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open=function(method,target){states.set(this,{id:b.id('xhr'),method:String(method||'GET').toUpperCase(),url:url(target),started:0,listeners:false});return Reflect.apply(open,this,arguments);};
        XMLHttpRequest.prototype.send=function(body){const s=states.get(this)||{id:b.id('xhr'),method:'GET',url:'',started:0,listeners:false};s.started=performance.now();states.set(this,s);b.push({id:s.id,kind:'xhr',phase:'request',method:s.method,url:s.url,requestBody:b.body(body)});
          if(!s.listeners){s.listeners=true;this.addEventListener('loadend',()=>{let responseBody=null,type=null;try{if(b.captureBodies&&(this.responseType===''||this.responseType==='text')&&typeof this.responseText==='string'&&this.responseText.length<=RESPONSE)responseBody=b.text(this.responseText,RESPONSE);}catch(_){}try{type=this.getResponseHeader('content-type');}catch(_){}
            b.push({id:`${s.id}-response`,kind:'xhr',phase:'response',method:s.method,url:url(this.responseURL||s.url),status:Number(this.status)||null,duration:performance.now()-s.started,mimeType:b.text(type,256),responseBody});},{once:true});
            this.addEventListener('error',()=>b.push({id:`${s.id}-error`,kind:'xhr',phase:'error',method:s.method,url:s.url,duration:performance.now()-s.started,detail:'XMLHttpRequest network error'}),{once:true});}
          return Reflect.apply(send,this,arguments);
        };
      }}catch(_){}

      try{if(typeof WebSocket!=='undefined'){
        const Native=WebSocket, Wrapped=function(target,protocols){const socket=protocols===undefined?new Native(target):new Native(target,protocols), id=b.id('websocket'), u=url(target), started=performance.now();b.push({id,kind:'websocket',phase:'connect',url:u});
          socket.addEventListener('open',()=>b.push({id:`${id}-open`,kind:'websocket',phase:'open',url:u,duration:performance.now()-started}));
          socket.addEventListener('message',e=>b.push({id:`${id}-message-${Date.now()}`,kind:'websocket',phase:'message',url:u,responseBody:b.body(e.data)}));
          socket.addEventListener('close',e=>b.push({id:`${id}-close`,kind:'websocket',phase:'close',url:u,status:e.code,detail:b.text(e.reason,1024)}));
          socket.addEventListener('error',()=>b.push({id:`${id}-error`,kind:'websocket',phase:'error',url:u}));
          const nativeSend=socket.send;socket.send=function(data){b.push({id:`${id}-send-${Date.now()}`,kind:'websocket',phase:'send',url:u,requestBody:b.body(data)});return Reflect.apply(nativeSend,this,arguments);};return socket;};
        Object.setPrototypeOf(Wrapped,Native);Wrapped.prototype=Native.prototype;window.WebSocket=Wrapped;
      }}catch(_){}

      try{if(typeof EventSource!=='undefined'){
        const Native=EventSource, Wrapped=function(target,config){const source=new Native(target,config),id=b.id('eventsource'),u=url(target),started=performance.now();b.push({id,kind:'eventsource',phase:'connect',url:u});source.addEventListener('open',()=>b.push({id:`${id}-open`,kind:'eventsource',phase:'open',url:u,duration:performance.now()-started}));source.addEventListener('message',e=>b.push({id:`${id}-message-${Date.now()}`,kind:'eventsource',phase:'message',url:u,responseBody:b.body(e.data)}));source.addEventListener('error',()=>b.push({id:`${id}-error`,kind:'eventsource',phase:'error',url:u}));return source;};
        Object.setPrototypeOf(Wrapped,Native);Wrapped.prototype=Native.prototype;window.EventSource=Wrapped;
      }}catch(_){}

      try{if(typeof navigator!=='undefined'&&typeof navigator.sendBeacon==='function'){const native=navigator.sendBeacon.bind(navigator);navigator.sendBeacon=function(target,data){b.push({kind:'beacon',phase:'send',method:'POST',url:url(target),requestBody:b.body(data)});return native(target,data);};}}catch(_){}

      try{const observer=new PerformanceObserver(list=>{for(const e of list.getEntries())b.push({kind:'resource',phase:'complete',method:'GET',url:url(e.name),duration:Number(e.duration)||null,transferSize:Number(e.transferSize)||null,detail:b.text(e.initiatorType,128)});});observer.observe({type:'resource',buffered:false});}catch(_){}
      b.push({kind:'navigation',phase:'document',method:'GET',url:url(location.href),detail:b.text(document.title,512)});
      return JSON.stringify(b.drain());
    })();
    """#
}
