#!/usr/bin/env node
// Build script: copies diane.html to www/index.html and injects the Capacitor native speech shim
const fs = require('fs');
const path = require('path');

const src = path.join(__dirname, '..', 'diane.html');
const dst = path.join(__dirname, '..', 'www', 'index.html');
const photosDir = path.join(__dirname, '..', 'www', 'photos');

// Ensure www/photos exists
fs.mkdirSync(photosDir, { recursive: true });

// Copy photos
const srcPhotos = path.join(__dirname, '..', 'photos');
if (fs.existsSync(srcPhotos)) {
  for (const f of fs.readdirSync(srcPhotos)) {
    fs.copyFileSync(path.join(srcPhotos, f), path.join(photosDir, f));
  }
}

// Read diane.html
let html = fs.readFileSync(src, 'utf-8');

// The native speech recognition shim
const SHIM = `
// ══════════════════════════════════════════════════
// NATIVE SPEECH RECOGNITION SHIM (Capacitor)
// Replaces Web Speech API with native iOS SFSpeechRecognizer
// Only activates when running inside native Capacitor shell
// ══════════════════════════════════════════════════
if(window.Capacitor && window.Capacitor.isNativePlatform()){
  const _SRPlugin = window.Capacitor.Plugins.SpeechRecognition;

  class NativeSpeechRecognition {
    constructor(){
      this.lang='en-US';
      this.continuous=false;
      this.interimResults=false;
      this.onresult=null;
      this.onerror=null;
      this.onstart=null;
      this.onend=null;
      this._listening=false;
      this._listenerHandle=null;
    }

    async start(){
      if(this._listening) return;
      this._listening=true;
      try{
        const perm=await _SRPlugin.requestPermissions();
        if(perm.speechRecognition==='denied'){
          if(this.onerror) this.onerror({error:'not-allowed'});
          this._listening=false;
          return;
        }
        if(this.onstart) this.onstart();

        if(this.continuous){
          this._listenerHandle=await _SRPlugin.addListener('partialResults',(data)=>{
            if(this.onresult && data.matches && data.matches.length>0){
              const event={
                resultIndex:0,
                results: data.matches.map(text=>{
                  const r=[{transcript:text, confidence:0.9}];
                  r.isFinal=true;
                  r.length=1;
                  return r;
                })
              };
              this.onresult(event);
            }
          });
          await _SRPlugin.start({
            language:this.lang,
            partialResults:true,
            popup:false
          });
        } else {
          const result=await _SRPlugin.start({
            language:this.lang,
            maxResults:5,
            partialResults:false,
            popup:false
          });
          if(this.onresult && result.matches && result.matches.length>0){
            const r=[{transcript:result.matches[0], confidence:0.9}];
            r.isFinal=true;
            r.length=1;
            const event={resultIndex:0, results:[r]};
            this.onresult(event);
          }
          this._listening=false;
          if(this.onend) this.onend();
        }
      }catch(e){
        this._listening=false;
        const errMsg=(e&&e.message)||'unknown';
        if(this.onerror) this.onerror({error:errMsg});
        if(this.onend) this.onend();
      }
    }

    async stop(){
      this._cleanup();
      try{ await _SRPlugin.stop(); }catch(e){}
      if(this.onend) this.onend();
    }

    async abort(){
      this._cleanup();
      try{ await _SRPlugin.stop(); }catch(e){}
      if(this.onend) this.onend();
    }

    _cleanup(){
      this._listening=false;
      if(this._listenerHandle){
        this._listenerHandle.remove();
        this._listenerHandle=null;
      }
    }
  }

  window.SpeechRecognition=NativeSpeechRecognition;
  window.webkitSpeechRecognition=NativeSpeechRecognition;
  console.log('[Diane] Native speech recognition shim loaded');
}
`;

// Inject shim after <script> tag
html = html.replace('<script>', '<script>\n' + SHIM);

fs.writeFileSync(dst, html);
console.log('Built www/index.html with native speech shim');
