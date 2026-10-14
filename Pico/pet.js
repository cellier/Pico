// Original monitor companion; reference informs proportions, never used as a texture.
const scene=new Scene();
const camera=new OrthographicCamera(-1.9,1.9,1.88,-1.92,.1,30);camera.position.set(0,0,8);camera.zoom=.78;camera.updateProjectionMatrix();
const renderer=new WebGLRenderer({alpha:true,antialias:true,powerPreference:'low-power'});
renderer.setSize(280,280);renderer.setPixelRatio(Math.min(devicePixelRatio,2));renderer.setClearColor(0,0);renderer.outputColorSpace=SRGBColorSpace;renderer.toneMapping=ACESFilmicToneMapping;renderer.toneMappingExposure=1.12;renderer.shadowMap.enabled=true;renderer.shadowMap.type=PCFSoftShadowMap;document.body.appendChild(renderer.domElement);
// A local, texture-free studio reflection environment, baked once at startup.
const studio=new Scene();studio.background=new Color(0x424b59);
function softbox(x,y,z,sx,sy,sz,color){const m=new Mesh(new BoxGeometry(sx,sy,sz),new MeshBasicMaterial({color}));m.position.set(x,y,z);studio.add(m);}
softbox(-4,4,3,2,5,3,0xffffff);softbox(4,2,1,1,4,3,0xb7d6ff);softbox(0,5,-2,5,.1,4,0xffffff);softbox(0,-3,2,6,.1,5,0x283443);
const pmrem=new PMREMGenerator(renderer);const env=pmrem.fromScene(studio,.06);scene.environment=env.texture;pmrem.dispose();studio.traverse(o=>{o.geometry?.dispose();o.material?.dispose();});
scene.add(new HemisphereLight(0xfffbf3,0x858580,1.20));
const key=new DirectionalLight(0xfff6e8,3.0);key.position.set(-3.5,5,4);key.castShadow=true;key.shadow.mapSize.set(512,512);key.shadow.camera.left=-2;key.shadow.camera.right=2;key.shadow.camera.top=2;key.shadow.camera.bottom=-2;key.shadow.bias=-.001;key.shadow.normalBias=.025;key.shadow.radius=3;scene.add(key);
const rim=new DirectionalLight(0xabcfff,.65);rim.position.set(3,3,-3);scene.add(rim);
const silver=new MeshStandardMaterial({color:0xd9e1e9,metalness:.65,roughness:.32});
const cream=new MeshPhysicalMaterial({color:0xf6f3eb,metalness:.025,roughness:.66,clearcoat:.12,clearcoatRoughness:.65,envMapIntensity:.65});
const shellCream=new MeshPhysicalMaterial({color:0xfffcf4,emissive:0xfff7e8,emissiveIntensity:.085,metalness:0,roughness:.29,clearcoat:.32,clearcoatRoughness:.28,ior:1.45,specularIntensity:.85,envMapIntensity:.68});
// A softly lit latex membrane: broad highlights and warm light at grazing angles.
// Keep it opaque so the desktop and the black face cannot bleed through the shell.
shellCream.onBeforeCompile=shader=>{shader.fragmentShader=shader.fragmentShader.replace('#include <opaque_fragment>',`
 float latexEdge=pow(1.0-clamp(dot(normal,normalize(vViewPosition)),0.0,1.0),1.6);
 outgoingLight+=vec3(1.0,.90,.73)*(.14*latexEdge);
 #include <opaque_fragment>`);};
