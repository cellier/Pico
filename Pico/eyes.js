// Pico's screen expressions: continuous curves, independently animated lids and gaze.
// No textures, per-frame geometry allocation, audio access, or random state changes.
const PICO_EYE_STATES = new Set(['idle','listening','transcribing','thinking','working','speaking','completed','error','needs_input','awaiting_approval','cancelled']);
const eyeClamp=(v,a,b)=>Math.max(a,Math.min(b,v));
const eyeMix=(a,b,t)=>a+(b-a)*t;
const eyeSmooth=(a,b,x)=>{const t=eyeClamp((x-a)/(b-a),0,1);return t*t*(3-2*t);};
const eyePose=(width=.235,height=.45,curve=0,tilt=0,lid=1,heart=0)=>({width,height,curve,tilt,lid,heart});
class PicoEyeMotion {
 constructor(){
  this.state='idle';this.time=0;this.entered=0;this.gesture=null;this.tapCount=0;
  this.seed=731;this.nextBlink=2.6;this.blinkStart=-100;this.doubleBlink=false;
  this.gaze={x:0,y:0};this.lastInterest=0;
  this.left={...eyePose(),open:1,x:0,y:0};this.right={...this.left};this.expression='relaxed';this.motion=1;
 }
 random(){this.seed=(Math.imul(this.seed,1664525)+1013904223)>>>0;return this.seed/4294967296;}
 setState(state){const next=PICO_EYE_STATES.has(state)?state:'idle';if(next===this.state)return;this.state=next;this.entered=this.time;this.gesture=null;this.lastInterest=this.time;}
 cheer(){this.tapCount++;this.gesture={kind:['happy','wink','love'][(this.tapCount-1)%3],start:this.time};this.lastInterest=this.time;}
 update(dt,{pointerX=0,pointerY=0,pointerAge=99,pressed=false,reduced=false}={}){
  dt=eyeClamp(dt,0,.08);this.time+=dt;const t=this.time,age=t-this.entered;
  if(pressed||pointerAge<.2)this.lastInterest=t;
  let left=eyePose(),right=eyePose(),gx=0,gy=0,expression='relaxed';
  const near=1-eyeSmooth(1.3,2.2,Math.max(Math.abs(pointerX),Math.abs(pointerY)));
  const attention=near*(1-eyeSmooth(1.6,3.8,pointerAge));
  const activeState=pressed?'listening':this.state;
  switch(activeState){
   case 'listening':
    left=eyePose(.27,.51);right=eyePose(.27,.51);gy=.035;expression='attentive';break;
   case 'transcribing':case 'thinking':
    left=eyePose(.235,.35,0,.06);right=eyePose(.245,.46,0,-.045);gx=.045;gy=.065;expression='pondering';break;
   case 'working':
    left=eyePose(.26,.31,0,-.025,.11);right=eyePose(.26,.31,0,.025,.11);gx=reduced?0:Math.sin(t*2.5)*.026;gy=-.055;expression='focused';break;
   case 'speaking':{
    const beat=reduced?0:Math.sin(t*3.1)*.022;
    left=eyePose(.255,.37+beat,.013,.015);right=eyePose(.25,.41-beat,.013,-.015);gy=.025;expression='engaged';break;}
   case 'completed':
    if(age<3.5){left=eyePose(.33,.075,.095,-.04);right=eyePose(.33,.075,.095,.04);gy=.015;expression='happy';}break;
   case 'error':
    left=eyePose(.25,.26,.016,.20,.075);right=eyePose(.25,.33,.016,-.20,.10);gy=-.015;expression='concerned';break;
   case 'needs_input':case 'awaiting_approval':
    left=eyePose(.255,.48,0,.06);right=eyePose(.23,.29,0,-.08,.10);gx=-.025;gy=.028;expression='curious';break;
   case 'cancelled':
    if(age<1.15){left=eyePose(.28,.09,-.027,.02);right=eyePose(.28,.09,-.027,-.02);expression='soft-close';}break;
   default:
    if(t-this.lastInterest>24){left=eyePose(.265,.22,-.016,0,.055);right=eyePose(.265,.22,-.016,0,.055);gy=-.018;expression='sleepy';}
    else if(attention>.3){left=eyePose(.24,.48,0,.025);right=eyePose(.245,.40,0,-.025);expression='curious';}
  }
  // A click is affectionate; deliberate work/voice states always take priority.
  if(this.gesture && t-this.gesture.start<2.6 && !pressed && ['idle','completed','cancelled'].includes(activeState)){
   const kind=this.gesture.kind;expression=kind;gx=0;gy=.025;
   if(kind==='happy'){left=eyePose(.33,.078,.095,-.04);right=eyePose(.33,.078,.095,.04);}
   else if(kind==='wink'){left=eyePose(.30,.065,.065,.04);right=eyePose(.25,.46,0,-.035);}
   else{left=eyePose(.36,.40,0,-.06,1,1);right=eyePose(.36,.40,0,.06,1,1);}
  }else if(this.gesture && t-this.gesture.start>=2.6){this.gesture=null;}
  if(attention>0){gx+=eyeClamp(pointerX,-1,1)*.075*attention;gy+=eyeClamp(pointerY,-1,1)*.055*attention;}
  // Tiny held glances, not constant wobbling. Quieted for reduced motion.
  if(!reduced && expression==='relaxed'){
   const phase=t%11;if(phase>5.3&&phase<6.3){gx-=.025;gy+=.009;}else if(phase>8.5&&phase<9.15){gx+=.022;}
  }
  if(!reduced && t>=this.nextBlink){this.blinkStart=t;this.nextBlink=t+2.8+this.random()*3.6;this.doubleBlink=this.random()<.24;}
  const blinkAt=(elapsed)=>{
   if(elapsed<0||elapsed>.25)return 1;
   return elapsed<.085?1-eyeSmooth(0,.085,elapsed)*.94:.06+eyeSmooth(.11,.25,elapsed)*.94;
  };
  let blink=reduced?1:blinkAt(t-this.blinkStart);
  if(!reduced&&this.doubleBlink)blink=Math.min(blink,blinkAt(t-this.blinkStart-.31));
  // Eyelids fold the whole silhouette, including hearts and smiling eyes.
  const smooth=1-Math.exp(-dt*(reduced?25:11));
  this.gaze.x=eyeMix(this.gaze.x,gx,smooth);this.gaze.y=eyeMix(this.gaze.y,gy,smooth);
  for(const [eye,target,index] of [[this.left,left,0],[this.right,right,1]]){
   for(const key of ['width','height','curve','tilt','lid','heart'])eye[key]=eyeMix(eye[key],target[key],smooth);
   eye.open=blink;eye.x=this.gaze.x;eye.y=this.gaze.y+(index===0?.003:-.003);
  }
  this.expression=expression;return this;
 }
}
class PicoEyeRig {
 constructor(parent,face={halfWidth:.99,halfHeight:.99,edgeZ:.61,bulge:.45,power:3.0}){
  this.motion=new PicoEyeMotion();this.meshes=[];
  // Project the eye geometry onto the glass, including while looking or tilting.
  const vertex=`varying vec2 p;uniform vec2 eyeCenter;uniform float eyeTilt;uniform vec4 screenProfile;uniform float screenPower;
   void main(){p=position.xy;float c=cos(eyeTilt),s=sin(eyeTilt);vec2 q=eyeCenter+vec2(c*p.x-s*p.y,s*p.x+c*p.y);
    vec2 ratio=abs(q/screenProfile.xy);float r2=pow(pow(ratio.x,screenPower)+pow(ratio.y,screenPower),2.0/screenPower);
    vec3 v=position;v.z+=screenProfile.z+screenProfile.w*(1.0-r2)+.007-.835;
    gl_Position=projectionMatrix*modelViewMatrix*vec4(v,1.0);}`;
  const fragment=`
   varying vec2 p;
   uniform vec2 eyeSize;uniform float curve;uniform float lid;uniform float openness;uniform float heart;
   float roundBox(vec2 q,vec2 b,float r){vec2 d=abs(q)-b+r;return min(max(d.x,d.y),0.0)+length(max(d,0.0))-r;}
   void main(){
    vec2 q=p;q.y/=max(.055,openness);
    float bend=curve*(1.0-pow(clamp(q.x/(eyeSize.x*.5),-1.0,1.0),2.0));
    vec2 bent=vec2(q.x,q.y-bend);
    float d=roundBox(bent,eyeSize*.5,min(eyeSize.x,eyeSize.y)*.48);
    d=max(d,bent.y-lid);
    float a=1.0-smoothstep(-.0045,.0045,d);
    vec2 h=vec2(q.x/(eyeSize.x*.43),q.y/(eyeSize.y*.43)+.20);
    float k=h.x*h.x+h.y*h.y-1.0;
    float f=k*k*k-h.x*h.x*h.y*h.y*h.y;
    vec2 grad=vec2(6.0*h.x*k*k-2.0*h.x*h.y*h.y*h.y,6.0*h.y*k*k-3.0*h.x*h.x*h.y*h.y);
    float hd=f/max(length(grad),.08)*.13;
    float ha=1.0-smoothstep(-.0045,.0045,hd);
    a=mix(a,ha,heart);
    if(a<.01)discard;
    vec3 color=mix(vec3(.955,.978,1.0),vec3(1.0,.75,.80),heart*.65);
    gl_FragColor=vec4(color,a);
   }`;
  for(const side of [-1,1]){
   const material=new ShaderMaterial({uniforms:{eyeSize:{value:new Vector2(.235,.45)},curve:{value:0},lid:{value:1},openness:{value:1},heart:{value:0},eyeCenter:{value:new Vector2(side*.31,0)},eyeTilt:{value:0},screenProfile:{value:new Vector4(face.halfWidth,face.halfHeight,face.edgeZ,face.bulge)},screenPower:{value:face.power}},vertexShader:vertex,fragmentShader:fragment,transparent:true,depthWrite:false,toneMapped:false});
   const eye=new Mesh(new PlaneGeometry(.60,.82,12,16),material);eye.name=side<0?'Expressive left eye':'Expressive right eye';eye.position.set(side*.31,0,.835);eye.castShadow=false;eye.receiveShadow=false;parent.add(eye);this.meshes.push(eye);
  }
 }
 setState(state){this.motion.setState(state);}
 cheer(){this.motion.cheer();}
 update(dt,input){
  const model=this.motion.update(dt,input);
  for(let i=0;i<2;i++){
   const eye=this.meshes[i],pose=i===0?model.left:model.right,u=eye.material.uniforms;
   u.eyeSize.value.set(pose.width,pose.height);u.curve.value=pose.curve;u.lid.value=pose.lid;u.openness.value=pose.open;u.heart.value=pose.heart;
   eye.position.x=(i===0?-.31:.31)+pose.x;eye.position.y=pose.y;eye.rotation.z=pose.tilt;
   u.eyeCenter.value.set(eye.position.x,eye.position.y);u.eyeTilt.value=pose.tilt;
  }
 }
 stats(){return {state:this.motion.state,expression:this.motion.expression,left:{...this.motion.left},right:{...this.motion.right},elapsed:this.motion.time};}
}