shellCream.customProgramCacheKey=()=> 'pico-latex-shell-v1';
const softGray=new MeshStandardMaterial({color:0x9a9b99,metalness:.02,roughness:.72});
const porcelain=new MeshStandardMaterial({color:0xe9edf2,metalness:.27,roughness:.3});
const graphite=new MeshStandardMaterial({color:0x18202a,metalness:.5,roughness:.34});
const glass=new MeshPhysicalMaterial({color:0x05070b,metalness:.12,roughness:.27,clearcoat:.85,clearcoatRoughness:.30,envMapIntensity:.95});
const blue=new MeshStandardMaterial({color:0x216cba,metalness:.65,roughness:.26});
const light=new MeshStandardMaterial({color:0xf6fbff,emissive:0xe3f3ff,emissiveIntensity:2,roughness:.35});
const cyan=new MeshStandardMaterial({color:0x87d5ff,emissive:0x53baff,emissiveIntensity:.5,metalness:.3,roughness:.3});
const pet=new Group();pet.name='Pico — original monitor companion';scene.add(pet);
function smooth(g){const p=g.attributes.position,map=new Map(),verts=[],idx=[];for(let i=0;i<p.count;i++){const x=p.getX(i),y=p.getY(i),z=p.getZ(i),k=[x,y,z].map(v=>Math.round(v*1e5)).join(',');let n=map.get(k);if(n===undefined){n=verts.length/3;map.set(k,n);verts.push(x,y,z);}idx.push(n);}const out=new BufferGeometry();out.setAttribute('position',new Float32BufferAttribute(verts,3));out.setIndex(idx);// Angle-weighted normals avoid bright triangulation artifacts along broad bevels.
const ns=new Float32Array(verts.length),va=new Vector3(),vb=new Vector3(),vc=new Vector3(),u=new Vector3(),v=new Vector3(),normal=new Vector3();
for(let f=0;f<idx.length;f+=3){const ids=idx.slice(f,f+3);va.fromArray(verts,ids[0]*3);vb.fromArray(verts,ids[1]*3);vc.fromArray(verts,ids[2]*3);normal.crossVectors(u.subVectors(vb,va),v.subVectors(vc,va)).normalize();const vs=[va,vb,vc];for(let c=0;c<3;c++){u.subVectors(vs[(c+1)%3],vs[c]).normalize();v.subVectors(vs[(c+2)%3],vs[c]).normalize();const angle=Math.acos(Math.max(-1,Math.min(1,u.dot(v))));const k=ids[c]*3;ns[k]+=normal.x*angle;ns[k+1]+=normal.y*angle;ns[k+2]+=normal.z*angle;}}
out.setAttribute('normal',new Float32BufferAttribute(ns,3));out.normalizeNormals();g.dispose();return out;}
function rounded(w,h,d,r,b=.025){r=Math.min(r,w/2-.001,h/2-.001);const s=new Shape(),x=-w/2,y=-h/2;s.moveTo(x+r,y);s.lineTo(x+w-r,y);s.quadraticCurveTo(x+w,y,x+w,y+r);s.lineTo(x+w,y+h-r);s.quadraticCurveTo(x+w,y+h,x+w-r,y+h);s.lineTo(x+r,y+h);s.quadraticCurveTo(x,y+h,x,y+h-r);s.lineTo(x,y+r);s.quadraticCurveTo(x,y,x+r,y);const g=new ExtrudeGeometry(s,{depth:d,bevelEnabled:b>0,bevelThickness:b,bevelSize:b,bevelSegments:w>1?7:3,curveSegments:w>1?18:5,steps:1});g.translate(0,0,-d/2);return smooth(g);}
function mesh(name,g,mat,parent,x=0,y=0,z=0){const m=new Mesh(g,mat);m.name=name;m.position.set(x,y,z);m.castShadow=true;m.receiveShadow=true;parent.add(m);return m;}
function box(name,w,h,d,r,mat,parent,x=0,y=0,z=0,b=.025){return mesh(name,rounded(w,h,d,r,b),mat,parent,x,y,z);}
function sphere(name,r,mat,parent,x,y,z,sx=1,sy=1,sz=1){const m=mesh(name,new SphereGeometry(r,20,12),mat,parent,x,y,z);m.scale.set(sx,sy,sz);return m;}
function tube(name,points,r,mat,parent){const c=new CatmullRomCurve3(points.map(p=>new Vector3(...p)));return mesh(name,new TubeGeometry(c,24,r,8,false),mat,parent);}
const head=new Group();head.name='Monitor head';head.position.y=.20;pet.add(head);
const classicSkin=new Group();classicSkin.name='Classic Pico';head.add(classicSkin);
// A continuous superellipsoid softens every surface, not just the silhouette corners.
function pillow(w,h,d,power=3.0){
 const g=new SphereGeometry(1,80,48),p=g.attributes.position,n=g.attributes.normal,axes=[w/2,h/2,d/2],e=2/power;
 for(let i=0;i<p.count;i++){
  const source=[p.getX(i),p.getY(i),p.getZ(i)],v=source.map((a,k)=>Math.sign(a)*Math.pow(Math.abs(a),e)*axes[k]);
  p.setXYZ(i,...v);const normal=new Vector3(...v.map((a,k)=>Math.sign(a)*Math.pow(Math.abs(a/axes[k]),power-1)/axes[k])).normalize();n.setXYZ(i,normal.x,normal.y,normal.z);
 }
 return g;
}
mesh('Inflated milk-white latex shell',pillow(2.30,2.30,1.58),shellCream,classicSkin);
// The same superellipse exponent gives shell, glass and rim one coherent outline.
const faceProfile={halfWidth:.99,halfHeight:.99,edgeZ:.61,bulge:.45,power:3.0};
function convexFace(profile){
 const {halfWidth:a,halfHeight:b,edgeZ,bulge,power}=profile,segments=96,rings=24,v=[0,0,edgeZ+bulge],idx=[];
 for(let ring=1;ring<=rings;ring++)for(let i=0;i<segments;i++){
  const r=ring/rings,t=i/segments*Math.PI*2,c=Math.cos(t),s=Math.sin(t),e=2/power;
  v.push(a*r*Math.sign(c)*Math.pow(Math.abs(c),e),b*r*Math.sign(s)*Math.pow(Math.abs(s),e),edgeZ+bulge*(1-r*r));
 }
 for(let i=0;i<segments;i++)idx.push(0,1+i,1+(i+1)%segments);
 for(let ring=1;ring<rings;ring++)for(let i=0;i<segments;i++){
  const a=1+(ring-1)*segments+i,b=1+(ring-1)*segments+(i+1)%segments,c=a+segments,d=b+segments;idx.push(a,c,b,b,c,d);
 }
 // A rounded dark edge seats the domed surface directly into the shell.
 if(profile.edgeDepth){const start=v.length/3;for(let i=0;i<segments;i++){const k=(1+(rings-1)*segments+i)*3;v.push(v[k]*.998,v[k+1]*.998,edgeZ-profile.edgeDepth);}for(let i=0;i<segments;i++){const a=1+(rings-1)*segments+i,b=1+(rings-1)*segments+(i+1)%segments,c=start+i,d=start+(i+1)%segments;idx.push(a,c,b,b,c,d);}}
 const g=new BufferGeometry();g.setAttribute('position',new Float32BufferAttribute(v,3));g.setIndex(idx);g.computeVertexNormals();return g;
}
// The glass edge seats directly into the shell; an overlapping flat gasket caused speckling.
mesh('Convex black glass face',convexFace({...faceProfile,edgeDepth:.065}),glass,classicSkin);
const eyeRig=new PicoEyeRig(classicSkin,faceProfile),eyes=eyeRig.meshes;
const chinLight=box('Chin status light',.12,.020,.012,.009,cyan,classicSkin,0,-1.065,.471,.002);chinLight.rotation.x=1.04;
const flowerRig=new PicoFlowerRig(head,renderer),orbRig=new PicoOrbRig(head);const defaultSkin='snowball';let skin=defaultSkin;
const skinGroups={classic:classicSkin,blossom:flowerRig.group,snowball:orbRig.group};
for(const [name,group] of Object.entries(skinGroups))group.visible=name===skin;
function activeSkin(){return skinGroups[skin];}
function activeEye(){return skin==='classic'?eyes[0]:skin==='blossom'?flowerRig.eyeMeshes[0]:orbRig.eyeMeshes[0];}
window.setSkin=value=>{skin=Object.prototype.hasOwnProperty.call(skinGroups,value)?value:defaultSkin;for(const [name,group] of Object.entries(skinGroups))group.visible=name===skin;if(skin==='blossom')flowerRig.update(0,eyeRig.motion,{reduced:reducedMotion});else if(skin==='snowball')orbRig.update(0,eyeRig.motion,{reduced:reducedMotion,pressed:interaction.down});if(screenFacing&&(paused||reducedMotion))applyHeadFacing(0,true);scene.updateMatrixWorld(true);renderer.render(scene,camera);return skin;};
window.getSkin=()=>skin;
// Three genuine mesh-based scene props, scaled smoothly with the state weights.
const work=new Group();work.name='Working — miniature keyboard';pet.add(work);work.position.set(0,-1.32,1.62);work.rotation.set(-.90,-.10,0);work.userData.displayScale=1.43;
box('Cream keyboard tray',1.49,.56,.105,.08,cream,work,0,0,0,.022);
box('Keyboard lower inset',1.42,.50,.025,.065,graphite,work,0,0,-.070,.008);
// ANSI 60%: 61 keys, 15 units per row. Coordinates are the typist's view.
const ansiRows=[
[['Esc',1],...Array.from('1234567890',k=>[k,1]),['-',1],['=',1],['Backspace',2]],
[['Tab',1.5],...Array.from('QWERTYUIOP',k=>[k,1]),['[',1],[']',1],['Backslash',1.5]],
[['Caps',1.75],...Array.from('ASDFGHJKL',k=>[k,1]),[';',1],["Quote",1],['Return',2.25]],
[['ShiftL',2.25],...Array.from('ZXCVBNM',k=>[k,1]),[',',1],['.',1],['/',1],['ShiftR',2.75]],
[['CtrlL',1.25],['Win',1.25],['AltL',1.25],['Space',6.25],['AltR',1.25],['Fn',1.25],['Menu',1.25],['CtrlR',1.25]]];
const keys=[];ansiRows.forEach((row,r)=>{let x=-7.5;for(const [label,u] of row){const mat=label==='Return'?new MeshStandardMaterial({color:0xa6bec1,roughness:.7,metalness:.02}):(u>1?cream:softGray).clone();const k=box('Keycap '+label,u*.095-.010,.087,.045,.017,mat,work,(x+u/2)*.095,(2-r)*.105,.086,.005);k.userData={label,units:u,row:r,restColor:mat.color.clone()};keys.push(k);x+=u;}if(Math.abs(x-7.5)>.001)throw Error('Invalid ANSI row');});
const returnKey=keys.find(k=>k.userData.label==='Return');
tube('Return arrow',[[.062,.023,.035],[.062,-.012,.035],[-.043,-.012,.035]],.006,graphite,returnKey);
tube('Return arrowhead',[[-.014,.010,.035],[-.044,-.012,.035],[-.014,-.034,.035]],.006,graphite,returnKey);
const typingSequence=['F','J','A','S','D','K','L','Return'].map(label=>keys.findIndex(k=>k.userData.label===label));let currentKey=0,keyPress=0;
const spacebar=keys.find(k=>k.userData.label==='Space');
// Rigid half-turn (no mirroring): Space points toward the character; Return is at its right hand.
work.rotation.z=Math.PI;
const think=new Group();think.name='Thinking — idea lamp';pet.add(think);think.position.set(1.43,1.53,1.48);think.userData.displayScale=1.67;think.rotation.y=-.18;
const bulbMaterial=new MeshPhysicalMaterial({color:0xffeac5,emissive:0xd88b2b,emissiveIntensity:.25,roughness:.25,metalness:.05,clearcoat:.7,transparent:true,opacity:.94,depthWrite:false});
const bulb=sphere('Frosted idea bulb',.155,bulbMaterial,think,0,.07,0,1,1.1,1);
bulb.castShadow=false;
const filamentMaterial=new MeshStandardMaterial({color:0xffbd49,emissive:0xffa827,emissiveIntensity:.2,roughness:.35});
tube('Visible warm filament',[[-.055,0,.04],[-.035,.105,.04],[0,.035,.04],[.035,.105,.04],[.055,0,.04]],.009,filamentMaterial,think);
const glowCanvas=document.createElement('canvas');glowCanvas.width=glowCanvas.height=128;const gc=glowCanvas.getContext('2d'),gradient=gc.createRadialGradient(64,64,3,64,64,64);gradient.addColorStop(0,'rgba(255,195,70,.8)');gradient.addColorStop(.3,'rgba(255,184,64,.35)');gradient.addColorStop(1,'rgba(255,167,40,0)');gc.fillStyle=gradient;gc.fillRect(0,0,128,128);
const glowMaterial=new MeshBasicMaterial({map:new CanvasTexture(glowCanvas),transparent:true,opacity:.04,depthWrite:false,blending:AdditiveBlending,toneMapped:false});
const glow=mesh('Soft lamp glow',new PlaneGeometry(.70,.70),glowMaterial,think,0,.07,-.05);glow.castShadow=glow.receiveShadow=false;glow.userData.passThrough=true;
sphere('Rounded glass neck',.10,bulbMaterial,think,0,-.065,0,1,.85,1);
box('Rounded cream lamp socket',.13,.11,.13,.055,cream,think,0,-.145,0,.020);
const lampLight=new PointLight(0xffdfa6,.35,2,2);lampLight.position.set(0,.07,.12);think.add(lampLight);
sphere('Rounded lamp foot',.065,softGray,think,0,-.216,0,1,.42,1);
const meeting=new Group();meeting.name='Meeting — floating studio microphone';pet.add(meeting);meeting.position.set(1.35,-1.01,1.60);meeting.userData.displayScale=1.78;meeting.rotation.y=-.32;
box('Independent microphone capsule',.23,.35,.23,.10,cream,meeting,0,.075,0,.022);
box('Soft dark microphone inset',.175,.26,.018,.078,graphite,meeting,0,.075,.14,.008);
box('Microphone activity light',.025,.025,.008,.01,cyan,meeting,0,-.065,.14,.002);
tube('Microphone cradle',[[-.16,.04,0],[-.15,-.14,0],[0,-.19,0],[.15,-.14,0],[.16,.04,0]],.022,cream,meeting);
// Simulated voice meter only. No audio input or permission is used.
const meters=[];for(let i=0;i<5;i++){const mat=new MeshStandardMaterial({color:0x5db9e4,emissive:0x249dd3,emissiveIntensity:.6,roughness:.4});const bar=box('Simulated voice level',.018,.20,.008,.008,mat,meeting,(i-2)*.031,0,.164,.002);bar.castShadow=false;meters.push(bar);}let voiceEnvelope=0,bulbPulse=0;
// Small directional ground contact shadow; no opaque rectangular floor.
const floor=mesh('Contact shadow',new PlaneGeometry(3.1,2.0),new ShadowMaterial({opacity:.09}),scene,0,-1.55,0);floor.rotation.x=-Math.PI/2;floor.castShadow=false;
let lastPointerMotion=-100;
let pointer={x:0,y:0},jump=-10,paused=false,frames=0,last=performance.now(),blink=1,animationTime=0,state='idle';
// Native supplies the direction from this window toward its display's center.
// A browser preview has no desktop location, so it keeps its original pose.
let screenFacing=null;
let weights={idle:1,thinking:0,working:0,meeting:0};
const springs={head:{x:1,v:0},thinking:{x:0,v:0},working:{x:0,v:0},meeting:{x:0,v:0}};
function spring(s,target,dt){for(let rest=dt;rest>0;){const h=Math.min(rest,1/120);s.v+=(150*(target-s.x)-19*s.v)*h;s.x+=s.v*h;rest-=h;}return s.x;}
const interaction={x:1,v:0,down:false};
let reducedMotion=window.matchMedia('(prefers-reduced-motion: reduce)').matches;
function pressSpring(s,target,dt){for(let rest=dt;rest>0;){const h=Math.min(rest,1/120);s.v+=(380*(target-s.x)-22*s.v)*h;s.x+=s.v*h;rest-=h;}return s.x;}
window.setReducedMotion=value=>{reducedMotion=Boolean(value);if(reducedMotion){interaction.x=interaction.down?.95:1;interaction.v=0;}};
window.setPressed=value=>{interaction.down=Boolean(value);if(reducedMotion||paused){interaction.x=interaction.down?.95:1;interaction.v=0;head.scale.setScalar(springs.head.x*interaction.x);if(orbRig.group.visible)orbRig.update(0,eyeRig.motion,{reduced:reducedMotion,pressed:interaction.down});renderer.render(scene,camera);}};
window.matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change',e=>window.setReducedMotion(e.matches));
window.addEventListener('blur',()=>window.setPressed(false));
const ray=new Raycaster();
// Skip absent props even if their descendants are meshes.
function interactive(o){for(let p=o;p;p=p.parent)if(!p.visible||p.userData.passThrough)return false;return true;}
window.pointerAt=(x,y)=>{const next={x:x/140-1,y:1-y/140};if(Math.hypot(next.x-pointer.x,next.y-pointer.y)>.006)lastPointerMotion=performance.now()/1000;pointer=next;scene.updateMatrixWorld(true);ray.setFromCamera(pointer,camera);return ray.intersectObjects([activeSkin(),...[work,think,meeting].filter(g=>g.visible)],true).some(h=>interactive(h.object));};
window.setScreenFacing=(x,y)=>{
 const next={x:Number.isFinite(x)?MathUtils.clamp(x,-1,1):0,y:Number.isFinite(y)?MathUtils.clamp(y,-1,1):0};
 if(screenFacing&&next.x===screenFacing.x&&next.y===screenFacing.y)return {...screenFacing};
 screenFacing=next;
 // Moving a paused pet still updates its placement, without advancing time.
 if(paused||reducedMotion){applyHeadFacing(0,true);renderer.render(scene,camera);}
 return {...screenFacing};
};
window.cheer=()=>{jump=animationTime;eyeRig.cheer();};
window.setPaused=p=>{paused=Boolean(p);last=performance.now();};
window.setPetState=next=>{if(!['idle','thinking','working','meeting'].includes(next))throw new Error('Unknown state '+next);state=next;return state;};
window.sprout=Object.freeze({setState:window.setPetState,setEmotion:value=>eyeRig.setState(value),getState:()=>state,setPaused:window.setPaused,setSkin:window.setSkin,getSkin:window.getSkin});
function viewBounds(g){if(!g.visible)return null;g.updateWorldMatrix(true,true);const b=new Box3().setFromObject(g),points=[];for(const x of [b.min.x,b.max.x])for(const y of [b.min.y,b.max.y])for(const z of [b.min.z,b.max.z]){const v=new Vector3(x,y,z).project(camera);points.push([(v.x+1)*140,(1-v.y)*140]);}const xs=points.map(p=>p[0]),ys=points.map(p=>p[1]);return [Math.min(...xs),Math.min(...ys),Math.max(...xs),Math.max(...ys)].map(v=>Math.round(v*10)/10);}
window.petStats=()=>({state,skin,screenFacing:screenFacing?{...screenFacing}:null,flower:flowerRig.stats(),orb:orbRig.stats(),eyes:eyeRig.stats(),weights:{...weights},headScale:head.scale.x,interaction:{...interaction},reducedMotion,springs:JSON.parse(JSON.stringify(springs)),animationTime,frames,blink,jump,bouncing:animationTime-jump<1.1,rotation:[head.rotation.x,head.rotation.y,head.rotation.z],props:{thinking:think.visible,working:work.visible,meeting:meeting.visible},triangles:renderer.info.render.triangles,pixelRatio:renderer.getPixelRatio(),alpha:renderer.getContext().getContextAttributes().alpha,paused,keyPress,currentKey,keyboardNormal:new Vector3(0,0,1).applyQuaternion(work.quaternion).toArray(),voiceEnvelope,voiceHeights:meters.map(b=>b.scale.y*.20),bulbPulse,glowOpacity:glowMaterial.opacity,bulbEmission:bulbMaterial.emissiveIntensity,viewYaw:head.rotation.y,boundsPt:{head:viewBounds(activeSkin()),eye:viewBounds(activeEye()),thinking:viewBounds(think),working:viewBounds(work),meeting:viewBounds(meeting)}});
function gazeOffset(p,age){const distance=Math.max(Math.abs(p.x),Math.abs(p.y));const near=1-MathUtils.smoothstep(distance,1.8,2.6);const active=1-MathUtils.smoothstep(age,1.8,3.8);return {yaw:MathUtils.clamp(p.x,-1,1)*.55*near*active,pitch:-MathUtils.clamp(p.y,-1,1)*.30*near*active};}
function applyHeadFacing(dt,snap=false){
 const e=snap?1:1-Math.exp(-dt*4.5),t=animationTime,{thinking:h,working:w,meeting:m}=weights;
 const gaze=gazeOffset(pointer,performance.now()/1000-lastPointerMotion);
 // Compensate the white balloon's built-in yaw, so its face follows the
 // same screen direction as every other skin instead of always leaning right.
 const localYaw=activeSkin().rotation.y;
 // Placement is a subtle preference, keeping the face nearly front-on.
 let yaw=(screenFacing?screenFacing.x*.16-localYaw:-.085)+gaze.yaw+.035*Math.tanh(Math.sin(t*.68)*2.8)*h+Math.sin(t*.8)*.025*m;
 if(screenFacing)yaw=MathUtils.clamp(yaw+localYaw,-.72,.72)-localYaw;
 const pitch=.02-(screenFacing?screenFacing.y*.08:0)+gaze.pitch-.04*h+(.035+Math.sin(t*6.6)*.008)*w+(.018+Math.sin(t*1.8)*.02)*m;
 head.rotation.x+=(pitch-head.rotation.x)*e;
 head.rotation.y+=(yaw-head.rotation.y)*e;
 head.rotation.z+=((-.09+Math.sin(t*.85)*.025)*h+.018*Math.sin(t*1.8)*m-head.rotation.z)*e;
}
function prop(g,a){g.visible=a>.008;g.scale.setScalar(Math.max(.001,a)*(g.userData.displayScale||1));}
function animate(dt){animationTime+=dt;const t=animationTime,e=1-Math.exp(-dt*4.5);for(const k of Object.keys(weights))weights[k]+=((k===state?1:0)-weights[k])*e;const {idle:i,thinking:h,working:w,meeting:m}=weights;
const baseScale=spring(springs.head,state==='idle'?1:.92,dt);const pressScale=reducedMotion?interaction.x:pressSpring(interaction,interaction.down?.95:1,dt);head.scale.setScalar(baseScale*pressScale);for(const k of ['thinking','working','meeting'])spring(springs[k],state===k?1:0,dt);
const breath=Math.sin(t*1.6);applyHeadFacing(dt);
const j=t-jump,bounce=j>=0&&j<1.1?Math.sin(j/1.1*Math.PI)*.22:0;pet.position.y=breath*(.018*i+.025*h+.007*w+.012*m)+bounce;
eyeRig.update(dt,{pointerX:pointer.x,pointerY:pointer.y,pointerAge:performance.now()/1000-lastPointerMotion,pressed:interaction.down,reduced:reducedMotion});blink=eyeRig.motion.left.open;if(flowerRig.group.visible)flowerRig.update(dt,eyeRig.motion,{reduced:reducedMotion});if(orbRig.group.visible)orbRig.update(dt,eyeRig.motion,{reduced:reducedMotion,pressed:interaction.down});
prop(work,springs.working.x);prop(think,springs.thinking.x);prop(meeting,springs.meeting.x);think.position.set(1.43,1.53+.10*(springs.thinking.x-1)+Math.sin(t*1.5)*.025,1.48);meeting.position.set(1.35+.13*(springs.meeting.x-1),-1.01,1.60);bulbPulse=.5-.5*Math.cos(t*2*Math.PI/3.8);bulbMaterial.color.set(0xb59462).lerp(new Color(0xe4b958),bulbPulse);bulbMaterial.emissiveIntensity=.02+.60*bulbPulse;filamentMaterial.emissiveIntensity=.15+1.7*bulbPulse;glowMaterial.opacity=.015+.22*bulbPulse;lampLight.intensity=.05+.45*bulbPulse;work.position.y=-1.32-.13*(springs.working.x-1);meeting.rotation.z=Math.sin(t*1.8)*.04;
const step=Math.floor(t*3.4);currentKey=typingSequence[step%typingSequence.length];keyPress=Math.sin((t*3.4%1)*Math.PI);
keys.forEach((k,index)=>{const press=index===currentKey?keyPress:0;k.position.z=.086-.026*press;k.material.color.copy(k.userData.restColor).lerp(new Color(0x8edcff),press);k.material.emissive.set(0x4cbdff);k.material.emissiveIntensity=press*.85;});spacebar.position.z=.085-(step%8===7?.020*keyPress:0);
const speech=t%6;voiceEnvelope=MathUtils.smoothstep(speech,.1,.5)*(1-MathUtils.smoothstep(speech,3.7,4.3));meters.forEach((bar,index)=>{const level=voiceEnvelope*(.2+.8*Math.pow(Math.sin(t*(5+index*.7)+index*.9),2));const height=.015+.150*level;bar.scale.y=height/.20;bar.position.y=-.015+height/2;bar.material.emissiveIntensity=.12+level*.40;});
renderer.render(scene,camera);frames++;}
function frame(){const now=performance.now(),dt=Math.min(.08,(now-last)/1000);last=now;if(!paused)animate(dt);setTimeout(frame,paused?100:1000/30);}
const bridge=(type,data)=>window.webkit?.messageHandlers.native.postMessage({type,data});
// Export all props as real GLB nodes before applying idle visibility.
[work,think,meeting].forEach(g=>g.scale.setScalar(g.userData.displayScale));
animate(0);bridge('ready',window.petStats());frame();
window.onerror=msg=>bridge('error',String(msg));
